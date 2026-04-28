# Running with Docker

If you are comfortable with Docker, you can run the samples without installing Python locally.

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- Your **Secret Base64 API key** from LeadIQ under **Settings → API Keys**

---

## Setup

**1. Create your environment file**

```bash
cp .env.example .env
```

Open `.env` and add your API key:

```
LEADIQ_API_KEY=ABCdef123...
```

**2. Build the image**

```bash
docker compose build
```

---

## Running a sample

```bash
docker compose run --rm leadiq python graphql/01_check_usage.py
```

Replace the script path with whichever sample you want to run.

---

## Notes

- The `--rm` flag removes the container after it finishes — no cleanup needed.
- Your `.env` file is loaded automatically by the Compose config.
- The project directory is mounted as a volume, so any changes you make to the scripts are reflected immediately without rebuilding the image.
