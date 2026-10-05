#!/usr/bin/env Rscript
# ===========================================================================
# fit_rstan.R
#
# RStan wrapper for trust_rl_core_rstan.stan. Re-implements the data prep in R
# (no Python dependency) so the whole pipeline is self-contained, and keeps the
# model definitions in lock-step with the Python/MLE side. Provides:
#   load_and_prep(csv)            -> dataframe with derived columns
#   build_stan_data(df, model)    -> named list for rstan::sampling
#   fit_model(model, df, ...)     -> fitted stanfit + stan data
#   group_summary(fit, model)     -> group-level parameters (incl. cell offsets)
#   trial_level(fit)              -> posterior-mean Q / pe / p_high  [S x T]
#   r_subject_loglik(...)         -> NumPy/Stan-equivalent forward pass (checks)
#   simulate_dataset / recover    -> hierarchical parameter recovery
#
# STAN model files in the same directory. Set STAN_FILE if needed.
# ===========================================================================

STAN_FILE          <- "trust_rl_core_rstan.stan"
VIOL_STAN_FILE     <- "trust_rl_violation_rstan.stan"
ANCHOR_STAN_FILE   <- "trust_rl_anchor_rstan.stan"
CHOICE_STAN_FILE   <- "trust_rl_choicepull_rstan.stan"
RECIP_RETURN <- 1.5
PARTNER_TYPES <- c("TC", "TI", "UC", "UI", "TA", "UA")

# --- model registry: the five switches, mirroring the Python MODELS ---------
# family: "core" -> trust_rl_core_rstan.stan; "violation"/"anchor"/"choicepull"
# select their sibling .stan files (the three stereotype-locus models).
.spec <- function(n_alpha, phi, q_init, readout, dual_beta = FALSE, family = "core")
  list(n_alpha = n_alpha, phi = phi, q_init = q_init,
       readout = readout, dual_beta = dual_beta, family = family)

MODELS <- list(
  M1  = .spec(1, FALSE, "fixed", "belief"),
  M2  = .spec(2, FALSE, "fixed", "belief"),
  M3  = .spec(1, TRUE,  "fixed", "belief"),
  M3b = .spec(2, TRUE,  "fixed", "belief"),
  M5  = .spec(1, FALSE, "stereotype", "belief"),
  M6  = .spec(2, FALSE, "stereotype", "belief"),
  M7  = .spec(1, TRUE,  "stereotype", "belief"),
  M7b = .spec(2, TRUE,  "stereotype", "belief"),
  M_cong    = .spec("cong", FALSE, "fixed",      "belief"),
  M_cong_P  = .spec("cong", TRUE,  "fixed",      "belief"),
  M_cong_S  = .spec("cong", FALSE, "stereotype", "belief"),
  M_cong_SP = .spec("cong", TRUE,  "stereotype", "belief"),
  M_type    = .spec("type", FALSE, "fixed",      "belief"),
  M_type_P  = .spec("type", TRUE,  "fixed",      "belief"),
  M_type_S  = .spec("type", FALSE, "stereotype", "belief"),
  M_type_SP = .spec("type", TRUE,  "stereotype", "belief"),
  # value-readout twins
  M1v = .spec(1, FALSE, "fixed", "value"),
  M2v = .spec(2, FALSE, "fixed", "value"),
  M3v = .spec(1, TRUE,  "fixed", "value"),
  M5v = .spec(1, FALSE, "stereotype", "value"),
  M6v = .spec(2, FALSE, "stereotype", "value"),
  M7v = .spec(1, TRUE,  "stereotype", "value"),
  # Three stereotype-locus siblings, all on the M7 architecture:
  M_viol = .spec(1, TRUE, "stereotype", "belief", family = "violation"),    # Locus 2: rate
  W1     = .spec(1, TRUE, "stereotype", "belief", family = "anchor"),       # Locus 1: prior
  W3     = .spec(1, TRUE, "stereotype", "belief", family = "choicepull")    # Locus 3: choice
)

# ===========================================================================
# Data prep
# ===========================================================================
load_and_prep <- function(path) {
  df <- read.csv(path, stringsAsFactors = FALSE)
  req <- c("participant_id", "trial", "stm", "left_amount", "right_amount",
           "amount_sent", "behavior", "pre_trustworthiness")
  miss <- setdiff(req, names(df))
  if (length(miss)) stop(paste("Missing required columns:", paste(miss, collapse = ", ")))

  # Resolve the partner reciprocation outcome column. Merges can leave the bare
  # `partner_choice` all-NA while the populated copy is `partner_choice_x`.
  # Prefer the first candidate that actually carries signal; fail loudly if none.
  cand <- c("partner_choice_x", "partner_choice", "partner_choice_y")
  oc <- NULL
  for (c in cand) if (c %in% names(df) && any(!is.na(df[[c]]))) { oc <- c; break }
  if (is.null(oc))
    stop(paste("No populated partner-choice column found (tried:",
               paste(cand, collapse = ", "), ")."))
  df$partner_choice <- df[[oc]]
  lev <- setdiff(unique(df$partner_choice), NA)
  if (!all(lev %in% c("half", "none")))
    stop(paste0("Unexpected partner_choice values in '", oc, "': ",
                paste(lev, collapse = ", "), " (expected half/none)."))

  df$low_amount  <- pmin(df$left_amount, df$right_amount)
  df$high_amount <- pmax(df$left_amount, df$right_amount)
  # A trial is "observed" iff an amount was recorded. Non-responses (timeouts)
  # have NA amount_sent: no choice to model, no feedback to learn from. They are
  # kept in sequence but masked out of the likelihood (observed = 0).
  df$observed    <- as.integer(!is.na(df$amount_sent))
  df$chose_high  <- ifelse(is.na(df$amount_sent), 0L,                 # dummy; masked out
                           as.integer(df$amount_sent == df$high_amount))
  df$return_bin  <- ifelse(!is.na(df$amount_sent) & df$amount_sent > 0,
                           as.integer(df$partner_choice == "half"), NA_integer_)
  df$stm_prior   <- df$pre_trustworthiness / 100
  df
}

.congruence_of <- function(profile, behavior) {
  if (behavior == "Neutral") return("ambiguous")
  if ((profile == "Trustworthy"   && behavior == "Trustworthy") ||
      (profile == "Untrustworthy" && behavior == "Untrustworthy")) return("congruent")
  "incongruent"
}
.type_of <- function(profile, behavior) {
  prof <- if (profile == "Trustworthy") "T" else "U"
  beh  <- switch(.congruence_of(profile, behavior),
                 congruent = "C", incongruent = "I", ambiguous = "A")
  paste0(prof, beh)
}

build_stan_data <- function(df, model_name) {
  spec <- MODELS[[model_name]]
  if (is.null(spec)) stop(paste("Unknown model:", model_name))
  if (isTRUE(spec$dual_beta)) stop(paste(model_name, "uses dual beta; core has a single beta."))

  subjects <- sort(unique(df$participant_id))
  partners <- sort(unique(df$stm))
  S <- length(subjects); P <- length(partners)
  p_index <- setNames(seq_along(partners), partners)

  K <- if (identical(spec$n_alpha, 1)) 1L
       else if (identical(spec$n_alpha, 2)) 2L
       else if (spec$n_alpha == "cong") 3L else 6L

  # static partner -> cell maps (only needed for cong / type)
  cell_of <- rep(1L, P)
  if (K == 3 || K == 6) {
    prof_by <- sapply(partners, function(pn) df$profile[df$stm == pn][1])
    beh_by  <- sapply(partners, function(pn) df$behavior[df$stm == pn][1])
    cong_int <- c(congruent = 1L, incongruent = 2L, ambiguous = 3L)
    type_int <- setNames(seq_along(PARTNER_TYPES), PARTNER_TYPES)
    for (j in seq_along(partners)) {
      cell_of[j] <- if (K == 3) cong_int[[.congruence_of(prof_by[[j]], beh_by[[j]])]]
                    else        type_int[[.type_of(prof_by[[j]], beh_by[[j]])]]
    }
  }

  tab <- table(df$participant_id)
  Tn <- as.integer(tab[1])
  if (length(unique(as.integer(tab))) != 1) stop("Subjects have unequal trial counts.")

  partner <- matrix(0L, S, Tn); choice <- matrix(0L, S, Tn); fb <- matrix(0L, S, Tn)
  outcome <- matrix(0L, S, Tn); a_idx <- matrix(1L, S, Tn)
  low <- matrix(0, S, Tn); high <- matrix(0, S, Tn)
  observed <- matrix(1L, S, Tn)
  Q0 <- matrix(0.5, S, P)

  for (si in seq_along(subjects)) {
    d <- df[df$participant_id == subjects[si], ]
    d <- d[order(d$trial), ]
    if (nrow(d) != Tn) stop(paste("Subject", subjects[si], "has", nrow(d), "trials; expected", Tn))
    for (ti in seq_len(Tn)) {
      pn  <- d$stm[ti]; pj <- p_index[[pn]]
      partner[si, ti] <- pj
      choice[si, ti]  <- as.integer(d$chose_high[ti])
      observed[si, ti] <- as.integer(d$observed[ti])
      amt             <- d$amount_sent[ti]
      feedback        <- !is.na(amt) && amt > 0          # NA-safe; non-response -> FALSE
      fb[si, ti]      <- as.integer(feedback)
      outcome[si, ti] <- if (feedback) as.integer(d$return_bin[ti]) else 0L
      low[si, ti]     <- d$low_amount[ti]
      high[si, ti]    <- d$high_amount[ti]
      if (K == 1) a_idx[si, ti] <- 1L
      else if (K == 2) a_idx[si, ti] <- if (feedback && outcome[si, ti] == 1L) 1L else 2L
      else a_idx[si, ti] <- cell_of[pj]
    }
    if (spec$q_init == "stereotype") {
      for (pn in partners) Q0[si, p_index[[pn]]] <- d$stm_prior[d$stm == pn][1]
    }
  }

  # base shared by all families (Q0 added per-family below: anchor builds it
  # from stereo x w1 inside Stan, so it is NOT passed for the anchor family)
  base <- list(S = S, T = Tn, P = P,
               partner = partner, choice = choice, fb = fb, outcome = outcome,
               low_amt = low, high_amt = high, observed = observed,
               readout = if (spec$readout == "value") 1L else 0L,
               use_phi = if (isTRUE(spec$phi)) 1L else 0L,
               recip_return = RECIP_RETURN,
               .subjects = subjects, .partners = partners)

  fam <- spec$family

  # fixed stereotype expectation per partner (scaled rating); needed by the
  # three stereotype-locus siblings (violation / anchor / choicepull)
  if (fam %in% c("violation", "anchor", "choicepull")) {
    stereo <- matrix(0.5, S, P)
    for (si in seq_along(subjects)) {
      d <- df[df$participant_id == subjects[si], ]
      for (pn in partners) {
        v <- d$stm_prior[d$stm == pn][1]
        if (!is.na(v)) stereo[si, p_index[[pn]]] <- v
      }
    }
  }

  if (fam == "core")
    return(c(base, list(Q0 = Q0, K = K, a_idx = a_idx)))

  if (fam == "violation") {
    snum <- 0; sden <- 0
    for (si in seq_len(S)) for (ti in seq_len(Tn)) if (fb[si, ti] == 1) {
      snum <- snum + abs(outcome[si, ti] - stereo[si, partner[si, ti]]); sden <- sden + 1
    }
    return(c(base, list(Q0 = Q0, stereo = stereo, viol_center = snum / sden)))
  }

  if (fam == "anchor")                       # Q0 computed in Stan from stereo x w1
    return(c(base, list(stereo = stereo)))

  if (fam == "choicepull")
    return(c(base, list(Q0 = Q0, stereo = stereo)))

  stop(paste("Unknown family:", fam))
}

# ===========================================================================
# Forward pass (identical math to Stan; for checks + recovery simulation)
# ===========================================================================
r_subject_loglik <- function(sd, si, alpha_vec, beta, phi) {
  P <- sd$P; Tn <- sd$T
  Q <- as.numeric(sd$Q0[si, ]); prev <- rep(NA_integer_, P); ll <- 0
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick)))
      ch <- sd$choice[si, t]
      ll <- ll + if (ch == 1) log(pr) else log(1 - pr)
      prev[p] <- ch                              # anchor only advances on a real choice
    }
    if (sd$fb[si, t] == 1) Q[p] <- Q[p] + alpha_vec[sd$a_idx[si, t]] * (sd$outcome[si, t] - Q[p])
  }
  ll
}

r_simulate_choices <- function(sd, si, alpha_vec, beta, phi) {
  P <- sd$P; Tn <- sd$T
  Q <- as.numeric(sd$Q0[si, ]); prev <- rep(NA_integer_, P); out <- integer(Tn)
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick)))
      ch <- as.integer(runif(1) < pr); out[t] <- ch; prev[p] <- ch
      sent <- if (ch == 1) sd$high_amt[si, t] else sd$low_amt[si, t]
      if (sent > 0 && sd$fb[si, t] == 1)
        Q[p] <- Q[p] + alpha_vec[sd$a_idx[si, t]] * (sd$outcome[si, t] - Q[p])
    } else {
      out[t] <- 0L                               # masked non-response; ignored in fitting
    }
  }
  out
}

# --- violation family: alpha scales with |outcome - fixed stereotype| --------
# alpha_base is the baseline learning rate in (0,1); omega the violation weight.
r_subject_loglik_viol <- function(sd, si, alpha_base, beta, phi, omega) {
  P <- sd$P; Tn <- sd$T; la <- qlogis(alpha_base)
  Q <- as.numeric(sd$Q0[si, ]); prev <- rep(NA_integer_, P); ll <- 0
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick)))
      ch <- sd$choice[si, t]
      ll <- ll + if (ch == 1) log(pr) else log(1 - pr)
      prev[p] <- ch
    }
    if (sd$fb[si, t] == 1) {
      viol  <- abs(sd$outcome[si, t] - sd$stereo[si, p])
      a_eff <- 1 / (1 + exp(-(la + omega * (viol - sd$viol_center))))
      Q[p]  <- Q[p] + a_eff * (sd$outcome[si, t] - Q[p])
    }
  }
  ll
}

r_simulate_choices_viol <- function(sd, si, alpha_base, beta, phi, omega) {
  P <- sd$P; Tn <- sd$T; la <- qlogis(alpha_base)
  Q <- as.numeric(sd$Q0[si, ]); prev <- rep(NA_integer_, P); out <- integer(Tn)
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick)))
      ch <- as.integer(runif(1) < pr); out[t] <- ch; prev[p] <- ch
      sent <- if (ch == 1) sd$high_amt[si, t] else sd$low_amt[si, t]
      if (sent > 0 && sd$fb[si, t] == 1) {
        viol  <- abs(sd$outcome[si, t] - sd$stereo[si, p])
        a_eff <- 1 / (1 + exp(-(la + omega * (viol - sd$viol_center))))
        Q[p]  <- Q[p] + a_eff * (sd$outcome[si, t] - Q[p])
      }
    } else {
      out[t] <- 0L
    }
  }
  out
}

# --- anchor family (W1): Q0 = 0.5 + w1*(stereo-0.5); constant learning rate ---
r_subject_loglik_anchor <- function(sd, si, alpha, beta, phi, w1) {
  P <- sd$P; Tn <- sd$T
  Q <- 0.5 + w1 * (as.numeric(sd$stereo[si, ]) - 0.5); prev <- rep(NA_integer_, P); ll <- 0
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick)))
      ch <- sd$choice[si, t]; ll <- ll + if (ch == 1) log(pr) else log(1 - pr); prev[p] <- ch
    }
    if (sd$fb[si, t] == 1) Q[p] <- Q[p] + alpha * (sd$outcome[si, t] - Q[p])
  }
  ll
}

r_simulate_choices_anchor <- function(sd, si, alpha, beta, phi, w1) {
  P <- sd$P; Tn <- sd$T
  Q <- 0.5 + w1 * (as.numeric(sd$stereo[si, ]) - 0.5); prev <- rep(NA_integer_, P); out <- integer(Tn)
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick)))
      ch <- as.integer(runif(1) < pr); out[t] <- ch; prev[p] <- ch
      sent <- if (ch == 1) sd$high_amt[si, t] else sd$low_amt[si, t]
      if (sent > 0 && sd$fb[si, t] == 1) Q[p] <- Q[p] + alpha * (sd$outcome[si, t] - Q[p])
    } else out[t] <- 0L
  }
  out
}

# --- choicepull family (W3): decaying stereotype pull on the choice policy ----
r_subject_loglik_choicepull <- function(sd, si, alpha, beta, phi, w3, lambda) {
  P <- sd$P; Tn <- sd$T
  Q <- as.numeric(sd$Q0[si, ]); prev <- rep(NA_integer_, P); occ <- integer(P); ll <- 0
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]; occ[p] <- occ[p] + 1
    pull <- w3 * (sd$stereo[si, p] - 0.5) * lambda^(occ[p] - 1)
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick + pull)))
      ch <- sd$choice[si, t]; ll <- ll + if (ch == 1) log(pr) else log(1 - pr); prev[p] <- ch
    }
    if (sd$fb[si, t] == 1) Q[p] <- Q[p] + alpha * (sd$outcome[si, t] - Q[p])
  }
  ll
}

r_simulate_choices_choicepull <- function(sd, si, alpha, beta, phi, w3, lambda) {
  P <- sd$P; Tn <- sd$T
  Q <- as.numeric(sd$Q0[si, ]); prev <- rep(NA_integer_, P); occ <- integer(P); out <- integer(Tn)
  for (t in seq_len(Tn)) {
    p <- sd$partner[si, t]; occ[p] <- occ[p] + 1
    pull <- w3 * (sd$stereo[si, p] - 0.5) * lambda^(occ[p] - 1)
    if (sd$observed[si, t] == 1) {
      stick <- if (is.na(prev[p])) 0 else if (prev[p] == 1) 1 else -1
      dv <- if (sd$readout == 1)
              (sd$high_amt[si, t] - sd$low_amt[si, t]) * (RECIP_RETURN * Q[p] - 1)
            else Q[p] - 0.5
      pr <- 1 / (1 + exp(-(beta * dv + phi * stick + pull)))
      ch <- as.integer(runif(1) < pr); out[t] <- ch; prev[p] <- ch
      sent <- if (ch == 1) sd$high_amt[si, t] else sd$low_amt[si, t]
      if (sent > 0 && sd$fb[si, t] == 1) Q[p] <- Q[p] + alpha * (sd$outcome[si, t] - Q[p])
    } else out[t] <- 0L
  }
  out
}

# ===========================================================================
# Fit
# ===========================================================================
fit_model <- function(model_name, df, chains = 4, iter = 2000, warmup = 1000,
                      adapt_delta = 0.95, max_treedepth = 12, seed = 1000,
                      cores = chains, stan_file = NULL, ...) {
  suppressPackageStartupMessages(library(rstan))
  rstan_options(auto_write = TRUE)
  options(mc.cores = cores)
  if (is.null(stan_file))
    stan_file <- switch(MODELS[[model_name]]$family,
                        violation  = VIOL_STAN_FILE,
                        anchor     = ANCHOR_STAN_FILE,
                        choicepull = CHOICE_STAN_FILE,
                        STAN_FILE)                       # default: core
  sd <- build_stan_data(df, model_name)
  payload <- sd[setdiff(names(sd), c(".subjects", ".partners"))]
  sm <- stan_model(file = stan_file)
  fit <- sampling(sm, data = payload, chains = chains, iter = iter, warmup = warmup,
                  control = list(adapt_delta = adapt_delta, max_treedepth = max_treedepth),
                  seed = seed, ...)
  list(fit = fit, stan_data = sd)
}

group_summary <- function(fit, model_name) {
  fam <- MODELS[[model_name]]$family
  pars <- switch(fam,
    violation  = c("mu_alpha", "sigma_alpha", "mu_beta", "sigma_beta", "omega"),
    anchor     = c("mu_alpha", "sigma_alpha", "mu_beta", "sigma_beta", "w1"),
    choicepull = c("mu_alpha", "sigma_alpha", "mu_beta", "sigma_beta", "w3", "lambda"),
    c("mu_alpha", "d_alpha", "tau_alpha", "sigma_alpha", "mu_beta", "sigma_beta"))  # core
  if (isTRUE(MODELS[[model_name]]$phi)) pars <- c(pars, "mu_phi", "sigma_phi")
  rstan::summary(fit, pars = pars)$summary
}

trial_level <- function(fit) {
  ex <- rstan::extract(fit, pars = c("Q_chosen", "pe", "p_high", "log_lik"))
  list(
    Q_chosen = apply(ex$Q_chosen, c(2, 3), mean),
    pe       = apply(ex$pe,       c(2, 3), mean),
    p_high   = apply(ex$p_high,   c(2, 3), mean),
    log_lik_draws = ex$log_lik           # [draws, S, T] for loo::waic / loo
  )
}

# ===========================================================================
# Hierarchical parameter recovery
# ===========================================================================
simulate_dataset <- function(df, model_name, group_truth, seed = 0) {
  set.seed(seed)
  sd <- build_stan_data(df, model_name)
  S <- sd$S
  za <- rnorm(S); zb <- rnorm(S); zp <- rnorm(S)
  sim <- df
  fam <- MODELS[[model_name]]$family
  d_alpha <- if (fam == "core") {
    da <- if (!is.null(group_truth$d_alpha)) group_truth$d_alpha else rep(0, sd$K)
    da - mean(da)
  } else NULL
  for (si in seq_along(sd$.subjects)) {
    sub <- sd$.subjects[si]
    beta <- exp(group_truth$mu_beta + group_truth$sigma_beta * zb[si])
    phi  <- if (sd$use_phi == 1)
              (group_truth$mu_phi %||% 0) + (group_truth$sigma_phi %||% 0) * zp[si] else 0
    a1   <- 1 / (1 + exp(-(group_truth$mu_alpha + group_truth$sigma_alpha * za[si])))  # scalar alpha
    ch <- switch(fam,
      violation  = r_simulate_choices_viol(sd, si, a1, beta, phi, group_truth$omega %||% 0),
      anchor     = r_simulate_choices_anchor(sd, si, a1, beta, phi, group_truth$w1 %||% 1),
      choicepull = r_simulate_choices_choicepull(sd, si, a1, beta, phi,
                                                 group_truth$w3 %||% 0, group_truth$lambda %||% 0.5),
      {  # core
        alpha_vec <- 1 / (1 + exp(-(group_truth$mu_alpha + d_alpha + group_truth$sigma_alpha * za[si])))
        r_simulate_choices(sd, si, alpha_vec, beta, phi)
      })
    idx <- which(sim$participant_id == sub)
    idx <- idx[order(sim$trial[idx])]
    sim$chose_high[idx] <- ch
  }
  sim
}
`%||%` <- function(a, b) if (is.null(a)) b else a

recover <- function(df, model_name, group_truth, seed = 0, ...) {
  sim <- simulate_dataset(df, model_name, group_truth, seed = seed)
  res <- fit_model(model_name, sim, ...)
  list(truth = group_truth, summary = group_summary(res$fit, model_name))
}

# ===========================================================================
# CLI: Rscript fit_rstan.R <data.csv> <model> [out_dir]
# ===========================================================================
if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) < 2) stop("Usage: Rscript fit_rstan.R <data.csv> <model> [out_dir]")
  df <- load_and_prep(args[1])
  res <- fit_model(args[2], df)
  print(group_summary(res$fit, args[2]))
  if (length(args) >= 3) saveRDS(res$fit, file.path(args[3], paste0("fit_", args[2], ".rds")))
}
