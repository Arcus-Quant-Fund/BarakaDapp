# Baraka Protocol — Simulation Framework

**Purpose:** Verify economic security of the protocol before testnet deployment.
**Principle:** No changing contracts post-deploy → simulate everything first.

---

## Architecture Overview

```
simulations/
├── config/
│   └── params.py              ← Protocol constants (mirrors Solidity)
├── cadcad/
│   ├── state.py               ← System state variables (genesis state)
│   ├── policies.py            ← Agent behaviours (price, traders, liquidator)
│   ├── state_updates.py       ← State transition functions
│   └── run.py                 ← Monte Carlo runner + plots
├── agents/
│   └── rl_trader.py           ← Gymnasium env + PPO/SAC agent (SB3)
├── game_theory/
│   └── funding_game.py        ← Nash equilibrium proof (nashpy)
├── mechanism_design/
│   └── parameter_optimizer.py ← Multi-objective param search (scipy)
├── scenarios/
│   └── flash_crash.py         ← 5 stress-test scenarios
├── notebooks/
│   └── (Jupyter notebooks for interactive exploration)
└── requirements.txt
```

---

## Module 1: cadCAD System Dynamics

**File:** `cadcad/run.py`
**What it does:** Runs the full Baraka Protocol as a dynamic system using cadCAD's
Partial State Update Block architecture. Simulates 720 intervals (30 days) × 20
Monte Carlo runs simultaneously.

**Key state variables tracked:**
| Variable | Description | Maps to |
|---|---|---|
| `mark_price` | Futures oracle price | OracleAdapter.getMarkPrice() |
| `index_price` | Spot oracle price | OracleAdapter.getIndexPrice() |
| `funding_rate` | Current interval rate | FundingEngine.getFundingRate() |
| `cumulative_funding_index` | Running sum of all F_t | FundingEngine.cumulativeFundingIndex |
| `oi_long / oi_short` | Open interest by side | PositionManager totals |
| `insurance_fund_balance` | Insurance reserves | InsuranceFund.fundBalance() |
| `positions` | All open positions | PositionManager.positions |

**Run:**
```bash
cd simulations
python cadcad/run.py --steps 720 --runs 20
# Output: results/cadcad_results.csv + results/cadcad_summary.png
```

**Key insight verified:** `funding_rate` oscillates around 0 with no systematic
positive bias → confirms ι=0 is maintained across all price scenarios.

---

## Module 2: Reinforcement Learning Trader

**File:** `agents/rl_trader.py`
**What it does:** Trains a PPO agent (Proximal Policy Optimization) to trade
optimally within Baraka's constraints. The agent discovers:
- Optimal leverage (given 2% maintenance margin + liquidation risk)
- When to stay long vs short based on funding rate signal
- Risk management: don't get liquidated

**Observation space (8 features):**
- Normalised mark/index prices
- Current funding rate
- Cumulative funding index
- Current position (size, collateral, direction)
- Free collateral

**Action space (Discrete 12):**
- 0: Hold
- 1–5: Open long, leverage 1x–5x
- 6–10: Open short, leverage 1x–5x
- 11: Close position

**Run:**
```bash
# Sanity check (no training):
python agents/rl_trader.py

# Train 200k steps:
python agents/rl_trader.py --train --timesteps 200000

# Evaluate trained model:
python agents/rl_trader.py --eval --model results/rl_trader
```

**Key insight:** Trained agents learn to use lower leverage during high funding
rate periods (expensive to hold) and higher leverage when funding rate is near
zero — consistent with optimal carry trade theory under ι=0.

---

## Module 3: Game Theory (Nash Equilibrium)

**File:** `game_theory/funding_game.py`
**What it does:** Formally proves that ι=0 is the unique Shariah-compliant Nash
Equilibrium in the two-player long-short funding game.

**The Funding Game:**
- Two representative players: LONGS and SHORTS
- Strategy space: leverage level {1, 2, 3, 4, 5}
- Payoff: expected return minus funding costs over a price path
- Funding formula: F = (mark - index) / index + ι

**Nash Equilibrium under ι=0:**
When OI_long ≈ OI_short (market balance), mark → index, F → 0. Neither player
can profitably deviate by changing leverage since funding costs are zero at
equilibrium. The Nash Equilibrium is the balanced state.

**With ι > 0 (interest floor):**
Longs always pay a positive cost even when mark = index. This creates a
systematic transfer from longs to the protocol/shorts — economically equivalent
to riba (interest). The game becomes unfair → not Shariah-compliant.

**Run:**
```bash
python game_theory/funding_game.py
# Output: results/payoff_iota0.png, results/payoff_iota005.png,
#         results/game_theory_iota.png
```

**Key output:** "ι=0 produces net_transfer ≈ 0 → no systematic transfer from
longs to the protocol → zero riba → Shariah-compliant ✓"

---

## Module 4: Mechanism Design (Parameter Optimizer)

**File:** `mechanism_design/parameter_optimizer.py`
**What it does:** Uses scipy differential_evolution to find the Pareto-optimal
combination of protocol parameters that simultaneously:

1. Maximises protocol solvency (insurance fund survival)
2. Minimises trader liquidation rate
3. Keeps funding rate near zero (Shariah compliance)
4. Allows adequate capital efficiency

**Parameters optimized:**
| Parameter | Current Value | Search Range |
|---|---|---|
| `max_funding_rate` | ±75bps | [10bps, 200bps] |
| `maintenance_margin` | 2% | [0.5%, 5%] |
| `liquidation_penalty` | 1% | [0.3%, 3%] |
| `insurance_split` | 50% | [10%, 90%] |

**Fixed constraints (Shariah principles):**
- `MAX_LEVERAGE = 5` — immutable constant, cannot be optimized away
- `iota = 0` — immutable principle, cannot be optimized away

**Run:**
```bash
python mechanism_design/parameter_optimizer.py
python mechanism_design/parameter_optimizer.py --quick  # faster
# Output: results/pareto_front.csv + results/pareto_front.png
```

---

## Module 5: Stress Test Scenarios

**File:** `scenarios/flash_crash.py`
**What it does:** 5 pre-defined market stress scenarios to test protocol resilience.

| Scenario | Description | Key Test |
|---|---|---|
| `flash_crash` | BTC -40% in 3 intervals | Insurance fund absorbs cascade |
| `funding_spiral` | +75bps for 48h straight | Max funding does not bankrupt protocol |
| `oracle_attack` | Mark +20% above index for 5h | Circuit breaker limits damage |
| `gradual_bear` | -2%/day for 60 days | Slow bleed on leveraged longs |
| `insurance_stress` | Worst-case liquidation cascade | Insurance fund solvency |

**For each scenario, verifies Shariah invariants:**
- `iota_violated = False` (ι=0 maintained throughout)
- `leverage_violated = False` (no position exceeds 5x)
- Insurance fund balance stays ≥ 0 (solvency)

**Run:**
```bash
python scenarios/flash_crash.py                        # all scenarios
python scenarios/flash_crash.py --scenario flash_crash # one scenario
# Output: results/scenario_*.csv + results/scenario_*.png
```

---

## Quick Start

```bash
# Install dependencies
pip install -r simulations/requirements.txt

# Run all simulations (from project root)
cd simulations

# 1. cadCAD Monte Carlo
python cadcad/run.py --steps 720 --runs 20

# 2. RL sanity check
python agents/rl_trader.py

# 3. Game theory
python game_theory/funding_game.py

# 4. Mechanism design (quick mode)
python mechanism_design/parameter_optimizer.py --quick

# 5. Stress tests
python scenarios/flash_crash.py
```

All outputs go to `simulations/results/`.

---

## What "Passes" Looks Like

Before deploying to Arbitrum Sepolia, all of the following must be true:

| Check | Target | File |
|---|---|---|
| cadCAD: insolvency rate | < 5% across 20 runs | cadcad/run.py |
| cadCAD: funding rate range | stays within ±75bps | cadcad/run.py |
| Game theory: ι=0 net transfer | ≈ $0 (< $10 over 200 steps) | game_theory/funding_game.py |
| Mechanism design: current params | in Pareto-optimal region | mechanism_design/parameter_optimizer.py |
| Flash crash scenario | Insurance fund survives | scenarios/flash_crash.py |
| Funding spiral scenario | Protocol solvent | scenarios/flash_crash.py |
| Oracle attack scenario | Circuit breaker limits damage | scenarios/flash_crash.py |
| RL agent: profitable | Mean PnL > 0 over 20 episodes | agents/rl_trader.py |

---

## Theoretical Foundation

All simulations are grounded in:

> **Ackerer, D., Hugonnier, J., & Jermann, U. (2024).** "Perpetual Futures Pricing."
> *Mathematical Finance.*
> — Theorem 3 / Proposition 3: The fair perpetual futures price equals the
>   expected future spot price when ι=0 (no interest floor).
>   With ι>0, the price diverges and creates an interest-equivalent transfer
>   from one counterparty to the protocol.

The simulations verify this theorem computationally across thousands of price paths.

---

*Simulation framework version 1.0 — February 2026*
*Baraka Protocol — World's first Shariah-compliant perpetual DEX*
