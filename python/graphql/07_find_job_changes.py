"""
07_find_job_changes.py — Find people who recently changed jobs or were promoted.

This sample uses the same `flatAdvancedSearch` query as 02_advanced_search.py,
but adds the job-change filters so the results are scoped to people who recently
moved companies (or were promoted in place). For each match it prints the
job-change transition: previous position → current position.

Job changes are a strong buying trigger — a champion who just moved into a new
role is often the best time to reach out.

IMPORTANT: Each page of results consumes one "Advanced Search (Page)" credit,
exactly like 02_advanced_search.py. This sample requests profile-level fields
only (no company firmographic unlock), so it stays at the cheapest tier.

Run it with:
    python graphql/07_find_job_changes.py
"""

import json
import os
import sys
from datetime import datetime, timezone

import requests

# ── Configuration ─────────────────────────────────────────────────────────────

GRAPHQL_URL = "https://api.leadiq.com/graphql"

API_KEY = os.getenv("LEADIQ_API_KEY")

# How many results to fetch per API call.
# Each call counts as one credit regardless of page size.
PAGE_SIZE = 25

# Safety cap on the total number of people to collect across all pages.
MAX_PEOPLE = 50

# ── Search filters ─────────────────────────────────────────────────────────────

# Which kind of change to look for:
#   "JobChange"   — the person MOVED to a different company
#   "TitleChange" — the person was PROMOTED in place (same company, new title)
# Use both (or an empty list) to include either kind.
JOB_CHANGE_TYPES = ["JobChange"]

# Optional: only include changes that started after this date.
# Set to None to include changes of any age. The API expects Unix milliseconds.
# Example below: changes that started in the last 90 days.
STARTED_AFTER_MS = int(
    (datetime.now(timezone.utc).timestamp() - 90 * 24 * 60 * 60) * 1000
)

# Filters describing the person's CURRENT role (after the change).
# Here: VPs in Sales who now work at a software company.
SENIORITIES = ["VP"]
ROLES = ["Sales"]
CURRENT_INDUSTRIES = ["Computer Software"]

# ── Query ──────────────────────────────────────────────────────────────────────

# flatAdvancedSearch is the same field used by 02_advanced_search.py. The
# difference is the input (which now carries jobChangeFilter) and the selection
# set, which asks for the personJobChange transition.
#
# We request the company `id` and `name` on both positions — these are part of
# the free profile tier. Firmographics (domain, industry, employeeCount) would
# require unlocking the company tier and cost extra, so we leave them out here.
FIND_JOB_CHANGES_QUERY = """
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
"""

# ── Helpers ────────────────────────────────────────────────────────────────────

def call_api(headers, variables):
    """Send one GraphQL request and return the parsed payload, or exit on error."""
    try:
        response = requests.post(
            GRAPHQL_URL,
            json={"query": FIND_JOB_CHANGES_QUERY, "variables": variables},
            headers=headers,
            timeout=30,
        )
        result = response.json()
    except requests.exceptions.Timeout:
        print("Error: The API took too long to respond. Please try again.")
        sys.exit(1)
    except requests.exceptions.ConnectionError:
        print("Error: Could not reach the API. Check your internet connection.")
        sys.exit(1)

    if "errors" in result:
        error = result["errors"][0]
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

    return result["data"]["flatAdvancedSearch"]


def format_started_at(value):
    """The API returns startedAt as Unix milliseconds. Render it as YYYY-MM-DD."""
    if value is None:
        return "—"
    try:
        return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
    except (ValueError, TypeError, OSError):
        # If the API ever returns a date string instead of a number, show it as-is.
        return str(value)


def company_name(position):
    """Pull the company name out of a position block, tolerating missing data."""
    if not position:
        return "—"
    company = position.get("company") or {}
    return company.get("name") or "—"

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(1)

    headers = {
        "Authorization": f"Basic {API_KEY}",
        "Content-Type": "application/json",
    }

    print("Searching LeadIQ for recent job changes...")
    print(f"  Change type      : {', '.join(JOB_CHANGE_TYPES) or 'any'}")
    print(f"  Current role     : {', '.join(ROLES)}")
    print(f"  Current seniority: {', '.join(SENIORITIES)}")
    print(f"  Current industry : {', '.join(CURRENT_INDUSTRIES)}")
    if STARTED_AFTER_MS is not None:
        print(f"  Changed since    : {format_started_at(STARTED_AFTER_MS)}")
    print()

    # Build the job-change filter. jobChangeTypes is required by the API; an
    # empty list means "both JobChange and TitleChange".
    job_change_filter = {"jobChangeTypes": JOB_CHANGE_TYPES}
    if STARTED_AFTER_MS is not None:
        job_change_filter["startedAfter"] = STARTED_AFTER_MS

    all_people = []
    skip = 0

    # Loop through pages until we have fetched all results.
    # Each iteration is one API call and consumes one credit.
    while True:
        variables = {
            "input": {
                "jobChangeFilter": job_change_filter,
                "contactFilter": {
                    "roles": ROLES,
                    "seniorities": SENIORITIES,
                },
                "companyFilter": {
                    "industries": CURRENT_INDUSTRIES,
                },
                # Show the most recent changes first.
                "sortContactsBy": ["JobChangeStartedAtDesc"],
                "limit": PAGE_SIZE,
                "skip": skip,
            }
        }

        data = call_api(headers, variables)

        total = data["totalPeople"]
        people = data["people"]

        # On the first page, show the total so the user knows what to expect.
        if skip == 0:
            if total == 0:
                print("No job changes found. Try widening the filters.")
                return
            target = min(total, MAX_PEOPLE)
            print(f"Found {total} job changes. Fetching up to {target} ({PAGE_SIZE} per page)...\n")

        # Collect people from this page, stopping at MAX_PEOPLE.
        for person in people:
            if len(all_people) >= MAX_PEOPLE:
                break
            all_people.append(person)

        # Stop when we have fetched everything (or hit the safety cap).
        if len(all_people) >= MAX_PEOPLE or skip + len(people) >= total:
            break

        skip += PAGE_SIZE

    # Print the transitions: previous role → current role.
    for i, person in enumerate(all_people, start=1):
        change = person.get("personJobChange") or {}
        previous = change.get("previousPosition") or {}
        current = change.get("currentPosition") or {}

        change_type = change.get("jobChangeType") or "—"
        started = format_started_at(change.get("startedAt"))

        print(f"{i}. {person.get('name') or '(unknown)'}  [{change_type} · {started}]")
        print(f"     from: {previous.get('title') or '—'} @ {company_name(previous)}")
        print(f"       to: {current.get('title') or '—'} @ {company_name(current)}")
        if person.get("linkedinUrl"):
            print(f"     {person['linkedinUrl']}")
        print()

    print(f"Total: {len(all_people)} job changes retrieved.")

    # Save the raw people list to output/job_changes.json for use elsewhere.
    output_path = os.path.join(os.path.dirname(__file__), "..", "output", "job_changes.json")
    output_path = os.path.normpath(output_path)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(all_people, f, indent=2)
    print(f"Saved to {output_path}")


if __name__ == "__main__":
    main()
