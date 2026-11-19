# Statistical engine for the review platform. All pooling is done here, by metafor; the API only
# stores the analysis specification and the returned result. See docs/spec/stats-module-plan.md.
#
# Usage: Rscript engine.R <analysis.json> <result.json>
#
# The specification (JSON) holds:
#   analysis_id, outcome, measure ("RR","OR","RD","MD","SMD","GEN"), level (default 95),
#   model: { method: "REML"|"DL"|..., hksj: "always"|"never"|"below_k", hksj_k: 10 },
#   min_studies (default 3), egger_min_k (default 10), double_zero: "exclude" (default) | "include",
#   rows: one row per study with study_id and either
#         ai,bi,ci,di (binary: events and non-events per arm) or n1i,n2i + events (ai,ci) ->
#         binary with "events" form: ai, n1i, ci, n2i
#         m1i,sd1i,n1i,m2i,sd2i,n2i (continuous), or yi,vi (generic, already on the analysis scale)
# The result reports every choice actually applied and why, plus software versions and the
# SHA-256 of the specification, so that the same input always gives the same, traceable output.

suppressPackageStartupMessages({ library(metafor); library(jsonlite) })

`%||%` <- function(a, b) if (is.null(a)) b else a

sha256_file <- function(path) {
  out <- tryCatch(system2("sha256sum", path, stdout = TRUE), error = function(e) NA_character_)
  if (length(out) && !is.na(out[1])) strsplit(out[1], " ")[[1]][1] else NA_character_
}

effect_sizes <- function(spec, rows) {
  m <- spec$measure
  if (m %in% c("RR", "OR", "RD")) {
    escalc(measure = m, ai = rows$ai, bi = rows$bi, ci = rows$ci, di = rows$di, slab = rows$study_id)
  } else if (m %in% c("MD", "SMD")) {
    escalc(measure = m, m1i = rows$m1i, sd1i = rows$sd1i, n1i = rows$n1i,
           m2i = rows$m2i, sd2i = rows$sd2i, n2i = rows$n2i, slab = rows$study_id)
  } else if (m == "GEN") {
    escalc(measure = "GEN", yi = rows$yi, vi = rows$vi, slab = rows$study_id)
  } else stop("Unknown measure: ", m)
}

run_analysis <- function(spec, spec_sha256 = NA_character_) {
  warnings <- character(0)
  result <- withCallingHandlers({
    rows <- as.data.frame(spec$rows, stringsAsFactors = FALSE)
    if (spec$measure %in% c("RR", "OR", "RD") && is.null(rows$bi) && !is.null(rows$n1i)) {
      rows$bi <- rows$n1i - rows$ai; rows$di <- rows$n2i - rows$ci   # events/total form -> 2x2 table
    }
    level <- spec$level %||% 95
    method <- spec$model$method %||% "REML"
    min_k <- spec$min_studies %||% 3
    # Studies with no information on a ratio measure (default: left out and listed; Cochrane Handbook practice).
    # RR: no events in either arm. OR: no events in either arm, or all participants with the event in both arms.
    dz_rule <- spec$double_zero %||% "exclude"
    excluded_dz <- character(0)
    if (spec$measure %in% c("RR", "OR")) {
      dz <- (rows$ai == 0 & rows$ci == 0) | (spec$measure == "OR" & rows$bi == 0 & rows$di == 0)
      if (dz_rule == "exclude" && any(dz)) { excluded_dz <- as.character(rows$study_id[dz]); rows <- rows[!dz, , drop = FALSE] }
      else if (!dz_rule %in% c("exclude", "include")) stop("Unknown double_zero rule: ", dz_rule)
    }
    k <- nrow(rows)
    base <- list(analysis_id = spec$analysis_id %||% NA, outcome = spec$outcome %||% NA, measure = spec$measure,
                 k = k, studies_supplied = k + length(excluded_dz), level = level,
                 double_zero = if (spec$measure %in% c("RR", "OR"))
                   list(rule = dz_rule, excluded_studies = as.list(excluded_dz),
                        reason = "no events in either arm carry no information on a ratio measure") else NULL,
                 software = list(R = R.version.string, metafor = as.character(packageVersion("metafor"))),
                 spec_sha256 = spec_sha256)
    if (k < min_k) {
      return(c(base, list(status = "narrative_only",
                          reason = sprintf("%d studies contribute; pre-specified minimum for pooling is %d.", k, min_k))))
    }
    es <- effect_sizes(spec, rows)
    if (dz_rule == "include") es <- escalc(measure = spec$measure, ai = rows$ai, bi = rows$bi, ci = rows$ci, di = rows$di,
                                           slab = rows$study_id, drop00 = FALSE, add = 1/2, to = "only0")
    hksj_rule <- spec$model$hksj %||% "below_k"
    hksj_k <- spec$model$hksj_k %||% 10
    use_hksj <- switch(hksj_rule, always = TRUE, never = FALSE, below_k = k < hksj_k,
                       stop("Unknown hksj rule: ", hksj_rule))
    fit <- rma(yi, vi, data = es, method = method, test = if (use_hksj) "knha" else "z", level = level)
    log_scale <- spec$measure %in% c("RR", "OR")
    tr <- if (log_scale) exp else identity
    pred <- predict(fit, level = level)
    out <- c(base, list(
      status = "pooled",
      model = list(type = "random-effects", tau2_estimator = method,
                   ci_method = if (use_hksj) "Hartung-Knapp-Sidik-Jonkman (t distribution, k-1 df)" else "Wald (normal)",
                   hksj_rule = hksj_rule, hksj_k = hksj_k,
                   hksj_reason = if (hksj_rule == "below_k") sprintf("k = %d %s %d", k, if (use_hksj) "<" else ">=", hksj_k) else hksj_rule),
      scale = if (log_scale) "log; estimates below are back-transformed" else "original",
      estimate = tr(as.numeric(fit$b)), ci_lb = tr(fit$ci.lb), ci_ub = tr(fit$ci.ub),
      estimate_analysis_scale = as.numeric(fit$b), se_analysis_scale = fit$se,
      pi_lb = tr(pred$pi.lb), pi_ub = tr(pred$pi.ub),
      p_value = fit$pval, tau2 = fit$tau2, I2 = fit$I2, Q = fit$QE, Q_df = k - 1, Q_p = fit$QEp,
      studies = data.frame(study_id = rows$study_id, yi = as.numeric(es$yi), vi = as.numeric(es$vi),
                           weight_percent = as.numeric(weights(fit)))
    ))
    if (spec$measure %in% c("RR", "OR", "RD")) {
      zero <- rows$ai == 0 | rows$bi == 0 | rows$ci == 0 | rows$di == 0
      both0 <- (rows$ai == 0 & rows$ci == 0) | (rows$bi == 0 & rows$di == 0)
      out$zero_cell_handling <- list(
        studies_with_a_zero_cell = as.list(rows$study_id[zero]),
        studies_with_zero_events_in_both_arms = as.list(rows$study_id[both0]),
        rule = if (spec$measure == "RD") "no correction needed for RD" else
          "0.5 added to every cell of a study with a zero cell (metafor escalc default add=1/2, to='only0'); random-effects analysis only. The Mantel-Haenszel sensitivity analysis uses no correction. Double-zero studies follow the double_zero rule above.")
      mh <- rma.mh(ai = rows$ai, bi = rows$bi, ci = rows$ci, di = rows$di, measure = spec$measure, level = level)
      out$sensitivity_mantel_haenszel_common_effect <- list(estimate = tr(as.numeric(mh$b)), ci_lb = tr(mh$ci.lb), ci_ub = tr(mh$ci.ub))
    }
    egger_min <- spec$egger_min_k %||% 10
    out$small_study_test <- if (k >= egger_min) {
      eg <- regtest(fit)
      list(test = "Egger regression (metafor::regtest)", z_or_t = eg$zval, p_value = eg$pval)
    } else list(test = "not run", reason = sprintf("k = %d < %d (pre-specified minimum)", k, egger_min))
    out
  }, warning = function(w) { warnings <<- c(warnings, conditionMessage(w)); invokeRestart("muffleWarning") })
  result$warnings <- warnings
  result
}

if (sys.nframe() == 0L && length(commandArgs(trailingOnly = TRUE)) == 2) {
  a <- commandArgs(trailingOnly = TRUE)
  spec <- fromJSON(a[1], simplifyVector = TRUE)
  res <- tryCatch(run_analysis(spec, sha256_file(a[1])),
                  error = function(e) list(status = "error", message = conditionMessage(e)))
  write(toJSON(res, auto_unbox = TRUE, digits = NA, null = "null", na = "null", pretty = TRUE), a[2])
}
