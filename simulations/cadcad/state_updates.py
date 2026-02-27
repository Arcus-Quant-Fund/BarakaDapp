"""
Baraka Protocol — cadCAD State Update Functions
Each function receives (params, substep, state_history, prev_state, policy_input)
and returns (key, new_value).
"""

import copy
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from config.params import (
    LIQUIDATION_PENALTY,
    INSURANCE_SPLIT,
    MAINTENANCE_MARGIN_RATE,
)
from cadcad.state import Position


# ─── Oracle ───────────────────────────────────────────────────────────────────

def s_update_index_price(params, substep, state_history, prev_state, policy_input):
    return ("index_price", policy_input["new_index_price"])

def s_update_mark_price(params, substep, state_history, prev_state, policy_input):
    return ("mark_price", policy_input["new_mark_price"])


# ─── Funding ──────────────────────────────────────────────────────────────────

def s_update_funding_rate(params, substep, state_history, prev_state, policy_input):
    return ("funding_rate", policy_input["new_funding_rate"])

def s_update_cumulative_funding(params, substep, state_history, prev_state, policy_input):
    """
    Mirrors FundingEngine.updateCumulativeFunding():
      cumulativeFundingIndex += rate (additive approximation for simulation)
    The contract uses additive increments: cumulativeFundingIndex += F_t
    """
    old  = prev_state["cumulative_funding_index"]
    rate = policy_input["new_funding_rate"]
    return ("cumulative_funding_index", old + rate)


# ─── Positions ────────────────────────────────────────────────────────────────

def s_update_positions(params, substep, state_history, prev_state, policy_input):
    """Process all trader actions: open / close / add_collateral."""
    positions   = copy.deepcopy(prev_state["positions"])
    actions     = policy_input.get("trader_actions", [])
    cum_funding = prev_state["cumulative_funding_index"]

    for action in actions:
        t = action["type"]
        tid = action.get("trader", "")

        if t == "open":
            positions[tid] = Position(
                trader       = tid,
                market       = "BTC/USD",
                is_long      = action["is_long"],
                size         = action["collateral"] * action["leverage"],
                collateral   = action["collateral"],
                leverage     = action["leverage"],
                entry_price  = action["price"],
                cumulative_funding_at_entry = action["cumulative_funding_at_entry"],
                open         = True,
            )

        elif t == "close" and tid in positions:
            positions[tid].open = False

        elif t == "add_collateral" and tid in positions and positions[tid].open:
            positions[tid].collateral += action["amount"]

    return ("positions", positions)


def s_update_oi(params, substep, state_history, prev_state, policy_input):
    """Recompute open interest from current open positions."""
    positions = prev_state["positions"]
    actions   = policy_input.get("trader_actions", [])

    oi_long  = prev_state["oi_long"]
    oi_short = prev_state["oi_short"]

    for action in actions:
        t = action["type"]
        if t == "open":
            size = action["collateral"] * action["leverage"]
            if action["is_long"]:
                oi_long  += size
            else:
                oi_short += size
        elif t == "close":
            tid = action.get("trader", "")
            if tid in positions and positions[tid].open:
                pos = positions[tid]
                if pos.is_long:
                    oi_long  = max(0, oi_long  - pos.size)
                else:
                    oi_short = max(0, oi_short - pos.size)

    return ("oi_long", oi_long)   # cadCAD limitation: return one key per function

def s_update_oi_short(params, substep, state_history, prev_state, policy_input):
    """Separate update for oi_short (cadCAD one-key-per-function constraint)."""
    positions = prev_state["positions"]
    actions   = policy_input.get("trader_actions", [])
    oi_short  = prev_state["oi_short"]

    for action in actions:
        t = action["type"]
        if t == "open" and not action["is_long"]:
            oi_short += action["collateral"] * action["leverage"]
        elif t == "close":
            tid = action.get("trader", "")
            if tid in positions and positions[tid].open and not positions[tid].is_long:
                oi_short = max(0, oi_short - positions[tid].size)

    return ("oi_short", oi_short)


# ─── Liquidations ─────────────────────────────────────────────────────────────

def s_process_liquidations(params, substep, state_history, prev_state, policy_input):
    """
    Close all flagged positions and apply penalty:
      - 50% of penalty → liquidator (not tracked in state, just removed)
      - 50% of penalty → insurance fund
    Returns updated positions dict.
    """
    to_liq    = policy_input.get("to_liquidate", [])
    positions = copy.deepcopy(prev_state["positions"])

    for tid in to_liq:
        if tid in positions and positions[tid].open:
            positions[tid].open = False

    return ("positions", positions)

def s_update_insurance_from_liquidations(params, substep, state_history, prev_state, policy_input):
    """
    Add insurance fund share of liquidation penalties.
    Penalty = size * LIQUIDATION_PENALTY * INSURANCE_SPLIT
    """
    to_liq    = policy_input.get("to_liquidate", [])
    positions = prev_state["positions"]
    mark      = prev_state["mark_price"]
    ins_bal   = prev_state["insurance_fund_balance"]

    for tid in to_liq:
        if tid in positions and positions[tid].open:
            pos     = positions[tid]
            # value at current mark
            penalty = pos.size * (params.get("liquidation_penalty", LIQUIDATION_PENALTY))
            ins_bal += penalty * params.get("insurance_split", INSURANCE_SPLIT)

    return ("insurance_fund_balance", max(0.0, ins_bal))

def s_update_liquidation_count(params, substep, state_history, prev_state, policy_input):
    to_liq = policy_input.get("to_liquidate", [])
    return ("liquidations_this_step", len(to_liq))

def s_update_total_liquidations(params, substep, state_history, prev_state, policy_input):
    to_liq = policy_input.get("to_liquidate", [])
    return ("total_liquidations", prev_state["total_liquidations"] + len(to_liq))


# ─── Collateral ───────────────────────────────────────────────────────────────

def s_update_total_collateral_locked(params, substep, state_history, prev_state, policy_input):
    positions = prev_state["positions"]
    locked    = sum(p.collateral for p in positions.values() if p.open)
    return ("total_collateral_locked", locked)

def s_update_total_collateral_free(params, substep, state_history, prev_state, policy_input):
    """
    Simplified: free collateral changes with open/close actions.
    Real vault also enforces 24h cooldown for withdrawals.
    """
    actions = policy_input.get("trader_actions", [])
    free    = prev_state["total_collateral_free"]

    for action in actions:
        t = action["type"]
        if t == "open":
            free -= action["collateral"]
        elif t == "add_collateral":
            free -= action["amount"]

    return ("total_collateral_free", max(0.0, free))


# ─── Funding PnL Tracking ─────────────────────────────────────────────────────

def s_track_funding_paid(params, substep, state_history, prev_state, policy_input):
    """Track cumulative funding paid by longs (positive when mark > index)."""
    rate      = policy_input["new_funding_rate"]
    oi_long   = prev_state["oi_long"]
    paid      = prev_state["total_funding_paid_longs"]
    if rate > 0:
        paid += rate * oi_long
    return ("total_funding_paid_longs", paid)

def s_track_funding_received(params, substep, state_history, prev_state, policy_input):
    """Track cumulative funding received by longs (negative rate = longs receive)."""
    rate      = policy_input["new_funding_rate"]
    oi_long   = prev_state["oi_long"]
    received  = prev_state["total_funding_received_longs"]
    if rate < 0:
        received += abs(rate) * oi_long
    return ("total_funding_received_longs", received)


# ─── Timestep ─────────────────────────────────────────────────────────────────

def s_update_timestep(params, substep, state_history, prev_state, policy_input):
    return ("timestep", prev_state["timestep"] + 1)

def s_check_solvency(params, substep, state_history, prev_state, policy_input):
    ins = prev_state["insurance_fund_balance"]
    return ("protocol_insolvent", ins < 0)
