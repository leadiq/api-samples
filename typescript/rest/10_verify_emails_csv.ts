/**
 * 10_verify_emails_csv.ts — Verify a CSV of email addresses, at any scale.
 *
 * This sample reads email addresses from a CSV file, checks each one with the
 * LeadIQ Prospector API, and writes the verdicts to a results CSV. Like
 * 08_verify_email.ts it is read-only: nothing is created or changed in LeadIQ.
 *
 * It is built for large files (hundreds of thousands of rows):
 *
 *   • Parallel   — several requests run at once, under a shared rate cap.
 *   • Resumable  — every verdict is written to disk the moment it arrives. If
 *                  the run stops for any reason (Ctrl+C, the terminal closing,
 *                  a crash, a network outage, running out of credits), run the
 *                  same command again and it picks up where it left off.
 *   • Retries    — rate limits (429) and temporary errors (5xx, timeouts) are
 *                  retried with a growing pause before giving up on an address.
 *   • Thrifty    — duplicate addresses are checked once, and addresses that are
 *                  obviously malformed are skipped without calling the API.
 *
 * The verdict is one of four values:
 *   Verified        — the mailbox exists and accepts mail
 *   VerifiedLikely  — the address is very likely deliverable
 *   Unverified      — the address could not be confirmed either way
 *   Invalid         — the address will bounce; do not send to it
 *
 * Two files are written to the output/ folder, named after the input file:
 *   <name>_results.csv — email,status   (one row per verified address)
 *   <name>_errors.csv  — email,error    (addresses that could not be checked)
 *
 * Run the script again to retry the addresses in the errors file — addresses
 * already in the results file are never checked (or charged) twice.
 *
 * IMPORTANT: Each address checked costs 0.1 credit — 100,000 addresses cost
 * 10,000 credits. The script shows the maximum cost and asks before starting.
 *
 * Run it with:
 *   npm run 10 -- path/to/emails.csv
 *
 * Options:
 *   --column NAME   the column holding the addresses (default: auto-detect
 *                   "email", "work_email", "workEmail" or "email_address")
 *   --workers N     how many requests to run at once (default: 10)
 *   --per-minute N  the most requests to start per minute (default: 60)
 *   --yes           skip the cost confirmation (for unattended runs)
 *
 * Exit codes (useful when a scheduler or wrapper script runs this):
 *   0  finished — every address is in the results or errors file
 *   1  stopped by a problem you need to fix (invalid key, out of credits)
 *   3  stopped early (interrupted, or the API stopped answering) —
 *      run the same command again to continue
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";
import readline from "readline/promises";
import { parseArgs } from "util";

dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

const PROSPECTOR_URL = "https://prospector.leadiq.com";
const API_KEY = process.env.LEADIQ_API_KEY;

// Where the results and errors files are written.
const OUTPUT_DIR = path.join(__dirname, "..", "output");

// Column names we look for when --column is not given (compared case-insensitively).
const EMAIL_COLUMNS = ["email", "work_email", "workemail", "email_address"];

// The most requests we start per minute, across all workers combined — set it
// to your API key's rate limit. The Prospector API reports its limit in every
// response (the "ratelimit-policy" header); the standard limit is 60 requests
// per minute, so 100,000 addresses take about 28 hours. If the API answers
// 429 (Too Many Requests) anyway, every worker pauses, so a cap that is too
// high costs time, not credits.
const DEFAULT_PER_MINUTE = 60;

// How many requests can be in flight at once. Some checks take several
// seconds (the verifier talks to the recipient's mail server), so to reach the
// per-minute cap you need roughly:  workers ≥ (per-minute ÷ 60) × seconds per
// check. 60/min with checks of up to 10 s needs 10. Raising this never
// exceeds the per-minute cap.
const DEFAULT_WORKERS = 10;

// How long to wait for one answer. Live mail-server checks can be slow.
const REQUEST_TIMEOUT_MS = 60_000;

// How many times to retry an address after a rate limit or temporary error,
// and the first pause between attempts (it doubles each time: 2s, 4s, 8s ...).
const MAX_RETRIES = 5;
const FIRST_BACKOFF_MS = 2000;

// If this many addresses in a row fail even after their retries, AND the API
// has not answered any address for OUTAGE_AFTER_MS, the API (or your network)
// is down. Stop instead of marking every remaining address as an error — the
// run can be resumed once things are back. (Both conditions are needed: a
// handful of addresses can fail on their own — some mail servers never
// answer the verifier — without anything being down.)
const MAX_FAILURES_IN_A_ROW = 10;
const OUTAGE_AFTER_MS = 300_000;

// How often to print a progress line, and how often to force the results to
// the physical disk (so they survive even a power cut).
const PROGRESS_EVERY_MS = 10_000;
const SYNC_TO_DISK_EVERY_MS = 5000;

const STATUSES = ["Verified", "VerifiedLikely", "Unverified", "Invalid"] as const;
type EmailStatus = (typeof STATUSES)[number];

// A deliberately loose shape check: something@something.something, with no
// spaces, commas or quotes. The API does the real validation — this only
// catches cells that are clearly not an address (blank cells, names, phone
// numbers) so they don't cost a call.
const EMAIL_SHAPE = /^[^@\s,"]+@[^@\s,"]+\.[^@\s,"]+$/;

// Exit codes — see the top of the file.
const EXIT_NEEDS_FIX = 1;
const EXIT_STOPPED_EARLY = 3;

// ── Authentication ─────────────────────────────────────────────────────────────

function decodeKey(key: string): string {
  // The Prospector API needs the raw decoded version of the base64 API key.
  return Buffer.from(key, "base64").toString("utf-8");
}

// ── Stopping ──────────────────────────────────────────────────────────────────

// One AbortController for the whole run. Aborting it makes every worker stop
// picking up new addresses and cuts short any pause they are sleeping through.
// Requests already sent are left to finish — they are paid for.
const stopController = new AbortController();
const stopSignal = stopController.signal;

type StopKind = "fatal" | "outage" | "interrupted";
let stoppedBy: { kind: StopKind; message?: string } | null = null;

function stopRun(kind: StopKind, message?: string): void {
  stoppedBy ??= { kind, message };
  stopController.abort();
}

// Sleep for `ms`, but wake up early if the run is stopping.
// Resolves to true if it was woken by a stop.
function sleepUnlessStopped(ms: number): Promise<boolean> {
  return new Promise((resolve) => {
    if (stopSignal.aborted) return resolve(true);
    const onStop = () => {
      clearTimeout(timer);
      resolve(true);
    };
    const timer = setTimeout(() => {
      stopSignal.removeEventListener("abort", onStop);
      resolve(false);
    }, ms);
    stopSignal.addEventListener("abort", onStop, { once: true });
  });
}

// ── Rate limiting ─────────────────────────────────────────────────────────────

class RateLimiter {
  // Hands out "start" slots no faster than `perMinute`, shared by all
  // workers. `pause()` pushes the next slot into the future — we call it when
  // the API says 429, so every worker backs off together. `throttled` counts
  // those 429s, so the progress line can show them: a steady stream of 429s
  // means --per-minute is higher than your limit.
  throttled = 0;
  private nextSlot = Date.now();
  private readonly intervalMs: number;

  constructor(perMinute: number) {
    this.intervalMs = 60_000 / perMinute;
  }

  async wait(): Promise<void> {
    const slot = Math.max(Date.now(), this.nextSlot);
    this.nextSlot = slot + this.intervalMs;
    await sleepUnlessStopped(slot - Date.now());
  }

  pause(ms: number): void {
    this.throttled++;
    this.nextSlot = Math.max(this.nextSlot, Date.now() + ms);
  }
}

// ── API call ──────────────────────────────────────────────────────────────────

class FatalError extends Error {}

type Outcome =
  | { kind: "verdict"; status: EmailStatus } // the API answered
  | { kind: "rejected"; reason: string } // the API refused this address; retrying won't help
  | { kind: "failed"; reason: string } // temporary errors on every attempt; worth a rerun
  | { kind: "abandoned" }; // the run is stopping; the address was not finished

function retryAfterMs(response: Response | null, attempt: number): number {
  // How long to wait before trying again. Prefer the server's own hints:
  //   Retry-After: 30                              — seconds to wait
  //   ratelimit: limit=60, remaining=0, reset=30   — seconds until the
  //                                                  rate-limit window resets
  // Otherwise back off exponentially, with a little randomness so workers
  // don't all retry at the same moment.
  const retryAfter = response?.headers.get("Retry-After");
  if (retryAfter && /^\d+$/.test(retryAfter)) return Number(retryAfter) * 1000;
  const reset = response?.headers.get("ratelimit")?.match(/reset=(\d+)/);
  if (reset) return Number(reset[1]) * 1000 + Math.random() * 1000;
  return FIRST_BACKOFF_MS * 2 ** attempt + Math.random() * 1000;
}

async function messageOf(response: Response): Promise<string> {
  const text = await response.text().catch(() => "");
  try {
    return (JSON.parse(text) as { message?: string }).message ?? "Unknown error";
  } catch {
    return text.slice(0, 200) || "Unknown error";
  }
}

async function verifyEmail(email: string, limiter: RateLimiter): Promise<Outcome> {
  // Sends GET /v1/verify-email?email=... — throws FatalError for problems
  // that affect every address (bad key, no credits).
  const headers = {
    "X-API-Key": decodeKey(API_KEY!),
    "Content-Type": "application/json",
  };
  const url = new URL(`${PROSPECTOR_URL}/v1/verify-email`);
  url.searchParams.set("email", email);

  let reason = "";
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    await limiter.wait();
    if (stopSignal.aborted) return { kind: "abandoned" };

    let response: Response | null = null;
    try {
      // Note: no stop signal on the request itself — once sent, it is paid
      // for, so we let it finish and save the answer.
      response = await fetch(url, {
        headers,
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
      const code = response.status;
      if (code === 200) {
        const body = (await response.json()) as { status: EmailStatus };
        return { kind: "verdict", status: body.status };
      }
      if (code === 400) return { kind: "rejected", reason: "malformed email" };
      if (code === 401) {
        throw new FatalError("Invalid API key — check LEADIQ_API_KEY in your .env file.");
      }
      if (code === 402) throw new FatalError(`Out of credits (402): ${await messageOf(response)}`);
      if (code === 403) throw new FatalError(`Access denied (403): ${await messageOf(response)}`);
      if (code === 429) {
        // Rate limited: pause *every* worker through the shared limiter, then
        // try this address again. No extra sleep here — the next
        // limiter.wait() does the waiting.
        limiter.pause(retryAfterMs(response, attempt));
        reason = "rate limited (429)";
        continue;
      }
      if (code < 500) {
        return { kind: "rejected", reason: `error ${code}: ${await messageOf(response)}` };
      }
      reason = `server error (${code})`;
    } catch (err) {
      if (err instanceof FatalError) throw err;
      reason = err instanceof Error && err.name === "TimeoutError" ? "timeout" : "connection error";
    }

    if (attempt < MAX_RETRIES && (await sleepUnlessStopped(retryAfterMs(response, attempt)))) {
      return { kind: "abandoned" };
    }
  }
  return { kind: "failed", reason: `${reason} after ${MAX_RETRIES + 1} attempts` };
}

// ── CSV ───────────────────────────────────────────────────────────────────────

// Splits CSV text into rows of fields. Handles quoted fields ("Smith, Jane"
// and "say ""hi"""), line breaks inside quotes, and Windows line endings.
function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQuotes) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i++;
      } else if (c === '"') {
        inQuotes = false;
      } else {
        field += c;
      }
    } else if (c === '"') {
      inQuotes = true;
    } else if (c === ",") {
      row.push(field);
      field = "";
    } else if (c === "\n" || c === "\r") {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = "";
    } else {
      field += c;
    }
  }
  if (field !== "" || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

// Returns the unique addresses in the CSV, in file order. Addresses are
// compared case-insensitively, so "Jane@Acme.com" and "jane@acme.com" are
// checked (and charged) once.
function readEmails(file: string, column: string | undefined) {
  // Drop the byte-order mark Excel adds to the start of CSV exports.
  const text = fs.readFileSync(file, "utf-8").replace(/^﻿/, "");
  const [header = [], ...rows] = parseCsv(text);
  const headers = header.map((h) => h.trim());

  const index =
    column !== undefined
      ? headers.indexOf(column)
      : headers.findIndex((h) => EMAIL_COLUMNS.includes(h.toLowerCase()));
  if (index === -1) {
    console.error(`Error: No email column found in ${file}.`);
    console.error(`  Columns in the file: ${headers.join(", ") || "(none)"}`);
    console.error("  Pass the right one with --column NAME.");
    process.exit(EXIT_NEEDS_FIX);
  }

  const seen = new Set<string>();
  const emails: string[] = [];
  for (const row of rows) {
    const email = (row[index] ?? "").trim();
    const key = email.toLowerCase();
    if (!seen.has(key)) {
      seen.add(key);
      emails.push(email);
    }
  }
  return { emails, rows: rows.length, column: headers[index] };
}

// Addresses already in the results file from an earlier run. A row only
// counts if its status is one of the four verdicts — if a previous run was
// killed halfway through writing a line, that cut-off line is ignored and the
// address is simply checked again.
// Addresses the previous run could not check (its errors file). They are
// retried at the END of this run: an address that failed before often fails
// again, slowly, and if a few of them came first they could keep every worker
// busy while thousands of healthy addresses wait.
function readFailed(errorsPath: string): Set<string> {
  if (!fs.existsSync(errorsPath)) return new Set();
  const [, ...rows] = parseCsv(fs.readFileSync(errorsPath, "utf-8"));
  return new Set(rows.filter(([email]) => email).map(([email]) => email.trim().toLowerCase()));
}

function readDone(resultsPath: string): Set<string> {
  if (!fs.existsSync(resultsPath)) return new Set();
  const [, ...rows] = parseCsv(fs.readFileSync(resultsPath, "utf-8"));
  return new Set(
    rows
      .filter(([email, status]) => email && STATUSES.includes(status as EmailStatus))
      .map(([email]) => email.trim().toLowerCase()),
  );
}

// Quote a CSV field only when it needs it.
function csvField(value: string): string {
  return /[",\r\n]/.test(value) ? `"${value.replace(/"/g, '""')}"` : value;
}

class CsvAppender {
  // A CSV file every worker appends to. Each row is written straight to the
  // operating system (no buffering in this program), so it survives this
  // program being killed; every few seconds the file is also forced to the
  // physical disk, so it survives a power cut too.
  private fd: number;
  private lastSync = Date.now();

  constructor(file: string, header: string[], mode: "w" | "a") {
    const exists = fs.existsSync(file) && fs.statSync(file).size > 0;
    const newFile = mode === "w" || !exists;
    if (!newFile) endWithNewline(file);
    this.fd = fs.openSync(file, mode);
    if (newFile) this.write(header);
  }

  write(row: string[]): void {
    if (this.fd < 0) return; // quitting on a second Ctrl+C
    fs.writeSync(this.fd, row.map(csvField).join(",") + "\n");
    if (Date.now() - this.lastSync >= SYNC_TO_DISK_EVERY_MS) {
      fs.fsyncSync(this.fd);
      this.lastSync = Date.now();
    }
  }

  close(): void {
    if (this.fd < 0) return;
    fs.fsyncSync(this.fd);
    fs.closeSync(this.fd);
    this.fd = -1;
  }
}

// If an earlier run was killed in the middle of writing a row, the file ends
// with half a line. Finish that line so the next row we append starts on a
// fresh one instead of being glued onto the broken one.
function endWithNewline(file: string): void {
  const fd = fs.openSync(file, "r+");
  const last = Buffer.alloc(1);
  fs.readSync(fd, last, 0, 1, fs.fstatSync(fd).size - 1);
  if (last.toString() !== "\n") fs.writeSync(fd, "\n", fs.fstatSync(fd).size);
  fs.closeSync(fd);
}

// Two runs on the same file would check (and charge) the same addresses
// twice, so only one run at a time may work on it. The lock file holds the
// process ID of the run that owns it; if that process is gone (it crashed or
// was killed), the lock is stale and we take it over.
function takeLock(lockPath: string, input: string): void {
  try {
    fs.writeFileSync(lockPath, String(process.pid), { flag: "wx" });
  } catch {
    const owner = Number(fs.readFileSync(lockPath, "utf-8").trim());
    if (owner && processAlive(owner)) {
      console.error(`Error: Another run (process ${owner}) is already working on ${input}.`);
      console.error("  Wait for it to finish or stop it first — two runs would pay for the same addresses twice.");
      console.error(`  If you are sure no other run is going, delete ${lockPath}`);
      process.exit(EXIT_NEEDS_FIX);
    }
    fs.writeFileSync(lockPath, String(process.pid));
  }
  process.on("exit", () => {
    try {
      if (fs.readFileSync(lockPath, "utf-8").trim() === String(process.pid)) fs.unlinkSync(lockPath);
    } catch {
      // already gone
    }
  });
}

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0); // signal 0 checks the process exists without touching it
    return true;
  } catch (err) {
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const { values: args, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      column: { type: "string" },
      workers: { type: "string", default: String(DEFAULT_WORKERS) },
      "per-minute": { type: "string", default: String(DEFAULT_PER_MINUTE) },
      yes: { type: "boolean", default: false },
    },
  });
  const input = positionals[0];
  const workers = Number(args.workers);
  const perMinute = Number(args["per-minute"]);

  if (!input) {
    console.error("Usage: npm run 10 -- path/to/emails.csv [--column NAME] [--workers N] [--per-minute N] [--yes]");
    process.exit(EXIT_NEEDS_FIX);
  }
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(EXIT_NEEDS_FIX);
  }
  if (!fs.existsSync(input)) {
    console.error(`Error: File not found: ${input}`);
    process.exit(EXIT_NEEDS_FIX);
  }

  const name = path.parse(input).name;
  const resultsPath = path.join(OUTPUT_DIR, `${name}_results.csv`);
  const errorsPath = path.join(OUTPUT_DIR, `${name}_errors.csv`);

  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  takeLock(path.join(OUTPUT_DIR, `${name}.lock`), input);

  const { emails, rows, column } = readEmails(input, args.column);
  const done = readDone(resultsPath);
  const failedBefore = readFailed(errorsPath);

  // Split the unique addresses into: already done, malformed, and to check.
  const notDone = emails.filter((e) => !done.has(e.toLowerCase()));
  const malformed = notDone.filter((e) => !EMAIL_SHAPE.test(e));
  const valid = notDone.filter((e) => EMAIL_SHAPE.test(e));
  const retry = valid.filter((e) => failedBefore.has(e.toLowerCase()));
  const todo = [...valid.filter((e) => !failedBefore.has(e.toLowerCase())), ...retry];

  const n = (x: number) => x.toLocaleString("en-US");
  const maxCredits = (todo.length * 0.1).toLocaleString("en-US", { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  console.log(`Input          : ${input} (${n(rows)} rows, column '${column}')`);
  console.log(`Unique emails  : ${n(emails.length)}`);
  console.log(`Already done   : ${n(emails.length - notDone.length)} (in ${resultsPath})`);
  console.log(`Malformed      : ${n(malformed.length)} (skipped, no credit used)`);
  if (retry.length) console.log(`Retried last   : ${n(retry.length)} (could not be checked in an earlier run)`);
  console.log(`To check       : ${n(todo.length)}`);
  console.log(`Max credits    : ${maxCredits}`);
  console.log(`Est. time      : ~${(todo.length / perMinute / 60).toFixed(1)} h at ${perMinute} requests/min`);
  console.log();

  if (todo.length > 0 && !args.yes) {
    if (!process.stdin.isTTY) {
      console.error("Refusing to spend credits without confirmation — pass --yes to run unattended.");
      process.exit(EXIT_NEEDS_FIX);
    }
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    const answer = (await rl.question(`Spend up to ${maxCredits} credits? [y/N] `)).trim().toLowerCase();
    rl.close();
    if (answer !== "y") {
      console.log("Cancelled.");
      return;
    }
  }

  // The errors file is rewritten on every run: it lists what is still left to
  // retry, not the history of everything that ever failed. (Only once the run
  // is confirmed — a cancelled run must not lose that list.)
  const errors = new CsvAppender(errorsPath, ["email", "error"], "w");
  for (const email of malformed) errors.write([email, email ? "malformed email" : "blank email"]);

  if (todo.length === 0) {
    errors.close();
    console.log("Nothing left to check.");
    return;
  }

  const results = new CsvAppender(resultsPath, ["email", "status"], "a");

  // ── Workers ─────────────────────────────────────────────────────────────────
  // Each worker takes the next address from the shared list until it is used
  // up, or until the run is stopping: by Ctrl+C, by a fatal error like an
  // invalid key, or by too many failures in a row. (Node runs one piece of
  // JavaScript at a time, so the shared counters below need no locks.)

  const limiter = new RateLimiter(perMinute);
  const counts: Record<EmailStatus | "errors", number> = {
    Verified: 0,
    VerifiedLikely: 0,
    Unverified: 0,
    Invalid: 0,
    errors: 0,
  };
  let next = 0;
  let failuresInARow = 0;
  let lastAnswer = Date.now(); // when the API last gave any address an answer

  async function worker(): Promise<void> {
    while (!stopSignal.aborted && next < todo.length) {
      const email = todo[next++];
      let outcome: Outcome;
      try {
        outcome = await verifyEmail(email, limiter);
      } catch (err) {
        stopRun("fatal", (err as Error).message);
        return;
      }
      if (outcome.kind === "abandoned") return; // not written anywhere, so the next run checks it again

      if (outcome.kind === "verdict") {
        results.write([email, outcome.status]);
        counts[outcome.status]++;
      } else {
        errors.write([email, outcome.reason]);
        counts.errors++;
      }

      if (outcome.kind !== "failed") {
        failuresInARow = 0;
        lastAnswer = Date.now();
      } else if (++failuresInARow >= MAX_FAILURES_IN_A_ROW && Date.now() - lastAnswer >= OUTAGE_AFTER_MS) {
        stopRun(
          "outage",
          `${failuresInARow} addresses in a row failed after retries and no answer for ` +
            `${OUTAGE_AFTER_MS / 60_000} minutes (last: ${outcome.reason}) — the API or your network looks down.`,
        );
      }
    }
  }

  const started = Date.now();
  function progress(): void {
    const finished = Object.values(counts).reduce((a, b) => a + b, 0);
    const minutes = (Date.now() - started) / 60_000;
    const rate = minutes > 0 ? finished / minutes : 0;
    const eta = rate > 0 ? `${((todo.length - finished) / rate / 60).toFixed(1)} h` : "?";
    const buckets = STATUSES.map((s) => `${s}=${n(counts[s])}`).join("  ");
    console.log(
      `[${n(finished)}/${n(todo.length)}] ${rate.toFixed(0)}/min  ETA ${eta}  ${buckets}  ` +
        `errors=${n(counts.errors)}  429s=${n(limiter.throttled)}`,
    );
  }

  function summaryAndExit(): never {
    results.close();
    errors.close();

    console.log();
    progress();
    console.log();
    for (const status of STATUSES) console.log(`${status.padEnd(15)}: ${n(counts[status])}`);
    console.log(`${"Errors".padEnd(15)}: ${n(counts.errors)}`);
    console.log(`${"Rate limited".padEnd(15)}: ${n(limiter.throttled)} (429 responses, each one retried)`);
    console.log(`${"Results".padEnd(15)}: ${resultsPath}`);
    console.log(`${"Errors file".padEnd(15)}: ${errorsPath}`);

    if (stoppedBy?.kind === "fatal") {
      console.log();
      console.log(`Error: ${stoppedBy.message}`);
      console.log("Your results so far are saved — fix the problem, then run the same command again.");
      process.exit(EXIT_NEEDS_FIX);
    }
    if (stoppedBy) {
      console.log();
      if (stoppedBy.message) console.log(`Stopped: ${stoppedBy.message}`);
      console.log("Stopped early — your results so far are saved. Run the same command again to continue.");
      process.exit(EXIT_STOPPED_EARLY);
    }
    if (counts.errors) {
      console.log();
      console.log("Some addresses could not be checked — run the same command again to retry them.");
    }
    process.exit(0);
  }

  // Ctrl+C (SIGINT), `kill` (SIGTERM) and a closed terminal window (SIGHUP)
  // all take the same careful path. The first one stops new requests and
  // lets the ones in flight finish — they are already paid for. A second one
  // quits right away; everything written so far is already on disk, and
  // answers still in flight are simply checked again next run.
  let interrupted = false;
  const onSignal = () => {
    if (interrupted) {
      console.log("\nQuitting now.");
      summaryAndExit();
    }
    interrupted = true;
    stopRun("interrupted");
    console.log("\nStopping — saving the requests already in flight (press Ctrl+C again to quit now)...");
  };
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(sig, onSignal);

  // `npm run` and `tsx` start this script as a child process. If that parent
  // is killed outright, no signal reaches us — so check once a second that
  // it is still there, and stop the same way as Ctrl+C if it is not.
  const parentPid = process.ppid;
  setInterval(() => {
    if (process.ppid !== parentPid && !interrupted) onSignal();
  }, 1000).unref();

  const timer = setInterval(progress, PROGRESS_EVERY_MS);
  await Promise.all(Array.from({ length: workers }, worker));
  clearInterval(timer);
  summaryAndExit();
}

main();
