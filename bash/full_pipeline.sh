#!/usr/bin/env bash
# full_pipeline.sh — End-to-end LeadIQ pipeline in a single script.
#
# This script combines every step from samples 01–06 into one run:
#
#   Step 1 — Advanced search (GraphQL)
#             Search for Sales professionals at VP, Director, and Manager level
#             in New Hampshire and collect their LeadIQ person IDs.
#
#   Step 2 — Enrich profiles (GraphQL)
#             For each person ID, fetch their work email and direct phone number.
#
#   Step 3 — Create a Prospector list (REST)
#             Create a new list named "Sales Leaders in NH - Pipeline" in the
#             LeadIQ Prospector.
#
#   Step 4 — Add prospects (REST)
#             Add each enriched person to the list as a prospect.
#
#   Step 5 — Export to CSV (REST)
#             Fetch all prospects back from the list and write them to a CSV
#             file you can open in Excel or Google Sheets.
#
# No intermediate files are created — everything flows through shell variables
# and arrays.  The only output is output/pipeline_prospects.csv.
#
# IMPORTANT — credit cost:
#   Step 1 costs 1 "Advanced Search (Page)" credit per page of results.
#   Step 2 costs 1 "Enrich" credit per person.
#   Steps 3–5 are free.
#   Set MAX_PEOPLE below to a small number until you are happy with the results.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash full_pipeline.sh

# ── Configuration ─────────────────────────────────────────────────────────────

GRAPHQL_URL="https://api.leadiq.com/graphql"
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

# ── Search filters (Step 1) ────────────────────────────────────────────────────

SEARCH_PAGE_SIZE=25

# ── Enrichment settings (Step 2) ──────────────────────────────────────────────

# Each person costs ONE Enrich credit — start small and raise once satisfied.
MAX_PEOPLE=10

# Pause between enrichment and prospect API calls to avoid rate-limit errors.
DELAY_BETWEEN_CALLS=1

# ── Prospector list settings (Steps 3–5) ──────────────────────────────────────

# This name is intentionally different from sample 04 to avoid a 409 conflict.
LIST_NAME="Sales Leaders in NH - Pipeline"
LIST_DESCRIPTION="VP, Director, and Manager level Sales professionals in New Hampshire — created by the full_pipeline.sh end-to-end sample."

EXPORT_PAGE_SIZE=100

# ── Output ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_CSV="$SCRIPT_DIR/output/pipeline_prospects.csv"

# ── Decode API key ─────────────────────────────────────────────────────────────

# The LEADIQ_API_KEY is the "Secret Base64" key.
# GraphQL uses it as-is; Prospector needs the raw decoded version.
PROSPECTOR_KEY=$(printf '%s' "$LEADIQ_API_KEY" | base64 -d 2>/dev/null \
  || printf '%s' "$LEADIQ_API_KEY" | base64 -D 2>/dev/null)

if [[ -z "$PROSPECTOR_KEY" ]]; then
  echo "Error: Could not decode the API key."
  exit 1
fi

# ── Helpers ────────────────────────────────────────────────────────────────────

graphql_request() {
  # Send one GraphQL request and print the raw JSON response.
  # Arguments: $1 = JSON body string
  curl -s --max-time 30 \
    -X POST "$GRAPHQL_URL" \
    -H "Authorization: Basic $LEADIQ_API_KEY" \
    -H "Content-Type: application/json" \
    --data-raw "$1" || {
    echo "" >&2
    echo "Error: Could not reach the GraphQL API." >&2
    exit 1
  }
}

extract_field() { echo "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -1 | cut -d'"' -f4; }
extract_number() { echo "$1" | grep -oE "\"$2\":[0-9]+" | head -1 | cut -d':' -f2; }
extract_object() { local after="${1#*\"$2\":}"; echo "$after"; }
csv_quote() { local val="${1//\"/\"\"}"; echo "\"$val\""; }

# ── Step 1 — Advanced search ───────────────────────────────────────────────────

SEARCH_QUERY='query FlatAdvancedSearch($input: FlatSearchInput!) { flatAdvancedSearch(input: $input) { totalPeople people { id } } }'

echo "============================================================"
echo "LeadIQ Full Pipeline"
echo "============================================================"
echo ""
echo "Step 1 — Advanced search"
echo "  Roles      : Sales"
echo "  Seniorities: VP, Director, Manager"
echo "  Location   : New Hampshire, United States"

# Collect up to MAX_PEOPLE person IDs across as many pages as needed.
declare -a PERSON_IDS
skip=0

while true; do
  body=$(printf '{"query":"%s","variables":{"input":{"contactFilter":{"roles":["Sales"],"seniorities":["VP","Director","Manager"],"locations":[{"areaLevel1":"New Hampshire","country":"United States"}]},"limit":%d,"skip":%d}}}' \
    "$SEARCH_QUERY" "$SEARCH_PAGE_SIZE" "$skip")

  response=$(graphql_request "$body")

  if echo "$response" | grep -q '"errors"'; then
    status=$(echo "$response" | grep -oE '"status":[0-9]+' | head -1 | grep -oE '[0-9]+$')
    case "$status" in
      401) echo "Error: Invalid API key." >&2; exit 1 ;;
      402) echo "Error: Insufficient credits." >&2; exit 1 ;;
      429) echo "Error: Too many requests." >&2; exit 1 ;;
      *)   echo "API error." >&2; exit 1 ;;
    esac
  fi

  total=$(echo "$response" | grep -oE '"totalPeople":[0-9]+' | grep -oE '[0-9]+$')

  if [[ "${skip}" -eq 0 ]]; then
    if [[ "${total:-0}" -eq 0 ]]; then
      echo "  No results found."
      exit 0
    fi
    echo "  Found $total people — will enrich up to $MAX_PEOPLE."
  fi

  # Extract all person IDs from this page and add them to our array.
  while IFS= read -r pid; do
    PERSON_IDS+=("$pid")
  done < <(echo "$response" | grep -oE '"id":"[^"]*"' | cut -d'"' -f4)

  # Stop when we have enough IDs or have fetched all pages.
  page_count=${#PERSON_IDS[@]}
  if (( page_count >= MAX_PEOPLE || skip + SEARCH_PAGE_SIZE >= total )); then
    break
  fi
  skip=$((skip + SEARCH_PAGE_SIZE))
done

# Trim to MAX_PEOPLE.
PERSON_IDS=("${PERSON_IDS[@]:0:$MAX_PEOPLE}")
echo "  Collected ${#PERSON_IDS[@]} IDs."
echo ""

# ── Step 2 — Enrich profiles ───────────────────────────────────────────────────

ENRICH_QUERY='query SearchPeople($input: SearchPeopleInput!) { searchPeople(input: $input) { results { id linkedin { linkedinUrl } name { fullName first last } currentPositions { title seniority function companyInfo { name } emails { value status } } personalPhones { value verificationStatus } } } }'

echo "Step 2 — Enriching ${#PERSON_IDS[@]} profiles (1 credit each)"

# Store enriched data in parallel indexed arrays.
# Each index corresponds to one enriched person.
declare -a E_IDS E_FIRST E_LAST E_FULL_NAMES E_TITLES E_COMPANIES E_EMAILS E_PHONES E_SENIORITIES E_FUNCTIONS E_LINKEDINS
enrich_count=0
total_ids=${#PERSON_IDS[@]}

for (( i=0; i<total_ids; i++ )); do
  pid="${PERSON_IDS[$i]}"
  printf "  [%d/%d] %s ..." "$((i+1))" "$total_ids" "$pid"

  body=$(printf '{"query":"%s","variables":{"input":{"id":"%s"}}}' "$ENRICH_QUERY" "$pid")
  response=$(graphql_request "$body")

  if ! echo "$response" | grep -q '"results":\[{'; then
    echo " not found — skipped"
    continue
  fi

  full_name=$(echo "$response" | grep -oE '"fullName":"[^"]*"' | head -1 | cut -d'"' -f4)
  first=$(echo "$response" | grep -oE '"first":"[^"]*"' | head -1 | cut -d'"' -f4)
  last=$(echo "$response" | grep -oE '"last":"[^"]*"' | head -1 | cut -d'"' -f4)
  title=$(echo "$response" | grep -oE '"title":"[^"]*"' | head -1 | cut -d'"' -f4)
  seniority=$(echo "$response" | grep -oE '"seniority":"[^"]*"' | head -1 | cut -d'"' -f4)
  func=$(echo "$response" | grep -oE '"function":"[^"]*"' | head -1 | cut -d'"' -f4)
  company=$(echo "$response" | grep -oE '"companyInfo":\{"name":"[^"]*"' | head -1 | grep -oE '"name":"[^"]*"' | cut -d'"' -f4)
  work_email=$(echo "$response" | grep -oE '"value":"[^"@]*@[^"]+"' | head -1 | cut -d'"' -f4)
  phone=$(echo "$response" | grep -oE '"personalPhones":\[(\{[^]]*\})*' | \
    grep -oE '"value":"[^"]+"' | head -1 | cut -d'"' -f4)
  linkedin_url=$(echo "$response" | grep -oE '"linkedinUrl":"[^"]*"' | head -1 | cut -d'"' -f4)

  E_IDS[$enrich_count]="$pid"
  E_FIRST[$enrich_count]="$first"
  E_LAST[$enrich_count]="$last"
  E_FULL_NAMES[$enrich_count]="$full_name"
  E_TITLES[$enrich_count]="$title"
  E_SENIORITIES[$enrich_count]="$seniority"
  E_FUNCTIONS[$enrich_count]="$func"
  E_COMPANIES[$enrich_count]="$company"
  E_EMAILS[$enrich_count]="$work_email"
  E_PHONES[$enrich_count]="$phone"
  E_LINKEDINS[$enrich_count]="$linkedin_url"


  email_tag=$([ -n "$work_email" ] && echo "✓ email" || echo "— email")
  phone_tag=$([ -n "$phone" ]      && echo "✓ phone" || echo "— phone")
  echo " $email_tag  $phone_tag"

  enrich_count=$((enrich_count + 1))
  (( i < total_ids - 1 )) && sleep "$DELAY_BETWEEN_CALLS"
done

echo "  Enriched $enrich_count of $total_ids profiles."
echo ""

# ── Step 3 — Create Prospector list ───────────────────────────────────────────

printf 'Step 3 — Creating list "%s"...' "$LIST_NAME"

create_body="{\"name\":\"$LIST_NAME\",\"description\":\"$LIST_DESCRIPTION\"}"
response=$(curl -s --max-time 30 \
  -X POST "$PROSPECTOR_URL/v1/lists" \
  -H "X-API-Key: $PROSPECTOR_KEY" \
  -H "Content-Type: application/json" \
  --data-raw "$create_body" \
  -w "\n%{http_code}") || { echo ""; echo "Error: Could not reach the Prospector API."; exit 1; }

http_code=$(echo "$response" | tail -1)
body=$(echo "$response" | sed '$d')

case "$http_code" in
  201) ;;
  401) echo ""; echo "Error: Invalid API key."; exit 1 ;;
  409) echo ""; echo "Error: List \"$LIST_NAME\" already exists. Change LIST_NAME."; exit 1 ;;
  *)   echo ""; echo "Error $http_code"; exit 1 ;;
esac

LIST_ID=$(echo "$body" | grep -oE '"id":"[0-9a-fA-F]{24}"' | head -1 | cut -d'"' -f4)
echo " done (id: $LIST_ID)"
echo ""

# ── Step 4 — Add prospects ─────────────────────────────────────────────────────

echo "Step 4 — Adding $enrich_count prospects to the list"

added=0
skipped=0

for (( i=0; i<enrich_count; i++ )); do
  first="${E_FIRST[$i]}"
  last="${E_LAST[$i]}"
  name="${E_FULL_NAMES[$i]}"
  title="${E_TITLES[$i]}"
  seniority="${E_SENIORITIES[$i]}"
  func="${E_FUNCTIONS[$i]}"
  company="${E_COMPANIES[$i]}"
  email="${E_EMAILS[$i]}"
  phone="${E_PHONES[$i]}"
  linkedin_url="${E_LINKEDINS[$i]}"

  printf "  [%d/%d] %s ..." "$((i+1))" "$enrich_count" "$name"

  if [[ -z "$first" || -z "$last" ]]; then
    echo " skipped (missing name)"
    skipped=$((skipped + 1))
    continue
  fi

  pbody="{\"firstName\":\"$first\",\"lastName\":\"$last\""
  [[ -n "$title"       ]] && pbody+=",\"title\":\"$title\""
  [[ -n "$seniority"   ]] && pbody+=",\"seniority\":\"$seniority\""
  [[ -n "$func"        ]] && pbody+=",\"function\":\"$func\""
  [[ -n "$company"     ]] && pbody+=",\"company\":\"$company\""
  [[ -n "$email"       ]] && pbody+=",\"workEmail\":\"$email\""
  [[ -n "$phone"       ]] && pbody+=",\"mobilePhone\":\"$phone\""
  [[ -n "$linkedin_url" ]] && pbody+=",\"linkedinUrl\":\"$linkedin_url\""
  pbody+="}"

  p_response=$(curl -s --max-time 30 \
    -X POST "$PROSPECTOR_URL/v1/lists/$LIST_ID/prospects" \
    -H "X-API-Key: $PROSPECTOR_KEY" \
    -H "Content-Type: application/json" \
    --data-raw "$pbody" \
    -w "\n%{http_code}") || { echo " connection error — skipped"; skipped=$((skipped+1)); continue; }

  p_code=$(echo "$p_response" | tail -1)
  case "$p_code" in
    201) echo " added"; added=$((added + 1)) ;;
    401) echo ""; echo "Error: Invalid API key."; exit 1 ;;
    *)   echo " error $p_code — skipped"; skipped=$((skipped + 1)) ;;
  esac

  (( i < enrich_count - 1 )) && sleep "$DELAY_BETWEEN_CALLS"
done

echo "  Added $added, skipped $skipped."
echo ""

# ── Step 5 — Export to CSV ─────────────────────────────────────────────────────

echo "Step 5 — Fetching prospects and writing CSV"

mkdir -p "$(dirname "$OUTPUT_CSV")"
printf '%s\n' \
  "id,name,first_name,last_name,title,seniority,function,work_email,email_status,direct_phone,linkedin_url,location_city,location_state,location_country,company_name,company_domain,company_industry,company_employees,updated_at" \
  > "$OUTPUT_CSV"

cursor=""
page=1
total_written=0

while true; do
  if [[ -n "$cursor" ]]; then
    url="$PROSPECTOR_URL/v1/lists/$LIST_ID/prospects?limit=$EXPORT_PAGE_SIZE&cursor=$cursor"
  else
    url="$PROSPECTOR_URL/v1/lists/$LIST_ID/prospects?limit=$EXPORT_PAGE_SIZE"
  fi

  printf "  Page %d..." "$page"

  exp_response=$(curl -s --max-time 30 \
    -H "X-API-Key: $PROSPECTOR_KEY" \
    -H "Content-Type: application/json" \
    "$url" \
    -w "\n%{http_code}") || { echo ""; echo "Error: Could not reach the API."; exit 1; }

  exp_code=$(echo "$exp_response" | tail -1)
  exp_body=$(echo "$exp_response" | sed '$d')

  [[ "$exp_code" != "200" ]] && { echo ""; echo "Error $exp_code"; exit 1; }

  items_raw=$(echo "$exp_body" | grep -oE '"items":\[.*\]' | sed 's/"items":\[//;s/\]$//')
  items_split=$(echo "$items_raw" | sed 's/},{"id"/}\n{"id"/g')

  item_count=0
  while IFS= read -r item; do
    [[ -z "$item" ]] && continue

    id=$(extract_field "$item" "id")
    name=$(extract_field "$item" "name")
    first=$(extract_field "$item" "firstName")
    last=$(extract_field "$item" "lastName")
    title=$(extract_field "$item" "title")
    email=$(extract_field "$item" "workEmail")
    email_status=$(extract_field "$item" "emailStatus")
    updated_at=$(extract_field "$item" "updatedAt")
    direct_phone=""; seniority=""; func=""; linkedin_url=""
    for (( j=0; j<enrich_count; j++ )); do
      if [[ "${E_EMAILS[$j]}" == "$email" ]]; then
        direct_phone="${E_PHONES[$j]}"
        seniority="${E_SENIORITIES[$j]}"
        func="${E_FUNCTIONS[$j]}"
        linkedin_url="${E_LINKEDINS[$j]}"
        break
      fi
    done

    loc_part=$(extract_object "$item" "location")
    loc_city=$(extract_field "$loc_part" "city")
    loc_state=$(extract_field "$loc_part" "state")
    loc_country=$(extract_field "$loc_part" "country")

    co_part=$(extract_object "$item" "company")
    co_name=$(extract_field "$co_part" "name")
    co_domain=$(extract_field "$co_part" "domain")
    co_industry=$(extract_field "$co_part" "industry")
    co_employees=$(extract_number "$co_part" "employees")

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_quote "$id")"           "$(csv_quote "$name")"         \
      "$(csv_quote "$first")"        "$(csv_quote "$last")"         \
      "$(csv_quote "$title")"        "$(csv_quote "$seniority")"    \
      "$(csv_quote "$func")"         "$(csv_quote "$email")"        \
      "$(csv_quote "$email_status")" "$(csv_quote "$direct_phone")" \
      "$(csv_quote "$linkedin_url")" "$(csv_quote "$loc_city")"     \
      "$(csv_quote "$loc_state")"    "$(csv_quote "$loc_country")"  \
      "$(csv_quote "$co_name")"      "$(csv_quote "$co_domain")"    \
      "$(csv_quote "$co_industry")"  "$(csv_quote "$co_employees")" \
      "$(csv_quote "$updated_at")"   \
      >> "$OUTPUT_CSV"

    item_count=$((item_count + 1))
    total_written=$((total_written + 1))
  done <<< "$items_split"

  echo " $item_count prospects"

  if echo "$exp_body" | grep -q '"nextCursor":null'; then
    break
  fi

  cursor=$(echo "$exp_body" | grep -oE '"nextCursor":"[0-9a-fA-F]{24}"' | cut -d'"' -f4)
  [[ -z "$cursor" ]] && break
  page=$((page + 1))
done

echo ""
echo "  Total: $total_written prospects"
echo "  Saved to: $OUTPUT_CSV"
echo ""
echo "Done."
