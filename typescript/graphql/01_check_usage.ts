/**
 * 01_check_usage.ts — Verify your API key and check your credit balance.
 *
 * Uses the `account` query to show plan status and credit usage.
 * It does NOT consume any credits.
 *
 * Run it with:
 *   npm run 01
 */

import dotenv from "dotenv";
import path from "path";

// Load the LEADIQ_API_KEY from the .env file in the typescript/ folder.
// This must happen before we read process.env below.
dotenv.config({ path: path.join(__dirname, "..", ".env") });

// ── Configuration ─────────────────────────────────────────────────────────────

// The URL every LeadIQ GraphQL request is sent to.
const GRAPHQL_URL = "https://api.leadiq.com/graphql";

// Your API key is loaded from the .env file — never hard-code it here.
const API_KEY = process.env.LEADIQ_API_KEY;

// ── Types ─────────────────────────────────────────────────────────────────────

// These interfaces describe the shape of the JSON the API sends back.
// TypeScript uses them to catch mistakes at compile time.

interface GraphQLError {
  message: string;
  extensions?: {
    response?: {
      status?: number;
    };
  };
}

interface Plan {
  name: string;
  product: string;
  status: string;
  nextBillingPeriod: string | null;
}

interface CreditPlan {
  name: string;
  product: string;
  status: string;
  nextBillingPeriod: string | null;
  available: number;
  used: number;
}

interface AccountResponse {
  data?: {
    account: {
      plans: Plan[];
      dataHubPlan: CreditPlan | null;
      universalPlan: CreditPlan | null;
    };
  };
  errors?: GraphQLError[];
}

// ── Query ──────────────────────────────────────────────────────────────────────

// This GraphQL query asks the API for your current plan and credit usage.
const ACCOUNT_QUERY = `
query Account {
  account {
    plans {
      name
      product
      status
      nextBillingPeriod
    }
    dataHubPlan {
      name
      product
      status
      nextBillingPeriod
      available
      used
    }
    universalPlan {
      name
      product
      status
      nextBillingPeriod
      available
      used
    }
  }
}
`;

// ── Helpers ────────────────────────────────────────────────────────────────────

/**
 * Send a single GraphQL request to the LeadIQ API.
 * Returns the parsed JSON response.
 * Exits the process if the network request fails.
 */
async function sendRequest(
  headers: Record<string, string>,
  body: object
): Promise<AccountResponse> {
  // AbortController lets us cancel the request if it takes too long.
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);

  try {
    const response = await fetch(GRAPHQL_URL, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    return (await response.json()) as AccountResponse;
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      console.error("Error: The API took too long to respond. Please try again.");
    } else {
      console.error("Error: Could not reach the API. Check your internet connection.");
    }
    process.exit(1);
  } finally {
    clearTimeout(timeoutId);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  // Make sure the API key was loaded. If not, remind the user how to set it up.
  if (!API_KEY) {
    console.error("Error: LEADIQ_API_KEY is not set.");
    console.error("  1. Copy .env.example to .env");
    console.error("  2. Open .env and paste your Secret Base64 API key");
    process.exit(1);
  }

  // Build the HTTP headers. LeadIQ uses HTTP Basic Auth — the API key
  // goes in the Authorization header as the username (no password needed).
  const headers = {
    Authorization: `Basic ${API_KEY}`,
    "Content-Type": "application/json",
  };

  process.stdout.write("Connecting to LeadIQ API... ");

  // Send the request to the API.
  const result = await sendRequest(headers, { query: ACCOUNT_QUERY });

  console.log("done.\n");

  // The LeadIQ API always returns HTTP 200, even for errors.
  // Real error information is inside the "errors" field of the response.
  if (result.errors) {
    const error = result.errors[0];
    const status = error.extensions?.response?.status;

    if (status === 401) {
      console.error("Error: Invalid API key.");
      console.error(
        "Make sure LEADIQ_API_KEY in your .env file is the correct Secret Base64 key."
      );
    } else if (status === 429) {
      console.error("Error: Too many requests. Wait a moment and try again.");
    } else {
      console.error(`API error: ${error.message ?? "Unknown error"}`);
    }
    process.exit(1);
  }

  // Pull out the account data from the response.
  const { account } = result.data!;

  // Print plan statuses.
  console.log("Plans:");
  const col1 = 30, col2 = 14, col3 = 12;
  console.log(
    "  Name".padEnd(col1 + 2) +
    "Product".padEnd(col2) +
    "Status".padEnd(col3) +
    "Next Billing Period"
  );
  console.log("  " + "-".repeat(74));
  for (const plan of account.plans) {
    console.log(
      ("  " + plan.name).padEnd(col1 + 2) +
      plan.product.padEnd(col2) +
      plan.status.padEnd(col3) +
      (plan.nextBillingPeriod ?? "N/A")
    );
  }

  // Print credit usage for DataHub and Universal plans.
  const creditPlans: Array<[string, CreditPlan | null]> = [
    ["DataHub", account.dataHubPlan],
    ["Universal", account.universalPlan],
  ];

  for (const [label, plan] of creditPlans) {
    if (!plan) continue;
    const total = plan.available + plan.used;
    console.log(`\n${label} Plan — ${plan.name} (${plan.status})`);
    console.log(`  Used      : ${plan.used}`);
    console.log(`  Available : ${plan.available}`);
    console.log(`  Total     : ${total}`);
    if (plan.nextBillingPeriod) {
      console.log(`  Resets    : ${plan.nextBillingPeriod}`);
    }
  }
}

main();
