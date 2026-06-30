#!/usr/bin/env bash
# 07_find_job_changes.sh — Find people who recently changed jobs or were promoted.
#
# This script uses the same flatAdvancedSearch query as 02_advanced_search.sh,
# but adds the job-change filters so the results are scoped to people who recently
# moved companies (or were promoted in place). For each match it prints the
# job-change transition: previous position → current position.
#
# Job changes are a strong buying trigger — a champion who just moved into a new
# role is often the best time to reach out.
#
# IMPORTANT: Each page of results consumes one "Advanced Search (Page)" credit,
# exactly like 02_advanced_search.sh. This script requests profile-level fields
# only (no company firmographic unlock), so it stays at the cheapest tier.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash graphql/07_find_job_changes.sh

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

# Safety cap on the total number of people to collect across all pages.
MAX_PEOPLE=50

# Which kind of change to look for:
#   "JobChange"   — the person MOVED to a different company
#   "TitleChange" — the person was PROMOTED in place (same company, new title)
# An empty list ([]) means "both kinds". Below we pass it inside the JSON body.
JOB_CHANGE_TYPES='["JobChange"]'

# Only include changes that started in the last 90 days (Unix milliseconds).
# Set STARTED_AFTER_MS="" to include changes of any age.
STARTED_AFTER_MS=$(( ($(date +%s) - 90 * 24 * 60 * 60) * 1000 ))

# Output file — stored next to this script's output/ folder.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="$SCRIPT_DIR/../output/job_changes.txt"

# ── Query ──────────────────────────────────────────────────────────────────────

# flatAdvancedSearch is the same field used by 02_advanced_search.sh. The
# difference is the input (which now carries jobChangeFilter) and the selection
# set, which asks for the personJobChange transition.
#
# We request the company name on both positions — that is part of the free
# profile tier. Firmographics (domain, industry, employeeCount) would require
# unlocking the company tier and cost extra, so we leave them out here.
QUERY='query FindJobChanges($input: FlatSearchInput!) { flatAdvancedSearch(input: $input) { totalPeople people { id name linkedinUrl personJobChange { jobChangeType startedAt previousPosition { title company { id name } } currentPosition { title role seniority company { id name } } } } } }'

# ── Helpers ────────────────────────────────────────────────────────────────────

# Send one page request to the API and print the raw JSON response.
# Arguments: $1 = skip (how many results to skip), $2 = limit (page size)
fetch_page() {
  local skip="$1"
  local limit="$2"

  # Build the jobChangeFilter, optionally including the startedAfter date.
  local job_change_filter
  if [[ -n "$STARTED_AFTER_MS" ]]; then
    job_change_filter=$(printf '{"jobChangeTypes":%s,"startedAfter":%s}' "$JOB_CHANGE_TYPES" "$STARTED_AFTER_MS")
  else
    job_change_filter=$(printf '{"jobChangeTypes":%s}' "$JOB_CHANGE_TYPES")
  fi

  # Build the full JSON request body with the query and variables.
  local body
  body=$(printf '{"query":"%s","variables":{"input":{"jobChangeFilter":%s,"contactFilter":{"roles":["Sales"],"seniorities":["VP"]},"companyFilter":{"industries":["Computer Software"]},"sortContactsBy":["JobChangeStartedAtDesc"],"limit":%d,"skip":%d}}}' \
    "$QUERY" "$job_change_filter" "$limit" "$skip")

  curl -s --max-time 30 \
    -X POST "$GRAPHQL_URL" \
    -H "Authorization: Basic $LEADIQ_API_KEY" \
    -H "Content-Type: application/json" \
    --data-raw "$body" || {
    echo "Error: Could not reach the API. Check your internet connection." >&2
    exit 1
  }
}

# Return the Nth occurrence of a "field":"value" string from a JSON chunk.
# Arguments: $1 = json chunk, $2 = field name, $3 = which occurrence (1-based)
# Example:   nth_string_field "$person" "title" 2  →  the 2nd title in the chunk
nth_string_field() {
  echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | sed -n "${3}p" | cut -d'"' -f4
}

# Convert a Unix-millisecond timestamp to a YYYY-MM-DD date.
# Falls back to printing the raw value if it is not a plain number.
format_started_at() {
  local ms="$1"
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    # macOS (BSD) and Linux (GNU) date take different flags — try both.
    date -u -r "$(( ms / 1000 ))" +%Y-%m-%d 2>/dev/null \
      || date -u -d "@$(( ms / 1000 ))" +%Y-%m-%d 2>/dev/null \
      || echo "$ms"
  else
    echo "${ms:----}"
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────────

echo "Searching LeadIQ for recent job changes..."
echo "  Change type      : JobChange"
echo "  Current role     : Sales"
echo "  Current seniority: VP"
echo "  Current industry : Computer Software"
[[ -n "$STARTED_AFTER_MS" ]] && echo "  Changed since    : $(format_started_at "$STARTED_AFTER_MS")"
echo ""

# Make sure the output directory exists and start with a fresh file.
mkdir -p "$(dirname "$OUTPUT_FILE")"
> "$OUTPUT_FILE"

skip=0
total=0
page=1
collected=0

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
      echo "No job changes found. Try widening the filters."
      exit 0
    fi
    target=$(( total < MAX_PEOPLE ? total : MAX_PEOPLE ))
    echo "Found $total job changes. Fetching up to $target ($PAGE_SIZE per page)..."
    echo ""
  fi

  # Split the response into one block per person. Each person object starts with
  # "id":"PersonID..." — company ids use a different prefix, so this delimiter
  # cleanly separates people without a JSON parser. The text before the first
  # match (response envelope) is discarded by the `[[ "$block" == *PersonID* ]]`
  # guard below.
  page_count=0
  while IFS= read -r block; do
    [[ "$block" != *'"id":"PersonID'* ]] && continue
    (( collected >= MAX_PEOPLE )) && break

    # Person fields. Within a person block "name" appears three times in query
    # order: the person, then the previous company, then the current company.
    person_name=$(nth_string_field   "$block" "name" 1)
    prev_company=$(nth_string_field   "$block" "name" 2)
    curr_company=$(nth_string_field   "$block" "name" 3)

    # "title" appears twice: previousPosition then currentPosition.
    prev_title=$(nth_string_field     "$block" "title" 1)
    curr_title=$(nth_string_field     "$block" "title" 2)

    change_type=$(nth_string_field    "$block" "jobChangeType" 1)
    linkedin_url=$(nth_string_field   "$block" "linkedinUrl" 1)
    started_raw=$(echo "$block" | grep -oE '"startedAt":[0-9]+' | head -1 | grep -oE '[0-9]+$')
    started=$(format_started_at "$started_raw")

    # Print the transition to the screen.
    echo "$(( collected + 1 )). ${person_name:-(unknown)}  [${change_type:----} · ${started}]"
    echo "     from: ${prev_title:----} @ ${prev_company:----}"
    echo "       to: ${curr_title:----} @ ${curr_company:----}"
    [[ -n "$linkedin_url" ]] && echo "     $linkedin_url"
    echo ""

    # Append a tab-separated row to the output file.
    printf '%s\t%s\t%s\t%s @ %s\t%s @ %s\t%s\n' \
      "${person_name:----}" "${change_type:----}" "$started" \
      "${prev_title:----}" "${prev_company:----}" \
      "${curr_title:----}" "${curr_company:----}" \
      "${linkedin_url:----}" >> "$OUTPUT_FILE"

    page_count=$(( page_count + 1 ))
    collected=$(( collected + 1 ))
  done < <(echo "$response" | sed 's/{"id":"PersonID/\n{"id":"PersonID/g')

  # Stop once we have collected enough, or fetched the last page.
  if (( collected >= MAX_PEOPLE || skip + PAGE_SIZE >= total )); then
    break
  fi

  skip=$(( skip + PAGE_SIZE ))
  page=$(( page + 1 ))
done

echo "Total: $collected job changes retrieved."
echo "Saved to $OUTPUT_FILE"
