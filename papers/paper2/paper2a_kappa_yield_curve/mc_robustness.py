#!/usr/bin/env python3
"""
mc_robustness.py — Monte Carlo CIR robustness check for Paper 2A.

Simulates 10,000 forward paths under the GMM-estimated (α, κ̄, ν) for each
of the 7 countries and checks whether the observed κ̂ series lies within the
5th/95th percentile bands.

Output: results/figures/fig6_mc_bands.pdf
        results/mc_coverage.csv   (coverage rates, for LaTeX text)
"""

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from pathlib import Path

# ── GMM parameter estimates (Table 6) ─────────────────────────────────────
CIR_PARAMS = {
    "UAE":          dict(alpha=0.803, kbar=0.01630, nu=0.046),
    "Bahrain":      dict(alpha=0.668, kbar=0.08096, nu=0.069),
    "Indonesia":    dict(alpha=0.632, kbar=0.04072, nu=0.055),
    "Kuwait":       dict(alpha=0.925, kbar=0.01686, nu=0.049),
    "Malaysia":     dict(alpha=0.762, kbar=0.02453, nu=0.043),
    "Qatar":        dict(alpha=0.684, kbar=0.01981, nu=0.050),
    "Saudi Arabia": dict(alpha=0.718, kbar=0.02409, nu=0.065),
}

COUNTRY_CODE = {
    "UAE": "AE", "Bahrain": "BH", "Indonesia": "ID",
    "Kuwait": "KW", "Malaysia": "MY", "Qatar": "QA", "Saudi Arabia": "SA",
}

N_PATHS = 10_000
DELTA   = 0.60      # recovery rate used in κ extraction
DT      = 1 / 12   # monthly step
SEED    = 42


# ── Simulation ─────────────────────────────────────────────────────────────
def simulate_cir(alpha, kbar, nu, kappa0, T, n_paths, dt, rng):
    """
    Euler-Maruyama discretisation of dκ = α(κ̄−κ)dt + ν√κ dW.
    Returns array of shape (n_paths, T); paths floored at 0.
    """
    paths = np.zeros((n_paths, T))
    paths[:, 0] = kappa0
    sqrt_dt = np.sqrt(dt)
    for t in range(1, T):
        k = paths[:, t - 1]
        eps = rng.standard_normal(n_paths)
        drift = alpha * (kbar - k) * dt
        diffusion = nu * np.sqrt(np.maximum(k, 0.0)) * sqrt_dt * eps
        paths[:, t] = np.maximum(k + drift + diffusion, 0.0)
    return paths


# ── Data helpers ───────────────────────────────────────────────────────────
def observed_kappa(df, country_code):
    """
    Monthly cross-maturity median κ̂ for one country.
    κ̂ = spread_bps / (10,000 × (1 − δ))
    """
    sub = df[df["country"] == country_code].copy()
    sub["kappa_hat"] = sub["spread_bps"] / (10_000 * (1 - DELTA))
    monthly = (
        sub.groupby("obs_date")["kappa_hat"]
        .median()
        .reset_index()
        .sort_values("obs_date")
    )
    return monthly


# ── Main ───────────────────────────────────────────────────────────────────
def main():
    rng = np.random.default_rng(SEED)

    here     = Path(__file__).parent
    data_dir = here / "data"
    out_dir  = here / "results" / "figures"
    csv_dir  = here / "results"
    out_dir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(data_dir / "sukuk_panel.csv", parse_dates=["obs_date"])

    # ── Figure layout: 3 × 3 grid, bottom-right 2 cells hidden ─────────────
    fig, axes = plt.subplots(3, 3, figsize=(13, 9))
    axes_flat = axes.flatten()

    records = []

    for idx, (country, params) in enumerate(CIR_PARAMS.items()):
        code  = COUNTRY_CODE[country]
        obs   = observed_kappa(df, code)
        dates = pd.to_datetime(obs["obs_date"].values)
        kobs  = obs["kappa_hat"].values
        T     = len(kobs)

        paths = simulate_cir(
            alpha   = params["alpha"],
            kbar    = params["kbar"],
            nu      = params["nu"],
            kappa0  = kobs[0],
            T       = T,
            n_paths = N_PATHS,
            dt      = DT,
            rng     = rng,
        )

        p5  = np.percentile(paths,  5, axis=0)
        p25 = np.percentile(paths, 25, axis=0)
        p50 = np.percentile(paths, 50, axis=0)
        p75 = np.percentile(paths, 75, axis=0)
        p95 = np.percentile(paths, 95, axis=0)

        inside_90 = int(np.sum((kobs >= p5)  & (kobs <= p95)))
        inside_50 = int(np.sum((kobs >= p25) & (kobs <= p75)))
        cov90 = inside_90 / T
        cov50 = inside_50 / T

        records.append(dict(
            country   = country,
            T         = T,
            inside_90 = inside_90,
            inside_50 = inside_50,
            cov90     = cov90,
            cov50     = cov50,
        ))

        # ── Plot ─────────────────────────────────────────────────────────────
        ax = axes_flat[idx]
        kpct  = kobs  * 100
        p5p   = p5   * 100
        p25p  = p25  * 100
        p50p  = p50  * 100
        p75p  = p75  * 100
        p95p  = p95  * 100

        ax.fill_between(dates, p5p, p95p,
                        alpha=0.18, color="steelblue",
                        label="5–95th pct." if idx == 0 else "_")
        ax.fill_between(dates, p25p, p75p,
                        alpha=0.32, color="steelblue",
                        label="25–75th pct." if idx == 0 else "_")
        ax.plot(dates, p50p, "--", color="steelblue", lw=1.0,
                label="Median path" if idx == 0 else "_")
        ax.plot(dates, kpct, "-", color="black", lw=1.5,
                label=r"Observed $\hat{\kappa}$" if idx == 0 else "_")

        ax.set_title(
            rf"{country}   (cov.$_{{90}}$={cov90:.0%})",
            fontsize=8.5,
        )
        ax.xaxis.set_major_locator(mdates.YearLocator(3))
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
        ax.tick_params(labelsize=7)
        ax.set_ylabel(r"$\hat{\kappa}$ (%)", fontsize=8)
        ax.yaxis.set_major_formatter(
            plt.FuncFormatter(lambda v, _: f"{v:.1f}")
        )

    # Hide unused cells
    for j in range(7, 9):
        axes_flat[j].set_visible(False)

    # Shared legend in bottom-right area
    handles, labels = axes_flat[0].get_legend_handles_labels()
    fig.legend(
        handles, labels,
        loc="lower right",
        bbox_to_anchor=(0.97, 0.05),
        fontsize=8,
        framealpha=0.9,
    )

    fig.suptitle(
        r"Monte Carlo CIR Bands vs.\ Observed $\hat{\kappa}$"
        "\n(10,000 paths, Euler–Maruyama, $\\Delta t = 1/12$)",
        fontsize=10.5,
    )
    plt.tight_layout(rect=[0, 0, 1, 0.97])

    out_path = out_dir / "fig6_mc_bands.pdf"
    plt.savefig(out_path, dpi=180, bbox_inches="tight")
    plt.close()
    print(f"Saved: {out_path}")

    # ── Coverage summary ─────────────────────────────────────────────────────
    cov_df = pd.DataFrame(records)
    cov_df.to_csv(csv_dir / "mc_coverage.csv", index=False)

    print("\nCoverage rates (obs κ̂ inside simulated band):")
    print(f"  {'Country':<15}  {'T':>4}  {'90% band':>9}  {'50% band':>9}")
    print("  " + "-" * 43)
    for r in records:
        print(
            f"  {r['country']:<15}  {r['T']:>4}  "
            f"{r['cov90']:>8.1%}  {r['cov50']:>8.1%}"
        )
    mean_cov90 = np.mean([r["cov90"] for r in records])
    print(f"\n  Mean 90%-band coverage: {mean_cov90:.1%}")

    return cov_df


if __name__ == "__main__":
    main()
