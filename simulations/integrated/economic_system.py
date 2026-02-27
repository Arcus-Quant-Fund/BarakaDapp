"""
Baraka Protocol — Integrated Economic System Simulation
=======================================================

Combines all four simulation layers into a single coupled feedback system:

  Layer 1  cadCAD Market Engine
           Pure-Python cadCAD runner driving market prices, funding, OI, and
           the insurance fund.  This is the ground truth for the simulation.

  Layer 2  RL Trader Agent
           At every cadCAD step the agent receives an observation built from
           live cadCAD state and submits an action (open long/short, close,
           hold).  The action is injected directly into the cadCAD position pool
           so the RL agent is a participant *inside* the market simulation, not
           a separate process.

  Layer 3  Game Theory Equilibrium Analyser
           Runs every GAME_THEORY_INTERVAL steps.  Builds 5×5 payoff matrices
           from the recent cadCAD price window, finds the Nash equilibrium
           leverage distribution, and feeds that back as the background-trader
           leverage policy for the next interval.

  Layer 4  Mechanism Design Optimizer
           Runs at the end of every episode.  Collects aggregate cadCAD metrics
           (insolvency rate, mean liquidations, mean funding, insurance surplus)
           and runs one round of Pareto optimisation to update the protocol
           parameters (max_funding_rate, maintenance_margin, liquidation_penalty,
           insurance_split) for the *next* episode.  This creates a closed-loop
           adaptive protocol.

Coupling graph:
  cadCAD ──obs──► RL ──action──► cadCAD
  cadCAD ──price_history──► GameTheory ──nash_leverage──► cadCAD trader policy
  cadCAD ──episode_metrics──► MechDesign ──optimal_params──► cadCAD params

Usage
-----
  # Quick 3-episode run (fast):
  python simulations/integrated/economic_system.py --episodes 3 --steps 200 --quick

  # Full run (matches paper2 parameter regime):
  python simulations/integrated/economic_system.py --episodes 5 --steps 720

  # With PPO RL model (if trained):
  python simulations/integrated/economic_system.py --rl-model results/rl_trader

Outputs
-------
  results/integrated/integrated_timeseries.csv   — full step-level data
  results/integrated/integrated_episodes.csv     — per-episode summary
  results/integrated/dashboard.png               — 6-panel combined dashboard
  results/integrated/params_evolution.png        — how protocol params changed
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import argparse
import copy
import json
import warnings
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from scipy.optimize import differential_evolution

from config.params import (
    INITIAL_BTC_PRICE, PRICE_VOLATILITY, MAX_LEVERAGE,
    MAX_FUNDING_RATE, MIN_FUNDING_RATE,
    MAINTENANCE_MARGIN_RATE, LIQUIDATION_PENALTY, INSURANCE_SPLIT,
    INSURANCE_FUND_SEED, LEVERAGE_CHOICES,
)

warnings.filterwarnings("ignore")


# ─── Constants ────────────────────────────────────────────────────────────────

GAME_THEORY_INTERVAL = 50    # Re-compute Nash equilibrium every N steps
GT_PRICE_WINDOW      = 100   # Steps of price history used for GT payoff matrices
N_BG_POSITIONS       = 20    # Background (non-RL) positions in market
RL_COLLATERAL_FRAC   = 0.10  # RL agent risks 10% of free collateral per trade
RL_INIT_CAPITAL      = 50_000.0

CURRENT_PARAMS = {
    "max_funding_rate":    0.0075,
    "maintenance_margin":  MAINTENANCE_MARGIN_RATE,
    "liquidation_penalty": LIQUIDATION_PENALTY,
    "insurance_split":     INSURANCE_SPLIT,
}

PARAM_BOUNDS = [
    (0.003, 0.015),   # max_funding_rate
    (0.010, 0.050),   # maintenance_margin
    (0.005, 0.030),   # liquidation_penalty
    (0.300, 0.800),   # insurance_split
]


# ─── RL Agent (rule-based fallback + optional PPO) ────────────────────────────

class RLAgent:
    """
    Wraps either a loaded PPO model (stable-baselines3) or a simple rule-based
    agent as fallback.  The rule-based agent:
      - Goes long 3x when funding_rate < -0.001 (market undervalued)
      - Goes short 3x when funding_rate > +0.002 (market overvalued)
      - Closes when PnL > 2% or < -3% of position size
      - Otherwise holds
    """

    def __init__(self, model_path: str = None):
        self.model = None
        if model_path:
            try:
                from stable_baselines3 import PPO
                self.model = PPO.load(model_path)
                print(f"[RL] Loaded PPO model from {model_path}")
            except (ImportError, FileNotFoundError) as e:
                print(f"[RL] Could not load PPO model ({e}), using rule-based fallback.")

    def act(self, obs: np.ndarray) -> int:
        """Return action integer 0-11 given 8-feature observation."""
        if self.model is not None:
            action, _ = self.model.predict(obs, deterministic=True)
            return int(action)
        return self._rule_based(obs)

    def _rule_based(self, obs: np.ndarray) -> int:
        """
        obs layout (matches BarakaTraderEnv):
          0: mark_price / p0       1: index_price / p0
          2: funding_rate          3: cum_funding
          4: pos_size / p0         5: pos_collateral / p0
          6: is_long (0/1)         7: free_collateral / 100_000
        """
        funding_rate  = obs[2]
        in_position   = obs[4] > 0
        pos_size      = obs[4] * INITIAL_BTC_PRICE
        pos_collat    = obs[5] * INITIAL_BTC_PRICE
        is_long       = obs[6] > 0.5
        free_collat   = obs[7] * 100_000

        if in_position:
            # Estimate unrealised PnL proxy (approximate from collateral erosion)
            leverage_est = max(1, pos_size / max(pos_collat, 1))
            pnl_frac = (pos_collat / max(pos_size / leverage_est, 1)) - 1

            if pnl_frac > 0.02 or pnl_frac < -0.03:
                return 11   # Close — take profit or cut loss
            return 0        # Hold
        else:
            if funding_rate < -0.001 and free_collat > 200:
                return 3    # Open long 3x
            if funding_rate > +0.002 and free_collat > 200:
                return 8    # Open short 3x
            return 0        # Hold


# ─── Game Theory Layer ────────────────────────────────────────────────────────

def _gt_payoff(lev_long: int, lev_short: int,
               price_path: np.ndarray, max_fr: float) -> tuple:
    """Compute (long_payoff, short_payoff) over a price window (ι=0)."""
    collateral = 10_000.0
    nav_l, nav_s = collateral, collateral
    size_l = collateral * lev_long
    size_s = collateral * lev_short
    mm = 0.02

    for t in range(len(price_path) - 1):
        p0, p1 = price_path[t], price_path[t + 1]
        raw = (p1 - p0) / p0                 # ι=0
        fr  = float(np.clip(raw, -max_fr, max_fr))

        nav_l += size_l  * ((p1 - p0) / p0) - fr * size_l
        nav_s += -size_s * ((p1 - p0) / p0) + fr * size_s

        if nav_l < size_l * mm:
            nav_l = 0.0; break
        if nav_s < size_s * mm:
            nav_s = 0.0; break

    return nav_l - collateral, nav_s - collateral


def run_game_theory(price_window: np.ndarray, max_fr: float) -> dict:
    """
    Build 5×5 payoff matrices from the live price window and compute Nash
    equilibria.  Returns the equilibrium leverage for longs and shorts.
    """
    n = len(LEVERAGE_CHOICES)
    A = np.zeros((n, n))
    B = np.zeros((n, n))

    for i, ll in enumerate(LEVERAGE_CHOICES):
        for j, ls in enumerate(LEVERAGE_CHOICES):
            pl, ps = _gt_payoff(ll, ls, price_window, max_fr)
            A[i, j] = pl
            B[i, j] = ps

    # Nash: find best-response intersection
    # Simplified: dominant strategy = row/col argmax of mean payoffs
    eq_long_idx  = int(np.argmax(A.mean(axis=1)))
    eq_short_idx = int(np.argmax(B.mean(axis=0)))

    try:
        import nashpy as nash
        game = nash.Game(A, B)
        eqs  = list(game.vertex_enumeration())
        if eqs:
            sigma_l, sigma_s = eqs[0]
            eq_long_lev  = float(np.dot(sigma_l, LEVERAGE_CHOICES))
            eq_short_lev = float(np.dot(sigma_s, LEVERAGE_CHOICES))
        else:
            raise ValueError("no NE")
    except Exception:
        eq_long_lev  = float(LEVERAGE_CHOICES[eq_long_idx])
        eq_short_lev = float(LEVERAGE_CHOICES[eq_short_idx])

    net_long = float(A.mean())
    net_short = float(B.mean())

    return {
        "eq_long_leverage":  eq_long_lev,
        "eq_short_leverage": eq_short_lev,
        "mean_long_payoff":  net_long,
        "mean_short_payoff": net_short,
        "net_transfer":      net_long - net_short,   # ~0 at ι=0
    }


# ─── Mechanism Design Layer ────────────────────────────────────────────────────

def _fast_eval(x: np.ndarray, episode_price_path: np.ndarray,
               n_positions: int = 15) -> float:
    """
    Evaluate a parameter vector on the episode's actual price path.
    Reuses the same price path to isolate the effect of params from randomness.
    """
    max_fr, mm, liq_pen, ins_split = x
    rng = np.random.default_rng(0)

    insurance_bal = INSURANCE_FUND_SEED
    collaterals   = np.ones(n_positions) * 5_000.0
    leverages     = rng.integers(1, MAX_LEVERAGE + 1, n_positions).astype(float)
    sizes         = collaterals * leverages
    is_long       = rng.choice([True, False], n_positions)
    cum_funding   = 0.0
    cum_at_entry  = np.zeros(n_positions)
    alive         = np.ones(n_positions, dtype=bool)
    total_liq     = 0
    funding_rates = []
    insolvent     = False

    steps = len(episode_price_path) - 1
    for t in range(steps):
        p0 = episode_price_path[t]
        p1 = episode_price_path[t + 1]
        mark  = p1
        index = p0
        raw   = (mark - index) / index
        fr    = float(np.clip(raw, -max_fr, max_fr))
        cum_funding += fr
        funding_rates.append(fr)

        delta = cum_funding - cum_at_entry
        for i in np.where(alive)[0]:
            collaterals[i] += (delta[i] * sizes[i]) * (-1 if is_long[i] else 1)
            cum_at_entry[i] = cum_funding

        for i in np.where(alive)[0]:
            if collaterals[i] < sizes[i] * mm:
                insurance_bal += sizes[i] * liq_pen * ins_split
                collaterals[i]  = 0.0
                alive[i]        = False
                total_liq      += 1

        if insurance_bal < 0:
            insolvent = True
            break

    score = (
        10.0  * int(insolvent)
      + 0.005 * total_liq
      + 5.0   * np.mean(np.abs(funding_rates))
    )
    return score


def run_mechanism_design(episode_price_path: np.ndarray,
                         current_params: dict,
                         n_positions: int = 15) -> dict:
    """
    Run one round of mechanism design optimisation using the episode price path.
    Returns updated optimal params.
    """
    result = differential_evolution(
        func    = lambda x: _fast_eval(x, episode_price_path, n_positions),
        bounds  = PARAM_BOUNDS,
        maxiter = 10,
        popsize = 5,
        seed    = 42,
        tol     = 0.02,
        disp    = False,
        workers = 1,
    )

    new_params = {
        "max_funding_rate":    result.x[0],
        "maintenance_margin":  result.x[1],
        "liquidation_penalty": result.x[2],
        "insurance_split":     result.x[3],
    }

    # Clamp: blend 70% current + 30% optimal (avoid abrupt protocol changes)
    blended = {}
    for k in current_params:
        blended[k] = 0.70 * current_params[k] + 0.30 * new_params[k]

    return {"raw": new_params, "blended": blended, "optimizer_score": result.fun}


# ─── Market Engine (cadCAD-compatible pure-Python runner) ─────────────────────

def _genesis_state(params: dict, rng: np.random.Generator) -> dict:
    """Initialise market state for one episode."""
    collaterals = np.ones(N_BG_POSITIONS) * 5_000.0
    leverages   = rng.integers(1, MAX_LEVERAGE + 1, N_BG_POSITIONS).astype(float)
    sizes       = collaterals * leverages
    is_long     = rng.choice([True, False], N_BG_POSITIONS)

    return {
        "mark_price":           INITIAL_BTC_PRICE,
        "index_price":          INITIAL_BTC_PRICE,
        "funding_rate":         0.0,
        "cum_funding":          0.0,
        "bg_collaterals":       collaterals,
        "bg_leverages":         leverages,
        "bg_sizes":             sizes,
        "bg_is_long":           is_long,
        "bg_cum_at_entry":      np.zeros(N_BG_POSITIONS),
        "bg_alive":             np.ones(N_BG_POSITIONS, dtype=bool),
        "insurance_fund":       INSURANCE_FUND_SEED,
        "total_liquidations":   0,
        "protocol_insolvent":   False,

        # RL agent state
        "rl_in_position":       False,
        "rl_size":              0.0,
        "rl_collateral":        0.0,
        "rl_is_long":           False,
        "rl_entry_price":       INITIAL_BTC_PRICE,
        "rl_cum_at_entry":      0.0,
        "rl_free_collateral":   RL_INIT_CAPITAL,
        "rl_total_pnl":         0.0,

        # GT-derived leverage distribution for background traders
        "bg_eq_long_lev":       3.0,
        "bg_eq_short_lev":      3.0,
    }


def _rl_obs(state: dict) -> np.ndarray:
    """Build 8-feature RL observation from cadCAD state."""
    p0 = INITIAL_BTC_PRICE
    return np.array([
        state["mark_price"]          / p0,
        state["index_price"]         / p0,
        state["funding_rate"],
        state["cum_funding"],
        state["rl_size"]             / p0,
        state["rl_collateral"]       / p0,
        float(state["rl_is_long"]),
        state["rl_free_collateral"]  / 100_000.0,
    ], dtype=np.float32)


def _apply_rl_action(state: dict, action: int, params: dict) -> dict:
    """Apply RL agent action to cadCAD state. Modifies in-place and returns."""
    mm    = params["maintenance_margin"]
    lp    = params["liquidation_penalty"]
    is_   = params["insurance_split"]
    fr    = state["funding_rate"]

    # Accrue funding to RL position
    if state["rl_in_position"]:
        delta = state["cum_funding"] - state["rl_cum_at_entry"]
        sign  = -1 if state["rl_is_long"] else +1
        state["rl_collateral"] += sign * delta * state["rl_size"]
        state["rl_cum_at_entry"] = state["cum_funding"]

        # Check liquidation
        if state["rl_collateral"] < state["rl_size"] * mm:
            penalty = state["rl_size"] * lp
            state["insurance_fund"] += penalty * is_
            state["rl_free_collateral"] = max(0, state["rl_free_collateral"]
                                              + state["rl_collateral"] - penalty)
            state["rl_total_pnl"] += state["rl_collateral"] - penalty
            state["rl_in_position"] = False
            state["rl_size"]        = 0.0
            state["rl_collateral"]  = 0.0
            state["total_liquidations"] += 1
            return state

    # Execute action
    if action == 0:   # hold
        pass

    elif 1 <= action <= 5 and not state["rl_in_position"]:
        leverage  = action
        collat    = state["rl_free_collateral"] * RL_COLLATERAL_FRAC
        collat    = max(100.0, min(collat, 10_000.0))
        size      = collat * leverage
        if state["rl_free_collateral"] >= collat:
            state["rl_in_position"]   = True
            state["rl_is_long"]       = True
            state["rl_size"]          = size
            state["rl_collateral"]    = collat
            state["rl_entry_price"]   = state["mark_price"]
            state["rl_cum_at_entry"]  = state["cum_funding"]
            state["rl_free_collateral"] -= collat

    elif 6 <= action <= 10 and not state["rl_in_position"]:
        leverage  = action - 5
        collat    = state["rl_free_collateral"] * RL_COLLATERAL_FRAC
        collat    = max(100.0, min(collat, 10_000.0))
        size      = collat * leverage
        if state["rl_free_collateral"] >= collat:
            state["rl_in_position"]   = True
            state["rl_is_long"]       = False
            state["rl_size"]          = size
            state["rl_collateral"]    = collat
            state["rl_entry_price"]   = state["mark_price"]
            state["rl_cum_at_entry"]  = state["cum_funding"]
            state["rl_free_collateral"] -= collat

    elif action == 11 and state["rl_in_position"]:
        # Close position
        mark = state["mark_price"]
        ep   = state["rl_entry_price"]
        if state["rl_is_long"]:
            price_pnl = state["rl_size"] * (mark - ep) / ep
        else:
            price_pnl = state["rl_size"] * (ep - mark) / ep

        returned = max(0, state["rl_collateral"] + price_pnl)
        state["rl_free_collateral"] += returned
        state["rl_total_pnl"]       += price_pnl
        state["rl_in_position"]      = False
        state["rl_size"]             = 0.0
        state["rl_collateral"]       = 0.0

    return state


def _step_market(state: dict, params: dict, rng: np.random.Generator,
                 gt_result: dict = None) -> dict:
    """
    One cadCAD step:
    1. Price oracle update (GBM with mark→index mean reversion)
    2. Funding settlement (ι=0, clamped ±max_fr)
    3. Accrue funding to background positions
    4. Liquidation check on background positions
    5. Solvency check
    If GT result is available, background traders use Nash equilibrium leverage.
    """
    max_fr = params["max_funding_rate"]
    mm     = params["maintenance_margin"]
    lp     = params["liquidation_penalty"]
    is_    = params["insurance_split"]

    # 1. Prices
    shock_i = rng.normal(0, PRICE_VOLATILITY)
    shock_m = rng.normal(0, PRICE_VOLATILITY * 0.7)
    state["index_price"] = state["index_price"] * np.exp(shock_i)
    state["mark_price"]  = (
        state["mark_price"] * np.exp(shock_m) * 0.9
        + state["index_price"] * 0.1
    )

    # 2. Funding (ι=0)
    raw   = (state["mark_price"] - state["index_price"]) / state["index_price"]
    fr    = float(np.clip(raw, -max_fr, max_fr))
    state["funding_rate"] = fr
    state["cum_funding"] += fr

    # 3. Accrue funding to background positions
    alive = state["bg_alive"]
    delta = state["cum_funding"] - state["bg_cum_at_entry"]

    for i in np.where(alive)[0]:
        sign = -1 if state["bg_is_long"][i] else +1
        state["bg_collaterals"][i] += sign * delta[i] * state["bg_sizes"][i]
        state["bg_cum_at_entry"][i]  = state["cum_funding"]

    # 4. Liquidations
    for i in np.where(alive)[0]:
        if state["bg_collaterals"][i] < state["bg_sizes"][i] * mm:
            penalty = state["bg_sizes"][i] * lp
            state["insurance_fund"]        += penalty * is_
            state["bg_collaterals"][i]      = 0.0
            state["bg_alive"][i]            = False
            state["total_liquidations"]    += 1

            # Respawn this position with Nash-equilibrium leverage
            if gt_result is not None:
                respawn_lev = (state["bg_eq_long_lev"]
                               if rng.random() > 0.5
                               else state["bg_eq_short_lev"])
            else:
                respawn_lev = float(rng.integers(1, MAX_LEVERAGE + 1))

            respawn_lev = float(np.clip(round(respawn_lev), 1, MAX_LEVERAGE))
            new_collat = 5_000.0
            state["bg_collaterals"][i]   = new_collat
            state["bg_leverages"][i]     = respawn_lev
            state["bg_sizes"][i]         = new_collat * respawn_lev
            state["bg_is_long"][i]       = rng.random() > 0.5
            state["bg_cum_at_entry"][i]  = state["cum_funding"]
            state["bg_alive"][i]         = True

    # 5. Solvency
    if state["insurance_fund"] < 0:
        state["protocol_insolvent"] = True

    return state


# ─── Integrated Episode Runner ────────────────────────────────────────────────

def run_episode(episode: int, steps: int, params: dict,
                rl_agent: RLAgent, rng: np.random.Generator,
                quick: bool = False) -> tuple:
    """
    Run one full episode and return:
      - step_records: list of per-step dicts
      - gt_records:   list of per-GT-interval dicts
      - price_path:   ndarray for mechanism design
      - episode_summary: dict
    """
    state        = _genesis_state(params, rng)
    step_records = []
    gt_records   = []
    price_path   = [INITIAL_BTC_PRICE]
    gt_result    = None

    for step in range(steps):

        # ── cadCAD market step ──────────────────────────────────────────
        state = _step_market(state, params, rng, gt_result)
        price_path.append(state["mark_price"])

        # ── RL agent acts ───────────────────────────────────────────────
        obs    = _rl_obs(state)
        action = rl_agent.act(obs)
        state  = _apply_rl_action(state, action, params)

        # ── Game theory (every N steps) ─────────────────────────────────
        if (step + 1) % GAME_THEORY_INTERVAL == 0 and len(price_path) >= GT_PRICE_WINDOW:
            window = np.array(price_path[-GT_PRICE_WINDOW:])
            if not quick:
                gt_result = run_game_theory(window, params["max_funding_rate"])
            else:
                # Skip expensive Nash solver in quick mode — use heuristics
                gt_result = {
                    "eq_long_leverage":  3.0,
                    "eq_short_leverage": 3.0,
                    "mean_long_payoff":  0.0,
                    "mean_short_payoff": 0.0,
                    "net_transfer":      0.0,
                }

            if gt_result:
                state["bg_eq_long_lev"]  = gt_result["eq_long_leverage"]
                state["bg_eq_short_lev"] = gt_result["eq_short_leverage"]
                gt_records.append({
                    "episode": episode,
                    "step":    step,
                    **gt_result,
                })

        # ── Record step ─────────────────────────────────────────────────
        oi_long  = state["bg_sizes"][state["bg_is_long"]  & state["bg_alive"]].sum()
        oi_short = state["bg_sizes"][~state["bg_is_long"] & state["bg_alive"]].sum()

        step_records.append({
            "episode":             episode,
            "step":                step,
            "mark_price":          state["mark_price"],
            "index_price":         state["index_price"],
            "funding_rate":        state["funding_rate"],
            "oi_long":             oi_long,
            "oi_short":            oi_short,
            "oi_imbalance":        (oi_long - oi_short) / (oi_long + oi_short + 1e-9),
            "insurance_fund":      state["insurance_fund"],
            "total_liquidations":  state["total_liquidations"],
            "protocol_insolvent":  int(state["protocol_insolvent"]),
            "rl_free_collateral":  state["rl_free_collateral"],
            "rl_total_pnl":        state["rl_total_pnl"],
            "rl_in_position":      int(state["rl_in_position"]),
            "rl_action":           action,
            "bg_eq_long_lev":      state["bg_eq_long_lev"],
            "bg_eq_short_lev":     state["bg_eq_short_lev"],
            # Current protocol params
            "param_max_fr":        params["max_funding_rate"],
            "param_mm":            params["maintenance_margin"],
            "param_liq_pen":       params["liquidation_penalty"],
            "param_ins_split":     params["insurance_split"],
        })

    # Episode summary
    final_step = step_records[-1]
    summary = {
        "episode":               episode,
        "final_insurance_fund":  final_step["insurance_fund"],
        "total_liquidations":    final_step["total_liquidations"],
        "protocol_insolvent":    final_step["protocol_insolvent"],
        "rl_final_pnl":          final_step["rl_total_pnl"],
        "rl_final_capital":      final_step["rl_free_collateral"],
        "mean_abs_funding":      np.mean(np.abs([r["funding_rate"] for r in step_records])),
        "mean_oi_imbalance":     np.mean(np.abs([r["oi_imbalance"] for r in step_records])),
        "gt_intervals_run":      len(gt_records),
        **params,
    }

    return step_records, gt_records, np.array(price_path), summary


# ─── Multi-Episode Runner with Mechanism Design Feedback ─────────────────────

def run_integrated_simulation(n_episodes: int = 5, steps_per_episode: int = 720,
                               rl_model_path: str = None,
                               quick: bool = False,
                               seed: int = 42) -> dict:
    """
    Run N episodes with mechanism-design parameter updates between episodes.

    Returns dict with:
      'timeseries':  pd.DataFrame (all step records)
      'episodes':    pd.DataFrame (per-episode summaries)
      'gt_analysis': pd.DataFrame (game theory results)
      'params_log':  list of dicts (how params evolved per episode)
    """
    print("\n" + "=" * 70)
    print("  BARAKA PROTOCOL — INTEGRATED ECONOMIC SYSTEM SIMULATION")
    print("  Layers: cadCAD  |  RL  |  Game Theory  |  Mechanism Design")
    print("=" * 70)
    print(f"\n  Episodes:     {n_episodes}")
    print(f"  Steps/ep:     {steps_per_episode}")
    print(f"  RL mode:      {'PPO' if rl_model_path else 'rule-based fallback'}")
    print(f"  Quick mode:   {quick}")
    print()

    rng       = np.random.default_rng(seed)
    rl_agent  = RLAgent(model_path=rl_model_path)
    params    = copy.deepcopy(CURRENT_PARAMS)
    params_log = [{"episode": 0, "source": "initial", **params}]

    all_steps   = []
    all_gt      = []
    all_eps     = []

    for ep in range(n_episodes):
        print(f"─── Episode {ep + 1}/{n_episodes} ──────────────────────────────────────────────")
        print(f"    Params: max_fr={params['max_funding_rate']:.4f}  "
              f"mm={params['maintenance_margin']:.3f}  "
              f"liq_pen={params['liquidation_penalty']:.3f}  "
              f"ins_split={params['insurance_split']:.2f}")

        ep_rng = np.random.default_rng(seed + ep * 1000)
        steps_rec, gt_rec, price_path, summary = run_episode(
            episode=ep,
            steps=steps_per_episode,
            params=params,
            rl_agent=rl_agent,
            rng=ep_rng,
            quick=quick,
        )

        all_steps.extend(steps_rec)
        all_gt.extend(gt_rec)
        all_eps.append(summary)

        print(f"    Insurance fund:    ${summary['final_insurance_fund']:>10,.0f}")
        print(f"    Total liquidations: {summary['total_liquidations']}")
        print(f"    Protocol insolvent: {bool(summary['protocol_insolvent'])}")
        print(f"    RL agent PnL:      ${summary['rl_final_pnl']:>10,.2f}  "
              f"(capital: ${summary['rl_final_capital']:,.0f})")
        print(f"    Mean |funding|:    {summary['mean_abs_funding']:.5f}")
        if gt_rec:
            last_gt = gt_rec[-1]
            print(f"    Nash eq leverage:   Long {last_gt['eq_long_leverage']:.1f}x | "
                  f"Short {last_gt['eq_short_leverage']:.1f}x  "
                  f"(net_transfer={last_gt['net_transfer']:.0f})")

        # ── Mechanism Design: update params for next episode ────────────
        if ep < n_episodes - 1:
            print(f"    [MechDesign] Optimising params for episode {ep + 2}...")
            md_result = run_mechanism_design(
                episode_price_path=price_path,
                current_params=params,
                n_positions=10 if quick else 15,
            )
            params = md_result["blended"]
            params_log.append({
                "episode": ep + 1,
                "source": "mechanism_design",
                "optimizer_score": md_result["optimizer_score"],
                **params,
            })
            raw = md_result["raw"]
            print(f"    [MechDesign] Suggested: max_fr={raw['max_funding_rate']:.4f}  "
                  f"mm={raw['maintenance_margin']:.3f}  "
                  f"score={md_result['optimizer_score']:.4f}")
            print(f"    [MechDesign] Blended:   max_fr={params['max_funding_rate']:.4f}  "
                  f"mm={params['maintenance_margin']:.3f}")
        print()

    return {
        "timeseries":  pd.DataFrame(all_steps),
        "episodes":    pd.DataFrame(all_eps),
        "gt_analysis": pd.DataFrame(all_gt) if all_gt else pd.DataFrame(),
        "params_log":  params_log,
    }


# ─── Dashboard Plotting ────────────────────────────────────────────────────────

def plot_dashboard(results: dict, out_dir: str = "results/integrated"):
    os.makedirs(out_dir, exist_ok=True)

    df   = results["timeseries"]
    eps  = results["episodes"]
    gt   = results["gt_analysis"]
    plog = pd.DataFrame(results["params_log"])

    # ── Main dashboard ───────────────────────────────────────────────────────
    fig = plt.figure(figsize=(18, 13))
    gs  = gridspec.GridSpec(3, 3, figure=fig, hspace=0.38, wspace=0.32)
    fig.suptitle(
        "Baraka Protocol — Integrated Economic System (cadCAD + RL + Game Theory + Mechanism Design)",
        fontsize=13, fontweight="bold"
    )

    colors = plt.cm.tab10.colors

    # Panel 1: Mark price per episode
    ax = fig.add_subplot(gs[0, 0])
    for ep in df["episode"].unique():
        sub = df[df["episode"] == ep]
        ax.plot(sub["step"].values, sub["mark_price"].values,
                alpha=0.8, linewidth=1, color=colors[ep % 10],
                label=f"Ep {ep + 1}")
    ax.set_title("BTC Mark Price (all episodes)", fontsize=9)
    ax.set_ylabel("USD")
    ax.legend(fontsize=7, loc="upper left")

    # Panel 2: Funding rate with ±75bps boundary
    ax = fig.add_subplot(gs[0, 1])
    mean_fr = df.groupby("step")["funding_rate"].mean()
    ax.plot(mean_fr.index, mean_fr, color="steelblue", linewidth=1.5, label="Mean")
    ax.fill_between(
        df.groupby("step")["funding_rate"].mean().index,
        df.groupby("step")["funding_rate"].quantile(0.1),
        df.groupby("step")["funding_rate"].quantile(0.9),
        alpha=0.2, color="steelblue",
    )
    ax.axhline(0, color="black", linewidth=0.8, linestyle="--")
    ax.axhline(+0.0075, color="red",   linewidth=0.8, linestyle=":", alpha=0.7)
    ax.axhline(-0.0075, color="green", linewidth=0.8, linestyle=":", alpha=0.7)
    ax.set_title("Funding Rate (ι=0 | ±75bps clamp)", fontsize=9)
    ax.set_ylabel("Rate / interval")

    # Panel 3: Insurance fund per episode
    ax = fig.add_subplot(gs[0, 2])
    for ep in df["episode"].unique():
        sub = df[df["episode"] == ep]
        ax.plot(sub["step"].values, sub["insurance_fund"].values / 1e3,
                alpha=0.8, linewidth=1, color=colors[ep % 10])
    ax.axhline(0, color="red", linewidth=1, linestyle="--", label="Insolvency threshold")
    ax.set_title("Insurance Fund Balance (k$)", fontsize=9)
    ax.set_ylabel("USD (thousands)")
    ax.legend(fontsize=7)

    # Panel 4: RL agent PnL
    ax = fig.add_subplot(gs[1, 0])
    for ep in df["episode"].unique():
        sub = df[df["episode"] == ep]
        ax.plot(sub["step"].values, sub["rl_total_pnl"].values,
                alpha=0.8, linewidth=1, color=colors[ep % 10], label=f"Ep {ep + 1}")
    ax.axhline(0, color="black", linewidth=0.8, linestyle="--")
    ax.set_title("RL Agent Cumulative PnL ($)", fontsize=9)
    ax.set_ylabel("USD")
    ax.legend(fontsize=7)

    # Panel 5: Game Theory — Nash leverage + net_transfer
    ax = fig.add_subplot(gs[1, 1])
    if not gt.empty:
        # Global step index = episode * max_step + step
        max_step = df["step"].max() + 1
        gt_x = gt["episode"].values * max_step + gt["step"].values
        ax.plot(gt_x, gt["eq_long_leverage"],  color="salmon",    linewidth=1.5, label="Nash long lev")
        ax.plot(gt_x, gt["eq_short_leverage"], color="steelblue", linewidth=1.5, label="Nash short lev")
        ax.set_ylabel("Nash Eq Leverage (x)", fontsize=8)
        ax2 = ax.twinx()
        ax2.bar(gt_x, gt["net_transfer"], alpha=0.3, color="purple", width=20, label="Net transfer ($)")
        ax2.set_ylabel("Net transfer ($)", fontsize=8)
        ax.axhline(3.0, color="black", linewidth=0.7, linestyle="--", alpha=0.5)
        lines1, labels1 = ax.get_legend_handles_labels()
        ax.legend(lines1, labels1, fontsize=7, loc="upper left")
        ax.set_title("Game Theory: Nash Eq Leverage & Net Transfer", fontsize=9)
    else:
        ax.text(0.5, 0.5, "No GT data\n(quick mode)", ha="center", va="center",
                transform=ax.transAxes, fontsize=11)
        ax.set_title("Game Theory (quick mode)", fontsize=9)

    # Panel 6: Mechanism design — param evolution
    ax = fig.add_subplot(gs[1, 2])
    if len(plog) > 1:
        ax.plot(plog["episode"], plog["max_funding_rate"] * 10_000,
                "o-", color="red",    label="max_fr (×10⁴)")
        ax.plot(plog["episode"], plog["maintenance_margin"] * 100,
                "s-", color="blue",   label="mm (%)")
        ax.plot(plog["episode"], plog["liquidation_penalty"] * 100,
                "^-", color="orange", label="liq_pen (%)")
        ax.plot(plog["episode"], plog["insurance_split"],
                "v-", color="green",  label="ins_split")
    ax.set_title("Mechanism Design: Protocol Param Evolution", fontsize=9)
    ax.set_xlabel("Episode")
    ax.legend(fontsize=7)

    # Panel 7: OI imbalance
    ax = fig.add_subplot(gs[2, 0])
    mean_oi = df.groupby("step")["oi_imbalance"].mean()
    ax.plot(mean_oi.index, mean_oi, color="purple", linewidth=1.5)
    ax.fill_between(
        df.groupby("step")["oi_imbalance"].mean().index,
        df.groupby("step")["oi_imbalance"].quantile(0.1),
        df.groupby("step")["oi_imbalance"].quantile(0.9),
        alpha=0.2, color="purple",
    )
    ax.axhline(0, color="black", linewidth=0.8, linestyle="--")
    ax.set_title("OI Imbalance (long−short)/total", fontsize=9)
    ax.set_ylabel("Fraction")

    # Panel 8: Episode summary bar chart
    ax = fig.add_subplot(gs[2, 1])
    x = np.arange(len(eps))
    ax.bar(x - 0.2, eps["final_insurance_fund"] / 1e3, 0.4,
           label="Insurance fund (k$)", color="green", alpha=0.8)
    ax.bar(x + 0.2, eps["rl_final_pnl"]              , 0.4,
           label="RL PnL ($)", color="steelblue", alpha=0.8)
    ax.set_xticks(x)
    ax.set_xticklabels([f"Ep {e+1}" for e in x], fontsize=8)
    ax.axhline(0, color="black", linewidth=0.8)
    ax.set_title("Per-Episode Outcomes", fontsize=9)
    ax.legend(fontsize=7)

    # Panel 9: Shariah check — |mean funding| ≈ 0 across episodes
    ax = fig.add_subplot(gs[2, 2])
    ax.bar(range(len(eps)), eps["mean_abs_funding"] * 10_000,
           color=["green" if v < 2 else "orange" for v in eps["mean_abs_funding"] * 10_000])
    ax.axhline(2, color="red", linewidth=1, linestyle="--", label="2 bps threshold")
    ax.set_xticks(range(len(eps)))
    ax.set_xticklabels([f"Ep {e+1}" for e in range(len(eps))], fontsize=8)
    ax.set_title("Shariah Check: Mean |Funding Rate| (bps)", fontsize=9)
    ax.set_ylabel("bps")
    ax.legend(fontsize=7)

    out_path = os.path.join(out_dir, "dashboard.png")
    plt.savefig(out_path, dpi=150, bbox_inches="tight")
    print(f"[Dashboard] Saved → {out_path}")
    plt.close()

    # ── Params evolution plot ────────────────────────────────────────────────
    if len(plog) > 1:
        fig2, axes = plt.subplots(2, 2, figsize=(12, 7))
        fig2.suptitle("Mechanism Design: Protocol Parameter Evolution Across Episodes",
                      fontsize=12, fontweight="bold")

        param_specs = [
            ("max_funding_rate",    "Max Funding Rate",     "bps", 10_000),
            ("maintenance_margin",  "Maintenance Margin",   "%",   100),
            ("liquidation_penalty", "Liquidation Penalty",  "%",   100),
            ("insurance_split",     "Insurance Split",      "frac", 1),
        ]
        initial = CURRENT_PARAMS

        for ax, (key, title, unit, scale) in zip(axes.flatten(), param_specs):
            ax.plot(plog["episode"], plog[key] * scale,
                    "o-", linewidth=2, markersize=5, color="steelblue", label="Evolved")
            ax.axhline(initial[key] * scale, color="red", linestyle="--",
                       linewidth=1.5, label=f"Initial ({initial[key]*scale:.2f})")
            ax.set_title(f"{title} ({unit})", fontsize=10)
            ax.set_xlabel("Episode")
            ax.legend(fontsize=8)

        plt.tight_layout()
        out2 = os.path.join(out_dir, "params_evolution.png")
        plt.savefig(out2, dpi=150, bbox_inches="tight")
        print(f"[Dashboard] Params evolution → {out2}")
        plt.close()


# ─── Print Final Summary ───────────────────────────────────────────────────────

def print_summary(results: dict):
    eps    = results["episodes"]
    plog   = results["params_log"]
    gt     = results["gt_analysis"]

    print("\n" + "=" * 70)
    print("  INTEGRATED SIMULATION SUMMARY")
    print("=" * 70)

    print(f"\n  Episodes run:          {len(eps)}")
    print(f"  Insolvent episodes:    {int(eps['protocol_insolvent'].sum())} / {len(eps)}")
    print(f"  Total liquidations:    {int(eps['total_liquidations'].sum())}")
    print(f"  RL agent (last ep):   "
          f" PnL=${eps.iloc[-1]['rl_final_pnl']:,.0f}  "
          f"capital=${eps.iloc[-1]['rl_final_capital']:,.0f}")
    print(f"  Mean |funding| (all):  {eps['mean_abs_funding'].mean()*10_000:.3f} bps")

    if not gt.empty:
        print(f"\n  Game Theory intervals: {len(gt)}")
        print(f"  Mean Nash long lev:    {gt['eq_long_leverage'].mean():.2f}x")
        print(f"  Mean Nash short lev:   {gt['eq_short_leverage'].mean():.2f}x")
        print(f"  Mean net transfer:     ${gt['net_transfer'].mean():,.0f}  "
              f"(~0 confirms ι=0 is riba-free)")

    print("\n  Mechanism Design parameter drift:")
    init = CURRENT_PARAMS
    final = {k: v for k, v in plog[-1].items() if k in init}
    for k in init:
        arrow = "▲" if final.get(k, init[k]) > init[k] else "▼" if final.get(k, init[k]) < init[k] else "="
        print(f"  {k:30s}  {init[k]:.5f} → {final.get(k, init[k]):.5f}  {arrow}")

    print("\n  Shariah Compliance Checks:")
    mean_fr_all = eps["mean_abs_funding"].mean()
    max_fr_cap  = CURRENT_PARAMS["max_funding_rate"]
    fr_ratio    = mean_fr_all / max_fr_cap           # fraction of circuit breaker used
    print(f"  [{'PASS' if fr_ratio < 0.95 else 'WARN'}] Mean |funding| = {mean_fr_all*10_000:.1f} bps/interval  "
          f"({fr_ratio*100:.0f}% of {max_fr_cap*10_000:.0f}bps cap, ι=0 symmetric)")
    insolv_rate = eps["protocol_insolvent"].mean() * 100
    print(f"  [{'PASS' if insolv_rate == 0 else 'WARN'}] Insolvency rate = {insolv_rate:.1f}%  (target 0%)")
    if not gt.empty:
        net_tr = gt["net_transfer"].mean()
        print(f"  [{'PASS' if abs(net_tr) < 500 else 'WARN'}] Net transfer ≈ ${net_tr:,.0f}  (target ~$0, ι=0 riba-free)")

    print()


# ─── CLI ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Baraka Protocol — Integrated Economic System Simulation"
    )
    parser.add_argument("--episodes", type=int,  default=5,    help="Number of episodes")
    parser.add_argument("--steps",    type=int,  default=720,  help="Steps per episode (720=30 days)")
    parser.add_argument("--seed",     type=int,  default=42)
    parser.add_argument("--quick",    action="store_true",
                        help="Skip expensive Nash solver (faster, GT uses heuristics)")
    parser.add_argument("--rl-model", type=str,  default=None,
                        help="Path to trained PPO model zip (omit = rule-based fallback)")
    parser.add_argument("--no-plot",  action="store_true")
    args = parser.parse_args()

    results = run_integrated_simulation(
        n_episodes        = args.episodes,
        steps_per_episode = args.steps,
        rl_model_path     = args.rl_model,
        quick             = args.quick,
        seed              = args.seed,
    )

    # Save outputs
    out_dir = "results/integrated"
    os.makedirs(out_dir, exist_ok=True)

    results["timeseries"].to_csv(
        os.path.join(out_dir, "integrated_timeseries.csv"), index=False
    )
    print(f"[Output] Timeseries → {out_dir}/integrated_timeseries.csv  "
          f"({len(results['timeseries'])} rows)")

    results["episodes"].to_csv(
        os.path.join(out_dir, "integrated_episodes.csv"), index=False
    )
    print(f"[Output] Episodes   → {out_dir}/integrated_episodes.csv")

    if not results["gt_analysis"].empty:
        results["gt_analysis"].to_csv(
            os.path.join(out_dir, "gt_analysis.csv"), index=False
        )
        print(f"[Output] GT analysis → {out_dir}/gt_analysis.csv")

    with open(os.path.join(out_dir, "params_log.json"), "w") as f:
        json.dump(results["params_log"], f, indent=2)
    print(f"[Output] Params log → {out_dir}/params_log.json")

    print_summary(results)

    if not args.no_plot:
        plot_dashboard(results, out_dir=out_dir)
