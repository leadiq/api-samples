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
QUERY='query { usage { subscription { status } planUsage { name creditType units cap billingType } } }'

# ── Call the API ───────────────────────────────────────────────────────────────

echo "Connecting to LeadIQ API..."

# curl flags used here:
#   -s            silent — no progress bar
#   --max-time 30 give up after 30 seconds
#   -X POST       send an HTTP POST request
#   -H            add a request header
#   --data-raw    set the request body (avoids curl interpreting @ characters)
response=$(curl -s --max-time 30 \
  -X POST "$GRAPHQL_URL" \
  -H "Authorization: Basic $LEADIQ_API_KEY" \
  -H "Content-Type: application/json" \
  --data-raw "{\"query\":\"$QUERY\"}") || {
  echo "Error: Could not reach the API. Check your internet connection."
  exit 1
}

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

echo "Done."
echo ""

# ── Display results ────────────────────────────────────────────────────────────

# Extract the subscription status from the response.
# grep -oE prints only the matching part; cut splits on quotes and takes field 4.
sub_status=$(echo "$response" | grep -oE '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Subscription : $sub_status"
echo ""

# Extract and display each credit type.
# The response contains multiple objects with creditType, units, and cap fields.
# We extract each field separately and print them together.
echo "Credit usage :"
echo "$response" | grep -oE '"creditType":"[^"]*"' | cut -d'"' -f4 | \
while IFS= read -r credit_type; do
  echo "  $credit_type"
done
echo ""
echo "Full response saved below (copy to https://jsonformatter.org for a readable view):"
echo "$response"
