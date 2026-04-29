"""
01_check_usage.py — Verify your API key and check your credit balance.

This is the simplest call you can make to the LeadIQ API.
It does NOT consume any credits.

Run it with:
    python graphql/01_check_usage.py
"""

import os
import sys
import requests

# ── Configuration ─────────────────────────────────────────────────────────────

# The API endpoint for all LeadIQ GraphQL queries.
GRAPHQL_URL = "https://api.leadiq.com/graphql"

# Your API key is loaded from the .env file — never hard-code it here.
API_KEY = os.getenv("LEADIQ_API_KEY")

# ── Query ──────────────────────────────────────────────────────────────────────

# This GraphQL query asks the API for your current plans and credit usage.
# You can paste it into any GraphQL client (e.g. Insomnia, Postman) to try it manually.
ACCOUNT_QUERY = """
query Account {
  account {
    plans {
      name
      product
      status
      nextBillingPeriod
    }
    dataHubPlan {
      name
      product
      status
      nextBillingPeriod
      available
      used
    }
    universalPlan {
      name
      product
      status
      nextBillingPeriod
      available
      used
    }
  }
}
"""

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    # Make sure the API key was loaded. If not, remind the user how to set it up.
    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(1)

    # Build the HTTP headers. LeadIQ uses HTTP Basic Auth — the API key
    # goes in the Authorization header as the username (no password needed).
    headers = {
        "Authorization": f"Basic {API_KEY}",
        "Content-Type": "application/json",
    }

    print("Connecting to LeadIQ API...", end=" ", flush=True)

    # Send the request to the API.
    try:
        response = requests.post(
            GRAPHQL_URL,
            json={"query": ACCOUNT_QUERY},
            headers=headers,
            timeout=30,
        )
        result = response.json()
    except requests.exceptions.Timeout:
        print("timed out.\nThe API took too long to respond. Please try again.")
        sys.exit(1)
    except requests.exceptions.ConnectionError:
        print("failed.\nCould not reach the API. Check your internet connection.")
        sys.exit(1)

    print("done.\n")

    # The LeadIQ API always returns HTTP 200, even for errors.
    # Real error information is inside the "errors" field of the response.
    if "errors" in result:
        error = result["errors"][0]
        status = error.get("extensions", {}).get("response", {}).get("status")

        if status == 401:
            print("Error: Invalid API key.")
            print("Make sure LEADIQ_API_KEY in your .env file is the correct Secret Base64 key.")
        elif status == 429:
            print("Error: Too many requests. Wait a moment and try again.")
        else:
            print(f"API error: {error.get('message', 'Unknown error')}")
        sys.exit(1)

    # Pull out the account data from the response.
    account = result["data"]["account"]

    # Print plan statuses as a table.
    col1, col2, col3 = 30, 14, 12
    print("Plans:")
    print(
        ("  " + "Name").ljust(col1 + 2) +
        "Product".ljust(col2) +
        "Status".ljust(col3) +
        "Next Billing Period"
    )
    print("  " + "-" * 74)
    for plan in account["plans"]:
        print(
            ("  " + plan["name"]).ljust(col1 + 2) +
            plan["product"].ljust(col2) +
            plan["status"].ljust(col3) +
            (plan["nextBillingPeriod"] or "N/A")
        )

    # Print credit usage for DataHub and Universal plans.
    credit_plans = [
        ("DataHub", account["dataHubPlan"]),
        ("Universal", account["universalPlan"]),
    ]
    for label, plan in credit_plans:
        if not plan:
            continue
        total = plan["available"] + plan["used"]
        print(f"\n{label} Plan — {plan['name']} ({plan['status']})")
        print(f"  Used      : {plan['used']}")
        print(f"  Available : {plan['available']}")
        print(f"  Total     : {total}")
        if plan["nextBillingPeriod"]:
            print(f"  Resets    : {plan['nextBillingPeriod']}")


if __name__ == "__main__":
    main()
