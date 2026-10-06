"""
09_verify_prospect_emails.py — Re-verify the emails of saved prospects.

This sample reads output/added_prospects.json (written by
05_add_prospects_to_list.py) and asks the LeadIQ Prospector API to verify the
work email stored on each prospect.  The new verdict is saved on the prospect
in LeadIQ, so the email status you see in the app stays up to date.

The prospect's email address itself is NEVER changed — this checks the address
that is already there, it does not look for a new one.  Prospects without an
email are skipped.

The verdict is one of four values:
  Verified        — the mailbox exists and accepts mail
  VerifiedLikely  — the address is very likely deliverable
  Unverified      — the address could not be confirmed either way
  Invalid         — the address will bounce; do not send to it

IMPORTANT: Each prospect verified costs 0.1 credit.
MAX_PROSPECTS below controls how many prospects are processed in one run.

Run it with:
    python rest/09_verify_prospect_emails.py

Or pass specific prospect IDs on the command line:
    python rest/09_verify_prospect_emails.py 6627e3f1a2b3c4d5e6f70001
"""

import base64
import json
import os
import sys
import time
import requests

# ── Configuration ─────────────────────────────────────────────────────────────

# The base URL for every Prospector API request.
PROSPECTOR_URL = "https://prospector.leadiq.com"

# Your API key is loaded from the .env file — never hard-code it here.
API_KEY = os.getenv("LEADIQ_API_KEY")


def _decode_key(key):
    # The .env file stores the "Secret Base64" key — a base64-encoded string.
    # The Prospector API needs the raw decoded version in the X-API-Key header.
    try:
        return base64.b64decode(key).decode("utf-8")
    except Exception:
        return key


# Path to the prospects written by 05_add_prospects_to_list.py.
PROSPECTS_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "output", "added_prospects.json")
)

# Where to save the verdicts and updated prospect records.
OUTPUT_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "output", "verified_prospects.json")
)

# Safety cap on how many prospects to verify in one run (each costs 0.1 credit).
MAX_PROSPECTS = 10

# How long to pause between each API call (in seconds).
# A short pause prevents sending requests too quickly and hitting rate limits.
DELAY_BETWEEN_CALLS = 0.5

# ── Helpers ────────────────────────────────────────────────────────────────────

def get_headers():
    return {
        "X-API-Key": _decode_key(API_KEY),
        "Content-Type": "application/json",
    }


def verify_prospect_email(prospect_id):
    # We send a POST request to /v1/prospects/{prospectId}/verify-email.
    # POST is used (rather than GET) because this call changes data: the new
    # email status is saved on the prospect.  No request body is needed — the
    # API verifies whatever email is already stored on the prospect.
    #
    # The API returns:
    #   status   — Verified, VerifiedLikely, Unverified, or Invalid
    #   prospect — the full prospect record, with emailStatus already updated
    try:
        response = requests.post(
            f"{PROSPECTOR_URL}/v1/prospects/{prospect_id}/verify-email",
            headers=get_headers(),
            timeout=30,
        )
        result = response.json()
    except requests.exceptions.Timeout:
        return None, "timeout"
    except requests.exceptions.ConnectionError:
        return None, "connection error"

    # 401 means our API key is wrong — no point continuing.
    if response.status_code == 401:
        print("Error: Invalid API key.")
        print("Make sure LEADIQ_API_KEY in your .env file is correct.")
        sys.exit(1)
    # 404 means the prospect was deleted or belongs to another account.
    if response.status_code == 404:
        return None, "prospect not found"
    # 409 means the prospect has no email on record, so there is nothing to verify.
    if response.status_code == 409:
        return None, "no email to verify"
    # 502 means the email verification service is temporarily unreachable.
    if response.status_code == 502:
        return None, "verification service unavailable"
    if not response.ok:
        return None, f"error {response.status_code}: {result.get('message', 'Unknown error')}"

    return result, None

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(1)

    if sys.argv[1:]:
        # Prospect IDs were passed on the command line — we don't know their
        # names or emails yet, so the API response will fill those in.
        prospects = [{"id": prospect_id} for prospect_id in sys.argv[1:]]
    else:
        if not os.path.exists(PROSPECTS_PATH):
            print(f"Error: Prospects file not found: {PROSPECTS_PATH}")
            print("Run 05_add_prospects_to_list.py first, or pass prospect IDs on the command line.")
            sys.exit(1)

        with open(PROSPECTS_PATH) as f:
            prospects = json.load(f)

        # Skip prospects without an email before calling the API — the API
        # would reject them with a 409 anyway.
        prospects = [p for p in prospects if p.get("workEmail")]

        if not prospects:
            print("Error: None of the prospects in the file have a work email to verify.")
            sys.exit(1)

    # Slice the list so we only process up to MAX_PROSPECTS entries.
    prospects = prospects[:MAX_PROSPECTS]
    total     = len(prospects)

    print(f"Prospects  : {total} (MAX_PROSPECTS={MAX_PROSPECTS})")
    print(f"Max credits: {total * 0.1:.1f}")
    print()

    verified = []   # prospects whose email was verified, with the new verdict
    skipped  = []   # prospects that could not be verified, with the reason why

    for i, prospect in enumerate(prospects, start=1):
        name = prospect.get("name") or prospect["id"]
        print(f"[{i}/{total}] {name} ...", end=" ", flush=True)

        result, reason = verify_prospect_email(prospect["id"])

        if result is None:
            print(f"skipped ({reason})")
            skipped.append({"id": prospect["id"], "reason": reason})
        else:
            # Show the status before and after so it is clear what changed.
            updated = result["prospect"]
            before  = prospect.get("emailStatus") or "—"
            print(f"{updated.get('workEmail')}  {before} → {result['status']}")
            verified.append({"status": result["status"], "prospect": updated})

        # Wait a moment before the next call to stay within rate limits.
        if i < total:
            time.sleep(DELAY_BETWEEN_CALLS)

    print()
    print(f"Verified : {len(verified)}")
    print(f"Skipped  : {len(skipped)}")

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w") as f:
        json.dump(verified, f, indent=2)
    print(f"Saved to : {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
