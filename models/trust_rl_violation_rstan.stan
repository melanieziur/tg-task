// ===========================================================================
// trust_rl_violation_rstan.stan   (Locus 2: stereotype-violation learning)
//
// Sibling of trust_rl_core_rstan.stan, built on the M7 architecture (single
// baseline learning rate, stereotype-rating prior Q0, perseveration). It adds
// ONE group-level weight, omega, that lets the effective learning rate scale
// with how much each outcome VIOLATES the fixed stereotype expectation:
//
//   violation_t  = | r_t - s_p |            (s_p = fixed scaled pre-game rating)
//   alpha_eff    = inv_logit( logit(alpha_s) + omega * (violation_t - viol_center) )
//   Q <- Q + alpha_eff * (r_t - Q)
//
// s_p is FIXED (never updates) -- this is surprise relative to the stereotype,
// not relative to the running belief Q (which would just be Pearce-Hall
// surprise). omega > 0: stereotype-violating outcomes update faster (the
// identity-prediction-error account). omega = 0 reduces EXACTLY to M7, so the
// models are nested and WAIC/LOO compares them directly.
//
// viol_center (data) centers the violation regressor at its mean so omega is
// decoupled from the baseline learning rate; logit(alpha_s) = mu_alpha +
// sigma_alpha * z_alpha[s] is the subject baseline, omega is group-level.
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
  real Q0[S, P];                 // initial belief per subject x partner
  real stereo[S, P];             // FIXED stereotype expectation per partner (scaled rating)
  real viol_center;              // mean |r - s_p| over feedback trials (centering)

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

  real omega;                    // group-level violation-sensitivity weight
}

transformed parameters {
  vector[S] la = mu_alpha + sigma_alpha * z_alpha;          // subject logit baseline alpha
  vector<lower=0, upper=1>[S] alpha_base;                   // = inv_logit(la), for reporting
  vector<lower=0>[S] beta;
  vector[S] phi;
  for (s in 1:S) {
    alpha_base[s] = inv_logit(la[s]);
    beta[s] = exp(mu_beta + sigma_beta * z_beta[s]);
    phi[s]  = use_phi == 1 ? (mu_phi + sigma_phi * z_phi[s]) : 0.0;
  }
}

model {
  mu_alpha    ~ normal(0, 1.5);
  sigma_alpha ~ normal(0, 1);
  z_alpha     ~ std_normal();

  mu_beta    ~ normal(0, 1);
  sigma_beta ~ normal(0, 1);
  z_beta     ~ std_normal();

  mu_phi    ~ normal(0, 1);
  sigma_phi ~ normal(0, 1);
  z_phi     ~ std_normal();

  omega ~ normal(0, 1);          // weakly informative; ω=0 -> M7

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
      if (observed[s, t] == 1) {
        choice[s, t] ~ bernoulli_logit(beta[s] * dv + phi[s] * stick);
        prev[p] = choice[s, t];
      }
      if (fb[s, t] == 1) {
        real viol  = fabs(outcome[s, t] - stereo[s, p]);
        real a_eff = inv_logit(la[s] + omega * (viol - viol_center));
        Q[p] = Q[p] + a_eff * (outcome[s, t] - Q[p]);
      }
    }
  }
}

generated quantities {
  real Q_chosen[S, T];
  real pe[S, T];
  real p_high[S, T];
  real log_lik[S, T];
  real alpha_eff[S, T];          // effective learning rate used on each feedback trial (0 otherwise)
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
      log_lik[s, t]  = observed[s, t] == 1 ? bernoulli_logit_lpmf(choice[s, t] | eta) : 0;
      if (observed[s, t] == 1) prev[p] = choice[s, t];
      if (fb[s, t] == 1) {
        real viol = fabs(outcome[s, t] - stereo[s, p]);
        real a_eff = inv_logit(la[s] + omega * (viol - viol_center));
        pe[s, t]        = outcome[s, t] - Q[p];
        alpha_eff[s, t] = a_eff;
        Q[p] = Q[p] + a_eff * pe[s, t];
      } else {
        pe[s, t] = 0;
        alpha_eff[s, t] = 0;
      }
    }
  }
}
