# Remaining Documented Items — Design Decisions (Not Code-Fixable)

**Date**: March 10, 2026
**Scope**: All items from P9–P21 internal audit passes that remain as intentional design decisions, architectural trade-offs, or informational notes. These are NOT code bugs — they are documented choices that require protocol governance, economic analysis, or v2.1 planning to address.

**Total internal audit**: 21 passes, ~302 findings, ~237 fixed in code. The ~65 items below are the remainder.

---

## Table of Contents

1. [MEV & Frontrunning Vectors](#1-mev--frontrunning-vectors)
2. [Access Control & Authorization Architecture](#2-access-control--authorization-architecture)
3. [Governance & Admin Gaps](#3-governance--admin-gaps)
4. [Oracle & Price Feed Design](#4-oracle--price-feed-design)
5. [Economic & Fee Design](#5-economic--fee-design)
6. [Instrument-Specific (iCDS, TakafulPool, PerpetualSukuk, EverlastingOption)](#6-instrument-specific)
7. [Migration & Upgrade Considerations](#7-migration--upgrade-considerations)
8. [Gas & Scalability](#8-gas--scalability)
9. [Informational Notes (Intentional Design)](#9-informational-notes)

---

## 1. MEV & Frontrunning Vectors

These are inherent to L2 CLOB architecture. Mitigated by layered defenses but not fully eliminable on-chain.

### P16-MEV-H1: Commit-Reveal Ineffective on L2 (Reveal is Plaintext)
- **Contract**: MatchingEngine.sol
- **Issue**: On Arbitrum, the sequencer sees `revealOrder()` calldata in plaintext. The commit-reveal only protects the *commit* — the *reveal* is fully transparent. With 1-block delay (~0.25s), protection is minimal.
- **Mitigations in place**: Commit-reveal delay ≥ 1 block (P10-H-6), commit hash includes chainId + address(this) (P10-H-5)
- **Future**: Consider encrypted mempool (Flashbots Protect, threshold encryption) or increase minimum delay.

### P16-MEV-H2: Liquidation Priority Gas Auction — No Dutch Auction
- **Contract**: LiquidationEngine.sol
- **Issue**: Permissionless `liquidate()` with 1.25% notional incentive creates PGA competition. Sequencer/MEV bots extract value.
- **Mitigations in place**: Partial liquidation reduces incentive size, InsuranceFund epoch drawdown limit
- **Future**: Consider Dutch auction for liquidation penalties (penalty increases over time). Consider keeper registry with rotation.

### P16-MEV-M1: Oracle Update Frontrunning
- **Contract**: OracleAdapter.sol
- **Issue**: Bots can see pending Chainlink price updates and front-run trades.
- **Mitigations in place**: Circuit breaker, P9-C-2 unrealized gains excluded from withdrawable collateral, mark price ±10% clamping, EWMA alpha cap 20%
- **Accepted risk**: Standard for all on-chain perp DEXs.

### P16-MEV-M2: Funding Rate Timing Manipulation
- **Contract**: FundingEngine.sol
- **Issue**: Permissionless `updateFunding()` allows strategic timing of accruals at peak premium.
- **Mitigations in place**: Clamp rate, mark price clamping, EWMA alpha cap, MIN_FUNDING_INTERVAL
- **Future**: TWAP-based funding instead of spot premium (v2.1).

### P16-MEV-M3: BatchSettlement Ordering Value Extraction
- **Contract**: BatchSettlement.sol
- **Issue**: Authorized settler controls item ordering. Can influence mark price EWMA via settlement ordering.
- **Mitigations in place**: Operator trust assumption documented, EWMA clamping
- **Future**: Require deterministic ordering (by timestamp/hash).

### P16-MEV-L1: Flash Loan Attack — Fully Mitigated
- **Status**: LOW (mitigated). Blocked by nonReentrant, getPastVotes(block.number - SNAPSHOT_DELAY), P9-C-2 unrealized gains exclusion.

### P16-MEV-L2: ADL Counterparty Ordering Predictable
- **Issue**: Transparent on-chain ranking allows sophisticated traders to preemptively close positions.
- **Status**: Known DeFi tradeoff (dYdX v4 has same design).

### P16-MEV-L3: Mark Price EWMA Manipulation via Min-Size Trades
- **Status**: LOW (mitigated). Economically unviable after layered mitigations (clamp, alpha cap, self-trade prevention, fees).

---

## 2. Access Control & Authorization Architecture

### P16-AC-H2: FundingEngine.updateFunding() Is Permissionless
- **Contract**: FundingEngine.sol
- **Issue**: Anyone can trigger funding accrual for any market. Combined with MIN_FUNDING_INTERVAL, controls exact timing.
- **Design rationale**: Permissionless keeper pattern (same as dYdX v4). Restricting to authorized callers would require a dedicated keeper.
- **Mitigations in place**: Clamp rate, MIN_FUNDING_INTERVAL, EWMA clamping

### P16-AC-H3: MarginEngine.settleFunding() Is Permissionless
- **Contract**: MarginEngine.sol
- **Issue**: Anyone can force-settle funding for any subaccount at strategically disadvantageous times.
- **Design rationale**: Necessary for liquidation path — funding must be settleable by LiquidationEngine. Making it permissionless avoids trusted keeper dependency.
- **Future**: Consider restricting to (a) subaccount owner, (b) authorized callers, (c) anyone after a delay.

### P16-AC-M3: MatchingEngine Commit Slot Squatting
- **Contract**: MatchingEngine.sol
- **Issue**: Attacker can front-run a commit hash visible in the mempool, blocking the legitimate user's commit.
- **Design rationale**: Commit hashes include msg.sender (P10-H-5), so same-hash collision requires same sender. Squatting requires predicting the hash, which requires knowing the order details — but reveal calldata is visible on L2.
- **Future**: Bind commit to msg.sender at commit time more tightly.

### P16-AC-M5: Flat Authorization Model — No Role Granularity
- **Contracts**: All 8 core contracts using `onlyAuthorised`
- **Issue**: Any `authorised` address can call ANY `onlyAuthorised` function. A compromised MatchingEngine could call `vault.withdraw()`.
- **Design rationale**: Simplicity for v2.0 — all authorized contracts are deployed by same deployer. Role-based ACL adds significant complexity.
- **Future**: Role-based access control in v2.1 (separate authorization mappings per operation category).

### P16-AC-M6: Vault.deposit() No Subaccount Ownership Check
- **Contract**: Vault.sol
- **Issue**: Any authorised contract can deposit to any subaccount.
- **Design rationale**: Ownership check exists in MarginEngine. Vault is a low-level ledger — caller is trusted.
- **Future**: Defense-in-depth ownership check in Vault.

### P16-RE-L2: BatchSettlement No Insolvent-Maker Handling
- **Contract**: BatchSettlement.sol
- **Issue**: Unlike MatchingEngine's atomic fill handling (P15-C-1), BatchSettlement silently drops fills when maker position update reverts.
- **Design rationale**: BatchSettlement is for authorized off-chain matcher. Insolvent-maker fills should have been filtered off-chain.
- **Future**: Mirror MatchingEngine's maker-failure reversal logic.

---

## 3. Governance & Admin Gaps

### P19-M-8: GovernanceModule Governance Token Is Permanently Immutable
- **Contract**: GovernanceModule.sol
- **Issue**: P5-H-6 made `governanceToken` immutable-after-set. If BRKX token contract is migrated, the DAO track is permanently bricked.
- **Design rationale**: Prevents a compromised Shariah multisig from replacing the token with one they control 100% of. Security > flexibility.
- **Future**: Shariah-multisig-gated migration path with long timelock (e.g., 30 days + DAO vote).

### P21-M-4: GovernanceModule Has No Owner or Emergency Admin
- **Contract**: GovernanceModule.sol
- **Issue**: `shariahMultisig` is the only admin. If key is lost before `setGovernanceToken()`, governance is permanently bricked.
- **Design rationale**: GovernanceModule is controlled by governance (proposals + Shariah board), not a single owner. Adding an owner creates a centralization vector.
- **Future**: Consider emergency admin with very long timelock (7+ days) for recovery only.

### P19-M-9/M-10: Inconsistent Timelock Coverage Across Contracts
- **Issue**: Oracle and MarginEngine dependencies have 48h timelocks in LE/ME/ADL/BS/FE. But `setADL()`, `setInsuranceFund()`, `setFundingEngine()` (LE), and `setOracle()`, `setFeeEngine()`, `setADL()` (MatchingEngine) remain instant-swap.
- **Design rationale**: Incremental hardening — most critical dependencies timelocked first. Remaining setters protected by Ownable2Step (two-step transfer) and multisig ownership.
- **Future**: Apply timelocked pattern to all remaining critical dependency setters.

### P21-M-5: Vault `migrated` Flag is Global
- **Contract**: Vault.sol
- **Issue**: `emergencyMigrate()` sets a global `migrated = true` flag. If multi-collateral is enabled, migrating one token blocks `unpause()` for all tokens.
- **Design rationale**: Current deployment is single-collateral (USDC). Global flag is simpler and correct.
- **Future**: Make `migrated` per-token if multi-collateral is added.

---

## 4. Oracle & Price Feed Design

### P10-I-1: setIndexPrice Cannot Update chainlinkReferencePrice During Prolonged Outage
- **Contract**: OracleAdapter.sol
- **Issue**: `setIndexPrice` (admin override) is bounded to [chainlinkReferencePrice/2, chainlinkReferencePrice*2]. During a prolonged outage, if real price moves >2x from stale reference, admin cannot set the correct price.
- **Design rationale**: Safety bounds prevent compromised admin from setting arbitrary prices. The 2x bound covers most scenarios.
- **Future**: Add `setChainlinkReferencePrice()` behind timelocked governance or multisig.

### P16-UP-M4: Inconsistent Oracle Mutability
- **Issue**: EverlastingOption has timelocked oracle update; core contracts have timelocked oracle update (P16-UP-C2 fix). FundingEngine has immutable oracle in constructor only.
- **Design rationale**: FundingEngine oracle is set via timelocked update (P16-UP-C2), matching core contracts.
- **Status**: Resolved by P16-UP-C2.

### P19-L-4: OracleAdapter Circuit Breaker Cannot Be Disabled Once Enabled
- **Contract**: OracleAdapter.sol
- **Issue**: `setMaxPriceDeviation` has minimum 1% (P15-M-3 fix). 50% max deviation may be insufficient for black swan events (LUNA-style 99% drops).
- **Design rationale**: Circuit breaker is a safety net. Disabling it entirely is worse than temporary inconvenience during black swans. Admin can use `setIndexPrice()` for manual override.
- **Accepted risk**: Standard. Admin override covers black swan scenarios.

---

## 5. Economic & Fee Design

### P14-VAL-1: FeeEngine.setTier() Ordering Check Skips Single-Tier Edge Case
- **Contract**: FeeEngine.sol
- **Issue**: A protocol with only 1 tier (unlikely) can set any threshold. Base tier (index 0) always has minBRKX = 0.
- **Status**: Documented as known edge case. Protocol deploys with 4 tiers.

### P20-M-1: FeeEngine Tier Structure Allows Zero Net Protocol Revenue
- **Contract**: FeeEngine.sol
- **Issue**: `takerBps >= makerBps` (P19-L-6) prevents negative fees, but allows taker fee = maker rebate (net zero). Protocol has no minimum-fee-floor.
- **Future**: Add `require(takerBps - makerBps >= MIN_NET_FEE_BPS)` if protocol sustainability requires minimum revenue per trade.

### P15-L-19: Fee Tier Update Takes Effect Immediately
- **Contract**: FeeEngine.sol
- **Issue**: Fee changes apply to trades already in the orderbook. Could front-run pending trades.
- **Design rationale**: Timelocked fee changes would require significant architectural changes. Fee changes are infrequent admin operations.
- **Accepted risk**: Standard for DEXs.

---

## 6. Instrument-Specific

### P11-EO-1: `useOracleKappa` Flag Is a Placeholder
- **Contract**: EverlastingOption.sol
- **Issue**: `_getKappaAnnual()` ignores the `useOracleKappa` flag, always returning `kappaAnnualWad`. If `useOracleKappa = true` and `kappaAnnualWad = 0`, pricing is degenerate.
- **Design rationale**: Oracle kappa integration is planned for v2.1. The flag is a forward-compatible schema element.
- **Mitigation**: Deploy only with `useOracleKappa = false` and `kappaAnnualWad > 0` until oracle integration is complete.

### P11-TP-1: TakafulPool Claim Reverts When Pool Balance < 1/maxClaimRatio Tokens
- **Contract**: TakafulPool.sol
- **Issue**: Sub-threshold balance (e.g., < 10 USDC with 10% maxClaimRatio) is permanently locked.
- **Design rationale**: Near-depletion edge case. Pool should never reach this state in normal operation.
- **Accepted risk**: Marginal, <$10 locked.

### P15-L-6: Liquidation Penalty Hardcoded at 5%
- **Contract**: LiquidationEngine.sol
- **Issue**: Should be configurable per market (volatile markets may need higher penalties).
- **Future**: Add per-market `liquidationPenaltyRate` in MarketParams.

### P15-L-8: InsuranceFund Staking Has No Lock Period
- **Contract**: InsuranceFund.sol
- **Issue**: Flash-loan stake → claim → unstake theoretically possible.
- **Mitigations in place**: Distribution cooldown (7 days), surplus distribution requires positive surplus.
- **Accepted risk**: Low — no practical attack vector with current cooldowns.

### P15-L-16: TakafulPool Premium Period Hardcoded to 30 Days
- **Contract**: TakafulPool.sol
- **Future**: Make configurable per pool.

### P15-L-17: PerpetualSukuk No Minimum Denomination
- **Contract**: PerpetualSukuk.sol
- **Issue**: Dust sukuk positions possible.
- **Future**: Add minimum denomination (e.g., 100 USDC).

### P15-L-18: iCDS No Maximum Coverage Amount Per Policy
- **Contract**: iCDS.sol
- **Issue**: Single policy could exhaust pool.
- **Mitigations in place**: Pool balance caps payouts naturally.
- **Future**: Add per-policy coverage limit.

### P19-M-11: TakafulPool emergencyRecoverTokens Desyncs poolBalance
- **Contract**: TakafulPool.sol
- **Issue**: Can transfer pool's own collateral without adjusting `poolBalance` accounting.
- **Design rationale**: Break-glass function (paused + onlyOwner). Manual poolBalance correction required after use.

### P20-M-9: PerpetualSukuk emergencyRecoverTokens Can Extract Tracked Reserves
- **Contract**: PerpetualSukuk.sol
- **Issue**: Same pattern as P19-M-11 (TakafulPool). Can transfer tracked collateral without adjusting internal accounting.
- **Design rationale**: Break-glass function. Complex per-token reserve aggregation risks new bugs. Manual correction required.

### P16-AR-L2: FundingEngine Accrual Truncation for Small Rates
- **Contract**: FundingEngine.sol
- **Issue**: `rate * elapsed / FUNDING_PERIOD` truncates for very small rates. Cumulative underpayment.
- **Accepted risk**: Negligible at realistic funding rates.

### P16-AR-L3: EverlastingOption Discriminant Precision Loss
- **Contract**: EverlastingOption.sol
- **Issue**: Sequential division in `_exponents()` loses precision at extreme parameter combinations.
- **Accepted risk**: Extreme parameters are outside normal operating range.

### P16-AR-L4: iCDS Settlement Rounds Down in Buyer's Favor
- **Contract**: iCDS.sol
- **Issue**: Loss payout rounds down via floor division. Seller retains up to 1 wei extra.
- **Design rationale**: Protocol-favorable rounding (consistent with Vault, FeeEngine).

---

## 7. Migration & Upgrade Considerations

### P16-UP-H1: Vault Guardian Not Set at Deployment
- **Contract**: Vault.sol, Deploy.s.sol
- **Issue**: Guardian defaults to address(0). Deploy script conditionally sets based on env var.
- **Fix status**: Deploy script updated. Operational procedure documented.

### P16-UP-H3: 30+ Post-Deployment Setters — High Misconfiguration Risk
- **Issue**: Missing any setter creates silent failure (e.g., insuranceFund == address(0) skips coverage).
- **Fix status**: Deployment verification script added. `isReady()` view functions on critical contracts.
- **Ongoing risk**: Operational — deployment checklist must be followed.

### P16-UP-H4: Shariah Board Not Wired — All Trades Revert
- **Issue**: ComplianceOracle has zero board members at deployment.
- **Fix status**: Deploy script updated with board member and asset approval calls.

---

## 8. Gas & Scalability

### P10-I-2 / P19-L-1: `markets[]` Array Grows Unboundedly
- **Contract**: MarginEngine.sol
- **Issue**: No `deactivateMarket()` function. After many markets, keeper functions scale linearly including zero-OI markets.
- **Design rationale**: Markets are expected to number < 50 in foreseeable future. Deactivation adds state complexity.
- **Future**: Add `marketActive` flag and filter in iteration loops.

### P11-OB-1: `_subaccountOrders` Array Not Auto-Compacted on Single-Order Cancel
- **Contract**: OrderBook.sol
- **Issue**: Dead entries accumulate until explicit `compactOrders()` call or `cancelAllOrders()`.
- **Fix status**: P17-HIGH-2 added AUTO_COMPACT_THRESHOLD = 400 for inline compaction.
- **Remaining**: Document that keepers should call `compactOrders()` periodically for high-frequency market makers.

### P14-GRIEF-1: ADL Participant List Can Contain Stale Zero-Size Entries
- **Contract**: AutoDeleveraging.sol
- **Issue**: MAX_ADL_SCAN = 200. Many stale entries reduce effective scan budget.
- **Design rationale**: ADL is last-resort. Scan limit sized for reasonable participation.
- **Future**: Add `compactParticipants(bytes32 marketId)` keeper function.

### P15-L-1: OrderBook Cancel Emits Event Before State Change (CEI Minor)
- **Contract**: OrderBook.sol
- **Status**: Gas griefing only. Event ordering is cosmetic.

### P15-L-2: OrderBook No Minimum Order Size
- **Contract**: OrderBook.sol
- **Issue**: Allows spam dust orders.
- **Mitigations in place**: Gas cost per order, MIN_TICK enforcement on limit orders, MAX_ACTIVE_ORDERS cap.
- **Future**: Add MIN_ORDER_SIZE per market.

### P15-L-3: MatchingEngine `placeOrder` Doesn't Validate `orderType` Enum Range
- **Contract**: MatchingEngine.sol
- **Issue**: Invalid orderType reverts at matching, not placement (wastes gas).
- **Accepted risk**: Defensive — Solidity enum validation at ABI decode handles most cases.

---

## 9. Informational Notes (Intentional Design)

These are not findings — they document intentional design choices confirmed during audit.

### P9-I-1: GovernanceModule execute() With Arbitrary Target
- Governance proposals can call arbitrary external contracts. `target != address(this)` prevents self-calls. This is by design — governance should be powerful.
- **Mitigation**: Shariah board veto window (72h). Proposal review process.

### P9-I-2: FeeEngine Staker Share Lost When stakerPool Is Zero
- When `stakerPool == address(0)`, staker share redirected to treasury. If treasury is also zero (should never happen), fees are burned.
- **Status**: Acceptable — treasury is always set via `setRecipients()` with zero-address check (P16-UP-M3).

### P14-VAL-2: OrderBook Market Orders Don't Enforce MIN_TICK
- Market orders execute at maker's limit price (already validated at placement). Correct by design.

### P14-REEN-1: MarginEngine updatePosition Settlement Before Position Update
- Funding/PnL settlement calls vault.settlePnL (ERC20 transfer) before pos.size is updated. Safe because:
  - `updatePosition` has `nonReentrant` (P10-H-2)
  - `vault.settlePnL` also has `nonReentrant`
  - Settlement uses old position state intentionally

### P15-I-1: Solidity 0.8.28 Compiler
- Consider 0.8.29 for minor gas optimizations. Not blocking.

### P15-I-2: OrderBook Red-Black Tree Gas Cost ~50k Per Insert
- Acceptable for Arbitrum L2 (~$0.01 per insert at current gas prices).

### P15-I-3: MatchingEngine Events Use indexed bytes32
- Correct for subgraph indexing.

### P15-I-4: MarginEngine Cross-Margin Mode Not Implemented
- Isolated-margin via subaccounts only. Cross-margin is v2.1.

### P15-I-5: Vault ERC4626-Like But Not Conformant
- Intentional per design — Vault is a ledger, not a yield vault.

### P15-I-6: GovernanceModule BRKX Token Voting — Snapshot-Based
- Uses `getPastVotes(snapshotBlock)` not live balance. Flash-loan resistant (256-block delay).

### P15-I-7: OracleAdapter Kappa Signal Stored On-Chain
- Unusual but functional. Required for EverlastingOption mean-reversion pricing.

### P15-I-8: FundingEngine Per-Second Continuous Funding
- Matches dYdX v4 model. Correct for perpetual instruments.

### P15-L-5: Vault Allows 0-Amount Deposits
- Wastes gas, no exploit. Defensive check adds gas to all deposits.

### P15-L-9: ShariahRegistry `setScholar` Doesn't Check Address is EOA
- Contract could be set as scholar. Acceptable — multisig is a contract.

### P15-L-10: ComplianceOracle No Batch Attestation Function
- Gas-inefficient for multi-user onboarding. Acceptable for current scale.

### P15-L-11: GovernanceModule No Vote Delegation
- Limits participation. Vote escrow (veBRKX) planned for future.

### P15-L-13: FundingEngine `setFundingRateCap` Allows 0
- Disables funding entirely. Admin-only — operational decision, not a vulnerability.

### P15-L-14: BatchSettlement No Idempotency Check on Settlement IDs
- Same settlement could be applied twice. Mitigated by authorized caller only (off-chain matcher controls IDs).

### P15-L-15: EverlastingOption Exercise Doesn't Check Expiry
- Perpetual by design — no expiry exists.

### P15-L-20: Vault `emergencyWithdraw` Has No Cooldown
- Admin can drain immediately. Intentional for break-glass scenarios. Protected by Ownable2Step + multisig.

### P18-L-2: Liquidated Event actualPenalty May Not Match Vault Transfer
- Informational for off-chain accounting systems. Event is computed locally; actual transfer may differ due to cap-at-balance logic.

### P18-L-3: MatchingEngine Missing Events for setOracle/setADL
- Several admin setters lack event emissions. Low priority.

### P19-L-3: LiquidationEngine pnlRealized May Diverge From Actual Settlement
- Informational for off-chain accounting. Actual settlement amount may differ due to cap-at-balance.

### P20-I-1: BatchSettlement Gas Limit Not Enforced
- `settleBatch()` has MAX_BATCH_SIZE = 100 (P15-M-6 fix). Off-chain keepers control batch sizes within this limit.

### P20-I-2: GovernanceModule Proposal Description Not Indexed
- Dynamic strings cannot be indexed in Solidity events. Standard limitation.

### P20-L-4: OrderBook totalSize Not Zeroed in Cleanup
- Verified as non-issue — totalSize is already 0 when cleanup removes a level.

### P21-I-1: MatchingEngine _isReducingPosition Based on Pre-Funding Position Size
- Funding changes PnL/equity, not position size. Correct behavior.

### P21-I-2: MarginEngine _wadToTokens Rounding Accumulation
- Protocol-favorable rounding loses at most 1 token unit per settlement. Economically negligible.

### P21-I-3: GovernanceModule execute() Cannot Send ETH
- `target.call{value: 0}` prevents governance from executing payable functions. Intentional — GovernanceModule rejects ETH via `receive()`.

### P21-L-2: ComplianceOracle boardMembers Array Unbounded
- Practically limited by real-world Shariah board sizes (< 20 members).
- **Fix status**: P21-L-2 → added MAX_BOARD_MEMBERS = 20 cap. RESOLVED.

---

## Summary by Category

| Category | Count | v2.1 Items |
|----------|-------|------------|
| MEV & Frontrunning | 8 | Dutch auction liquidations, TWAP funding, encrypted mempool |
| Access Control | 6 | Role-based ACL, Vault ownership check |
| Governance & Admin | 4 | Token migration path, emergency admin, full timelock coverage |
| Oracle & Price Feed | 3 | Reference price update, circuit breaker flexibility |
| Economic & Fee Design | 3 | Minimum net fee, timelocked fee changes |
| Instrument-Specific | 11 | Min denomination, coverage caps, configurable periods |
| Migration & Upgrade | 3 | Deployment verification (addressed) |
| Gas & Scalability | 6 | Market deactivation, participant compaction |
| Informational Notes | 24 | N/A (design documentation only) |
| **Total** | **~68** | |

---

## Recommendation for External Auditors

When submitting to Code4rena / Sherlock / Trail of Bits:

1. **Share this document** — prevents re-discovery of known design decisions
2. **Flag MEV items** as "known, mitigated, L2 limitations" — avoids wasted auditor time
3. **Flag flat authorization model** (P16-AC-M5) as intentional v2.0 simplification with v2.1 upgrade path
4. **Highlight the 3 break-glass functions** (Vault emergencyMigrate, TakafulPool/PerpetualSukuk emergencyRecoverTokens) as intentionally powerful with manual accounting correction required
5. **Governance token immutability** (P19-M-8) and **GovernanceModule no-owner** (P21-M-4) are conscious security-over-flexibility trade-offs with documented rationale
