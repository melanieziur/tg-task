// ===========================================================================
// trust_rl_anchor_rstan.stan   (W1 / Locus 1: stereotype weights the PRIOR)
//
// Sibling of trust_rl_core_rstan.stan on the M7 architecture (single learning
// rate, perseveration), but the stereotype enters only through HOW STRONGLY it
// anchors the initial belief, via one group-level weight w1:
//
//   Q0_eff[s,p] = 0.5 + w1 * (stereo[s,p] - 0.5)      (stereo = scaled rating)
//
//   w1 = 1  -> Q0 = stereo  (exactly M7: full stereotype anchor)
//   w1 = 0  -> Q0 = 0.5      (stereotype ignored; everyone starts neutral)
//   0<w1<1  -> prior partially discounted toward neutral
//   w1 > 1  -> stereotype over-weighted
//
// Because w1 = 1 reproduces M7, the models are nested: W1 asks *how much* the
// stereotype sets the starting belief, and the M7-vs-W1 comparison plus the
// posterior of w1 (vs 0 and vs 1) localizes the prior effect. Learning rate is
// constant (not violation-modulated) -- this isolates the prior, not the rate.
// ===========================================================================
data {
  int<lower=1> S;
  int<lower=1> T;
  int<lower=1> P;

  int<lower=1, upper=P> partner[S, T];
  int<lower=0, upper=1> choice[S, T];
  int<lower=0, upper=1> fb[S, T];
  int<lower=0, upper=1> outcome[S, T];
  int<lower=0, upper=1> observed[S, T];
  real low_amt[S, T];
  real high_amt[S, T];
  real stereo[S, P];             // fixed stereotype expectation per partner (scaled rating)

  int<lower=0, upper=1> readout;
  int<lower=0, upper=1> use_phi;
  real recip_return;
}

parameters {
  real mu_alpha;
  real<lower=0> sigma_alpha;
  vector[S] z_alpha;

  real mu_beta;
  real<lower=0> sigma_beta;
  vector[S] z_beta;

  real mu_phi;
  real<lower=0> sigma_phi;
  vector[S] z_phi;

  real w1;                       // group-level stereotype anchor weight
}

transformed parameters {
  vector<lower=0, upper=1>[S] alpha;
  vector<lower=0>[S] beta;
  vector[S] phi;
  for (s in 1:S) {
    alpha[s] = inv_logit(mu_alpha + sigma_alpha * z_alpha[s]);
    beta[s]  = exp(mu_beta + sigma_beta * z_beta[s]);
    phi[s]   = use_phi == 1 ? (mu_phi + sigma_phi * z_phi[s]) : 0.0;
  }
}

model {
  mu_alpha ~ normal(0, 1.5);  sigma_alpha ~ normal(0, 1);  z_alpha ~ std_normal();
  mu_beta  ~ normal(0, 1);    sigma_beta  ~ normal(0, 1);  z_beta  ~ std_normal();
  mu_phi   ~ normal(0, 1);    sigma_phi   ~ normal(0, 1);  z_phi   ~ std_normal();
  w1 ~ normal(0, 1);          // weakly informative; w1 = 1 -> M7

  for (s in 1:S) {
    vector[P] Q;
    int prev[P];
    for (p in 1:P) { Q[p] = 0.5 + w1 * (stereo[s, p] - 0.5); prev[p] = -1; }
    for (t in 1:T) {
      int p = partner[s, t];
      real stick = prev[p] == -1 ? 0.0 : (prev[p] == 1 ? 1.0 : -1.0);
      real dv = readout == 1
                ? (high_amt[s, t] - low_amt[s, t]) * (recip_return * Q[p] - 1.0)
                : (Q[p] - 0.5);
      if (observed[s, t] == 1) {
        choice[s, t] ~ bernoulli_logit(beta[s] * dv + phi[s] * stick);
        prev[p] = choice[s, t];
      }
      if (fb[s, t] == 1)
        Q[p] = Q[p] + alpha[s] * (outcome[s, t] - Q[p]);
    }
  }
}

generated quantities {
  real Q_chosen[S, T];
  real pe[S, T];
  real p_high[S, T];
  real log_lik[S, T];
  for (s in 1:S) {
    vector[P] Q;
    int prev[P];
    for (p in 1:P) { Q[p] = 0.5 + w1 * (stereo[s, p] - 0.5); prev[p] = -1; }
    for (t in 1:T) {
      int p = partner[s, t];
      real stick = prev[p] == -1 ? 0.0 : (prev[p] == 1 ? 1.0 : -1.0);
      real dv = readout == 1
                ? (high_amt[s, t] - low_amt[s, t]) * (recip_return * Q[p] - 1.0)
                : (Q[p] - 0.5);
      real eta = beta[s] * dv + phi[s] * stick;
      Q_chosen[s, t] = Q[p];
      p_high[s, t]   = inv_logit(eta);
      log_lik[s, t]  = observed[s, t] == 1 ? bernoulli_logit_lpmf(choice[s, t] | eta) : 0;
      if (observed[s, t] == 1) prev[p] = choice[s, t];
      if (fb[s, t] == 1) {
        pe[s, t] = outcome[s, t] - Q[p];
        Q[p] = Q[p] + alpha[s] * pe[s, t];
      } else {
        pe[s, t] = 0;
      }
    }
  }
}
