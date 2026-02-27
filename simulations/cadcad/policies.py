"""
Baraka Protocol — cadCAD Policy Functions
Policies are read-only: they observe state and produce signals (actions).
State update functions consume those signals and mutate state.

Policy categories:
  p_price_discovery  — simulates oracle price updates (GBM)
  p_trader_actions   — simulated traders open/close/add collateral
  p_liquidator       — bots scan for undercollateralised positions
  p_funding_settle   — triggers funding settlement every FUNDING_INTERVAL
"""

import numpy as np
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from config.params import (
    PRICE_VOLATILITY, FUNDING_INTERVAL,
    MAX_LEVERAGE, MAINTENANCE_MARGIN_RATE,
    N_TRADERS, INITIAL_BTC_PRICE,
)
from cadcad.state import Position

RNG = np.random.default_rng()   # seeded per Monte Carlo run in run.py


# ─── 1. Price Discovery ───────────────────────────────────────────────────────

def p_price_discovery(params, substep, state_history, prev_state):
    """
    Geometric Brownian Motion for both mark and index.
    Mark price leads slightly (futures premium/discount).
    Index price is the spot reference.
    """
    vol   = params.get("price_volatility", PRICE_VOLATILITY)
    index = prev_state["index_price"]
    mark  = prev_state["mark_price"]

    # Spot (index) follows pure GBM
    shock_index = RNG.normal(0, vol)
    new_index   = index * np.exp(shock_index)

    # Mark price mean-reverts to index + small premium noise
    mean_reversion = 0.1                           # how fast mark snaps back
    premium_noise  = RNG.normal(0, vol * 0.5)
    new_mark       = mark * np.exp(premium_noise) * (1 - mean_reversion) \
                   + new_index * mean_reversion

    return {"new_index_price": new_index, "new_mark_price": new_mark}


# ─── 2. Trader Actions ────────────────────────────────────────────────────────

def p_trader_actions(params, substep, state_history, prev_state):
    """
    Simple rule-based traders:
      - 30% chance each step: a new random trader opens a position
      - 20% chance: an existing trader closes their position
      - 10% chance: an existing trader adds collateral
    All actions respect MAX_LEVERAGE and available free collateral.
    """
    actions = []
    positions = prev_state["positions"]
    free_collateral = prev_state["total_collateral_free"]
    mark = prev_state["mark_price"]

    # New position — need at least $5k free so 10% >= $500 (avoids RNG.uniform low>high)
    if RNG.random() < 0.30 and free_collateral > 5_000:
        trader_id  = f"trader_{RNG.integers(0, N_TRADERS)}"
        if trader_id not in positions or not positions[trader_id].open:
            upper      = max(500.0, min(10_000.0, free_collateral * 0.1))
            collateral = float(RNG.uniform(500, upper))
            leverage   = float(RNG.integers(1, MAX_LEVERAGE + 1))
            is_long    = bool(RNG.random() < 0.5)
            actions.append({
                "type":       "open",
                "trader":     trader_id,
                "collateral": collateral,
                "leverage":   leverage,
                "is_long":    is_long,
                "price":      mark,
                "cumulative_funding_at_entry": prev_state["cumulative_funding_index"],
            })

    # Close position
    if RNG.random() < 0.20 and positions:
        open_positions = [k for k, v in positions.items() if v.open]
        if open_positions:
            tid = RNG.choice(open_positions)
            actions.append({"type": "close", "trader": tid, "price": mark})

    # Add collateral
    if RNG.random() < 0.10 and positions and free_collateral > 500:
        open_positions = [k for k, v in positions.items() if v.open]
        if open_positions:
            tid  = RNG.choice(open_positions)
            add  = float(RNG.uniform(100, 500))
            actions.append({"type": "add_collateral", "trader": tid, "amount": add})

    return {"trader_actions": actions}


# ─── 3. Liquidator ────────────────────────────────────────────────────────────

def p_liquidator(params, substep, state_history, prev_state):
    """
    Liquidation bots scan all open positions each step.
    A position is liquidatable when:
        pos.collateral / pos.size  <  MAINTENANCE_MARGIN_RATE
    using the virtual collateral after funding accrual.
    """
    to_liquidate = []
    positions    = prev_state["positions"]
    mark         = prev_state["mark_price"]
    cum_funding  = prev_state["cumulative_funding_index"]

    for tid, pos in positions.items():
        if not pos.open:
            continue

        # Virtual collateral = original collateral - funding accrued
        funding_delta = cum_funding - pos.cumulative_funding_at_entry
        if pos.is_long:
            virtual_collateral = pos.collateral - funding_delta * pos.size
        else:
            virtual_collateral = pos.collateral + funding_delta * pos.size

        # Unrealised PnL
        if pos.is_long:
            pnl = pos.size * (mark - pos.entry_price) / pos.entry_price
        else:
            pnl = pos.size * (pos.entry_price - mark) / pos.entry_price

        effective_collateral = virtual_collateral + pnl

        if effective_collateral < pos.size * MAINTENANCE_MARGIN_RATE:
            to_liquidate.append(tid)

    return {"to_liquidate": to_liquidate}


# ─── 4. Funding Settlement ────────────────────────────────────────────────────

def p_funding_settle(params, substep, state_history, prev_state):
    """
    Computes the new funding rate for this interval.
    F = (mark - index) / index,  clipped to ±MAX_FUNDING_RATE
    ι = 0: no interest floor added.
    """
    mark  = prev_state["mark_price"]
    index = prev_state["index_price"]

    if index == 0:
        rate = 0.0
    else:
        rate = (mark - index) / index

    max_r = params.get("max_funding_rate", 0.0075)
    rate  = float(np.clip(rate, -max_r, max_r))

    return {"new_funding_rate": rate}
