# Statistics module — plan (R / metafor)

Status: plan, with a working engine prototype and its validation (`platform/stats/`).
House style it must reproduce: random-effects always; REML or DL chosen in the protocol; HKSJ pre-specified by study count; pool only with ≥ 3 studies; risk ratio for dichotomous outcomes; SMD when instruments differ; funnel plot and Egger only with ≥ 10 studies; sensitivity analyses pre-specified; unit of analysis declared; deviations from protocol logged.

## 1. Principles

1. **R does every calculation.** The API stores what to compute and what came back. No pooled number is ever produced in Python, in the browser, or by an AI model.
2. **Every result is traceable.** A result is stored with: the exact analysis specification (JSON) and its SHA-256, the frozen data snapshot it used, R and metafor versions, warnings, and the reason for each choice the engine applied (e.g. "HKSJ applied: k = 4 < 10").
3. **Choices are made before results are seen.** The analysis plan is locked when the protocol is registered. Running an analysis with settings that differ from the locked plan is allowed but is recorded as a deviation with a reason, and shows in the export.
4. **AI suggests, people confirm.** An AI model may propose an extracted value only with its evidence (quoted text, page, file SHA-256). The value is unusable until a person confirms or corrects it. Analyses read only confirmed values.

## 2. Data model (additions to the platform schema)

```
outcome_definitions(id, review_id, name, definition_text, type in (binary, continuous, time_to_event),
                    preferred_measure, timepoint_rule, unit_of_analysis, locked_at)
extraction_forms(id, review_id, version, fields jsonb, locked_at)          -- versioned, never edited after use
extraction_values(id, review_id, study_id, arm, outcome_id, timepoint, field, value,
                  status in (suggested, confirmed, rejected, superseded),
                  entered_by, entered_via in (human, ai),
                  evidence_quote, evidence_page, evidence_file_sha256,
                  ai_model, confirmed_by, confirmed_at, supersedes_id)       -- append-only
extraction_discrepancies(...)          -- two extractors, same rule as screening conflicts: blinded, then resolved
rob_assessments(id, study_id, outcome_id, tool in (RoB2, ROBINS-I), domain_judgements jsonb, overall, assessor, ...)
analysis_plans(id, review_id, outcome_id, measure, tau2_estimator, hksj_rule, hksj_k, min_studies,
               egger_min_k, subgroups jsonb, sensitivity jsonb, expected_bias_direction text, locked_at)
analysis_runs(id, plan_id, spec jsonb, spec_sha256, data_snapshot_sha256, result jsonb,
              engine_version, r_version, metafor_version, status, deviation_reason, run_by, run_at)  -- append-only
```

`expected_bias_direction` holds the confounding-by-indication argument written **before** analysis (e.g. "the 3-stage technique is reserved for harder cases, so confounding biases against it; a null result may hide a protective effect"). The result page shows it next to the estimate.

Studies, not publications, are the unit of extraction: values from an article and its conference abstract are entered against one study, and the form shows which report each value came from.

## 3. Engine

`platform/stats/engine.R` — `Rscript engine.R spec.json result.json`. The API calls it as a subprocess with a time limit and no network access, writes the spec to a temporary file and stores the returned JSON.

Why a subprocess and not an R web service (Plumber, OpenCPU): one analysis takes well under a second, runs are infrequent, and a subprocess needs no extra server to deploy or secure. Revisit if many users run analyses at once.

What the prototype already does:

| Item | Behaviour |
|---|---|
| Measures | RR, OR, RD (2×2 or events/total), MD, SMD (Hedges' g), generic yi/vi |
| Model | `rma(method = REML/DL/…)`, always random-effects |
| HKSJ | rule from the plan: `always`, `never`, or `below_k` (default: applied when k < 10). The reason is written into the result. |
| Pooling threshold | k < `min_studies` (default 3) → `status = narrative_only`, nothing pooled |
| Output | estimate and CI (back-transformed for RR/OR, log-scale value kept), prediction interval, τ², I², Q and p, per-study yi, vi and weights |
| Mantel-Haenszel | common-effect MH estimate reported as a sensitivity analysis for RR/OR/RD |
| Zero cells | studies with a zero cell are listed; double-zero studies are left out of RR/OR and listed; the rule applied is written into the result |
| Small-study test | Egger (`regtest`) only when k ≥ 10, otherwise "not run" with the reason |
| Reproducibility | spec SHA-256, R and metafor versions, all warnings captured |

Decisions still needed from you before the engine is used on real data:

1. **Double-zero studies for RR/OR — decided 2026-11-19:** left out of RR/OR analyses and listed in the result (`double_zero = "exclude"`, the default). They still count as studies in the narrative and in PRISMA. A protocol can choose `"include"` (0.5 added to every cell) as a sensitivity analysis. Exclusion happens before the ≥ 3-studies check.
2. **Comparison with the published forehead-flap paper — done 2026-11-19** (`validate.R` section 4). With the team's extraction (Noel 2017's 3 necroses allocated to the 2-stage arm, as the published totals imply), the engine reproduces the final necrosis result with **DerSimonian–Laird + HKSJ**: 0.94 (0.1855–4.75), I² 27%, p 0.92 against the published 0.94 (0.18–4.75); only the lower limit differs (0.19 vs 0.18 after rounding). The pre-revision value in the Abstract and funnel-plot section, 1.25 (0.52–3.02), I² 2%, is reproduced exactly by the 7-study set with **REML and a Wald interval**. So three things changed between draft and publication: the study set, the τ² estimator and the interval method. These figures were reproduced with metafor; the Methods section says RevMan 5.4.1 and does not name the τ² estimator. Lesson for the protocol template: name the estimator and the software that produced each number.
3. **HKSJ threshold.** The prototype uses "k < 10". Your protocols should state the number; the plan field stores it.

## 4. Validation (done for the prototype)

`platform/stats/validation/validate.R` writes `REPORT.md` and exits with an error if any check fails. Current report: **all checks pass**.

1. **Published values** — six cases whose expected values come from published tables, as checked by metafor's own test suite: Normand 1999 (risk difference, DL; mean difference, DL and REML), Raudenbush 2009 (Knapp–Hartung with REML and with DL), Rothman 2008 (Mantel–Haenszel risk ratio, 90% CI). All agree within rounding.
2. **Independent formulas** — DerSimonian–Laird τ², the random-effects estimate, the Hartung–Knapp standard error and t-based CI, and I², written out in plain arithmetic, match the engine to 1e-8 on two datasets.
3. **Rules** — fewer than 3 studies are not pooled; HKSJ is applied or not according to the rule and the reason is recorded; Egger runs only at k ≥ 10; the same input gives identical output; ratio measures are back-transformed correctly.

Limits of this validation: it ran on metafor 4.4.0 (Ubuntu package; CRAN was not reachable from my workspace). The engine records the version on every run, and `validate.R` must be re-run whenever R or metafor is upgraded. The published values were taken from metafor's test files, not re-read from the original papers.

To add: an SMD (Hedges' g) reference case, an odds-ratio MH case with zero cells, a prediction-interval case, and — most useful for you — regression cases built from your two published meta-analyses.

## 5. AI-assisted extraction

- Input: the full-text PDF (by SHA-256) and the locked extraction form.
- Output per field: proposed value, verbatim quote (short), page number, and the model's identity. Stored as `status = suggested`.
- The extractor sees the suggestion next to the highlighted quote and must confirm, correct or reject it. Two independent extractors work blinded to each other, exactly as in screening; the AI suggestion is shown to both or to neither, depending on a setting recorded in the protocol.
- The analysis specification is built only from `confirmed` values. The export lists, for every number, who confirmed it and whether it started as an AI suggestion.

## 6. Exports for the paper

- Forest plots and funnel plots drawn in R from the stored result (16 cm wide, 600 dpi, black and white by default, as in your current R → Word routine).
- Summary-of-findings table rows (estimate, CI, k, participants, I², certainty field filled by the team).
- A reproducibility bundle per outcome: data CSV, spec JSON, engine script, `sessionInfo()`, result JSON — enough for a reviewer to re-run it.

## 7. Phases

1. Engine + validation (prototype done).
2. Extraction forms and values with two-extractor blinding (reuses the screening rules).
3. Analysis plans locked at registration; analysis runs; deviations log.
4. Plots and Word export; reproducibility bundle.
5. AI suggestions for extraction.
6. Subgroups, meta-regression, sensitivity analyses (exclude serious risk of bias; overlapping cohorts alternative).
