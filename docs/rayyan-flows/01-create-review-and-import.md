# 01 — Create review, import references, detect duplicates, invite a member

Observed with REA on 2026-11-19 in two separate Chrome profiles signed in by the user: **account A** (the user, port 9222) and **account B** (a colleague whose plan allows creating reviews, port 9223). The test review **"SYNTHETIC - teste de fluxos (nao usar)"** was created in account B. Only the synthetic files in `test-data/synthetic/` were imported.

**What was captured:** accessibility trees and screenshots only. **No network events, request or response bodies, headers, scripts or storage values were captured** (every scenario ran with `event_families: []` and `network_content` all false). Real review titles, e-mail addresses and the test review's numeric ID are not reproduced here.

Legend: **Observed** = seen on screen. **Inference** = a reading of what was seen, not verified. **Open** = not answered yet.

---

## 1.1 Home page

**Observed**

- Two tables, "Active reviews" and "Archived Reviews": Title, Date created (or Date archived), Owner, Number of articles, Actions. Archived rows have "Restore".
- Each row has a badge "Team review | Base Team" and the viewer's role in that review: **Owner**, **Collaborator** or **Reviewer** were seen.
- Only rows where the viewer is Owner have an "Invite member" action.
- "Create review" is labelled "Premium feature" in both accounts. Account A also shows an "Upgrade" button; account B does not.
- A review without articles shows "Upload — Upload articles needed" in the article-count column.

**Inference**: creation is plan-gated. Account A was not used to create anything, so whether its plan would be refused at submit is **Open**.

Evidence: `ev_a03221f9…`, `ev_6df59bb9…`, `ev_f10f6239…`.

## 1.2 Create-review wizard

**Observed**

| Step | Fields and controls |
|---|---|
| 1 Add review info | Review title * (placeholder "Review title has to be unique"); Review type * (Not applicable, Systematic review, Literature review, Umbrella review, Scoping review, Rapid review, Qualitative review, State of the art review, Mixed study review, Meta-analysis, Other); Review domain * (Not applicable, Biomedical, Environmental, Social sciences, Electrical engineering, Materials, Chemicals, Other); Description (optional). "Create new review" is disabled until required fields are filled. |
| 2 Upload articles | List of supported formats: Endnote export, Refman/RIS, CSV, BibTeX, Pubmed xml, New pubmed format/nbib, Web of science/ciw, PDF. "Select up to 10 files. If you have many, upload them in separate batches." Buttons Select files, Skip. |
| 3 Invite members | User email * ("Use comma, to add multiple emails"), User role *, Reason/message (optional). Buttons Skip, Invite. |

- Step buttons are disabled: the wizard is linear.
- **The review is created when step 1 is submitted**, before any file is uploaded: it already appears in the home list at step 2.
- After "Skip" in step 3 the app opens the review's Overview page.

Evidence: `ev_573faeb6…`, `ev_e5f1ec7f…`, `ev_f091e8d4…`, screenshots `ev_375b9270…`, `ev_8209620f…`, `ev_73e7bc1c…`.

## 1.3 Upload and import

**Inputs**: 4 files, 13 rows (2 RIS, 1 BibTeX, 1 CSV); ground truth in `test-data/synthetic/README.md`.

**Observed**

1. After "Select files": the selected files are listed with a delete icon each, plus "Select more", "Skip", "Continue". **No record count, no parsing preview and no warnings are shown before import.**
2. After "Continue": "4 reference files uploaded!", a check mark per file, a progress bar and "Upload successful!". **Still no record counts.**
3. Overview → Data summary: "Imported references 13". Review data → side panel lists each file with its own count: BibTeX 2, Embase RIS 4, MEDLINE RIS 5, CSV 2. **All 13 rows were imported; none rejected.** Each file has a "Delete" button (delete a whole import batch).
4. Display of imported fields:
   - BibTeX titles keep the protective braces: `{SYNTHETIC} Delta trial…`. RIS and CSV titles are clean.
   - Records with only a year show a full date `YYYY-01-01`.
   - Author lists are shown as imported (`Silva A.; Costa B.` from Embase, `Silva, Ana; Costa, Bruno` from MEDLINE and CSV); no normalisation is visible.
5. Records are numbered 01–13 in the list; the numbering is a display order, and it changes with filters.

**Inference**

- BibTeX brace handling and the year → 1 January conversion are import-quality defects: the first changes titles used for duplicate matching and display; the second invents a precision the source did not have.
- Whether the original file is kept and can be downloaded again is **Open**.

## 1.4 Duplicate detection

**Observed**

- Detection is **not automatic** on import ("Possible duplicates detected 0" until run).
- "Detect duplicates" → confirmation dialog ("By start detecting duplicates, Rayyan will find all duplicated articles and organize it to help you resolve them!", Cancel / Proceed) → a toast "Detect Duplicates — Finished — 7 duplicates were found".
- Overview counters: Possible duplicates detected 7, Unresolved duplicates 7; Duplicates summary: Resolved 0, Not duplicate 0, Deleted 0.
- Review data → "Possible duplicates" filter with four states: **Unresolved, Deleted, Not duplicate, Resolved**. The Unresolved list ("Showing 7 / 13 Articles") adds a **Similarity** column with a percentage per record.

| Flagged group (our ground truth) | Records flagged | Similarity shown |
|---|---|---|
| Alpha (MEDLINE + Embase + CSV) | 3 | 94% each |
| Beta (MEDLINE + Embase, no shared ID) | 2 | 95% each |
| Delta article (MEDLINE + BibTeX, same DOI) | 2 | 96% each |
| Delta conference abstract | not flagged | — |
| Epsilon correction notice | not flagged | — |

**Compared with the ground truth**: all 3 true duplicate groups were found, and both traps (conference abstract of the same study, correction notice) were correctly **not** merged. "7 duplicates" counts **records inside duplicate groups, including the one to keep**, not records to remove (4) and not pairs.

**Inference**

- The similarity score is shown per record, not per pair, so a reviewer cannot see which record it was compared with from the list alone.
- Nothing on screen links the conference abstract to the article as **two reports of one study**. Rayyan appears to have no study-level entity separate from records. **Open**: whether a "related" link exists elsewhere.

**Open**: the "Resolve duplicates" screen and "Auto resolve" (the user previously shared a screenshot: choose fields that must match and which version to keep) were not exercised yet; whether resolution is reversible.

Evidence: `ev_2b2804f9…`, `ev_19bcd61d…`, `ev_3e7aa85f…`, `ev_bf861a1e…`, `ev_51cacccc…`.

## 1.5 Review page and members

**Observed**

- Review sections: Overview, Review data, Screening, Full text screening, Data extraction, Risk of bias.
- Toolbar: **Blind Mode** (a toggle, **on by default** for the new review), Review settings, Screening criteria, Review chat, Invite members, PRISMA.
- Overview panels: Review info (editable), Data summary, Review members, Screening progress (Title & abstract) with "Your progress", "Team progress", and a "Screening summary" chart (Included, Maybe, Excluded, Unresolved conflict).
- A "Get started with rayyan" checklist: Create review, Add references, Invite members, Resolve duplicates, Define screening criteria.
- Invite dialog roles: **Collaborator, Reviewer, Viewer**. The e-mail field turns each address into a chip marked "Valid".
- Inviting an e-mail that already has a Rayyan account added the member **immediately as Active** with role Reviewer (no acceptance step seen).
- For each member the owner sees: name, e-mail, role (changeable from a menu), status, and actions **Revoke member** and **Delete member**.

**Open**: what each role may do; difference between "Revoke" and "Delete"; what an invited person without an account sees.

Evidence: `ev_e34fa9ad…`, `ev_331fa785…`.

## Limitations of this observation

- REA browser actions cannot upload files; uploads were done by the user while REA observed before and after.
- Connect mode reloads the start page before each scenario, so multi-step dialogs were repeated from the start each time.
- One run per observation; server behaviour under other inputs (larger files, malformed rows, encodings) is not established.
- Two scenarios timed out on the client side (80 s) without a result; the page state was re-read before repeating, and the invitation was sent only once.
