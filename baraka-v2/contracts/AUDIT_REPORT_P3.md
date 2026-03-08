# Baraka Protocol v2 — Internal Security Audit Report (Pass 3)

**Date:** March 8, 2026
**Auditor:** Internal (5 parallel specialized agents — CLOB, MarginEngine, LiquidationEngine, Instruments, Cross-cutting)
**Codebase:** `baraka-v2/contracts/` — 20 contracts, ~3,300 SLOC
**Baseline:** 568/568 tests passing, 0 Slither HIGH/MEDIUM
**Prior passes:** Pass 1 (142 findings), Pass 2 (74 findings) — all 216 findings remediated

---

## Summary

| Severity | Count | Fixed |
|---|---|---|
| CRITICAL | 3 | 3 |
| HIGH | 20 | 3 |
| MEDIUM | 24 | 0 |
| LOW | 8 | 0 |
| INFO | 7 | 0 |
| **TOTAL** | **62** | **6** |

**Invalidated findings:** P3-ME-2 marked INVALID (int256.max ≈ 5.79×10⁷⁶; BTC at $100k = 1e23 fits with enormous margin — agent confused int256 with int128).

---

## CRITICAL Findings

### P3-FE-1 — FundingEngine.updateFunding() has whenNotPaused — blocks all liquidations when FE paused

**Contract:** `src/core/FundingEngine.sol:109`
**Status:** ✅ FIXED (Pass 3)

`FundingEngine.updateFunding()` has `whenNotPaused`. `MarginEngine._settleFundingForPosition()` calls `fundingEngine.updateFunding()`, which is called from `updatePosition()` on the reducing/closing path (line 263). `LiquidationEngine.liquidate()` calls `marginEngine.updatePosition()` to close the position. Result: FundingEngine pause → all liquidations revert. The P2-CRIT-3 fix removed `whenNotPaused` from `liquidate()` but left it intact one layer deeper in `updateFunding()`.

**Fix:** Removed `whenNotPaused` from `FundingEngine.updateFunding()`. Funding accrual is a read-heavy mathematical operation; pausing it does not protect against exploits but does block the entire liquidation system.

---

### P3-LIQ-1 — MarginEngine.updatePosition() has whenNotPaused — liquidation cascade blocked when ME paused

**Contract:** `src/core/MarginEngine.sol:231`
**Status:** ✅ FIXED (Pass 3)

`MarginEngine.updatePosition()` retains `whenNotPaused`. `LiquidationEngine.liquidate()` calls `marginEngine.updatePosition()` at line 193 — if MarginEngine is paused (e.g., to pause trading during an exploit investigation), all liquidations revert at that inner call. This completely negates the P2-CRIT-3 fix, which only removed the guard from the LiquidationEngine entry point. ADL also calls `updatePosition` (AutoDeleveraging:160), so ADL is equivalently blocked.

**Fix:** Removed `whenNotPaused` from `MarginEngine.updatePosition()`. Consistent with `Vault.settlePnL` (P2-HIGH-4) pattern: settlement-path functions must not be gateable by pause.

---

### P3-INST-1 — iCDS.expire() missing oracle staleness check — stale oracle enables seller to escape live credit event

**Contract:** `src/instruments/iCDS.sol:205-207`
**Status:** ✅ FIXED (Pass 3)

`expire()` checks `spotWad > prot.recoveryFloorWad` to block expiration during an active credit event. If the oracle is stale (Chainlink heartbeat lapsed), `oracle.getIndexPrice()` returns the last cached price. The seller can call `expire()` during a period when the real market price has dropped below the floor (a genuine default) but the stale oracle still shows a pre-default price. The seller reclaims full notional; the buyer receives nothing. `terminateForNonPayment()` correctly checks `!oracle.isStale()` (line 222) — the same guard was omitted from `expire()`.

**Fix:** Added `require(!oracle.isStale(prot.refAsset), "iCDS: oracle stale");` before the spot price comparison in the Active branch of `expire()`.

---

## HIGH Findings

### P3-LIQ-5 — InsuranceFund.coverShortfall() blocked by pause — silently fires unnecessary ADL

**Contract:** `src/risk/InsuranceFund.sol:125` / `src/risk/LiquidationEngine.sol:246,253`
**Status:** ✅ FIXED (Pass 3)

`InsuranceFund.coverShortfall()` retains `whenNotPaused`. The `LiquidationEngine` calls it inside a `try/catch` that swallows ALL reverts — including pause reverts — identically to "insufficient balance." When the IF is paused (even briefly for maintenance), every concurrent liquidation fires ADL against profitable counterparties instead of using the fully-funded InsuranceFund. This is an inappropriate escalation to the last-resort mechanism.

**Fix:** Removed `whenNotPaused` from `InsuranceFund.coverShortfall()`. Coverage of liquidation shortfalls must be pause-immune.

---

### P3-LIQ-9 — Vault.chargeFee() has whenNotPaused — liquidation penalty charging reverts if Vault paused

**Contract:** `src/core/Vault.sol:216` / `src/risk/LiquidationEngine.sol:217,220,229`
**Status:** ✅ FIXED (Pass 3)

`Vault.chargeFee()` retains `whenNotPaused`. `LiquidationEngine.liquidate()` calls `chargeFee()` three times for liquidator reward, insurance share, and residual sweep. If Vault is paused, all three calls revert, rolling back the entire liquidation including the `updatePosition()` call that already settled PnL. Vault already exempts `settlePnL()` (P2-HIGH-4); `chargeFee()` in the liquidation flow must be equally exempt.

**Fix:** Removed `whenNotPaused` from `Vault.chargeFee()`.

---

### P3-CLOB-1 (HIGH) — Fill array hardcoded to 100 — OOB panic if >100 price levels crossed

**Contract:** `src/orderbook/MatchingEngine.sol` (fill array allocation)
**Status:** 🔴 OPEN

Market orders crossing >100 price levels trigger `Panic(0x32)` (array index out-of-bounds), reverting the entire transaction. This is a liveness failure for large market orders in thin books.

**Recommended fix:** Use a dynamic `fills.push()` pattern or cap fills at `MAX_FILLS` with a return value indicating partial fill.

---

### P3-CLOB-2 (HIGH) — Market order price=0 bypasses slippage guard

**Contract:** `src/orderbook/OrderBook.sol`
**Status:** 🔴 OPEN

Market orders submitted with `price=0` skip the `maxPrice > 0` slippage guard. The order fills at any price without protection.

**Recommended fix:** For market orders, require explicit maxPrice parameter (for buys) / minPrice (for sells), or reject price=0 outright.

---

### P3-CLOB-4 (HIGH) — Multi-subaccount margin bypass

**Contract:** `src/shariah/ShariahRegistry.sol` / `src/orderbook/OrderBook.sol`
**Status:** 🔴 OPEN

Margin check at order placement is per-subaccount snapshot. Multiple subaccounts under one wallet each pass the margin check independently at different times, allowing aggregate exposure well above the 5x limit.

**Recommended fix:** Aggregate margin check across all subaccounts owned by same wallet, or restrict each wallet to one subaccount.

---

### P3-CLOB-6 (HIGH) — Insolvent maker reverts taker fill

**Contract:** `src/orderbook/MatchingEngine.sol`
**Status:** 🔴 OPEN

If a maker's `updatePosition()` call reverts (insufficient margin), the entire taker transaction reverts. A maker who goes insolvent after placing an order can grief all takers at their price level.

**Recommended fix:** Wrap maker `updatePosition()` in try/catch; on revert, cancel the maker order and continue to next order.

---

### P3-CLOB-10 (HIGH) — _isReducingPosition bypass — oversized reduce orders bypass margin check

**Contract:** `src/orderbook/OrderBook.sol`
**Status:** 🔴 OPEN

`_isReducingPosition` check uses a snapshot of position size. A reduce-only order larger than the current position is classified as "reducing" and skips the margin check, but the flip portion opens a new margined position without IMR validation.

**Recommended fix:** Split reduce orders into two sub-orders: (1) close existing, (2) open new opposing — each subject to independent margin checks.

---

### P3-LIQ-2 (HIGH) — Shortfall computed using pre-penalty balance — understates true shortfall

**Contract:** `src/risk/LiquidationEngine.sol:236`
**Status:** 🔴 OPEN

`shortfallTokens = lossTokens - balanceBeforeClose`. `balanceBeforeClose` is captured before the penalty is deducted. The actual available collateral at shortfall evaluation time is `balanceBeforeClose - actualPenalty`. Shortfall is understated by the full penalty amount on every liquidation with a non-zero penalty.

**Recommended fix:** Capture post-penalty balance for the shortfall formula: `shortfallTokens = lossTokens > (balanceBeforeClose - actualPenalty) ? lossTokens - (balanceBeforeClose - actualPenalty) : 0`.

---

### P3-LIQ-3 (HIGH) — No self-liquidation guard — position owner extracts liquidator fee

**Contract:** `src/risk/LiquidationEngine.sol:159`
**Status:** 🔴 OPEN

`liquidate()` has no check that `msg.sender != owner(subaccount)`. Position owner can self-liquidate, receiving 50% of the liquidation penalty back, halving their effective cost.

**Recommended fix:** Import ISubaccountManager; add `require(msg.sender != ISubaccountManager(address(marginEngine.subaccountManager())).getOwner(subaccount), "LE: self-liquidation");`.

---

### P3-LIQ-4 (HIGH) — ADL participant list not sorted by PnL — first-50 pre-fillable by adversary

**Contract:** `src/risk/AutoDeleveraging.sol:119-167`
**Status:** 🔴 OPEN

ADL iterates `participants[0..49]` in insertion order. No PnL-based sorting. An adversary pre-filling 49 of 50 slots with zero-PnL accounts can prevent real counterparties from being reached.

**Recommended fix:** Accept caller-supplied `bytes32[] calldata rankedParticipants` array, validated on-chain for `unrealizedPnl > 0`.

---

### P3-CROSS-1 (HIGH) — Governance timelock bypass — proposal executable before veto window closes

**Contract:** `src/governance/GovernanceModule.sol`
**Status:** 🔴 OPEN

Proposal is executable at T+48h; veto window remains open until T+72h. A proposal can be executed while still vetable.

**Recommended fix:** Make execution available only after `max(timelock, vetoWindow)` has elapsed.

---

### P3-CROSS-2 (HIGH) — ShariahRegistry.setShariahBoard() onlyOwner — DAO can replace Shariah board

**Contract:** `src/shariah/ShariahRegistry.sol`
**Status:** 🔴 OPEN

Governance (owner) can unilaterally replace the Shariah board without board approval, undermining the separation of powers.

**Recommended fix:** Require multi-sig of current Shariah board to approve board changes.

---

### P3-CROSS-3 (HIGH) — OracleAdapter.setIndexPrice/setMarkPrice unbounded — arbitrary price injection

**Contract:** `src/oracle/OracleAdapter.sol`
**Status:** 🔴 OPEN

Owner can set any oracle price without bounds, triggering mass liquidations. Should require prices within e.g. ±10% of current.

---

### P3-CROSS-4 (HIGH) — BatchSettlement has no on-chain validation — fabricated settlements possible

**Contract:** `src/settlement/BatchSettlement.sol`
**Status:** 🔴 OPEN

Authorized operator can submit arbitrary settlement items without on-chain proof. Requires merkle root validation or other proof mechanism.

---

### P3-CROSS-6 (HIGH) — ComplianceOracle.assetCompliance never enforced by MatchingEngine

**Contract:** `src/shariah/ComplianceOracle.sol`
**Status:** 🔴 OPEN

Compliance attestations are stored but never read by MatchingEngine or ShariahRegistry. Shariah compliance enforcement is advisory only.

**Recommended fix:** MatchingEngine.placeOrder() calls `complianceOracle.checkCompliance(marketId)` and reverts on non-compliant markets.

---

### P3-INST-2 (HIGH) — Buyer locked out of settlement when paused during settlement window

**Contract:** `src/instruments/iCDS.sol:178`
**Status:** 🔴 OPEN

`settle()` has `whenNotPaused`. If paused during the 7-day settlement window, buyer cannot settle. After window expires, seller reclaims full notional via `expireTrigger()`.

---

### P3-INST-3 (HIGH) — Grace period runs during oracle outage — forced termination by seller

**Contract:** `src/instruments/iCDS.sol:215`
**Status:** 🔴 OPEN

Grace period counts oracle outage time. Buyer cannot pay premium (oracle stale check in `_computePremium` reverts), but grace period expires. Seller calls `terminateForNonPayment()` once oracle recovers.

---

### P3-INST-4 (HIGH) — Fixed recoveryRateWad enables spurious trigger at momentary price dip

**Contract:** `src/instruments/iCDS.sol:170`
**Status:** 🔴 OPEN

Recovery floor is fixed at open. A momentary oracle dip below floor (from a flash price anomaly) lets keeper permanently trigger settlement, even if price recovers seconds later.

---

### P3-INST-6 (HIGH) — TakafulPool.payClaim() missing oracle staleness check

**Contract:** `src/instruments/TakafulPool.sol`
**Status:** 🔴 OPEN

Claims can be paid against stale floor price, enabling claims during oracle outages when the real price may not be below floor.

---

### P3-INST-7 (HIGH) — TakafulPool no contribution cooldown — same-block contribute+claim

**Contract:** `src/instruments/TakafulPool.sol`
**Status:** 🔴 OPEN

Contributor can contribute and claim in same block via compromised keeper. Minimum cooldown required between contribution and first claim eligibility.

---

### P3-INST-8 (HIGH) — No claim-to-tabarru ratio cap — cheap OTM coverage drains pool

**Contract:** `src/instruments/TakafulPool.sol`
**Status:** 🔴 OPEN

Large deep-OTM protection claims can drain the entire tabarru fund.

---

### P3-INST-11 (HIGH) — EverlastingOption extreme parameters cause expWad overflow

**Contract:** `src/instruments/EverlastingOption.sol`
**Status:** 🔴 OPEN

With extreme volatility or time-to-expiry parameters, `expWad()` overflows, causing `quotePut`/`quoteCall` to permanently revert. All instruments depending on EverlastingOption pricing are bricked.

**Recommended fix:** Add parameter bounds validation in `quotePut`/`quoteCall`.

---

### P3-INST-15 (HIGH) — PerpetualSukuk call strike uses token-decimal normalization not USD

**Contract:** `src/instruments/PerpetualSukuk.sol`
**Status:** 🔴 OPEN

Call strike calculated using token decimals rather than USD value makes non-stablecoin sukuk deeply in-the-money by default, draining issuer reserve immediately at maturity.

---

## MEDIUM Findings (24 total — abbreviated)

| ID | Contract | Title |
|---|---|---|
| P3-CLOB-3 | OrderBook | Commit-reveal front-running burns victim's hash slot |
| P3-CLOB-5 | OrderBook | Stale tailOrderId in drained price levels |
| P3-CLOB-7 | OrderBook | spread() underflow revert on inverted book |
| P3-CLOB-8 | OrderBook | cancelOrder missing ownership check — any auth can cancel any order |
| P3-CLOB-9 | MarginEngine | updatePosition missing nonReentrant |
| P3-CLOB-12 | OrderBook | O(N²) sort on price level removal — gas DoS |
| P3-FE-2 | FundingEngine | Signed integer truncation drops sub-dust funding payments |
| P3-ME-3 | MarginEngine | Stale oracle skip asymmetry — equity skips but IMR/MMR don't |
| P3-ME-4 | MarginEngine | updatePosition accepts non-existent subaccounts — funds locked |
| P3-ME-5 | MarginEngine | Partial liquidation formula ignores realized PnL |
| P3-ME-6 | MarginEngine | IMR/MMR revert on uninitialized oracle (price=0) |
| P3-ME-7 | MarginEngine | Margin check skipped on position flip |
| P3-ME-8 | MarginEngine | _subaccountMarkets invariant fragile in flip branch |
| P3-FE-3 | FundingEngine | Dual funding computation with independent clamping |
| P3-V-1 | Vault | settlePnL positive credit has no backing invariant |
| P3-CROSS-5 | FeeEngine | _getTier() is dead stub — always returns base tier |
| P3-CROSS-7 | GovernanceModule | Self-call guard bypassed via indirect contract call |
| P3-CROSS-8 | OracleAdapter | updateIndexPrice() permissionless — staleness clock manipulation |
| P3-CROSS-9 | ShariahRegistry | Owner can replace ME/Oracle references without board approval |
| P3-CROSS-10 | ComplianceOracle | Board member addition onlyOwner — Sybil stuffing |
| P3-CROSS-11 | GovernanceModule | setGovernanceToken() unbounded proposal loop — DoS |
| P3-LIQ-6 | LiquidationEngine | Partial liquidation math ignores realized PnL |
| P3-LIQ-7 | AutoDeleveraging | ADL closeSize floor division — residual shortfall permanent |
| P3-LIQ-8 | InsuranceFund | weeklyClaimsSum lastClaimReset to block.timestamp — cooldown renewable |
| P3-LIQ-10 | AutoDeleveraging | ADL updatePosition also blocked by ME pause (root same as P3-LIQ-1) |
| P3-LIQ-11 | AutoDeleveraging | Stale zero-position participants waste ADL iterations |
| P3-INST-5 | iCDS | Mid-function transfer to untrusted seller in acceptProtection |
| P3-INST-9 | PerpetualSukuk | Issuer can self-subscribe and arbitrage call upside |
| P3-INST-10 | PerpetualSukuk | Profit distribution first-come-first-served — last investors starved |
| P3-INST-13 | iCDS | openProtection() missing staleness check |
| P3-INST-14 | TakafulPool | Surplus reserve uses cumulative claims — blocks distribution |

## LOW Findings (8 total)

| ID | Contract | Title |
|---|---|---|
| P3-CLOB-13 | OrderBook | Expired commits never cleaned — hash slot poisoning |
| P3-CLOB-14 | OrderBook | Maker rebate uses taker's fee tier |
| P3-ME-9 | MarginEngine | No deactivateMarket function |
| P3-V-2 | Vault | chargeFee whenNotPaused blocks liquidation penalty — FIXED (P3) |
| P3-OA-1 | OracleAdapter | Frozen mark price applies extreme constant funding |
| P3-CROSS-12 | FeeEngine | Precision loss — maker rebate zero on small trades |
| P3-CROSS-13 | BatchSettlement | feeEngine is mutable — inconsistency with immutables |
| P3-CROSS-14 | MatchingEngine | setFeeEngine() accepts address(0) |
| P3-LIQ-12 | LiquidationEngine | TOCTOU race between fundBalance() and coverShortfall() |
| P3-LIQ-14 | LiquidationEngine | No readiness guard on liquidate() — unconfigured IF/ADL |

## INFO Findings (7 total)

| ID | Contract | Title |
|---|---|---|
| P3-CLOB-11 | SubaccountManager | Subaccount ID scheme — no exploitable issue |
| P3-CLOB-15 | OrderBook | PositionUpdated event — no issue |
| P3-ME-2 | MarginEngine | **INVALID** — int256 overflow claim incorrect (int256.max ≈ 5.79×10⁷⁶, BTC at $100k = 1e23, no overflow) |
| P3-ME-9 | MarginEngine | No deactivateMarket — operational improvement |
| P3-CROSS-15 | GovernanceModule | Flash loan governance defense via 256-block snapshot — informational |
| P3-CROSS-16 | ShariahRegistry | validateOrder() only checks at placement — leverage drift noted |
| P3-INST-12 | EverlastingOption | _lnWad lacks explicit int256 range check on denomWad — latent |
| P3-LIQ-13 | LiquidationEngine | Minimum penalty of 1 raw token is decimals-sensitive — benign |

---

## Fixes Applied in Pass 3

| Finding | Severity | Contract | Change |
|---|---|---|---|
| P3-FE-1 | CRITICAL | FundingEngine.sol:109 | Removed `whenNotPaused` from `updateFunding()` |
| P3-LIQ-1 | CRITICAL | MarginEngine.sol:231 | Removed `whenNotPaused` from `updatePosition()` |
| P3-INST-1 | CRITICAL | iCDS.sol:205 | Added `require(!oracle.isStale(...))` in `expire()` |
| P3-LIQ-5 | HIGH | InsuranceFund.sol:125 | Removed `whenNotPaused` from `coverShortfall()` |
| P3-LIQ-9/P3-V-2 | MEDIUM/HIGH | Vault.sol:216 | Removed `whenNotPaused` from `chargeFee()` |

---

## Cumulative Audit Status (All 3 Passes)

| Pass | Findings | Critical | High | Fixed |
|---|---|---|---|---|
| Pass 1 | 142 | 5 | 18 | 142 (100%) |
| Pass 2 | 74 | 5 | 22 | 74 (100%) |
| Pass 3 | 62 | 3 | 20 | 6 (CRITICALs + 2 HIGH) |
| **Total** | **278** | **13** | **60** | **222** |

**High/Medium/Low findings from Pass 3 require prioritized remediation before external audit submission.**

The most urgent remaining opens are: P3-CLOB-1 (OOB panic on large market orders), P3-LIQ-3 (self-liquidation), P3-LIQ-4 (ADL griefing), P3-CROSS-6 (compliance never enforced), P3-INST-11 (EverlastingOption overflow).
