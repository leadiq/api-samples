# LeadIQ API — Python Samples

Ready-to-run Python scripts that show you how to use the LeadIQ API. No prior programming experience needed — just follow the steps below.

---

## What you will need

- A **LeadIQ account** with API access enabled
- Your **Secret Base64 API key** — find it in LeadIQ under **Settings → API Keys**
- **Python 3.10 or later** installed on your computer — see instructions below

---

## Installing Python

### Windows

1. Go to [python.org/downloads](https://www.python.org/downloads/) and click **Download Python 3.x.x**
2. Run the installer
3. **Important:** on the first screen, check the box that says **"Add Python to PATH"** before clicking Install
4. Once installed, open the **Command Prompt** (search for `cmd` in the Start menu) and verify it worked:
   ```
   python --version
   ```
   You should see something like `Python 3.12.0`.

### Mac

Mac comes with Python pre-installed, but it is often outdated. The easiest way to install a current version is through the official installer:

1. Go to [python.org/downloads](https://www.python.org/downloads/) and click **Download Python 3.x.x**
2. Open the downloaded `.pkg` file and follow the installer steps
3. Once installed, open **Terminal** (search for it in Spotlight with `Cmd + Space`) and verify:
   ```
   python3 --version
   ```
   You should see something like `Python 3.12.0`.

### Linux

Most Linux distributions include Python. Check first:

```bash
python3 --version
```

If it is missing or below 3.10, install it via your package manager:

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install python3 python3-pip python3-venv

# Fedora
sudo dnf install python3
```

---

## Setup (one time)

**1. Clone this repository**

```bash
git clone https://github.com/leadiq/api-samples.git
cd api-samples/python
```

**2. Create a virtual environment**

This keeps the dependencies for these scripts separate from anything else on your machine.

```bash
python3 -m venv .venv
```

**3. Activate the virtual environment**

On Mac / Linux:
```bash
source .venv/bin/activate
```

On Windows:
```bash
.venv\Scripts\activate
```

> You will need to activate the virtual environment each time you open a new terminal window before running scripts.

**4. Install dependencies**

```bash
pip install -r requirements.txt
```

**5. Create your environment file**

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
python graphql/01_check_usage.py
```

Replace the script path with whichever sample you want to run.

---

## Samples

### Full pipeline

If you want to run the complete workflow in a single command, use:

```bash
python full_pipeline.py
```

This script runs all steps end-to-end — search, enrich, create list, add prospects, export — entirely in memory. The only output is `output/pipeline_prospects.csv`.

---

The individual scripts below are numbered and build on each other. Run them in order if you want to inspect the output at each step.

### GraphQL API (`graphql/`)

The GraphQL API endpoint is `https://api.leadiq.com/graphql`. It supports rich queries for people, companies, and account management.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.py` | Verifies your API key and displays your current credit usage | None |
| `graphql/02_advanced_search.py` | Finds people by role, seniority, and location — saves their IDs to `output/advanced_search_ids.json` | 1 per page of results |
| `graphql/03_enrich_profiles.py` | Reads IDs from `output/advanced_search_ids.json` and enriches each person with their work email and direct phone — saves results to `output/enriched_profiles.json` | 1 Enrich credit per person |
| `graphql/07_find_job_changes.py` | Finds people who recently changed jobs or were promoted, and prints the previous → current transition — saves results to `output/job_changes.json` | 1 per page of results |

> `07_find_job_changes.py` is a standalone alternative to `02` (not part of the numbered pipeline). It uses the same `flatAdvancedSearch` query, scoped with the job-change filters.

Expected output for `01_check_usage.py`:

```
Connecting to LeadIQ API... done.

Plans:
  Name                            Product       Status        Next Billing Period
  --------------------------------------------------------------------------
  Starter Annual                  Api           active        2026-05-01T00:00:00.000Z

DataHub Plan — Starter Annual (active)
  Used      : 7
  Available : 493
  Total     : 500
  Resets    : 2026-05-01T00:00:00.000Z
```

Expected output for `02_advanced_search.py`:

```
Searching LeadIQ API...
  Roles      : Sales
  Seniorities: VP, Director, Manager
  Location   : New Hampshire, United States

Found 42 people. Fetching IDs (25 per page)...

#      ID
--------------------------------------------------
1      abc123def456
2      xyz789ghi012
3      jkl345mno678
...
42     pqr901stu234

Total: 42 IDs retrieved.
Saved to output/advanced_search_ids.json
```

Expected output for `03_enrich_profiles.py`:

```
Input file : output/advanced_search_ids.json
Total IDs  : 42
Processing : 10 (MAX_PEOPLE=10)
Batches    : 1 × up to 25 people each
Max credits: 10 Enrich credits

Batch 1/1 — enriching 10 profiles... done (10 enriched, 0 errors)

#     Name                         Title                          Company                  Work Email                       Direct Phone
----------------------------------------------------------------------------------------------------------------------------------
1     Jane Smith                   VP of Sales                    Acme Corp                jane.smith@acme.com              +16035551234
2     John Doe                     Sales Director                 Example Inc              john.doe@example.com             —
...

Enriched : 10
Errors   : 0
Saved to output/enriched_profiles.json
```

---

### REST API (`rest/`)

The REST API endpoint is `https://prospector.leadiq.com`. It manages Prospector lists and prospects.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `rest/04_create_prospector_list.py` | Creates a list named "Sales Leaders in New Hampshire" in the Prospector — saves the list details to `output/prospector_list.json` | None |
| `rest/05_add_prospects_to_list.py` | Reads `output/enriched_profiles.json` and adds each person to the list as a prospect — saves results to `output/added_prospects.json` | None |
| `rest/06_export_list_to_csv.py` | Fetches all prospects from the list and saves them to `output/prospects.csv` — ready to open in Excel or Google Sheets | None |
| `rest/08_verify_email.py` | Checks whether one or more email addresses are deliverable, without saving anything — saves the verdicts to `output/verified_emails.json` | 0.1 per email |
| `rest/09_verify_prospect_emails.py` | Reads `output/added_prospects.json` and re-verifies the work email stored on each prospect — the new status is saved on the prospect in LeadIQ, and the results to `output/verified_prospects.json` | 0.1 per prospect |
| `rest/10_verify_emails_csv.py` | Verifies every address in a CSV file, at any scale (parallel, resumable, survives interruptions) — saves the verdicts to `output/<name>_results.csv`, without saving anything in LeadIQ | 0.1 per unique email |

> `08_verify_email.py` is standalone — edit `EMAILS_TO_VERIFY` in the script, or pass addresses on the command line: `python rest/08_verify_email.py jane@acme.com`.
>
> `09_verify_prospect_emails.py` runs after `05` and verifies up to `MAX_PROSPECTS` (10) prospects; prospects without an email are skipped. You can also pass prospect IDs directly: `python rest/09_verify_prospect_emails.py 6627e3f1a2b3c4d5e6f70001`.
>
> `10_verify_emails_csv.py` is standalone — pass it any CSV with an email column: `python rest/10_verify_emails_csv.py contacts.csv`. See [Verifying a large CSV](#verifying-a-large-csv) below.

Expected output for `04_create_prospector_list.py`:

```
Creating list "Sales Leaders in New Hampshire"... done.

  ID         : 6627e3f1a2b3c4d5e6f70001
  Name       : Sales Leaders in New Hampshire
  Created at : 2026-04-29T14:22:31.000Z

Saved to  : output/prospector_list.json
```

Expected output for `05_add_prospects_to_list.py`:

```
List       : Sales Leaders in New Hampshire
List ID    : 6627e3f1a2b3c4d5e6f70001
Profiles   : 10

[1/10] Jane Smith ... added
[2/10] John Doe ... added
[3/10] Alice Johnson ... added
...
[10/10] Bob Williams ... added

Added   : 10
Skipped : 0
Saved to  : output/added_prospects.json
```

Expected output for `06_export_list_to_csv.py`:

```
List    : Sales Leaders in New Hampshire
List ID : 6627e3f1a2b3c4d5e6f70001

Fetching page 1... 10 prospects

Total   : 10 prospects retrieved
Saved to: output/prospects.csv
```

Expected output for `07_find_job_changes.py`:

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

Expected output for `08_verify_email.py`:

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

Expected output for `09_verify_prospect_emails.py`:

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
python rest/10_verify_emails_csv.py contacts.csv
```

- **Input** — any CSV with a header row. The email column is found automatically if it is called `email`, `work_email`, `workEmail` or `email_address`; otherwise pass `--column "Your Column"`.
- **Output** — `output/contacts_results.csv` (`email,status`) and `output/contacts_errors.csv` (`email,error`) for addresses that could not be checked.
- **Cost** — 0.1 credit per *unique* address. Duplicates (compared case-insensitively) are checked once, and blank or obviously malformed cells are skipped without calling the API. The script prints the maximum cost and asks before starting; pass `--yes` to skip the question in unattended runs.
- **Speed** — set `--per-minute` to your API key's rate limit (default 60, the standard Prospector API limit; every API response states it in its `ratelimit-policy` header). At 60 per minute, 100,000 addresses take about 28 hours; at 300 per minute, about 5.5 hours. Several requests run at once (`--workers`, default 10) so slow checks don't hold up the queue — you need roughly *per-minute ÷ 60 × seconds per check* workers to reach the cap. The progress line counts `429s`: a steady stream of them means `--per-minute` is higher than your key allows.
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

For long runs, keep the machine awake (on macOS: `caffeinate -i python rest/10_verify_emails_csv.py contacts.csv --yes`) or run it on a server inside `tmux`/`screen`.

Expected output:

```
Input          : contacts.csv (312,480 rows, column 'Email')
Unique emails  : 301,912
Already done   : 0 (in output/contacts_results.csv)
Malformed      : 1,204 (skipped, no credit used)
To check       : 300,708
Max credits    : 30,070.8
Est. time      : ~83.5 h at 60 requests/min

Spend up to 30,070.8 credits? [y/N] y
[598/300,708] 60/min  ETA 83.4 h  Verified=231  VerifiedLikely=148  Unverified=139  Invalid=80  errors=0  429s=0
...
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `LEADIQ_API_KEY is not set` | `.env` file is missing or empty | Follow Setup step 5 above |
| `Error: Invalid API key` | The key in `.env` is wrong | Double-check you copied the **Secret Base64** key from LeadIQ Settings → API Keys |
| `Error 402: Insufficient credits` | Your account has no credits left | Log in to LeadIQ and check your plan |
| `Too many requests` | Requests sent too quickly | Wait a moment and try again |
| `A list with this name already exists` | Sample 04 was already run | Delete the list in LeadIQ or change `LIST_NAME` in the script |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
