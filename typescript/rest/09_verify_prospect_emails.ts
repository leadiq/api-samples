/**
 * 09_verify_prospect_emails.ts — Re-verify the emails of saved prospects.
 *
 * This sample reads output/added_prospects.json (written by
 * 05_add_prospects_to_list.ts) and asks the LeadIQ Prospector API to verify
 * the work email stored on each prospect. The new verdict is saved on the
 * prospect in LeadIQ, so the email status you see in the app stays up to date.
 *
 * The prospect's email address itself is NEVER changed — this checks the
 * address that is already there, it does not look for a new one. Prospects
 * without an email are skipped.
 *
 * The verdict is one of four values:
 *   Verified        — the mailbox exists and accepts mail
 *   VerifiedLikely  — the address is very likely deliverable
 *   Unverified      — the address could not be confirmed either way
 *   Invalid         — the address will bounce; do not send to it
 *
 * IMPORTANT: Each prospect verified costs 0.1 credit.
 * MAX_PROSPECTS below controls how many prospects are processed in one run.
 *
 * Run it with:
 *   npm run 09
 *
 * Or pass specific prospect IDs on the command line:
 *   npm run 09 -- 6627e3f1a2b3c4d5e6f70001
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";

dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

const PROSPECTOR_URL = "https://prospector.leadiq.com";
const API_KEY = process.env.LEADIQ_API_KEY;

// Path to the prospects written by 05_add_prospects_to_list.ts.
const PROSPECTS_PATH = path.join(
  __dirname,
  "..",
  "output",
  "added_prospects.json"
);

// Where to save the verdicts and updated prospect records.
const OUTPUT_PATH = path.join(
  __dirname,
  "..",
  "output",
  "verified_prospects.json"
);

// Safety cap on how many prospects to verify in one run (each costs 0.1 credit).
const MAX_PROSPECTS = 10;

// How long to pause between each API call (in milliseconds).
// A short pause prevents sending requests too quickly and hitting rate limits.
const DELAY_MS = 500;

// ── Types ─────────────────────────────────────────────────────────────────────

type EmailStatus = "Verified" | "VerifiedLikely" | "Unverified" | "Invalid";

interface Prospect {
  id: string;
  name?: string;
  workEmail?: string;
  emailStatus?: string;
}

interface VerifyEmailResponse {
  status: EmailStatus;
  prospect: Prospect;
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

async function verifyProspectEmail(
  prospectId: string
): Promise<VerifyEmailResponse | string> {
  // We send a POST request to /v1/prospects/{prospectId}/verify-email.
  // POST is used (rather than GET) because this call changes data: the new
  // email status is saved on the prospect. No request body is needed — the
  // API verifies whatever email is already stored on the prospect.
  //
  // The API returns:
  //   status   — Verified, VerifiedLikely, Unverified, or Invalid
  //   prospect — the full prospect record, with emailStatus already updated
  //
  // On failure this function returns a short reason string instead.
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  try {
    const response = await fetch(
      `${PROSPECTOR_URL}/v1/prospects/${prospectId}/verify-email`,
      {
        method: "POST",
        headers: prospectorHeaders(),
        signal: controller.signal,
      }
    );
    const result = (await response.json()) as VerifyEmailResponse & {
      message?: string;
    };

    // 401 means our API key is wrong — no point continuing.
    if (response.status === 401) {
      console.error("\nError: Invalid API key.");
      console.error("Make sure LEADIQ_API_KEY in your .env file is correct.");
      process.exit(1);
    }
    // 404 means the prospect was deleted or belongs to another account.
    if (response.status === 404) return "prospect not found";
    // 409 means the prospect has no email on record, so there is nothing to verify.
    if (response.status === 409) return "no email to verify";
    // 502 means the email verification service is temporarily unreachable.
    if (response.status === 502) return "verification service unavailable";
    if (!response.ok) {
      return `error ${response.status}: ${result.message ?? "Unknown error"}`;
    }

    return result;
  } catch (err) {
    return err instanceof Error && err.name === "AbortError"
      ? "timeout"
      : "connection error";
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

  let prospects: Prospect[];
  const cliIds = process.argv.slice(2);

  if (cliIds.length > 0) {
    // Prospect IDs were passed on the command line — we don't know their
    // names or emails yet, so the API response will fill those in.
    prospects = cliIds.map((id) => ({ id }));
  } else {
    if (!fs.existsSync(PROSPECTS_PATH)) {
      console.error(`Error: Prospects file not found: ${PROSPECTS_PATH}`);
      console.error(
        "Run 05_add_prospects_to_list.ts first, or pass prospect IDs on the command line."
      );
      process.exit(1);
    }

    const saved: Prospect[] = JSON.parse(
      fs.readFileSync(PROSPECTS_PATH, "utf-8")
    );

    // Skip prospects without an email before calling the API — the API
    // would reject them with a 409 anyway.
    prospects = saved.filter((p) => p.workEmail);

    if (prospects.length === 0) {
      console.error(
        "Error: None of the prospects in the file have a work email to verify."
      );
      process.exit(1);
    }
  }

  // Slice the list so we only process up to MAX_PROSPECTS entries.
  prospects = prospects.slice(0, MAX_PROSPECTS);
  const total = prospects.length;

  console.log(`Prospects  : ${total} (MAX_PROSPECTS=${MAX_PROSPECTS})`);
  console.log(`Max credits: ${(total * 0.1).toFixed(1)}`);
  console.log();

  const verified: { status: EmailStatus; prospect: Prospect }[] = [];
  let skipped = 0;

  for (let i = 0; i < prospects.length; i++) {
    const prospect = prospects[i];
    process.stdout.write(`[${i + 1}/${total}] ${prospect.name || prospect.id} ... `);

    const result = await verifyProspectEmail(prospect.id);

    if (typeof result === "string") {
      console.log(`skipped (${result})`);
      skipped++;
    } else {
      // Show the status before and after so it is clear what changed.
      const before = prospect.emailStatus || "—";
      console.log(`${result.prospect.workEmail}  ${before} → ${result.status}`);
      verified.push({ status: result.status, prospect: result.prospect });
    }

    // Wait a moment before the next call to stay within rate limits.
    if (i < prospects.length - 1) await sleep(DELAY_MS);
  }

  console.log();
  console.log(`Verified : ${verified.length}`);
  console.log(`Skipped  : ${skipped}`);

  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, JSON.stringify(verified, null, 2));
  console.log(`Saved to : ${OUTPUT_PATH}`);
}

main();
