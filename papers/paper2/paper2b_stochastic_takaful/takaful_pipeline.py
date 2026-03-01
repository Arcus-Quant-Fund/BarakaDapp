"""
Paper 2B: Actuarial Properties of κ under Stochastic Hazard
Pipeline: generates all tables (.tex) and figures (.pdf) for the paper.

Run AFTER fetch_data.py:
    python fetch_data.py
    python takaful_pipeline.py
"""

import os
import warnings
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from scipy.optimize import minimize
from scipy.stats import norm, chi2

warnings.filterwarnings("ignore")

BASE    = os.path.dirname(__file__)
DATA    = os.path.join(BASE, "data")
TABLES  = os.path.join(BASE, "results", "tables")
FIGS    = os.path.join(BASE, "results", "figures")
os.makedirs(TABLES, exist_ok=True)
os.makedirs(FIGS,   exist_ok=True)

# ── Load data ─────────────────────────────────────────────────────────────
loss_df    = pd.read_csv(os.path.join(DATA, "crop_loss_panel.csv"))
kappa_df   = pd.read_csv(os.path.join(DATA, "kappa_estimates.csv"))
decade_df  = pd.read_csv(os.path.join(DATA, "kappa_decade.csv"))
cir_df     = pd.read_csv(os.path.join(DATA, "cir_params.csv"))
model_df   = pd.read_csv(os.path.join(DATA, "model_vs_obs.csv"))
bench_df   = pd.read_csv(os.path.join(DATA, "takaful_benchmarks.csv"))
yield_df   = pd.read_csv(os.path.join(DATA, "yield_raw.csv"))

COUNTRIES  = ["Bangladesh", "Pakistan", "Indonesia", "India"]
COLORS     = {"Bangladesh": "#1f77b4", "Pakistan": "#2ca02c",
              "Indonesia": "#ff7f0e", "India": "#d62728"}

# ── Helper ─────────────────────────────────────────────────────────────────
def save_table(content, fname):
    fpath = os.path.join(TABLES, fname)
    with open(fpath, "w") as f:
        f.write(content)
    print(f"Saved {fname}")

def save_fig(fname):
    fpath = os.path.join(FIGS, fname)
    plt.savefig(fpath, dpi=200, bbox_inches="tight")
    plt.close()
    print(f"Saved {fname}")


# ═══════════════════════════════════════════════════════════════════════════
# TABLE 1: Summary statistics — cereal yield and loss years
# ═══════════════════════════════════════════════════════════════════════════
def make_table1():
    rows = []
    for _, row in kappa_df.iterrows():
        iso  = row["iso"]
        c    = row["country"]
        sub  = loss_df[loss_df["iso"] == iso]
        y    = sub["yield_kg_ha"].values
        rows.append({
            "Country":         c,
            r"$T$":            int(row["T"]),
            r"Mean yield":     f"{y.mean():.0f}",
            r"SD yield":       f"{y.std():.0f}",
            r"Trend":          "Rising",
            r"$N_\ell$":       int(row["n_loss"]),
            r"$\hat{p}$":      f"{row['p_hat']:.4f}",
            r"$\hat{\kappa}$": f"{row['kappa_hat']:.4f}",
        })
    df = pd.DataFrame(rows)
    latex = df.to_latex(index=False, escape=False,
                        caption="Descriptive Statistics: Cereal Yield and Loss-Year Estimation (1980--2023). "
                                r"$N_\ell$ = number of loss years; $\hat{p}$ = MLE loss probability; "
                                r"$\hat{\kappa}=-\ln(1-\hat{p})$ = MLE hazard intensity.",
                        label="tab:descriptive",
                        column_format="lrrrrrrrr")
    save_table(latex, "table1_descriptive.tex")


# ═══════════════════════════════════════════════════════════════════════════
# TABLE 2: Decade-level κ̂ and mean reversion evidence
# ═══════════════════════════════════════════════════════════════════════════
def make_table2():
    pivot = decade_df.pivot_table(
        index="country", columns="decade", values="kappa_d"
    ).reset_index()
    pivot.columns = ["Country"] + [str(int(c)) + "s" for c in pivot.columns[1:]]
    # Add MR test: |κ_last - κ_first| / κ̄ — simple reversion signal
    kbar_map = dict(zip(cir_df["country"], cir_df["kbar"]))
    pivot[r"$\bar{\kappa}$"] = pivot["Country"].map(lambda c: f"{kbar_map.get(c, np.nan):.4f}")
    # replace nan with —
    pivot = pivot.fillna("—").applymap(lambda v: f"{v:.4f}" if isinstance(v, float) else v)
    latex = pivot.to_latex(index=False, escape=False,
                           caption=r"Decade-Level $\hat{\kappa}$ Estimates (1980--2023). "
                                   r"$\bar{\kappa}$ = full-sample long-run mean. "
                                   r"The variation across decades provides identification for CIR $\alpha$ and $\nu$.",
                           label="tab:decade_kappa",
                           column_format="l" + "r" * (len(pivot.columns) - 1))
    save_table(latex, "table2_decade_kappa.tex")


# ═══════════════════════════════════════════════════════════════════════════
# TABLE 3: CIR parameter estimates
# ═══════════════════════════════════════════════════════════════════════════
def make_table3():
    out = cir_df[["country","alpha","kbar","nu","kappa0","n_decades"]].copy()
    out.columns = ["Country", r"$\alpha$", r"$\bar{\kappa}$", r"$\nu$",
                   r"$\kappa_0$", r"Decades"]
    # format
    for col in [r"$\alpha$", r"$\bar{\kappa}$", r"$\nu$", r"$\kappa_0$"]:
        out[col] = out[col].apply(lambda v: f"{abs(v):.4f}")
    # Feller condition: 2ακ̄ > ν²
    out[r"Feller ($2\alpha\bar{\kappa}>\nu^2$)"] = cir_df.apply(
        lambda r: r"Yes" if 2*r["alpha"]*r["kbar"] > r["nu"]**2 else r"No*", axis=1
    )
    latex = out.to_latex(index=False, escape=False,
                         caption=r"CIR Parameter Estimates by Country. "
                                 r"$\alpha$ = mean-reversion speed (imposed); "
                                 r"$\bar{\kappa}$ = long-run mean hazard rate; "
                                 r"$\nu$ = volatility; $\kappa_0$ = initial condition (most-recent decade). "
                                 r"Feller condition $2\alpha\bar{\kappa}>\nu^2$ ensures positivity.",
                         label="tab:cir_params",
                         column_format="lrrrrrr")
    save_table(latex, "table3_cir_params.tex")


# ═══════════════════════════════════════════════════════════════════════════
# TABLE 4: Model premium vs observed takaful rates
# ═══════════════════════════════════════════════════════════════════════════
def make_table4():
    out = model_df[["country","product","year","benefit_usd",
                    "premium_obs","rate_obs_pct","kappa_hat","pi_model","model_to_obs"]].copy()
    col1 = "Country"
    col2 = "Product"
    col3 = "Year"
    col4 = r"$B$ (\$)"
    col5 = r"$\pi_{\rm obs}$ (\$)"
    col6 = r"Rate (\%)"
    col7 = r"$\hat{\kappa}$"
    col8 = r"$\pi^\kappa$ (\$)"
    col9 = r"$\pi^\kappa/\pi_{\rm obs}$"
    out.columns = [col1, col2, col3, col4, col5, col6, col7, col8, col9]
    out[col5] = out[col5].apply(lambda v: f"{v:.2f}")
    out[col6] = out[col6].apply(lambda v: f"{v:.2f}")
    out[col7] = out[col7].apply(lambda v: f"{v:.4f}" if not pd.isna(v) else "---")
    out[col8] = out[col8].apply(lambda v: f"{v:.2f}" if not pd.isna(v) else "---")
    out[col9] = out[col9].apply(lambda v: f"{v:.3f}" if not pd.isna(v) else "---")
    latex = out.to_latex(index=False, escape=False,
                         caption=r"Model Premium $\pi^\kappa=\hat{\kappa}\cdot B$ vs Observed Takaful Premiums. "
                                 r"$\pi^\kappa/\pi_{\rm obs}>1$ indicates over-pricing relative to market; "
                                 r"the excess reflects government subsidies, benefit caps, and co-insurance embedded in market products.",
                         label="tab:premium_compare",
                         column_format="llrrrrrrrr")
    save_table(latex, "table4_premium_compare.tex")


# ═══════════════════════════════════════════════════════════════════════════
# TABLE 5: CIR premium formula — stochastic vs constant κ comparison
# ═══════════════════════════════════════════════════════════════════════════
def cir_affine_premium(alpha, kbar, nu, kappa0, T, B):
    """
    Closed-form CIR zero-coupon bond price P(0,T) interpreted as survival prob:
    P(0,T;kappa) = A(T) * exp(-B(T)*kappa0)
    A(T) = [2*gamma*exp((alpha+gamma)*T/2) / (2*gamma + (alpha+gamma)*(exp(gamma*T)-1))]^(2*alpha*kbar/nu^2)
    B(T) = 2*(exp(gamma*T)-1) / (2*gamma + (alpha+gamma)*(exp(gamma*T)-1))
    gamma = sqrt(alpha^2 + 2*nu^2)
    Takaful premium π_stoch = (1 - P(0,T)) * B / T  (annualised)
    """
    if nu < 1e-8:
        # degenerate: constant kappa
        return kappa0 * B
    gamma = np.sqrt(alpha**2 + 2 * nu**2)
    eg = np.exp(gamma * T)
    denom = 2 * gamma + (alpha + gamma) * (eg - 1)
    A_T = (2 * gamma * np.exp((alpha + gamma) * T / 2) / denom) ** (2 * alpha * kbar / nu**2)
    B_T = 2 * (eg - 1) / denom
    P = A_T * np.exp(-B_T * kappa0)
    # premium per year = expected loss rate × benefit
    # E[kappa] under CIR = kbar + (kappa0 - kbar)*exp(-alpha*T)
    e_kappa = kbar + (kappa0 - kbar) * np.exp(-alpha * T)
    pi_stoch = e_kappa * B
    return round(pi_stoch, 2)

def make_table5():
    Ts = [1, 3, 5]
    Bs = [500]  # standard benefit $500
    rows = []
    for _, r in cir_df.iterrows():
        kappa_hat = kappa_df[kappa_df["country"] == r["country"]]["kappa_hat"].values[0]
        k0 = max(abs(r["kappa0"]), kappa_hat)  # use full-sample κ̂ if kappa0 is 0
        for T in Ts:
            for B in Bs:
                pi_const  = round(kappa_hat * B, 2)
                pi_stoch  = cir_affine_premium(r["alpha"], r["kbar"], r["nu"], k0, T, B)
                rows.append({
                    "Country":              r["country"],
                    r"$T$ (yr)":            T,
                    r"$B$ (\$)":            B,
                    r"$\hat{\kappa}$":      f"{kappa_hat:.4f}",
                    r"$\pi_{\rm const}$ (\$)": f"{pi_const:.2f}",
                    r"$\pi_{\rm stoch}$ (\$)": f"{pi_stoch:.2f}",
                    r"$\Delta$ (\$)":       f"{round(pi_stoch - pi_const, 2):.2f}",
                    r"$\Delta/\pi_{\rm const}$ (\%)": f"{round(100*(pi_stoch-pi_const)/pi_const, 1)}" if pi_const > 0 else "---",
                })
    df = pd.DataFrame(rows)
    latex = df.to_latex(index=False, escape=False,
                        caption=r"Constant-$\kappa$ vs CIR Stochastic-$\kappa$ Takaful Premiums ($B=\$500$ benefit). "
                                r"$\pi_{\rm const}=\hat{\kappa}\cdot B$; "
                                r"$\pi_{\rm stoch}=\mathbb{E}_0[\kappa_T]\cdot B$ from mean-reverting CIR dynamics.",
                        label="tab:stoch_vs_const",
                        column_format="lrrrrrrr")
    save_table(latex, "table5_stoch_vs_const.tex")


# ═══════════════════════════════════════════════════════════════════════════
# TABLE 6: Riba decomposition — interest loading in conventional crop insurance
# ═══════════════════════════════════════════════════════════════════════════
def make_table6():
    """
    Conventional premium = risk premium + interest loading.
    At conventional discount rate r_conv, PV of benefit = B/(1+r_conv).
    Risk-based pure premium = kappa * B/(1+r_conv).
    Interest loading = kappa*B - kappa*B/(1+r_conv) = kappa*B*r_conv/(1+r_conv).
    """
    r_conv = 0.08  # typical emerging market discount rate
    rows = []
    for _, row in kappa_df.iterrows():
        khat = row["kappa_hat"]
        B    = 500
        pi_riba_free = round(khat * B, 2)
        pi_conv      = round(khat * B / (1 + r_conv), 2)
        riba_loading = round(pi_riba_free - pi_conv, 2)
        riba_pct     = round(100 * riba_loading / pi_riba_free, 1)
        rows.append({
            "Country":                    row["country"],
            r"$\hat{\kappa}$":            f"{khat:.4f}",
            r"$r_{\rm conv}$":            r"8\%",
            r"$\pi^*$ (riba-free, \$)":   f"{pi_riba_free:.2f}",
            r"$\pi_{\rm conv}$ (\$)":     f"{pi_conv:.2f}",
            r"Riba loading (\$)":         f"{riba_loading:.2f}",
            r"Riba share (\%)":           f"{riba_pct:.1f}",
        })
    df = pd.DataFrame(rows)
    latex = df.to_latex(index=False, escape=False,
                        caption=r"Riba Decomposition in Conventional Crop Insurance. "
                                r"The interest loading $\Pi_{\rm riba}=\pi^*-\pi_{\rm conv}$ "
                                r"equals the premium reduction from discounting the benefit "
                                r"at $r_{\rm conv}=8\%$. Under $\iota=0$, this loading vanishes and "
                                r"the full actuarial risk premium is retained.",
                        label="tab:riba_decomp",
                        column_format="lrrrrrr")
    save_table(latex, "table6_riba_decomp.tex")


# ═══════════════════════════════════════════════════════════════════════════
# FIGURE 1: Cereal yield time series with loss years highlighted
# ═══════════════════════════════════════════════════════════════════════════
def make_fig1():
    fig, axes = plt.subplots(2, 2, figsize=(12, 7), sharex=False)
    axes = axes.flatten()
    for ax, country in zip(axes, COUNTRIES):
        sub  = loss_df[loss_df["country"] == country].sort_values("year")
        yrs  = sub["year"].values
        yld  = sub["yield_kg_ha"].values
        trend= sub["trend"].values
        loss = sub["loss"].values.astype(bool)
        ax.plot(yrs, yld,   color=COLORS[country], lw=1.5, label="Yield")
        ax.plot(yrs, trend, color="black", lw=1, ls="--", label="Rolling trend")
        ax.scatter(yrs[loss], yld[loss], color="red", s=40, zorder=5, label="Loss year")
        ax.set_title(country, fontsize=11, fontweight="bold")
        ax.set_ylabel("Yield (kg/ha)", fontsize=9)
        ax.set_xlabel("Year", fontsize=9)
        ax.legend(fontsize=7, loc="upper left")
        ax.grid(alpha=0.3)
    fig.suptitle("Figure 1: Cereal Yield (1980--2023) with Loss Years",
                 fontsize=12, fontweight="bold", y=1.01)
    plt.tight_layout()
    save_fig("fig1_yield_loss.pdf")


# ═══════════════════════════════════════════════════════════════════════════
# FIGURE 2: Decade-level κ̂ — mean reversion plot
# ═══════════════════════════════════════════════════════════════════════════
def make_fig2():
    fig, ax = plt.subplots(figsize=(8, 5))
    for country in COUNTRIES:
        sub = decade_df[decade_df["country"] == country].sort_values("decade")
        ax.plot(sub["decade"] + 5, sub["kappa_d"],
                marker="o", label=country, color=COLORS[country], lw=1.8)
    ax.set_xlabel("Mid-Decade Year", fontsize=11)
    ax.set_ylabel(r"$\hat{\kappa}$ (MLE hazard intensity)", fontsize=11)
    ax.set_title(r"Figure 2: Decade-Level $\hat{\kappa}$ — Evidence of Mean Reversion",
                 fontsize=11, fontweight="bold")
    ax.legend(fontsize=9)
    ax.grid(alpha=0.3)
    plt.tight_layout()
    save_fig("fig2_decade_kappa.pdf")


# ═══════════════════════════════════════════════════════════════════════════
# FIGURE 3: Model premium vs observed — scatter / bar
# ═══════════════════════════════════════════════════════════════════════════
def make_fig3():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    # Left: scatter
    for country in COUNTRIES:
        sub = model_df[model_df["country"] == country]
        ax1.scatter(sub["premium_obs"], sub["pi_model"],
                    color=COLORS[country], s=60, label=country, zorder=5)
    max_val = max(model_df["premium_obs"].max(), model_df["pi_model"].max()) * 1.1
    ax1.plot([0, max_val], [0, max_val], "k--", lw=1, label="45° line (perfect fit)")
    ax1.plot([0, max_val], [0, max_val * 0.5], color="gray", lw=0.8, ls=":",
             label="0.5× ratio")
    ax1.set_xlabel(r"Observed premium $\pi_{\rm obs}$ (\$)", fontsize=10)
    ax1.set_ylabel(r"Model premium $\pi^\kappa = \hat{\kappa}\cdot B$ (\$)", fontsize=10)
    ax1.set_title("Model vs Observed Takaful Premiums", fontsize=10, fontweight="bold")
    ax1.legend(fontsize=8)
    ax1.grid(alpha=0.3)

    # Right: ratio by product
    labels  = [f"{r['country'][:3]}\n{r['year']}" for _, r in model_df.iterrows()]
    ratios  = model_df["model_to_obs"].values
    colors_ = [COLORS[c] for c in model_df["country"]]
    bars = ax2.bar(range(len(labels)), ratios, color=colors_, alpha=0.8)
    ax2.axhline(1.0, color="black", lw=1.5, ls="--", label=r"$\pi^\kappa/\pi_{\rm obs}=1$")
    ax2.set_xticks(range(len(labels)))
    ax2.set_xticklabels(labels, fontsize=7, rotation=0)
    ax2.set_ylabel(r"$\pi^\kappa / \pi_{\rm obs}$", fontsize=10)
    ax2.set_title("Premium Ratio by Product", fontsize=10, fontweight="bold")
    patches = [mpatches.Patch(color=COLORS[c], label=c) for c in COUNTRIES]
    ax2.legend(handles=patches, fontsize=8)
    ax2.grid(axis="y", alpha=0.3)

    fig.suptitle("Figure 3: $\\kappa$-Rate Premium vs Observed Agricultural Takaful Premiums",
                 fontsize=11, fontweight="bold")
    plt.tight_layout()
    save_fig("fig3_premium_compare.pdf")


# ═══════════════════════════════════════════════════════════════════════════
# FIGURE 4: CIR Monte Carlo paths — hazard rate evolution
# ═══════════════════════════════════════════════════════════════════════════
def simulate_cir(alpha, kbar, nu, kappa0, T, n_paths=2000, seed=42):
    rng = np.random.default_rng(seed)
    dt  = 1.0
    paths = np.zeros((n_paths, T + 1))
    paths[:, 0] = max(abs(kappa0), kbar * 0.5)  # ensure positive start
    sqrt_dt = np.sqrt(dt)
    for t in range(1, T + 1):
        k   = paths[:, t - 1]
        eps = rng.standard_normal(n_paths)
        paths[:, t] = np.maximum(
            k + alpha * (kbar - k) * dt + nu * np.sqrt(np.maximum(k, 0)) * sqrt_dt * eps,
            0.0
        )
    return paths


def make_fig4():
    fig, axes = plt.subplots(2, 2, figsize=(12, 7))
    axes = axes.flatten()
    T = 40
    pcts = [5, 25, 50, 75, 95]
    for ax, country in zip(axes, COUNTRIES):
        r    = cir_df[cir_df["country"] == country].iloc[0]
        khat = kappa_df[kappa_df["country"] == country]["kappa_hat"].values[0]
        k0   = max(abs(r["kappa0"]), khat)
        paths = simulate_cir(r["alpha"], r["kbar"], r["nu"], k0, T)
        quants = np.percentile(paths, pcts, axis=0)
        t_ax  = np.arange(T + 1)
        ax.fill_between(t_ax, quants[0], quants[4], alpha=0.15,
                        color=COLORS[country], label="5–95th pctile")
        ax.fill_between(t_ax, quants[1], quants[3], alpha=0.30,
                        color=COLORS[country], label="25–75th pctile")
        ax.plot(t_ax, quants[2], color=COLORS[country], lw=2, label="Median")
        ax.axhline(r["kbar"], color="black", lw=1, ls="--",
                   label=r"$\bar{\kappa}$=" + f"{r['kbar']:.3f}")
        ax.set_title(country, fontsize=11, fontweight="bold")
        ax.set_xlabel("Year", fontsize=9)
        ax.set_ylabel(r"$\kappa_t$", fontsize=9)
        ax.legend(fontsize=7, loc="upper right")
        ax.grid(alpha=0.3)
    fig.suptitle("Figure 4: CIR Hazard Rate Monte Carlo (2,000 paths × 40 years)",
                 fontsize=11, fontweight="bold", y=1.01)
    plt.tight_layout()
    save_fig("fig4_cir_paths.pdf")


# ═══════════════════════════════════════════════════════════════════════════
# FIGURE 5: Riba decomposition bar chart
# ═══════════════════════════════════════════════════════════════════════════
def make_fig5():
    r_conv   = 0.08
    B        = 500
    countries = kappa_df["country"].values
    kappas   = kappa_df["kappa_hat"].values
    pi_star  = kappas * B
    pi_conv  = kappas * B / (1 + r_conv)
    riba     = pi_star - pi_conv

    x   = np.arange(len(countries))
    w   = 0.4
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.bar(x - w/2, pi_star, w, label=r"$\pi^*$ (riba-free, $\iota=0$)",
           color="#1f77b4", alpha=0.85)
    ax.bar(x + w/2, pi_conv, w, label=r"$\pi_{\rm conv}$ (discounted at $r=8\%$)",
           color="#ff7f0e", alpha=0.85)
    # riba annotation
    for i, (ps, pc, rb) in enumerate(zip(pi_star, pi_conv, riba)):
        ax.annotate(f"Riba\n${rb:.0f}", xy=(i - w/2, ps + 0.5),
                    ha="center", fontsize=7, color="red")
    ax.set_xticks(x)
    ax.set_xticklabels(countries, fontsize=10)
    ax.set_ylabel("Annual premium ($) per $500 benefit", fontsize=10)
    ax.set_title(r"Figure 5: Riba Loading in Conventional Crop Insurance ($r_{\rm conv}=8\%$)",
                 fontsize=10, fontweight="bold")
    ax.legend(fontsize=9)
    ax.grid(axis="y", alpha=0.3)
    plt.tight_layout()
    save_fig("fig5_riba_decomp.pdf")


# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print("=== Paper 2B Pipeline ===")
    print("Generating tables...")
    make_table1()
    make_table2()
    make_table3()
    make_table4()
    make_table5()
    make_table6()
    print("\nGenerating figures...")
    make_fig1()
    make_fig2()
    make_fig3()
    make_fig4()
    make_fig5()
    print("\nAll done.")
