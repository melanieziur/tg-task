#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Mon Sep 28 21:59:44 2026

@author: melanieruiz
"""

#!/usr/bin/env python3
"""
Poster figures for the trust-game RL fits.

Reads rl_model_results.csv (written by run_empirical) and saves, to OUT_DIR:
  model_comparison.png / .svg   winner + its one-change neighbors
  eq_prior, eq_update, eq_choice (.png / .svg)   equations for Panel C
Also prints summed dBIC, per-participant best-fit counts, and M6 parameter
summaries (fill these into Panel C).

Usage:  python make_poster_figs.py [results.csv] [out_dir]
"""
import os
import sys
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy.stats import wilcoxon

RESULTS = sys.argv[1] if len(sys.argv) > 1 else \
    "/Users/melanieruiz/Desktop/tg-analyses_updated/rl_model_results.csv"
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else \
    "/Users/melanieruiz/Desktop/tg-analyses_updated/poster_figs"

WINNER = "M6"
# Winner plus every model that differs from it in exactly one switch
# (prior, learning-rate scheme, perseveration, choice readout), plus the null.
# Each label says what changed relative to the winner.
SHOW = {
    "M6":       "Winning model",
    "M7b":      "+ choice perseveration",
    "M6v":      "Expected-value choice rule",
    "M2":       "Flat prior (Q₀ = 0.5)",
    "M5":       "One learning rate",
    "M_cong_S": "Learning rate by congruence",
    "M_type_S": "Learning rate by partner type",
    "M0":       "Chance (no learning)",
}

# Set FIG_SIZE to the size (inches) the chart will occupy on the printed poster
# so font sizes come out as real point sizes.
FIG_SIZE  = (11, 6)
FONT      = "DejaVu Sans"     # swap for your poster font if it's installed
BASE_PT   = 22
FG        = "white"            # text color on the dark poster
MUTED     = "#b9b9c9"
WIN_COLOR = "#9fb3f0"
BAR_COLOR = "#6d6d82"

plt.rcParams.update({
    "font.family": FONT, "font.size": BASE_PT, "text.color": FG,
    "axes.labelcolor": FG, "xtick.color": MUTED, "ytick.color": FG,
    "mathtext.fontset": "dejavusans",
    "svg.fonttype": "path",       # text saved as outlines so Canva can't swap fonts
})


def save(fig, name, tight=False):
    kw = {"bbox_inches": "tight", "pad_inches": 0.05} if tight else {}
    for ext in ("png", "svg"):
        fig.savefig(os.path.join(OUT_DIR, f"{name}.{ext}"), dpi=300, transparent=True, **kw)
    plt.close(fig)
    print(f"Saved {name}.png / .svg")


def model_comparison(df):
    cols = {f"bic_{m}": m for m in SHOW}
    missing = [c for c in cols if c not in df.columns]
    if missing:
        raise SystemExit(f"Not in results file: {missing}")
    bic = df[list(cols)].rename(columns=cols)

    ok = bic.notna().all(axis=1)
    if (~ok).any():
        print(f"Dropping {(~ok).sum()} participant(s) with a failed fit in a shown model")
    bic = bic[ok]

    dbic = (bic.sum() - bic[WINNER].sum()).sort_values()
    if dbic.min() < 0:
        print(f"WARNING: {dbic.idxmin()} beats {WINNER} on this subset")

    print(f"\nSummed dBIC vs {WINNER} (n = {len(bic)}):")
    print(dbic.round(1).to_string())
    print("\nParticipants best fit, among shown models:")
    print(bic.idxmin(axis=1).value_counts().reindex(dbic.index, fill_value=0).to_string())

    fig, ax = plt.subplots(figsize=FIG_SIZE)
    y = np.arange(len(dbic))
    ax.barh(y, dbic.values, height=0.65,
            color=[WIN_COLOR if m == WINNER else BAR_COLOR for m in dbic.index])
    ax.set_yticks(y)
    ax.set_yticklabels([SHOW[m] for m in dbic.index])
    ax.invert_yaxis()
    for lab, m in zip(ax.get_yticklabels(), dbic.index):
        if m == WINNER:
            lab.set_color(WIN_COLOR)
            lab.set_fontweight("bold")

    pad = dbic.max() * 0.015
    for yi, (m, v) in zip(y, dbic.items()):
        ax.text(v + pad, yi, "best" if m == WINNER else f"+{v:,.0f}", va="center",
                fontsize=BASE_PT * 0.8, color=WIN_COLOR if m == WINNER else MUTED)

    ax.set_xlim(0, dbic.max() * 1.18)
    ax.set_xlabel("ΔBIC vs. winning model\n(summed across participants; lower = better)",
                  color=MUTED, fontsize=BASE_PT * 0.75)
    ax.tick_params(axis="y", length=0)
    ax.tick_params(axis="x", labelsize=BASE_PT * 0.75)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(MUTED)
    fig.tight_layout()
    save(fig, "model_comparison")


EQUATIONS = {
    "eq_prior":  r"$Q_{p,0} = \mathrm{rating}_p\,/\,100$",
    "eq_update": r"$Q_{p,t+1} = Q_{p,t} + \alpha^{\pm}\,(r_t - Q_{p,t})$",
    "eq_choice": r"$P(\mathrm{high}) = \sigma(\beta\,(Q_{p,t} - 0.5))$",
}


def equations():
    for name, tex in EQUATIONS.items():
        fig = plt.figure(figsize=(6, 1))
        fig.text(0, 0.5, tex, fontsize=BASE_PT * 1.4, color=FG, va="center")
        save(fig, name, tight=True)


def winner_params(df):
    a_pos, a_neg, beta = (df[f"{p}_{WINNER}"] for p in ("alpha_r", "alpha_d", "beta"))
    print(f"\n{WINNER} fitted parameters:")
    for nm, s in [("alpha+ (after return)", a_pos), ("alpha- (after non-return)", a_neg),
                  ("beta", beta)]:
        q1, med, q3 = s.quantile([0.25, 0.5, 0.75])
        print(f"  {nm:<26} median {med:.2f}  IQR [{q1:.2f}, {q3:.2f}]")
    ok = a_pos.notna() & a_neg.notna()
    p = wilcoxon(a_neg[ok], a_pos[ok]).pvalue
    print(f"  alpha- vs alpha+: Wilcoxon p = {p:.3g}; "
          f"alpha- > alpha+ in {(a_neg[ok] > a_pos[ok]).sum()}/{ok.sum()} participants")


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    df = pd.read_csv(RESULTS)
    model_comparison(df)
    equations()
    winner_params(df)