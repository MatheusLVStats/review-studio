# FishingMeta — review platform v1 (local)

A first working version of our own screening platform: create a review → import references → merge duplicates → assign to two reviewers → vote independently (blinded) → open reconciliation → resolve conflicts → export.

- Specification: [`docs/spec/platform-spec.md`](../docs/spec/platform-spec.md)
- What was observed in Rayyan: [`docs/rayyan-flows/`](../docs/rayyan-flows/)
- Statistics module plan: [`docs/spec/stats-module-plan.md`](../docs/spec/stats-module-plan.md)

```
platform/
  db/migrations/   PostgreSQL schema; blinding rule = rp.can_see_others()
  api/             FastAPI server (Python) + tests
  web/             Next.js (TypeScript) screens; no rules live here
  e2e/             browser test that plays three users
```

## Run it on your Mac

You need three things once: **PostgreSQL**, **Python 3.11+** and **Node 20+** (you already have Node).

1. **PostgreSQL.** Install [Postgres.app](https://postgresapp.com/) (no Homebrew needed), open it and click *Initialize*. It runs on port 5432 with your macOS user name and no password. Then, in Terminal:

   ```bash
   /Applications/Postgres.app/Contents/Versions/latest/bin/createdb review_platform
   ```

2. **API** (first terminal window):

   ```bash
   cd review-studio/platform/api
   python3 -m venv .venv && source .venv/bin/activate
   pip install -r requirements.txt
   export DATABASE_URL="postgresql://$USER@localhost:5432/review_platform"
   python -m app.db                      # creates the tables (safe to run again)
   uvicorn app.main:app --port 8000
   ```

3. **Web** (second terminal window):

   ```bash
   cd review-studio/platform/web
   npm install
   npm run build && npm start            # or: npm run dev
   ```

4. Open <http://localhost:3000>. Each person creates an account. The owner creates a review and adds the others by e-mail. To try two reviewers on one computer, use a normal window and a private window.

Settings (environment variables): `DATABASE_URL`, `FILES_DIR` (where full-text PDFs are kept, default `./files`), `WEB_ORIGINS` (default `http://localhost:3000`) for the API; `NEXT_PUBLIC_API_URL` (default `http://localhost:8000`) for the web app.

## Tests

API tests create and delete their own temporary databases, so point them at a server where you may create databases:

```bash
cd platform/api && source .venv/bin/activate
export TEST_DATABASE_ADMIN_URL="postgresql://$USER@localhost:5432/postgres"
python -m pytest -q
```

What they check (spec §13): the full flow with two reviewers and a lead; duplicate detection against the synthetic ground truth (13 records → 9 publications → 7 studies, both traps); merge then split restores the original grouping; while blinded, a reviewer cannot get the other reviewer's decision from the queue, the record, progress counts, export or PRISMA; non-members get 404 everywhere; viewers cannot vote or export; reviewers cannot assign, resolve, open reconciliation, read the audit log or change blinding; IDs from another review are not found; votes on unassigned or revealed publications are refused; vote changes keep history; resolutions leave votes untouched; κ uses first votes; votes, resolutions, source records and the audit log cannot be updated or deleted, even directly in the database.

The tests were checked against a deliberately broken blinding rule: they fail when blinding is removed.

Browser test (needs the two servers running on an empty database, and `pip install playwright && playwright install chromium`):

```bash
python platform/e2e/ui_flow.py
```

## Statistical engine

`platform/stats/engine.R` does all pooling (R + metafor). Check it against published reference values and an independent formula implementation:

```bash
cd platform/stats/validation && Rscript validate.R     # writes REPORT.md; exits 1 if any check fails
```

Needs R with the `metafor` and `jsonlite` packages. Re-run after every R or metafor upgrade.

## What v1 does not do yet

PubMed XML / NBIB / EndNote import; e-mail invitations (people register themselves, then the owner adds them); automatic PDF retrieval; data extraction, risk of bias and the statistics module (planned); sign-in through Google or the university. The Supabase-based Review Studio on the `main` branch is unchanged.

## Why only these services

PostgreSQL, one API and one web app. No queue, cache, search engine or object store: imports of a few thousand references run inside one request, and full texts are files named by their SHA-256. Each extra service will be added only with the problem it solves and the measurement that showed it (spec §2).
