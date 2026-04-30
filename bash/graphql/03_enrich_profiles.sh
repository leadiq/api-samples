#!/usr/bin/env bash
# 03_enrich_profiles.sh — Enrich people with work email and direct phone.
#
# Reads the person IDs produced by 02_advanced_search.sh and calls
# searchPeople once per person to retrieve their work email and personal
# (direct) phone number.
#
# Results are saved to output/enriched_profiles.txt as a simple
# tab-separated file (one person per line).
#
# IMPORTANT: Each searchPeople call consumes one "Enrich" credit.
#   MAX_PEOPLE controls how many profiles are processed.
#   Start small to verify results before enriching in bulk.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash graphql/03_enrich_profiles.sh

# ── Configuration ─────────────────────────────────────────────────────────────

GRAPHQL_URL="https://api.leadiq.com/graphql"

if [[ -z "${LEADIQ_API_KEY:-}" ]]; then
  echo "Error: LEADIQ_API_KEY is not set."
  echo "  Run: export LEADIQ_API_KEY=your_secret_base64_key"
  exit 1
fi

if ! command -v curl &>/dev/null; then
  echo "Error: curl is required but not installed."
  echo "  Ubuntu/Debian : sudo apt install curl"
  echo "  Fedora        : sudo dnf install curl"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_FILE="$SCRIPT_DIR/../output/advanced_search_ids.txt"
OUTPUT_FILE="$SCRIPT_DIR/../output/enriched_profiles.txt"

# Maximum number of people to enrich in this run.
# ── IMPORTANT ──────────────────────────────────────────────────────────────────
# Each person enriched costs ONE Enrich credit from your plan.
# The default is 10 so you can try the script without burning many credits.
# Once you are happy with the results, raise this number to process more people.
MAX_PEOPLE=10

# Seconds to wait between API calls to avoid rate-limit errors.
DELAY_BETWEEN_CALLS=1

# ── Query ──────────────────────────────────────────────────────────────────────

# This query looks up a single person by their LeadIQ ID and returns:
#   id                          — confirms we got the right person
#   name.fullName / first / last — their display name and name parts
#   currentPositions[].title    — their job title
#   currentPositions[].companyInfo.name — the company they work at
#   currentPositions[].emails[] — work email addresses linked to that job
#   personalPhones[]            — direct (personal) phone numbers
#
# Note: The bash version of this script picks the first available email and
# phone it finds in the response. The Python and TypeScript versions apply
# confidence ranking to choose the best address — bash cannot do that
# without a JSON parser like jq, so results may occasionally differ.
QUERY='query SearchPeople($input: SearchPeopleInput!) { searchPeople(input: $input) { totalResults results { id linkedin { linkedinUrl } name { fullName first last } currentPositions { title seniority function companyInfo { name } emails { value status } } personalPhones { value verificationStatus } } } }'

# ── Helpers ────────────────────────────────────────────────────────────────────

# Call searchPeople for a single person ID and print the raw JSON response.
fetch_person() {
  local person_id="$1"

  local body
  # Use printf to safely embed the person ID into the JSON body.
  body=$(printf '{"query":"%s","variables":{"input":{"id":"%s"}}}' "$QUERY" "$person_id")

  curl -s --max-time 30 \
    -X POST "$GRAPHQL_URL" \
    -H "Authorization: Basic $LEADIQ_API_KEY" \
    -H "Content-Type: application/json" \
    --data-raw "$body" || {
    echo "Error: Could not reach the API. Check your internet connection." >&2
    exit 1
  }
}

# Extract a top-level string field from the JSON response.
# Works for any field that looks like  "fieldName":"some value"  in the JSON.
# If the field appears more than once, only the first occurrence is returned.
# Arguments: $1 = full JSON string, $2 = field name to look up
# Example:   extract_field "$response" "fullName"  →  Jane Smith
extract_field() {
  echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

# Extract the first work email address from the response.
# Email addresses appear in the JSON as  "value":"jane@example.com"  and are
# easy to spot because they always contain an @ sign.  We grab the first
# "value" field whose content contains @, which is a work email from
# currentPositions[].emails[].
#
# Limitation: this picks the first email address found anywhere in the
# response. It does not check the "status" field or rank by confidence the
# way the Python and TypeScript versions do.
extract_work_email() {
  local response="$1"
  echo "$response" | grep -oE '"value":"[^"@]*@[^"]+"' | head -1 | cut -d'"' -f4
}

# Extract the first personal (direct) phone number from the response.
# Phone numbers live under the "personalPhones" key, separate from work phones.
extract_personal_phone() {
  local response="$1"
  echo "$response" | grep -oE '"personalPhones":\[(\{[^]]*\})*' | \
    grep -oE '"value":"[^"]+"' | head -1 | cut -d'"' -f4
}

# ── Main ───────────────────────────────────────────────────────────────────────

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "Error: Input file not found: $INPUT_FILE"
  echo "Run 02_advanced_search.sh first to generate the IDs file."
  exit 1
fi

total_in_file=$(wc -l < "$INPUT_FILE" | tr -d ' ')

if [[ "$total_in_file" -eq 0 ]]; then
  echo "Error: The IDs file is empty. Run 02_advanced_search.sh first."
  exit 1
fi

# Read the first MAX_PEOPLE IDs into an array.
mapfile -t ids < <(head -n "$MAX_PEOPLE" "$INPUT_FILE")
total=${#ids[@]}

echo "Input file : $INPUT_FILE"
echo "Total IDs  : $total_in_file"
echo "Processing : $total (MAX_PEOPLE=$MAX_PEOPLE)"
echo "API calls  : $total  (one per person)"
echo "Max credits: $total Enrich credits"
echo ""

# Write the output file header.
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf "%-40s %-25s %-12s %-14s %-35s %-20s %-60s %s\n" \
  "ID" "Name" "Seniority" "Function" "Work Email" "Direct Phone" "LinkedIn URL" "Title" > "$OUTPUT_FILE"
printf '%s\n' "$(printf '%.0s-' {1..220})" >> "$OUTPUT_FILE"

enriched=0
not_found=0

for (( i=0; i<total; i++ )); do
  person_id="${ids[$i]}"
  printf "[%d/%d] %s ... " "$((i+1))" "$total" "$person_id"

  response=$(fetch_person "$person_id")

  # Check for API errors.
  if echo "$response" | grep -q '"errors"'; then
    status_code=$(echo "$response" | grep -oE '"status":[0-9]+' | head -1 | grep -oE '[0-9]+')
    case "$status_code" in
      401) echo "Error: Invalid API key." >&2; exit 1 ;;
      402) echo "Error: Insufficient credits." >&2; exit 1 ;;
      429) echo "Error: Too many requests. Wait a moment and try again." >&2; exit 1 ;;
      *)   echo "API error: $(echo "$response" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)" >&2; exit 1 ;;
    esac
  fi

  # Check if the API returned any results for this ID.
  result_count=$(echo "$response" | grep -oE '"totalResults":[0-9]+' | grep -oE '[0-9]+$')
  if [[ "${result_count:-0}" -eq 0 ]]; then
    echo "not found"
    (( not_found++ )) || true
    continue
  fi

  # Extract the fields we care about.
  full_name=$(extract_field   "$response" "fullName")
  title=$(extract_field       "$response" "title")
  seniority=$(extract_field   "$response" "seniority")
  function=$(extract_field    "$response" "function")
  work_email=$(extract_work_email  "$response")
  direct_phone=$(extract_personal_phone "$response")
  linkedin_url=$(echo "$response" | grep -oE '"linkedinUrl":"[^"]*"' | head -1 | cut -d'"' -f4)

  # Show a quick summary line for this person.
  email_indicator=$([ -n "$work_email"   ] && echo "✓ email" || echo "— email")
  phone_indicator=$([ -n "$direct_phone" ] && echo "✓ phone" || echo "— phone")
  echo "$email_indicator  $phone_indicator"

  # Append a row to the output file.
  printf "%-40s %-25s %-12s %-14s %-35s %-20s %-60s %s\n" \
    "$person_id" \
    "${full_name:----}" \
    "${seniority:----}" \
    "${function:----}" \
    "${work_email:----}" \
    "${direct_phone:----}" \
    "${linkedin_url:----}" \
    "${title:----}" >> "$OUTPUT_FILE"

  (( enriched++ )) || true

  # Pause before the next call to avoid hitting rate limits.
  if (( i < total - 1 )); then
    sleep "$DELAY_BETWEEN_CALLS"
  fi
done

echo ""
echo "Enriched  : $enriched"
echo "Not found : $not_found"
echo "Saved to  : $OUTPUT_FILE"
