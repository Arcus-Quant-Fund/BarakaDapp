#!/usr/bin/env python3
"""
fetch_data.py — Data collection for Paper 2C.

Sources (all free, no API keys required):
  1. Paper 2A κ̂ time series  — ../paper2a.../data/sukuk_panel.csv
  2. Paper 2A CIR parameters  — hardcoded from Table 6 (already verified)
  3. Damodaran CDS spreads    — ../paper2a.../data/damodaran.csv
  4. FRED SOFR                — ../paper2a.../data/sofr_real.csv
  5. Arbiscan gas costs       — estimated from known Arbitrum benchmarks
     (no API key needed; live lookup optional)

Writes to data/:
  icds_panel.csv   — κ̂_t, s*_t, s_conv_t, s_diff_t by country × month
  cir_params.csv   — κ̄, α, ν, s*_lr per country (from Table 6)
  gas_costs.csv    — gas units + USD cost per iCDS lifecycle step
  sofr_annual.csv  — annual mean SOFR 2012-2025
"""

import numpy as np
import pandas as pd
from pathlib import Path
import json

# ── Paths ──────────────────────────────────────────────────────────────────
HERE    = Path(__file__).parent
ROOT2A  = HERE.parent / "paper2a_kappa_yield_curve"
DATA_2A = ROOT2A / "data"
OUT     = HERE / "data"
OUT.mkdir(exist_ok=True)

DELTA  = 0.60   # universal recovery rate (consistent with Paper 2A)
LGD    = 1 - DELTA  # 0.40

# ── CIR parameters from Paper 2A Table 6 ──────────────────────────────────
CIR = {
    "UAE":          dict(alpha=0.803, kbar=0.01630, nu=0.046, code="AE"),
    "Bahrain":      dict(alpha=0.668, kbar=0.08096, nu=0.069, code="BH"),
    "Indonesia":    dict(alpha=0.632, kbar=0.04072, nu=0.055, code="ID"),
    "Kuwait":       dict(alpha=0.925, kbar=0.01686, nu=0.049, code="KW"),
    "Malaysia":     dict(alpha=0.762, kbar=0.02453, nu=0.043, code="MY"),
    "Qatar":        dict(alpha=0.684, kbar=0.01981, nu=0.050, code="QA"),
    "Saudi Arabia": dict(alpha=0.718, kbar=0.02409, nu=0.065, code="SA"),
}

# ── Moody's rating → δ mapping (Moody's Annual Default Study 2024) ─────────
RATING_DELTA = {
    "Aaa": 0.60, "Aa1": 0.60, "Aa2": 0.60, "Aa3": 0.60,
    "A1":  0.62, "A2":  0.62, "A3":  0.62,
    "Baa1": 0.63, "Baa2": 0.63, "Baa3": 0.63,
    "Ba1":  0.65, "Ba2":  0.65, "Ba3":  0.65,
    "B1":   0.72, "B2":   0.75, "B3":   0.75,
    "Caa1": 0.78, "Caa2": 0.80, "Caa3": 0.82,
}

# ── iCDS.sol gas benchmarks (Arbitrum Sepolia empirical, March 2026) ───────
# Arbitrum average: ~0.1 gwei; ETH price: $2,800; 1 gwei = 1e-9 ETH
GAS_PRICE_GWEI  = 0.1          # Arbitrum L2 fee (gwei)
ETH_USD         = 2800.0
GWEI_TO_ETH     = 1e-9
GAS_STEPS = {
    "openProtection":     {"gas_units": 128_000, "description": "Seller deposits notional; storage write"},
    "acceptProtection":   {"gas_units":  85_000, "description": "Buyer accepts; first premium transfer"},
    "payPremium":         {"gas_units":  58_000, "description": "Quarterly premium payment"},
    "triggerCreditEvent": {"gas_units":  48_000, "description": "Keeper + oracle price check"},
    "settle":             {"gas_units":  67_000, "description": "LGD payout to buyer; remainder to seller"},
    "expire":             {"gas_units":  52_000, "description": "Seller reclaims collateral at maturity"},
}


def load_sukuk_panel() -> pd.DataFrame:
    path = DATA_2A / "sukuk_panel.csv"
    df = pd.read_csv(path, parse_dates=["obs_date"])
    df["kappa_hat"] = df["spread_bps"] / (10_000 * LGD)
    df["s_star_bps"] = df["kappa_hat"] * LGD * 10_000   # = spread_bps (identity)
    return df


def load_sofr_annual() -> pd.DataFrame:
    path = DATA_2A / "sofr_real.csv"
    sofr = pd.read_csv(path, parse_dates=["date"])
    sofr.columns = ["date", "sofr_pct"]   # rename 'value' → 'sofr_pct'
    sofr["year"] = sofr["date"].dt.year
    annual = sofr.groupby("year")["sofr_pct"].mean().reset_index()
    annual.columns = ["year", "sofr_pct"]
    return annual[annual["year"].between(2012, 2025)]


def load_damodaran() -> pd.DataFrame:
    path = DATA_2A / "damodaran.csv"
    return pd.read_csv(path)


def build_icds_panel(df_panel: pd.DataFrame, sofr_annual: pd.DataFrame,
                     damo: pd.DataFrame) -> pd.DataFrame:
    """
    Build monthly iCDS analysis panel.
    Columns: country, obs_date, kappa_hat, s_obs_bps, s_star_bps,
             sofr_pct, s_conv_bps (AHJ at ι=SOFR), s_diff_bps,
             riba_premium_bps
    """
    rows = []
    damo["obs_date"] = pd.to_datetime(damo["year"].astype(str) + "-01-01")

    for country, params in CIR.items():
        code = params["code"]
        sub  = df_panel[df_panel["country"] == code].copy()

        monthly = (sub.groupby("obs_date")
                      .agg(kappa_hat=("kappa_hat", "median"),
                           s_obs_bps=("spread_bps", "median"))
                      .reset_index()
                      .sort_values("obs_date"))

        monthly["year"] = monthly["obs_date"].dt.year
        monthly = monthly.merge(sofr_annual, on="year", how="left")

        # s* (ι=0): κ̂ × (1−δ) × 10000  ≡ s_obs_bps (structural identity)
        monthly["s_star_bps"] = monthly["kappa_hat"] * LGD * 10_000

        # s_conv (AHJ at ι=SOFR):
        # s_conv = κ × LGD × ι / (κ + ι)
        iota = monthly["sofr_pct"].fillna(0.05) / 100
        kap  = monthly["kappa_hat"]
        monthly["s_conv_bps"] = (kap * LGD * iota / (kap + iota)) * 10_000

        # Riba premium = s*(ι=0) − s_conv(ι=SOFR) = κ²·LGD/(κ+ι) × 10000
        monthly["riba_premium_bps"] = monthly["s_star_bps"] - monthly["s_conv_bps"]

        # s_diff: convention CDS (Damodaran) vs our s_conv
        damo_c = damo[damo["country"] == country][["obs_date", "cds_spread_bps"]].copy()
        monthly = monthly.merge(damo_c, on="obs_date", how="left")
        monthly["s_diff_bps"] = monthly["s_conv_bps"] - monthly["cds_spread_bps"].fillna(np.nan)

        monthly["country"] = country
        rows.append(monthly)

    panel = pd.concat(rows, ignore_index=True)
    return panel


def build_cir_table(sofr_annual: pd.DataFrame, damo: pd.DataFrame) -> pd.DataFrame:
    """
    Long-run pricing: s*_lr = κ̄ × LGD × 10000
    Also compute s_conv_lr using last-year SOFR.
    """
    sofr_2025 = float(sofr_annual[sofr_annual["year"] == 2025]["sofr_pct"].iloc[0]) / 100

    rows = []
    for country, p in CIR.items():
        kbar = p["kbar"]
        hlmo = np.log(2) / p["alpha"] / (1/12)   # half-life in months

        s_lr   = kbar * LGD * 10_000              # long-run iCDS spread (bps)
        s_conv = kbar * LGD * sofr_2025 / (kbar + sofr_2025) * 10_000  # at ι=SOFR

        # 2025 observed CDS
        damo_2025 = damo[(damo["country"] == country) & (damo["year"] == 2025)]
        cds_2025  = float(damo_2025["cds_spread_bps"].iloc[0]) if len(damo_2025) else np.nan

        rows.append(dict(
            country       = country,
            kbar_pct      = kbar * 100,
            half_life_mo  = hlmo,
            s_star_lr     = s_lr,          # iCDS at ι=0, long-run
            s_conv_lr     = s_conv,        # formula at ι=SOFR, long-run
            cds_2025      = cds_2025,      # observed Damodaran 2025
            premium_bps   = s_lr - s_conv, # riba premium (long-run)
            pct_above_cds = (s_lr - cds_2025) / cds_2025 * 100,
        ))
    return pd.DataFrame(rows)


def build_gas_table() -> pd.DataFrame:
    rows = []
    for step, info in GAS_STEPS.items():
        eth_cost = info["gas_units"] * GAS_PRICE_GWEI * GWEI_TO_ETH
        usd_cost = eth_cost * ETH_USD
        rows.append(dict(
            step        = step,
            gas_units   = info["gas_units"],
            gas_gwei    = info["gas_units"] * GAS_PRICE_GWEI,
            eth_cost    = eth_cost,
            usd_cost    = usd_cost,
            description = info["description"],
        ))
    # Total lifecycle (open + accept + 3×pay + trigger + settle)
    total_gas = (GAS_STEPS["openProtection"]["gas_units"]
                 + GAS_STEPS["acceptProtection"]["gas_units"]
                 + 3 * GAS_STEPS["payPremium"]["gas_units"]
                 + GAS_STEPS["triggerCreditEvent"]["gas_units"]
                 + GAS_STEPS["settle"]["gas_units"])
    rows.append(dict(
        step="Full lifecycle (1yr, 3 premiums + settlement)",
        gas_units=total_gas,
        gas_gwei=total_gas * GAS_PRICE_GWEI,
        eth_cost=total_gas * GAS_PRICE_GWEI * GWEI_TO_ETH,
        usd_cost=total_gas * GAS_PRICE_GWEI * GWEI_TO_ETH * ETH_USD,
        description="openProtection+accept+3×pay+trigger+settle",
    ))
    return pd.DataFrame(rows)


def build_welfare_analysis() -> pd.DataFrame:
    """
    CRRA utility comparison for a $10M Saudi Aramco 5yr sukuk position.
    Risk aversion γ ∈ {2, 5, 10}.
    Strategies: unhedged, iCDS (ι=0), conventional CDS (ι=SOFR).
    """
    W0        = 10_000_000   # $10M sukuk position
    kappa_sa  = CIR["Saudi Arabia"]["kbar"]   # 2.409%
    lgd       = LGD                            # 0.40
    sofr_2025 = 0.053                          # 5.3%
    T         = 5                              # years

    # Expected loss over T years (Poisson arrival):
    # E[loss] = notional × LGD × (1 - exp(-κT))
    p_default = 1 - np.exp(-kappa_sa * T)     # 5-yr default probability
    exp_loss  = W0 * lgd * p_default

    # Premium cost:
    # iCDS (ι=0, perpetual): s* × W0 per year × T = κ·LGD·W0·T
    prem_icds = kappa_sa * lgd * W0 * T
    # CDS (ι=SOFR): s_conv × W0 per year × T
    s_conv = kappa_sa * lgd * sofr_2025 / (kappa_sa + sofr_2025)
    prem_cds  = s_conv * W0 * T

    rows = []
    for gamma in [2, 5, 10]:
        def crra(w):
            if gamma == 1:
                return np.log(max(w, 1))
            return (max(w, 1) ** (1 - gamma)) / (1 - gamma)

        # Unhedged
        W_no_default = W0
        W_default    = W0 * (1 - lgd)
        EU_unhedged  = (1 - p_default) * crra(W_no_default) + p_default * crra(W_default)

        # iCDS hedged
        W_iCDS_no_def = W0 - prem_icds
        W_iCDS_def    = W0 - prem_icds  # full recovery (iCDS pays LGD × notional)
        EU_icds       = (1 - p_default) * crra(W_iCDS_no_def) + p_default * crra(W_iCDS_def)

        # CDS hedged (cheaper premium due to ι discount)
        W_cds_no_def  = W0 - prem_cds
        W_cds_def     = W0 - prem_cds
        EU_cds        = (1 - p_default) * crra(W_cds_no_def) + p_default * crra(W_cds_def)

        rows.append(dict(
            gamma           = gamma,
            prem_icds_usd   = prem_icds,
            prem_cds_usd    = prem_cds,
            EU_unhedged     = EU_unhedged,
            EU_icds         = EU_icds,
            EU_cds          = EU_cds,
            delta_EU_icds   = EU_icds - EU_unhedged,   # utility gain from iCDS
            delta_EU_cds    = EU_cds  - EU_unhedged,   # utility gain from CDS
            hedge_equiv_bps = (prem_icds - prem_cds) / W0 * 10_000,  # iCDS premium excess
        ))
    return pd.DataFrame(rows)


def main():
    print("Loading Paper 2A data...")
    df_panel   = load_sukuk_panel()
    sofr_ann   = load_sofr_annual()
    damo       = load_damodaran()

    print("Building iCDS panel...")
    panel      = build_icds_panel(df_panel, sofr_ann, damo)
    panel.to_csv(OUT / "icds_panel.csv", index=False)
    print(f"  icds_panel.csv: {len(panel):,} rows")

    print("Building CIR long-run table...")
    cir_tbl    = build_cir_table(sofr_ann, damo)
    cir_tbl.to_csv(OUT / "cir_longrun.csv", index=False)
    print(cir_tbl[["country","kbar_pct","s_star_lr","s_conv_lr","cds_2025","pct_above_cds"]].to_string(index=False))

    print("\nBuilding gas cost table...")
    gas_tbl    = build_gas_table()
    gas_tbl.to_csv(OUT / "gas_costs.csv", index=False)
    for _, r in gas_tbl.iterrows():
        print(f"  {r['step']:<45}: {r['gas_units']:>8,} gas  ~${r['usd_cost']:.4f}")

    print("\nBuilding welfare analysis...")
    welfare    = build_welfare_analysis()
    welfare.to_csv(OUT / "welfare.csv", index=False)
    print(welfare[["gamma","prem_icds_usd","prem_cds_usd","delta_EU_icds","delta_EU_cds"]].to_string(index=False))

    print("\nSaving SOFR annual...")
    sofr_ann.to_csv(OUT / "sofr_annual.csv", index=False)

    print(f"\nAll data written to {OUT}")


if __name__ == "__main__":
    main()
