# LeadIQ API — TypeScript Samples

Ready-to-run TypeScript scripts that show you how to use the LeadIQ API. No prior programming experience needed — just follow the steps below.

---

## What you will need

- A **LeadIQ account** with API access enabled
- Your **Secret Base64 API key** — find it in LeadIQ under **Settings → API Keys**
- **Node.js 22 or later** installed on your computer — see instructions below

---

## Installing Node.js

### Windows

1. Go to [nodejs.org](https://nodejs.org/) and click **Download Node.js (LTS)**
2. Run the installer and follow the steps — the defaults are fine
3. Once installed, open the **Command Prompt** (search for `cmd` in the Start menu) and verify it worked:
   ```
   node --version
   ```
   You should see something like `v20.12.0`.

### Mac

1. Go to [nodejs.org](https://nodejs.org/) and click **Download Node.js (LTS)**
2. Open the downloaded `.pkg` file and follow the installer steps
3. Once installed, open **Terminal** (search for it in Spotlight with `Cmd + Space`) and verify:
   ```
   node --version
   ```
   You should see something like `v20.12.0`.

### Linux

Most Linux distributions can install Node.js via a package manager:

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install nodejs npm

# Fedora
sudo dnf install nodejs npm
```

Then verify:

```bash
node --version
```

---

## Setup (one time)

**1. Clone this repository**

```bash
git clone https://github.com/leadiq/api-samples.git
cd api-samples/typescript
```

**2. Install dependencies**

This downloads the libraries the scripts need (TypeScript, ts-node, dotenv).

```bash
npm install
```

**3. Create your environment file**

```bash
cp .env.example .env
```

Open the `.env` file in any text editor and replace the placeholder with your real key:

```
LEADIQ_API_KEY=ABCdef123...   ← paste your Secret Base64 key here
```

Save the file. You only need to do this once.

---

## Running the samples

```bash
npx ts-node graphql/01_check_usage.ts
```

Replace the script path with whichever sample you want to run.

---

## Samples

### GraphQL API (`graphql/`)

The GraphQL API endpoint is `https://api.leadiq.com/graphql`. It supports rich queries for people, companies, and account management.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.ts` | Verifies your API key and displays your current credit usage | None |
| `graphql/02_advanced_search.ts` | Finds people by role, seniority, and location — saves their IDs to `output/advanced_search_ids.json` | 1 per page of results |
| `graphql/03_enrich_profiles.ts` | Reads IDs from `output/advanced_search_ids.json` and enriches each person with their work email and direct phone — saves results to `output/enriched_profiles.json` | 1 Enrich credit per person |

Expected output for `01_check_usage.ts`:

```
Connecting to LeadIQ API... done.

Subscription status : active

Credit Type                Plan                   Used      Cap  Billing
----------------------------------------------------------------------
Contact (Page)             Starter                   5      500  monthly
Contact (ExactMatch)       Starter                   2      100  monthly
```

Expected output for `02_advanced_search.ts`:

```
Searching LeadIQ API...
  Roles      : Sales
  Seniorities: VP, Director, Manager
  Location   : New Hampshire, United States

Found 42 people. Fetching IDs (25 per page)...

#      ID
--------------------------------------------------
1      PersonID-abc123def456
2      PersonID-xyz789ghi012
...
42     PersonID-pqr901stu234

Total: 42 IDs retrieved.
Saved to output/advanced_search_ids.json
```

Expected output for `03_enrich_profiles.ts`:

```
Input file : output/advanced_search_ids.json
Total IDs  : 42
Processing : 10 (MAX_PEOPLE=10)
API calls  : 10  (one per person)
Max credits: 10 Enrich credits

[1/10] PersonID-abc123def456 ... ✓ email  ✓ phone
[2/10] PersonID-xyz789ghi012 ... ✓ email  — phone
...

#     Name                         Title                          Company                  Work Email                       Direct Phone
----------------------------------------------------------------------------------------------------------------------------------
1     Jane Smith                   VP of Sales                    Acme Corp                jane.smith@acme.com              +16035551234
2     John Doe                     Sales Director                 Example Inc              john.doe@example.com             —
...

Enriched  : 10
Not found : 0
Saved to  : output/enriched_profiles.json
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `LEADIQ_API_KEY is not set` | `.env` file is missing or empty | Follow Setup step 3 above |
| `Error: Invalid API key` | The key in `.env` is wrong | Double-check you copied the **Secret Base64** key from LeadIQ Settings → API Keys |
| `Error 402: Insufficient credits` | Your account has no credits left | Log in to LeadIQ and check your plan |
| `Too many requests` | Requests sent too quickly | Wait a moment and try again |
| `Cannot find module` | Dependencies not installed | Run `npm install` |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
