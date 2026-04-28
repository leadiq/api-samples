#!/usr/bin/env bash
# 02_advanced_search.sh — Find people using advanced filters.
#
# Searches for Sales professionals at VP, Director, and Manager level in
# New Hampshire, and saves their LeadIQ person IDs to
# output/advanced_search_ids.txt (one ID per line).
#
# IMPORTANT: Each page of results consumes one "Advanced Search (Page)" credit.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash graphql/02_advanced_search.sh

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

# How many results to fetch per API call.
# Each call counts as one credit regardless of page size.
PAGE_SIZE=25

# Output file — stored next to this script's output/ folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/../output/advanced_search_ids.txt"

# ── Query ──────────────────────────────────────────────────────────────────────

# We only ask for the id field here. Add more fields if you need them.
QUERY='query FlatAdvancedSearch($input: FlatSearchInput!) { flatAdvancedSearch(input: $input) { totalPeople people { id } } }'

# ── Helpers ────────────────────────────────────────────────────────────────────

# Send one page request to the API and print the raw JSON response.
# Arguments: $1 = skip (how many results to skip), $2 = limit (page size)
fetch_page() {
  local skip="$1"
  local limit="$2"

  # Build the JSON request body with the query and variables.
  local body
  body=$(printf '{"query":"%s","variables":{"input":{"contactFilter":{"roles":["Sales"],"seniorities":["VP","Director","Manager"],"locations":[{"areaLevel1":"New Hampshire","country":"United States"}]},"limit":%d,"skip":%d}}}' \
    "$QUERY" "$limit" "$skip")

  curl -s --max-time 30 \
    -X POST "$GRAPHQL_URL" \
    -H "Authorization: Basic $LEADIQ_API_KEY" \
    -H "Content-Type: application/json" \
    --data-raw "$body" || {
    echo "Error: Could not reach the API. Check your internet connection." >&2
    exit 1
  }
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Searching LeadIQ API..."
echo "  Roles       : Sales"
echo "  Seniorities : VP, Director, Manager"
echo "  Location    : New Hampshire, United States"
echo ""

# Make sure the output directory exists.
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Clear the output file before we start writing.
> "$OUTPUT_FILE"

skip=0
total=0
page=1

# Loop through pages until we have fetched all results.
# Each iteration is one API call and consumes one credit.
while true; do
  response=$(fetch_page "$skip" "$PAGE_SIZE")

  # Check for API errors.
  if echo "$response" | grep -q '"errors"'; then
    status_code=$(echo "$response" | grep -oE '"status":[0-9]+' | head -1 | grep -oE '[0-9]+')
    case "$status_code" in
      401) echo "Error: Invalid API key." >&2 ;;
      402) echo "Error: Insufficient credits." >&2 ;;
      429) echo "Error: Too many requests. Wait a moment and try again." >&2 ;;
      *)   echo "API error: $(echo "$response" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)" >&2 ;;
    esac
    exit 1
  fi

  # On the first page, read the total so we know when to stop.
  if [[ "$page" -eq 1 ]]; then
    total=$(echo "$response" | grep -oE '"totalPeople":[0-9]+' | grep -oE '[0-9]+$')
    if [[ "${total:-0}" -eq 0 ]]; then
      echo "No results found. Try adjusting the filters."
      exit 0
    fi
    echo "Found $total people. Fetching IDs ($PAGE_SIZE per page)..."
    echo ""
  fi

  # Extract person IDs from this page and append them to the output file.
  # Each ID looks like: "id":"PersonID-xxxxxxxx-..."
  echo "$response" | grep -oE '"id":"[^"]+"' | cut -d'"' -f4 >> "$OUTPUT_FILE"

  page_count=$(echo "$response" | grep -oE '"id":"[^"]+"' | wc -l | tr -d ' ')
  echo "  Page $page: $page_count IDs fetched"

  # Stop once we have fetched all pages.
  if (( skip + page_count >= total )); then
    break
  fi

  skip=$(( skip + PAGE_SIZE ))
  page=$(( page + 1 ))
done

id_count=$(wc -l < "$OUTPUT_FILE" | tr -d ' ')
echo ""
echo "Total: $id_count IDs retrieved."
echo "Saved to $OUTPUT_FILE"
