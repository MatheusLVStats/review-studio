# Builds reference_cases.json: published datasets with the values reported in the original papers.
# Expected values are those that metafor's own test suite checks against the cited tables
# (github.com/wviechtb/metafor, tests/testthat/test_analysis_example_*.r).
suppressPackageStartupMessages({ library(metafor); library(jsonlite) })
rows <- function(df) lapply(seq_len(nrow(df)), function(i) as.list(df[i, , drop = FALSE]))

hine <- dat.hine1989
nor <- dat.normand1999
nor$sdp <- with(nor, sqrt(((n1i - 1) * sd1i^2 + (n2i - 1) * sd2i^2) / (n1i + n2i - 2)))
rau <- dat.raudenbush1985
roth <- data.frame(study_id = c("Age <55", "Age 55+"), ai = c(8, 22), bi = c(98, 76), ci = c(5, 16), di = c(115, 69))

cases <- list(
  list(id = "normand1999_rd_dl",
       source = "Normand SL. Stat Med 1999;18:321-59, Table VII (p. 349): risk difference, percentage points",
       note = "Expected values are in percentage points; the engine works in proportions, so they are divided by 100.",
       spec = list(measure = "RD", model = list(method = "DL", hksj = "never"),
                   rows = rows(data.frame(study_id = hine$study, ai = hine$ai, n1i = hine$n1i, ci = hine$ci, n2i = hine$n2i))),
       expected = list(estimate = 2.9444 / 100, ci_lb = 0.3831 / 100, ci_ub = 5.5058 / 100, tau2 = 0)),
  list(id = "normand1999_md_dl",
       source = "Normand SL. Stat Med 1999;18:321-59, Table IX (p. 352): mean difference, DerSimonian-Laird",
       note = "Pooled within-study SD used for both arms, as in the paper.",
       spec = list(measure = "MD", model = list(method = "DL", hksj = "never"),
                   rows = rows(data.frame(study_id = nor$source, m1i = nor$m1i, sd1i = nor$sdp, n1i = nor$n1i,
                                          m2i = nor$m2i, sd2i = nor$sdp, n2i = nor$n2i))),
       expected = list(estimate = -14.0972, ci_lb = -24.4454, ci_ub = -3.7490, tau2 = 218.7216)),
  list(id = "normand1999_md_reml",
       source = "Normand SL. Stat Med 1999;18:321-59, Table IX (p. 352): mean difference, REML",
       spec = list(measure = "MD", model = list(method = "REML", hksj = "never"),
                   rows = rows(data.frame(study_id = nor$source, m1i = nor$m1i, sd1i = nor$sdp, n1i = nor$n1i,
                                          m2i = nor$m2i, sd2i = nor$sdp, n2i = nor$n2i))),
       expected = list(estimate = -15.1217, ci_lb = -32.6716, ci_ub = 2.4282, tau2 = 685.1965)),
  list(id = "raudenbush2009_knha_reml",
       source = "Raudenbush SW. In: Cooper H et al. Handbook of Research Synthesis and Meta-Analysis, 2nd ed., 2009, Table 16.3 (p. 309): Knapp-Hartung, REML",
       spec = list(measure = "GEN", model = list(method = "REML", hksj = "always"),
                   rows = rows(data.frame(study_id = rau$study, yi = rau$yi, vi = rau$vi))),
       expected = list(estimate = 0.0837, se_analysis_scale = 0.0616, ci_lb = -0.0457, ci_ub = 0.2131, tau2 = 0.0188)),
  list(id = "raudenbush2009_knha_dl",
       source = "Raudenbush SW. Handbook of Research Synthesis and Meta-Analysis, 2nd ed., 2009, Table 16.3 (p. 309): Knapp-Hartung, DerSimonian-Laird",
       spec = list(measure = "GEN", model = list(method = "DL", hksj = "always"),
                   rows = rows(data.frame(study_id = rau$study, yi = rau$yi, vi = rau$vi))),
       expected = list(estimate = 0.0893, se_analysis_scale = 0.0636, ci_lb = -0.0442, ci_ub = 0.2229, tau2 = 0.0259)),
  list(id = "rothman2008_mh_rr",
       source = "Rothman KJ, Greenland S, Lash TL. Modern Epidemiology, 3rd ed., 2008, Chapter 15, Table 15-1: Mantel-Haenszel risk ratio, 90% CI",
       spec = list(measure = "RR", level = 90, min_studies = 2, model = list(method = "DL", hksj = "never"), rows = rows(roth)),
       expected = list(`sensitivity_mantel_haenszel_common_effect.estimate` = 1.3256,
                       `sensitivity_mantel_haenszel_common_effect.ci_lb` = 0.8658,
                       `sensitivity_mantel_haenszel_common_effect.ci_ub` = 2.0296))
)
write(toJSON(cases, auto_unbox = TRUE, digits = NA, pretty = TRUE), "reference_cases.json")
cat(length(cases), "cases written\n")
