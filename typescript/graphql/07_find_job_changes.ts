/**
 * 07_find_job_changes.ts — Find people who recently changed jobs or were promoted.
 *
 * This sample uses the same `flatAdvancedSearch` query as 02_advanced_search.ts,
 * but adds the job-change filters so the results are scoped to people who recently
 * moved companies (or were promoted in place). For each match it prints the
 * job-change transition: previous position → current position.
 *
 * Job changes are a strong buying trigger — a champion who just moved into a new
 * role is often the best time to reach out.
 *
 * IMPORTANT: Each page of results consumes one "Advanced Search (Page)" credit,
 * exactly like 02_advanced_search.ts. This sample requests profile-level fields
 * only (no company firmographic unlock), so it stays at the cheapest tier.
 *
 * Run it with:
 *   npx tsx graphql/07_find_job_changes.ts
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";

// Load the LEADIQ_API_KEY from the .env file in the typescript/ folder.
dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

const GRAPHQL_URL = "https://api.leadiq.com/graphql";

const API_KEY = process.env.LEADIQ_API_KEY;

// How many results to fetch per API call.
// Each call counts as one credit regardless of page size.
const PAGE_SIZE = 25;

// Safety cap on the total number of people to collect across all pages.
const MAX_PEOPLE = 50;

// ── Search filters ─────────────────────────────────────────────────────────────

// Which kind of change to look for:
//   "JobChange"   — the person MOVED to a different company
//   "TitleChange" — the person was PROMOTED in place (same company, new title)
// Use both (or an empty list) to include either kind.
const JOB_CHANGE_TYPES = ["JobChange"];

// Optional: only include changes that started after this date.
// Set to null to include changes of any age. The API expects Unix milliseconds.
// Example below: changes that started in the last 90 days.
const STARTED_AFTER_MS: number | null =
  Date.now() - 90 * 24 * 60 * 60 * 1000;

// Filters describing the person's CURRENT role (after the change).
// Here: VPs in Sales who now work at a software company.
const SENIORITIES = ["VP"];
const ROLES = ["Sales"];
const CURRENT_INDUSTRIES = ["Computer Software"];

// ── Types ─────────────────────────────────────────────────────────────────────

interface GraphQLError {
  message: string;
  extensions?: {
    response?: {
      status?: number;
    };
  };
}

interface Company {
  id?: string;
  name?: string;
}

interface Position {
  title?: string;
  role?: string;
  seniority?: string;
  company?: Company | null;
}

interface PersonJobChange {
  jobChangeType?: string;
  startedAt?: string | number;
  previousPosition?: Position | null;
  currentPosition?: Position | null;
}

interface Person {
  id: string;
  name?: string;
  linkedinUrl?: string;
  personJobChange?: PersonJobChange | null;
}

interface FindJobChangesData {
  totalPeople: number;
  people: Person[];
}

interface FindJobChangesResponse {
  data?: {
    flatAdvancedSearch: FindJobChangesData;
  };
  errors?: GraphQLError[];
}

// ── Query ──────────────────────────────────────────────────────────────────────

// flatAdvancedSearch is the same field used by 02_advanced_search.ts. The
// difference is the input (which now carries jobChangeFilter) and the selection
// set, which asks for the personJobChange transition.
//
// We request the company `id` and `name` on both positions — these are part of
// the free profile tier. Firmographics (domain, industry, employeeCount) would
// require unlocking the company tier and cost extra, so we leave them out here.
const FIND_JOB_CHANGES_QUERY = `
query FindJobChanges($input: FlatSearchInput!) {
  flatAdvancedSearch(input: $input) {
    totalPeople
    people {
      id
      name
      linkedinUrl
      personJobChange {
        jobChangeType
        startedAt
        previousPosition {
          title
          company {
            id
            name
          }
        }
        currentPosition {
          title
          role
          seniority
          company {
            id
            name
          }
        }
      }
    }
  }
}
`;

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Send one GraphQL request and return the flatAdvancedSearch payload.
 * Exits the process if the network request fails or the API returns an error.
 */
async function callApi(
  headers: Record<string, string>,
  variables: object
): Promise<FindJobChangesData> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  let result: FindJobChangesResponse;
  try {
    const response = await fetch(GRAPHQL_URL, {
      method: "POST",
      headers,
      body: JSON.stringify({ query: FIND_JOB_CHANGES_QUERY, variables }),
      signal: controller.signal,
    });
    result = (await response.json()) as FindJobChangesResponse;
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

  if (result.errors) {
    const error = result.errors[0];
    const status = error.extensions?.response?.status;

    if (status === 401) {
      console.error("Error: Invalid API key.");
      console.error(
        "Make sure LEADIQ_API_KEY in your .env file is the correct Secret Base64 key."
      );
    } else if (status === 402) {
      console.error("Error: Insufficient credits.");
    } else if (status === 429) {
      console.error("Error: Too many requests. Wait a moment and try again.");
    } else {
      console.error(`API error: ${error.message ?? "Unknown error"}`);
    }
    process.exit(1);
  }

  return result.data!.flatAdvancedSearch;
}

/** The API returns startedAt as Unix milliseconds. Render it as YYYY-MM-DD. */
function formatStartedAt(value: string | number | undefined): string {
  if (value === undefined || value === null) return "—";
  const ms = Number(value);
  if (Number.isNaN(ms)) return String(value); // tolerate a date string
  return new Date(ms).toISOString().slice(0, 10);
}

/** Pull the company name out of a position block, tolerating missing data. */
function companyName(position: Position | null | undefined): string {
  return position?.company?.name ?? "—";
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(1);
  }

  const headers = {
    Authorization: `Basic ${API_KEY}`,
    "Content-Type": "application/json",
  };

  console.log("Searching LeadIQ for recent job changes...");
  console.log(`  Change type      : ${JOB_CHANGE_TYPES.join(", ") || "any"}`);
  console.log(`  Current role     : ${ROLES.join(", ")}`);
  console.log(`  Current seniority: ${SENIORITIES.join(", ")}`);
  console.log(`  Current industry : ${CURRENT_INDUSTRIES.join(", ")}`);
  if (STARTED_AFTER_MS !== null) {
    console.log(`  Changed since    : ${formatStartedAt(STARTED_AFTER_MS)}`);
  }
  console.log();

  // Build the job-change filter. jobChangeTypes is required by the API; an
  // empty list means "both JobChange and TitleChange".
  const jobChangeFilter: { jobChangeTypes: string[]; startedAfter?: number } = {
    jobChangeTypes: JOB_CHANGE_TYPES,
  };
  if (STARTED_AFTER_MS !== null) {
    jobChangeFilter.startedAfter = STARTED_AFTER_MS;
  }

  const allPeople: Person[] = [];
  let skip = 0;

  // Loop through pages until we have fetched all results.
  // Each iteration is one API call and consumes one credit.
  while (true) {
    const variables = {
      input: {
        jobChangeFilter,
        contactFilter: {
          roles: ROLES,
          seniorities: SENIORITIES,
        },
        companyFilter: {
          industries: CURRENT_INDUSTRIES,
        },
        // Show the most recent changes first.
        sortContactsBy: ["JobChangeStartedAtDesc"],
        limit: PAGE_SIZE,
        skip,
      },
    };

    const data = await callApi(headers, variables);
    const { totalPeople, people } = data;

    // On the first page, show the total so the user knows what to expect.
    if (skip === 0) {
      if (totalPeople === 0) {
        console.log("No job changes found. Try widening the filters.");
        return;
      }
      const target = Math.min(totalPeople, MAX_PEOPLE);
      console.log(
        `Found ${totalPeople} job changes. Fetching up to ${target} (${PAGE_SIZE} per page)...\n`
      );
    }

    // Collect people from this page, stopping at MAX_PEOPLE.
    for (const person of people) {
      if (allPeople.length >= MAX_PEOPLE) break;
      allPeople.push(person);
    }

    // Stop when we have fetched everything (or hit the safety cap).
    if (allPeople.length >= MAX_PEOPLE || skip + people.length >= totalPeople) {
      break;
    }

    skip += PAGE_SIZE;
  }

  // Print the transitions: previous role → current role.
  allPeople.forEach((person, index) => {
    const change = person.personJobChange ?? {};
    const previous = change.previousPosition ?? {};
    const current = change.currentPosition ?? {};

    const changeType = change.jobChangeType ?? "—";
    const started = formatStartedAt(change.startedAt);

    console.log(`${index + 1}. ${person.name ?? "(unknown)"}  [${changeType} · ${started}]`);
    console.log(`     from: ${previous.title ?? "—"} @ ${companyName(previous)}`);
    console.log(`       to: ${current.title ?? "—"} @ ${companyName(current)}`);
    if (person.linkedinUrl) {
      console.log(`     ${person.linkedinUrl}`);
    }
    console.log();
  });

  console.log(`Total: ${allPeople.length} job changes retrieved.`);

  // Save the raw people list to output/job_changes.json for use elsewhere.
  const outputPath = path.join(__dirname, "..", "output", "job_changes.json");
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(allPeople, null, 2));
  console.log(`Saved to ${outputPath}`);
}

main();
