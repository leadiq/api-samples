/**
 * 08_verify_email.ts — Verify any email address without saving anything.
 *
 * This sample sends one or more email addresses to the LeadIQ Prospector API
 * and prints a deliverability verdict for each one. Nothing is created or
 * changed in LeadIQ — it is a read-only "pre-flight" check you can run before
 * adding someone as a prospect.
 *
 * The verdict is one of four values:
 *   Verified        — the mailbox exists and accepts mail
 *   VerifiedLikely  — the address is very likely deliverable
 *   Unverified      — the address could not be confirmed either way
 *   Invalid         — the address will bounce; do not send to it
 *
 * This sample is standalone — it does not need the output of any earlier script.
 *
 * IMPORTANT: Each address checked costs 0.1 credit.
 *
 * Run it with:
 *   npm run 08
 *
 * Or pass the addresses to check on the command line:
 *   npm run 08 -- jane@acme.com john@example.com
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";

dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

const PROSPECTOR_URL = "https://prospector.leadiq.com";
const API_KEY = process.env.LEADIQ_API_KEY;

// The addresses to verify when none are passed on the command line.
// Replace these with the emails you want to check.
const EMAILS_TO_VERIFY = ["someone@example.com"];

// Where to save the verdicts.
const OUTPUT_PATH = path.join(__dirname, "..", "output", "verified_emails.json");

// How long to pause between each API call (in milliseconds).
// A short pause prevents sending requests too quickly and hitting rate limits.
const DELAY_MS = 500;

// ── Types ─────────────────────────────────────────────────────────────────────

const STATUSES = ["Verified", "VerifiedLikely", "Unverified", "Invalid"] as const;
type EmailStatus = (typeof STATUSES)[number];

interface VerifyEmailResponse {
  status: EmailStatus;
}

interface VerifyResult {
  email: string;
  status: EmailStatus | null;
  error?: string;
}

// ── Authentication ─────────────────────────────────────────────────────────────

function decodeKey(key: string): string {
  // The Prospector API needs the raw decoded version of the base64 API key.
  return Buffer.from(key, "base64").toString("utf-8");
}

function prospectorHeaders(): Record<string, string> {
  return {
    "X-API-Key": decodeKey(API_KEY!),
    "Content-Type": "application/json",
  };
}

// ── Helpers ────────────────────────────────────────────────────────────────────

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

async function verifyEmail(email: string): Promise<VerifyResult> {
  // We send a GET request to /v1/verify-email?email=...
  // GET is used because this call only reads a verdict — it never changes
  // anything on the server.
  //
  // The API returns a single field:
  //   status — Verified, VerifiedLikely, Unverified, or Invalid
  const url = new URL(`${PROSPECTOR_URL}/v1/verify-email`);
  url.searchParams.set("email", email);

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  try {
    const response = await fetch(url.toString(), {
      headers: prospectorHeaders(),
      signal: controller.signal,
    });
    const result = (await response.json()) as VerifyEmailResponse & {
      message?: string;
    };

    // 401 means our API key is wrong — no point continuing.
    if (response.status === 401) {
      console.error("\nError: Invalid API key.");
      console.error("Make sure LEADIQ_API_KEY in your .env file is correct.");
      process.exit(1);
    }
    // 400 means the address is malformed (e.g. missing the @ sign).
    if (response.status === 400) {
      return { email, status: null, error: "malformed email" };
    }
    // 502 means the email verification service is temporarily unreachable.
    if (response.status === 502) {
      return { email, status: null, error: "verification service unavailable" };
    }
    if (!response.ok) {
      return {
        email,
        status: null,
        error: `error ${response.status}: ${result.message ?? "Unknown error"}`,
      };
    }

    return { email, status: result.status };
  } catch (err) {
    const error =
      err instanceof Error && err.name === "AbortError"
        ? "timeout"
        : "connection error";
    return { email, status: null, error };
  } finally {
    clearTimeout(timeoutId);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(1);
  }

  // Use the addresses from the command line if any were given, otherwise
  // fall back to the EMAILS_TO_VERIFY list above.
  const cliEmails = process.argv.slice(2);
  const emails = cliEmails.length > 0 ? cliEmails : EMAILS_TO_VERIFY;
  const total = emails.length;

  console.log(`Emails     : ${total}`);
  console.log(`Max credits: ${(total * 0.1).toFixed(1)}`);
  console.log();

  const results: VerifyResult[] = [];

  for (let i = 0; i < emails.length; i++) {
    process.stdout.write(`[${i + 1}/${total}] ${emails[i]} ... `);

    const result = await verifyEmail(emails[i]);
    console.log(result.status ?? `skipped (${result.error})`);
    results.push(result);

    // Wait a moment before the next call to stay within rate limits.
    if (i < emails.length - 1) await sleep(DELAY_MS);
  }

  // Count how many addresses landed in each verdict bucket.
  console.log();
  for (const status of STATUSES) {
    const count = results.filter((r) => r.status === status).length;
    console.log(`${status.padEnd(15)}: ${count}`);
  }
  const skipped = results.filter((r) => r.status === null).length;
  console.log(`${"Skipped".padEnd(15)}: ${skipped}`);

  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(results, null, 2));
  console.log(`Saved to       : ${OUTPUT_PATH}`);
}

main();
