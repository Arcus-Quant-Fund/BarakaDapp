"""
Baraka Protocol — cadCAD State Variables
Defines the initial system state that cadCAD will evolve each timestep.
Each variable maps to on-chain storage in the real contracts.
"""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.params import (
    INITIAL_BTC_PRICE,
    N_TRADERS,
    INSURANCE_FUND_SEED,
    MAX_LEVERAGE,
    MAX_FUNDING_RATE,
)
from dataclasses import dataclass, field
from typing import Dict, List


@dataclass
class Position:
    """Mirrors PositionManager.Position struct"""
    trader:               str
    market:               str
    is_long:              bool
    size:                 float   # notional in USD
    collateral:           float   # USDC
    leverage:             float
    entry_price:          float
    cumulative_funding_at_entry: float
    open:                 bool = True


def _initial_positions() -> Dict[str, Position]:
    """Seed 10 open positions across long/short at launch."""
    pos = {}
    for i in range(10):
        is_long = (i % 2 == 0)
        leverage = min((i % MAX_LEVERAGE) + 1, MAX_LEVERAGE)
        collateral = 5_000.0  # $5k each
        pos[f"trader_{i}"] = Position(
            trader       = f"trader_{i}",
            market       = "BTC/USD",
            is_long      = is_long,
            size         = collateral * leverage,
            collateral   = collateral,
            leverage     = leverage,
            entry_price  = INITIAL_BTC_PRICE,
            cumulative_funding_at_entry = 0.0,
        )
    return pos


# ─── Genesis State ────────────────────────────────────────────────────────────
# cadCAD requires a plain dict for `genesis_states`

genesis_states = {
    # ── Oracle Layer ──────────────────────────────────────────────────────────
    "mark_price":                   INITIAL_BTC_PRICE,
    "index_price":                  INITIAL_BTC_PRICE,

    # ── FundingEngine.sol state ───────────────────────────────────────────────
    "funding_rate":                 0.0,        # F(t) = (mark-index)/index, clipped ±75bps
    "cumulative_funding_index":     1.0,        # product of (1 + F_t) over all intervals
    "last_funding_time":            0,          # sim timestep counter

    # ── Open Interest ─────────────────────────────────────────────────────────
    "oi_long":                      25_000.0,   # total long notional ($)
    "oi_short":                     25_000.0,   # total short notional ($)

    # ── Positions ─────────────────────────────────────────────────────────────
    "positions":                    _initial_positions(),

    # ── CollateralVault.sol state ─────────────────────────────────────────────
    "total_collateral_locked":      50_000.0,   # sum of all position collaterals
    "total_collateral_free":        200_000.0,  # deposited but not in positions

    # ── InsuranceFund.sol state ───────────────────────────────────────────────
    "insurance_fund_balance":       INSURANCE_FUND_SEED,

    # ── Protocol Health Metrics ───────────────────────────────────────────────
    "liquidations_this_step":       0,
    "total_liquidations":           0,
    "total_funding_paid_longs":     0.0,
    "total_funding_received_longs": 0.0,
    "protocol_insolvent":           False,      # True if insurance fund < 0

    # ── Timestep ──────────────────────────────────────────────────────────────
    "timestep":                     0,
}
