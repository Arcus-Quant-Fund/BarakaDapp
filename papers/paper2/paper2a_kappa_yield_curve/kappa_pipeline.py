#!/usr/bin/env python3
"""
kappa_pipeline.py
=================
Estimation pipeline for Paper 2A:
  "The κ-Yield Curve: Empirical Estimation of the Convergence Intensity
   from Sukuk Panel Data"

Pipeline stages:
  1. load_data()          — Load sukuk panel from CSV
  2. extract_kappa()      — κ̂ = s_obs / (1 − δ)
  3. fit_nss()            — Nelson-Siegel-Svensson curve fitting per country-date
  4. fit_cir()            — GMM estimation of CIR dynamics
  5. horse_race()         — κ-model vs. SOFR-model predictive accuracy
  6. panel_regression()   — s_{i,t} = α + β·κ̂ + γ·X + ε  (two-way FE)
  7. plot_kappa_curves()  — Publication-quality κ-yield curve figures
  8. export_latex()       — LaTeX-ready tables (ready to paste into paper)

Data format (CSV, columns):
  sukuk_id        str     unique identifier  e.g. "SAU-2027-USD"
  country         str     ISO-2             e.g. "SA", "MY", "AE", "QA", "ID"
  sector          str     sovereign|corporate
  issue_date      str     YYYY-MM-DD
  maturity_date   str     YYYY-MM-DD
  maturity_years  float   time to maturity in years at observation date
  obs_date        str     YYYY-MM-DD        observation date
  yield_pct       float   yield to maturity (%)
  sofr_pct        float   SOFR rate on obs_date (%)
  spread_bps      float   yield_pct - sofr_pct in basis points
  rating          str     Moody's rating   e.g. "Aa3", "A1", "Baa1"
  currency        str     "USD", "MYR", "SAR"

Usage:
  python kappa_pipeline.py --data data/sukuk_panel.csv
  python kappa_pipeline.py --data data/sukuk_panel.csv --delta 0.40 --output results/
  python kappa_pipeline.py --demo   # run on synthetic data to verify pipeline
"""

import argparse
import os
import sys
import warnings
from typing import Dict, List, Optional, Tuple

import numpy as np
import pandas as pd
from scipy.optimize import differential_evolution, minimize
from scipy.stats import chi2

warnings.filterwarnings("ignore", category=RuntimeWarning)
warnings.filterwarnings("ignore", category=FutureWarning)

# ── optional heavy imports ─────────────────────────────────────────────────────
try:
    import matplotlib.pyplot as plt
    import matplotlib.ticker as mtick
    HAS_MPL = True
except ImportError:
    HAS_MPL = False
    print("Warning: matplotlib not found — plots will be skipped.")

try:
    import statsmodels.formula.api as smf
    import statsmodels.api as sm
    HAS_SM = True
except ImportError:
    HAS_SM = False
    print("Warning: statsmodels not found — panel regressions will be skipped.")


# ══════════════════════════════════════════════════════════════════════════════
# 1.  CONSTANTS AND RECOVERY RATE TABLE
# ══════════════════════════════════════════════════════════════════════════════

# Recovery rates by Moody's rating category (Basel II / Moody's 2023 study)
RECOVERY_BY_RATING: Dict[str, float] = {
    "Aaa": 0.60, "Aa1": 0.60, "Aa2": 0.60, "Aa3": 0.60,
    "A1":  0.55, "A2":  0.55, "A3":  0.50,
    "Baa1": 0.45, "Baa2": 0.40, "Baa3": 0.35,
    "Ba1":  0.30, "Ba2":  0.25, "Ba3":  0.20,
    "B1":   0.15, "B2":   0.15, "B3":   0.10,
    "Caa1": 0.08, "Caa2": 0.07, "Caa3": 0.05,
    "C":    0.03, "D":    0.02,
    # Sovereign overrides (higher recovery in debt restructuring)
    "sovereign_AA": 0.65, "sovereign_A": 0.60, "sovereign_BBB": 0.55,
}
DELTA_DEFAULT_CORPORATE = 0.40   # Basel II standard
DELTA_DEFAULT_SOVEREIGN  = 0.60   # Moody's sovereign


# ══════════════════════════════════════════════════════════════════════════════
# 2.  DATA LOADING
# ══════════════════════════════════════════════════════════════════════════════

def load_data(path: str) -> pd.DataFrame:
    """Load sukuk panel CSV and apply basic validation + date parsing."""
    required = {
        "sukuk_id", "country", "sector", "maturity_years",
        "obs_date", "spread_bps", "rating",
    }
    df = pd.read_csv(path, parse_dates=["obs_date", "issue_date", "maturity_date"],
                     infer_datetime_format=True)
    missing = required - set(df.columns)
    if missing:
        raise ValueError(f"CSV is missing required columns: {missing}")

    df = df[df["maturity_years"] >= 1.0].copy()          # drop sub-1yr
    df = df[df["spread_bps"].notna()].copy()
    df = df[df["spread_bps"] > -500].copy()               # sanity bound
    df["obs_date"] = pd.to_datetime(df["obs_date"])
    df = df.sort_values(["sukuk_id", "obs_date"]).reset_index(drop=True)
    print(f"[load_data] {len(df):,} observations | "
          f"{df['sukuk_id'].nunique()} sukuk | "
          f"{df['country'].nunique()} countries")
    return df


# ══════════════════════════════════════════════════════════════════════════════
# 3.  κ EXTRACTION  (Paper 2A Equation 1)
# ══════════════════════════════════════════════════════════════════════════════

def get_delta(row: pd.Series, delta_override: Optional[float] = None) -> float:
    """Return recovery rate δ for a single observation."""
    if delta_override is not None:
        return delta_override
    if row.get("sector", "corporate") == "sovereign":
        rating_key = f"sovereign_{row.get('rating_sp', 'A')}"
        return RECOVERY_BY_RATING.get(rating_key, DELTA_DEFAULT_SOVEREIGN)
    return RECOVERY_BY_RATING.get(row.get("rating", "Baa2"), DELTA_DEFAULT_CORPORATE)


def extract_kappa(df: pd.DataFrame, delta: Optional[float] = None) -> pd.DataFrame:
    """
    κ̂ = spread_bps / (10_000 × (1 − δ))

    Spread in bps → convert to decimal: spread_bps / 10_000
    So κ̂ is in units of per-annum (same units as a default intensity).
    Also computes kappa_annualised = kappa * 100 (in %) for readability.
    """
    df = df.copy()
    df["delta"] = df.apply(lambda r: get_delta(r, delta), axis=1)
    df["spread_dec"] = df["spread_bps"] / 10_000        # convert bps → decimal
    df["kappa_hat"] = df["spread_dec"] / (1 - df["delta"])
    df["kappa_hat"] = df["kappa_hat"].clip(lower=1e-6)   # κ̂ > 0 always
    df["kappa_pct"] = df["kappa_hat"] * 100              # % per annum (readable)
    print(f"[extract_kappa] κ̂ range: "
          f"{df['kappa_hat'].min()*1e4:.1f} – {df['kappa_hat'].max()*1e4:.1f} bps/yr")
    return df


# ══════════════════════════════════════════════════════════════════════════════
# 4.  NELSON-SIEGEL-SVENSSON CURVE FITTING  (Paper 2A Equation 2)
# ══════════════════════════════════════════════════════════════════════════════

def nss_curve(T: np.ndarray, b0: float, b1: float, b2: float, b3: float,
              t1: float, t2: float) -> np.ndarray:
    """
    Nelson-Siegel-Svensson functional form for the κ-yield curve.

    κ(T; β) = β₀
            + β₁ · [(1−e^{−T/τ₁}) / (T/τ₁)]
            + β₂ · [(1−e^{−T/τ₁}) / (T/τ₁) − e^{−T/τ₁}]
            + β₃ · [(1−e^{−T/τ₂}) / (T/τ₂) − e^{−T/τ₂}]
    """
    t1 = max(t1, 1e-4)
    t2 = max(t2, 1e-4)
    T  = np.asarray(T, dtype=float)

    f1 = (1 - np.exp(-T / t1)) / (T / t1)
    f2 = f1 - np.exp(-T / t1)
    f3 = (1 - np.exp(-T / t2)) / (T / t2) - np.exp(-T / t2)

    return b0 + b1 * f1 + b2 * f2 + b3 * f3


def fit_nss(T: np.ndarray, kappa_hat: np.ndarray,
            weights: Optional[np.ndarray] = None) -> Dict:
    """
    Fit NSS model to a cross-section of κ̂(T) observations.

    Parameters
    ----------
    T          : array of maturities (years)
    kappa_hat  : array of κ̂ estimates at those maturities
    weights    : optional precision weights

    Returns
    -------
    dict with keys: params, fitted, rmse, success
    """
    if weights is None:
        weights = np.ones_like(kappa_hat)

    def objective(params):
        b0, b1, b2, b3, t1, t2 = params
        fitted = nss_curve(T, b0, b1, b2, b3, t1, t2)
        resid = kappa_hat - fitted
        return np.sum(weights * resid**2)

    # Differential evolution for global optimum, then refine with L-BFGS-B
    bounds = [
        (1e-5, 0.20),   # b0: level (κ range 1bps–20%)
        (-0.10, 0.10),  # b1: slope
        (-0.10, 0.10),  # b2: curvature 1
        (-0.10, 0.10),  # b3: curvature 2
        (0.25, 10.0),   # τ₁
        (0.25, 15.0),   # τ₂
    ]
    # Warm start: simple initial guess
    b0_init = float(np.mean(kappa_hat))
    x0 = [b0_init, 0.0, 0.0, 0.0, 1.5, 5.0]

    res = minimize(objective, x0, method="L-BFGS-B", bounds=bounds,
                   options={"maxiter": 5000, "ftol": 1e-12})
    if not res.success:
        res_de = differential_evolution(objective, bounds, maxiter=500, tol=1e-10,
                                        seed=42, polish=True)
        if res_de.fun < res.fun:
            res = res_de

    params = res.x
    fitted = nss_curve(T, *params)
    rmse = np.sqrt(np.mean((kappa_hat - fitted)**2)) * 10_000  # bps

    return {
        "params": {
            "beta0": params[0], "beta1": params[1],
            "beta2": params[2], "beta3": params[3],
            "tau1": params[4],  "tau2": params[5],
        },
        "fitted": fitted,
        "rmse_bps": rmse,
        "success": res.success,
    }


def fit_nss_panel(df: pd.DataFrame,
                  group_cols: List[str] = ["country", "obs_date"],
                  maturity_col: str = "maturity_years",
                  kappa_col:   str = "kappa_hat") -> pd.DataFrame:
    """
    Fit NSS curve for each group (country × date) and store parameters.
    Returns DataFrame of NSS parameters, one row per group.
    """
    records = []
    for keys, grp in df.groupby(group_cols):
        T_arr = grp[maturity_col].values
        k_arr = grp[kappa_col].values
        if len(T_arr) < 4:          # need at least 4 maturities to fit 6 params
            continue
        result = fit_nss(T_arr, k_arr)
        row = dict(zip(group_cols, keys if isinstance(keys, tuple) else [keys]))
        row.update(result["params"])
        row["nss_rmse_bps"] = result["rmse_bps"]
        row["nss_success"]  = result["success"]
        row["n_maturities"] = len(T_arr)
        records.append(row)
    nss_df = pd.DataFrame(records)
    print(f"[fit_nss_panel] Fitted {len(nss_df)} NSS curves.")
    return nss_df


# ══════════════════════════════════════════════════════════════════════════════
# 5.  CIR DYNAMICS — GMM ESTIMATION  (Paper 2A Equation 3–4)
# ══════════════════════════════════════════════════════════════════════════════

def cir_gmm_moments(theta: np.ndarray, kappa_ts: np.ndarray, h: float) -> np.ndarray:
    """
    GMM moment conditions for the CIR model (Euler-Maruyama discretisation).

    θ = (α, κ̄, ν)

    g₁ = E[κ_{t+h} − κ_t − αh(κ̄ − κ_t)]                              (mean)
    g₂ = E[(κ_{t+h} − κ_t − αh(κ̄ − κ_t))² − ν²κ_t h]                 (variance)
    g₃ = E[(κ_{t+h} − κ_t − αh(κ̄ − κ_t)) · (κ_t − κ̄)]               (autocov)
    """
    alpha, kbar, nu = theta
    kappa_t  = kappa_ts[:-1]
    kappa_t1 = kappa_ts[1:]

    innov = kappa_t1 - kappa_t - alpha * h * (kbar - kappa_t)

    g1 = innov
    g2 = innov**2 - nu**2 * kappa_t * h
    g3 = innov * (kappa_t - kbar)

    return np.column_stack([g1, g2, g3])   # shape (T-1, 3)


def fit_cir(kappa_ts: np.ndarray, h: float = 1/12) -> Dict:
    """
    Estimate CIR parameters θ = (α, κ̄, ν) by GMM with Newey-West weighting.

    Parameters
    ----------
    kappa_ts : 1-D array of κ̂ time series (monthly)
    h        : step size in years (default 1/12 = monthly)

    Returns
    -------
    dict with keys: alpha, kbar, nu, se_alpha, se_kbar, se_nu,
                    half_life_months, feller_ok, j_stat, j_pval
    """
    kappa_ts = np.asarray(kappa_ts, dtype=float)
    kappa_ts = kappa_ts[~np.isnan(kappa_ts)]
    if len(kappa_ts) < 24:
        return {"error": "Need at least 24 observations for CIR GMM."}

    def gmm_objective(theta, W):
        g = cir_gmm_moments(theta, kappa_ts, h)
        g_mean = g.mean(axis=0)
        return float(g_mean @ W @ g_mean)

    # Step 1: identity weight matrix (first-stage GMM)
    W1 = np.eye(3)
    x0 = [2.0, float(np.mean(kappa_ts)), float(np.std(kappa_ts))]
    bounds = [(0.01, 50.0), (1e-5, 0.50), (1e-5, 1.0)]
    res1 = minimize(gmm_objective, x0, args=(W1,), method="L-BFGS-B", bounds=bounds,
                    options={"maxiter": 10000})
    theta1 = res1.x

    # Step 2: Newey-West optimal weight matrix
    g_mat = cir_gmm_moments(theta1, kappa_ts, h)
    n = g_mat.shape[0]
    lags = int(np.floor(4 * (n / 100) ** (2 / 9)))   # Newey-West bandwidth
    S = g_mat.T @ g_mat / n
    for lag in range(1, lags + 1):
        weight = 1 - lag / (lags + 1)
        gamma  = g_mat[lag:].T @ g_mat[:-lag] / n
        S     += weight * (gamma + gamma.T)
    W2 = np.linalg.pinv(S)

    # Step 3: second-stage GMM
    res2 = minimize(gmm_objective, theta1, args=(W2,), method="L-BFGS-B", bounds=bounds,
                    options={"maxiter": 10000})
    theta_hat = res2.x
    alpha, kbar, nu = theta_hat

    # Standard errors: sandwich formula
    g_final = cir_gmm_moments(theta_hat, kappa_ts, h)
    eps = 1e-5
    D = np.zeros((3, 3))
    for j in range(3):
        tp, tm = theta_hat.copy(), theta_hat.copy()
        tp[j] += eps; tm[j] -= eps
        D[:, j] = (cir_gmm_moments(tp, kappa_ts, h).mean(axis=0) -
                   cir_gmm_moments(tm, kappa_ts, h).mean(axis=0)) / (2 * eps)
    V = np.linalg.pinv(D.T @ W2 @ D) / n
    se = np.sqrt(np.diag(V))

    # Feller condition: 2αk̄ ≥ ν²
    feller_ok = 2 * alpha * kbar >= nu**2

    # Half-life of mean reversion
    half_life_months = np.log(2) / alpha / h if alpha > 0 else np.inf

    # J-test for overidentification (with 4th instrument)
    # (3 moment conditions, 3 params → exactly identified → J = 0; skip here)
    j_stat = float(n * gmm_objective(theta_hat, W2))
    j_pval = 1.0   # exactly identified

    return {
        "alpha":          alpha,
        "kbar":           kbar,
        "nu":             nu,
        "se_alpha":       se[0],
        "se_kbar":        se[1],
        "se_nu":          se[2],
        "half_life_months": half_life_months,
        "feller_ok":      feller_ok,
        "j_stat":         j_stat,
        "j_pval":         j_pval,
    }


# ══════════════════════════════════════════════════════════════════════════════
# 6.  HORSE RACE: κ-MODEL vs. SOFR-MODEL
# ══════════════════════════════════════════════════════════════════════════════

def horse_race(df: pd.DataFrame) -> pd.DataFrame:
    """
    Compare predictive accuracy of κ-model vs. SOFR-model vs. random walk.

    κ-model:    ŝ_κ   = κ̂_{i,t} × (1 − δ_i)   [should recover s by construction]
    SOFR-model: ŝ_SOFR = OLS fit of s on SOFR level + maturity + rating dummies
    RW:         ŝ_RW   = s_{i,t-1}

    Returns DataFrame with RMSE, MAE, R² for each model.
    """
    df = df.copy().sort_values(["sukuk_id", "obs_date"])

    # κ-model prediction (analytical)
    df["pred_kappa_bps"] = df["kappa_hat"] * (1 - df["delta"]) * 10_000

    # SOFR-model (OLS benchmark) — requires sofr_pct column
    results = {}
    if "sofr_pct" in df.columns and HAS_SM:
        df["rating_code"] = pd.Categorical(df["rating"]).codes
        sofr_model = smf.ols(
            "spread_bps ~ sofr_pct + maturity_years + rating_code + C(country)",
            data=df.dropna(subset=["sofr_pct"])
        ).fit()
        df["pred_sofr_bps"] = sofr_model.predict(df)
    else:
        df["pred_sofr_bps"] = np.nan

    # Random walk benchmark
    df["pred_rw_bps"] = df.groupby("sukuk_id")["spread_bps"].shift(1)

    def metrics(actual, predicted, label):
        mask = ~(np.isnan(actual) | np.isnan(predicted))
        a, p = actual[mask], predicted[mask]
        rmse = np.sqrt(np.mean((a - p)**2))
        mae  = np.mean(np.abs(a - p))
        ss_res = np.sum((a - p)**2)
        ss_tot = np.sum((a - np.mean(a))**2)
        r2 = 1 - ss_res / ss_tot if ss_tot > 0 else np.nan
        return {"Model": label, "N": mask.sum(),
                "RMSE_bps": rmse, "MAE_bps": mae, "R2": r2}

    rows = [
        metrics(df["spread_bps"], df["pred_kappa_bps"], "κ-model"),
        metrics(df["spread_bps"], df["pred_sofr_bps"],  "SOFR-model"),
        metrics(df["spread_bps"], df["pred_rw_bps"],    "Random Walk"),
    ]

    # Diebold-Mariano test: κ-model vs. SOFR-model
    dm_result = diebold_mariano(df["spread_bps"], df["pred_kappa_bps"],
                                df["pred_sofr_bps"])
    print(f"[horse_race] Diebold-Mariano stat: {dm_result['dm_stat']:.3f} "
          f"(p={dm_result['p_value']:.4f})")

    results_df = pd.DataFrame(rows)
    results_df["DM_vs_SOFR"] = [dm_result["dm_stat"], np.nan, np.nan]
    results_df["DM_pval"]    = [dm_result["p_value"], np.nan, np.nan]
    return results_df


def diebold_mariano(actual: pd.Series, pred1: pd.Series,
                    pred2: pd.Series, h: int = 1) -> Dict:
    """
    Diebold-Mariano (1995) test for equal predictive accuracy.
    H₀: E[L(e₁)] = E[L(e₂)], L = squared loss.
    """
    e1 = (actual - pred1).dropna()
    e2 = (actual - pred2).dropna()
    idx = e1.index.intersection(e2.index)
    e1, e2 = e1[idx], e2[idx]
    d = e1**2 - e2**2
    n = len(d)
    d_mean = d.mean()
    # Newey-West variance of d
    gamma0 = np.var(d, ddof=1)
    nw_var = gamma0
    for lag in range(1, h):
        gamma_l = np.cov(d[lag:].values, d[:-lag].values)[0, 1]
        nw_var += 2 * (1 - lag / h) * gamma_l
    se = np.sqrt(nw_var / n)
    dm_stat = d_mean / se if se > 0 else np.nan
    p_value = 2 * (1 - _normal_cdf(abs(dm_stat))) if not np.isnan(dm_stat) else np.nan
    return {"dm_stat": dm_stat, "p_value": p_value, "n": n}


def _normal_cdf(z: float) -> float:
    """Standard normal CDF via error function."""
    from math import erf, sqrt
    return 0.5 * (1 + erf(z / sqrt(2)))


# ══════════════════════════════════════════════════════════════════════════════
# 7.  PANEL REGRESSION
# ══════════════════════════════════════════════════════════════════════════════

def panel_regression(df: pd.DataFrame) -> Dict:
    """
    Run panel regressions of sukuk spread on κ̂ with controls.

    Specifications:
      (1) OLS pooled: s = α + β κ̂ + ε
      (2) Country FE: s = α_c + β κ̂ + ε
      (3) Sector FE:  s = α_s + β κ̂ + ε
      (4) Two-way FE: s = α_c + α_s + β κ̂ + ε
      (5) Full:       s = α_c + α_s + β κ̂ + γ₁ Rating + γ₂ log(Maturity)
                          + γ₃ VIX + γ₄ OilPrice + ε

    Returns dict of fitted model objects (statsmodels).
    """
    if not HAS_SM:
        print("[panel_regression] statsmodels not available — skipping.")
        return {}

    df = df.copy()
    df["log_maturity"] = np.log(df["maturity_years"])
    df["rating_code"]  = pd.Categorical(df["rating"]).codes

    models = {}
    specs = {
        "(1) OLS":       "spread_bps ~ kappa_hat",
        "(2) Country FE":"spread_bps ~ kappa_hat + C(country)",
        "(3) Sector FE": "spread_bps ~ kappa_hat + C(sector)",
        "(4) Two-way FE":"spread_bps ~ kappa_hat + C(country) + C(sector)",
    }
    full_controls = ("vix" in df.columns and "oil_price" in df.columns)
    if full_controls:
        specs["(5) Full"] = (
            "spread_bps ~ kappa_hat + C(country) + C(sector) "
            "+ rating_code + log_maturity + vix + oil_price"
        )

    for name, formula in specs.items():
        try:
            res = smf.ols(formula, data=df.dropna()).fit(
                cov_type="HC3"   # heteroskedasticity-robust SEs
            )
            models[name] = res
            beta  = res.params.get("kappa_hat", np.nan)
            se    = res.bse.get("kappa_hat", np.nan)
            tstat = res.tvalues.get("kappa_hat", np.nan)
            print(f"[panel_regression] {name}: β(κ̂) = {beta:.4f} "
                  f"(SE={se:.4f}, t={tstat:.2f}, R²={res.rsquared:.3f})")
        except Exception as e:
            print(f"[panel_regression] {name} failed: {e}")

    return models


# ══════════════════════════════════════════════════════════════════════════════
# 8.  VISUALISATION
# ══════════════════════════════════════════════════════════════════════════════

COUNTRY_LABELS = {
    "SA": "Saudi Arabia", "AE": "UAE", "QA": "Qatar",
    "BH": "Bahrain",      "MY": "Malaysia", "ID": "Indonesia",
    "KW": "Kuwait",
}
COUNTRY_COLORS = {
    "SA": "#006C35",  # Saudi green
    "AE": "#FF0000",  # UAE red
    "QA": "#8D1B3D",  # Qatar maroon
    "BH": "#CE1126",  # Bahrain red
    "MY": "#CC0001",  # Malaysia red
    "ID": "#E70011",  # Indonesia red
    "KW": "#007A3D",  # Kuwait green
}


def plot_kappa_curves(df: pd.DataFrame, nss_params: pd.DataFrame,
                      output_dir: str = "results/figures") -> None:
    """
    Figure 2: κ-yield curves per country (NSS fit + scatter of κ̂ points).
    Figure 3: GCC aggregate vs. Malaysia aggregate comparison.
    """
    if not HAS_MPL:
        return
    os.makedirs(output_dir, exist_ok=True)
    T_grid = np.linspace(0.5, 30, 300)

    # ── Figure 2: individual country curves ──────────────────────────────────
    countries = df["country"].unique()
    n_cols = min(3, len(countries))
    n_rows = int(np.ceil(len(countries) / n_cols))
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(5 * n_cols, 4 * n_rows),
                             squeeze=False)
    fig.suptitle(r"$\hat{\kappa}$-Yield Curves by Country", fontsize=14, y=1.01)

    for ax, country in zip(axes.flat, countries):
        c_data  = df[df["country"] == country]
        c_label = COUNTRY_LABELS.get(country, country)
        color   = COUNTRY_COLORS.get(country, "#333333")

        ax.scatter(c_data["maturity_years"], c_data["kappa_pct"],
                   alpha=0.25, s=10, color=color, label="κ̂ obs.")

        # Overlay most recent NSS fit
        if nss_params is not None and "country" in nss_params.columns:
            c_nss = nss_params[nss_params["country"] == country]
            if len(c_nss):
                p = c_nss.sort_values("obs_date").iloc[-1]
                kappa_nss = nss_curve(T_grid, p.beta0, p.beta1,
                                      p.beta2, p.beta3, p.tau1, p.tau2)
                ax.plot(T_grid, kappa_nss * 100, color=color, lw=2,
                        label="NSS fit (latest)")

        ax.set_title(c_label, fontsize=11)
        ax.set_xlabel("Maturity (years)")
        ax.set_ylabel(r"$\hat{\kappa}$ (% p.a.)")
        ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=2))
        ax.legend(fontsize=8, frameon=False)
        ax.grid(alpha=0.3)

    for ax in axes.flat[len(countries):]:
        ax.set_visible(False)

    plt.tight_layout()
    path2 = os.path.join(output_dir, "fig2_kappa_curves_by_country.pdf")
    plt.savefig(path2, bbox_inches="tight")
    plt.close()
    print(f"[plot] Saved {path2}")

    # ── Figure 3: GCC vs. Malaysia aggregate ─────────────────────────────────
    gccc = ["SA", "AE", "QA", "BH", "KW"]
    sea  = ["MY", "ID"]

    fig3, ax3 = plt.subplots(figsize=(7, 4))
    for group, label, color in [
        (gccc, "GCC Aggregate",     "#006C35"),
        (sea,  "Malaysia/Indonesia", "#CC0001"),
    ]:
        g_data = df[df["country"].isin(group)]
        if len(g_data) == 0:
            continue
        # Mean κ̂ per maturity bucket
        g_data = g_data.copy()
        g_data["mat_bucket"] = pd.cut(g_data["maturity_years"],
                                       bins=[0,2,4,7,12,20,35],
                                       labels=[1.5,3,5.5,9.5,16,25])
        mean_k = g_data.groupby("mat_bucket")["kappa_pct"].mean()
        ax3.plot(mean_k.index.astype(float), mean_k.values, "o-",
                 color=color, lw=2.5, ms=6, label=label)

    ax3.set_xlabel("Maturity (years)", fontsize=12)
    ax3.set_ylabel(r"Mean $\hat{\kappa}$ (% p.a.)", fontsize=12)
    ax3.set_title(r"$\hat{\kappa}$-Yield Curve: GCC vs.\ Malaysia/Indonesia",
                  fontsize=13)
    ax3.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=2))
    ax3.legend(fontsize=11, frameon=False)
    ax3.grid(alpha=0.3)
    plt.tight_layout()
    path3 = os.path.join(output_dir, "fig3_gcc_vs_malaysia.pdf")
    plt.savefig(path3, bbox_inches="tight")
    plt.close()
    print(f"[plot] Saved {path3}")


def plot_kappa_timeseries(df: pd.DataFrame, output_dir: str = "results/figures") -> None:
    """Figure 4: Time series of mean κ̂ by country group."""
    if not HAS_MPL:
        return
    os.makedirs(output_dir, exist_ok=True)
    df = df.copy()
    df["year_month"] = df["obs_date"].dt.to_period("M")
    ts = df.groupby(["year_month", "country"])["kappa_pct"].mean().reset_index()

    fig, ax = plt.subplots(figsize=(10, 4))
    for country in ts["country"].unique():
        c_ts   = ts[ts["country"] == country].sort_values("year_month")
        color  = COUNTRY_COLORS.get(country, "#aaaaaa")
        label  = COUNTRY_LABELS.get(country, country)
        ax.plot(c_ts["year_month"].dt.to_timestamp(), c_ts["kappa_pct"],
                lw=1.5, color=color, label=label, alpha=0.85)

    ax.axvspan(pd.Timestamp("2014-06-01"), pd.Timestamp("2022-07-01"),
               alpha=0.08, color="blue", label="ECB negative rate era")
    ax.axvspan(pd.Timestamp("2020-01-01"), pd.Timestamp("2020-09-01"),
               alpha=0.10, color="red", label="COVID-19 shock")
    ax.set_xlabel("Date")
    ax.set_ylabel(r"Mean $\hat{\kappa}$ (% p.a.)")
    ax.set_title(r"Time Series of $\hat{\kappa}$ by Country (2010–2025)")
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=2))
    ax.legend(fontsize=8, ncol=3, frameon=False)
    ax.grid(alpha=0.3)
    plt.tight_layout()
    path = os.path.join(output_dir, "fig1_kappa_timeseries.pdf")
    plt.savefig(path, bbox_inches="tight")
    plt.close()
    print(f"[plot] Saved {path}")


def plot_robustness_delta(df_base: pd.DataFrame,
                          output_dir: str = "results/figures") -> None:
    """Figure 5: κ̂ sensitivity to recovery rate δ ∈ {0.20, 0.40, 0.60, 0.80}."""
    if not HAS_MPL:
        return
    os.makedirs(output_dir, exist_ok=True)
    fig, ax = plt.subplots(figsize=(7, 4))
    deltas = [0.20, 0.40, 0.60, 0.80]
    colors = ["#003f5c", "#2f9e44", "#f08c00", "#e03131"]
    for delta, color in zip(deltas, colors):
        df_d = extract_kappa(df_base, delta=delta)
        # Mean κ̂ per maturity bucket
        df_d["mat_bucket"] = pd.cut(df_d["maturity_years"],
                                     bins=[0,2,4,7,12,20,35],
                                     labels=[1.5,3,5.5,9.5,16,25])
        mean_k = df_d.groupby("mat_bucket")["kappa_pct"].mean()
        ax.plot(mean_k.index.astype(float), mean_k.values, "o-",
                lw=2, color=color, label=f"δ = {delta:.2f}")
    ax.set_xlabel("Maturity (years)", fontsize=12)
    ax.set_ylabel(r"Mean $\hat{\kappa}$ (% p.a.)", fontsize=12)
    ax.set_title(r"Robustness: $\hat{\kappa}$ Across Recovery Rate Assumptions")
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=2))
    ax.legend(fontsize=11, frameon=False)
    ax.grid(alpha=0.3)
    plt.tight_layout()
    path = os.path.join(output_dir, "fig5_robustness_delta.pdf")
    plt.savefig(path, bbox_inches="tight")
    plt.close()
    print(f"[plot] Saved {path}")


# ══════════════════════════════════════════════════════════════════════════════
# 9.  LATEX TABLE EXPORT
# ══════════════════════════════════════════════════════════════════════════════

def _fmt(v, decimals=3):
    if v is None or (isinstance(v, float) and np.isnan(v)):
        return "---"
    return f"{v:.{decimals}f}"


def export_table1_summary(df: pd.DataFrame, path: str) -> None:
    """Table 1: Descriptive statistics of sukuk panel."""
    rows = []
    for country, grp in df.groupby("country"):
        rows.append({
            "Country": COUNTRY_LABELS.get(country, country),
            "N":       len(grp),
            "Sukuk":   grp["sukuk_id"].nunique(),
            "Mean S (bps)":  _fmt(grp["spread_bps"].mean(), 1),
            "Std S (bps)":   _fmt(grp["spread_bps"].std(), 1),
            "Min S":         _fmt(grp["spread_bps"].min(), 0),
            "Max S":         _fmt(grp["spread_bps"].max(), 0),
            "Mean Mat (yr)": _fmt(grp["maturity_years"].mean(), 1),
            r"\% Sov.":      f"{(grp['sector']=='sovereign').mean()*100:.0f}\\%",
        })
    tbl_df = pd.DataFrame(rows)
    with open(path, "w") as f:
        f.write("% Table 1: Sukuk Panel Descriptive Statistics\n")
        f.write("% Auto-generated by kappa_pipeline.py\n")
        f.write("\\begin{table}[t]\n\\centering\n")
        f.write("\\caption{Sukuk Panel: Descriptive Statistics by Country.}\n")
        f.write("\\label{tab:descriptive}\n")
        f.write("\\small\n")
        f.write("\\begin{tabular}{lrrrrrrrrr}\n\\toprule\n")
        f.write(" & ".join(tbl_df.columns) + " \\\\\n\\midrule\n")
        for _, row in tbl_df.iterrows():
            f.write(" & ".join(str(v) for v in row) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n\\end{table}\n")
    print(f"[export] Saved {path}")


def export_table2_kappa_cross(df: pd.DataFrame, path: str) -> None:
    """Table 2: Mean κ̂ by country × maturity bucket."""
    df = df.copy()
    buckets = [(1, 3, "1–3y"), (3, 7, "3–7y"), (7, 12, "7–12y"),
               (12, 20, "12–20y"), (20, 35, "20y+")]
    rows = []
    for country, grp in df.groupby("country"):
        row = {"Country": COUNTRY_LABELS.get(country, country)}
        for lo, hi, label in buckets:
            sub = grp[(grp["maturity_years"] >= lo) & (grp["maturity_years"] < hi)]
            row[label] = _fmt(sub["kappa_pct"].mean(), 2) if len(sub) else "---"
        row["Overall"] = _fmt(grp["kappa_pct"].mean(), 2)
        rows.append(row)
    tbl_df = pd.DataFrame(rows)
    with open(path, "w") as f:
        f.write("% Table 2: κ̂ Estimates by Country and Maturity Bucket\n")
        f.write("% Auto-generated by kappa_pipeline.py\n")
        f.write("\\begin{table}[t]\n\\centering\n")
        f.write("\\caption{Mean $\\hat{\\kappa}$ (\\%, p.a.) by Country and Maturity.}\n")
        f.write("\\label{tab:kappa_cross}\n")
        f.write("\\small\n")
        f.write("\\begin{tabular}{lrrrrrrr}\n\\toprule\n")
        f.write("Country & 1--3y & 3--7y & 7--12y & 12--20y & 20y+ & Overall \\\\\n")
        f.write("\\midrule\n")
        for _, row in tbl_df.iterrows():
            vals = [row["Country"]] + [row[c[2]] for c in buckets] + [row["Overall"]]
            f.write(" & ".join(str(v) for v in vals) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n\\end{table}\n")
    print(f"[export] Saved {path}")


def export_table_cir(cir_results: Dict[str, Dict], path: str) -> None:
    """Table 6: CIR GMM estimates by country."""
    with open(path, "w") as f:
        f.write("% Table 6: CIR GMM Parameter Estimates\n")
        f.write("% Auto-generated by kappa_pipeline.py\n")
        f.write("\\begin{table}[t]\n\\centering\n")
        f.write("\\caption{CIR Dynamics of $\\hat{\\kappa}$: GMM Estimates.}\n")
        f.write("\\label{tab:cir_gmm}\n")
        f.write("\\small\n")
        f.write("\\begin{tabular}{lrrrrrr}\n\\toprule\n")
        f.write("Country & $\\hat{\\alpha}$ & $\\hat{\\bar{\\kappa}}$ & "
                "$\\hat{\\nu}$ & Half-life (mo.) & Feller & $J$-stat \\\\\n")
        f.write("\\midrule\n")
        for country, res in cir_results.items():
            if "error" in res:
                continue
            label = COUNTRY_LABELS.get(country, country)
            feller = "Yes" if res["feller_ok"] else "No"
            hl = f"{res['half_life_months']:.1f}" if np.isfinite(res["half_life_months"]) else "$\\infty$"
            f.write(
                f"{label} & {_fmt(res['alpha'])} & {_fmt(res['kbar']*100)}\\% & "
                f"{_fmt(res['nu'])} & {hl} & {feller} & {_fmt(res['j_stat'],2)} \\\\\n"
            )
        f.write("\\bottomrule\n\\end{tabular}\n\\end{table}\n")
    print(f"[export] Saved {path}")


# ══════════════════════════════════════════════════════════════════════════════
# 10.  SYNTHETIC DEMO DATA  (--demo flag)
# ══════════════════════════════════════════════════════════════════════════════

def generate_demo_data(seed: int = 42) -> pd.DataFrame:
    """
    Generate synthetic sukuk panel matching the expected CSV format.
    Used to verify the pipeline runs end-to-end before Bloomberg data arrives.

    CIR ground truth: α=2.5, κ̄=0.035 (3.5% p.a.), ν=0.08, δ=0.40
    Spread = κ × (1−δ) × 10_000 bps + noise
    """
    rng = np.random.default_rng(seed)
    countries   = ["SA", "AE", "QA", "MY", "ID"]
    sectors     = {"SA": "sovereign", "AE": "sovereign",
                   "QA": "sovereign", "MY": "sovereign", "ID": "sovereign"}
    ratings     = {"SA": "A1", "AE": "Aa3", "QA": "Aa3", "MY": "A3", "ID": "Baa2"}
    maturities  = [2, 3, 5, 7, 10, 15, 20]
    dates       = pd.date_range("2014-01-01", "2025-01-01", freq="Q")

    # Simulate CIR path for each country
    alpha, kbar, nu, h = 2.5, 0.035, 0.08, 1/4   # quarterly step
    records = []
    for country in countries:
        kappa = kbar
        delta = 0.60 if sectors[country] == "sovereign" else 0.40
        for t, obs_date in enumerate(dates):
            kappa = max(kappa + alpha * h * (kbar - kappa)
                        + nu * np.sqrt(max(kappa, 1e-6) * h) * rng.normal(),
                        0.005)
            for mat in maturities:
                # Term structure: κ(T) slightly increasing with T
                kappa_T = kappa * (1 + 0.05 * np.log(mat))
                spread_bps = kappa_T * (1 - delta) * 10_000 + rng.normal(0, 3)
                records.append({
                    "sukuk_id":      f"{country}-{mat}Y",
                    "country":       country,
                    "sector":        sectors[country],
                    "issue_date":    obs_date - pd.DateOffset(years=2),
                    "maturity_date": obs_date + pd.DateOffset(years=mat),
                    "maturity_years": float(mat),
                    "obs_date":      obs_date,
                    "yield_pct":     spread_bps / 100 + 2.5,
                    "sofr_pct":      2.5 + rng.normal(0, 0.2),
                    "spread_bps":    max(spread_bps, 1.0),
                    "rating":        ratings[country],
                    "currency":      "USD",
                })
    df = pd.DataFrame(records)
    print(f"[demo] Generated {len(df):,} synthetic observations.")
    return df


# ══════════════════════════════════════════════════════════════════════════════
# 11.  MAIN ENTRY POINT
# ══════════════════════════════════════════════════════════════════════════════

def run_pipeline(df: pd.DataFrame, output_dir: str = "results",
                 delta: Optional[float] = None) -> None:
    os.makedirs(output_dir, exist_ok=True)
    fig_dir = os.path.join(output_dir, "figures")
    tab_dir = os.path.join(output_dir, "tables")
    os.makedirs(fig_dir, exist_ok=True)
    os.makedirs(tab_dir, exist_ok=True)

    # ── Step 1: κ extraction ─────────────────────────────────────────────────
    print("\n=== Step 1: κ Extraction ===")
    df = extract_kappa(df, delta=delta)

    # ── Step 2: NSS curve fitting ────────────────────────────────────────────
    print("\n=== Step 2: NSS Curve Fitting ===")
    nss_df = fit_nss_panel(df)
    nss_df.to_csv(os.path.join(output_dir, "nss_params.csv"), index=False)

    # ── Step 3: CIR dynamics ─────────────────────────────────────────────────
    print("\n=== Step 3: CIR Dynamics (GMM) ===")
    cir_results = {}
    for country, grp in df.groupby("country"):
        ts = grp.groupby("obs_date")["kappa_hat"].mean().sort_index().values
        print(f"  Fitting CIR for {COUNTRY_LABELS.get(country, country)} "
              f"(T={len(ts)})...")
        cir_results[country] = fit_cir(ts)
        r = cir_results[country]
        if "error" not in r:
            print(f"    α={r['alpha']:.3f}  κ̄={r['kbar']*100:.2f}%  "
                  f"ν={r['nu']:.4f}  half-life={r['half_life_months']:.1f}mo  "
                  f"Feller={'✓' if r['feller_ok'] else '✗'}")

    # ── Step 4: Horse race ───────────────────────────────────────────────────
    print("\n=== Step 4: Horse Race — κ vs. SOFR ===")
    hr = horse_race(df)
    print(hr.to_string(index=False))
    hr.to_csv(os.path.join(output_dir, "horse_race.csv"), index=False)

    # ── Step 5: Panel regression ─────────────────────────────────────────────
    print("\n=== Step 5: Panel Regressions ===")
    models = panel_regression(df)

    # ── Step 6: Figures ──────────────────────────────────────────────────────
    print("\n=== Step 6: Figures ===")
    plot_kappa_timeseries(df, fig_dir)
    plot_kappa_curves(df, nss_df, fig_dir)
    plot_robustness_delta(df, fig_dir)

    # ── Step 7: LaTeX tables ─────────────────────────────────────────────────
    print("\n=== Step 7: LaTeX Tables ===")
    export_table1_summary(df, os.path.join(tab_dir, "table1_descriptive.tex"))
    export_table2_kappa_cross(df, os.path.join(tab_dir, "table2_kappa_cross.tex"))
    export_table_cir(cir_results, os.path.join(tab_dir, "table6_cir_gmm.tex"))

    print(f"\n✓ Pipeline complete. Results in: {output_dir}/")


def main():
    parser = argparse.ArgumentParser(description="κ-Yield Curve Estimation Pipeline")
    parser.add_argument("--data",   help="Path to sukuk panel CSV")
    parser.add_argument("--delta",  type=float, default=None,
                        help="Override recovery rate (0–1). Default: rating-based.")
    parser.add_argument("--output", default="results",
                        help="Output directory (default: results/)")
    parser.add_argument("--demo",   action="store_true",
                        help="Run on synthetic demo data (no Bloomberg needed)")
    args = parser.parse_args()

    if args.demo:
        df = generate_demo_data()
    elif args.data:
        df = load_data(args.data)
    else:
        print("Error: provide --data <path> or --demo")
        sys.exit(1)

    run_pipeline(df, output_dir=args.output, delta=args.delta)


if __name__ == "__main__":
    main()
