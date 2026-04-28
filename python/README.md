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

### GraphQL API (`graphql/`)

The GraphQL API endpoint is `https://api.leadiq.com/graphql`. It supports rich queries for people, companies, and account management.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.py` | Verifies your API key and displays your current credit usage | None |
| `graphql/02_advanced_search.py` | Finds people by role, seniority, and location — returns their IDs | 1 per page of results |

Expected output for `01_check_usage.py`:

```
Connecting to LeadIQ API... done.

Subscription status : active

Credit Type                Plan                   Used      Cap  Billing
----------------------------------------------------------------------
Contact (Page)             Starter                   5      500  monthly
Contact (ExactMatch)       Starter                   2      100  monthly
```

---

### REST API (`rest/`)

The REST API endpoint is `https://prospector.leadiq.com`. Samples coming soon.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `LEADIQ_API_KEY is not set` | `.env` file is missing or empty | Follow Setup steps 5 above |
| `Error: Invalid API key` | The key in `.env` is wrong | Double-check you copied the **Secret Base64** key from LeadIQ Settings → API Keys |
| `Error 402: Insufficient credits` | Your account has no credits left | Log in to LeadIQ and check your plan |
| `Too many requests` | Requests sent too quickly | Wait a moment and try again |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
