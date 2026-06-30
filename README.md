# LeadIQ API Samples

Ready-to-run code samples showing how to use the LeadIQ API. Each language folder is self-contained — pick the one that fits your setup and follow its README.

---

## Languages

| Folder | Language | Requirements | How to run |
|--------|----------|--------------|------------|
| [`bash/`](bash/README.md) | Bash | `curl` — pre-installed on most systems | `bash graphql/01_check_usage.sh` |
| [`python/`](python/README.md) | Python 3.10+ | `pip install -r requirements.txt` | `python graphql/01_check_usage.py` |
| [`typescript/`](typescript/README.md) | Node.js 24+ | `npm install` | `npm run 01` |

---

## Samples

The scripts are numbered and build on each other. Run them in order, or use `full_pipeline` to run all six steps at once and produce a single CSV.

### GraphQL API (`graphql/`)

| # | Script | What it does | Credits |
|---|--------|-------------|---------|
| 01 | `check_usage` | Verify your API key and view your credit balance | None |
| 02 | `advanced_search` | Search for people by role, seniority, and location — saves their IDs | 1 per page |
| 03 | `enrich_profiles` | Enrich each person with their work email and direct phone | 1 per person |
| 07 | `find_job_changes` | Find people who recently changed jobs or were promoted — prints the previous → current transition (standalone, not part of the pipeline) | 1 per page |

### Prospector REST API (`rest/`)

| # | Script | What it does | Credits |
|---|--------|-------------|---------|
| 04 | `create_prospector_list` | Create a Prospector list named "Sales Leaders in New Hampshire" | None |
| 05 | `add_prospects_to_list` | Add the enriched profiles to the list as prospects | None |
| 06 | `export_list_to_csv` | Fetch all prospects from the list and save to `output/prospects.csv` | None |

### Full pipeline

| Script | What it does |
|--------|-------------|
| `full_pipeline` | Runs all six steps end-to-end in memory — the only output is `output/pipeline_prospects.csv` |

---

## API key

All samples authenticate with a **Secret Base64 API key**. Find yours in LeadIQ under **Settings → API Keys**.

- **Python / TypeScript** — add the key to a `.env` file (see the folder README)
- **Bash** — export it in your terminal: `export LEADIQ_API_KEY=your_key`

---

## API overview

- **GraphQL API** — `https://api.leadiq.com/graphql` — used by samples 01–03
- **Prospector REST API** — `https://prospector.leadiq.com` — used by samples 04–06

---

## Docker

Prefer not to install anything locally? A Docker setup in [`_docker/`](_docker/DOCKER.md) covers all three languages. You only need Docker Desktop.

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
