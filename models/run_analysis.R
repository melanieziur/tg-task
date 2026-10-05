#!/usr/bin/env Rscript
# ===========================================================================
# run_analysis.R  --  trust-game RL: full hierarchical-Bayesian workflow
#
# Run this TOP TO BOTTOM or block-by-block (each "# ----" section is
# self-contained once Sections 0-1 have run). Fits take ~45s each on 4 cores.
# Models: M7 (validated base) + three stereotype-locus siblings --
#   M_viol  Locus 2: stereotype VIOLATION modulates the learning RATE   (omega)
#   W1      Locus 1: stereotype weights the PRIOR                        (w1)
#   W3      Locus 3: decaying stereotype PULL on CHOICE                  (w3, lambda)
# Each sibling nests M7 (omega=0 / w1=1 / w3=0), so comparisons are clean.
# ===========================================================================

# ---- 0. Setup -------------------------------------------------------------
setwd("~/path/to/your/stan/folder")   # <-- EDIT: folder holding the .stan + .R files
source("fit_rstan.R")
suppressPackageStartupMessages({ library(rstan); library(loo) })
options(mc.cores = parallel::detectCores())
rstan_options(auto_write = TRUE)      # cache compiled models

DATA <- "notlive-all_data.csv"        # <-- EDIT if needed

# Convenience: print the group params on natural scales + a "clear of X?" check.
natural_scale <- function(gs) {
  cat("  group-mean learning rate  plogis(mu_alpha) =",
      round(plogis(gs["mu_alpha", "mean"]), 3),
      sprintf("[%.3f, %.3f]\n", plogis(gs["mu_alpha","2.5%"]), plogis(gs["mu_alpha","97.5%"])))
  cat("  group-mean inv-temp       exp(mu_beta)     =",
      round(exp(gs["mu_beta", "mean"]), 3),
      sprintf("[%.3f, %.3f]\n", exp(gs["mu_beta","2.5%"]), exp(gs["mu_beta","97.5%"])))
  if ("mu_phi" %in% rownames(gs))
    cat("  group-mean perseveration  mu_phi          =",
        round(gs["mu_phi","mean"],3),
        sprintf("[%.3f, %.3f]\n", gs["mu_phi","2.5%"], gs["mu_phi","97.5%"]))
}
ci_excludes <- function(gs, par, value = 0) {
  lo <- gs[par, "2.5%"]; hi <- gs[par, "97.5%"]
  cat(sprintf("  %s = %.3f [%.3f, %.3f] -- %s %g\n", par, gs[par,"mean"], lo, hi,
              if (lo > value || hi < value) "EXCLUDES" else "includes", value))
}

# ---- 1. Load, prep, and sanity-check the data -----------------------------
df <- load_and_prep(DATA)             # resolves outcome col, masks non-responses
table(df$return_bin, useNA = "always")               # 0/1 + NA on $0-send & non-response
sd_check <- build_stan_data(df, "M7")
sapply(c("outcome","fb","observed"), function(nm) sum(is.na(sd_check[[nm]])))   # all 0
cat("feedback share (mean fb):", round(mean(sd_check$fb), 3), "\n")             # ~0.86
cat("non-response trials masked:", sum(sd_check$observed == 0), "\n")           # e.g. 3

# ---- 2. Fit the base model (M7) + diagnostics -----------------------------
res7 <- fit_model("M7", df, seed = 1000)
gs7  <- group_summary(res7$fit, "M7"); print(round(gs7, 3))
natural_scale(gs7)
check_hmc_diagnostics(res7$fit)       # divergences / treedepth / E-BFMI
# (For M7, K=1: d_alpha[1] is pinned at 0 and tau_alpha reflects its prior -- ignore both.)

# ---- 3. Fit the three stereotype-locus siblings ---------------------------
res_v  <- fit_model("M_viol", df, seed = 1000)   # Locus 2: rate
res_w1 <- fit_model("W1",     df, seed = 1000)   # Locus 1: prior
res_w3 <- fit_model("W3",     df, seed = 1000)   # Locus 3: choice
lapply(list(res_v$fit, res_w1$fit, res_w3$fit), check_hmc_diagnostics)

# ---- 4. Headline parameters: where (if anywhere) does the stereotype act? --
cat("\nLocus 2 (rate) -- M_viol:\n");  gv  <- group_summary(res_v$fit,  "M_viol"); ci_excludes(gv,  "omega",  0)
cat("Locus 1 (prior) -- W1:\n");       gw1 <- group_summary(res_w1$fit, "W1");     ci_excludes(gw1, "w1", 0); ci_excludes(gw1, "w1", 1)
cat("Locus 3 (choice) -- W3:\n");      gw3 <- group_summary(res_w3$fit, "W3");     ci_excludes(gw3, "w3", 0)
cat("   (lambda is only interpretable if w3 excludes 0; else it reflects its prior)\n")
print(round(gv, 3)); print(round(gw1, 3)); print(round(gw3, 3))

# ---- 5. Model comparison (WAIC + LOO) -------------------------------------
# Note: log_lik is 0 on the few masked non-response trials; those entries are
# numerically inert. For an exact observation count, trim all-zero columns.
trim_ll <- function(fit) {
  ll <- extract_log_lik(fit, merge_chains = FALSE)          # [iter, chain, S*T]
  keep <- apply(ll, 3, function(x) any(x != 0)); ll[, , keep, drop = FALSE]
}
waic_of <- function(fit) waic(trim_ll(fit))
W <- list(M7 = waic_of(res7$fit), M_viol = waic_of(res_v$fit),
          W1 = waic_of(res_w1$fit), W3 = waic_of(res_w3$fit))
print(loo_compare(W))                                       # WAIC ranking

# PSIS-LOO (use moment_match=TRUE if Pareto-k warnings appear; needs the fits in memory)
L <- list(M7     = loo(res7$fit,  moment_match = TRUE),
          M_viol = loo(res_v$fit,  moment_match = TRUE),
          W1     = loo(res_w1$fit, moment_match = TRUE),
          W3     = loo(res_w3$fit, moment_match = TRUE))
print(loo_compare(L))                                       # LOO ranking + elpd_diff +/- se

# ---- 6. Parameter-recovery battery ----------------------------------------
# Simulate at known group truth on the REAL design (partner order, amounts,
# masked trials), refit, and check the posterior brackets truth. A null is only
# meaningful if the matching effect WOULD have been detected here.

# 6a. M7 baseline recovery
truth_m7 <- list(mu_alpha=-1.0, sigma_alpha=0.7, mu_beta=0.8, sigma_beta=0.5,
                 mu_phi=0.4, sigma_phi=0.3)
rec_m7 <- recover(df, "M7", truth_m7, seed = 1); print(round(rec_m7$summary, 3))

# 6b. M_viol -- power for the violation effect (large then moderate)
truth_v8 <- c(truth_m7, list(omega = 0.8))
truth_v4 <- c(truth_m7, list(omega = 0.4))
rec_v8 <- recover(df, "M_viol", truth_v8, seed = 1); print(round(rec_v8$summary, 3))  # omega ~ 0.8, clear of 0?
rec_v4 <- recover(df, "M_viol", truth_v4, seed = 1); print(round(rec_v4$summary, 3))  # moderate-effect power

# 6c. W1 -- can a partial anchor be recovered? (truth between 0 and 1)
truth_w1 <- c(truth_m7, list(w1 = 0.6))
rec_w1 <- recover(df, "W1", truth_w1, seed = 1); print(round(rec_w1$summary, 3))      # w1 ~ 0.6?

# 6d. W3 -- THE lambda decision: are w3 and lambda jointly identifiable?
#     If lambda's posterior brackets 0.5 with a usable interval -> keep it free.
#     If lambda just reflects its prior (mean ~0.5, very wide) even when w3 is
#     well-recovered -> fix lambda (e.g. 0.5) and refit W3 with it pinned.
truth_w3 <- c(truth_m7, list(w3 = 0.8, lambda = 0.5))
rec_w3 <- recover(df, "W3", truth_w3, seed = 1); print(round(rec_w3$summary, 3))      # w3 ~ 0.8 & lambda ~ 0.5?

# ---- 7. Trial-level trajectories (plotting / neural regressors) -----------
tl <- trial_level(res7$fit)           # posterior-mean Q_chosen, pe, p_high  [S x T]
str(tl[c("Q_chosen","pe","p_high")])
# Sibling-specific trial signals (fit object must be the matching model):
#   M_viol: rstan::extract(res_v$fit,  "alpha_eff")$alpha_eff   (effective LR per trial)
#   W3:     rstan::extract(res_w3$fit, "pull_term")$pull_term   (stereotype choice pull)

# ---- 8. Save ---------------------------------------------------------------
# saveRDS(list(M7=res7$fit, M_viol=res_v$fit, W1=res_w1$fit, W3=res_w3$fit),
#         "trust_rl_fits.rds")
