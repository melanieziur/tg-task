#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Created on Mon Sep 14 09:00:40 2026

@author: melanieruiz
"""

import matplotlib.pyplot as plt

# read: first col = model name, second col = BIC; skip the ",0" header
models, bic = [], []
with open("/Users/melanieruiz/Desktop/tg-analyses_updated/bic_means.txt") as f:
    next(f)  # skip header
    for line in f:
        name, val = line.strip().split(",")
        models.append(name.replace("bic_", ""))
        bic.append(float(val))

# sort best (lowest BIC) to worst, compute delta from best
order = sorted(range(len(bic)), key=lambda i: bic[i])
models = [models[i] for i in order]
bic = [bic[i] for i in order]
delta = [b - bic[0] for b in bic]

fig, ax = plt.subplots(figsize=(6, 8))
colors = ["#c0392b"] + ["#4a6fa5"] * (len(delta) - 1)  # highlight best
ax.barh(models, delta, color=colors)
ax.invert_yaxis()               # best at top
ax.set_xlabel("ΔBIC (relative to best model)")
ax.axvline(2, ls="--", c="gray", lw=0.8)   # ΔBIC ~2-6 = positive evidence
ax.axvline(10, ls="--", c="gray", lw=0.8)  # ΔBIC >10 = strong
fig.tight_layout()
fig.savefig("/Users/melanieruiz/Desktop/tg-analyses_updated/bic_figure.png", dpi=300)

import matplotlib.pyplot as plt
from matplotlib.patches import Patch

models, bic = [], []
with open("/Users/melanieruiz/Desktop/tg-analyses_updated/bic_means.txt") as f:
    next(f)
    for line in f:
        name, val = line.strip().split(",")
        models.append(name.replace("bic_", ""))
        bic.append(float(val))

order = sorted(range(len(bic)), key=lambda i: bic[i])
models = [models[i] for i in order]
bic    = [bic[i]    for i in order]
best   = bic[0]

# evidence tiers still defined on delta, but we color the raw points by them
tiers = [
    (0,  2,  "#2a7f62", "Best / negligible (Δ<2)"),
    (2,  6,  "#6aa84f", "Positive (2–6)"),
    (6,  10, "#e0a83b", "Strong (6–10)"),
    (10, 1e9,"#c0503f", "Very strong (>10)"),
]
def tier_color(d):
    for lo, hi, c, _ in tiers:
        if lo <= d < hi:
            return c
    return tiers[-1][2]
colors = [tier_color(b - best) for b in bic]

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 11})
fig, ax = plt.subplots(figsize=(7.5, 9))
y = range(len(models))

# stems from the best-BIC reference line to each point
for yi, b, c in zip(y, bic, colors):
    ax.plot([best, b], [yi, yi], color=c, lw=2, zorder=2, alpha=0.6)
ax.scatter(bic, y, color=colors, s=70, zorder=3, edgecolor="white", linewidth=0.8)

ax.axvline(best, ls="--", c="#2a7f62", lw=1, zorder=1)
ax.text(best, -0.9, f"best = {best:.1f}", color="#2a7f62", fontsize=9,
        ha="center", va="bottom")

for yi, b in zip(y, bic):
    ax.text(b + 0.4, yi, f"{b:.1f}", va="center", ha="left", fontsize=8.5, color="#333")

ax.set_yticks(list(y)); ax.set_yticklabels(models)
ax.invert_yaxis()
ax.set_xlabel("BIC (raw mean)", fontsize=12)
ax.set_xlim(best - 2, max(bic) + 4)   # truncated: honest for points, not bars
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.tick_params(length=0)
ax.grid(axis="x", color="#eee", zorder=0); ax.set_axisbelow(True)

legend = [Patch(facecolor=c, label=lab) for _, _, c, lab in tiers]
ax.legend(handles=legend, title="Evidence vs. best (Kass & Raftery)",
          loc="center right", frameon=False, fontsize=9, title_fontsize=9)

fig.tight_layout()
fig.savefig("/Users/melanieruiz/Desktop/tg-analyses_updated/bic_figure_raw.png", dpi=300, bbox_inches="tight")
print("saved")
saved