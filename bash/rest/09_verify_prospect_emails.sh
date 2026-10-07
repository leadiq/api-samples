#!/usr/bin/env bash
# 09_verify_prospect_emails.sh — Re-verify the emails of saved prospects.
#
# This script reads output/prospects.csv (written by 06_export_list_to_csv.sh)
# and asks the LeadIQ Prospector API to verify the work email stored on each
# prospect.  The new verdict is saved on the prospect in LeadIQ, so the email
# status you see in the app stays up to date.
#
# The prospect's email address itself is NEVER changed — this checks the
# address that is already there, it does not look for a new one.  Prospects
# without an email are skipped.
#
# The verdict is one of four values:
#   Verified        — the mailbox exists and accepts mail
#   VerifiedLikely  — the address is very likely deliverable
#   Unverified      — the address could not be confirmed either way
#   Invalid         — the address will bounce; do not send to it
#
# IMPORTANT: Each prospect verified costs 0.1 credit.
# MAX_PROSPECTS below controls how many prospects are processed in one run.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash rest/09_verify_prospect_emails.sh
#
# Or pass specific prospect IDs on the command line:
#   bash rest/09_verify_prospect_emails.sh 6627e3f1a2b3c4d5e6f70001

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
PROSPECTS_CSV="$SCRIPT_DIR/../output/prospects.csv"
OUTPUT_FILE="$SCRIPT_DIR/../output/verified_prospects.txt"

# Safety cap on how many prospects to verify in one run (each costs 0.1 credit).
MAX_PROSPECTS=10

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

# ── Load inputs ────────────────────────────────────────────────────────────────

# Each entry is "id|name|email|status".  Name, email and status are only known
# when we read from the CSV; command-line IDs leave them empty.
prospects=()

if [[ $# -gt 0 ]]; then
  for id in "$@"; do
    prospects+=("$id|||")
  done
else
  if [[ ! -f "$PROSPECTS_CSV" ]]; then
    echo "Error: Prospects file not found: $PROSPECTS_CSV"
    echo "Run 06_export_list_to_csv.sh first, or pass prospect IDs on the command line."
    exit 1
  fi

  # 06_export_list_to_csv.sh quotes every value, so each row looks like:
  #   "id","name","first_name","last_name","title","work_email","email_status",...
  # Splitting on "," (quote-comma-quote) gives us the columns we need:
  #   $1=id  $2=name  $6=work_email  $7=email_status
  # We skip the header row and rows without a work email — the API would
  # reject those with a 409 anyway.
  while IFS= read -r entry; do
    prospects+=("$entry")
  done < <(awk -F'","' 'NR > 1 && $6 != "" {
    sub(/^"/, "", $1)
    print $1 "|" $2 "|" $6 "|" $7
  }' "$PROSPECTS_CSV")

  if [[ ${#prospects[@]} -eq 0 ]]; then
    echo "Error: None of the prospects in $PROSPECTS_CSV have a work email to verify."
    exit 1
  fi
fi

# Only process up to MAX_PROSPECTS entries.
prospects=("${prospects[@]:0:$MAX_PROSPECTS}")
total=${#prospects[@]}

# ── Helpers ────────────────────────────────────────────────────────────────────

# Verify the email stored on one prospect.
# Prints "<work email>|<new status>" on success, or "skipped (<reason>)".
# Arguments: $1=prospect_id
verify_prospect_email() {
  local prospect_id="$1"
  local response http_code body email status

  # Send a POST request to /v1/prospects/{prospectId}/verify-email.
  # POST is used (rather than GET) because this call changes data: the new
  # email status is saved on the prospect.  No request body is needed — the
  # API verifies whatever email is already stored on the prospect.
  response=$(curl -s --max-time 30 \
    -X POST "$PROSPECTOR_URL/v1/prospects/$prospect_id/verify-email" \
    -H "X-API-Key: $PROSPECTOR_KEY" \
    -H "Content-Type: application/json" \
    -w "\n%{http_code}") || { echo "skipped (connection error)"; return; }

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  case "$http_code" in
    200)
      # The response contains the verdict and the updated prospect record.
      # We read the verdict from the prospect's "emailStatus" field — it holds
      # the same value as the top-level "status", but the name is unique in
      # the response, so a simple grep cannot pick up the wrong field.
      email=$(echo "$body" | grep -oE '"workEmail"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
      status=$(echo "$body" | grep -oE '"emailStatus"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
      echo "$email|$status"
      ;;
    400) echo "skipped (malformed prospect ID)" ;;
    401) echo "Error: Invalid API key."; exit 1 ;;
    404) echo "skipped (prospect not found)" ;;
    409) echo "skipped (no email to verify)" ;;
    502) echo "skipped (verification service unavailable)" ;;
    *)   echo "skipped (error $http_code)" ;;
  esac
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Prospects   : $total (MAX_PROSPECTS=$MAX_PROSPECTS)"
# bash only does whole-number maths, so we use awk for the 0.1 multiplication.
echo "Max credits : $(awk "BEGIN { printf \"%.1f\", $total * 0.1 }")"
echo ""

mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '%-26s %-40s %s\n' "ID" "Work Email" "Status" > "$OUTPUT_FILE"
printf '%s\n' "$(printf '%.0s-' {1..82})" >> "$OUTPUT_FILE"

verified=0
skipped=0
i=0

for entry in "${prospects[@]}"; do
  i=$((i + 1))
  IFS='|' read -r prospect_id name _ before <<< "$entry"

  printf "[%d/%d] %s ... " "$i" "$total" "${name:-$prospect_id}"

  result=$(verify_prospect_email "$prospect_id")

  # The 401 branch prints an error and exits the subshell — stop here too.
  if [[ "$result" == Error:* ]]; then
    echo "$result"
    exit 1
  fi

  if [[ "$result" == skipped* ]]; then
    echo "$result"
    skipped=$((skipped + 1))
  else
    IFS='|' read -r email status <<< "$result"
    # Show the status before and after so it is clear what changed.
    echo "$email  ${before:-—} → $status"
    printf '%-26s %-40s %s\n' "$prospect_id" "$email" "$status" >> "$OUTPUT_FILE"
    verified=$((verified + 1))
  fi

  # Wait a moment before the next call to stay within rate limits.
  [[ $i -lt $total ]] && sleep "$DELAY_BETWEEN_CALLS"
done

echo ""
echo "Verified : $verified"
echo "Skipped  : $skipped"
echo "Saved to : $OUTPUT_FILE"
