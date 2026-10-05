// ===========================================================================
// trust_rl_core_rstan.stan
//
// RStan port of trust_rl_core.stan. The model is IDENTICAL; only the array
// declaration syntax is written in the legacy form (`int x[N];` rather than
// `array[N] int x;`) so it compiles across rstan versions (2.19-2.32). If you
// are on rstan >= 2.26 (recent StanHeaders) or cmdstanr, the array[] syntax in
// trust_rl_core.stan also works and avoids deprecation warnings.
//
// ONE flexible program covering the standard-RL ladder by DATA:
//   K + a_idx  -> alpha scheme (1 single / 2 valence / 3 congruence / 6 type)
//   Q0         -> flat 0.5 or rescaled stereotype rating, per subject x partner
//   readout    -> 0 belief (Q-0.5), 1 value (EV gap)
//   use_phi    -> include perseveration
// Hierarchy: subject-level overall alpha, beta, (phi); group-level cell offsets
// d_alpha (mean-centered, pooled via tau_alpha) carry the valence/congruence/
// type pattern. generated quantities returns trial-level Q, prediction error,
// choice probability, and pointwise log-lik (WAIC/LOO).
// ===========================================================================
data {
  int<lower=1> S;
  int<lower=1> T;
  int<lower=1> P;
  int<lower=1> K;

  int<lower=1, upper=P> partner[S, T];
  int<lower=0, upper=1> choice[S, T];
  int<lower=0, upper=1> fb[S, T];
  int<lower=0, upper=1> outcome[S, T];
  int<lower=1, upper=K> a_idx[S, T];
  real low_amt[S, T];
  real high_amt[S, T];
  real Q0[S, P];
  int<lower=0, upper=1> observed[S, T];      // 1 = a choice was made; 0 = non-response (masked)

  int<lower=0, upper=1> readout;
  int<lower=0, upper=1> use_phi;
  real recip_return;
}

parameters {
  real mu_alpha;
  vector[K] d_alpha_raw;
  real<lower=0> tau_alpha;
  real<lower=0> sigma_alpha;
  vector[S] z_alpha;

  real mu_beta;
  real<lower=0> sigma_beta;
  vector[S] z_beta;

  real mu_phi;
  real<lower=0> sigma_phi;
  vector[S] z_phi;
}

transformed parameters {
  vector[K] d_alpha;
  vector[K] alpha[S];
  vector<lower=0>[S] beta;
  vector[S] phi;
  {
    vector[K] tmp = d_alpha_raw * tau_alpha;
    d_alpha = tmp - mean(tmp);            // mean-centered; K=1 -> all zero
  }
  for (s in 1:S) {
    for (k in 1:K)
      alpha[s, k] = inv_logit(mu_alpha + d_alpha[k] + sigma_alpha * z_alpha[s]);
    beta[s] = exp(mu_beta + sigma_beta * z_beta[s]);
    phi[s]  = use_phi == 1 ? (mu_phi + sigma_phi * z_phi[s]) : 0.0;
  }
}

model {
  mu_alpha    ~ normal(0, 1.5);
  d_alpha_raw ~ std_normal();
  tau_alpha   ~ normal(0, 1);
  sigma_alpha ~ normal(0, 1);
  z_alpha     ~ std_normal();

  mu_beta    ~ normal(0, 1);
  sigma_beta ~ normal(0, 1);
  z_beta     ~ std_normal();

  mu_phi    ~ normal(0, 1);
  sigma_phi ~ normal(0, 1);
  z_phi     ~ std_normal();

  for (s in 1:S) {
    vector[P] Q = to_vector(Q0[s]);
    int prev[P];
    for (p in 1:P) prev[p] = -1;
    for (t in 1:T) {
      int p = partner[s, t];
      real stick = prev[p] == -1 ? 0.0 : (prev[p] == 1 ? 1.0 : -1.0);
      real dv = readout == 1
                ? (high_amt[s, t] - low_amt[s, t]) * (recip_return * Q[p] - 1.0)
                : (Q[p] - 0.5);
      if (observed[s, t] == 1) {              // skip non-responses; anchor unchanged
        choice[s, t] ~ bernoulli_logit(beta[s] * dv + phi[s] * stick);
        prev[p] = choice[s, t];
      }
      if (fb[s, t] == 1)
        Q[p] = Q[p] + alpha[s, a_idx[s, t]] * (outcome[s, t] - Q[p]);
    }
  }
}

generated quantities {
  real Q_chosen[S, T];
  real pe[S, T];
  real p_high[S, T];
  real log_lik[S, T];
  for (s in 1:S) {
    vector[P] Q = to_vector(Q0[s]);
    int prev[P];
    for (p in 1:P) prev[p] = -1;
    for (t in 1:T) {
      int p = partner[s, t];
      real stick = prev[p] == -1 ? 0.0 : (prev[p] == 1 ? 1.0 : -1.0);
      real dv = readout == 1
                ? (high_amt[s, t] - low_amt[s, t]) * (recip_return * Q[p] - 1.0)
                : (Q[p] - 0.5);
      real eta = beta[s] * dv + phi[s] * stick;
      Q_chosen[s, t] = Q[p];
      p_high[s, t]   = inv_logit(eta);
      // log_lik only over real choices, so WAIC/LOO sum over observed trials;
      // Q_chosen / p_high / pe are still recorded on every trial for plotting.
      log_lik[s, t]  = observed[s, t] == 1 ? bernoulli_logit_lpmf(choice[s, t] | eta) : 0;
      if (observed[s, t] == 1)
        prev[p] = choice[s, t];
      if (fb[s, t] == 1) {
        pe[s, t] = outcome[s, t] - Q[p];
        Q[p] = Q[p] + alpha[s, a_idx[s, t]] * pe[s, t];
      } else {
        pe[s, t] = 0;
      }
    }
  }
}
