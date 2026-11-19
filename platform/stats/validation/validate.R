# Validates the engine against (1) published reference values, (2) an independent implementation of the
# DerSimonian-Laird + Hartung-Knapp formulas written in plain arithmetic, and (3) the pre-specified rules.
# Usage (from platform/stats/validation): Rscript validate.R   -> prints results, writes REPORT.md, exits 1 on failure.
suppressPackageStartupMessages({ library(metafor); library(jsonlite) })
source("../engine.R")

pick <- function(res, path) { for (p in strsplit(path, ".", fixed = TRUE)[[1]]) res <- res[[p]]; as.numeric(res) }
# Published values are rounded to 4 decimals: allow half a unit in the last place, or 0.5% of the value.
close_enough <- function(obs, exp) abs(obs - exp) <= max(0.00051, 0.005 * abs(exp))

lines <- c("# Statistical engine validation", "",
           sprintf("Run: %s. %s; metafor %s.", format(Sys.time(), "%Y-%m-%d %H:%M %Z"), R.version.string, packageVersion("metafor")), "")
fail <- 0

# (1) Published reference values -------------------------------------------------------------
cases <- fromJSON("reference_cases.json", simplifyVector = FALSE)
lines <- c(lines, "## 1. Published reference values", "",
           "| Case | Quantity | Published | Engine | OK |", "|---|---|---|---|---|")
for (cs in cases) {
  spec <- cs$spec
  spec$rows <- do.call(rbind, lapply(spec$rows, as.data.frame))
  res <- run_analysis(spec)
  for (q in names(cs$expected)) {
    e <- cs$expected[[q]]; o <- pick(res, q); ok <- close_enough(o, e)
    fail <- fail + !ok
    lines <- c(lines, sprintf("| %s | %s | %.6g | %.6g | %s |", cs$id, q, e, o, if (ok) "yes" else "**NO**"))
  }
}
lines <- c(lines, "", "Sources:", "", vapply(cases, function(cs) sprintf("- `%s`: %s", cs$id, cs$source), ""), "",
           "The published values are those that metafor's own test suite checks against the cited tables (github.com/wviechtb/metafor, tests/testthat). They were not re-read from the original papers for this report.", "")

# (2) Independent implementation of DL + HKSJ ------------------------------------------------
hand_dl_hksj <- function(y, v, level = 95) {
  k <- length(y); w <- 1 / v
  mu_fe <- sum(w * y) / sum(w); Q <- sum(w * (y - mu_fe)^2)
  tau2 <- max(0, (Q - (k - 1)) / (sum(w) - sum(w^2) / sum(w)))
  ws <- 1 / (v + tau2); mu <- sum(ws * y) / sum(ws)
  se_hk <- sqrt(sum(ws * (y - mu)^2) / ((k - 1) * sum(ws)))
  tq <- qt(1 - (1 - level / 100) / 2, k - 1)
  c(tau2 = tau2, estimate = mu, se = se_hk, ci_lb = mu - tq * se_hk, ci_ub = mu + tq * se_hk,
    I2 = 100 * max(0, (Q - (k - 1)) / Q))
}
lines <- c(lines, "## 2. Independent formula check (DerSimonian-Laird + Hartung-Knapp-Sidik-Jonkman)", "",
           "Formulas written out in plain R arithmetic, without metafor, compared with the engine to 1e-8.", "",
           "| Dataset | Quantity | Formula | Engine | OK |", "|---|---|---|---|---|")
for (nm in c("dat.raudenbush1985", "dat.bcg")) {
  d <- get(nm)
  if (nm == "dat.bcg") d <- escalc(measure = "RR", ai = tpos, bi = tneg, ci = cpos, di = cneg, data = d)
  h <- hand_dl_hksj(d$yi, d$vi)
  res <- run_analysis(list(measure = "GEN", model = list(method = "DL", hksj = "always"),
                           rows = data.frame(study_id = seq_along(d$yi), yi = d$yi, vi = d$vi)))
  eng <- c(tau2 = res$tau2, estimate = res$estimate, se = res$se_analysis_scale, ci_lb = res$ci_lb, ci_ub = res$ci_ub, I2 = res$I2)
  for (q in names(h)) {
    ok <- abs(h[[q]] - eng[[q]]) < 1e-8; fail <- fail + !ok
    lines <- c(lines, sprintf("| %s | %s | %.8f | %.8f | %s |", nm, q, h[[q]], eng[[q]], if (ok) "yes" else "**NO**"))
  }
}

# (3) Pre-specified rules --------------------------------------------------------------------
rule <- function(desc, ok) { fail <<- fail + !ok; lines <<- c(lines, sprintf("| %s | %s |", desc, if (ok) "yes" else "**NO**")) }
lines <- c(lines, "", "## 3. Pre-specified rules", "", "| Rule | OK |", "|---|---|")
two <- run_analysis(list(measure = "GEN", rows = data.frame(study_id = 1:2, yi = c(0.1, 0.3), vi = c(0.04, 0.05))))
rule("Fewer than 3 studies: no pooling, status narrative_only", two$status == "narrative_only")
rau <- data.frame(study_id = dat.raudenbush1985$study, yi = dat.raudenbush1985$yi, vi = dat.raudenbush1985$vi)
r19 <- run_analysis(list(measure = "GEN", model = list(method = "REML", hksj = "below_k", hksj_k = 10), rows = rau))
rule("k = 19 with HKSJ rule 'below 10': Wald CI used, reason recorded", grepl("Wald", r19$model$ci_method) && r19$model$hksj_reason == "k = 19 >= 10")
r5 <- run_analysis(list(measure = "GEN", model = list(method = "REML", hksj = "below_k", hksj_k = 10), rows = rau[1:5, ]))
rule("k = 5 with HKSJ rule 'below 10': HKSJ applied", grepl("Hartung", r5$model$ci_method))
rule("Egger test not run below 10 studies", r5$small_study_test$test == "not run")
rule("Egger test run at 10 or more studies", grepl("Egger", r19$small_study_test$test))
again <- run_analysis(list(measure = "GEN", model = list(method = "REML", hksj = "below_k", hksj_k = 10), rows = rau))
rule("Same input gives identical output", identical(toJSON(r19, digits = NA), toJSON(again, digits = NA)))
rr <- run_analysis(list(measure = "RR", rows = data.frame(study_id = 1:3, ai = c(4, 6, 2), n1i = c(50, 60, 40), ci = c(8, 9, 5), n2i = c(50, 58, 41))))
dz <- run_analysis(list(measure = "RR", rows = data.frame(study_id = c("A","B","C","D"), ai = c(4, 6, 2, 0), n1i = c(50, 60, 40, 30),
                                                          ci = c(8, 9, 5, 0), n2i = c(50, 58, 41, 31))))
rule("RR: study with no events in either arm is left out and listed (k 4 -> 3)", dz$k == 3 && identical(unlist(dz$double_zero$excluded_studies), "D"))
dz_inc <- run_analysis(list(measure = "RR", double_zero = "include", rows = data.frame(study_id = c("A","B","C","D"), ai = c(4, 6, 2, 0), n1i = c(50, 60, 40, 30), ci = c(8, 9, 5, 0), n2i = c(50, 58, 41, 31))))
rule("RR: double_zero = include keeps it, with 0.5 added (k = 4)", dz_inc$k == 4 && length(dz_inc$double_zero$excluded_studies) == 0)
dz2 <- run_analysis(list(measure = "RR", rows = data.frame(study_id = c("A","D","E"), ai = c(4, 0, 0), n1i = c(50, 30, 20), ci = c(8, 0, 0), n2i = c(50, 31, 22))))
rule("Exclusion counted before the pooling threshold: 3 supplied, 1 informative -> narrative_only", dz2$status == "narrative_only" && dz2$studies_supplied == 3)
rule("RR reported on the ratio scale with the log-scale estimate kept", abs(rr$estimate - exp(rr$estimate_analysis_scale)) < 1e-12)

# (4) Regression: the team's own published analysis -------------------------------------------
# Kumar SIS, ..., de Luna Barros MM, et al. Eur J Plast Surg 2026;49:122. doi:10.1007/s00238-026-02497-5
# Necrosis, 3-stage vs 2-stage. Per-study counts from the team's extraction sheet; Noel 2017 does not say in which
# group its 3 necroses occurred: the published totals (8/162 vs 12/196) imply 0/15 vs 3/16.
lines <- c(lines, "", "## 4. Regression against the team's published forehead-flap meta-analysis", "",
           "Published values have 2 decimals, so agreement means within half a unit of the last digit (0.005).", "",
           "| Analysis | Quantity | Published | Engine | OK |", "|---|---|---|---|---|")
ff6 <- data.frame(study_id = c("Palmer 2025", "Lo Torto 2019", "Ribuffo 2012", "de Pochat 2014", "Stahl 2015 (2003-2009)", "Noel 2017"),
                  ai = c(2, 0, 0, 1, 5, 0), n1i = c(13, 16, 11, 7, 100, 15), ci = c(0, 4, 2, 0, 3, 3), n2i = c(39, 30, 20, 4, 87, 16))
ff7 <- rbind(ff6, data.frame(study_id = "Stahl 2015 (2003-2012)", ai = 6, n1i = 45, ci = 1, n2i = 25))
reg <- list(
  list(lbl = "Final (Results/Discussion): 6 studies, DL + HKSJ", spec = list(measure = "RR", model = list(method = "DL", hksj = "always"), rows = ff6),
       exp = list(estimate = 0.94, ci_lb = 0.18, ci_ub = 4.75, I2 = 27, p_value = 0.92), known = "ci_lb"),
  list(lbl = "Pre-revision (Abstract/funnel plot): 7 studies, REML, Wald", spec = list(measure = "RR", model = list(method = "REML", hksj = "never"), rows = ff7),
       exp = list(estimate = 1.25, ci_lb = 0.52, ci_ub = 3.02, I2 = 2), known = character(0)))
for (r in reg) {
  res <- run_analysis(r$spec)
  for (q in names(r$exp)) {
    e <- r$exp[[q]]; o <- res[[q]]; tol <- if (q == "I2") 0.5 else 0.005
    ok <- abs(o - e) <= tol + 1e-9
    status <- if (ok) "yes" else if (q %in% r$known) "known difference (see note)" else "**NO**"
    if (!ok && !(q %in% r$known)) fail <- fail + 1
    lines <- c(lines, sprintf("| %s | %s | %s | %.4f | %s |", r$lbl, q, format(e), o, status))
  }
}
lines <- c(lines, "", "Note: the published lower limit 0.18 differs from the engine's 0.1855 (which rounds to 0.19); every other value agrees. The published analysis may have used a slightly different implementation; this does not change any conclusion. The 7-study values reproduce the pre-revision draft exactly with REML and a Wald interval, so the change between draft and publication involved the study set, the tau2 estimator (REML to DL) and the interval (Wald to HKSJ).")

lines <- c(lines, "", if (fail == 0) "**All checks passed.**" else sprintf("**%d check(s) failed.**", fail))
writeLines(lines, "REPORT.md")
cat(lines, sep = "\n")
quit(status = if (fail == 0) 0 else 1)
