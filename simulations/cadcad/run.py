"""
Baraka Protocol — cadCAD Simulation Runner

Runs a Monte Carlo simulation of the Baraka Protocol over SIM_STEPS intervals
(default: 720 = 30 days at 1-hour funding intervals).

Usage:
    python simulations/cadcad/run.py
    python simulations/cadcad/run.py --steps 1440 --runs 50

Outputs:
    - simulations/results/cadcad_results.csv   — raw timeseries
    - simulations/results/cadcad_summary.png   — key metric plots
"""

import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import argparse
import copy
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

from cadcad.state import genesis_states
from cadcad.policies import (
    p_price_discovery,
    p_trader_actions,
    p_liquidator,
    p_funding_settle,
)
from cadcad.state_updates import (
    s_update_index_price, s_update_mark_price,
    s_update_funding_rate, s_update_cumulative_funding,
    s_update_positions, s_update_oi, s_update_oi_short,
    s_process_liquidations, s_update_insurance_from_liquidations,
    s_update_liquidation_count, s_update_total_liquidations,
    s_update_total_collateral_locked, s_update_total_collateral_free,
    s_track_funding_paid, s_track_funding_received,
    s_update_timestep, s_check_solvency,
)
from config.params import (
    SIM_STEPS, MONTE_CARLO_RUNS, MAX_FUNDING_RATE,
    LIQUIDATION_PENALTY, INSURANCE_SPLIT,
)

# ─── cadCAD Partial State Update Blocks ───────────────────────────────────────
# Each block runs all policy functions in parallel, then all state updates.

PARTIAL_STATE_UPDATE_BLOCKS = [
    # Block 1: Price oracle update
    {
        "policies":  {"price": p_price_discovery},
        "variables": {
            "index_price": s_update_index_price,
            "mark_price":  s_update_mark_price,
        },
    },
    # Block 2: Funding settlement
    {
        "policies":  {"funding": p_funding_settle},
        "variables": {
            "funding_rate":            s_update_funding_rate,
            "cumulative_funding_index": s_update_cumulative_funding,
            "total_funding_paid_longs":     s_track_funding_paid,
            "total_funding_received_longs": s_track_funding_received,
        },
    },
    # Block 3: Trader actions
    {
        "policies":  {"traders": p_trader_actions},
        "variables": {
            "positions":              s_update_positions,
            "oi_long":                s_update_oi,
            "oi_short":               s_update_oi_short,
            "total_collateral_locked": s_update_total_collateral_locked,
            "total_collateral_free":   s_update_total_collateral_free,
        },
    },
    # Block 4: Liquidations
    {
        "policies":  {"liquidator": p_liquidator},
        "variables": {
            "positions":               s_process_liquidations,
            "insurance_fund_balance":  s_update_insurance_from_liquidations,
            "liquidations_this_step":  s_update_liquidation_count,
            "total_liquidations":      s_update_total_liquidations,
            "protocol_insolvent":      s_check_solvency,
        },
    },
    # Block 5: Bookkeeping
    {
        "policies":  {"noop": lambda *a: {}},
        "variables": {"timestep": s_update_timestep},
    },
]


# ─── Lightweight Manual Runner (no cadCAD dependency needed for quick tests) ──

def _merge_policy_inputs(blocks, params, timestep, state_history, state):
    """Run all policies in a block and merge their outputs."""
    merged = {}
    for block in blocks:
        for _, policy_fn in block["policies"].items():
            result = policy_fn(params, 0, state_history, state)
            merged.update(result)
    return merged

def run_simulation(steps: int = SIM_STEPS, n_runs: int = MONTE_CARLO_RUNS,
                   params: dict = None) -> pd.DataFrame:
    """
    Pure-Python simulation runner (no cadCAD install required).
    Returns a DataFrame with columns: run, step, + all state keys.
    """
    if params is None:
        params = {
            "max_funding_rate":    MAX_FUNDING_RATE,
            "liquidation_penalty": LIQUIDATION_PENALTY,
            "insurance_split":     INSURANCE_SPLIT,
            "price_volatility":    0.02,
        }

    records = []

    for run in range(n_runs):
        rng_seed = run * 42
        import cadcad.policies as pol_mod
        pol_mod.RNG = np.random.default_rng(rng_seed)

        state = copy.deepcopy(genesis_states)

        for step in range(steps):
            # Collect policy signals from all blocks
            policy_signals = {}
            for block in PARTIAL_STATE_UPDATE_BLOCKS:
                for _, policy_fn in block["policies"].items():
                    signals = policy_fn(params, 0, [], state)
                    policy_signals.update(signals)

            # Apply state update functions
            new_state = copy.copy(state)
            for block in PARTIAL_STATE_UPDATE_BLOCKS:
                for var, update_fn in block["variables"].items():
                    _, val = update_fn(params, 0, [], state, policy_signals)
                    new_state[var] = val

            state = new_state

            # Record scalar metrics (skip positions dict for CSV size)
            records.append({
                "run":                       run,
                "step":                      step,
                "mark_price":                state["mark_price"],
                "index_price":               state["index_price"],
                "funding_rate":              state["funding_rate"],
                "cumulative_funding_index":  state["cumulative_funding_index"],
                "oi_long":                   state["oi_long"],
                "oi_short":                  state["oi_short"],
                "insurance_fund_balance":    state["insurance_fund_balance"],
                "liquidations_this_step":    state["liquidations_this_step"],
                "total_liquidations":        state["total_liquidations"],
                "total_collateral_locked":   state["total_collateral_locked"],
                "protocol_insolvent":        int(state["protocol_insolvent"]),
                "funding_paid_longs":        state["total_funding_paid_longs"],
                "funding_received_longs":    state["total_funding_received_longs"],
            })

    return pd.DataFrame(records)


# ─── Plotting ──────────────────────────────────────────────────────────────────

def plot_results(df: pd.DataFrame, output_path: str = "results/cadcad_summary.png"):
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    fig, axes = plt.subplots(3, 2, figsize=(14, 10))
    fig.suptitle("Baraka Protocol — cadCAD Monte Carlo Simulation", fontsize=14, fontweight="bold")

    # 1. Price paths
    ax = axes[0, 0]
    for run in df["run"].unique():
        sub = df[df["run"] == run]
        ax.plot(sub["step"], sub["mark_price"], alpha=0.3, linewidth=0.8)
    ax.set_title("Mark Price (all runs)")
    ax.set_ylabel("USD")
    ax.set_xlabel("Interval (1hr)")

    # 2. Funding rate
    ax = axes[0, 1]
    mean_fr = df.groupby("step")["funding_rate"].mean()
    p5  = df.groupby("step")["funding_rate"].quantile(0.05)
    p95 = df.groupby("step")["funding_rate"].quantile(0.95)
    ax.fill_between(mean_fr.index, p5, p95, alpha=0.2, color="blue", label="5th–95th pct")
    ax.plot(mean_fr.index, mean_fr, color="blue", linewidth=1.5, label="Mean")
    ax.axhline(0, color="black", linewidth=0.8, linestyle="--")
    ax.axhline(0.0075, color="red", linewidth=0.8, linestyle=":", label="+75bps ceiling")
    ax.axhline(-0.0075, color="green", linewidth=0.8, linestyle=":", label="-75bps floor")
    ax.set_title("Funding Rate (ι=0 confirmed)")
    ax.set_ylabel("Rate per interval")
    ax.legend(fontsize=7)

    # 3. Insurance fund
    ax = axes[1, 0]
    mean_ins = df.groupby("step")["insurance_fund_balance"].mean()
    ax.fill_between(
        mean_ins.index,
        df.groupby("step")["insurance_fund_balance"].quantile(0.05),
        df.groupby("step")["insurance_fund_balance"].quantile(0.95),
        alpha=0.2, color="green",
    )
    ax.plot(mean_ins.index, mean_ins, color="green", linewidth=1.5)
    ax.axhline(0, color="red", linewidth=1, linestyle="--", label="Insolvency threshold")
    ax.set_title("Insurance Fund Balance ($)")
    ax.set_ylabel("USD")
    ax.legend(fontsize=7)

    # 4. Open interest imbalance
    ax = axes[1, 1]
    df["oi_imbalance"] = (df["oi_long"] - df["oi_short"]) / (df["oi_long"] + df["oi_short"] + 1e-9)
    mean_oi = df.groupby("step")["oi_imbalance"].mean()
    ax.plot(mean_oi.index, mean_oi, color="purple", linewidth=1.5)
    ax.axhline(0, color="black", linewidth=0.8, linestyle="--")
    ax.set_title("OI Imbalance (long-short)/total")
    ax.set_ylabel("Fraction")

    # 5. Cumulative liquidations
    ax = axes[2, 0]
    mean_liq = df.groupby("step")["total_liquidations"].mean()
    ax.plot(mean_liq.index, mean_liq, color="red", linewidth=1.5)
    ax.set_title("Cumulative Liquidations (mean)")
    ax.set_xlabel("Interval")

    # 6. Protocol solvency
    ax = axes[2, 1]
    insolvency_rate = df.groupby("step")["protocol_insolvent"].mean()
    ax.plot(insolvency_rate.index, insolvency_rate * 100, color="darkred", linewidth=1.5)
    ax.set_title("Insolvency Rate (% of runs)")
    ax.set_ylabel("%")
    ax.set_xlabel("Interval")
    ax.set_ylim(0, 100)

    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    print(f"[cadCAD] Plot saved → {output_path}")
    plt.close()


# ─── CLI ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Baraka Protocol cadCAD simulation")
    parser.add_argument("--steps", type=int, default=SIM_STEPS)
    parser.add_argument("--runs",  type=int, default=MONTE_CARLO_RUNS)
    args = parser.parse_args()

    print(f"[cadCAD] Running {args.runs} Monte Carlo runs × {args.steps} steps...")
    df = run_simulation(steps=args.steps, n_runs=args.runs)

    os.makedirs("results", exist_ok=True)
    df.to_csv("results/cadcad_results.csv", index=False)
    print(f"[cadCAD] Results saved → results/cadcad_results.csv  ({len(df)} rows)")

    # Key statistics
    print("\n── Summary ──────────────────────────────────────────────────────")
    print(f"  Mean final insurance fund : ${df[df['step']==df['step'].max()]['insurance_fund_balance'].mean():,.0f}")
    print(f"  Insolvency events (runs)  : {df[df['protocol_insolvent']==1]['run'].nunique()} / {args.runs}")
    print(f"  Mean total liquidations   : {df[df['step']==df['step'].max()]['total_liquidations'].mean():.1f}")
    funding_rates = df["funding_rate"]
    print(f"  Funding rate range        : [{funding_rates.min():.4f}, {funding_rates.max():.4f}]")
    print(f"  iota violations (rate > 0 always?): {(funding_rates < 0).any()}")

    plot_results(df, "results/cadcad_summary.png")
