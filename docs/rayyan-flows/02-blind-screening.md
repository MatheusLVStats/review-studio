# 02 — Blind title/abstract screening, conflicts and resolution

Observed with REA on 2026-11-19 in the same two Chrome profiles as flow 01: **account A** (the user, role *Reviewer* in the test review) and **account B** (the review *Owner*). Only the test review "SYNTHETIC - teste de fluxos (nao usar)" was opened. Real reviews were not opened.

**What was captured:** accessibility trees and the URL after each step. **No network events, request or response bodies, headers, scripts or storage values were captured** (`event_families: []`, `network_content` all false). E-mail addresses, real review titles and the test review's numeric ID are not reproduced. The internal article ID shown on screen is also omitted.

Legend: **Observed** = seen on screen. **Inference** = a reading of what was seen, not verified. **Open** = not answered yet.

---

## 2.1 Vote plan used

Four synthetic records were voted on. The plan was chosen so that every pair type appears once.

| Record | Account B (owner) | Account A (reviewer) | Pair type |
|---|---|---|---|
| Gamma | Exclude | Include | Include × Exclude |
| Zeta | Include | Include | agreement (include) |
| Eta | Maybe | Exclude | Maybe × Exclude |
| Epsilon | Exclude | Exclude | agreement (exclude) |

The other 9 records were left undecided. Duplicates were **not** resolved before screening (7 records still in unresolved duplicate groups), so duplicate copies of Alpha, Beta and Delta are each in the list.

## 2.2 Screening screen

**Observed**

- Left: article list. Each item shows a sequence number, a checkbox, the title, the date (year-only dates appear as `YYYY-01-01`) and a group "Article tags".
- Right: "Abstract content" region with an internal numeric article ID, the title, a "Copy DOI" button, the notice "Author and journal details are hidden for this review" with a **Show** button, "See more", and the abstract.
- Vote buttons: **Include**, **Maybe**, **Exclude**. Next to them: Reason, Label, Analyze. Toolbar: Search, Samples, PICO, Ratings (AI), Attach PDF, AI Reviewer, Filters, Sort.
- A note box ("Add note") under the abstract.
- The selected article is in the URL as `?article=<n>`; the inclusion filter as `?inclusion=all|undecided|…|conflict`.

**Inference**: "Author and journal details are hidden" is a review-level setting, separate from Blind Mode. Any reviewer can press Show, so it hides authors only from view, not from access. Not tested further.

## 2.3 Casting a vote

**Observed**

- One click on Include/Maybe/Exclude applies the vote at once. No reason is requested, including for Exclude.
- The pressed button changes to "Click to remove: <Decision>"; clicking it again removes the vote.
- A tag "<Decision> by <the voter's e-mail>" appears on the article.
- **After a vote the app moves to the next article on its own** (the `article` number in the URL changes within about 1.5 s).
- **Changing a vote silently replaces the previous one.** No confirmation and no visible history. This happened by accident during the test: a wait for "Eta trial" matched "Zeta trial" (substring), and a Maybe overwrote B's Include on Zeta. It was detected only through the filter counts and corrected by voting Include again.

**Inference**: auto-advance plus one-click voting makes accidental votes easy. Because no history is visible, a reviewer cannot see that a vote was changed. Whether the server keeps vote history is **Open** (not visible to members; no export was examined yet).

Evidence: `ev_2f01c8ed…` (B, Epsilon Exclude), `ev_1cb20133…` (A, four votes).

## 2.4 What each reviewer sees while Blind Mode is on

**Observed**

| Where | Account A after B voted, before A voted | Account A after both voted | Account B after both voted |
|---|---|---|---|
| Inclusion filter counts | Undecided 13, all others 0 | Undecided 9, Excluded 2, Maybe 0, Included 2 | Undecided 9, Excluded 2, Maybe 1, Included 1 |
| "Conflict" filter | disabled, label "Blind Mode on" | disabled | disabled |
| Article tags | none from B | own decision only | own decision only |
| Overview "Your progress" | — | Screened 4, 31%, Inc 2 / Maybe 0 / Exc 2 | Screened 4, 31%, Inc 1 / Maybe 1 / Exc 2 |
| **Overview "Screening summary"** | not captured | **Included 1, Maybe 1, Excluded 1, Unresolved conflict 1** | same |

- The Blind Mode button is shown as pressed for both roles. Only the owner's member table has role menus and Revoke/Delete buttons.
- "Your progress" includes "Time spent" (hours and minutes) per member.

**Inference — a blinding leak in the overview.** While Blind Mode is on, the Screening summary shows team-level combined results to a *Reviewer*. Account A knows its own votes (Include on Gamma and Zeta, Exclude on Eta and Epsilon). From "Included 1, Maybe 1, Excluded 1, conflict 1" it can work out that B disagreed on one of its includes and voted Maybe on one of its excludes. With a small number of records this identifies B's votes almost exactly. Our platform must not show combined counts to reviewers while blinding is active (see `docs/spec/`).

**Inference — combination rule.** The summary is consistent with this rule, and with no other simple rule on these four pairs:

| Pair | Combined status shown |
|---|---|
| Include + Include | Included |
| Exclude + Exclude | Excluded |
| Include + Exclude | Unresolved conflict |
| Maybe + Exclude | Maybe (not a conflict) |

Pairs not tested: Include + Maybe, Maybe + Maybe, one vote only. **Open.** We do not adopt this rule; our own rule is defined in the spec.

Evidence: `ev_52731633…` (A before voting), `ev_a2cedc10…` (A overview), `ev_52407d22…` (B overview).

## 2.5 Turning Blind Mode off

**Observed**

- Owner clicks "Blind Mode" → dialog **"Blind Off"**: "Blind Mode off allows members to see each other's decisions!" with Cancel / **Turn Off Blind**.
- After confirming: toast "Blind Mode has been turned Off.", the button loses its pressed state with tooltip "Turn On Blind Mode", and a "New chat activity" indicator appears.
- The review chat contains a system message **"Review blind: Off"**. The same chat also lists, as "Rayyan systems bot", each file import start and success and "Deduplication started / finished".
- The filter menu gains the line **"Conflict resolution method: Consensus"** and the Conflict item becomes active.
- Article tags now show **both** decisions with each voter's e-mail.
- **The filter counts change meaning.** For account A they became Included 2, Maybe 1, Excluded 1, Conflict 1→0 (see 2.6). Its own votes were still Include 2 / Exclude 2. The counts are now the combined team status, not the viewer's own votes.

**Inference**: turning blinding off is a review-wide switch, not per article and not per member. It is reversible from the same button (not tested). The chat doubles as a visible activity log, but it is a free-text chat, not a structured audit trail.

Evidence: `ev_b22b5944…` (dialog), `ev_15b86dd3…` (after confirming), `ev_7181dd77…` (chat).

## 2.6 Conflicts and resolution

**Observed**

- Conflict filter: "Showing 1 / 13 Conflict articles" — only **Gamma** (Include × Exclude). Eta (Maybe × Exclude) is **not** listed as a conflict.
- On Gamma, the owner pressed Include (changing their own Exclude). Result: Conflict 0; combined counts Included 2, Maybe 1, Excluded 1.
- No separate "final decision" control was seen. The resolution was made by **one reviewer replacing their own vote**. After that, Gamma shows two Include votes; the earlier Exclude is not visible anywhere on screen.

**Inference**: under "Consensus", Rayyan stores the agreed outcome as matching individual votes. The disagreement that existed is therefore lost from the visible record, which matters for reporting inter-rater agreement (kappa) and for PRISMA. Other resolution methods may exist in Review settings; not examined. **Open.**

Evidence: `ev_6a59bd37…` (conflict list), `ev_cb9b611b…` (after resolving), `ev_a68bb474…` (A's counts after blind off).

## 2.7 Requirements this flow gives our platform

These are our design decisions, prompted by what was seen. They are not claims about Rayyan's server.

1. Blinding is enforced by the server: while active, no endpoint, count, summary or export returns another reviewer's decision, or any aggregate derived from it, to a reviewer.
2. Each vote change is a new event; the previous vote is kept in history, and the screen shows that a vote was changed.
3. Exclusion can require a reason (configurable per stage).
4. Conflict detection is a declared rule (default: any disagreement between final votes of the required reviewers, including Maybe vs Include/Exclude, is a conflict). It is saved with the review.
5. Resolution is a separate record (who, when, decision, reason) and does not overwrite the reviewers' original votes, so agreement statistics stay computable.
6. Unblinding is an audited, structured event (who, when, scope), not a chat message.
7. Auto-advance after a vote is optional, and the vote button shows which record it applies to.

## 2.8 Limitations

- One test review, two accounts, four voted records. Behaviour with more reviewers, with "required reviewers" settings, or with large lists was not seen.
- Duplicates were left unresolved, so duplicate copies appeared as separate items to screen.
- Only accessibility trees were read. Visual styling and timing were not compared.
- Rayyan's server rules are not known. Everything above is what the interface showed; no request or response was recorded, by design.

## 2.9 Open questions

- Is vote history kept, and is it exported?
- Do Include + Maybe and Maybe + Maybe count as conflicts?
- What other conflict-resolution methods exist, and who may resolve?
- Can a Reviewer turn Blind Mode on/off? (Button visible to account A; not clicked.)
- Does turning Blind Mode back on hide the decisions again for everyone?
- What does the export contain while blinding is on, and does it reveal other reviewers' votes?
