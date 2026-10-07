"""
10_verify_emails_csv.py — Verify a CSV of email addresses, at any scale.

This sample reads email addresses from a CSV file, checks each one with the
LeadIQ Prospector API, and writes the verdicts to a results CSV.  Like
08_verify_email.py it is read-only: nothing is created or changed in LeadIQ.

It is built for large files (hundreds of thousands of rows):

  • Parallel   — several requests run at once, under a shared rate cap.
  • Resumable  — every verdict is written to disk the moment it arrives.  If
                 the run stops for any reason (Ctrl+C, the terminal closing,
                 a crash, a network outage, running out of credits), run the
                 same command again and it picks up where it left off.
  • Retries    — rate limits (429) and temporary errors (5xx, timeouts) are
                 retried with a growing pause before giving up on an address.
  • Thrifty    — duplicate addresses are checked once, and addresses that are
                 obviously malformed are skipped without calling the API.

The verdict is one of four values:
  Verified        — the mailbox exists and accepts mail
  VerifiedLikely  — the address is very likely deliverable
  Unverified      — the address could not be confirmed either way
  Invalid         — the address will bounce; do not send to it

Two files are written to the output/ folder, named after the input file:
  <name>_results.csv — email, status   (one row per verified address)
  <name>_errors.csv  — email, error    (addresses that could not be checked)

Run the script again to retry the addresses in the errors file — addresses
already in the results file are never checked (or charged) twice.

IMPORTANT: Each address checked costs 0.1 credit — 100,000 addresses cost
10,000 credits.  The script shows the maximum cost and asks before starting.

Run it with:
    python rest/10_verify_emails_csv.py path/to/emails.csv

Options:
    --column NAME   the column holding the addresses (default: auto-detect
                    "email", "work_email", "workEmail" or "email_address")
    --workers N     how many requests to run at once (default: 10)
    --per-minute N  the most requests to start per minute (default: 60)
    --yes           skip the cost confirmation (for unattended runs)

Exit codes (useful when a scheduler or wrapper script runs this):
    0  finished — every address is in the results or errors file
    1  stopped by a problem you need to fix (invalid key, out of credits)
    3  stopped early (interrupted, or the API stopped answering) —
       run the same command again to continue
"""

import argparse
import atexit
import base64
import csv
import os
import queue
import random
import re
import signal
import sys
import threading
import time
import requests

# ── Configuration ─────────────────────────────────────────────────────────────

# The base URL for every Prospector API request.
PROSPECTOR_URL = "https://prospector.leadiq.com"

# Your API key is loaded from the .env file — never hard-code it here.
API_KEY = os.getenv("LEADIQ_API_KEY")


def _decode_key(key):
    # The .env file stores the "Secret Base64" key — a base64-encoded string.
    # The Prospector API needs the raw decoded version in the X-API-Key header.
    try:
        return base64.b64decode(key).decode("utf-8")
    except Exception:
        return key


# Where the results and errors files are written.
OUTPUT_DIR = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "output"))

# Column names we look for when --column is not given (compared case-insensitively).
EMAIL_COLUMNS = ("email", "work_email", "workemail", "email_address")

# The most requests we start per minute, across all workers combined — set it
# to your API key's rate limit.  The Prospector API reports its limit in every
# response (the "ratelimit-policy" header); the standard limit is 60 requests
# per minute, so 100,000 addresses take about 28 hours.  If the API answers
# 429 (Too Many Requests) anyway, every worker pauses, so a cap that is too
# high costs time, not credits.
DEFAULT_PER_MINUTE = 60

# How many requests can be in flight at once.  Some checks take several
# seconds (the verifier talks to the recipient's mail server), so to reach the
# per-minute cap you need roughly:  workers ≥ (per-minute ÷ 60) × seconds per
# check.  60/min with checks of up to 10 s needs 10.  Raising this never
# exceeds the per-minute cap.
DEFAULT_WORKERS = 10

# How long to wait for one answer.  Live mail-server checks can be slow.
REQUEST_TIMEOUT_SECONDS = 60

# How many times to retry an address after a rate limit or temporary error,
# and the first pause between attempts (it doubles each time: 2s, 4s, 8s ...).
MAX_RETRIES = 5
FIRST_BACKOFF_SECONDS = 2

# If this many addresses in a row fail even after their retries, the API (or
# your network) is down.  Stop instead of marking every remaining address as
# an error — the run can be resumed once things are back.
MAX_FAILURES_IN_A_ROW = 10

# How often to print a progress line, and how often to force the results to
# the physical disk (so they survive even a power cut), in seconds.
PROGRESS_EVERY_SECONDS = 10
SYNC_TO_DISK_EVERY_SECONDS = 5

STATUSES = ("Verified", "VerifiedLikely", "Unverified", "Invalid")

# A deliberately loose shape check: something@something.something, with no
# spaces, commas or quotes.  The API does the real validation — this only
# catches cells that are clearly not an address (blank cells, names, phone
# numbers) so they don't cost a call.
EMAIL_SHAPE = re.compile(r'^[^@\s,"]+@[^@\s,"]+\.[^@\s,"]+$')

# Exit codes — see the top of the file.
EXIT_NEEDS_FIX = 1
EXIT_STOPPED_EARLY = 3

# ── Rate limiting ─────────────────────────────────────────────────────────────

class RateLimiter:
    # Hands out "start" slots no faster than `per_minute`, shared by all
    # worker threads.  `pause()` pushes the next slot into the future — we
    # call it when the API says 429, so every worker backs off together.
    # `throttled` counts those 429s, so the progress line can show them: a
    # steady stream of 429s means --per-minute is higher than your limit.

    def __init__(self, per_minute, stop):
        self.interval = 60.0 / per_minute
        self.next_slot = time.monotonic()
        self.lock = threading.Lock()
        self.stop = stop
        self.throttled = 0

    def wait(self):
        with self.lock:
            now = time.monotonic()
            slot = max(now, self.next_slot)
            self.next_slot = slot + self.interval
        # stop.wait() sleeps like time.sleep(), but wakes up early if the run
        # is being stopped, so Ctrl+C never waits out a long pause.
        self.stop.wait(max(0.0, slot - time.monotonic()))

    def pause(self, seconds):
        with self.lock:
            self.throttled += 1
            self.next_slot = max(self.next_slot, time.monotonic() + seconds)

# ── API call ──────────────────────────────────────────────────────────────────

class FatalError(Exception):
    # Raised for problems that retrying cannot fix (bad key, no credits).
    pass


# requests.Session reuses connections, which matters at this volume — but a
# session should not be shared between threads, so each worker gets its own.
_local = threading.local()


def _session():
    if not hasattr(_local, "session"):
        _local.session = requests.Session()
        _local.session.headers.update({
            "X-API-Key": _decode_key(API_KEY),
            "Content-Type": "application/json",
        })
    return _local.session


def _retry_after(response, attempt):
    # How long to wait before trying again.  Prefer the server's own hints:
    #   Retry-After: 30                              — seconds to wait
    #   ratelimit: limit=60, remaining=0, reset=30   — seconds until the
    #                                                  rate-limit window resets
    # Otherwise back off exponentially, with a little randomness so workers
    # don't all retry at the same moment.
    if response is not None:
        retry_after = response.headers.get("Retry-After", "")
        if retry_after.isdigit():
            return int(retry_after)
        reset = re.search(r"reset=(\d+)", response.headers.get("ratelimit", ""))
        if reset:
            return int(reset.group(1)) + random.uniform(0, 1)
    return FIRST_BACKOFF_SECONDS * (2 ** attempt) + random.uniform(0, 1)


def _message(response):
    try:
        return response.json().get("message", "Unknown error")
    except ValueError:
        return response.text[:200] or "Unknown error"


def verify_email(email, limiter, stop):
    # Sends GET /v1/verify-email?email=... and returns one of:
    #   ("verdict",   status)  — the API answered; status is the verdict
    #   ("rejected",  reason)  — the API refused this address; retrying won't help
    #   ("failed",    reason)  — temporary errors on every attempt; worth a rerun
    #   ("abandoned", None)    — the run is stopping; the address was not finished
    # and raises FatalError for problems that affect every address.
    reason = None
    for attempt in range(MAX_RETRIES + 1):
        limiter.wait()
        if stop.is_set():
            return "abandoned", None

        response = None
        try:
            response = _session().get(
                f"{PROSPECTOR_URL}/v1/verify-email",
                params={"email": email},
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            code = response.status_code
            if code == 200:
                return "verdict", response.json()["status"]
            if code == 400:
                return "rejected", "malformed email"
            if code == 401:
                raise FatalError("Invalid API key — check LEADIQ_API_KEY in your .env file.")
            if code == 402:
                raise FatalError(f"Out of credits (402): {_message(response)}")
            if code == 403:
                raise FatalError(f"Access denied (403): {_message(response)}")
            if code == 429:
                # Rate limited: pause *every* worker through the shared limiter,
                # then try this address again.  No extra sleep here — the next
                # limiter.wait() does the waiting.
                limiter.pause(_retry_after(response, attempt))
                reason = "rate limited (429)"
                continue
            if code < 500:
                return "rejected", f"error {code}: {_message(response)}"
            reason = f"server error ({code})"
        except requests.exceptions.Timeout:
            reason = "timeout"
        except requests.exceptions.ConnectionError:
            reason = "connection error"

        if attempt < MAX_RETRIES and stop.wait(_retry_after(response, attempt)):
            return "abandoned", None

    return "failed", f"{reason} after {MAX_RETRIES + 1} attempts"

# ── Files ─────────────────────────────────────────────────────────────────────

def read_emails(path, column):
    # Returns the unique addresses in the CSV, in file order.  Addresses are
    # compared case-insensitively, so "Jane@Acme.com" and "jane@acme.com" are
    # checked (and charged) once.
    #
    # utf-8-sig silently drops the byte-order mark Excel adds to CSV exports.
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        headers = reader.fieldnames or []
        if column is None:
            column = next((h for h in headers if h.strip().lower() in EMAIL_COLUMNS), None)
        if column not in headers:
            print(f"Error: No email column found in {path}.")
            print(f"  Columns in the file: {', '.join(headers) or '(none)'}")
            print("  Pass the right one with --column NAME.")
            sys.exit(EXIT_NEEDS_FIX)

        seen = set()
        emails = []
        rows = 0
        for row in reader:
            rows += 1
            email = (row.get(column) or "").strip()
            key = email.lower()
            if key not in seen:
                seen.add(key)
                emails.append(email)
    return emails, rows, column


def read_done(results_path):
    # Addresses already in the results file from an earlier run.  A row only
    # counts if its status is one of the four verdicts — if a previous run was
    # killed halfway through writing a line, that cut-off line is ignored and
    # the address is simply checked again.
    if not os.path.exists(results_path):
        return set()
    with open(results_path, newline="", encoding="utf-8") as f:
        return {
            row["email"].strip().lower()
            for row in csv.DictReader(f)
            if row.get("email") and row.get("status") in STATUSES
        }


class CsvAppender:
    # A CSV file several threads can append to.  Every row is handed to the
    # operating system as soon as it is written, so it survives this program
    # being killed; every few seconds the file is also forced to the physical
    # disk, so it survives a power cut too.

    def __init__(self, path, header, mode):
        new_file = mode == "w" or not os.path.exists(path) or os.path.getsize(path) == 0
        if not new_file:
            _end_with_newline(path)
        self.file = open(path, mode, newline="", encoding="utf-8")
        # Plain "\n" line endings, the same as the bash and TypeScript versions
        # write (Python's csv module would otherwise use "\r\n").
        self.writer = csv.writer(self.file, lineterminator="\n")
        self.lock = threading.Lock()
        self.last_sync = time.monotonic()
        if new_file:
            self.write(header)

    def write(self, row):
        with self.lock:
            if self.file.closed:   # quitting on a second Ctrl+C
                return
            self.writer.writerow(row)
            self.file.flush()
            if time.monotonic() - self.last_sync >= SYNC_TO_DISK_EVERY_SECONDS:
                os.fsync(self.file.fileno())
                self.last_sync = time.monotonic()

    def close(self):
        with self.lock:
            self.file.flush()
            os.fsync(self.file.fileno())
            self.file.close()


def _end_with_newline(path):
    # If an earlier run was killed in the middle of writing a row, the file
    # ends with half a line.  Finish that line so the next row we append
    # starts on a fresh one instead of being glued onto the broken one.
    with open(path, "rb+") as f:
        f.seek(-1, os.SEEK_END)
        if f.read(1) != b"\n":
            f.write(b"\n")

def take_lock(lock_path, input_csv):
    # Two runs on the same file would check (and charge) the same addresses
    # twice, so only one run at a time may work on it.  The lock file holds
    # the process ID of the run that owns it; if that process is gone (it
    # crashed or was killed), the lock is stale and we take it over.
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        try:
            with open(lock_path) as f:
                owner = int(f.read().strip() or 0)
        except (OSError, ValueError):
            owner = 0
        if owner and _process_alive(owner):
            print(f"Error: Another run (process {owner}) is already working on {input_csv}.")
            print("  Wait for it to finish or stop it first — two runs would pay for the same addresses twice.")
            print(f"  If you are sure no other run is going, delete {lock_path}")
            sys.exit(EXIT_NEEDS_FIX)
        fd = os.open(lock_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY)
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)
    atexit.register(_release_lock, lock_path)


def _process_alive(pid):
    if os.name == "nt":
        # Windows has no safe "is this process alive?" check in the standard
        # library (os.kill would terminate it), so assume the lock is live.
        return True
    try:
        os.kill(pid, 0)   # signal 0 checks the process exists without touching it
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _release_lock(lock_path):
    try:
        with open(lock_path) as f:
            if f.read().strip() == str(os.getpid()):
                os.remove(lock_path)
    except OSError:
        pass

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Verify a CSV of email addresses.")
    parser.add_argument("input_csv", help="CSV file with a column of email addresses")
    parser.add_argument("--column", help="name of the email column (default: auto-detect)")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"requests to run at once (default: {DEFAULT_WORKERS})")
    parser.add_argument("--per-minute", type=int, default=DEFAULT_PER_MINUTE,
                        help=f"most requests to start per minute (default: {DEFAULT_PER_MINUTE})")
    parser.add_argument("--yes", action="store_true", help="skip the cost confirmation")
    args = parser.parse_args()

    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(EXIT_NEEDS_FIX)

    if not os.path.exists(args.input_csv):
        print(f"Error: File not found: {args.input_csv}")
        sys.exit(EXIT_NEEDS_FIX)

    name = os.path.splitext(os.path.basename(args.input_csv))[0]
    results_path = os.path.join(OUTPUT_DIR, f"{name}_results.csv")
    errors_path  = os.path.join(OUTPUT_DIR, f"{name}_errors.csv")

    os.makedirs(OUTPUT_DIR, exist_ok=True)
    take_lock(os.path.join(OUTPUT_DIR, f"{name}.lock"), args.input_csv)

    emails, rows, column = read_emails(args.input_csv, args.column)
    done = read_done(results_path)

    # Split the unique addresses into: already done, malformed, and to check.
    todo      = [e for e in emails if e.lower() not in done]
    malformed = [e for e in todo if not EMAIL_SHAPE.match(e)]
    todo      = [e for e in todo if EMAIL_SHAPE.match(e)]

    print(f"Input          : {args.input_csv} ({rows:,} rows, column '{column}')")
    print(f"Unique emails  : {len(emails):,}")
    print(f"Already done   : {len(emails) - len(todo) - len(malformed):,} (in {results_path})")
    print(f"Malformed      : {len(malformed):,} (skipped, no credit used)")
    print(f"To check       : {len(todo):,}")
    print(f"Max credits    : {len(todo) * 0.1:,.1f}")
    est_hours = len(todo) / args.per_minute / 60
    print(f"Est. time      : ~{est_hours:.1f} h at {args.per_minute} requests/min")
    print()

    # The errors file is rewritten on every run: it lists what is still left
    # to retry, not the history of everything that ever failed.
    errors = CsvAppender(errors_path, ["email", "error"], "w")
    for email in malformed:
        errors.write([email, "malformed email" if email else "blank email"])

    if not todo:
        errors.close()
        print("Nothing left to check.")
        return

    if not args.yes:
        if not sys.stdin.isatty():
            print("Refusing to spend credits without confirmation — pass --yes to run unattended.")
            sys.exit(EXIT_NEEDS_FIX)
        answer = input(f"Spend up to {len(todo) * 0.1:,.1f} credits? [y/N] ").strip().lower()
        if answer != "y":
            print("Cancelled.")
            sys.exit(0)

    results = CsvAppender(results_path, ["email", "status"], "a")

    # ── Workers ───────────────────────────────────────────────────────────────
    # Each worker takes addresses from a shared queue until it is empty, or
    # until `stop` is set: by Ctrl+C, by a fatal error like an invalid key, or
    # by too many failures in a row.

    work = queue.Queue()
    for email in todo:
        work.put(email)

    stop    = threading.Event()
    limiter = RateLimiter(args.per_minute, stop)
    counts  = {s: 0 for s in STATUSES}
    counts["errors"] = 0
    lock = threading.Lock()   # guards counts, failures_in_a_row and stopped_by
    failures_in_a_row = 0
    stopped_by = None         # (kind, message) — the first reason the run stopped

    def stop_run(kind, message=None):
        # kind is "fatal" (needs a fix), "outage" or "interrupted" (rerun later).
        nonlocal stopped_by
        with lock:
            stopped_by = stopped_by or (kind, message)
        stop.set()

    def worker():
        nonlocal failures_in_a_row
        while not stop.is_set():
            try:
                email = work.get_nowait()
            except queue.Empty:
                return
            try:
                outcome, detail = verify_email(email, limiter, stop)
            except FatalError as e:
                stop_run("fatal", str(e))
                return
            if outcome == "abandoned":
                return   # not written anywhere, so the next run checks it again

            if outcome == "verdict":
                results.write([email, detail])
            else:
                errors.write([email, detail])

            with lock:
                counts[detail if outcome == "verdict" else "errors"] += 1
                failures_in_a_row = failures_in_a_row + 1 if outcome == "failed" else 0
                outage = failures_in_a_row >= MAX_FAILURES_IN_A_ROW
            if outage:
                stop_run("outage", f"{MAX_FAILURES_IN_A_ROW} addresses in a row failed after "
                                   f"retries (last: {detail}) — the API or your network looks down.")

    # Ctrl+C (SIGINT), `kill` (SIGTERM) and a closed terminal window (SIGHUP)
    # all take the same careful shutdown path below.  SIGINT is set up here
    # too, even though Python normally handles it: when a script is started in
    # the background (`... &` from another script), Ctrl+C arrives switched
    # off, and Python then leaves it off.
    def interrupt(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    if hasattr(signal, "SIGHUP"):   # not available on Windows
        signal.signal(signal.SIGHUP, interrupt)

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(args.workers)]
    started = time.monotonic()
    for t in threads:
        t.start()

    def progress():
        with lock:
            snapshot = dict(counts)
        finished = sum(snapshot.values())
        elapsed = time.monotonic() - started
        rate = finished / elapsed * 60 if elapsed else 0
        left = len(todo) - finished
        eta = f"{left / rate / 60:,.1f} h" if rate else "?"
        buckets = "  ".join(f"{s}={snapshot[s]:,}" for s in STATUSES)
        print(f"[{finished:,}/{len(todo):,}] {rate:.0f}/min  ETA {eta}  "
              f"{buckets}  errors={snapshot['errors']:,}  429s={limiter.throttled:,}", flush=True)

    try:
        next_report = time.monotonic() + PROGRESS_EVERY_SECONDS
        while any(t.is_alive() for t in threads):
            time.sleep(0.2)
            if time.monotonic() >= next_report:
                progress()
                next_report += PROGRESS_EVERY_SECONDS
    except KeyboardInterrupt:
        # Requests already sent are paid for, so give them a chance to finish
        # and be saved.  Workers stop picking up new addresses straight away.
        stop_run("interrupted")
        print("\nStopping — saving the requests already in flight "
              "(press Ctrl+C again to quit now)...", flush=True)
        try:
            for t in threads:
                t.join()
        except KeyboardInterrupt:
            # Everything written so far is already on disk.  Only the answers
            # still in flight are lost, and the next run checks them again.
            print("\nQuitting now.")

    results.close()
    errors.close()

    print()
    progress()
    print()
    for status in STATUSES:
        print(f"{status:<15}: {counts[status]:,}")
    print(f"{'Errors':<15}: {counts['errors']:,}")
    print(f"{'Rate limited':<15}: {limiter.throttled:,} (429 responses, each one retried)")
    print(f"{'Results':<15}: {results_path}")
    print(f"{'Errors file':<15}: {errors_path}")

    if stopped_by:
        kind, message = stopped_by
        print()
        if kind == "fatal":
            print(f"Error: {message}")
            print("Your results so far are saved — fix the problem, then run the same command again.")
            sys.exit(EXIT_NEEDS_FIX)
        if message:
            print(f"Stopped: {message}")
        print("Stopped early — your results so far are saved. Run the same command again to continue.")
        sys.exit(EXIT_STOPPED_EARLY)
    if counts["errors"]:
        print()
        print("Some addresses could not be checked — run the same command again to retry them.")


if __name__ == "__main__":
    main()
