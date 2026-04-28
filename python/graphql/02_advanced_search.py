"""
02_advanced_search.py — Find people using advanced filters.

This sample searches for Sales professionals at VP, Director, and Manager
level located in New Hampshire, and prints their LeadIQ IDs.

IMPORTANT: Each page of results consumes one "Advanced Search (Page)" credit.

Run it with:
    docker compose run --rm leadiq python graphql/02_advanced_search.py
"""

import os
import sys
import requests

# ── Configuration ─────────────────────────────────────────────────────────────

GRAPHQL_URL = "https://api.leadiq.com/graphql"

API_KEY = os.getenv("LEADIQ_API_KEY")

# How many results to fetch per API call.
# Increasing this reduces the number of API calls (and credits used),
# but each call still counts as one credit regardless of page size.
PAGE_SIZE = 25

# ── Search filters ─────────────────────────────────────────────────────────────

# The seniority levels we want to include.
SENIORITIES = ["VP", "Director", "Manager"]

# The job function we want to filter by.
# Common values: "Sales", "Marketing", "Engineering", "Finance", "Operations"
ROLES = ["Sales"]

# The location we want to search in.
# areaLevel1 is the state or province (e.g. "New Hampshire", "California").
# country should match the full country name.
LOCATION = {
    "areaLevel1": "New Hampshire",
    "country": "United States",
}

# ── Query ──────────────────────────────────────────────────────────────────────

# We only request the `id` field — add more fields here if needed later.
# See the LeadIQ API docs for the full list of available person fields.
ADVANCED_SEARCH_QUERY = """
query FlatAdvancedSearch($input: FlatSearchInput!) {
  flatAdvancedSearch(input: $input) {
    totalPeople
    people {
      id
    }
  }
}
"""

# ── Helpers ────────────────────────────────────────────────────────────────────

def call_api(headers, variables):
    """Send one GraphQL request and return the parsed JSON, or exit on error."""
    try:
        response = requests.post(
            GRAPHQL_URL,
            json={"query": ADVANCED_SEARCH_QUERY, "variables": variables},
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

    print("Searching LeadIQ API...")
    print(f"  Roles      : {', '.join(ROLES)}")
    print(f"  Seniorities: {', '.join(SENIORITIES)}")
    print(f"  Location   : {LOCATION['areaLevel1']}, {LOCATION['country']}")
    print()

    all_ids = []
    skip = 0

    # Loop through pages until we have fetched all results.
    # Each iteration is one API call and consumes one credit.
    while True:
        variables = {
            "input": {
                "contactFilter": {
                    "roles": ROLES,
                    "seniorities": SENIORITIES,
                    "locations": [LOCATION],
                },
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
                print("No results found. Try adjusting the filters.")
                return
            print(f"Found {total} people. Fetching IDs ({PAGE_SIZE} per page)...\n")

        # Collect the IDs from this page.
        for person in people:
            all_ids.append(person["id"])

        # Stop when we have fetched everything.
        if skip + len(people) >= total:
            break

        skip += PAGE_SIZE

    # Print all collected IDs.
    print(f"{'#':<6} {'ID'}")
    print("-" * 50)
    for i, person_id in enumerate(all_ids, start=1):
        print(f"{i:<6} {person_id}")

    print(f"\nTotal: {len(all_ids)} IDs retrieved.")


if __name__ == "__main__":
    main()
