#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Trust-game RL model fitting -- single-Q-per-partner formulation, with a
simulate-and-recover block (model-recovery confusion matrix + parameter
recovery).

WHAT THE MODELED CHOICE IS
--------------------------
Each trial the participant is shown two amounts (left_amount, right_amount)
and sends one of them (amount_sent). The modeled binary decision is whether
they sent the LARGER of the two amounts:

    chose_high = 1  -> sent the higher amount
    chose_high = 0  -> sent the lower amount

TWO CHOICE READOUTS (set per model via ModelSpec.readout)
---------------------------------------------------------
  "belief":  P(send high) = sigmoid(beta * (Q - 0.5) + phi * stick)
             Choice depends only on the belief Q and ignores the stakes.

  "value":   P(send high) = sigmoid(beta * dV + phi * stick),
             dV = (a_high - a_low) * (RECIP_RETURN_PER_DOLLAR * Q - 1)
             Choice depends on the expected-value gap between the two offered
             amounts, so it scales with how large the stakes are.

  In both, Q is ONE value per partner = expected P(partner reciprocates),
  stick = +1 / -1 / 0 for last action high / low / first encounter, and the
  stereotype-prior models initialize Q from the participant's pre-game rating.

PAYOFF ECONOMICS (motivates the "value" readout)
------------------------------------------------
The amount sent is tripled, then the partner returns half of that (reciprocate)
or nothing (defect). So sending $a yields 1.5*a if reciprocated, 0 if defected
(e.g., send $4 -> 4*3/2 = $6 back, or $0). Relative to keeping the dollar, each
staked dollar is worth (1.5*Q - 1) in expectation: positive only when the
participant believes reciprocation is more likely than ~2/3. The value gap
between the high and low options is therefore (a_high - a_low)*(1.5*Q - 1).

WHEN LEARNING HAPPENS
---------------------
Reciprocation feedback exists only when a positive amount was sent. return_bin
is NaN whenever amount_sent == 0, and the learning step is skipped on NaN
trials. Learning is NOT tied to whether the higher or lower amount was chosen.

DATA COLUMNS USED
-----------------
  left_amount, right_amount : the two offered amounts.
  amount_sent               : amount the participant actually sent.
  partner_choice            : "half" (reciprocated) or "none" (did not / n.a.).
  pre_trustworthiness       : pre-game rating of the partner, 0-100, constant
                              within partner; rescaled to [0,1] for the prior.
  stm                       : partner identity (occupation).
  profile                   : occupational stereotype ("Trustworthy"/"Untrustworthy").
  behavior                  : reciprocity type ("Trustworthy" 80% / "Untrustworthy"
                              20% / "Neutral" 50%).
"""

import os
import argparse
from collections import namedtuple
import pandas as pd
import numpy as np
from scipy.optimize import minimize
from scipy.special import expit  # sigmoid

np.random.seed(1000)

# --- config -----------------------------------------------------------------
BELIEF_MIDPOINT         = 0.5   # reference belief for the "belief" readout
RECIP_RETURN_PER_DOLLAR = 1.5   # dollars returned per dollar staked if reciprocated
                                # (amount tripled, then halved back -> 3/2)

# Recovery covers ALL registered models by default (gen_models=fit_models=None
# -> resolved to the full registry inside run_recovery). Parameter recovery is
# guaranteed for every generating model regardless of the confusion-matrix fit
# set, because run_recovery always also fits each model to its own data.
# WARNING: the confusion matrix is a full gen x fit cross (~ len(MODELS)^2 x
# n_iter x n_starts fits); with all 32 models this is a multi-hour run. Throttle
# with --recovery-n-iter / --recovery-n-starts, or pass a smaller fit_models
# list (parameter recovery for all models is unaffected by that).
RECOVERY_GEN_MODELS = None   # None -> all models
RECOVERY_FIT_MODELS = None   # None -> all models
RECOVERY_N_ITER     = 15     # synthetic datasets per generating model
RECOVERY_N_STARTS   = 8      # optimizer restarts per fit during recovery

EXPECTED_BEHAVIOR = {"Trustworthy", "Untrustworthy", "Neutral"}
EXPECTED_PROFILE  = {"Trustworthy", "Untrustworthy"}

# Six stereotype x behavior cells, one partner per cell:
#   first letter  = occupational stereotype (profile): T rustworthy / U ntrustworthy
#   second letter = behavior relative to it: C ongruent / I ncongruent / A mbiguous
PARTNER_TYPES = ["TC", "TI", "UC", "UI", "TA", "UA"]

exclude = ['O100', 'O711', '721', 'O725']


# ===========================================================================
# Model registry
#   A model is fully described by five switches. M0 (null) is the lone special
#   case (no free parameters).
#     n_alpha   : 1 | 2 | "cong" | "type"
#                 1      single learning rate
#                 2      reciprocation vs defection (outcome-gated)
#                 "cong" congruent / incongruent / ambiguous (3 alphas)
#                 "type" one alpha per stereotype x behavior cell (6 alphas:
#                        TC TI UC UI TA UA). Unconstrained parent of "cong".
#     phi       : bool             (choice perseveration)
#     dual_beta : bool             (beta gated by last observed outcome)
#     q_init    : "fixed" | "stereotype"
#     readout   : "belief" | "value"
# ===========================================================================
ModelSpec = namedtuple("ModelSpec", "n_alpha phi dual_beta q_init readout")

MODELS = {
    "M0": None,  # null: P(send high) = 0.5

    # ---- fixed prior (Q0 = 0.5), belief readout ----------------------------
    "M1":  ModelSpec(1,      False, False, "fixed", "belief"),
    "M2":  ModelSpec(2,      False, False, "fixed", "belief"),
    "M3":  ModelSpec(1,      True,  False, "fixed", "belief"),
    "M3b": ModelSpec(2,      True,  False, "fixed", "belief"),
    "M4":  ModelSpec(2,      True,  True,  "fixed", "belief"),

    # ---- stereotype prior (Q0 = pre-game rating), belief readout -----------
    "M5":  ModelSpec(1,      False, False, "stereotype", "belief"),
    "M6":  ModelSpec(2,      False, False, "stereotype", "belief"),
    "M7":  ModelSpec(1,      True,  False, "stereotype", "belief"),
    "M7b": ModelSpec(2,      True,  False, "stereotype", "belief"),
    "M8":  ModelSpec(2,      True,  True,  "stereotype", "belief"),

    # ---- congruence-gated learning rates, belief readout -------------------
    # Naming: _P adds perseveration, _S uses the stereotype prior. The original
    # M_cong had neither, so it was missing both ingredients that mattered in
    # the main family; M_cong_SP is the fair-shot version (stereotype + phi),
    # matched to the architecture of the winning model (M7).
    "M_cong":    ModelSpec("cong", False, False, "fixed",      "belief"),
    "M_cong_P":  ModelSpec("cong", True,  False, "fixed",      "belief"),
    "M_cong_S":  ModelSpec("cong", False, False, "stereotype", "belief"),
    "M_cong_SP": ModelSpec("cong", True,  False, "stereotype", "belief"),

    # ---- value readout twins (stakes-sensitive choice) ---------------------
    "M1v":  ModelSpec(1,      False, False, "fixed", "value"),
    "M2v":  ModelSpec(2,      False, False, "fixed", "value"),
    "M3v":  ModelSpec(1,      True,  False, "fixed", "value"),
    "M3bv": ModelSpec(2,      True,  False, "fixed", "value"),
    "M5v":  ModelSpec(1,      False, False, "stereotype", "value"),
    "M6v":  ModelSpec(2,      False, False, "stereotype", "value"),
    "M7v":  ModelSpec(1,      True,  False, "stereotype", "value"),
    "M7bv": ModelSpec(2,      True,  False, "stereotype", "value"),
    "M_congv":    ModelSpec("cong", False, False, "fixed",      "value"),
    "M_cong_Sv":  ModelSpec("cong", False, False, "stereotype", "value"),
    "M_cong_SPv": ModelSpec("cong", True,  False, "stereotype", "value"),

    # ---- partner-type learning rates (6 alphas: one per TC/TI/UC/UI/TA/UA) --
    # Most granular learning-rate model: one alpha per partner cell. With a
    # single partner per cell these are estimated from ~16 feedback trials
    # each, so per-subject MLE estimates will be noisy -- validate with the
    # parameter-recovery output before interpreting individual alphas, and
    # consider hierarchical fitting. M_type_SP matches the winning M7 setup.
    "M_type":     ModelSpec("type", False, False, "fixed",      "belief"),
    "M_type_P":   ModelSpec("type", True,  False, "fixed",      "belief"),
    "M_type_S":   ModelSpec("type", False, False, "stereotype", "belief"),
    "M_type_SP":  ModelSpec("type", True,  False, "stereotype", "belief"),
    "M_type_Sv":  ModelSpec("type", False, False, "stereotype", "value"),
    "M_type_SPv": ModelSpec("type", True,  False, "stereotype", "value"),
}


def _param_names(spec):
    """Ordered free-parameter names implied by a ModelSpec."""
    if spec.n_alpha == 1:
        names = ["alpha"]
    elif spec.n_alpha == 2:
        names = ["alpha_r", "alpha_d"]
    elif spec.n_alpha == "cong":
        names = ["alpha_c", "alpha_i", "alpha_amb"]
    else:  # "type": one learning rate per stereotype x behavior cell
        names = [f"alpha_{t}" for t in PARTNER_TYPES]
    names += ["beta_r", "beta_d"] if spec.dual_beta else ["beta"]
    if spec.phi:
        names.append("phi")
    return names


def _param_bounds(spec):
    """Optimizer bounds aligned with _param_names. Value-readout betas live on
    a smaller scale because they multiply a dollar-denominated value gap."""
    beta_bound = (0.01, 20.0) if spec.readout == "belief" else (0.001, 5.0)
    bounds = []
    for nm in _param_names(spec):
        if nm.startswith("alpha"):
            bounds.append((0.0, 1.0))
        elif nm.startswith("beta"):
            bounds.append(beta_bound)
        elif nm == "phi":
            bounds.append((-5.0, 5.0))
    return bounds


def param_names(model_name):
    spec = MODELS[model_name]
    return [] if spec is None else _param_names(spec)


def n_params(model_name):
    return len(param_names(model_name))


# ===========================================================================
# Load + prepare data
# ===========================================================================
def load_data(path):
    raw_df = pd.read_csv(path)
    df = raw_df[~raw_df['participant_id'].isin(exclude)]

    required = ["participant_id", "trial", "stm", "left_amount", "right_amount",
                "amount_sent", "partner_choice", "behavior", "pre_trustworthiness"]
    missing = [c for c in required if c not in df.columns]
    if missing:
        raise ValueError(f"Data is missing required columns: {missing}")

    # The two offered amounts, lower and higher, per trial.
    df["low_amount"]  = df[["left_amount", "right_amount"]].min(axis=1)
    df["high_amount"] = df[["left_amount", "right_amount"]].max(axis=1)

    # Modeled choice: did the participant send the larger amount?
    df["chose_high"] = (df["amount_sent"] == df["high_amount"]).astype(int)

    # Reciprocation outcome, observed ONLY when a positive amount was sent.
    #   sent == 0 -> nothing at stake -> no feedback -> NaN
    #   sent  > 0 -> 1 if partner returned half, else 0
    df["return_bin"] = np.where(
        df["amount_sent"] > 0,
        (df["partner_choice"] == "half").astype(float),
        np.nan,
    )

    # Pre-game rating (0-100) rescaled to [0,1]; initial Q for M5-M8 / *v twins.
    df["stm_prior"] = df["pre_trustworthiness"] / 100.0

    # --- light sanity checks (fail fast on surprising data) -----------------
    bad_beh = set(df["behavior"].dropna().unique()) - EXPECTED_BEHAVIOR
    if bad_beh:
        raise ValueError(f"Unexpected behavior labels: {bad_beh}")
    if "profile" in df.columns:
        bad_prof = set(df["profile"].dropna().unique()) - EXPECTED_PROFILE
        if bad_prof:
            raise ValueError(f"Unexpected profile labels: {bad_prof}")
    grp = df.groupby(["participant_id", "stm"])["pre_trustworthiness"].nunique()
    if (grp > 1).any():
        raise ValueError("pre_trustworthiness varies within a participant x partner.")

    return df


# ===========================================================================
# Helpers
# ===========================================================================
def _resolve_q0(p, q_init):
    """q_init may be a scalar (fixed 0.5) or a dict {partner: prior}."""
    if isinstance(q_init, dict):
        return float(q_init.get(p, 0.5))
    return float(q_init)


def choice_prob(Q, beta, stick, phi, readout, a_low, a_high):
    """P(send the higher amount).

    belief: decision value = Q - 0.5 (stakes ignored).
    value : decision value = (a_high - a_low) * (1.5*Q - 1), the expected-value
            gap between the higher and lower options under the task payoff."""
    if readout == "value":
        dv = (a_high - a_low) * (RECIP_RETURN_PER_DOLLAR * Q - 1.0)
    else:
        dv = Q - BELIEF_MIDPOINT
    return expit(beta * dv + phi * stick)


_CONG_TO_ALPHA = {"congruent": "alpha_c", "incongruent": "alpha_i", "ambiguous": "alpha_amb"}


def _congruence_map(data, partners):
    """Label each partner congruent / incongruent / ambiguous by whether its
    reciprocity behavior matches its occupational stereotype (collapses profile)."""
    cmap = {}
    for p in partners:
        row = data[data["stm"] == p].iloc[0]
        profile, behav = row["profile"], row["behavior"]
        if behav == "Neutral":
            cmap[p] = "ambiguous"
        elif (profile == "Trustworthy"   and behav == "Trustworthy") or \
             (profile == "Untrustworthy" and behav == "Untrustworthy"):
            cmap[p] = "congruent"
        else:
            cmap[p] = "incongruent"
    return cmap


def _partner_type_map(data, partners):
    """Label each partner with its stereotype x behavior cell (TC/TI/UC/UI/TA/UA).
    This keeps the stereotype profile separate from congruence, so it is the
    UNCONSTRAINED parent of the congruence scheme: congruence forces
    alpha_TC = alpha_UC, alpha_TI = alpha_UI, alpha_TA = alpha_UA, and the
    single-alpha models force all six equal."""
    cong = _congruence_map(data, partners)
    cell = {"congruent": "C", "incongruent": "I", "ambiguous": "A"}
    out = {}
    for p in partners:
        prof = "T" if data[data["stm"] == p].iloc[0]["profile"] == "Trustworthy" else "U"
        out[p] = prof + cell[cong[p]]
    return out


def _alpha_key_map(spec, data, partners):
    """For partner-static alpha schemes, map each partner to the NAME of the
    learning-rate parameter governing it. Returns None for the single- and
    dual-(outcome)-alpha schemes, which do not key on partner identity."""
    if spec.n_alpha == "cong":
        cong = _congruence_map(data, partners)
        return {p: _CONG_TO_ALPHA[cong[p]] for p in partners}
    if spec.n_alpha == "type":
        typ = _partner_type_map(data, partners)
        return {p: f"alpha_{typ[p]}" for p in partners}
    return None


def _arrays(data):
    return (data["stm"].values,
            data["chose_high"].values.astype(int),
            data["return_bin"].values,
            data["low_amount"].values.astype(float),
            data["high_amount"].values.astype(float))


def _select_alpha(pd_, spec, r, akeys, p):
    """Learning rate for this update given the model's alpha scheme.
    akeys (from _alpha_key_map) handles the partner-static schemes (cong, type);
    otherwise alpha keys on the outcome (dual) or is shared (single)."""
    if akeys is not None:
        return pd_[akeys[p]]
    if spec.n_alpha == 2:
        return pd_["alpha_r"] if r == 1 else pd_["alpha_d"]
    return pd_["alpha"]


# ===========================================================================
# NLL (one engine for every non-null model)
# ===========================================================================
def nll_null(data):
    """M0: P(send high) = 0.5, no free parameters."""
    chose = data["chose_high"].values
    return -np.sum(chose * np.log(0.5) + (1 - chose) * np.log(0.5))


def nll_model(params, data, spec, q_init):
    pd_ = dict(zip(_param_names(spec), params))
    stm, chose, ret, lo, hi = _arrays(data)
    partners = np.unique(stm)
    Q        = {p: _resolve_q0(p, q_init) for p in partners}
    prev     = {p: None for p in partners}   # last choice (for phi)
    prev_ret = {p: None for p in partners}    # last observed outcome (for dual beta)
    akeys    = _alpha_key_map(spec, data, partners)  # partner -> alpha param (cong/type)

    nll = 0.0
    for i in range(len(stm)):
        p, ch, r = stm[i], chose[i], ret[i]
        beta = (pd_["beta_r"] if (prev_ret[p] is None or prev_ret[p] == 1) else pd_["beta_d"]) \
               if spec.dual_beta else pd_["beta"]
        phi   = pd_.get("phi", 0.0)
        stick = (1.0 if prev[p] == 1 else -1.0) if (spec.phi and prev[p] is not None) else 0.0

        pt = np.clip(choice_prob(Q[p], beta, stick, phi, spec.readout, lo[i], hi[i]),
                     1e-10, 1 - 1e-10)
        nll -= ch * np.log(pt) + (1 - ch) * np.log(1 - pt)
        if spec.phi:
            prev[p] = ch
        if np.isnan(r):
            continue
        Q[p] += _select_alpha(pd_, spec, r, akeys, p) * (r - Q[p])
        if spec.dual_beta:
            prev_ret[p] = r
    return nll


# ===========================================================================
# Fitting
# ===========================================================================
def get_q_init(sub_data, mode):
    if mode == "fixed":
        return 0.5
    return sub_data.groupby("stm")["stm_prior"].first().to_dict()


def fit_model(model_name, sub_data, n_starts=50):
    spec = MODELS[model_name]
    if spec is None:  # M0
        return {"params": [], "nll": nll_null(sub_data)}

    bounds = _param_bounds(spec)
    q_init = get_q_init(sub_data, spec.q_init)

    def wrapped_nll(params):
        return nll_model(params, sub_data, spec, q_init)

    best_params, best_nll = None, np.inf
    for _ in range(n_starts):
        init = [np.random.uniform(lo, hi) for lo, hi in bounds]
        try:
            res = minimize(wrapped_nll, init, bounds=bounds, method="L-BFGS-B")
            # Keep the best finite optimum (L-BFGS-B's success flag is unreliable).
            if np.isfinite(res.fun) and res.fun < best_nll:
                best_nll, best_params = res.fun, res.x
        except Exception:
            continue
    return {"params": best_params, "nll": best_nll}


# ===========================================================================
# Simulation (generative twin of the engine)
# ===========================================================================
def simulate_model(model_name, params, template, q_init):
    """Return simulated chose_high for the trial template. Partner identities,
    offered amounts, and returns come from the template (returns are exogenous);
    only the participant's CHOICES are model-generated.

    Feedback in simulation is available iff the simulated agent sends a positive
    amount AND the template carries an observed return for that trial."""
    spec = MODELS[model_name]
    stm, _, ret, lo, hi = _arrays(template)
    n = len(stm)
    if spec is None:  # M0
        return (np.random.rand(n) < 0.5).astype(int)

    pd_ = dict(zip(_param_names(spec), params))
    partners = np.unique(stm)
    Q        = {p: _resolve_q0(p, q_init) for p in partners}
    prev     = {p: None for p in partners}
    prev_ret = {p: None for p in partners}
    akeys    = _alpha_key_map(spec, template, partners)

    out = np.zeros(n, dtype=int)
    for i in range(n):
        p, r = stm[i], ret[i]
        beta = (pd_["beta_r"] if (prev_ret[p] is None or prev_ret[p] == 1) else pd_["beta_d"]) \
               if spec.dual_beta else pd_["beta"]
        phi   = pd_.get("phi", 0.0)
        stick = (1.0 if prev[p] == 1 else -1.0) if (spec.phi and prev[p] is not None) else 0.0

        pt = choice_prob(Q[p], beta, stick, phi, spec.readout, lo[i], hi[i])
        ch = 1 if np.random.rand() < pt else 0
        out[i] = ch
        if spec.phi:
            prev[p] = ch

        sent = hi[i] if ch == 1 else lo[i]
        if sent == 0 or np.isnan(r):
            continue
        Q[p] += _select_alpha(pd_, spec, r, akeys, p) * (r - Q[p])
        if spec.dual_beta:
            prev_ret[p] = r
    return out


def sample_true_params(model_name):
    """Plausible 'true' values for recovery (kept away from bound edges).
    Value-readout betas are sampled smaller (they scale a dollar value gap)."""
    spec = MODELS[model_name]
    vals = []
    for nm in _param_names(spec):
        if nm.startswith("alpha"):
            vals.append(np.random.uniform(0.05, 0.6))
        elif nm.startswith("beta"):
            vals.append(np.random.uniform(0.2, 2.0) if spec.readout == "value"
                        else np.random.uniform(1.0, 8.0))
        elif nm == "phi":
            vals.append(np.random.uniform(-1.0, 2.0))
    return np.array(vals)


# ===========================================================================
# Runs
# ===========================================================================
def run_empirical(df, out_dir, n_starts=50, models=None):
    """Fit each subject. `models` defaults to the full registry; pass a list to
    fit a subset (the 6-alpha 'type' models are the slowest)."""
    models = list(MODELS) if models is None else models
    subject_ids = df["participant_id"].unique()
    results = []
    for sub in subject_ids:
        print(f"Fitting subject {sub}...")
        sub_data = df[df["participant_id"] == sub].sort_values("trial").reset_index(drop=True)
        n = len(sub_data)
        row = {"participant_id": sub}
        for m in models:
            res = fit_model(m, sub_data, n_starts=n_starts)
            k, nll, params = n_params(m), res["nll"], res["params"]
            finite = np.isfinite(nll)
            row[f"nll_{m}"] = nll
            row[f"bic_{m}"] = k * np.log(n) + 2 * nll if finite else np.nan
            row[f"aic_{m}"] = 2 * k + 2 * nll if finite else np.nan
            if params is not None:
                for pname, pval in zip(param_names(m), params):
                    row[f"{pname}_{m}"] = pval
        results.append(row)

    rdf = pd.DataFrame(results)
    rdf.to_csv(os.path.join(out_dir, "rl_model_results.csv"), index=False)
    print("Saved rl_model_results.csv")

    bic_cols = [f"bic_{m}" for m in models]
    bic_means = rdf[bic_cols].mean().sort_values()
    print("\nMean BIC by model:\n", bic_means)
    bic_means.to_csv(os.path.join(out_dir, "bic_means.txt"))
    return rdf


def run_recovery(df, out_dir,
                 gen_models=RECOVERY_GEN_MODELS, fit_models=RECOVERY_FIT_MODELS,
                 n_iter=RECOVERY_N_ITER, n_starts=RECOVERY_N_STARTS):
    # None -> all registered models (parameter recovery then covers everything).
    gen_models = list(MODELS) if gen_models is None else gen_models
    fit_models = list(MODELS) if fit_models is None else fit_models

    subject_ids = df["participant_id"].unique()
    templates = [df[df["participant_id"] == s].sort_values("trial").reset_index(drop=True)
                 for s in subject_ids]
    confusion = {g: {f: 0 for f in fit_models} for g in gen_models}
    p_true = {m: [] for m in gen_models}
    p_rec  = {m: [] for m in gen_models}

    # Each iteration fits the confusion set plus the generating model (so every
    # generating model gets parameter recovery even if it is not in fit_models).
    total = n_iter * sum(len(set(fit_models) | {g}) for g in gen_models)
    mode = "param-only" if not fit_models else f"{len(fit_models)}-model confusion + param recovery"
    print(f"Recovery [{mode}]: {len(gen_models)} gen x {n_iter} iter "
          f"= ~{total} model fits (n_starts={n_starts} each). This can take a while.\n")

    for g in gen_models:
        gmode = MODELS[g].q_init if MODELS[g] is not None else "fixed"
        for it in range(n_iter):
            template = templates[np.random.randint(len(templates))]
            true_p   = sample_true_params(g) if MODELS[g] is not None else np.array([])
            q0       = get_q_init(template, gmode)
            sim_df   = template.copy()
            sim_df["chose_high"] = simulate_model(g, true_p, template, q0)

            # Fit every model needed this iteration exactly once.
            res_by_model = {f: fit_model(f, sim_df, n_starts=n_starts)
                            for f in (set(fit_models) | {g})}

            # Model recovery: best BIC among the confusion fit set (if any).
            if fit_models:
                best_model, best_bic = None, np.inf
                for f in fit_models:
                    nll = res_by_model[f]["nll"]
                    bic = n_params(f) * np.log(len(sim_df)) + 2 * nll if np.isfinite(nll) else np.inf
                    if bic < best_bic:
                        best_bic, best_model = bic, f
                confusion[g][best_model] += 1

            # Parameter recovery: g fit to its own data (always available).
            res_g = res_by_model[g]
            if len(true_p) > 0 and res_g["params"] is not None:
                p_true[g].append(true_p)
                p_rec[g].append(np.asarray(res_g["params"]))

            tag = best_model if fit_models else "(param-only)"
            print(f"  gen={g:<10} iter={it+1}/{n_iter}  ->  best={tag}")

    # Model-recovery confusion matrix (rows = generating, cols = best-fitting)
    if fit_models:
        conf = pd.DataFrame(confusion).T.reindex(index=gen_models, columns=fit_models).fillna(0)
        conf_prop = conf.div(conf.sum(axis=1), axis=0)
        print("\n=== Model-recovery confusion matrix (row-normalized) ===")
        print(conf_prop.round(2))
        conf_prop.to_csv(os.path.join(out_dir, "recovery_confusion.csv"))
    else:
        conf_prop = None
        print("\n(param-only recovery: confusion matrix skipped)")

    # Parameter recovery for every generating model (true vs. recovered)
    print("\n=== Parameter recovery (Pearson r, true vs. recovered) ===")
    rec_rows = []
    for m in gen_models:
        if len(p_true[m]) > 2:
            T, R = np.vstack(p_true[m]), np.vstack(p_rec[m])
            for j, nm in enumerate(param_names(m)):
                # corrcoef is undefined if either side has no variance (e.g. a
                # parameter that always pins to a bound) -- report NaN cleanly.
                if np.std(T[:, j]) == 0 or np.std(R[:, j]) == 0:
                    r = np.nan
                else:
                    r = np.corrcoef(T[:, j], R[:, j])[0, 1]
                rec_rows.append({"model": m, "param": nm, "r": r, "n": len(T)})
                print(f"  {m:<10} {nm:<10} r = {r:.2f}")
    pd.DataFrame(rec_rows).to_csv(os.path.join(out_dir, "recovery_parameters.csv"), index=False)
    return conf_prop


# ===========================================================================
# Entry point
# ===========================================================================

DATA_PATH = "/Users/melanieruiz/Desktop/tg-analyses_updated/NOCF/NOCF_master.csv"
OUT_DIR   = "/Users/melanieruiz/Desktop/tg-analyses_updated"

RUN_EMPIRICAL = True
RUN_RECOVERY  = True
RECOVERY_PARAM_ONLY = True   # True = fast (param recovery only); False = full confusion matrix

if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    df = load_data(DATA_PATH)

    if RUN_EMPIRICAL:
        run_empirical(df, OUT_DIR, n_starts=50)
    if RUN_RECOVERY:
        run_recovery(df, OUT_DIR,
                     fit_models=[] if RECOVERY_PARAM_ONLY else RECOVERY_FIT_MODELS,
                     n_iter=RECOVERY_N_ITER, n_starts=RECOVERY_N_STARTS)
    print("\nDone.")