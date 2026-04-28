# Running with Docker

If you are comfortable with Docker, you can run the samples without installing Python, Node.js, or any other tool locally.

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- Your **Secret Base64 API key** from LeadIQ under **Settings → API Keys**

---

## Setup

### Python and TypeScript — use an `.env` file

Copy the example file for the language you want to use:

```bash
cp python/.env.example python/.env        # for Python
cp typescript/.env.example typescript/.env  # for TypeScript
```

Open the `.env` file and add your API key:

```
LEADIQ_API_KEY=ABCdef123...
```

### Bash — use an environment variable

```bash
export LEADIQ_API_KEY=ABCdef123...
```

---

## Build the images

From the `docker/` directory:

```bash
docker compose build
```

To build only one language:

```bash
docker compose build leadiq-python   # Python only
docker compose build leadiq-ts       # TypeScript only
docker compose build leadiq-bash     # Bash only
```

---

## Running a sample

### Python

```bash
docker compose run --rm leadiq-python python graphql/01_check_usage.py
docker compose run --rm leadiq-python python graphql/02_advanced_search.py
docker compose run --rm leadiq-python python graphql/03_enrich_profiles.py
```

### TypeScript

```bash
docker compose run --rm leadiq-ts npx ts-node graphql/01_check_usage.ts
docker compose run --rm leadiq-ts npx ts-node graphql/02_advanced_search.ts
docker compose run --rm leadiq-ts npx ts-node graphql/03_enrich_profiles.ts
```

### Bash

```bash
docker compose run --rm leadiq-bash bash graphql/01_check_usage.sh
docker compose run --rm leadiq-bash bash graphql/02_advanced_search.sh
docker compose run --rm leadiq-bash bash graphql/03_enrich_profiles.sh
```

---

## Notes

- The `--rm` flag removes the container after it finishes — no cleanup needed.
- The source directories are mounted as volumes so edits to scripts take effect immediately without rebuilding.
- For the TypeScript service, `node_modules` is kept inside the container and is not affected by the volume mount — so you do not need to run `npm install` locally.
- For the Bash service, `LEADIQ_API_KEY` is read from your current shell environment rather than an `.env` file — make sure you have run `export LEADIQ_API_KEY=...` before running `docker compose`.
