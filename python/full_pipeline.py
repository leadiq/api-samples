"""
full_pipeline.py — End-to-end LeadIQ pipeline in a single script.

This script combines every step from samples 01–06 into one run:

  Step 1 — Advanced search (GraphQL)
            Search for Sales professionals at VP, Director, and Manager level
            in New Hampshire and collect their LeadIQ person IDs.

  Step 2 — Enrich profiles (GraphQL)
            For each person ID, fetch their work email and direct phone number.

  Step 3 — Create a Prospector list (REST)
            Create a new list named "Sales Leaders in NH - Pipeline" in the
            LeadIQ Prospector.

  Step 4 — Add prospects (REST)
            Add each enriched person to the list as a prospect.

  Step 5 — Export to CSV (REST)
            Fetch all prospects back from the list and write them to a CSV
            file you can open in Excel or Google Sheets.

No intermediate JSON files are created — everything flows through memory.
The only output is output/pipeline_prospects.csv.

IMPORTANT — credit cost:
  Step 1 costs 1 "Advanced Search (Page)" credit per page of results.
  Step 2 costs 1 "Enrich" credit per person.
  Steps 3–5 are free.
  Set MAX_PEOPLE below to a small number until you are happy with the results.

Run it with:
    python full_pipeline.py
"""

import base64
import csv
import os
import sys
import time
import requests

# ── Configuration ─────────────────────────────────────────────────────────────

# GraphQL API — used for search and enrichment (steps 1 and 2).
GRAPHQL_URL = "https://api.leadiq.com/graphql"

# Prospector REST API — used for list management and export (steps 3–5).
PROSPECTOR_URL = "https://prospector.leadiq.com"

# Your API key is loaded from the .env file — never hard-code it here.
API_KEY = os.getenv("LEADIQ_API_KEY")

# ── Search filters (Step 1) ────────────────────────────────────────────────────

SENIORITIES = ["VP", "Director", "Manager"]
ROLES       = ["Sales"]
LOCATION    = {"areaLevel1": "New Hampshire", "country": "United States"}

# How many results to fetch per advanced-search API call (max 25).
# Each call costs one credit regardless of how many results come back.
SEARCH_PAGE_SIZE = 25

# ── Enrichment settings (Step 2) ──────────────────────────────────────────────

# Maximum number of people to enrich.
# Each person costs ONE Enrich credit — start small and raise once satisfied.
MAX_PEOPLE = 10

# Pause between enrichment calls to avoid hitting rate limits.
ENRICH_DELAY = 0.5  # seconds

# ── Prospector list settings (Steps 3–5) ──────────────────────────────────────

# This name is intentionally different from sample 04 to avoid a 409 conflict.
LIST_NAME        = "Sales Leaders in NH - Pipeline"
LIST_DESCRIPTION = (
    "VP, Director, and Manager level Sales professionals in New Hampshire "
    "— created by the full_pipeline.py end-to-end sample."
)

# How many prospects to request per Prospector API call when exporting (max 100).
EXPORT_PAGE_SIZE = 100

# ── Output ─────────────────────────────────────────────────────────────────────

OUTPUT_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "output", "pipeline_prospects.csv")
)

# Columns written to the CSV file, in left-to-right order.
CSV_FIELDS = [
    "id",
    "name",
    "first_name",
    "last_name",
    "title",
    "seniority",
    "function",
    "work_email",
    "email_status",
    "direct_phone",
    "linkedin_url",
    "location_city",
    "location_state",
    "location_country",
    "company_name",
    "company_domain",
    "company_industry",
    "company_employees",
    "updated_at",
]

# ── Authentication helpers ─────────────────────────────────────────────────────

def graphql_headers():
    # The GraphQL API uses HTTP Basic Auth.  The API key goes in the
    # Authorization header as-is — it is already base64-encoded.
    return {
        "Authorization": f"Basic {API_KEY}",
        "Content-Type": "application/json",
    }


def prospector_headers():
    # The Prospector REST API uses a different header (X-API-Key) and expects
    # the raw decoded key, not the base64 version stored in the .env file.
    try:
        raw_key = base64.b64decode(API_KEY).decode("utf-8")
    except Exception:
        raw_key = API_KEY
    return {
        "X-API-Key": raw_key,
        "Content-Type": "application/json",
    }

# ── GraphQL helper ─────────────────────────────────────────────────────────────

def graphql_request(query, variables):
    # A single reusable function for every GraphQL call.
    # Sends the query and variables as JSON, then checks for errors.
    try:
        response = requests.post(
            GRAPHQL_URL,
            json={"query": query, "variables": variables},
            headers=graphql_headers(),
            timeout=30,
        )
        result = response.json()
    except requests.exceptions.Timeout:
        print("\nError: The API took too long to respond. Please try again.")
        sys.exit(1)
    except requests.exceptions.ConnectionError:
        print("\nError: Could not reach the API. Check your internet connection.")
        sys.exit(1)

    if "errors" in result:
        error  = result["errors"][0]
        status = error.get("extensions", {}).get("response", {}).get("status")
        if status == 401:
            print("\nError: Invalid API key.")
        elif status == 402:
            print("\nError: Insufficient credits.")
        elif status == 429:
            print("\nError: Too many requests. Wait a moment and try again.")
        else:
            print(f"\nAPI error: {error.get('message', 'Unknown error')}")
        sys.exit(1)

    return result["data"]

# ── Step 1 — Advanced search ───────────────────────────────────────────────────

ADVANCED_SEARCH_QUERY = """
query FlatAdvancedSearch($input: FlatSearchInput!) {
  flatAdvancedSearch(input: $input) {
    totalPeople
    people { id }
  }
}
"""

def get_all_ids():
    # Send paged requests until we have every person ID matching the filters.
    # Each page call costs one "Advanced Search (Page)" credit.
    print("Step 1 — Advanced search")
    print(f"  Roles      : {', '.join(ROLES)}")
    print(f"  Seniorities: {', '.join(SENIORITIES)}")
    print(f"  Location   : {LOCATION['areaLevel1']}, {LOCATION['country']}")

    all_ids = []
    skip    = 0

    while True:
        variables = {
            "input": {
                "contactFilter": {
                    "roles":        ROLES,
                    "seniorities":  SENIORITIES,
                    "locations":    [LOCATION],
                },
                "limit": SEARCH_PAGE_SIZE,
                "skip":  skip,
            }
        }

        data   = graphql_request(ADVANCED_SEARCH_QUERY, variables)
        total  = data["flatAdvancedSearch"]["totalPeople"]
        people = data["flatAdvancedSearch"]["people"]

        if skip == 0:
            if total == 0:
                print("  No results found. Try adjusting the filters.")
                sys.exit(0)
            # Limit to MAX_PEOPLE before spending credits on enrichment.
            print(f"  Found {total} people — will enrich up to {MAX_PEOPLE}.")

        all_ids.extend(p["id"] for p in people)

        if skip + len(people) >= total:
            break

        # Stop early once we have enough IDs for the enrichment step.
        if len(all_ids) >= MAX_PEOPLE:
            break

        skip += SEARCH_PAGE_SIZE

    ids = all_ids[:MAX_PEOPLE]
    print(f"  Collected {len(ids)} IDs.\n")
    return ids

# ── Step 2 — Enrich profiles ───────────────────────────────────────────────────

SEARCH_PEOPLE_QUERY = """
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
}
"""

def _best_email(positions):
    # Work emails live inside each job position.  We return the most confident
    # address found across all positions, skipping invalid or suppressed ones.
    skip     = {"Invalid", "Suppressed"}
    priority = {"Verified": 0, "VerifiedLikely": 1, "Unverified": 2}
    candidates = [
        email
        for pos in (positions or [])
        for email in (pos.get("emails") or [])
        if email.get("status") not in skip
    ]
    if not candidates:
        return None
    candidates.sort(key=lambda e: priority.get(e.get("status") or "", 99))
    return candidates[0]["value"]


def _best_phone(phones):
    phones = phones or []
    return phones[0]["value"] if phones else None


def enrich_profiles(ids):
    # Call searchPeople once per person ID to fetch their contact details.
    # Each call costs one Enrich credit.
    print(f"Step 2 — Enriching {len(ids)} profiles (1 credit each)")

    enriched = []
    total    = len(ids)

    for i, person_id in enumerate(ids, start=1):
        print(f"  [{i}/{total}] {person_id} ...", end=" ", flush=True)

        data    = graphql_request(SEARCH_PEOPLE_QUERY, {"input": {"id": person_id}})
        results = data["searchPeople"]["results"]

        if not results:
            print("not found — skipped")
        else:
            person    = results[0]
            name      = person.get("name") or {}
            positions = person.get("currentPositions") or []
            current   = positions[0] if positions else {}

            linkedin = person.get("linkedin") or {}
            profile = {
                "id":           person.get("id"),
                "full_name":    name.get("fullName"),
                "first_name":   name.get("first"),
                "last_name":    name.get("last"),
                "title":        current.get("title"),
                "seniority":    current.get("seniority"),
                "function":     current.get("function"),
                "company":      (current.get("companyInfo") or {}).get("name"),
                "work_email":   _best_email(positions),
                "direct_phone": _best_phone(person.get("personalPhones")),
                "linkedin_url": linkedin.get("linkedinUrl"),
            }
            enriched.append(profile)

            email_tag = "✓ email" if profile["work_email"]   else "— email"
            phone_tag = "✓ phone" if profile["direct_phone"] else "— phone"
            print(f"{email_tag}  {phone_tag}")

        if i < total:
            time.sleep(ENRICH_DELAY)

    print(f"  Enriched {len(enriched)} of {total} profiles.\n")
    return enriched

# ── Step 3 — Create Prospector list ───────────────────────────────────────────

def create_list():
    # POST /v1/lists — create a new list and return its ID.
    # POST is the REST way of saying "create something new."
    print(f'Step 3 — Creating list "{LIST_NAME}"...', end=" ", flush=True)

    try:
        response = requests.post(
            f"{PROSPECTOR_URL}/v1/lists",
            json={"name": LIST_NAME, "description": LIST_DESCRIPTION},
            headers=prospector_headers(),
            timeout=30,
        )
        result = response.json()
    except requests.exceptions.Timeout:
        print("\nError: The API took too long to respond.")
        sys.exit(1)
    except requests.exceptions.ConnectionError:
        print("\nError: Could not reach the Prospector API.")
        sys.exit(1)

    if response.status_code == 401:
        print("\nError: Invalid API key.")
        sys.exit(1)
    if response.status_code == 409:
        print(f'\nError: A list named "{LIST_NAME}" already exists.')
        print("Change LIST_NAME in this script and try again.")
        sys.exit(1)
    if not response.ok:
        print(f"\nError {response.status_code}: {result.get('message', 'Unknown error')}")
        sys.exit(1)

    list_id = result["id"]
    print(f"done (id: {list_id})\n")
    return list_id

# ── Step 4 — Add prospects ─────────────────────────────────────────────────────

def add_prospects(list_id, profiles):
    # POST /v1/lists/{listId}/prospects — add one person to the list.
    # A prospect is a person record inside a list — like a row in a spreadsheet.
    print(f"Step 4 — Adding {len(profiles)} prospects to the list")

    added   = 0
    skipped = 0
    total   = len(profiles)

    for i, profile in enumerate(profiles, start=1):
        first = (profile.get("first_name") or "").strip()
        last  = (profile.get("last_name")  or "").strip()
        name  = profile.get("full_name") or f"{first} {last}".strip() or "—"

        print(f"  [{i}/{total}] {name} ...", end=" ", flush=True)

        # The API requires first and last name — skip anyone missing either.
        if not first or not last:
            print("skipped (missing name)")
            skipped += 1
            continue

        body = {"firstName": first, "lastName": last}
        if profile.get("title"):        body["title"]       = profile["title"]
        if profile.get("seniority"):    body["seniority"]   = profile["seniority"]
        if profile.get("function"):     body["function"]    = profile["function"]
        if profile.get("company"):      body["company"]     = profile["company"]
        if profile.get("work_email"):   body["workEmail"]   = profile["work_email"]
        if profile.get("direct_phone"): body["mobilePhone"] = profile["direct_phone"]
        if profile.get("linkedin_url"): body["linkedinUrl"] = profile["linkedin_url"]

        try:
            response = requests.post(
                f"{PROSPECTOR_URL}/v1/lists/{list_id}/prospects",
                json=body,
                headers=prospector_headers(),
                timeout=30,
            )
        except requests.exceptions.Timeout:
            print("timeout — skipped")
            skipped += 1
            continue
        except requests.exceptions.ConnectionError:
            print("connection error — skipped")
            skipped += 1
            continue

        if response.status_code == 401:
            print("\nError: Invalid API key.")
            sys.exit(1)
        if not response.ok:
            print(f"error {response.status_code} — skipped")
            skipped += 1
            continue

        print("added")
        added += 1

        if i < total:
            time.sleep(ENRICH_DELAY)

    print(f"  Added {added}, skipped {skipped}.\n")

# ── Step 5 — Export to CSV ─────────────────────────────────────────────────────

def fetch_and_export(list_id, profiles):
    profile_by_email = {p["work_email"]: p for p in profiles if p.get("work_email")}

    # GET /v1/lists/{listId}/prospects — fetch all prospects from the list.
    # GET is the REST way of reading data without changing anything.
    #
    # The API returns results in pages (up to 100 at a time).  Each page comes
    # with a "cursor" — a bookmark that tells the next call where to continue.
    # We keep fetching until there is no next cursor.
    print("Step 5 — Fetching prospects and writing CSV")

    all_rows = []
    cursor   = None
    page     = 1

    while True:
        params = {"limit": EXPORT_PAGE_SIZE}
        if cursor:
            params["cursor"] = cursor

        try:
            response = requests.get(
                f"{PROSPECTOR_URL}/v1/lists/{list_id}/prospects",
                params=params,
                headers=prospector_headers(),
                timeout=30,
            )
            result = response.json()
        except requests.exceptions.Timeout:
            print("\nError: The API took too long to respond.")
            sys.exit(1)
        except requests.exceptions.ConnectionError:
            print("\nError: Could not reach the Prospector API.")
            sys.exit(1)

        if not response.ok:
            print(f"\nError {response.status_code}: {result.get('message', 'Unknown error')}")
            sys.exit(1)

        items       = result["items"]
        next_cursor = result["nextCursor"]

        print(f"  Page {page}: {len(items)} prospects")

        for p in items:
            loc      = p.get("location") or {}
            company  = p.get("company")  or {}
            enriched = profile_by_email.get(p.get("workEmail") or "")
            all_rows.append({
                "id":                p.get("id"),
                "name":              p.get("name"),
                "first_name":        p.get("firstName"),
                "last_name":         p.get("lastName"),
                "title":             p.get("title"),
                "seniority":         enriched.get("seniority")    if enriched else None,
                "function":          enriched.get("function")     if enriched else None,
                "work_email":        p.get("workEmail"),
                "email_status":      p.get("emailStatus"),
                "direct_phone":      enriched.get("direct_phone") if enriched else None,
                "linkedin_url":      enriched.get("linkedin_url") if enriched else None,
                "location_city":     loc.get("city"),
                "location_state":    loc.get("state"),
                "location_country":  loc.get("country"),
                "company_name":      company.get("name"),
                "company_domain":    company.get("domain"),
                "company_industry":  company.get("industry"),
                "company_employees": company.get("employees"),
                "updated_at":        p.get("updatedAt"),
            })

        if not next_cursor:
            break

        cursor = next_cursor
        page  += 1

    # Write all rows to a CSV file.
    # newline="" prevents extra blank lines on Windows.
    # encoding="utf-8" handles names and characters from any language.
    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_FIELDS)
        writer.writeheader()
        writer.writerows(all_rows)

    print(f"\n  Total: {len(all_rows)} prospects")
    print(f"  Saved to: {OUTPUT_PATH}")

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(1)

    print("=" * 60)
    print("LeadIQ Full Pipeline")
    print("=" * 60)
    print()

    ids      = get_all_ids()
    profiles = enrich_profiles(ids)
    list_id  = create_list()
    add_prospects(list_id, profiles)
    fetch_and_export(list_id, profiles)

    print()
    print("Done.")


if __name__ == "__main__":
    main()
