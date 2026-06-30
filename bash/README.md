# LeadIQ API — Bash Samples

Ready-to-run shell scripts that show you how to use the LeadIQ API using only `curl` — no extra tools or languages to install.

---

## What you will need

- A **LeadIQ account** with API access enabled
- Your **Secret Base64 API key** — find it in LeadIQ under **Settings → API Keys**
- **curl** — pre-installed on macOS and most Linux distributions

To check if curl is already available:
```bash
curl --version
```

If it is missing:
```bash
# Ubuntu / Debian
sudo apt install curl

# Fedora
sudo dnf install curl
```

---

## Setting your API key

Before running any script, export your API key in the terminal:

```bash
export LEADIQ_API_KEY=ABCdef123...
```

You only need to do this once per terminal session. To avoid typing it every time, add the line to your shell profile (`~/.bashrc`, `~/.zshrc`, etc.).

---

## Running the samples

```bash
bash graphql/01_check_usage.sh
```

Replace the script path with whichever sample you want to run.

---

## Samples

### Full pipeline

If you want to run the complete workflow in a single command, use:

```bash
bash full_pipeline.sh
```

This script runs all steps end-to-end — search, enrich, create list, add prospects, export — entirely in memory. The only output is `output/pipeline_prospects.csv`.

---

The individual scripts below are numbered and build on each other. Run them in order if you want to inspect the output at each step.

### GraphQL API (`graphql/`)

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.sh` | Verifies your API key and displays your current credit usage | None |
| `graphql/02_advanced_search.sh` | Finds people by role, seniority, and location — saves their IDs to `output/advanced_search_ids.txt` | 1 per page of results |
| `graphql/03_enrich_profiles.sh` | Reads IDs from `output/advanced_search_ids.txt` and enriches each person with their work email and direct phone — saves results to `output/enriched_profiles.txt` | 1 Enrich credit per person |
| `graphql/07_find_job_changes.sh` | Finds people who recently changed jobs or were promoted, and prints the previous → current transition — saves results to `output/job_changes.txt` | 1 per page of results |

> `07_find_job_changes.sh` is a standalone alternative to `02` (not part of the numbered pipeline). It uses the same `flatAdvancedSearch` query, scoped with the job-change filters.

Expected output for `01_check_usage.sh`:

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

Expected output for `02_advanced_search.sh`:

```
Searching LeadIQ API...
  Roles       : Sales
  Seniorities : VP, Director, Manager
  Location    : New Hampshire, United States

Found 42 people. Fetching IDs (25 per page)...

  Page 1: 25 IDs fetched
  Page 2: 17 IDs fetched

Total: 42 IDs retrieved.
Saved to output/advanced_search_ids.txt
```

Expected output for `03_enrich_profiles.sh`:

```
Input file : output/advanced_search_ids.txt
Total IDs  : 42
Processing : 10 (MAX_PEOPLE=10)
API calls  : 10  (one per person)
Max credits: 10 Enrich credits

[1/10] PersonID-abc123... ... ✓ email  ✓ phone
[2/10] PersonID-def456... ... ✓ email  — phone
...

Enriched  : 10
Not found : 0
Saved to  : output/enriched_profiles.txt
```

---

### REST API (`rest/`)

The REST API endpoint is `https://prospector.leadiq.com`. It manages Prospector lists and prospects.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `rest/04_create_prospector_list.sh` | Creates a list named "Sales Leaders in New Hampshire" in the Prospector — saves the list ID to `output/prospector_list_id.txt` | None |
| `rest/05_add_prospects_to_list.sh` | Reads `output/enriched_profiles.txt` and adds each person to the list as a prospect | None |
| `rest/06_export_list_to_csv.sh` | Fetches all prospects from the list and saves them to `output/prospects.csv` — ready to open in Excel or Google Sheets | None |

Expected output for `04_create_prospector_list.sh`:

```
Creating list "Sales Leaders in New Hampshire"...
Done.

  ID         : 6627e3f1a2b3c4d5e6f70001
  Name       : Sales Leaders in New Hampshire
  Created at : 2026-04-29T14:22:31.000Z

Saved to: output/prospector_list_id.txt
```

Expected output for `05_add_prospects_to_list.sh`:

```
List ID  : 6627e3f1a2b3c4d5e6f70001
Profiles : 10

[1/10] Jane Smith ... added
[2/10] John Doe ... added
...

Added   : 10
Skipped : 0
```

Expected output for `06_export_list_to_csv.sh`:

```
List ID : 6627e3f1a2b3c4d5e6f70001

Fetching page 1... 10 prospects

Total   : 10 prospects retrieved
Saved to: output/prospects.csv
```

Expected output for `07_find_job_changes.sh`:

```
Searching LeadIQ for recent job changes...
  Change type      : JobChange
  Current role     : Sales
  Current seniority: VP
  Current industry : Computer Software
  Changed since    : 2026-04-01

Found 10 job changes. Fetching up to 10 (25 per page)...

1. Erin Walker  [JobChange · ---]
     from: Global Vice President, Direct Sales @ Lytx, Inc.
       to: Vice President, North America Sales @ MANTIS
     https://www.linkedin.com/in/erin-walker-a6b6a06

2. Vladislav Simeonov  [JobChange · ---]
     from: VP Sales, EMEA @ Press Ganey Forsta
       to: Vp, Sales @ Qualtrics
     https://www.linkedin.com/in/vladislav-simeonov-630b37b6

...

Total: 10 job changes retrieved.
Saved to output/job_changes.txt
```

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `LEADIQ_API_KEY is not set` | Key not exported | Run `export LEADIQ_API_KEY=your_key` |
| `Error: Invalid API key` | Wrong key value | Double-check the **Secret Base64** key from LeadIQ Settings → API Keys |
| `Error 402: Insufficient credits` | No credits left | Log in to LeadIQ and check your plan |
| `Too many requests` | Requests sent too quickly | Wait a moment and try again |
| `curl: command not found` | curl not installed | See install instructions above |
| `A list with this name already exists` | Sample 04 was already run | Delete the list in LeadIQ or change `LIST_NAME` in the script |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
