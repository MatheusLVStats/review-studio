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
rule("RR reported on the ratio scale with the log-scale estimate kept", abs(rr$estimate - exp(rr$estimate_analysis_scale)) < 1e-12)

lines <- c(lines, "", if (fail == 0) "**All checks passed.**" else sprintf("**%d check(s) failed.**", fail))
writeLines(lines, "REPORT.md")
cat(lines, sep = "\n")
quit(status = if (fail == 0) 0 else 1)
