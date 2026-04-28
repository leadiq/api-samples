# LeadIQ API — Python Samples

Ready-to-run Python scripts that show you how to use the LeadIQ API.

---

## What you will need

- A **LeadIQ account** with API access enabled
- Your **Secret Base64 API key** — find it in LeadIQ under **Settings → API Keys**
- Either **Docker Desktop** or **Python 3.10+** installed on your machine (see options below)

---

## Setup (one time)

**1. Clone this repository**

```bash
git clone https://github.com/leadiq/api-samples.git
cd api-samples/python
```

**2. Create your environment file**

```bash
cp .env.example .env
```

**3. Add your API key**

Open the `.env` file in any text editor and replace the placeholder with your real key:

```
LEADIQ_API_KEY=ABCdef123...   ← paste your Secret Base64 key here
```

Save the file. You only need to do this once.

---

## Running the samples

Choose the option that matches what you have installed.

### Option A — Docker (no Python required)

If you have [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed, you do not need Python on your machine. Docker handles everything.

```bash
docker compose run --rm leadiq python graphql/01_check_usage.py
```

The first run will take a minute to download and build the image. Subsequent runs are much faster.

---

### Option B — Python directly

If you have Python 3.10 or later installed, you can run the scripts without Docker.

**1. Create a virtual environment** (keeps dependencies isolated from the rest of your system)

```bash
python3 -m venv .venv
```

**2. Activate it**

On Mac / Linux:
```bash
source .venv/bin/activate
```

On Windows:
```bash
.venv\Scripts\activate
```

**3. Install dependencies**

```bash
pip install -r requirements.txt
```

**4. Run a sample**

```bash
python graphql/01_check_usage.py
```

> The virtual environment only needs to be created and set up once. After that, just activate it (`source .venv/bin/activate`) before running scripts.

---

## Samples

### GraphQL API (`graphql/`)

The GraphQL API endpoint is `https://api.leadiq.com/graphql`. It supports rich queries for people, companies, and account management.

| Script | What it does | Credits used |
|--------|-------------|--------------|
| `graphql/01_check_usage.py` | Verifies your API key and displays your current credit usage | None |

Expected output:

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
| `LEADIQ_API_KEY is not set` | `.env` file is missing or empty | Follow Setup steps 2 and 3 above |
| `Error: Invalid API key` | The key in `.env` is wrong | Double-check you copied the **Secret Base64** key from LeadIQ Settings → API Keys |
| `Error 402: Insufficient credits` | Your account has no credits left | Log in to LeadIQ and check your plan |
| `Too many requests` | Requests sent too quickly | Wait a moment and try again |

---

## Questions or issues?

Contact the LeadIQ API team at [api@leadiq.com](mailto:api@leadiq.com).
