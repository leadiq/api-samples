#!/usr/bin/env bash
# 08_verify_email.sh — Verify any email address without saving anything.
#
# This script sends one or more email addresses to the LeadIQ Prospector API
# and prints a deliverability verdict for each one.  Nothing is created or
# changed in LeadIQ — it is a read-only "pre-flight" check you can run before
# adding someone as a prospect.
#
# The verdict is one of four values:
#   Verified        — the mailbox exists and accepts mail
#   VerifiedLikely  — the address is very likely deliverable
#   Unverified      — the address could not be confirmed either way
#   Invalid         — the address will bounce; do not send to it
#
# This sample is standalone — it does not need the output of any earlier script.
#
# IMPORTANT: Each address checked costs 0.1 credit.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash rest/08_verify_email.sh
#
# Or pass the addresses to check on the command line:
#   bash rest/08_verify_email.sh jane@acme.com john@example.com

# ── Configuration ─────────────────────────────────────────────────────────────

PROSPECTOR_URL="https://prospector.leadiq.com"

if [[ -z "${LEADIQ_API_KEY:-}" ]]; then
  echo "Error: LEADIQ_API_KEY is not set."
  echo "  Run: export LEADIQ_API_KEY=your_secret_base64_key"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "Error: curl is required but not installed."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/../output/verified_emails.txt"

# The addresses to verify when none are passed on the command line.
# Replace these with the emails you want to check.
EMAILS_TO_VERIFY=(
  "someone@example.com"
)

# How long to pause between API calls (seconds) to avoid rate-limit errors.
DELAY_BETWEEN_CALLS=0.5

# ── Decode API key ─────────────────────────────────────────────────────────────

# The Prospector API needs the raw decoded version of the base64 API key.
PROSPECTOR_KEY=$(printf '%s' "$LEADIQ_API_KEY" | base64 -d 2>/dev/null \
  || printf '%s' "$LEADIQ_API_KEY" | base64 -D 2>/dev/null)

if [[ -z "$PROSPECTOR_KEY" ]]; then
  echo "Error: Could not decode the API key."
  exit 1
fi

# ── Helpers ────────────────────────────────────────────────────────────────────

# Verify one email address and print the verdict (or the reason it was skipped).
# Arguments: $1=email
verify_email() {
  local email="$1"
  local response http_code body

  # Send a GET request to /v1/verify-email?email=...
  # GET is used because this call only reads a verdict — it never changes
  # anything on the server.
  #
  # -G turns --data-urlencode into a query parameter, and --data-urlencode
  # escapes characters like "+" that would otherwise break the URL.
  response=$(curl -s --max-time 30 -G \
    "$PROSPECTOR_URL/v1/verify-email" \
    --data-urlencode "email=$email" \
    -H "X-API-Key: $PROSPECTOR_KEY" \
    -H "Content-Type: application/json" \
    -w "\n%{http_code}") || { echo "skipped (connection error)"; return; }

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  case "$http_code" in
    # The response body is a single field, e.g. {"status":"Verified"}
    200)
      local status
      status=$(echo "$body" | grep -oE '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
      echo "${status:-skipped (unexpected response)}"
      ;;
    400) echo "skipped (malformed email)" ;;
    401) echo "Error: Invalid API key."; exit 1 ;;
    502) echo "skipped (verification service unavailable)" ;;
    *)   echo "skipped (error $http_code)" ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Use the addresses from the command line if any were given, otherwise fall
# back to the EMAILS_TO_VERIFY list above.
if [[ $# -gt 0 ]]; then
  emails=("$@")
else
  emails=("${EMAILS_TO_VERIFY[@]}")
fi

total=${#emails[@]}

echo "Emails      : $total"
# bash only does whole-number maths, so we use awk for the 0.1 multiplication.
echo "Max credits : $(awk "BEGIN { printf \"%.1f\", $total * 0.1 }")"
echo ""

mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '%-50s %s\n' "Email" "Status" > "$OUTPUT_FILE"
printf '%s\n' "$(printf '%.0s-' {1..66})" >> "$OUTPUT_FILE"

checked=0
skipped=0
i=0

for email in "${emails[@]}"; do
  i=$((i + 1))
  printf "[%d/%d] %s ... " "$i" "$total" "$email"

  result=$(verify_email "$email")
  echo "$result"

  # The 401 branch prints an error and exits the subshell — stop here too.
  [[ "$result" == Error:* ]] && exit 1

  printf '%-50s %s\n' "$email" "$result" >> "$OUTPUT_FILE"

  if [[ "$result" == skipped* ]]; then
    skipped=$((skipped + 1))
  else
    checked=$((checked + 1))
  fi

  # Wait a moment before the next call to stay within rate limits.
  [[ $i -lt $total ]] && sleep "$DELAY_BETWEEN_CALLS"
done

echo ""
echo "Checked  : $checked"
echo "Skipped  : $skipped"
echo "Saved to : $OUTPUT_FILE"
