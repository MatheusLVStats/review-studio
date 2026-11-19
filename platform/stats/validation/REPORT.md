# Statistical engine validation

Run: 2026-11-19 18:50 -03. R version 4.3.3 (2024-02-29); metafor 4.4.0.

## 1. Published reference values

| Case | Quantity | Published | Engine | OK |
|---|---|---|---|---|
| normand1999_rd_dl | estimate | 0.029444 | 0.0294443 | yes |
| normand1999_rd_dl | ci_lb | 0.003831 | 0.00383089 | yes |
| normand1999_rd_dl | ci_ub | 0.055058 | 0.0550578 | yes |
| normand1999_rd_dl | tau2 | 0 | 0 | yes |
| normand1999_md_dl | estimate | -14.0972 | -14.0972 | yes |
| normand1999_md_dl | ci_lb | -24.4454 | -24.4454 | yes |
| normand1999_md_dl | ci_ub | -3.749 | -3.74901 | yes |
| normand1999_md_dl | tau2 | 218.722 | 218.722 | yes |
| normand1999_md_reml | estimate | -15.1217 | -15.1217 | yes |
| normand1999_md_reml | ci_lb | -32.6716 | -32.6716 | yes |
| normand1999_md_reml | ci_ub | 2.4282 | 2.42823 | yes |
| normand1999_md_reml | tau2 | 685.197 | 685.197 | yes |
| raudenbush2009_knha_reml | estimate | 0.0837 | 0.0837082 | yes |
| raudenbush2009_knha_reml | se_analysis_scale | 0.0616 | 0.0615819 | yes |
| raudenbush2009_knha_reml | ci_lb | -0.0457 | -0.0456705 | yes |
| raudenbush2009_knha_reml | ci_ub | 0.2131 | 0.213087 | yes |
| raudenbush2009_knha_reml | tau2 | 0.0188 | 0.0188263 | yes |
| raudenbush2009_knha_dl | estimate | 0.0893 | 0.0893221 | yes |
| raudenbush2009_knha_dl | se_analysis_scale | 0.0636 | 0.0635756 | yes |
| raudenbush2009_knha_dl | ci_lb | -0.0442 | -0.0442452 | yes |
| raudenbush2009_knha_dl | ci_ub | 0.2229 | 0.222889 | yes |
| raudenbush2009_knha_dl | tau2 | 0.0259 | 0.0259037 | yes |
| rothman2008_mh_rr | sensitivity_mantel_haenszel_common_effect.estimate | 1.3256 | 1.32556 | yes |
| rothman2008_mh_rr | sensitivity_mantel_haenszel_common_effect.ci_lb | 0.8658 | 0.865753 | yes |
| rothman2008_mh_rr | sensitivity_mantel_haenszel_common_effect.ci_ub | 2.0296 | 2.02956 | yes |

Sources:

- `normand1999_rd_dl`: Normand SL. Stat Med 1999;18:321-59, Table VII (p. 349): risk difference, percentage points
- `normand1999_md_dl`: Normand SL. Stat Med 1999;18:321-59, Table IX (p. 352): mean difference, DerSimonian-Laird
- `normand1999_md_reml`: Normand SL. Stat Med 1999;18:321-59, Table IX (p. 352): mean difference, REML
- `raudenbush2009_knha_reml`: Raudenbush SW. In: Cooper H et al. Handbook of Research Synthesis and Meta-Analysis, 2nd ed., 2009, Table 16.3 (p. 309): Knapp-Hartung, REML
- `raudenbush2009_knha_dl`: Raudenbush SW. Handbook of Research Synthesis and Meta-Analysis, 2nd ed., 2009, Table 16.3 (p. 309): Knapp-Hartung, DerSimonian-Laird
- `rothman2008_mh_rr`: Rothman KJ, Greenland S, Lash TL. Modern Epidemiology, 3rd ed., 2008, Chapter 15, Table 15-1: Mantel-Haenszel risk ratio, 90% CI

The published values are those that metafor's own test suite checks against the cited tables (github.com/wviechtb/metafor, tests/testthat). They were not re-read from the original papers for this report.

## 2. Independent formula check (DerSimonian-Laird + Hartung-Knapp-Sidik-Jonkman)

Formulas written out in plain R arithmetic, without metafor, compared with the engine to 1e-8.

| Dataset | Quantity | Formula | Engine | OK |
|---|---|---|---|---|
| dat.raudenbush1985 | tau2 | 0.02590367 | 0.02590367 | yes |
| dat.raudenbush1985 | estimate | 0.08932208 | 0.08932208 | yes |
| dat.raudenbush1985 | se | 0.06357556 | 0.06357556 | yes |
| dat.raudenbush1985 | ci_lb | -0.04424520 | -0.04424520 | yes |
| dat.raudenbush1985 | ci_ub | 0.22288937 | 0.22288937 | yes |
| dat.raudenbush1985 | I2 | 49.76211847 | 49.76211847 | yes |
| dat.bcg | tau2 | 0.30876026 | 0.30876026 | yes |
| dat.bcg | estimate | -0.71411722 | -0.71411722 | yes |
| dat.bcg | se | 0.18069663 | 0.18069663 | yes |
| dat.bcg | ci_lb | -1.10782135 | -1.10782135 | yes |
| dat.bcg | ci_ub | -0.32041309 | -0.32041309 | yes |
| dat.bcg | I2 | 92.11734685 | 92.11734685 | yes |

## 3. Pre-specified rules

| Rule | OK |
|---|---|
| Fewer than 3 studies: no pooling, status narrative_only | yes |
| k = 19 with HKSJ rule 'below 10': Wald CI used, reason recorded | yes |
| k = 5 with HKSJ rule 'below 10': HKSJ applied | yes |
| Egger test not run below 10 studies | yes |
| Egger test run at 10 or more studies | yes |
| Same input gives identical output | yes |
| RR reported on the ratio scale with the log-scale estimate kept | yes |

**All checks passed.**
