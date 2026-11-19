# FishingMeta inside Claude (artifact)

Live page: https://claude.ai/artifact/TgiTkjhot9CQzSLrXfqP5c (slug `d81929e2-51a7-45c5-8ace-bc2f3e2a3383`).

One HTML page published as a claude.ai artifact. Data lives in the artifact's database; the access rules
below are enforced by the platform, not by the page code.

| Path | Read | Write | Holds |
|---|---|---|---|
| everything not listed | anyone the page is shared with | Editors (leads) and the owner | reviews, publications, assignments, resolutions, PDFs index, analysis results |
| `data/users/<id>/` | only that person (not even the owner) | that person | votes while blinded, Claude's screening suggestions |
| `progress/<id>` | team | only that person | counts: assigned / voted (no decisions) |
| `released/<id>/` | team | only that person | that person's votes, published by their own page once reconciliation opens |
| `extraction/` | team | Contributors and up | extracted numbers, who entered and who checked |

Sharing: reviewers are Contributors, leads are Editors (Share button on the page).
Opening reconciliation closes voting for that stage; each reviewer's votes become visible once their page publishes them.
Statistics run in R/metafor in Matheus's RStudio (as in the magnesium vs lidocaine review), started from the Analysis tab; results are written back to `reviews/<rid>/analysis/`.

Build and test:

```bash
python claude-app/build.py                     # writes dist/index.html and test/harness.html
python -m http.server 8765 --directory claude-app &
python claude-app/test/flow_test.py            # three people against a mock of the database rules
```
