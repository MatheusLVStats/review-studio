# Review platform v1 — specification

Status: draft for the first local version (branch `platform-v2`).
Inputs: `docs/rayyan-flows/01-*`, `02-*` (what a user sees in Rayyan), the Review Studio rules already approved in the `rs` schema, PRISMA 2020 and the Cochrane Handbook (chapter 4: two independent reviewers, documented resolution).

Server rules here are **our** decisions. They are not copied from Rayyan; nothing in Rayyan's server was observed.

Words used with one meaning only:

| Term | Meaning |
|---|---|
| **Source record** | One entry exactly as it came in one imported file (one RIS block, one BibTeX entry, one CSV row). Never edited, never deleted. |
| **Publication** | One bibliographic item after deduplication (an article, an abstract, a registry entry). Groups one or more source records. The unit of title/abstract screening. |
| **Study** | One investigation (one trial, one cohort). Groups one or more publications (article + conference abstract + registry entry). The unit of data extraction and analysis. |
| **Stage** | `ta` (title/abstract) or `ft` (full text). |
| **Vote** | One reviewer's decision on one publication at one stage. Append-only. |
| **Resolution** | A separate decision that settles a conflict. Does not change any vote. |

---

## 1. Scope of v1

In: create review → import RIS/BibTeX/CSV → detect and merge duplicates (reversible) → add members → assign publications to two reviewers → independent blinded votes → open reconciliation → resolve conflicts → export. Full-text stage with file upload and "not retrieved" status. Audit log of every change.

Out (later): PubMed XML/NBIB/EndNote XML import, automatic retrieval of PDFs, data extraction forms (planned in `docs/spec/stats-module-plan.md`), risk of bias, AI suggestions, e-mail invitations, single sign-on.

## 2. Architecture and the simplifications chosen

| Part | v1 choice | Why this and not more |
|---|---|---|
| Database | PostgreSQL 16 | Requested. Constraints and append-only triggers live here, so the rules hold whatever client calls. |
| API | FastAPI (Python), raw SQL via psycopg 3 | Requested. No ORM: the blinding queries must be readable and reviewable as SQL. |
| Web | Next.js (TypeScript), calls the API | Requested. Holds no rules; everything it shows comes from the API already filtered. |
| Migrations | Numbered `.sql` files run by a 30-line runner | Alembic adds a model layer we do not use. |
| Auth | E-mail + password, scrypt hash (Python standard library), opaque session token stored hashed | No external identity provider is needed for a local team version. OAuth can be added in front later without changing review rules. |
| Files (full text) | Local directory, file name = SHA-256 of content; metadata in Postgres | No object store until files must be shared across machines. |
| Background jobs | None | Import of a few thousand records and duplicate detection run inside the request in well under a minute. A queue is added only when a measured import exceeds that. |
| Cache, search engine, message broker | None | Not needed for team-sized reviews (< 50 000 records). |

Each added service must state the problem it solves and the measurement that showed the problem.

## 3. Data model

All tables have `review_id` (except users/sessions) and every query filters by it, so an ID from another review is never found (returns 404, not 403, to avoid confirming it exists).

```
users(id, email unique, display_name, password_hash, created_at)
sessions(token_sha256 pk, user_id, created_at, expires_at)

reviews(id, title, description, created_by, created_at,
        blind_mode bool default true,          -- review-wide switch, see §6
        ta_conflict_rule text default 'exclude_vs_other',
        reviewers_per_publication int default 2,
        require_reason_ft_exclude bool default true,
        require_reason_ta_exclude bool default false)
members(review_id, user_id, role in ('owner','lead','reviewer','viewer'), added_by, added_at, removed_at)
stage_state(review_id, stage, reconciliation_open bool, opened_by, opened_at)

import_batches(id, review_id, filename, format in ('ris','bibtex','csv'), file_sha256, file_bytes bytea,
               uploaded_by, uploaded_at, n_entries, n_ok, n_warnings, n_failed)
source_records(id, review_id, batch_id, ordinal, raw_text, fields jsonb, warnings text[])     -- immutable

publications(id, review_id, title, abstract, year, doi_norm, pmid, journal, authors text[], kind, created_at)
publication_sources(id, review_id, publication_id, source_record_id,
                    linked_at, linked_by, link_reason,           -- 'import' | 'merge'
                    unlinked_at, unlinked_by, unlink_reason)     -- never deleted
dedup_candidates(id, review_id, publication_a, publication_b, rule, score, blockers text[],
                 status in ('open','merged','rejected'), decided_by, decided_at)

studies(id, review_id, label, created_by, created_at)
study_publications(study_id, publication_id, role in ('primary','secondary'), linked_by, linked_at, unlinked_at, unlinked_by)

reason_labels(id, review_id, stage in ('ta','ft','both'), label, active)
assignments(review_id, stage, publication_id, user_id, assigned_by, assigned_at)  pk(review_id, stage, publication_id, user_id)
votes(id, review_id, stage, publication_id, user_id, decision in ('include','exclude','maybe'),
      reason_id, note, created_at, supersedes_id, after_reveal bool)            -- append-only
resolutions(id, review_id, stage, publication_id, decision in ('include','exclude'),
            reason_id, note, resolved_by, created_at, supersedes_id)            -- append-only

fulltext_files(id, review_id, publication_id, sha256, filename, bytes, uploaded_by, uploaded_at)
retrieval(review_id, publication_id, status in ('pending','retrieved','not_retrieved'), note, updated_by, updated_at)

audit_log(id, review_id, actor_id, action, entity, entity_id, detail jsonb, created_at)   -- append-only
```

Append-only is enforced by triggers that reject `UPDATE` and `DELETE` on `source_records`, `votes`, `resolutions` and `audit_log`. The "current" vote of a reviewer is the newest row for (stage, publication, user); "current" resolution likewise.

### Why three levels

Rayyan keeps records and duplicate groups, and has no study level (flow 01, §1.5: the Delta article and its conference abstract stay separate items with no link). We need all three:

- PRISMA counts **records identified** (source records), **records after duplicates removed** (publications) and **studies included** with **reports** (publications) per study.
- Screening is per publication. Extraction and analysis are per study, so a trial reported twice is counted once.

## 4. Import

**Formats:** RIS (`TY` … `ER`), BibTeX (`@type{key, field = {…}}`), CSV (header row; recognised columns `title, abstract, authors, year, journal, doi, pmid, key`, case-insensitive; other columns kept in `fields`).

**Rules**

1. The uploaded file is stored whole with its SHA-256. Uploading the same file twice to the same review is refused (409) with the earlier batch named.
2. Each entry becomes one source record with its exact `raw_text`, its parsed `fields` and any warnings (missing title, unparseable year, unbalanced braces). Entries that cannot be parsed at all are counted as failed and listed in the response with their position; nothing is silently dropped.
3. Normalisation for matching only (the source record keeps the original): DOI lower-cased, `https://doi.org/` and `doi:` prefixes removed; BibTeX braces removed from titles; year = first 4-digit number.
4. Every source record creates its own publication at import (one-to-one). Merging happens only through §5.
5. The response and the batch row report: entries found, imported, with warnings, failed. (Rayyan showed no counts at upload; flow 01, §1.3.)

## 5. Duplicate detection and merging (reversible)

**Candidate rules**, in order, between publications of the same review:

| Rule | Match | Score |
|---|---|---|
| `doi` | same normalised DOI | 1.0 |
| `pmid` | same PMID | 1.0 |
| `title_year` | same normalised title (lower case, punctuation and spaces collapsed) and same year | 0.9 |

**Blockers** (a candidate with a blocker is never merged automatically and is shown with the blocker): title or type indicates *correction, erratum, retraction, comment, reply, protocol*; the two `kind`s differ (e.g. journal article vs conference abstract); years differ by more than one.

**Actions** (owner or lead):

- `merge(candidate)`: unlinks the source records of publication B and links them to publication A (`link_reason='merge'`), marks B as merged into A. Votes already on B stay on B and are reported as a warning; merging a publication that has votes needs `force=true`.
- `reject(candidate)`: records "not duplicate".
- `split(publication, source_record)`: unlinks one source record and gives it a new publication (or restores its original one). This undoes any merge.
- `auto-merge`: merges every open candidate with score 1.0 and no blocker, in one transaction, listing what it did. It is a convenience and can be undone with `split`.

Nothing is deleted. The history of every link is in `publication_sources` and `audit_log`.

Expected result on `test-data/synthetic/` (13 entries → 9 publications → 8 studies): Alpha 3 copies merged, Beta 2 copies found only by `title_year`, Delta article 2 copies merged, Delta conference abstract **not** merged (blocker: different kind) but linkable at study level, Epsilon correction **not** merged with Alpha (blocker).

## 6. Team, roles and permissions

| Action | owner | lead | reviewer | viewer |
|---|---|---|---|---|
| Read review, publications | ✓ | ✓ | ✓ | ✓ |
| Import, deduplicate, manage studies | ✓ | ✓ | — | — |
| Add/remove members, change roles | ✓ | — | — | — |
| Assign publications | ✓ | ✓ | — | — |
| Vote | if assigned | if assigned | if assigned | — |
| Open reconciliation, resolve conflicts | ✓ | ✓ | — | — |
| Change blind mode | ✓ | — | — | — |
| Export | ✓ | ✓ | ✓ (own view, §8) | — |

There is always exactly one owner. The owner cannot remove themself while owner.

## 7. Assignment, blinding and voting

**Assignment.** A lead assigns each publication to `reviewers_per_publication` members (default 2) for a stage. Bulk assignment "all unassigned to A and B" is one call. A reviewer may vote only on publications assigned to them.

**Blinding is a server rule, applied in every response.** Define, for viewer *U*, publication *P*, stage *S*:

```
can_see_others(U, P, S) :=
      reviews.blind_mode = false
   OR ( stage_state.reconciliation_open(S)
        AND every reviewer assigned to P at S has a current vote
        AND ( U is assigned to P at S          -- they already voted, so seeing can't bias that vote
              OR U.role in (owner, lead) ) )
```

When `can_see_others` is false for *U*:

- Other reviewers' votes, notes and reasons on *P* are absent from every response (list, detail, export, counts), not merely hidden by the web page.
- *U* gets only their own vote and a status of `pending`/`voted` for *P*; never `conflict`, `agreed`, or the combined decision.
- **No aggregate that depends on other reviewers' decisions** is returned to a member who is assigned in that stage: no team include/exclude/conflict counts. (Rayyan shows these in the overview while blind; flow 02, §2.4.) They receive their own counts and the number of publications still awaiting any vote. An owner/lead who is **not** assigned in the stage may see per-reviewer progress (how many voted), not decisions.

**Voting**

- A vote needs `decision`; `reason_id` is required when the review requires it for that stage and decision is `exclude`.
- Changing a vote inserts a new row with `supersedes_id`; the old row stays. The UI shows "changed" with the time.
- Once *P* is revealed (`can_see_others` true for its assigned reviewers because reconciliation is open), its votes are **locked**: a reviewer can no longer vote on it (409 `votes_locked`). Disagreements from then on are settled only by a resolution. (In Rayyan a reviewer changes their vote to resolve, and the disagreement disappears from view; flow 02, §2.6.)
- If `blind_mode` is turned off by the owner, votes cast while unblinded are flagged `after_reveal = true` for reporting.

## 8. Conflicts, reconciliation and final decisions

**Status of a publication at a stage**, computed from the current votes of its assigned reviewers:

| Votes (all assigned reviewers) | `ta` status | `ft` status |
|---|---|---|
| some missing | `pending` | `pending` |
| all exclude | `excluded` | `excluded` if all chose the same reason, else `conflict` |
| all include | `included` | `included` |
| include + maybe, or all maybe | `included` (flag `uncertain`) | `conflict` |
| exclude + (include or maybe) | `conflict` | `conflict` |

The `ta` rule is `ta_conflict_rule = 'exclude_vs_other'` (stored with the review). It differs from what Rayyan displayed (Maybe + Exclude shown as "Maybe"); our rule treats it as a conflict because the two reviewers disagree on whether to exclude.

**Final decision** = current resolution if one exists, else the status above when it is `included`/`excluded`. Publications with a final `ta` include move to `ft`.

**Reconciliation flow**

1. Lead calls `open_reconciliation(stage)`. Response: how many publications are revealed now, how many are still pending (they stay blind until their votes are complete).
2. Lead lists conflicts: each with all votes, reasons, notes and who cast them.
3. Lead posts a resolution (decision, reason if exclude, note). Votes are untouched.
4. Agreement statistics (raw agreement, Cohen's κ) are computed from the **first independent** votes, not from resolutions.

## 9. Full text

- A publication enters `ft` when its final `ta` decision is include.
- Lead uploads a PDF (stored by SHA-256) or marks `not_retrieved` with a note. A `not_retrieved` publication cannot be voted on at `ft` and is reported in PRISMA as "reports not retrieved", never as excluded.
- Full-text votes use the same assignment, blinding and reconciliation rules.

## 10. Export

`GET /reviews/{id}/export?stage=ta&format=csv|ris`

- Columns: publication ID, title, year, DOI, PMID, source files, status, final decision, resolution note; and, **only for rows where `can_see_others` is true for the requester**, one column per reviewer with their first and current vote. For a blinded requester the reviewer columns contain only their own vote and the status column shows `pending`/`voted`.
- RIS export of publications with final include, with the original source records available as a separate export.
- Every export is logged in `audit_log` with the requester, filters and row count.
- PRISMA counts endpoint: identified (source records, per file), duplicates removed, screened, excluded at `ta`, sought, not retrieved, assessed, excluded at `ft` with reasons, included publications and studies. Counts that depend on other reviewers' decisions follow the same blinding rule.

## 11. Audit

Every write inserts one `audit_log` row in the same transaction: actor, action, entity, entity ID, and a `detail` object. Detail never contains passwords, tokens or file bytes. Reading the audit log is limited to owner/lead, and entries that contain decisions follow the blinding rule.

## 12. API outline (v1)

```
POST /auth/register   POST /auth/login   POST /auth/logout   GET /me
POST /reviews                          GET /reviews            GET /reviews/{r}
PATCH /reviews/{r}                     (owner: blind_mode, rules)
POST /reviews/{r}/members              DELETE /reviews/{r}/members/{u}
POST /reviews/{r}/imports  (multipart) GET /reviews/{r}/imports
POST /reviews/{r}/dedup/detect         GET /reviews/{r}/dedup/candidates
POST /reviews/{r}/dedup/candidates/{c}/merge | /reject
POST /reviews/{r}/dedup/auto-merge     POST /reviews/{r}/publications/{p}/split
POST /reviews/{r}/studies              POST /reviews/{r}/studies/{s}/publications
POST /reviews/{r}/assignments          (bulk)
GET  /reviews/{r}/screening/{stage}    (my queue, blinded)
GET  /reviews/{r}/publications/{p}?stage=  (detail, blinded)
POST /reviews/{r}/publications/{p}/votes
POST /reviews/{r}/stages/{stage}/reconciliation
GET  /reviews/{r}/stages/{stage}/conflicts
POST /reviews/{r}/publications/{p}/resolutions
GET  /reviews/{r}/progress?stage=      (blinded counts)
GET  /reviews/{r}/export?stage=&format=
GET  /reviews/{r}/prisma
GET  /reviews/{r}/audit
```

Errors use one shape: `{"error": "<code>", "message": "<plain sentence>"}`.

## 13. Tests that must pass before any release

1. The full flow on the synthetic files with two reviewers and one lead.
2. Duplicate detection reproduces the ground truth in `test-data/synthetic/README.md`, including both traps.
3. Merge followed by split restores the original grouping.
4. While blind: reviewer B cannot obtain A's vote through the queue, the detail, progress counts, export, PRISMA or audit endpoints.
5. While blind: no endpoint returns team-level combined counts to an assigned reviewer.
6. Non-member gets 404 on every review endpoint; viewer cannot vote; reviewer cannot assign, resolve, open reconciliation, export others' votes or change blind mode.
7. A publication ID or candidate ID from another review is not found.
8. A vote on an unassigned publication is refused; a vote after reveal is refused; a vote change keeps the earlier vote.
9. A resolution does not alter votes; κ is computed from first votes.
10. `UPDATE`/`DELETE` on votes, resolutions, source records and audit log fail at the database.
