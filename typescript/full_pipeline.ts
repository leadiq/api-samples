/**
 * full_pipeline.ts — End-to-end LeadIQ pipeline in a single script.
 *
 * This script combines every step from samples 01–06 into one run:
 *
 *   Step 1 — Advanced search (GraphQL)
 *             Search for Sales professionals at VP, Director, and Manager level
 *             in New Hampshire and collect their LeadIQ person IDs.
 *
 *   Step 2 — Enrich profiles (GraphQL)
 *             For each person ID, fetch their work email and direct phone number.
 *
 *   Step 3 — Create a Prospector list (REST)
 *             Create a new list named "Sales Leaders in NH - Pipeline" in the
 *             LeadIQ Prospector.
 *
 *   Step 4 — Add prospects (REST)
 *             Add each enriched person to the list as a prospect.
 *
 *   Step 5 — Export to CSV (REST)
 *             Fetch all prospects back from the list and write them to a CSV
 *             file you can open in Excel or Google Sheets.
 *
 * No intermediate JSON files are created — everything flows through memory.
 * The only output is output/pipeline_prospects.csv.
 *
 * IMPORTANT — credit cost:
 *   Step 1 costs 1 "Advanced Search (Page)" credit per page of results.
 *   Step 2 costs 1 "Enrich" credit per person.
 *   Steps 3–5 are free.
 *   Set MAX_PEOPLE below to a small number until you are happy with the results.
 *
 * Run it with:
 *   npx ts-node full_pipeline.ts
 */

import dotenv from "dotenv";
import fs from "fs";
import path from "path";

dotenv.config({ path: path.join(__dirname, ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

// GraphQL API — used for search and enrichment (steps 1 and 2).
const GRAPHQL_URL = "https://api.leadiq.com/graphql";

// Prospector REST API — used for list management and export (steps 3–5).
const PROSPECTOR_URL = "https://prospector.leadiq.com";

const API_KEY = process.env.LEADIQ_API_KEY;

// ── Search filters (Step 1) ────────────────────────────────────────────────────

const SENIORITIES = ["VP", "Director", "Manager"];
const ROLES = ["Sales"];
const LOCATION = { areaLevel1: "New Hampshire", country: "United States" };
const SEARCH_PAGE_SIZE = 25;

// ── Enrichment settings (Step 2) ──────────────────────────────────────────────

// Each person costs ONE Enrich credit — start small and raise once satisfied.
const MAX_PEOPLE = 10;
const ENRICH_DELAY_MS = 500;

// ── Prospector list settings (Steps 3–5) ──────────────────────────────────────

// This name is intentionally different from sample 04 to avoid a 409 conflict.
const LIST_NAME = "Sales Leaders in NH - Pipeline - TS";
const LIST_DESCRIPTION =
  "VP, Director, and Manager level Sales professionals in New Hampshire " +
  "— created by the full_pipeline.ts end-to-end sample.";
const EXPORT_PAGE_SIZE = 100;

// ── Output ─────────────────────────────────────────────────────────────────────

const OUTPUT_PATH = path.join(__dirname, "output", "pipeline_prospects.csv");

const CSV_FIELDS = [
  "id", "name", "first_name", "last_name", "title",
  "seniority", "function",
  "work_email", "email_status",
  "direct_phone",
  "linkedin_url",
  "location_city", "location_state", "location_country",
  "company_name", "company_domain", "company_industry", "company_employees",
  "updated_at",
] as const;

type CsvField = (typeof CSV_FIELDS)[number];
type CsvRow = Record<CsvField, string | number | null | undefined>;

// ── Types ─────────────────────────────────────────────────────────────────────

interface GraphQLError {
  message: string;
  extensions?: { response?: { status?: number } };
}

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

interface ProspectorList { id: string; name: string; createdAt: string }

interface ProspectSummary {
  id: string;
  firstName?: string;
  lastName?: string;
  name?: string;
  title?: string;
  workEmail?: string;
  emailStatus?: string;
  location?: { city?: string; state?: string; country?: string };
  company?: { name?: string; domain?: string; industry?: string; employees?: number };
  updatedAt: string;
}

// ── Authentication ─────────────────────────────────────────────────────────────

function graphqlHeaders(): Record<string, string> {
  // The GraphQL API uses HTTP Basic Auth. The API key goes in the Authorization
  // header as-is — it is already base64-encoded.
  return {
    Authorization: `Basic ${API_KEY}`,
    "Content-Type": "application/json",
  };
}

function prospectorHeaders(): Record<string, string> {
  // The Prospector REST API uses a different header (X-API-Key) and expects
  // the raw decoded key, not the base64 version stored in the .env file.
  return {
    "X-API-Key": Buffer.from(API_KEY!, "base64").toString("utf-8"),
    "Content-Type": "application/json",
  };
}

// ── GraphQL helper ─────────────────────────────────────────────────────────────

async function graphqlRequest<T>(
  query: string,
  variables: object
): Promise<T> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  try {
    const response = await fetch(GRAPHQL_URL, {
      method: "POST",
      headers: graphqlHeaders(),
      body: JSON.stringify({ query, variables }),
      signal: controller.signal,
    });
    const result = (await response.json()) as { data?: T; errors?: GraphQLError[] };

    if (result.errors) {
      const error = result.errors[0];
      const status = error.extensions?.response?.status;
      if (status === 401)      console.error("\nError: Invalid API key.");
      else if (status === 402) console.error("\nError: Insufficient credits.");
      else if (status === 429) console.error("\nError: Too many requests. Wait a moment and try again.");
      else                     console.error(`\nAPI error: ${error.message ?? "Unknown error"}`);
      process.exit(1);
    }

    return result.data!;
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      console.error("\nError: The API took too long to respond.");
    } else {
      console.error("\nError: Could not reach the API. Check your internet connection.");
    }
    process.exit(1);
  } finally {
    clearTimeout(timeoutId);
  }
}

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

// ── Step 1 — Advanced search ───────────────────────────────────────────────────

const ADVANCED_SEARCH_QUERY = `
query FlatAdvancedSearch($input: FlatSearchInput!) {
  flatAdvancedSearch(input: $input) {
    totalPeople
    people { id }
  }
}`;

async function getAllIds(): Promise<string[]> {
  console.log("Step 1 — Advanced search");
  console.log(`  Roles      : ${ROLES.join(", ")}`);
  console.log(`  Seniorities: ${SENIORITIES.join(", ")}`);
  console.log(`  Location   : ${LOCATION.areaLevel1}, ${LOCATION.country}`);

  const allIds: string[] = [];
  let skip = 0;

  while (true) {
    const data = await graphqlRequest<{
      flatAdvancedSearch: { totalPeople: number; people: { id: string }[] };
    }>(ADVANCED_SEARCH_QUERY, {
      input: {
        contactFilter: { roles: ROLES, seniorities: SENIORITIES, locations: [LOCATION] },
        limit: SEARCH_PAGE_SIZE,
        skip,
      },
    });

    const { totalPeople, people } = data.flatAdvancedSearch;

    if (skip === 0) {
      if (totalPeople === 0) {
        console.log("  No results found. Try adjusting the filters.");
        process.exit(0);
      }
      console.log(`  Found ${totalPeople} people — will enrich up to ${MAX_PEOPLE}.`);
    }

    allIds.push(...people.map((p) => p.id));

    if (skip + people.length >= totalPeople || allIds.length >= MAX_PEOPLE) break;
    skip += SEARCH_PAGE_SIZE;
  }

  const ids = allIds.slice(0, MAX_PEOPLE);
  console.log(`  Collected ${ids.length} IDs.\n`);
  return ids;
}

// ── Step 2 — Enrich profiles ───────────────────────────────────────────────────

const SEARCH_PEOPLE_QUERY = `
query SearchPeople($input: SearchPeopleInput!) {
  searchPeople(input: $input) {
    results {
      id
      linkedin { linkedinUrl }
      name { fullName first last }
      currentPositions {
        title
        seniority
        function
        companyInfo { name }
        emails { value status }
      }
      personalPhones { value verificationStatus }
    }
  }
}`;

interface PersonRecord {
  id: string;
  linkedin?: { linkedinUrl?: string };
  name?: { fullName?: string; first?: string; last?: string };
  currentPositions?: Array<{
    title?: string;
    seniority?: string;
    function?: string;
    companyInfo?: { name?: string };
    emails?: Array<{ value: string; status: string }>;
  }>;
  personalPhones?: Array<{ value: string; verificationStatus: string }>;
}

function bestEmail(
  positions: PersonRecord["currentPositions"]
): string | null {
  const skip = new Set(["Invalid", "Suppressed"]);
  const priority: Record<string, number> = { Verified: 0, VerifiedLikely: 1, Unverified: 2 };
  const candidates = (positions ?? []).flatMap((p) =>
    (p.emails ?? []).filter((e) => !skip.has(e.status))
  );
  if (!candidates.length) return null;
  candidates.sort((a, b) => (priority[a.status] ?? 99) - (priority[b.status] ?? 99));
  return candidates[0].value;
}

function bestPhone(phones: PersonRecord["personalPhones"]): string | null {
  return phones?.[0]?.value ?? null;
}

async function enrichProfiles(ids: string[]): Promise<EnrichedProfile[]> {
  console.log(`Step 2 — Enriching ${ids.length} profiles (1 credit each)`);

  const enriched: EnrichedProfile[] = [];
  const total = ids.length;

  for (let i = 0; i < ids.length; i++) {
    const personId = ids[i];
    process.stdout.write(`  [${i + 1}/${total}] ${personId} ... `);

    const data = await graphqlRequest<{ searchPeople: { results: PersonRecord[] } }>(
      SEARCH_PEOPLE_QUERY,
      { input: { id: personId } }
    );

    const results = data.searchPeople.results;
    if (!results.length) {
      console.log("not found — skipped");
    } else {
      const person = results[0];
      const current = person.currentPositions?.[0] ?? {};

      const profile: EnrichedProfile = {
        id:           person.id,
        full_name:    person.name?.fullName ?? null,
        first_name:   person.name?.first ?? null,
        last_name:    person.name?.last ?? null,
        title:        current.title ?? null,
        seniority:    current.seniority ?? null,
        function:     current.function ?? null,
        company:      current.companyInfo?.name ?? null,
        work_email:   bestEmail(person.currentPositions),
        direct_phone: bestPhone(person.personalPhones),
        linkedin_url: person.linkedin?.linkedinUrl ?? null,
      };
      enriched.push(profile);

      const emailTag = profile.work_email   ? "✓ email" : "— email";
      const phoneTag = profile.direct_phone ? "✓ phone" : "— phone";
      console.log(`${emailTag}  ${phoneTag}`);
    }

    if (i < ids.length - 1) await sleep(ENRICH_DELAY_MS);
  }

  console.log(`  Enriched ${enriched.length} of ${total} profiles.\n`);
  return enriched;
}

// ── Step 3 — Create Prospector list ───────────────────────────────────────────

async function createList(): Promise<string> {
  process.stdout.write(`Step 3 — Creating list "${LIST_NAME}"... `);

  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  try {
    const response = await fetch(`${PROSPECTOR_URL}/v1/lists`, {
      method: "POST",
      headers: prospectorHeaders(),
      body: JSON.stringify({ name: LIST_NAME, description: LIST_DESCRIPTION }),
      signal: controller.signal,
    });
    const result = (await response.json()) as ProspectorList & { message?: string };

    if (response.status === 401) { console.error("\nError: Invalid API key."); process.exit(1); }
    if (response.status === 409) {
      console.error(`\nError: A list named "${LIST_NAME}" already exists.`);
      console.error("Change LIST_NAME in this script and try again.");
      process.exit(1);
    }
    if (!response.ok) {
      console.error(`\nError ${response.status}: ${result.message ?? "Unknown error"}`);
      process.exit(1);
    }

    console.log(`done (id: ${result.id})\n`);
    return result.id;
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      console.error("\nError: The API took too long to respond.");
    } else {
      console.error("\nError: Could not reach the Prospector API.");
    }
    process.exit(1);
  } finally {
    clearTimeout(timeoutId);
  }
}

// ── Step 4 — Add prospects ─────────────────────────────────────────────────────

async function addProspects(
  listId: string,
  profiles: EnrichedProfile[]
): Promise<void> {
  console.log(`Step 4 — Adding ${profiles.length} prospects to the list`);

  let added = 0;
  let skipped = 0;
  const total = profiles.length;

  for (let i = 0; i < profiles.length; i++) {
    const profile = profiles[i];
    const first = (profile.first_name ?? "").trim();
    const last  = (profile.last_name  ?? "").trim();
    const name  =
      profile.full_name || `${first} ${last}`.trim() || "—";

    process.stdout.write(`  [${i + 1}/${total}] ${name} ... `);

    if (!first || !last) {
      console.log("skipped (missing name)");
      skipped++;
      continue;
    }

    const body: Record<string, string> = { firstName: first, lastName: last };
    if (profile.title)        body.title       = profile.title;
    if (profile.seniority)    body.seniority   = profile.seniority;
    if (profile.function)     body.function    = profile.function;
    if (profile.company)      body.company     = profile.company;
    if (profile.work_email)   body.workEmail   = profile.work_email;
    if (profile.direct_phone) body.mobilePhone = profile.direct_phone;
    if (profile.linkedin_url) body.linkedinUrl = profile.linkedin_url;

    const controller = new AbortController();
    const timeoutId  = setTimeout(() => controller.abort(), 30_000);

    try {
      const response = await fetch(
        `${PROSPECTOR_URL}/v1/lists/${listId}/prospects`,
        { method: "POST", headers: prospectorHeaders(), body: JSON.stringify(body), signal: controller.signal }
      );

      if (response.status === 401) { console.error("\nError: Invalid API key."); process.exit(1); }
      if (!response.ok) { console.log(`error ${response.status} — skipped`); skipped++; continue; }

      console.log("added");
      added++;
    } catch (err) {
      console.log(err instanceof Error && err.name === "AbortError" ? "timeout — skipped" : "connection error — skipped");
      skipped++;
    } finally {
      clearTimeout(timeoutId);
    }

    if (i < profiles.length - 1) await sleep(ENRICH_DELAY_MS);
  }

  console.log(`  Added ${added}, skipped ${skipped}.\n`);
}

// ── Step 5 — Export to CSV ─────────────────────────────────────────────────────

async function fetchAndExport(listId: string, profiles: EnrichedProfile[]): Promise<void> {
  const profileByEmail = new Map(
    profiles.filter((p) => p.work_email).map((p) => [p.work_email!, p])
  );
  console.log("Step 5 — Fetching prospects and writing CSV");

  const allRows: CsvRow[] = [];
  let cursor: string | undefined;
  let page = 1;

  while (true) {
    const url = new URL(`${PROSPECTOR_URL}/v1/lists/${listId}/prospects`);
    url.searchParams.set("limit", String(EXPORT_PAGE_SIZE));
    if (cursor) url.searchParams.set("cursor", cursor);

    const controller = new AbortController();
    const timeoutId  = setTimeout(() => controller.abort(), 30_000);

    try {
      const response  = await fetch(url.toString(), { headers: prospectorHeaders(), signal: controller.signal });
      const result    = (await response.json()) as { items: ProspectSummary[]; nextCursor: string | null; message?: string };

      if (!response.ok) { console.error(`\nError ${response.status}: ${result.message ?? "Unknown error"}`); process.exit(1); }

      process.stdout.write(`  Page ${page}: `);
      console.log(`${result.items.length} prospects`);

      for (const p of result.items) {
        const loc = p.location ?? {};
        const co  = p.company  ?? {};
        const enriched = p.workEmail ? profileByEmail.get(p.workEmail) : undefined;
        allRows.push({
          id: p.id, name: p.name, first_name: p.firstName, last_name: p.lastName,
          title: p.title, seniority: enriched?.seniority, "function": enriched?.function,
          work_email: p.workEmail, email_status: p.emailStatus,
          direct_phone: enriched?.direct_phone,
          linkedin_url: enriched?.linkedin_url,
          location_city: loc.city, location_state: loc.state, location_country: loc.country,
          company_name: co.name, company_domain: co.domain,
          company_industry: co.industry, company_employees: co.employees,
          updated_at: p.updatedAt,
        });
      }

      if (!result.nextCursor) break;
      cursor = result.nextCursor;
      page++;
    } catch (err) {
      if (err instanceof Error && err.name === "AbortError") console.error("\nError: The API took too long to respond.");
      else console.error("\nError: Could not reach the Prospector API.");
      process.exit(1);
    } finally {
      clearTimeout(timeoutId);
    }
  }

  const escape = (v: unknown): string => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const csv = [
    CSV_FIELDS.map(escape).join(","),
    ...allRows.map((row) => CSV_FIELDS.map((f) => escape(row[f])).join(",")),
  ].join("\n");

  fs.mkdirSync(path.dirname(OUTPUT_PATH), { recursive: true });
  fs.writeFileSync(OUTPUT_PATH, csv, "utf-8");

  console.log(`\n  Total: ${allRows.length} prospects`);
  console.log(`  Saved to: ${OUTPUT_PATH}`);
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(1);
  }

  console.log("=".repeat(60));
  console.log("LeadIQ Full Pipeline");
  console.log("=".repeat(60));
  console.log();

  const ids      = await getAllIds();
  const profiles = await enrichProfiles(ids);
  const listId   = await createList();
  await addProspects(listId, profiles);
  await fetchAndExport(listId, profiles);

  console.log();
  console.log("Done.");
}

main();
