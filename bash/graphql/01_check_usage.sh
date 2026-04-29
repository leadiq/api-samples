#!/usr/bin/env bash
# 01_check_usage.sh — Verify your API key and check your credit balance.
#
# This is the simplest call you can make to the LeadIQ API.
# It does NOT consume any credits.
#
# Usage:
#   export LEADIQ_API_KEY=your_secret_base64_key
#   bash graphql/01_check_usage.sh

# ── Configuration ─────────────────────────────────────────────────────────────

GRAPHQL_URL="https://api.leadiq.com/graphql"

# Check that the API key has been exported before running this script.
if [[ -z "${LEADIQ_API_KEY:-}" ]]; then
  echo "Error: LEADIQ_API_KEY is not set."
  echo "  Run: export LEADIQ_API_KEY=your_secret_base64_key"
  exit 1
fi

# Check that curl is available (it is pre-installed on macOS and most Linux distros).
if ! command -v curl &>/dev/null; then
  echo "Error: curl is required but not installed."
  echo "  Ubuntu/Debian : sudo apt install curl"
  echo "  Fedora        : sudo dnf install curl"
  exit 1
fi

# ── Query ──────────────────────────────────────────────────────────────────────

# GraphQL query written as a single line so it can be embedded directly in the
# JSON request body without any extra escaping.
QUERY='query Account { account { plans { name product status nextBillingPeriod } dataHubPlan { name product status nextBillingPeriod available used } universalPlan { name product status nextBillingPeriod available used } } }'

# ── Call the API ───────────────────────────────────────────────────────────────

printf "Connecting to LeadIQ API... "

# curl flags used here:
#   -s            silent — no progress bar
#   --max-time 30 give up after 30 seconds
#   -X POST       send an HTTP POST request
#   -H            add a request header
#   --data-raw    set the request body (avoids curl interpreting @ characters)
if ! response=$(curl -s --max-time 30 \
  -X POST "$GRAPHQL_URL" \
  -H "Authorization: Basic $LEADIQ_API_KEY" \
  -H "Content-Type: application/json" \
  --data-raw "{\"query\":\"$QUERY\"}"); then
  echo "failed."
  echo "Error: Could not reach the API. Check your internet connection."
  exit 1
fi

echo "done."
echo ""

# The LeadIQ API always returns HTTP 200, even for errors.
# Real error details are inside the "errors" field of the response body.
if echo "$response" | grep -q '"errors"'; then
  # Extract the HTTP-style status code from the error to give a helpful message.
  status_code=$(echo "$response" | grep -oE '"status":[0-9]+' | head -1 | grep -oE '[0-9]+')
  case "$status_code" in
    401) echo "Error: Invalid API key."
         echo "Make sure LEADIQ_API_KEY is set to the correct Secret Base64 key." ;;
    429) echo "Error: Too many requests. Wait a moment and try again." ;;
    *)   echo "API error: $(echo "$response" | grep -oE '"message":"[^"]*"' | head -1 | cut -d'"' -f4)" ;;
  esac
  exit 1
fi

# ── Display plans ──────────────────────────────────────────────────────────────

# Extract the plans array from the response.
# Replacing null nextBillingPeriod values with "N/A" keeps the column count
# consistent when paste combines the four field streams below.
plans_raw=$(echo "$response" | grep -oE '"plans":\[[^]]*\]' | head -1 | \
  sed 's/"nextBillingPeriod":null/"nextBillingPeriod":"N\/A"/g')

echo "Plans:"
printf "  %-32s %-14s %-12s %s\n" "Name" "Product" "Status" "Next Billing Period"
printf "  %s\n" "$(printf '%0.s-' {1..74})"

# paste combines four parallel streams (one field per line from each) into tab-
# separated rows. IFS=$'\t' splits on the tab so each field lands in its own
# variable for printf to align.
paste \
  <(echo "$plans_raw" | grep -oE '"name":"[^"]*"'              | cut -d'"' -f4) \
  <(echo "$plans_raw" | grep -oE '"product":"[^"]*"'           | cut -d'"' -f4) \
  <(echo "$plans_raw" | grep -oE '"status":"[^"]*"'            | cut -d'"' -f4) \
  <(echo "$plans_raw" | grep -oE '"nextBillingPeriod":"[^"]*"' | cut -d'"' -f4) \
| while IFS=$'\t' read -r name product status next; do
  printf "  %-32s %-14s %-12s %s\n" "$name" "$product" "$status" "${next:-N/A}"
done

# ── Display DataHub credit plan ────────────────────────────────────────────────

# Extract the dataHubPlan object (it has no nested objects, so [^}]* is safe).
dh_json=$(echo "$response" | grep -oE '"dataHubPlan":\{[^}]*\}' | head -1)
if [[ -n "$dh_json" ]]; then
  dh_name=$(     echo "$dh_json" | grep -oE '"name":"[^"]*"'              | head -1 | cut -d'"' -f4)
  dh_status=$(   echo "$dh_json" | grep -oE '"status":"[^"]*"'            | head -1 | cut -d'"' -f4)
  dh_next=$(     echo "$dh_json" | grep -oE '"nextBillingPeriod":"[^"]*"' | head -1 | cut -d'"' -f4)
  dh_available=$(echo "$dh_json" | grep -oE '"available":[0-9]+'          | head -1 | cut -d':' -f2)
  dh_used=$(     echo "$dh_json" | grep -oE '"used":[0-9]+'               | head -1 | cut -d':' -f2)
  dh_total=$((dh_available + dh_used))
  echo ""
  echo "DataHub Plan — $dh_name ($dh_status)"
  echo "  Used      : $dh_used"
  echo "  Available : $dh_available"
  echo "  Total     : $dh_total"
  [[ -n "$dh_next" ]] && echo "  Resets    : $dh_next"
fi

# ── Display Universal credit plan ─────────────────────────────────────────────

# Same structure as dataHubPlan.
uv_json=$(echo "$response" | grep -oE '"universalPlan":\{[^}]*\}' | head -1)
if [[ -n "$uv_json" ]]; then
  uv_name=$(     echo "$uv_json" | grep -oE '"name":"[^"]*"'              | head -1 | cut -d'"' -f4)
  uv_status=$(   echo "$uv_json" | grep -oE '"status":"[^"]*"'            | head -1 | cut -d'"' -f4)
  uv_next=$(     echo "$uv_json" | grep -oE '"nextBillingPeriod":"[^"]*"' | head -1 | cut -d'"' -f4)
  uv_available=$(echo "$uv_json" | grep -oE '"available":[0-9]+'          | head -1 | cut -d':' -f2)
  uv_used=$(     echo "$uv_json" | grep -oE '"used":[0-9]+'               | head -1 | cut -d':' -f2)
  uv_total=$((uv_available + uv_used))
  echo ""
  echo "Universal Plan — $uv_name ($uv_status)"
  echo "  Used      : $uv_used"
  echo "  Available : $uv_available"
  echo "  Total     : $uv_total"
  [[ -n "$uv_next" ]] && echo "  Resets    : $uv_next"
fi
