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
