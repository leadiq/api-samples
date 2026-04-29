/**
 * 04_create_prospector_list.ts — Create a Prospector list.
 *
 * Creates a list named "Sales Leaders in New Hampshire" in the LeadIQ
 * Prospector API and saves the result to output/prospector_list.json.
 *
 * What is the Prospector API?
 *   The Prospector API is a REST API — a different style from the GraphQL API
 *   used in the earlier samples. Instead of writing queries, you call specific
 *   URLs (called "endpoints") to create, read, update, or delete things.
 *   Each endpoint has a clear purpose, like "create a list" or "add a person".
 *
 * Authentication note:
 *   The Prospector API uses the same API key as the GraphQL API, but expects
 *   the raw decoded key in an X-API-Key header instead of HTTP Basic Auth.
 *   This script handles the decoding automatically — you do not need to change
 *   anything in your .env file.
 *
 * Run it with:
 *   npx ts-node rest/04_create_prospector_list.ts
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";

// Load LEADIQ_API_KEY from the .env file before reading process.env.
dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

// The base URL for every Prospector API request.
const PROSPECTOR_URL = "https://prospector.leadiq.com";

// Your API key is loaded from the .env file — never hard-code it here.
const API_KEY = process.env.LEADIQ_API_KEY;

// Change LIST_NAME here if you want to create a list with a different name.
const LIST_NAME = "Sales Leaders in New Hampshire - TS";
const LIST_DESCRIPTION =
  "VP, Director, and Manager level Sales professionals in New Hampshire " +
  "— sourced via LeadIQ advanced search.";

// ── Types ─────────────────────────────────────────────────────────────────────

interface ProspectorList {
  id: string;
  name: string;
  description?: string;
  createdAt: string;
  updatedAt: string;
}

interface ErrorBody {
  code: string;
  message: string;
}

// ── Authentication ─────────────────────────────────────────────────────────────

function decodeKey(key: string): string {
  // The .env file stores the "Secret Base64" key — a base64-encoded string.
  // The GraphQL API uses it as-is, but the Prospector API needs the raw
  // decoded version. Buffer.from(key, "base64") reverses the encoding.
  return Buffer.from(key, "base64").toString("utf-8");
}

function prospectorHeaders(): Record<string, string> {
  // "X-API-Key" tells the server who you are (authentication).
  // "Content-Type: application/json" tells the server the body is JSON.
  return {
    "X-API-Key": decodeKey(API_KEY!),
    "Content-Type": "application/json",
  };
}

// ── Helpers ────────────────────────────────────────────────────────────────────

async function createList(
  name: string,
  description: string
): Promise<ProspectorList> {
  // We send an HTTP POST request to /v1/lists.
  // POST is the standard way to "create something new" in a REST API.
  // The request body is a JSON object with the list name and description.
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  let response: Response;
  let result: ProspectorList | ErrorBody;

  try {
    response = await fetch(`${PROSPECTOR_URL}/v1/lists`, {
      method: "POST",
      headers: prospectorHeaders(),
      body: JSON.stringify({ name, description }),
      signal: controller.signal,
    });
    result = (await response.json()) as ProspectorList | ErrorBody;
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      console.error("Error: The API took too long to respond. Please try again.");
    } else {
      console.error("Error: Could not reach the API. Check your internet connection.");
    }
    process.exit(1);
  } finally {
    clearTimeout(timeoutId);
  }

  // HTTP status codes tell us whether the request succeeded.
  // 401 means the server did not recognise our API key.
  if (response.status === 401) {
    console.error("Error: Invalid API key.");
    console.error("Make sure LEADIQ_API_KEY in your .env file is correct.");
    process.exit(1);
  }
  // 409 Conflict means a list with this name already exists.
  if (response.status === 409) {
    console.error(`Error: A list named "${name}" already exists.`);
    console.error("Rename it in LeadIQ or change LIST_NAME in this script.");
    process.exit(1);
  }
  if (!response.ok) {
    console.error(
      `Error ${response.status}: ${(result as ErrorBody).message ?? "Unknown error"}`
    );
    process.exit(1);
  }

  return result as ProspectorList;
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(1);
  }

  process.stdout.write(`Creating list "${LIST_NAME}"... `);
  const createdList = await createList(LIST_NAME, LIST_DESCRIPTION);
  console.log("done.");
  console.log();
  // The API returns the new list's details. The ID is the most important
  // piece — we save it so the next scripts know which list to work with.
  console.log(`  ID         : ${createdList.id}`);
  console.log(`  Name       : ${createdList.name}`);
  console.log(`  Created at : ${createdList.createdAt}`);

  // Save the full list object to a file so the next scripts can read the ID
  // without us having to copy-paste it manually.
  const outputPath = path.join(__dirname, "..", "output", "prospector_list.json");
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(createdList, null, 2));
  console.log(`\nSaved to  : ${outputPath}`);
}

main();
