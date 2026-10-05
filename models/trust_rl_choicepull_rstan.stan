// ===========================================================================
// trust_rl_choicepull_rstan.stan   (W3 / Locus 3: decaying stereotype pull on CHOICE)
//
// Sibling on the M7 architecture (single learning rate, stereotype prior Q0,
// perseveration), adding a stereotype bias that acts DIRECTLY ON CHOICE and
// fades with experience of the partner:
//
//   eta = beta*dv + phi*stick + w3 * (stereo[s,p] - 0.5) * lambda^(k-1)
//
// where k is the partner's occurrence count (1 on first encounter) and
// lambda in (0,1) is a group-level decay. Early on, a trustworthy-looking
// partner (stereo > 0.5) pulls choices toward trusting regardless of the
// learned belief Q; the pull decays as evidence accumulates. This is a
// choice-level bias that coexists with learned value -- distinct from W1
// (which moves the prior) and the violation model (which moves the rate).
//
//   w3 = 0 -> M7 exactly (nested). lambda is only identified when w3 != 0;
//   if w3 ~ 0 in the data, lambda reverts to its prior (expected, ignorable).
//   Both w3 and lambda are group-level (not subject-varying), mirroring omega.
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
  real Q0[S, P];                 // initial belief per partner (stereotype prior)
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

  real w3;                       // group-level choice-pull weight
  real<lower=0, upper=1> lambda; // group-level decay of the pull with experience
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
  w3 ~ normal(0, 1);          // weakly informative; w3 = 0 -> M7
  lambda ~ beta(2, 2);        // gentle prior away from the 0/1 edges

  for (s in 1:S) {
    vector[P] Q = to_vector(Q0[s]);
    int prev[P];
    int occ[P];
    for (p in 1:P) { prev[p] = -1; occ[p] = 0; }
    for (t in 1:T) {
      int p = partner[s, t];
      real stick;
      real dv;
      real pull;
      occ[p] = occ[p] + 1;
      stick = prev[p] == -1 ? 0.0 : (prev[p] == 1 ? 1.0 : -1.0);
      dv = readout == 1
           ? (high_amt[s, t] - low_amt[s, t]) * (recip_return * Q[p] - 1.0)
           : (Q[p] - 0.5);
      pull = w3 * (stereo[s, p] - 0.5) * pow(lambda, occ[p] - 1);
      if (observed[s, t] == 1) {
        choice[s, t] ~ bernoulli_logit(beta[s] * dv + phi[s] * stick + pull);
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
  real pull_term[S, T];          // the stereotype choice-pull on each trial
  for (s in 1:S) {
    vector[P] Q = to_vector(Q0[s]);
    int prev[P];
    int occ[P];
    for (p in 1:P) { prev[p] = -1; occ[p] = 0; }
    for (t in 1:T) {
      int p = partner[s, t];
      real stick;
      real dv;
      real pull;
      real eta;
      occ[p] = occ[p] + 1;
      stick = prev[p] == -1 ? 0.0 : (prev[p] == 1 ? 1.0 : -1.0);
      dv = readout == 1
           ? (high_amt[s, t] - low_amt[s, t]) * (recip_return * Q[p] - 1.0)
           : (Q[p] - 0.5);
      pull = w3 * (stereo[s, p] - 0.5) * pow(lambda, occ[p] - 1);
      eta = beta[s] * dv + phi[s] * stick + pull;
      Q_chosen[s, t]  = Q[p];
      p_high[s, t]    = inv_logit(eta);
      pull_term[s, t] = pull;
      log_lik[s, t]   = observed[s, t] == 1 ? bernoulli_logit_lpmf(choice[s, t] | eta) : 0;
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
