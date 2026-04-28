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

### GraphQL API (`graphql/`)

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.sh` | Verifies your API key and displays your current credit usage | None |
| `graphql/02_advanced_search.sh` | Finds people by role, seniority, and location — saves their IDs to `output/advanced_search_ids.txt` | 1 per page of results |
| `graphql/03_enrich_profiles.sh` | Reads IDs from `output/advanced_search_ids.txt` and enriches each person with their work email and direct phone — saves results to `output/enriched_profiles.txt` | 1 Enrich credit per person |

Expected output for `01_check_usage.sh`:

```
Connecting to LeadIQ API...
Done.

Subscription : active

Credit usage :
  Contact (Page)
  Contact (ExactMatch)
  ...
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

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `LEADIQ_API_KEY is not set` | Key not exported | Run `export LEADIQ_API_KEY=your_key` |
| `Error: Invalid API key` | Wrong key value | Double-check the **Secret Base64** key from LeadIQ Settings → API Keys |
| `Error 402: Insufficient credits` | No credits left | Log in to LeadIQ and check your plan |
| `Too many requests` | Requests sent too quickly | Wait a moment and try again |
| `curl: command not found` | curl not installed | See install instructions above |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
