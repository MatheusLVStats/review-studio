# 01 — Create review and import references (in progress)

Observed with REA `capture_browser_scenario` in **connect** mode on a separate Chrome profile signed in by the user, 2026-11-19. Captures requested: accessibility tree and screenshot only. **No network events, request bodies, response bodies, headers, scripts or storage were captured** (`event_families: []`, `network_content` all false).

Real review titles seen on the home page are not reproduced here.

## 1.1 Home page (user account A)

**Observed**

- Two tables, "Active reviews" and "Archived Reviews", with columns Title, Date created (or Date archived), Owner, Number of articles, Actions. Archived rows have a "Restore" button.
- Each row carries a badge "Team review | Base Team" and a role badge. Roles seen on this account: **Collaborator** and **Reviewer**.
- The "Create review" button is labelled **"Premium feature"** (accessible name `Premium feature Create review`, with a diamond icon). An "Upgrade" button is in the header.

**Inference (not verified)**

- Creating a review depends on the plan of the account. Account A can open the dialog; whether the server accepts the creation on this plan was **not tested**, to avoid creating anything in account A.
- "Collaborator" and "Reviewer" are different permission levels. What each one can do was not observed yet.

Evidence: REA `ev_a03221f9…` (home screenshot), `ev_6df59bb9…` (dialog accessibility tree).

## 1.2 Create-review dialog

**Observed** (dialog opened and closed without saving)

| Element | Observation |
|---|---|
| Wizard | Three steps: "1 Add review info", "2 Upload articles", "3 Invite members". Step buttons are disabled (cannot jump ahead). |
| Review title * | Required text box. Placeholder: "Review title has to be unique". |
| Review type * | Required list: Not applicable, Systematic review, Literature review, Umbrella review, Scoping review, Rapid review, Qualitative review, State of the art review, Mixed study review, Meta-analysis, Other. |
| Review domain * | Required list: Not applicable, Biomedical, Environmental, Social sciences, Electrical engineering, Materials, Chemicals, Other. |
| Description | Optional text box. Placeholder: "Describe your review!". |
| Buttons | "Cancel"; "Create new review" (disabled while required fields are empty). |

**Inference (not verified)**

- Title uniqueness is stated by the placeholder only. Whether uniqueness is per user, per team or global, and whether the server enforces it, is unknown.
- Review type and domain look like labels; whether they change any behaviour was not observed.

Evidence: REA `ev_573faeb6…` (type list), `ev_e5f1ec7f…` (domain list).

## Still to observe

- Step 2 "Upload articles": accepted formats, per-file preview, error messages, what is shown after import (counts per file), handling of the CSV and BibTeX test files.
- Duplicate detection after import, compared with the ground truth in `test-data/synthetic/README.md`.
- Step 3 "Invite members" and roles offered.

## Limitations

- REA's browser actions do not include file upload (`goto`, `click`, `fill`, `press`, `select_option`, `check`/`uncheck`, `wait_for`, `request`, `wait_for_timeout`). The upload step has to be done by a person; REA observes the screen before and after.
- Connect mode reloads the start page before each scenario, so unsaved form state is lost between scenarios.
- One controlled replay per observation; it does not establish what the server does in other conditions.
