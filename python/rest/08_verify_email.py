"""
08_verify_email.py — Verify any email address without saving anything.

This sample sends one or more email addresses to the LeadIQ Prospector API
and prints a deliverability verdict for each one.  Nothing is created or
changed in LeadIQ — it is a read-only "pre-flight" check you can run before
adding someone as a prospect.

The verdict is one of four values:
  Verified        — the mailbox exists and accepts mail
  VerifiedLikely  — the address is very likely deliverable
  Unverified      — the address could not be confirmed either way
  Invalid         — the address will bounce; do not send to it

This sample is standalone — it does not need the output of any earlier script.

IMPORTANT: Each address checked costs 0.1 credit.

Run it with:
    python rest/08_verify_email.py

Or pass the addresses to check on the command line:
    python rest/08_verify_email.py jane@acme.com john@example.com
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


# The addresses to verify when none are passed on the command line.
# Replace these with the emails you want to check.
EMAILS_TO_VERIFY = [
    "someone@example.com",
]

# Where to save the verdicts.
OUTPUT_PATH = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "output", "verified_emails.json")
)

# How long to pause between each API call (in seconds).
# A short pause prevents sending requests too quickly and hitting rate limits.
DELAY_BETWEEN_CALLS = 0.5

# ── Helpers ────────────────────────────────────────────────────────────────────

def get_headers():
    return {
        "X-API-Key": _decode_key(API_KEY),
        "Content-Type": "application/json",
    }


def verify_email(email):
    # We send a GET request to /v1/verify-email?email=...
    # GET is used because this call only reads a verdict — it never changes
    # anything on the server.
    #
    # The API returns a single field:
    #   status — Verified, VerifiedLikely, Unverified, or Invalid
    try:
        response = requests.get(
            f"{PROSPECTOR_URL}/v1/verify-email",
            params={"email": email},
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
    # 400 means the address is malformed (e.g. missing the @ sign).
    if response.status_code == 400:
        return None, "malformed email"
    # 502 means the email verification service is temporarily unreachable.
    if response.status_code == 502:
        return None, "verification service unavailable"
    if not response.ok:
        return None, f"error {response.status_code}: {result.get('message', 'Unknown error')}"

    return result["status"], None

# ── Main ───────────────────────────────────────────────────────────────────────

def main():
    if not API_KEY:
        print("Error: LEADIQ_API_KEY is not set.")
        print("  1. Copy .env.example to .env")
        print("  2. Open .env and paste your Secret Base64 API key")
        sys.exit(1)

    # Use the addresses from the command line if any were given, otherwise
    # fall back to the EMAILS_TO_VERIFY list above.
    emails = sys.argv[1:] or EMAILS_TO_VERIFY
    total  = len(emails)

    print(f"Emails     : {total}")
    print(f"Max credits: {total * 0.1:.1f}")
    print()

    results = []   # one entry per address: the email and its verdict (or error)

    for i, email in enumerate(emails, start=1):
        print(f"[{i}/{total}] {email} ...", end=" ", flush=True)

        status, error = verify_email(email)

        if status is None:
            print(f"skipped ({error})")
            results.append({"email": email, "status": None, "error": error})
        else:
            print(status)
            results.append({"email": email, "status": status})

        # Wait a moment before the next call to stay within rate limits.
        if i < total:
            time.sleep(DELAY_BETWEEN_CALLS)

    # Count how many addresses landed in each verdict bucket.
    print()
    for status in ("Verified", "VerifiedLikely", "Unverified", "Invalid"):
        count = sum(1 for r in results if r["status"] == status)
        print(f"{status:<15}: {count}")
    print(f"{'Skipped':<15}: {sum(1 for r in results if r['status'] is None)}")

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w") as f:
        json.dump(results, f, indent=2)
    print(f"Saved to       : {OUTPUT_PATH}")


if __name__ == "__main__":
    main()
