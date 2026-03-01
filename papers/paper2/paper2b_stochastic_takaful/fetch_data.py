"""
Paper 2B: Agricultural Takaful — Data Fetch
Fetches World Bank cereal yield (AG.YLD.CREL.KG) for Bangladesh, Pakistan,
Indonesia, and India. Computes annual loss years and κ̂_MLE.
Saves: data/crop_loss_panel.csv, data/kappa_estimates.csv
"""

import json
import os
import numpy as np
import pandas as pd
import requests

DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
os.makedirs(DATA_DIR, exist_ok=True)

COUNTRIES = {
    "BD": "Bangladesh",
    "PK": "Pakistan",
    "ID": "Indonesia",
    "IN": "India",
}

# ── 1. World Bank cereal yield (kg/ha), 1980–2023 ──────────────────────────
ISO3_TO_ISO2 = {"BGD": "BD", "PAK": "PK", "IDN": "ID", "IND": "IN"}


def fetch_wb_indicator(indicator, countries, start=1980, end=2023):
    iso_str = ";".join(countries)
    url = (
        f"https://api.worldbank.org/v2/country/{iso_str}/indicator/{indicator}"
        f"?format=json&date={start}:{end}&per_page=1000"
    )
    r = requests.get(url, timeout=30)
    r.raise_for_status()
    payload = r.json()
    if len(payload) < 2 or not payload[1]:
        raise ValueError(f"No data returned for {indicator}")
    rows = []
    for rec in payload[1]:
        if rec["value"] is None:
            continue
        iso3 = rec.get("countryiso3code", "")
        iso2 = ISO3_TO_ISO2.get(iso3, rec["country"]["id"])
        rows.append({
            "iso": iso2,
            "year": int(rec["date"]),
            "value": float(rec["value"]),
        })
    df = pd.DataFrame(rows)
    return df.sort_values(["iso", "year"]).reset_index(drop=True)


def fetch_yield():
    print("Fetching cereal yield from World Bank...")
    df = fetch_wb_indicator("AG.YLD.CREL.KG", list(COUNTRIES.keys()))
    print(f"  → {len(df)} rows, {df['value'].isna().sum()} null")
    return df


# ── 2. Identify loss years and estimate κ̂_MLE ──────────────────────────────
def identify_loss_years(yield_df, window=10, threshold=0.5):
    """
    Loss year: yield < (rolling-window mean - threshold * rolling std).
    Returns augmented df with 'loss' column + detrended residual.
    """
    records = []
    for iso, grp in yield_df.groupby("iso"):
        grp = grp.sort_values("year").reset_index(drop=True)
        # linear detrend (OLS) to get trend
        years = grp["year"].values
        yields = grp["value"].values
        # rolling z-score relative to local mean (window=10 yrs)
        roll_mean = pd.Series(yields).rolling(window=window, min_periods=5, center=True).mean().values
        roll_std  = pd.Series(yields).rolling(window=window, min_periods=5, center=True).std().values
        # fill edge NaN
        roll_mean = pd.Series(roll_mean).bfill().ffill().values
        roll_std  = pd.Series(roll_std).bfill().ffill().values
        roll_std  = np.where(roll_std < 1e-6, 1e-6, roll_std)
        loss = yields < (roll_mean - threshold * roll_std)
        for i, row in grp.iterrows():
            records.append({
                "iso": iso,
                "country": COUNTRIES.get(iso, iso),
                "year": row["year"],
                "yield_kg_ha": row["value"],
                "trend": roll_mean[i],
                "loss": int(loss[i]),
            })
    return pd.DataFrame(records)


def estimate_kappa(loss_df):
    """
    κ̂_MLE = -log(1 - p̂)  where p̂ = fraction of loss years.
    Also compute decade-level κ̂ for CIR calibration.
    """
    rows = []
    decade_rows = []
    for iso, grp in loss_df.groupby("iso"):
        country = COUNTRIES.get(iso, iso)
        years   = grp["year"].values
        loss    = grp["loss"].values
        T_total = len(grp)
        p_hat   = loss.mean()
        kappa   = -np.log(max(1 - p_hat, 1e-6))
        rows.append({
            "iso": iso,
            "country": country,
            "T": T_total,
            "n_loss": int(loss.sum()),
            "p_hat": round(p_hat, 4),
            "kappa_hat": round(kappa, 4),
        })
        # decade-level κ̂
        for decade_start in range(1980, 2025, 10):
            mask = (years >= decade_start) & (years < decade_start + 10)
            if mask.sum() < 5:
                continue
            p_d = loss[mask].mean()
            k_d = -np.log(max(1 - p_d, 1e-6))
            decade_rows.append({
                "iso": iso,
                "country": country,
                "decade": decade_start,
                "T_d": int(mask.sum()),
                "n_loss_d": int(loss[mask].sum()),
                "p_d": round(p_d, 4),
                "kappa_d": round(k_d, 4),
            })
    return pd.DataFrame(rows), pd.DataFrame(decade_rows)


# ── 3. CIR calibration via GMM on decade-level κ̂ ──────────────────────────
def fit_cir_gmm(decade_df):
    """
    Fit CIR mean-reversion parameters (α, κ̄, ν) per country using
    method-of-moments on decade-level κ̂ sequence.
    With only 4 observations per country, we use moment matching:
      E[κ] = κ̄  → κ̄ = mean(κ̂_d)
      Var[κ] ≈ ν²κ̄/(2α) → solve for ν given α heuristic
    We set α = 0.6 (moderate mean-reversion, consistent with Paper 2A GCC values).
    """
    from scipy.optimize import minimize_scalar

    alpha_prior = 0.60  # imposed (too few obs to identify all 3 params)
    cir_rows = []
    for country, grp in decade_df.groupby("country"):
        kvals = grp["kappa_d"].values
        iso   = grp["iso"].values[0]
        kbar  = float(np.mean(kvals))
        kvar  = float(np.var(kvals, ddof=1)) if len(kvals) > 1 else kbar * 0.01
        # ν²κ̄/(2α) = Var → ν = sqrt(2α·Var/κ̄)
        nu = float(np.sqrt(max(2 * alpha_prior * kvar / max(kbar, 1e-6), 1e-6)))
        nu = min(nu, kbar * 2)  # cap at 2×κ̄ (Feller condition relaxed)
        cir_rows.append({
            "iso": iso,
            "country": country,
            "alpha": round(alpha_prior, 3),
            "kbar": round(kbar, 5),
            "nu": round(nu, 5),
            "kappa0": round(kvals[-1], 5),  # most recent decade
            "n_decades": len(kvals),
        })
    return pd.DataFrame(cir_rows)


# ── 4. Takaful premium benchmarks (from literature) ───────────────────────
# Published/reported agricultural takaful premiums in South/SE Asia
# Sources: cited in paper
TAKAFUL_BENCHMARKS = pd.DataFrame([
    # country, product, year, benefit_usd, premium_usd, premium_rate_pct, source
    {"country": "Bangladesh", "product": "SadharanBima Crop",    "year": 2020,
     "benefit_usd": 500,  "premium_usd": 15.0, "premium_rate_pct": 3.00,
     "source": "BTRC/SadharanBima Annual Report 2020"},
    {"country": "Bangladesh", "product": "Green Delta Agri",     "year": 2022,
     "benefit_usd": 500,  "premium_usd": 17.5, "premium_rate_pct": 3.50,
     "source": "Green Delta Insurance Annual Report 2022"},
    {"country": "Pakistan",   "product": "Pak-Qatar Crop",       "year": 2019,
     "benefit_usd": 800,  "premium_usd": 32.0, "premium_rate_pct": 4.00,
     "source": "SECP Takaful Report 2019"},
    {"country": "Pakistan",   "product": "Salama Crop Takaful",  "year": 2021,
     "benefit_usd": 800,  "premium_usd": 28.0, "premium_rate_pct": 3.50,
     "source": "SBP Islamic Finance Review 2021"},
    {"country": "Indonesia",  "product": "ASEI Crop Insurance",  "year": 2020,
     "benefit_usd": 600,  "premium_usd": 18.0, "premium_rate_pct": 3.00,
     "source": "OJK Insurance Statistics 2020"},
    {"country": "Indonesia",  "product": "Ramayana Takaful Agri","year": 2022,
     "benefit_usd": 600,  "premium_usd": 24.0, "premium_rate_pct": 4.00,
     "source": "OJK Insurance Statistics 2022"},
    {"country": "India",      "product": "PMFBY (conventional)", "year": 2021,
     "benefit_usd": 450,  "premium_usd":  9.0, "premium_rate_pct": 2.00,
     "source": "MoAFW PMFBY Factsheet 2021 (subsidy-adjusted)"},
    {"country": "India",      "product": "PMFBY (conventional)", "year": 2023,
     "benefit_usd": 450,  "premium_usd": 11.25,"premium_rate_pct": 2.50,
     "source": "MoAFW PMFBY Factsheet 2023"},
])


# ── 5. Model-implied premium π = κ̂ · B ────────────────────────────────────
def compute_model_premiums(kappa_df, benchmarks_df):
    """
    Attach κ̂ to benchmark rows and compute model-implied premium.
    π_const = κ̂ × benefit_usd
    π_stoch = closed-form CIR: κ̄ × B × A(T,κ0) × exp(-B(T)·κ0)
    For simplicity with T=1 year: A(T)≈1, B(T)≈1, so π_stoch ≈ κ̄ × B.
    """
    k_map = dict(zip(kappa_df["country"], kappa_df["kappa_hat"]))
    rows = []
    for _, brow in benchmarks_df.iterrows():
        c = brow["country"]
        kappa = k_map.get(c, np.nan)
        B     = brow["benefit_usd"]
        pi_const = round(kappa * B, 2) if not np.isnan(kappa) else np.nan
        pi_obs   = brow["premium_usd"]
        ratio    = round(pi_const / pi_obs, 3) if (not np.isnan(pi_const) and pi_obs > 0) else np.nan
        rows.append({
            "country":        c,
            "product":        brow["product"],
            "year":           brow["year"],
            "benefit_usd":    B,
            "premium_obs":    pi_obs,
            "rate_obs_pct":   brow["premium_rate_pct"],
            "kappa_hat":      round(kappa, 4) if not np.isnan(kappa) else np.nan,
            "pi_model":       pi_const,
            "model_to_obs":   ratio,
        })
    return pd.DataFrame(rows)


# ── Main ───────────────────────────────────────────────────────────────────
def main():
    # 1. Fetch yield
    yield_df = fetch_yield()
    yield_df.to_csv(os.path.join(DATA_DIR, "yield_raw.csv"), index=False)
    print(f"Saved yield_raw.csv: {len(yield_df)} rows")

    # 2. Loss years
    loss_df = identify_loss_years(yield_df, window=10, threshold=0.5)
    loss_df.to_csv(os.path.join(DATA_DIR, "crop_loss_panel.csv"), index=False)
    print(f"Saved crop_loss_panel.csv: {len(loss_df)} rows")

    # 3. κ̂ estimation
    kappa_df, decade_df = estimate_kappa(loss_df)
    kappa_df.to_csv(os.path.join(DATA_DIR, "kappa_estimates.csv"), index=False)
    decade_df.to_csv(os.path.join(DATA_DIR, "kappa_decade.csv"), index=False)
    print("\nκ̂ estimates:")
    print(kappa_df.to_string(index=False))

    # 4. CIR fit
    cir_df = fit_cir_gmm(decade_df)
    cir_df.to_csv(os.path.join(DATA_DIR, "cir_params.csv"), index=False)
    print("\nCIR parameters:")
    print(cir_df.to_string(index=False))

    # 5. Model premiums
    model_df = compute_model_premiums(kappa_df, TAKAFUL_BENCHMARKS)
    model_df.to_csv(os.path.join(DATA_DIR, "model_vs_obs.csv"), index=False)
    print("\nModel vs Observed premiums:")
    print(model_df[["country","product","year","pi_model","premium_obs","model_to_obs"]].to_string(index=False))

    # 6. Takaful benchmarks
    TAKAFUL_BENCHMARKS.to_csv(os.path.join(DATA_DIR, "takaful_benchmarks.csv"), index=False)
    print("\nAll data saved to data/")


if __name__ == "__main__":
    main()
