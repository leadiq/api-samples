"""
03_enrich_profiles.py — Enrich people with work email and direct phone.

This sample reads the LeadIQ person IDs produced by 02_advanced_search.py,
calls searchPeople once per person to retrieve their work email and personal
(direct) phone number, and saves the enriched records to
output/enriched_profiles.json.

IMPORTANT: Each searchPeople call consumes one "Enrich" credit.
  MAX_PEOPLE below controls how many profiles are processed in one run.
  Start with a small number to verify your results before enriching in bulk.

Run it with:
    python graphql/03_enrich_profiles.py
"""

import json   # for reading the IDs file and writing the output file
import os     # for building file paths that work on any operating system
import sys    # for exiting the script when an unrecoverable error occurs
import time   # for adding a short pause between API calls
import requests  # for sending HTTP requests to the LeadIQ API

# ── Configuration ─────────────────────────────────────────────────────────────

# The URL every LeadIQ GraphQL request is sent to.
GRAPHQL_URL = "https://api.leadiq.com/graphql"

# Your API key is loaded from the .env file — never hard-code it here.
API_KEY = os.getenv("LEADIQ_API_KEY")

# Where to read the person IDs from.  This file is created by running
# 02_advanced_search.py first.
INPUT_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "output", "advanced_search_ids.json")
)

# Maximum number of people to enrich in this run.
# ── IMPORTANT ──────────────────────────────────────────────────────────────────
# Each person enriched costs ONE Enrich credit from your plan.
# The default is 10 so you can try the script without burning many credits.
# Once you are happy with the results, raise this number to process more people.
MAX_PEOPLE = 10

# How long to wait (in seconds) between API calls.
# This keeps the script from sending requests too fast and hitting rate limits.
DELAY_BETWEEN_CALLS = 0.5

# ── Query ──────────────────────────────────────────────────────────────────────

# This is the GraphQL query we send to the API.
#
# GraphQL lets you ask for exactly the fields you need — nothing more, nothing
# less.  Think of it like a very precise form you fill out to describe what data
# you want back.
#
# searchPeople looks up ONE person by their LeadIQ ID and returns their profile.
# The "input" argument tells the API which person to look up.
#
# Field guide:
#   id              — the unique LeadIQ identifier for this person
#   name            — first, last, and full name
#   currentPositions — their current job(s), each containing:
#       title           — job title
#       companyInfo     — basic company details (name only here)
#       emails          — work email addresses for this job
#                         (value = the address, status = how confident we are)
#   personalPhones  — direct / personal phone numbers (mobile, landline, etc.)
#                     (value = the number, type = what kind, status = confidence)
SEARCH_PEOPLE_QUERY = """
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
"""

# ── Helpers ────────────────────────────────────────────────────────────────────

def call_api(headers, person_id):
    """Send a searchPeople request for one person and return the results list.

    Returns a list of matching PersonRecord objects (usually just one).
    Exits the script if the API returns an error we cannot recover from.
    """
    # Build the variables object that fills the $input placeholder in the query.
    # "id" is the LeadIQ person ID we want to enrich.
    variables = {"input": {"id": person_id}}

    try:
        response = requests.post(
            GRAPHQL_URL,
            json={"query": SEARCH_PEOPLE_QUERY, "variables": variables},
            headers=headers,
            timeout=30,  # give up if the server doesn't respond within 30 seconds
        )
        result = response.json()
    except requests.exceptions.Timeout:
        print("Error: The API took too long to respond. Please try again.")
        sys.exit(1)
    except requests.exceptions.ConnectionError:
        print("Error: Could not reach the API. Check your internet connection.")
        sys.exit(1)

    # The LeadIQ API always returns HTTP 200 even for errors.
    # Real error details are inside the "errors" field of the JSON response.
    if "errors" in result:
        error = result["errors"][0]
        # The HTTP-style status code is nested inside the error extensions.
        status = error.get("extensions", {}).get("response", {}).get("status")

        if status == 401:
            print("Error: Invalid API key.")
            print("Make sure LEADIQ_API_KEY in your .env file is the correct Secret Base64 key.")
        elif status == 402:
            print("Error: Insufficient credits.")
        elif status == 429:
            print("Error: Too many requests. Wait a moment and try again.")
        else:
            print(f"API error: {error.get('message', 'Unknown error')}")
        sys.exit(1)

    # Return the list of matched person records (normally one item).
    return result["data"]["searchPeople"]["results"]


def pick_work_email(current_positions):
    """Return the best work email address found across all current positions.

    Work emails are stored inside each job position (currentPositions), so we
    look through every position and collect all available addresses.

    The API may return several email addresses with different confidence levels:
      Verified       — confirmed accurate
      VerifiedLikely — very likely accurate
      Unverified     — found but not yet confirmed
      Invalid        — known to be wrong (skipped)
      Suppressed     — opted out of contact (skipped)

    We pick the most confident address and ignore Invalid / Suppressed ones.
    """
    # Statuses we do not want to return.
    skip_statuses = {"Invalid", "Suppressed"}

    # Map each status to a number so we can sort — lower number = better.
    priority = {"Verified": 0, "VerifiedLikely": 1, "Unverified": 2}

    # Gather every usable work email from all current positions.
    candidates = []
    for position in (current_positions or []):
        for email in (position.get("emails") or []):
            if email.get("status") not in skip_statuses:
                candidates.append(email)

    if not candidates:
        return None  # no work email found for this person

    # Sort by confidence and return the best one.
    candidates.sort(key=lambda e: priority.get(e.get("status") or "", 99))
    return candidates[0]["value"]


def pick_personal_phone(personal_phones):
    phones = personal_phones or []
    return phones[0]["value"] if phones else None


def extract_profile(person):
    """Pull the fields we care about out of a raw PersonRecord and return a
    clean, flat dictionary that is easy to read and save to JSON.
    """
    name = person.get("name") or {}
    positions = person.get("currentPositions") or []

    # Use the first current position for title and company.
    # Most people have only one current job, but some may have more.
    current = positions[0] if positions else {}
    company_info = current.get("companyInfo") or {}

    linkedin = person.get("linkedin") or {}
    return {
        "id":           person.get("id"),
        "full_name":    name.get("fullName"),
        "first_name":   name.get("first"),
        "last_name":    name.get("last"),
        "title":        current.get("title"),
        "seniority":    current.get("seniority"),
        "function":     current.get("function"),
        "company":      company_info.get("name"),
        "work_email":   pick_work_email(positions),
        "direct_phone": pick_personal_phone(person.get("personalPhones")),
        "linkedin_url": linkedin.get("linkedinUrl"),
    }

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    # Verify the API key is available before doing anything else.
    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(1)

    # Make sure the IDs file from the previous sample exists.
    if not os.path.exists(INPUT_PATH):
        print(f"Error: Input file not found: {INPUT_PATH}")
        print("Run 02_advanced_search.py first to generate the IDs file.")
        sys.exit(1)

    # Load the list of person IDs.
    with open(INPUT_PATH) as f:
        all_ids = json.load(f)

    if not all_ids:
        print("Error: The IDs file is empty. Run 02_advanced_search.py first.")
        sys.exit(1)

    # Slice the list so we only process up to MAX_PEOPLE entries.
    # This protects against accidentally spending hundreds of credits in one run.
    ids_to_process = all_ids[:MAX_PEOPLE]
    total = len(ids_to_process)

    # Print a summary of what is about to happen before spending any credits.
    print(f"Input file : {INPUT_PATH}")
    print(f"Total IDs  : {len(all_ids)}")
    print(f"Processing : {total} (MAX_PEOPLE={MAX_PEOPLE})")
    print(f"API calls  : {total}  (one per person)")
    print(f"Max credits: {total} Enrich credits")
    print()

    # Build the HTTP headers that authenticate every request.
    # LeadIQ uses HTTP Basic Auth — the API key goes in as the username.
    headers = {
        "Authorization": f"Basic {API_KEY}",
        "Content-Type": "application/json",
    }

    enriched = []   # profiles that were found and enriched successfully
    not_found = 0   # IDs that returned no results from the API

    # Loop through each ID and enrich one person at a time.
    # The API does not support looking up multiple IDs in a single call.
    for i, person_id in enumerate(ids_to_process, start=1):
        print(f"[{i}/{total}] {person_id} ...", end=" ", flush=True)

        results = call_api(headers, person_id)

        if not results:
            # The API returned no match for this ID (e.g. profile was deleted).
            print("not found")
            not_found += 1
        else:
            # results[0] is the best match for the ID we sent.
            profile = extract_profile(results[0])
            enriched.append(profile)

            # Show a quick indicator so you can see enrichment quality in real time.
            email_indicator = "✓ email" if profile["work_email"] else "— email"
            phone_indicator = "✓ phone" if profile["direct_phone"] else "— phone"
            print(f"{email_indicator}  {phone_indicator}")

        # Wait a short moment before the next call to avoid rate-limit errors.
        if i < total:
            time.sleep(DELAY_BETWEEN_CALLS)

    # ── Print a summary table ──────────────────────────────────────────────────

    print()
    print(f"{'#':<5} {'Name':<28} {'Seniority':<12} {'Function':<14} {'Title':<30} {'Company':<24} {'Work Email':<32} {'Direct Phone'}")
    print("-" * 160)
    for i, p in enumerate(enriched, start=1):
        name = (
            p["full_name"]
            or f"{p['first_name'] or ''} {p['last_name'] or ''}".strip()
            or "—"
        )
        print(
            f"{i:<5} "
            f"{name:<28} "
            f"{(p['seniority'] or '—'):<12} "
            f"{(p['function'] or '—'):<14} "
            f"{(p['title'] or '—'):<30} "
            f"{(p['company'] or '—'):<24} "
            f"{(p['work_email'] or '—'):<32} "
            f"{p['direct_phone'] or '—'}"
        )

    print()
    print(f"Enriched  : {len(enriched)}")
    print(f"Not found : {not_found}")

    # ── Save results to JSON ───────────────────────────────────────────────────

    # Build the output path relative to this script's location so the script
    # works no matter where on your computer you have cloned the repository.
    output_path = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "output", "enriched_profiles.json")
    )
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    with open(output_path, "w") as f:
        json.dump(enriched, f, indent=2)

    print(f"Saved to  : {output_path}")


if __name__ == "__main__":
    main()
