/**
 * 03_enrich_profiles.ts — Enrich people with work email and direct phone.
 *
 * This sample reads the LeadIQ person IDs produced by 02_advanced_search.ts,
 * calls searchPeople once per person to retrieve their work email and personal
 * (direct) phone number, and saves the enriched records to
 * output/enriched_profiles.json.
 *
 * IMPORTANT: Each searchPeople call consumes one "Enrich" credit.
 *   MAX_PEOPLE below controls how many profiles are processed in one run.
 *   Start with a small number to verify your results before enriching in bulk.
 *
 * Run it with:
 *   npx ts-node graphql/03_enrich_profiles.ts
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";

// Load the LEADIQ_API_KEY from the .env file in the typescript/ folder.
dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

// The URL every LeadIQ GraphQL request is sent to.
const GRAPHQL_URL = "https://api.leadiq.com/graphql";

// Your API key is loaded from the .env file — never hard-code it here.
const API_KEY = process.env.LEADIQ_API_KEY;

// Path to the IDs file produced by 02_advanced_search.ts.
const INPUT_PATH = path.join(
  __dirname,
  "..",
  "output",
  "advanced_search_ids.json"
);

// Maximum number of people to enrich in this run.
// ── IMPORTANT ──────────────────────────────────────────────────────────────────
// Each person enriched costs ONE Enrich credit from your plan.
// The default is 10 so you can try the script without burning many credits.
// Once you are happy with the results, raise this number to process more people.
const MAX_PEOPLE = 10;

// How long to wait (in milliseconds) between API calls.
// This keeps the script from sending requests too fast and hitting rate limits.
const DELAY_BETWEEN_CALLS_MS = 500;

// ── Types ─────────────────────────────────────────────────────────────────────

interface GraphQLError {
  message: string;
  extensions?: {
    response?: {
      status?: number;
    };
  };
}

// Shape of a single email record returned by the API.
interface EmailRecord {
  value: string;
  type: string;
  status: string;
}

// Shape of a single phone record returned by the API.
interface PhoneRecord {
  value: string;
  verificationStatus: string;
}

// Shape of a current job position (contains work emails for that job).
interface PositionRecord {
  title: string | null;
  seniority: string | null;
  function: string | null;
  companyInfo: { name: string } | null;
  emails: EmailRecord[];
}

// Shape of a full person record returned by searchPeople.
interface PersonRecord {
  id: string;
  linkedin: { linkedinUrl: string } | null;
  name: {
    fullName: string | null;
    first: string | null;
    last: string | null;
  };
  currentPositions: PositionRecord[];
  personalPhones: PhoneRecord[];
}

interface SearchPeopleResponse {
  data?: {
    searchPeople: {
      totalResults: number;
      results: PersonRecord[];
    };
  };
  errors?: GraphQLError[];
}

// Shape of the clean, flat record we save to the output file.
interface EnrichedProfile {
  id: string;
  full_name: string | null;
  first_name: string | null;
  last_name: string | null;
  title: string | null;
  seniority: string | null;
  function: string | null;
  company: string | null;
  work_email: string | null;
  direct_phone: string | null;
  linkedin_url: string | null;
}

// ── Query ──────────────────────────────────────────────────────────────────────

// searchPeople looks up ONE person by their LeadIQ ID and returns their profile.
//
// Work emails are nested inside currentPositions — every email there is a work
// email tied to that job.  Personal (direct) phones live at the top level in
// personalPhones.
const SEARCH_PEOPLE_QUERY = `
query SearchPeople($input: SearchPeopleInput!) {
  searchPeople(input: $input) {
    totalResults
    results {
      id
      linkedin { linkedinUrl }
      name {
        fullName
        first
        last
      }
      currentPositions {
        title
        seniority
        function
        companyInfo {
          name
        }
        emails {
          value
          type
          status
        }
      }
      personalPhones {
        value
        verificationStatus
      }
    }
  }
}
`;

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Call searchPeople for one person ID and return the results array.
 * Exits the process if the network request fails or the API returns an error.
 */
async function callApi(
  headers: Record<string, string>,
  personId: string
): Promise<PersonRecord[]> {
  // Build the variables object that fills the $input placeholder in the query.
  const variables = { input: { id: personId } };

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  let result: SearchPeopleResponse;
  try {
    const response = await fetch(GRAPHQL_URL, {
      method: "POST",
      headers,
      body: JSON.stringify({ query: SEARCH_PEOPLE_QUERY, variables }),
      signal: controller.signal,
    });
    result = (await response.json()) as SearchPeopleResponse;
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

  // The LeadIQ API always returns HTTP 200 even for errors.
  // Real error details are inside the "errors" field of the JSON response.
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

  // Return the list of matched person records (normally one item).
  return result.data!.searchPeople.results;
}

/**
 * Return the best work email address found across all current positions.
 *
 * Work emails are stored inside each job position (currentPositions), so we
 * look through every position and collect all available addresses.
 *
 * The API may return several addresses with different confidence levels:
 *   Verified       — confirmed accurate
 *   VerifiedLikely — very likely accurate
 *   Unverified     — found but not yet confirmed
 *   Invalid        — known to be wrong (skipped)
 *   Suppressed     — opted out of contact (skipped)
 *
 * We pick the most confident address and ignore Invalid / Suppressed ones.
 */
function pickWorkEmail(currentPositions: PositionRecord[]): string | null {
  // Statuses we do not want to return.
  const skipStatuses = new Set(["Invalid", "Suppressed"]);

  // Map each status to a number so we can sort — lower number = better.
  const priority: Record<string, number> = {
    Verified: 0,
    VerifiedLikely: 1,
    Unverified: 2,
  };

  // Gather every usable work email from all current positions.
  const candidates: EmailRecord[] = [];
  for (const position of currentPositions) {
    for (const email of position.emails ?? []) {
      if (!skipStatuses.has(email.status)) {
        candidates.push(email);
      }
    }
  }

  if (candidates.length === 0) return null;

  // Sort by confidence and return the best one.
  candidates.sort(
    (a, b) => (priority[a.status] ?? 99) - (priority[b.status] ?? 99)
  );
  return candidates[0].value;
}

function pickPersonalPhone(personalPhones: PhoneRecord[]): string | null {
  return personalPhones[0]?.value ?? null;
}

/**
 * Pull the fields we care about out of a raw PersonRecord and return a
 * clean, flat object that is easy to read and save to JSON.
 */
function extractProfile(person: PersonRecord): EnrichedProfile {
  // Use the first current position for title and company.
  // Most people have only one current job, but some may have more.
  const current = person.currentPositions?.[0] ?? null;

  return {
    id: person.id,
    full_name: person.name?.fullName ?? null,
    first_name: person.name?.first ?? null,
    last_name: person.name?.last ?? null,
    title: current?.title ?? null,
    seniority: current?.seniority ?? null,
    function: current?.function ?? null,
    company: current?.companyInfo?.name ?? null,
    work_email: pickWorkEmail(person.currentPositions ?? []),
    direct_phone: pickPersonalPhone(person.personalPhones ?? []),
    linkedin_url: person.linkedin?.linkedinUrl ?? null,
  };
}

/** Pause execution for a given number of milliseconds. */
const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  // Verify the API key is available before doing anything else.
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(1);
  }

  // Make sure the IDs file from the previous sample exists.
  if (!fs.existsSync(INPUT_PATH)) {
    console.error(`Error: Input file not found: ${INPUT_PATH}`);
    console.error("Run 02_advanced_search.ts first to generate the IDs file.");
    process.exit(1);
  }

  // Load the list of person IDs.
  const allIds: string[] = JSON.parse(fs.readFileSync(INPUT_PATH, "utf-8"));

  if (allIds.length === 0) {
    console.error("Error: The IDs file is empty. Run 02_advanced_search.ts first.");
    process.exit(1);
  }

  // Slice the list so we only process up to MAX_PEOPLE entries.
  // This protects against accidentally spending hundreds of credits in one run.
  const idsToProcess = allIds.slice(0, MAX_PEOPLE);
  const total = idsToProcess.length;

  // Print a summary of what is about to happen before spending any credits.
  console.log(`Input file : ${INPUT_PATH}`);
  console.log(`Total IDs  : ${allIds.length}`);
  console.log(`Processing : ${total} (MAX_PEOPLE=${MAX_PEOPLE})`);
  console.log(`API calls  : ${total}  (one per person)`);
  console.log(`Max credits: ${total} Enrich credits`);
  console.log();

  // Build the HTTP headers that authenticate every request.
  const headers = {
    Authorization: `Basic ${API_KEY}`,
    "Content-Type": "application/json",
  };

  const enriched: EnrichedProfile[] = []; // profiles enriched successfully
  let notFound = 0;                        // IDs that returned no results

  // Loop through each ID and enrich one person at a time.
  // The API does not support looking up multiple IDs in a single call.
  for (let i = 0; i < idsToProcess.length; i++) {
    const personId = idsToProcess[i];
    process.stdout.write(`[${i + 1}/${total}] ${personId} ... `);

    const results = await callApi(headers, personId);

    if (results.length === 0) {
      // The API returned no match for this ID (e.g. profile was deleted).
      console.log("not found");
      notFound++;
    } else {
      // results[0] is the best match for the ID we sent.
      const profile = extractProfile(results[0]);
      enriched.push(profile);

      // Show a quick indicator so you can see enrichment quality in real time.
      const emailIndicator = profile.work_email ? "✓ email" : "— email";
      const phoneIndicator = profile.direct_phone ? "✓ phone" : "— phone";
      console.log(`${emailIndicator}  ${phoneIndicator}`);
    }

    // Wait a short moment before the next call to avoid rate-limit errors.
    if (i < total - 1) {
      await sleep(DELAY_BETWEEN_CALLS_MS);
    }
  }

  // ── Print a summary table ──────────────────────────────────────────────────

  console.log();
  console.log(
    "#".padEnd(5) +
    "Name".padEnd(28) +
    "Seniority".padEnd(12) +
    "Function".padEnd(14) +
    "Title".padEnd(30) +
    "Company".padEnd(24) +
    "Work Email".padEnd(32) +
    "Direct Phone"
  );
  console.log("-".repeat(160));

  enriched.forEach((p, index) => {
    const name =
      p.full_name ||
      `${p.first_name ?? ""} ${p.last_name ?? ""}`.trim() ||
      "—";

    console.log(
      String(index + 1).padEnd(5) +
      name.padEnd(28) +
      (p.seniority ?? "—").padEnd(12) +
      (p.function ?? "—").padEnd(14) +
      (p.title ?? "—").padEnd(30) +
      (p.company ?? "—").padEnd(24) +
      (p.work_email ?? "—").padEnd(32) +
      (p.direct_phone ?? "—")
    );
  });

  console.log();
  console.log(`Enriched  : ${enriched.length}`);
  console.log(`Not found : ${notFound}`);

  // ── Save results to JSON ───────────────────────────────────────────────────

  const outputPath = path.join(
    __dirname,
    "..",
    "output",
    "enriched_profiles.json"
  );
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, JSON.stringify(enriched, null, 2));
  console.log(`Saved to  : ${outputPath}`);
}

main();
