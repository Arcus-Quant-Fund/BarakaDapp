"""
Baraka Protocol — Simulation Parameters
Mirrors the on-chain constants in FundingEngine.sol, LiquidationEngine.sol, etc.
All basis-point values are stored as fractions (e.g. 75bps = 0.0075).
"""

# ─── Funding Engine ────────────────────────────────────────────────────────────
FUNDING_INTERVAL        = 3600            # seconds (1 hour, matches FUNDING_INTERVAL in contract)
MAX_FUNDING_RATE        = 0.0075          # +75 bps per interval ceiling
MIN_FUNDING_RATE        = -0.0075         # -75 bps per interval floor
IOTA                    = 0.0             # ι = 0 (the core Shariah principle — no interest floor)

# ─── Shariah Guard ────────────────────────────────────────────────────────────
MAX_LEVERAGE            = 5               # Hard cap (immutable on-chain constant)

# ─── Position / Collateral ────────────────────────────────────────────────────
MIN_LEVERAGE            = 1
COLLATERAL_DECIMALS     = 6              # USDC 6 dp

# ─── Liquidation Engine ───────────────────────────────────────────────────────
MAINTENANCE_MARGIN_BPS  = 200            # 2% — liquidation threshold
LIQUIDATION_PENALTY_BPS = 100            # 1% — split 50/50 liquidator / insurance
INSURANCE_SPLIT_BPS     = 5000           # 50% of penalty to insurance fund

MAINTENANCE_MARGIN_RATE = MAINTENANCE_MARGIN_BPS  / 10_000
LIQUIDATION_PENALTY     = LIQUIDATION_PENALTY_BPS / 10_000
INSURANCE_SPLIT         = INSURANCE_SPLIT_BPS     / 10_000

# ─── CollateralVault ──────────────────────────────────────────────────────────
WITHDRAWAL_COOLDOWN     = 86_400         # 24 hours in seconds

# ─── Simulation Ranges ────────────────────────────────────────────────────────
# Price scenarios
INITIAL_BTC_PRICE       = 50_000.0       # USD
PRICE_VOLATILITY        = 0.02           # 2% per interval std (log-normal)

# Agent population
N_TRADERS               = 50             # number of simulated traders
N_LIQUIDATORS           = 5             # number of arbitrage/liquidation bots

# Simulation horizon
SIM_STEPS               = 720            # 720 intervals = 30 days at 1hr each
MONTE_CARLO_RUNS        = 20             # parallel Monte Carlo seeds

# Insurance fund seed (in USDC notional)
INSURANCE_FUND_SEED     = 100_000.0      # $100k initial seed

# ─── Game Theory Matrix Dimensions ────────────────────────────────────────────
# Discretised leverage choices for the Nash equilibrium analysis
LEVERAGE_CHOICES        = [1, 2, 3, 4, 5]  # all Shariah-permissible levels

# ─── Mechanism Design Search Space ────────────────────────────────────────────
PARAM_BOUNDS = {
    "max_funding_rate":         (0.001,  0.020),   # 10–200 bps
    "maintenance_margin":       (0.005,  0.050),   # 0.5%–5%
    "liquidation_penalty":      (0.003,  0.030),   # 0.3%–3%
    "insurance_split":          (0.10,   0.90),    # 10%–90%
    "max_leverage":             (2,      5),        # (kept integer)
}
