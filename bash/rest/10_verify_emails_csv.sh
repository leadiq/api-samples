#!/usr/bin/env bash
# 10_verify_emails_csv.sh — Verify a CSV of email addresses, at any scale.
#
# This script reads email addresses from a CSV file, checks each one with the
# LeadIQ Prospector API, and writes the verdicts to a results CSV.  Like
# 08_verify_email.sh it is read-only: nothing is created or changed in LeadIQ.
#
# The only column the input needs is the email address.  Any other columns —
# person id, name, company, your own ids — are optional: they are not sent to
# the API, and they are copied unchanged into the merged file (see below) so
# you can match every verdict back to your own records.
#
# It is built for large files (hundreds of thousands of rows):
#
#   • Parallel   — several requests run at once, under a shared rate cap.
#   • Resumable  — every verdict is written to disk the moment it arrives.  If
#                  the run stops for any reason (Ctrl+C, the terminal closing,
#                  a crash, a network outage, running out of credits), run the
#                  same command again and it picks up where it left off.
#   • Retries    — rate limits (429) and temporary errors (5xx, timeouts) are
#                  retried with a growing pause before giving up on an address.
#   • Thrifty    — duplicate addresses are checked once, and addresses that are
#                  obviously malformed are skipped without calling the API.
#
# The verdict is one of four values:
#   Verified        — the mailbox exists and accepts mail
#   VerifiedLikely  — the address is very likely deliverable
#   Unverified      — the address could not be confirmed either way
#   Invalid         — the address will bounce; do not send to it
#
# Three files are written to the output/ folder, named after the input file:
#   <name>_results.csv — email,status   (one row per verified address)
#   <name>_errors.csv  — email,error    (addresses that could not be checked)
#   <name>_merged.csv  — every input row with all its columns, plus
#                        verification_status and verification_error
#                        (rewritten at the end of every run)
#
# Run the script again to retry the addresses in the errors file — addresses
# already in the results file are never checked (or charged) twice.
#
# IMPORTANT: Each address checked costs 0.1 credit — 100,000 addresses cost
# 10,000 credits.  The script shows the maximum cost and asks before starting.
#
# Needs only bash and curl.  The CSV may use quoted fields ("Smith, Jane"),
# but a quoted field must not contain a line break.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash rest/10_verify_emails_csv.sh path/to/emails.csv
#
# Options:
#   --column NAME   the column holding the addresses (default: auto-detect
#                   "email", "work_email", "workEmail" or "email_address")
#   --workers N     how many requests to run at once (default: 150)
#   --per-minute N  the most requests to start per minute (default: 900)
#   --yes           skip the cost confirmation (for unattended runs)
#
# Exit codes (useful when a scheduler or wrapper script runs this):
#   0  finished — every address is in the results or errors file
#   1  stopped by a problem you need to fix (invalid key, out of credits)
#   3  stopped early (interrupted, or the API stopped answering) —
#      run the same command again to continue

# ── Configuration ─────────────────────────────────────────────────────────────

PROSPECTOR_URL="https://prospector.leadiq.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../output"

# Column names we look for when --column is not given (compared case-insensitively).
EMAIL_COLUMNS="email work_email workemail email_address"

# The most requests we start per minute, across all workers combined.  The
# verify-email limit is 450 requests per minute per API key on EACH API
# server, and the API runs on 2 servers that share the traffic, so a key gets
# 2 × 450 = 900 a minute in total — 100,000 addresses take about 2 hours.
# (The "ratelimit-policy" header in each response shows one server's 450, not
# the total.)  If the API answers 429 (Too Many Requests) anyway, every worker
# pauses, so a cap that is too high costs time, not credits — if the progress
# line shows a steady stream of 429s, lower it with --per-minute.
PER_MINUTE=900

# How many requests can be in flight at once.  Some checks take several
# seconds (the verifier talks to the recipient's mail server), so to reach the
# per-minute cap you need roughly:  workers ≥ (per-minute ÷ 60) × seconds per
# check.  900/min with checks of up to 10 s needs 150.
WORKERS=150

# How long to wait for one answer (seconds).  Live mail-server checks can be slow.
REQUEST_TIMEOUT_SECONDS=60

# How many times to retry an address after a rate limit or temporary error,
# and the first pause between attempts (it doubles each time: 2s, 4s, 8s ...).
MAX_RETRIES=5
FIRST_BACKOFF_SECONDS=2

# If this many addresses in a row fail even after their retries, AND the API
# has not answered any address for OUTAGE_AFTER_SECONDS, the API (or your
# network) is down.  Stop instead of marking every remaining address as an
# error — the run can be resumed once things are back.  (Both conditions are
# needed: a handful of addresses can fail on their own — some mail servers
# never answer the verifier — without anything being down.)
MAX_FAILURES_IN_A_ROW=10
OUTAGE_AFTER_SECONDS=300

# How often to print a progress line (and ask the OS to write everything to
# the physical disk, so results survive even a power cut), in seconds.
PROGRESS_EVERY_SECONDS=10

# A deliberately loose shape check: something@something.something, with no
# spaces, commas or quotes.  The API does the real validation — this only
# catches cells that are clearly not an address (blank cells, names, phone
# numbers) so they don't cost a call.
EMAIL_SHAPE='^[^@[:space:],"]+@[^@[:space:],"]+[.][^@[:space:],"]+$'

EXIT_NEEDS_FIX=1
EXIT_STOPPED_EARLY=3

# ── Arguments ─────────────────────────────────────────────────────────────────

INPUT=""
COLUMN=""
YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --column)     COLUMN="$2"; shift 2 ;;
    --workers)    WORKERS="$2"; shift 2 ;;
    --per-minute) PER_MINUTE="$2"; shift 2 ;;
    --yes)        YES=1; shift ;;
    -*)           echo "Unknown option: $1"; exit $EXIT_NEEDS_FIX ;;
    *)            INPUT="$1"; shift ;;
  esac
done

if [[ -z "$INPUT" ]]; then
  echo "Usage: bash rest/10_verify_emails_csv.sh path/to/emails.csv [--column NAME] [--workers N] [--per-minute N] [--yes]"
  exit $EXIT_NEEDS_FIX
fi

if [[ -z "${LEADIQ_API_KEY:-}" ]]; then
  echo "Error: LEADIQ_API_KEY is not set."
  echo "  Run: export LEADIQ_API_KEY=your_secret_base64_key"
  exit $EXIT_NEEDS_FIX
fi

if ! command -v curl &>/dev/null; then
  echo "Error: curl is required but not installed."
  exit $EXIT_NEEDS_FIX
fi

if [[ ! -f "$INPUT" ]]; then
  echo "Error: File not found: $INPUT"
  exit $EXIT_NEEDS_FIX
fi

# ── Decode API key ─────────────────────────────────────────────────────────────

# The Prospector API needs the raw decoded version of the base64 API key.
PROSPECTOR_KEY=$(printf '%s' "$LEADIQ_API_KEY" | base64 -d 2>/dev/null \
  || printf '%s' "$LEADIQ_API_KEY" | base64 -D 2>/dev/null)

if [[ -z "$PROSPECTOR_KEY" ]]; then
  echo "Error: Could not decode the API key."
  exit $EXIT_NEEDS_FIX
fi

# ── Working files ─────────────────────────────────────────────────────────────

name=$(basename "$INPUT"); name="${name%.*}"
mkdir -p "$OUTPUT_DIR"
RESULTS="$OUTPUT_DIR/${name}_results.csv"
ERRORS="$OUTPUT_DIR/${name}_errors.csv"
MERGED="$OUTPUT_DIR/${name}_merged.csv"

# A private scratch folder for this run.  The background workers use small
# files in it to share state with each other:
#   headers         the API key header (kept out of the process list, where
#                   other users of this machine could see a -H argument)
#   stop            exists once the run is stopping
#   fatal / outage  why the run stopped
#   pause_until     a 429 asked everyone to wait until this time (epoch secs)
#   throttled       one line per 429 response, for the progress line
#   failures        one line per address that failed in a row
#   last_answer     when the API last answered any address (epoch secs)
STATE=$(mktemp -d)
chmod 700 "$STATE"

# Two runs on the same file would check (and charge) the same addresses
# twice, so only one run at a time may work on it.  The lock file holds the
# process ID of the run that owns it; if that process is gone (it crashed or
# was killed), the lock is stale and we take it over.
LOCK="$OUTPUT_DIR/${name}.lock"
if ! ( set -o noclobber; echo $$ > "$LOCK" ) 2>/dev/null; then
  owner=$(cat "$LOCK" 2>/dev/null)
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    echo "Error: Another run (process $owner) is already working on $INPUT."
    echo "  Wait for it to finish or stop it first — two runs would pay for the same addresses twice."
    echo "  If you are sure no other run is going, delete $LOCK"
    rm -rf "$STATE"
    exit $EXIT_NEEDS_FIX
  fi
  echo $$ > "$LOCK"
fi

cleanup() {
  rm -rf "$STATE"
  [[ "$(cat "$LOCK" 2>/dev/null)" == "$$" ]] && rm -f "$LOCK"
}
trap cleanup EXIT
printf 'X-API-Key: %s\n' "$PROSPECTOR_KEY" > "$STATE/headers"
: > "$STATE/failures"
: > "$STATE/throttled"
date +%s > "$STATE/last_answer"

# ── Read the CSV ──────────────────────────────────────────────────────────────

# awk helpers shared by extract_column and write_merged.  parse() splits a CSV
# line into F[1..n] and handles quoted fields ("Smith, Jane" and
# "say ""hi"""); find_column() picks the email column from the header line
# (--column, or the first header in EMAIL_COLUMNS), or prints the headers to
# stderr and exits 2.  Both awk programs also strip Windows line endings and
# the byte-order mark Excel adds.
CSV_AWK='
    function parse(line,   n, i, c, field, inq) {
      if (index(line, "\"") == 0) return split(line, F, ",")
      n = 0; field = ""; inq = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (inq) {
          if (c == "\"") {
            if (substr(line, i + 1, 1) == "\"") { field = field "\""; i++ }
            else inq = 0
          } else field = field c
        }
        else if (c == "\"") inq = 1
        else if (c == ",") { F[++n] = field; field = "" }
        else field = field c
      }
      F[++n] = field
      return n
    }
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function find_column(line,   n, i, h, list) {
      split(auto, names, " "); for (i in names) wanted[names[i]] = 1
      n = parse(line)
      for (i = 1; i <= n; i++) {
        h = trim(F[i])
        if ((want != "" && h == want) || (want == "" && tolower(h) in wanted)) return i
      }
      list = ""
      for (i = 1; i <= n; i++) list = list (i > 1 ? ", " : "") trim(F[i])
      print list > "/dev/stderr"
      exit 2
    }
'

# Print the email column of the CSV, one address per line.  LC_ALL=C makes awk
# treat the file as plain bytes, which behaves the same on macOS and Linux.
extract_column() {
  LC_ALL=C awk -v want="$COLUMN" -v auto="$EMAIL_COLUMNS" "$CSV_AWK"'
    { sub(/\r$/, "") }
    NR == 1 {
      if (substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
      col = find_column($0)
      next
    }
    { delete F; parse($0); print trim(F[col]) }
  ' "$INPUT"
}

# Write the merged file: every input line, unchanged, with the verdict for its
# address added as two more columns.  Rows that share an address all get the
# same verdict (it was checked once).  Rows not checked yet — the run stopped
# early — get neither; run the script again to fill them in.  It is written to
# a temporary file first and then renamed, so it is never left half-written.
write_merged() {
  LC_ALL=C awk -v want="$COLUMN" -v auto="$EMAIL_COLUMNS" -v shape="$EMAIL_SHAPE" "$CSV_AWK"'
    function csv(s) { if (s ~ /[",]/) { gsub(/"/, "\"\"", s); s = "\"" s "\"" } return s }
    FILENAME == ARGV[1] {   # the results file: email,status
      if (FNR > 1 && $0 ~ /,(Verified|VerifiedLikely|Unverified|Invalid)\r?$/) {
        i = index($0, ","); s = substr($0, i + 1); sub(/\r$/, "", s)
        status[tolower(substr($0, 1, i - 1))] = s
      }
      next
    }
    FILENAME == ARGV[2] {   # the errors file: email,error
      if (FNR > 1 && (i = index($0, ","))) error[tolower(substr($0, 1, i - 1))] = substr($0, i + 1)
      next
    }
    { sub(/\r$/, "") }
    FNR == 1 {
      if (substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
      col = find_column($0); columns = parse($0)
      print $0 ",verification_status,verification_error"
      next
    }
    {
      delete F; n = parse($0); line = $0
      for (; n < columns; n++) line = line ","   # pad short rows so the new columns line up
      key = tolower(trim(F[col]))
      # Blank and malformed cells never reached the API (and may hold commas
      # or quotes the plain errors file cannot be split on), so label them here.
      if (key == "")            print line ",,blank email"
      else if (key !~ shape)    print line ",,malformed email"
      else if (key in status)   print line "," status[key] ","
      else                      print line ",," csv(error[key])
    }
  ' "$RESULTS" "$ERRORS" "$INPUT" > "$MERGED.tmp" && mv "$MERGED.tmp" "$MERGED"
}

ALL="$STATE/all_emails"
if ! extract_column > "$ALL" 2> "$STATE/columns"; then
  echo "Error: No email column found in $INPUT."
  echo "  Columns in the file: $(cat "$STATE/columns")"
  echo "  Pass the right one with --column NAME."
  exit $EXIT_NEEDS_FIX
fi
rows=$(wc -l < "$ALL" | tr -d ' ')

# If an earlier run was killed in the middle of writing a row, the results
# file ends with half a line.  Finish that line so the next row we append
# starts on a fresh one instead of being glued onto the broken one.
if [[ -s "$RESULTS" && -n "$(tail -c 1 "$RESULTS")" ]]; then
  echo >> "$RESULTS"
fi
[[ -s "$RESULTS" ]] || echo "email,status" > "$RESULTS"

# Split the addresses into: already done, malformed, and to check.
#  • Addresses are compared case-insensitively, so "Jane@Acme.com" and
#    "jane@acme.com" are checked (and charged) once.
#  • A results row only counts as done if its status is one of the four
#    verdicts — a half-written line from a killed run is checked again.
#  • Addresses in the previous run's errors file are checked LAST: an address
#    that failed before often fails again, slowly, and if a few of them came
#    first they could keep every worker busy while thousands of healthy
#    addresses wait.
TODO="$STATE/todo"
RETRY="$STATE/retry"
MALFORMED="$STATE/malformed"
PREVIOUS_ERRORS="$ERRORS"
[[ -f "$PREVIOUS_ERRORS" ]] || PREVIOUS_ERRORS=/dev/null
summary=$(LC_ALL=C awk -F, -v shape="$EMAIL_SHAPE" -v todo="$TODO" -v retry="$RETRY" -v bad="$MALFORMED" '
  FILENAME == ARGV[1] {   # the results file
    if (FNR > 1 && $2 ~ /^(Verified|VerifiedLikely|Unverified|Invalid)$/) done[tolower($1)] = 1
    next
  }
  FILENAME == ARGV[2] {   # the previous errors file (or /dev/null if there is none)
    if (FNR > 1 && $1 != "") failed[tolower($1)] = 1
    next
  }
  {
    key = tolower($0)
    if (key in seen) next
    seen[key] = 1; unique++
    if (key in done)        already++
    else if ($0 !~ shape)   { print > bad;   malformed++ }
    else if (key in failed) { print > retry; check++; retried++ }
    else                    { print > todo;  check++ }
  }
  END { printf "%d %d %d %d %d", unique, already, malformed, check, retried }
' "$RESULTS" "$PREVIOUS_ERRORS" "$ALL")
read -r unique already malformed to_check retried <<< "$summary"
touch "$TODO" "$RETRY" "$MALFORMED"
cat "$RETRY" >> "$TODO"

credits=$(awk "BEGIN { printf \"%.1f\", $to_check * 0.1 }")
echo "Input          : $INPUT ($rows rows)"
echo "Unique emails  : $unique"
echo "Already done   : $already (in $RESULTS)"
echo "Malformed      : $malformed (skipped, no credit used)"
[[ "$retried" -gt 0 ]] && echo "Retried last   : $retried (could not be checked in an earlier run)"
echo "To check       : $to_check"
echo "Max credits    : $credits"
echo "Est. time      : ~$(awk "BEGIN { printf \"%.1f\", $to_check / $PER_MINUTE / 60 }") h at $PER_MINUTE requests/min"
echo ""

if [[ "$to_check" -gt 0 && $YES -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "Refusing to spend credits without confirmation — pass --yes to run unattended."
    exit $EXIT_NEEDS_FIX
  fi
  read -r -p "Spend up to $credits credits? [y/N] " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# The errors file is rewritten on every run: it lists what is still left to
# retry, not the history of everything that ever failed.  (Only once the run
# is confirmed — a cancelled run must not lose that list.)
echo "email,error" > "$ERRORS"
while IFS= read -r email; do
  if [[ -z "$email" ]]; then echo ",blank email"; else echo "$email,malformed email"; fi
done < "$MALFORMED" >> "$ERRORS"

if [[ "$to_check" -eq 0 ]]; then
  write_merged
  echo "Nothing left to check."
  echo "Merged file    : $MERGED"
  exit 0
fi

# ── Worker ────────────────────────────────────────────────────────────────────

# A worker stops when the run is stopping — or when the main script is gone
# (killed with kill -9), so no worker carries on unsupervised.
MAIN_PID=$$
is_stopping() { [[ -e "$STATE/stop" ]] || ! kill -0 "$MAIN_PID" 2>/dev/null; }

# Sleep for $1 seconds (may be fractional), waking early if the run is stopping.
# Returns 1 if it was woken by a stop.
sleep_unless_stopped() {
  local steps i
  steps=$(awk "BEGIN { print int($1 / 0.5) + 1 }")
  for ((i = 0; i < steps; i++)); do
    is_stopping && return 1
    sleep 0.5
  done
  return 0
}

# The API answered this address (whatever the answer): reset the run of
# failures and note the time, for the outage check.
answered() {
  : > "$STATE/failures"
  date +%s > "$STATE/last_answer"
}

# Write one line to a file shared by all workers.  A single short append is
# one write to the OS, so lines from different workers never get mixed up —
# and once written, the line survives this script being killed.
append() { printf '%s\n' "$2" >> "$1"; }

# Check one address, retrying temporary errors, and record the outcome.
# Runs in the background — one copy per request in flight.
verify_one() {
  local email="$1" attempt=0 reason="" response rc code body status wait_s retry_after

  while true; do
    # The run is stopping: leave this address unrecorded so the next run
    # checks it again.
    is_stopping && return

    # GET /v1/verify-email?email=...
    #   -G + --data-urlencode puts the address in the URL, escaping "+" etc.
    #   -D - includes the response headers, so we can read Retry-After.
    #   -H @file reads the API key header from our private file.
    response=$(curl -s --max-time "$REQUEST_TIMEOUT_SECONDS" -G -D - \
      "$PROSPECTOR_URL/v1/verify-email" \
      --data-urlencode "email=$email" \
      -H @"$STATE/headers" \
      -w "\n%{http_code}")
    rc=$?
    code=$(printf '%s' "$response" | tail -1)
    body=$(printf '%s' "$response" | sed '$d' | tail -1)
    # How long the server wants us to wait, if it says:
    #   Retry-After: 30                              — seconds to wait
    #   ratelimit: limit=60, remaining=0, reset=30   — seconds until the
    #                                                  rate-limit window resets
    retry_after=$(printf '%s' "$response" | tr -d '\r' | grep -i '^retry-after:' | grep -oE '[0-9]+' | head -1)
    if [[ -z "$retry_after" ]]; then
      retry_after=$(printf '%s' "$response" | tr -d '\r' | grep -i '^ratelimit:' | grep -oE 'reset=[0-9]+' | cut -d= -f2 | head -1)
    fi

    case "$code" in
      200)
        # The response body is a single field, e.g. {"status":"Verified"}
        status=$(echo "$body" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
        if [[ -n "$status" ]]; then
          append "$RESULTS" "$email,$status"
        else
          append "$ERRORS" "$email,unexpected response"
        fi
        answered
        return ;;
      400)
        append "$ERRORS" "$email,malformed email"
        answered
        return ;;
      401) echo "Invalid API key — check LEADIQ_API_KEY." > "$STATE/fatal"; touch "$STATE/stop"; return ;;
      402) echo "Out of credits (402)." > "$STATE/fatal"; touch "$STATE/stop"; return ;;
      403) echo "Access denied (403)." > "$STATE/fatal"; touch "$STATE/stop"; return ;;
      429)
        # Rate limited: tell every worker (and the dispatcher) to pause.
        reason="rate limited (429)"
        echo x >> "$STATE/throttled"
        wait_s=${retry_after:-$(awk -v f="$FIRST_BACKOFF_SECONDS" -v n="$attempt" 'BEGIN { print int(f * 2 ^ n) + 1 }')}
        echo $(( $(date +%s) + wait_s )) > "$STATE/pause_until" ;;
      000)
        # curl could not get an answer at all.  Exit code 28 means it timed out.
        if [[ $rc -eq 28 ]]; then reason="timeout"; else reason="connection error"; fi ;;
      5*)
        reason="server error ($code)" ;;
      *)
        append "$ERRORS" "$email,error $code"
        answered
        return ;;
    esac

    attempt=$((attempt + 1))
    if [[ $attempt -gt $MAX_RETRIES ]]; then
      append "$ERRORS" "$email,$reason after $((MAX_RETRIES + 1)) attempts"
      echo x >> "$STATE/failures"
      return
    fi

    # Wait before trying again: the server's Retry-After if it sent one,
    # otherwise a pause that doubles each time, plus a little randomness so
    # workers don't all retry at the same moment.
    wait_s=${retry_after:-$(awk -v f="$FIRST_BACKOFF_SECONDS" -v n="$((attempt - 1))" -v r="$RANDOM" \
      'BEGIN { printf "%.2f", f * 2 ^ n + r / 32768 }')}
    sleep_unless_stopped "$wait_s" || return
  done
}

# ── Progress ──────────────────────────────────────────────────────────────────

start_lines=$(wc -l < "$RESULTS" | tr -d ' ')
start_errors=$(wc -l < "$ERRORS" | tr -d ' ')
started=$SECONDS

# Counts for this run: verdicts appended to the results file since we
# started, and errors appended to the errors file (excluding malformed rows).
counts() {
  tail -n +$((start_lines + 1)) "$RESULTS" | awk -F, -v errs="$(( $(wc -l < "$ERRORS") - start_errors ))" '
    { c[$2]++; n++ }
    END { printf "%d %d %d %d %d %d", n + errs, c["Verified"], c["VerifiedLikely"], c["Unverified"], c["Invalid"], errs }'
}

throttled() { wc -l < "$STATE/throttled" | tr -d ' '; }

progress() {
  local finished v vl u i e elapsed
  read -r finished v vl u i e <<< "$(counts)"
  elapsed=$((SECONDS - started))
  awk -v th="$(throttled)" -v f="$finished" -v t="$to_check" -v s="$elapsed" -v v="$v" -v vl="$vl" -v u="$u" -v i="$i" -v e="$e" 'BEGIN {
    rate = s > 0 ? f / s * 60 : 0
    eta = rate > 0 ? sprintf("%.1f h", (t - f) / rate / 60) : "?"
    printf "[%d/%d] %.0f/min  ETA %s  Verified=%d  VerifiedLikely=%d  Unverified=%d  Invalid=%d  errors=%d  429s=%d\n", f, t, rate, eta, v, vl, u, i, e, th
  }'
}

# ── Stopping ──────────────────────────────────────────────────────────────────

# Ctrl+C (INT), `kill` (TERM) and a closed terminal (HUP) all land here.  The
# first one stops new requests and lets the ones in flight finish — they are
# already paid for.  (Background jobs in a script ignore Ctrl+C, so curl keeps
# going.)  A second one quits right away; anything not yet answered is simply
# checked again next run.
#
# One exception: if this script is started in the background from another
# script (`bash 10_verify_emails_csv.sh ... &`), bash starts it with Ctrl+C
# switched off and won't let it be switched back on.  Stop such a run with
# `kill PID` instead — that takes the same careful path.
on_signal() {
  if [[ -e "$STATE/interrupted" ]]; then
    echo ""
    echo "Quitting now."
    kill $(jobs -p) 2>/dev/null
    finish
  fi
  touch "$STATE/interrupted" "$STATE/stop"
  echo ""
  echo "Stopping — saving the requests already in flight (press Ctrl+C again to quit now)..."
}
trap on_signal INT TERM HUP

finish() {
  local finished v vl u i e
  write_merged
  sync
  echo ""
  progress
  read -r finished v vl u i e <<< "$(counts)"
  echo ""
  echo "Verified       : $v"
  echo "VerifiedLikely : $vl"
  echo "Unverified     : $u"
  echo "Invalid        : $i"
  echo "Errors         : $e"
  echo "Rate limited   : $(throttled) (429 responses, each one retried)"
  echo "Results        : $RESULTS"
  echo "Errors file    : $ERRORS"
  echo "Merged file    : $MERGED"

  if [[ -e "$STATE/fatal" ]]; then
    echo ""
    echo "Error: $(cat "$STATE/fatal")"
    echo "Your results so far are saved — fix the problem, then run the same command again."
    exit $EXIT_NEEDS_FIX
  fi
  if [[ -e "$STATE/stop" ]]; then
    echo ""
    [[ -e "$STATE/outage" ]] && echo "Stopped: $(cat "$STATE/outage")"
    echo "Stopped early — your results so far are saved. Run the same command again to continue."
    exit $EXIT_STOPPED_EARLY
  fi
  if [[ "$e" -gt 0 ]]; then
    echo ""
    echo "Some addresses could not be checked — run the same command again to retry them."
  fi
  exit 0
}

# ── Main loop ─────────────────────────────────────────────────────────────────

next_report=$((SECONDS + PROGRESS_EVERY_SECONDS))

# Pacing: after `elapsed` seconds we may have started at most
# (elapsed + 1) × PER_MINUTE ÷ 60 requests.  Counting against the clock (rather
# than sleeping a fixed gap after each start) keeps the real rate on target
# even though starting a request takes a little time itself.
pace_start=$SECONDS
launched=0

# Stop if too many addresses in a row failed after all their retries and the
# API has not answered anything for OUTAGE_AFTER_SECONDS.
check_outage() {
  local n last
  n=$(wc -l < "$STATE/failures" | tr -d ' ')
  last=$(cat "$STATE/last_answer" 2>/dev/null)
  if [[ ${n:-0} -ge $MAX_FAILURES_IN_A_ROW && $(( $(date +%s) - ${last:-0} )) -ge $OUTAGE_AFTER_SECONDS ]]; then
    echo "$n addresses in a row failed after retries and no answer for $((OUTAGE_AFTER_SECONDS / 60)) minutes — the API or your network looks down." > "$STATE/outage"
    touch "$STATE/stop"
  fi
}

while IFS= read -r email; do
  check_outage
  is_stopping && break

  # Wait for a free worker slot.
  while [[ $(jobs -rp | wc -l) -ge $WORKERS ]]; do
    sleep 0.05
    is_stopping && break 2
  done

  # Wait for the next start slot under the per-minute cap.
  while (( launched * 60 >= (SECONDS - pace_start + 1) * PER_MINUTE )); do
    sleep 0.05
    is_stopping && break 2
  done

  # If a worker hit a 429, hold off starting anything new until it's over,
  # then restart the pacing clock so we don't burst to "catch up".
  until_ts=$(cat "$STATE/pause_until" 2>/dev/null)
  now=$(date +%s)
  if [[ -n "$until_ts" && $until_ts -gt $now ]]; then
    sleep $((until_ts - now))
    is_stopping && break
    pace_start=$SECONDS
    launched=0
  fi

  verify_one "$email" &
  launched=$((launched + 1))

  if [[ $SECONDS -ge $next_report ]]; then
    progress
    sync   # ask the OS to write everything to the physical disk
    next_report=$((SECONDS + PROGRESS_EVERY_SECONDS))
  fi
done < "$TODO"

# Wait for the requests still in flight.  `wait` returns early when a signal
# arrives, so keep waiting until every worker has finished.
while [[ -n "$(jobs -rp)" ]]; do
  wait
done
check_outage
finish
