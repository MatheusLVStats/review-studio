# Synthetic test references

All records are invented and labelled SYNTHETIC. DOIs use the unassigned prefix `10.99999`; IDs starting with `99000` or `L99000` are not real PubMed or Embase numbers. Use these files for test reviews only, never in a real review.

## Files

| File | Format | Rows | Imitates |
|---|---|---|---|
| `rayyan-test-medline.ris` | RIS | 5 | PubMed export |
| `rayyan-test-embase.ris` | RIS | 4 | Embase export (abbreviated journals, initials, upper-case DOI) |
| `rayyan-test-central.bib` | BibTeX | 2 | Reference manager export |
| `rayyan-test-registry.csv` | CSV | 2 | Trial registry / hand-made list |

13 rows in total.

## Ground truth (what a correct tool should conclude)

| Group | Rows | Truth | What it tests |
|---|---|---|---|
| Alpha | MEDLINE 0001, Embase L99000101, CSV REG-2 | One publication, three copies | Same DOI with different case; journal abbreviation; page range `101-109` vs `101-9`; CSV import |
| Beta | MEDLINE 99000002, Embase L99000102 | One publication, two copies | No shared identifier; trailing full stop in title; author initials |
| Delta article | MEDLINE 99000004, BibTeX synthetic0004 | One publication, two copies | Same DOI across RIS and BibTeX |
| Delta abstract | Embase L99000104 | Separate publication of the **same study** as Delta article | Conference abstract must not be merged with the article; it should be linked as a companion report |
| Epsilon | MEDLINE 99000005 | Separate record (correction notice) | Must not be merged with Alpha even though the title contains Alpha's title |
| Gamma, Zeta, Eta, Theta | one row each | Unique | No false merges |

Expected counts: 13 imported rows → **9 publications** → **8 studies** (Delta article and Delta abstract are one study; Epsilon is a notice attached to Alpha, not a study).
