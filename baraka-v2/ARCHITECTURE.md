# Baraka Protocol v2 — Architecture

**Design philosophy:** dYdX v4 concepts reimplemented in Solidity for EVM L2 deployment. Orderbook-based matching with cross-margin, MEV protection, and full Shariah compliance.

---

## Why v2?

v1 (13+1 contracts, 580 tests) proved the Shariah layers work but has a fundamental limitation: pool-based AMM counterparty (BarakaPool). This creates:
- **Adverse selection**: LPs always take the wrong side (traders have information advantage)
- **Impermanent loss**: LP returns are inversely correlated with trader skill
- **No price discovery**: oracle-dependent, not market-driven
- **Limited liquidity depth**: pool size = max OI

dYdX v4 solved these with an orderbook. v2 brings that to EVM + Shariah.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        Baraka v2 Stack                           │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Layer 5: Governance                                     │    │
│  │  GovernanceModule · BRKXToken                            │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Layer 4: Islamic Instruments                            │    │
│  │  iCDS · PerpetualSukuk · EverlastingOption               │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Layer 3: Risk & Insurance                               │    │
│  │  InsuranceFund · TakafulPool · AutoDeleveraging          │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Layer 2: Shariah Compliance                             │    │
│  │  ShariahRegistry · ComplianceOracle                      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Layer 1: Core Trading Engine                            │    │
│  │  OrderBook · MatchingEngine · MarginEngine ·             │    │
│  │  SubaccountManager · FundingEngine · LiquidationEngine · │    │
│  │  OracleAdapter · FeeEngine                               │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │  Layer 0: Settlement                                     │    │
│  │  Vault · BatchSettlement                                 │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## Layer 0: Settlement

### Vault.sol
Central custodian for all collateral. Holds actual ERC-20 tokens.
- Maps subaccount → token → balance
- Atomic batch transfers for settlement
- No rehypothecation (Shariah: idle capital stays idle)
- Guardian emergency revocation (from v1 CV-M-4)

### BatchSettlement.sol
Processes matched trades in batches to reduce MEV and gas.
- Receives batch of matched orders from MatchingEngine
- Settles all fills atomically (one tx = many trades)
- Updates margin accounts, transfers fees
- Emits events for indexers

---

## Layer 1: Core Trading Engine

### OrderBook.sol
On-chain Central Limit Order Book (CLOB) per market.
- **Red-black tree** for price levels (O(log n) insert/cancel)
- Price-time priority matching
- Order types: Limit, Market, Stop-Limit, Stop-Market
- Time-in-force: GTC (Good Till Cancel), IOC (Immediate Or Cancel), FOK (Fill Or Kill), Post-Only
- Self-trade prevention (STP)
- Per-market order book (one contract instance per market, or mapping)

**dYdX v4 difference:** dYdX runs orderbook off-chain in validator memory. We run it on-chain for trustlessness, accepting higher gas cost (mitigated by L2 cheap gas on Arbitrum/Base).

**Gas optimization:**
- Batch order placement (place N orders in one tx)
- Lazy deletion (cancelled orders marked, cleaned on match)
- Packed storage (price + size + trader in 2 slots)

### MatchingEngine.sol
Matches incoming orders against resting book.
- Price-time priority (best price first, earliest order first at same price)
- Partial fills supported
- Emits Fill events consumed by MarginEngine
- MEV protection: commit-reveal for market orders (optional, configurable)

**Commit-reveal flow (MEV protection):**
1. Trader submits `commit(hash(order + nonce))` — no order details visible
2. After N blocks, trader submits `reveal(order, nonce)` — matched against book
3. Prevents front-running and sandwich attacks
4. Optional per-market (can be disabled for markets where speed > MEV risk)

### MarginEngine.sol
Cross-margin account management (dYdX v4's key innovation).
- **Subaccounts**: each address can have up to 128 subaccounts
- **Cross-margin**: all positions in a subaccount share collateral
- **Isolated margin**: optional — create a dedicated subaccount per position
- Initial margin rate (IMR): per-market, set by governance
- Maintenance margin rate (MMR): per-market, always < IMR
- Free collateral = equity - Σ(position_notional × IMR)
- Equity = balance + Σ(unrealized_pnl) - Σ(pending_funding)

**Key formulas (from dYdX v4):**
```
equity = collateral_balance + Σ(position_size × (oracle_price - entry_price))
initial_margin_requirement = Σ(|position_size| × oracle_price × IMR_market)
maintenance_margin_requirement = Σ(|position_size| × oracle_price × MMR_market)
free_collateral = equity - initial_margin_requirement
is_liquidatable = equity < maintenance_margin_requirement
```

### SubaccountManager.sol
Manages subaccount creation, transfers, and queries.
- `createSubaccount()` → returns subaccount ID (address + uint8 index)
- `transferBetweenSubaccounts()` — move collateral between own subaccounts
- `deposit()` / `withdraw()` — vault interactions
- View: `getEquity()`, `getFreeCollateral()`, `isLiquidatable()`

### FundingEngine.sol
Premium-only funding (ι=0), 8-hour basis, continuous accrual.
- `F = premium / 8h` where `premium = (mark_price - index_price) / index_price`
- Mark price = EWMA of recent trade prices (not oracle — market-driven)
- Clamped at ±(IMR - MMR) × 0.9 (dYdX v4 pattern)
- Accrues per-second (not per-block) for precision
- No interest component — pure convergence mechanism

### LiquidationEngine.sol
Partial liquidation with insurance fund cascade (dYdX v4 three-tier).
- **Tier 1**: Partial liquidation — reduce position to bring equity back above MMR
- **Tier 2**: Full liquidation — close entire position, remaining collateral → InsuranceFund
- **Tier 3**: Auto-deleveraging (ADL) — if InsuranceFund insufficient, profitable opposing positions are reduced pro-rata
- Liquidation fee: split between liquidator (incentive) and InsuranceFund (reserve)
- **Shariah constraint**: max 5x leverage enforced at open, but liquidation at any level

### OracleAdapter.sol
Dual-source oracle with staleness protection.
- Primary: Chainlink (or Pyth on supported chains)
- Secondary: on-chain TWAP from recent trades
- Deviation check: if |chainlink - twap| > threshold, flag for review
- Staleness: reject if last update > heartbeat × 2
- Used for: margin calculation, liquidation triggers, funding index price
- NOT used for trade execution (that uses orderbook prices)

### FeeEngine.sol
Maker-taker fee model with BRKX discount tiers.
- Maker fee: negative (rebate) — incentivizes limit orders / liquidity provision
- Taker fee: positive — charged on market orders / aggressive fills
- BRKX tiers (from v1, using getPastVotes for flash-loan resistance):
  - < 1,000 BRKX: 5.0 bps taker / -0.5 bps maker
  - ≥ 1,000 BRKX: 4.0 bps / -1.0 bps
  - ≥ 10,000 BRKX: 3.5 bps / -1.5 bps
  - ≥ 50,000 BRKX: 2.5 bps / -2.0 bps
- Fee split: 60% Treasury + 20% InsuranceFund + 20% Stakers

---

## Layer 2: Shariah Compliance

### ShariahRegistry.sol (evolved from v1 ShariahGuard)
- Asset whitelist (Shariah board multisig approval)
- Collateral whitelist (USDC, PAXG, XAUT, DAI-if-approved)
- Max leverage per market (default 5x, can be lower per asset)
- Fatwa IPFS CID on-chain
- `validateOrder()` — called by MatchingEngine before every fill
- `validateMarket()` — called when creating new market
- Emergency halt: freeze all trading instantly

### ComplianceOracle.sol
Off-chain Shariah screening results brought on-chain.
- Shariah board signs compliance attestations off-chain
- Attestations submitted on-chain with ECDSA signatures
- Quorum: 3-of-5 Shariah scholars must sign
- Used for: new asset approval, parameter changes, fatwa updates

---

## Layer 3: Risk & Insurance

### InsuranceFund.sol (from v1, enhanced)
- Receives: liquidation penalties, fee share, surplus from TakafulPool
- Pays: shortfalls from underwater liquidations
- Weekly claims tracking (EWMA decay)
- Surplus distribution to TakafulPool (7-day cooldown)
- No rehypothecation

### TakafulPool.sol (from v1)
- Everlasting put pricing (Ackerer Prop 6)
- Mutual guarantee (Kafala) for catastrophic losses
- Surplus redistribution to participants

### AutoDeleveraging.sol (new — dYdX v4 Tier 3)
- Triggered when InsuranceFund is exhausted during liquidation
- Ranks opposing profitable positions by unrealized PnL
- Partially closes most profitable opposing positions to cover shortfall
- Emits ADL events (traders can monitor and hedge)
- Last resort — should rarely activate

---

## Layer 4: Islamic Instruments (from v1, unchanged)

### EverlastingOption.sol
- Ackerer Prop 6 on-chain pricer
- No expiry (everlasting)

### iCDS.sol
- Islamic credit default swap

### PerpetualSukuk.sol
- On-chain sukuk with embedded call option

---

## Layer 5: Governance (from v1, unchanged)

### BRKXToken.sol
- ERC20Votes governance token
- 100M fixed supply, no mint function

### GovernanceModule.sol
- Timelock + multisig governance
- Parameter updates (fees, margins, etc.)

---

## Contract Count

| Layer | Contracts | Status |
|---|---|---|
| 0 Settlement | Vault, BatchSettlement | BUILT |
| 1 Core Engine | OrderBook, MatchingEngine, MarginEngine, SubaccountManager, FundingEngine, LiquidationEngine, OracleAdapter, FeeEngine | BUILT + 12 E2E tests |
| 2 Shariah | ShariahRegistry, ComplianceOracle | BUILT |
| 3 Risk | InsuranceFund, TakafulPool, AutoDeleveraging | BUILT |
| 4 Instruments | EverlastingOption, iCDS, PerpetualSukuk | BUILT (ported from v1) |
| 5 Governance | BRKXToken, GovernanceModule | BUILT (ported from v1) |
| **Total** | **20 contracts** | **All compiling** |

---

## Build Order (bottom-up) — ALL PHASES COMPLETE

Phase 1 — Foundation (Layer 0 + Core Layer 1): **COMPLETE** (12 E2E tests passing)
1. Vault.sol — collateral custody
2. SubaccountManager.sol — cross-margin accounts
3. MarginEngine.sol — margin calculations
4. OracleAdapter.sol — price feeds
5. FundingEngine.sol — premium-only funding
6. OrderBook.sol — on-chain CLOB
7. MatchingEngine.sol — order matching + MEV protection
8. ShariahRegistry.sol — compliance enforcement

Phase 2 — Trading Engine: **COMPLETE** (needs unit tests)
9. FeeEngine.sol — maker-taker fees with BRKX tiers
10. BatchSettlement.sol — atomic multi-trade settlement

Phase 3 — Risk: **COMPLETE** (needs unit tests)
11. LiquidationEngine.sol — three-tier: partial → full → ADL
12. AutoDeleveraging.sol — pro-rata ADL cascade
13. InsuranceFund.sol — EWMA claims, shortfall backstop

Phase 4 — Shariah + Instruments: **COMPLETE** (ported from v1, needs unit tests)
14. ComplianceOracle.sol — 3-of-5 Shariah board attestations
15. EverlastingOption.sol — Ackerer Prop 6, Solady math
16. iCDS.sol — Islamic credit default swap
17. PerpetualSukuk.sol — on-chain sukuk + embedded call
18. TakafulPool.sol — Wakala agency mutual insurance

Phase 5 — Governance: **COMPLETE** (ported from v1, needs unit tests)
19. BRKXToken.sol — ERC20Votes, 100M supply
20. GovernanceModule.sol — dual-track DAO + Shariah veto + v2 emergencyPause

**Build status:** 32 source files, ~14,568 SLOC, forge build clean. All v1 audit fixes preserved.

---

## Key Design Decisions

1. **On-chain orderbook vs off-chain matching**: On-chain for trustlessness. L2 gas is cheap enough (~$0.01-0.05 per order on Arbitrum). dYdX v4 went off-chain for throughput, but we prioritize censorship resistance.

2. **Cross-margin by default**: dYdX v4's best UX innovation. Capital efficient — one deposit backs all positions. Isolated margin available via separate subaccount.

3. **Commit-reveal for MEV**: Optional per-market. Adds 1-block latency but eliminates front-running. Can be disabled for low-MEV markets.

4. **Partial liquidation**: dYdX v4 pattern — reduce position size to restore margin, not full close. Less cascading, more stable.

5. **Maker rebates**: Negative maker fee incentivizes limit orders, building book depth organically. dYdX v4 does this and it creates deep liquidity.

6. **Shariah at the matching layer**: ShariahRegistry.validateOrder() is called before every fill, not just at position open. This ensures compliance even for partial fills and cross-margin scenarios.

7. **Auto-deleveraging as last resort**: After InsuranceFund is exhausted, ADL kicks in. This is the nuclear option — keeps the protocol solvent without socialized losses.
