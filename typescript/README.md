# LeadIQ API — TypeScript Samples

Ready-to-run TypeScript scripts that show you how to use the LeadIQ API. No prior programming experience needed — just follow the steps below.

---

## What you will need

- A **LeadIQ account** with API access enabled
- Your **Secret Base64 API key** — find it in LeadIQ under **Settings → API Keys**
- **Node.js 24 or later** installed on your computer — see instructions below

---

## Installing Node.js

### Windows

1. Go to [nodejs.org](https://nodejs.org/) and click **Download Node.js (LTS)**
2. Run the installer and follow the steps — the defaults are fine
3. Once installed, open the **Command Prompt** (search for `cmd` in the Start menu) and verify it worked:
   ```
   node --version
   ```
   You should see something like `v24.0.0`.

### Mac

1. Go to [nodejs.org](https://nodejs.org/) and click **Download Node.js (LTS)**
2. Open the downloaded `.pkg` file and follow the installer steps
3. Once installed, open **Terminal** (search for it in Spotlight with `Cmd + Space`) and verify:
   ```
   node --version
   ```
   You should see something like `v24.0.0`.

### Linux

The Node.js version bundled with most Linux distributions is often outdated. Use the official installer script from NodeSource to get Node.js 24:

```bash
# Ubuntu / Debian
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt install -y nodejs

# Fedora
curl -fsSL https://rpm.nodesource.com/setup_24.x | sudo bash -
sudo dnf install -y nodejs
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
npm run 01
```

Replace `01` with the number of whichever sample you want to run (`01` through `09`).

---

## Samples

### Full pipeline

If you want to run the complete workflow in a single command, use:

```bash
npm start
```

This script runs all steps end-to-end — search, enrich, create list, add prospects, export — entirely in memory. The only output is `output/pipeline_prospects.csv`.

---

The individual scripts below are numbered and build on each other. Run them in order if you want to inspect the output at each step.

### GraphQL API (`graphql/`)

The GraphQL API endpoint is `https://api.leadiq.com/graphql`. It supports rich queries for people, companies, and account management.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.ts` | Verifies your API key and displays your current credit usage | None |
| `graphql/02_advanced_search.ts` | Finds people by role, seniority, and location — saves their IDs to `output/advanced_search_ids.json` | 1 per page of results |
| `graphql/03_enrich_profiles.ts` | Reads IDs from `output/advanced_search_ids.json` and enriches each person with their work email and direct phone — saves results to `output/enriched_profiles.json` | 1 Enrich credit per person |
| `graphql/07_find_job_changes.ts` | Finds people who recently changed jobs or were promoted, and prints the previous → current transition — saves results to `output/job_changes.json` | 1 per page of results |

> `07_find_job_changes.ts` is a standalone alternative to `02` (not part of the numbered pipeline). It uses the same `flatAdvancedSearch` query, scoped with the job-change filters. Run it with `npm run 07`.

Expected output for `01_check_usage.ts`:

```
Connecting to LeadIQ API... done.

Plans:
  Name                            Product       Status        Next Billing Period
  --------------------------------------------------------------------------
  Starter Annual                  Api           Active        2026-05-01T00:00:00.000Z

Universal Plan — Starter Annual (Active)
  Used      : 7
  Available : 493
  Total     : 500
  Resets    : 2026-05-01T00:00:00.000Z
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

### REST API (`rest/`)

The REST API endpoint is `https://prospector.leadiq.com`. It manages Prospector lists and prospects.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `rest/04_create_prospector_list.ts` | Creates a list named "Sales Leaders in New Hampshire" in the Prospector — saves the list details to `output/prospector_list.json` | None |
| `rest/05_add_prospects_to_list.ts` | Reads `output/enriched_profiles.json` and adds each person to the list as a prospect — saves results to `output/added_prospects.json` | None |
| `rest/06_export_list_to_csv.ts` | Fetches all prospects from the list and saves them to `output/prospects.csv` — ready to open in Excel or Google Sheets | None |
| `rest/08_verify_email.ts` | Checks whether one or more email addresses are deliverable, without saving anything — saves the verdicts to `output/verified_emails.json` | 0.1 per email |
| `rest/09_verify_prospect_emails.ts` | Reads `output/added_prospects.json` and re-verifies the work email stored on each prospect — the new status is saved on the prospect in LeadIQ, and the results to `output/verified_prospects.json` | 0.1 per prospect |
| `rest/10_verify_emails_csv.ts` | Verifies every address in a CSV file, at any scale (parallel, resumable, survives interruptions) — saves the verdicts to `output/<name>_results.csv`, and your rows with the verdict added to `output/<name>_merged.csv`, without saving anything in LeadIQ | 0.1 per unique email |

> `08_verify_email.ts` is standalone — edit `EMAILS_TO_VERIFY` in the script, or pass addresses on the command line: `npm run 08 -- jane@acme.com`.
>
> `09_verify_prospect_emails.ts` runs after `05` and verifies up to `MAX_PROSPECTS` (10) prospects; prospects without an email are skipped. You can also pass prospect IDs directly: `npm run 09 -- 6627e3f1a2b3c4d5e6f70001`.
>
> `10_verify_emails_csv.ts` is standalone — pass it any CSV with an email column (every other column, like a person id, is optional): `npm run 10 -- contacts.csv`. See [Verifying a large CSV](#verifying-a-large-csv) below.

Expected output for `04_create_prospector_list.ts`:

```
Creating list "Sales Leaders in New Hampshire"... done.

  ID         : 6627e3f1a2b3c4d5e6f70001
  Name       : Sales Leaders in New Hampshire
  Created at : 2026-04-29T14:22:31.000Z

Saved to  : output/prospector_list.json
```

Expected output for `05_add_prospects_to_list.ts`:

```
List       : Sales Leaders in New Hampshire
List ID    : 6627e3f1a2b3c4d5e6f70001
Profiles   : 10

[1/10] Jane Smith ... added
[2/10] John Doe ... added
...

Added   : 10
Skipped : 0
Saved to  : output/added_prospects.json
```

Expected output for `06_export_list_to_csv.ts`:

```
List    : Sales Leaders in New Hampshire
List ID : 6627e3f1a2b3c4d5e6f70001

Fetching page 1... 10 prospects

Total   : 10 prospects retrieved
Saved to: output/prospects.csv
```

Expected output for `07_find_job_changes.ts`:

```
Searching LeadIQ for recent job changes...
  Change type      : JobChange
  Current role     : Sales
  Current seniority: VP
  Current industry : Computer Software
  Changed since    : 2026-04-01

Found 10 job changes. Fetching up to 10 (25 per page)...

1. Erin Walker  [JobChange · 2026-05-01T00:00Z]
     from: Global Vice President, Direct Sales @ Lytx, Inc.
       to: Vice President, North America Sales @ MANTIS
     https://www.linkedin.com/in/erin-walker-a6b6a06

2. Vladislav Simeonov  [JobChange · 2026-05-01T00:00Z]
     from: VP Sales, EMEA @ Press Ganey Forsta
       to: Vp, Sales @ Qualtrics
     https://www.linkedin.com/in/vladislav-simeonov-630b37b6

...

Total: 10 job changes retrieved.
Saved to output/job_changes.json
```

Expected output for `08_verify_email.ts`:

```
Emails     : 2
Max credits: 0.2

[1/2] jane.smith@acme.com ... Verified
[2/2] old.address@example.com ... Invalid

Verified       : 1
VerifiedLikely : 0
Unverified     : 0
Invalid        : 1
Skipped        : 0
Saved to       : output/verified_emails.json
```

Expected output for `09_verify_prospect_emails.ts`:

```
Prospects  : 10 (MAX_PROSPECTS=10)
Max credits: 1.0

[1/10] Jane Smith ... jane.smith@acme.com  Unverified → Verified
[2/10] John Doe ... john.doe@example.com  VerifiedLikely → VerifiedLikely
...

Verified       : 6
VerifiedLikely : 2
Unverified     : 1
Invalid        : 1
Skipped        : 0
Saved to       : output/verified_prospects.json
```

---

## Verifying a large CSV

`rest/10_verify_emails_csv` checks every address in a CSV file and writes the verdicts to a new CSV. It is built for big files — hundreds of thousands of rows:

```bash
npm run 10 -- contacts.csv
```

- **Input** — any CSV with a header row. The email column is found automatically if it is called `email`, `work_email`, `workEmail` or `email_address`; otherwise pass `--column "Your Column"`. It is the only column you need: any others (person id, name, company, your own ids) are optional — they are not sent to the API, and are copied unchanged into the merged file.
- **Output** — `output/contacts_results.csv` (`email,status`), `output/contacts_errors.csv` (`email,error`) for addresses that could not be checked, and `output/contacts_merged.csv`: every row of your file with all its columns, plus `verification_status` and `verification_error`, so you can match each verdict back to your records. Rows that share an address get the same verdict. The merged file is rewritten at the end of every run; rows not checked yet (the run stopped early) have both columns empty until you run the command again.
- **Cost** — 0.1 credit per *unique* address. Duplicates (compared case-insensitively) are checked once, and blank or obviously malformed cells are skipped without calling the API. The script prints the maximum cost and asks before starting; pass `--yes` to skip the question in unattended runs.
- **Speed** — `--per-minute` defaults to 900. The verify-email limit is 450 requests per minute per API key on *each* API server, and the API runs on 2 servers that share the traffic, so a key gets 900 a minute in total (the `ratelimit-policy` header in each response shows one server's 450, not the total). At 900 per minute, 100,000 addresses take about 2 hours. Several requests run at once (`--workers`, default 150) so slow checks don't hold up the queue — you need roughly *per-minute ÷ 60 × seconds per check* workers to reach the cap. The progress line counts `429s`: a steady stream of them means `--per-minute` is higher than your key allows.
- **Errors** — rate limits (429), server errors (5xx), timeouts and connection drops are retried up to 5 times with a growing pause. After a 429, every request waits until the API's rate-limit window resets (from its `Retry-After` or `ratelimit` header). Addresses that still fail go to the errors file; running the command again retries them — after every other address, so a few addresses whose mail servers never answer can't hold up the rest.

### If the run is interrupted

Every verdict is written to the results file the moment it arrives, so a stopped run never loses an answer it already paid for. To continue, run **the same command again** — addresses already in the results file are skipped, so nothing is checked or charged twice.

| What happened | What the script does |
|---|---|
| Ctrl+C, `kill`, or the terminal window closed | Stops starting new requests, waits for the ones in flight so their answers are saved, then exits. Press Ctrl+C a second time to quit immediately. |
| The process was killed outright (`kill -9`, crash, power cut) | Everything already written is kept. A half-written last line is detected and that address is checked again. |
| The API or your network went down | Once 10 addresses in a row have failed and the API hasn't answered anything for 5 minutes, the run stops instead of filling the errors file. |
| Out of credits (402) or invalid key (401) | Stops at once; results so far are kept. |
| You start a second run on the same file while one is going | The second run refuses to start, so no address is paid for twice. A lock left behind by a killed run is detected and taken over automatically. |

Exit codes, for wrapper scripts and schedulers: `0` finished, `1` needs a fix (key, credits), `3` stopped early — run again to continue.

For long runs, keep the machine awake (on macOS: `caffeinate -i npm run 10 -- contacts.csv --yes`) or run it on a server inside `tmux`/`screen`.

Expected output:

```
Input          : contacts.csv (312,480 rows, column 'Email')
Unique emails  : 301,912
Already done   : 0 (in output/contacts_results.csv)
Malformed      : 1,204 (skipped, no credit used)
To check       : 300,708
Max credits    : 30,070.8
Est. time      : ~5.6 h at 900 requests/min

Spend up to 30,070.8 credits? [y/N] y
[9,000/300,708] 900/min  ETA 5.4 h  Verified=3,477  VerifiedLikely=2,228  Unverified=2,092  Invalid=1,203  errors=0  429s=0
...
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
| `A list with this name already exists` | Sample 04 was already run | Delete the list in LeadIQ or change `LIST_NAME` in the script |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
