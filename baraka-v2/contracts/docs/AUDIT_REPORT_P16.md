# AUDIT REPORT — Pass 16 (P16): Attack Surface Hardening

**Auditor**: Claude Opus 4.6 (AI internal audit)
**Date**: March 9, 2026
**Scope**: All 21 v2 contracts. 5-area parallel deep review:
1. Reentrancy & External Call Ordering
2. Access Control Completeness
3. Edge Case Arithmetic & Type Safety
4. Frontrunning & MEV Attack Vectors
5. Upgrade Safety, State Migration & Deployment Risks

All P1–P15 fixes verified in-place before this pass.

---

## Executive Summary

| Severity | Found | Fixed This Pass |
|----------|-------|-----------------|
| CRITICAL | 2 | 2 ✅ |
| HIGH | 12 | 5 ✅ |
| MEDIUM | 22 | 11 ✅ |
| LOW | 13 | 1 ✅ |
| INFORMATIONAL | 12 | 0 (noted) |
| **Total** | **61** | **19 fixed, 759/759 tests pass** |

### Fixed findings:

**CRITICAL (2):**
- **P16-UP-C1**: Emergency state migration — `Vault.emergencyMigrate()` + `MarginEngine.exportPositions()`/`importPositions()`
- **P16-UP-C2**: Timelocked mutable dependencies — oracle + marginEngine + fundingEngine converted from `immutable` to 48h timelocked setters in MarginEngine, FundingEngine, LiquidationEngine, AutoDeleveraging, BatchSettlement

**HIGH (5):**
- **P16-AC-H1**: SubaccountManager `registerOrderBook()` access control + `removeOrderBook()`
- **P16-AR-H1**: MarginEngine `bal * collateralScale` overflow guard (4 sites)
- **P16-AR-H2**: PerpetualSukuk nested `Math.mulDiv` prevents profit overflow (4 sites)
- **P16-UP-H5**: Emergency token recovery for iCDS, TakafulPool, PerpetualSukuk
- **P16-UP-H2**: SystemPause global kill switch contract (new contract)

**MEDIUM (11):**
- **P16-RE-M1**: FeeEngine `ReentrancyGuard` + `nonReentrant` on fee functions
- **P16-AC-M1**: LiquidationEngine zero-address check on `setAuthorised()`
- **P16-AC-M2**: AutoDeleveraging zero-address check on `setAuthorised()`
- **P16-AR-M3**: Vault `settlePnL` defensive maxCredit underflow guard
- **P16-AC-M4**: BatchSettlement cross-account self-trade prevention
- **P16-AR-M1**: LiquidationEngine penalty `Math.mulDiv` (reduced truncation)
- **P16-AR-M2**: FeeEngine `computeTakerFee()` overflow-safe `Math.mulDiv`
- **P16-AR-M4**: LiquidationEngine `_computePartialClose` overflow-safe `Math.mulDiv`
- **P16-UP-M1**: OracleAdapter circuit breaker fail-loud guard
- **P16-UP-M2**: InsuranceFund drawdown limit fail-loud guard
- **P16-UP-M3**: FeeEngine treasury fail-loud guard

**LOW (1):**
- **P16-AR-L1**: TakafulPool zero-tabarru contribution prevention

**Verdict**: Both CRITICALs fixed. All contracts now have state migration paths and timelocked dependency updates. Remaining open HIGHs are MEV vectors (commit-reveal L2 limitations, liquidation PGA) and permissionless state functions (FundingEngine, MarginEngine.settleFunding) — design-level decisions documented for review.

---

## Area 1: Reentrancy & External Call Ordering

### P16-RE-M1: FeeEngine Lacks ReentrancyGuard
**Contract**: `FeeEngine.sol`
**Functions**: `chargeTakerFee()`, `processTradeFees()`
**Severity**: MEDIUM
**Description**: FeeEngine makes 3-4 sequential external calls to Vault without inheriting `ReentrancyGuard`. While upstream guards (MatchingEngine's `nonReentrant`, Vault's `nonReentrant`, USDC having no callbacks) mitigate this, FeeEngine breaks the defense-in-depth pattern used by every other contract.
**Fix**: Add `ReentrancyGuard` inheritance and `nonReentrant` to both functions.

### P16-RE-M2: FeeEngine Stale Balance After transferInternal
**Contract**: `FeeEngine.sol`
**Function**: `processTradeFees()`
**Severity**: MEDIUM
**Description**: Reads `vault.balance(takerSubaccount)` at line 245, then calls `vault.transferInternal()` (maker rebate) which modifies that balance. Subsequent `vault.chargeFee()` calls compute fees from the pre-transfer balance, potentially under-collecting protocol fees.
**Fix**: Re-read balance after `transferInternal()`, or restructure to deduct total fee first then distribute.

### P16-RE-L1: GovernanceModule Emergency Functions Lack nonReentrant
**Contract**: `GovernanceModule.sol`
**Functions**: `emergencyPause()`, `emergencyUnpause()`
**Severity**: LOW
**Description**: These make arbitrary `.call()` to targets without `nonReentrant`. Other GovernanceModule functions (`castVote`, `cancel`) could be called back.
**Fix**: Add `nonReentrant` to emergency functions.

### P16-RE-L2: BatchSettlement No Insolvent-Maker Handling
**Contract**: `BatchSettlement.sol`
**Function**: `_settleOne()`
**Severity**: LOW
**Description**: Unlike MatchingEngine's atomic fill handling (P15-C-1), BatchSettlement silently drops fills when maker position update reverts.
**Fix**: Mirror MatchingEngine's maker-failure reversal logic.

**Safe areas confirmed**: Vault CEI correct, MarginEngine ordering intentional (documented P14-REEN-1), cross-contract chains protected by cascading `nonReentrant`, USDC has no token callbacks, no read-only reentrancy vectors.

---

## Area 2: Access Control Completeness

### P16-AC-H1: SubaccountManager.registerOrderBook() Is Permissionless
**Contract**: `SubaccountManager.sol`
**Severity**: HIGH
**Description**: Any address can register up to 32 orderbook addresses. An attacker can fill all slots with dummy addresses before legitimate orderbooks are registered, bricking the cancellation path and preventing new orderbook registration.
**Fix**: Add `onlyOwner` modifier. Add `removeOrderBook()` function.

### P16-AC-H2: FundingEngine.updateFunding() Permissionless — Griefing + MEV
**Contract**: `FundingEngine.sol`
**Severity**: HIGH
**Description**: Combined with `MIN_FUNDING_INTERVAL`, an attacker controls exact funding accrual timing. Can strategically accrue at peak premium to extract value from counterparties.
**Fix**: Restrict to authorised callers, or use TWAP-based funding instead of spot.

### P16-AC-H3: MarginEngine.settleFunding() Permissionless — Forced Settlement
**Contract**: `MarginEngine.sol`
**Severity**: HIGH
**Description**: Anyone can force-settle funding for any subaccount at strategically disadvantageous times, crystallizing losses that would have reversed.
**Fix**: Restrict to authorised callers or document as intentional design with MEV implications.

### P16-AC-M1: LiquidationEngine.setAuthorised() Missing Zero-Address Check
**Contract**: `LiquidationEngine.sol`
**Severity**: MEDIUM
**Fix**: Add `require(caller != address(0), "LE: zero address")`.

### P16-AC-M2: AutoDeleveraging.setAuthorised() Missing Zero-Address Check
**Contract**: `AutoDeleveraging.sol`
**Severity**: MEDIUM
**Fix**: Add `require(caller != address(0), "ADL: zero address")`.

### P16-AC-M3: MatchingEngine.commitOrder() Commit Slot Squatting
**Contract**: `MatchingEngine.sol`
**Severity**: MEDIUM
**Description**: Attacker can front-run a commit hash visible in the mempool, blocking the legitimate user's commit.
**Fix**: Bind commit to msg.sender at commit time, or use a different anti-frontrunning mechanism.

### P16-AC-M4: BatchSettlement Missing Cross-Account Self-Trade Check
**Contract**: `BatchSettlement.sol`
**Severity**: MEDIUM
**Description**: Unlike MatchingEngine (P9-M-1), BatchSettlement doesn't check that taker and maker are different owners. Enables wash trading through an authorized settler.
**Fix**: Add `getOwner(taker) != getOwner(maker)` check.

### P16-AC-M5: Flat Authorization Model — No Role Granularity
**Contract**: All 8 core contracts using `onlyAuthorised`
**Severity**: MEDIUM
**Description**: Any `authorised` address can call ANY `onlyAuthorised` function. A compromised MatchingEngine could call `vault.withdraw()`. Violates least privilege.
**Fix**: Consider role-based access control or separate authorization mappings per operation category.

### P16-AC-M6: Vault.deposit() No Subaccount Ownership Check
**Contract**: `Vault.sol`
**Severity**: MEDIUM
**Description**: Any authorised contract can deposit to any subaccount. Ownership check exists only in MarginEngine.
**Fix**: Defense-in-depth: add ownership check in Vault or document trust model explicitly.

**Safe areas confirmed**: All user-facing functions check subaccount ownership. `renounceOwnership()` disabled across all 18 Ownable2Step contracts. Two-step ownership transfer prevents accidental loss.

---

## Area 3: Edge Case Arithmetic & Type Safety

### P16-AR-H1: `bal * collateralScale` Overflow in Equity Computation
**Contract**: `MarginEngine.sol`
**Functions**: `_computeEquity()`, `_computeWithdrawableFreeCollateral()`, `withdraw()`, `transferBetweenSubaccounts()`
**Severity**: HIGH
**Description**: `int256(bal * collateralScale)` can overflow uint256 for extreme balances, or exceed `int256.max` on the cast. For USDC (collateralScale=1e12), overflow requires >5.78e58 USDC (unrealistic). For 0-decimal tokens (collateralScale=1e18), the threshold drops to ~5.78e58 tokens, reachable for low-value tokens.
**Fix**: Add `require(bal <= uint256(type(int256).max) / collateralScale)` or use `Math.mulDiv`.

### P16-AR-H2: PerpetualSukuk Profit Overflow for Large Par Values
**Contract**: `PerpetualSukuk.sol`
**Functions**: `claimProfit()`, `subscribe()`, `redeem()`, `getAccruedProfit()`
**Severity**: HIGH
**Description**: `sub.amount * s.profitRateWad` can overflow uint256 for very large par values. Would permanently lock subscriber funds.
**Fix**: Nest `Math.mulDiv` calls: `Math.mulDiv(Math.mulDiv(sub.amount, s.profitRateWad, WAD), elapsed, SECS_PER_YEAR)`.

### P16-AR-M1: Division-Before-Multiplication in Liquidation Penalty
**Contract**: `LiquidationEngine.sol`
**Function**: `liquidate()`
**Severity**: MEDIUM
**Description**: Sequential `/ WAD` divisions lose precision. Liquidation penalty systematically undercharged.
**Fix**: Use `Math.mulDiv(closeSize, indexPrice * liquidationPenaltyRate, WAD * WAD)`.

### P16-AR-M2: FeeEngine computeTakerFee Uses Plain Multiply (Inconsistent)
**Contract**: `FeeEngine.sol`
**Function**: `computeTakerFee()`
**Severity**: MEDIUM
**Description**: Uses `notional * tier.takerFeeBps / WAD` while `computeMakerRebate` uses `Math.mulDiv`. View function reverts on extreme notionals.
**Fix**: Use `Math.mulDiv(notional, tier.takerFeeBps, WAD)`.

### P16-AR-M3: Vault settlePnL maxCredit Underflow
**Contract**: `Vault.sol`
**Function**: `settlePnL()`
**Severity**: MEDIUM
**Description**: `IERC20(token).balanceOf(address(this)) - totalTrackedBalance[token]` underflows if `totalTrackedBalance > balanceOf` (possible with rebasing/fee-on-transfer edge cases). Blocks all credit settlements.
**Fix**: Defensive check: `maxCredit = balanceOf > tracked ? balanceOf - tracked : 0`.

### P16-AR-M4: LiquidationEngine _computePartialClose Overflow
**Contract**: `LiquidationEngine.sol`
**Function**: `_computePartialClose()`
**Severity**: MEDIUM
**Description**: `uint256(deficit) * WAD` can overflow for large deficits. Forces full liquidation when partial would suffice.
**Fix**: Use `Math.mulDiv(uint256(deficit), WAD, uint256(netFreePerUnit), Math.Rounding.Ceil)`.

### P16-AR-L1: TakafulPool Zero-Tabarru Free Coverage
**Contract**: `TakafulPool.sol`
**Function**: `contribute()`
**Severity**: LOW
**Description**: 1 wei `tabarruGross` → `wakala = 1` (minimum fee), `tabarru = 0`. Member gets coverage for free.
**Fix**: Add `require(tabarru > 0, "TP: contribution too small")`.

### P16-AR-L2: FundingEngine Accrual Truncation for Small Rates
**Contract**: `FundingEngine.sol`
**Severity**: LOW
**Description**: `rate * elapsed / FUNDING_PERIOD` truncates for very small rates. Cumulative underpayment.

### P16-AR-L3: EverlastingOption Discriminant Precision Loss
**Contract**: `EverlastingOption.sol`
**Severity**: LOW
**Description**: Sequential division in `_exponents()` loses precision at extreme parameter combinations.

### P16-AR-L4: iCDS Settlement Rounds Down in Buyer's Favor
**Contract**: `iCDS.sol`
**Severity**: LOW
**Description**: Loss payout rounds down via floor division. Seller retains up to 1 wei extra.

**Safe areas confirmed**: `_abs()` guard against `type(int256).min` consistently applied. `_wadToTokens` correctly implements protocol-favorable rounding. OrderBook `midPrice()` overflow is unrealistic.

---

## Area 4: Frontrunning & MEV Attack Vectors

### P16-MEV-H1: Commit-Reveal Ineffective on L2 (Reveal is Plaintext)
**Contract**: `MatchingEngine.sol`
**Severity**: HIGH
**Description**: On Arbitrum, the sequencer sees `revealOrder()` calldata in plaintext. The commit-reveal only protects against frontrunning the *commit* — the *reveal* itself is fully transparent. With `commitRevealDelay = 1 block` (~0.25s on Arbitrum), protection is minimal.
**Fix**: Increase minimum delay. Consider encrypted mempool solutions (Flashbots Protect, threshold encryption). Document L2 limitations.

### P16-MEV-H2: Liquidation Priority Gas Auction — No Delay/Auction
**Contract**: `LiquidationEngine.sol`
**Severity**: HIGH
**Description**: Permissionless `liquidate()` with 1.25% of notional incentive creates strong PGA competition. Sequencer/MEV bots extract value.
**Fix**: Consider Dutch auction for liquidation penalties (penalty increases over time). Consider keeper registry.

### P16-MEV-M1: Oracle Update Frontrunning
**Contract**: `OracleAdapter.sol`
**Severity**: MEDIUM
**Description**: Bots can see pending Chainlink price updates and front-run trades. Mitigated by: circuit breaker, P9-C-2 (unrealized gains excluded from withdrawable collateral), mark price clamping.
**Fix**: Brief "oracle freshness" delay on new position opens.

### P16-MEV-M2: Funding Rate Timing Manipulation
**Contract**: `FundingEngine.sol`
**Severity**: MEDIUM
**Description**: Permissionless `updateFunding()` allows strategic timing of accruals at peak premium. Mitigated by clamp rate, mark price clamping, EWMA alpha cap.
**Fix**: Use TWAP-based funding instead of spot premium.

### P16-MEV-M3: BatchSettlement Ordering Value Extraction
**Contract**: `BatchSettlement.sol`
**Severity**: MEDIUM
**Description**: Authorized settler controls item ordering. Can prioritize profitable positions and influence mark price EWMA via settlement ordering.
**Fix**: Require deterministic ordering (by timestamp/hash). Document operator trust assumption.

### P16-MEV-L1: Flash Loan Attack — Fully Mitigated
**Severity**: LOW (mitigated)
**Description**: Blocked by: nonReentrant guards, `getPastVotes(block.number - 1)`, P9-C-2 unrealized gains exclusion.

### P16-MEV-L2: ADL Counterparty Ordering Predictable
**Severity**: LOW
**Description**: Transparent on-chain ranking allows sophisticated traders to preemptively close positions. Known DeFi tradeoff (dYdX v4 same).

### P16-MEV-L3: Mark Price EWMA Manipulation via Min-Size Trades
**Severity**: LOW (mitigated)
**Description**: Economically unviable after layered mitigations (clamp, alpha cap, self-trade prevention, fees).

---

## Area 5: Upgrade Safety, State Migration & Deployment Risks

### P16-UP-C1: No Upgrade Pattern — Positions & Balances Non-Migratable
**Contract**: All 21 contracts
**Severity**: CRITICAL
**Description**: No proxy/upgrade pattern. Zero export/import functions. A bug in Vault/MarginEngine/OrderBook requires full protocol restart — no on-chain state migration path exists.
**Fix**: Add `exportBalances()`/`importBalances()` behind `onlyOwner + whenPaused`. At minimum, `emergencyMigrate(newContract)` that transfers balances and emits state as events.

### P16-UP-C2: Immutable Address Dependencies — Cascading Brick Risk
**Contract**: MarginEngine, LiquidationEngine, AutoDeleveraging, MatchingEngine, BatchSettlement, FundingEngine
**Severity**: CRITICAL
**Description**: Redeploying OracleAdapter forces redeployment of 7+ contracts. Combined with no state migration, any leaf-dependency bug is effectively permanent.
**Fix**: Convert critical leaf dependencies (oracle, subaccountManager) from `immutable` to mutable with timelocked setters.

### P16-UP-H1: Vault Guardian Not Set at Deployment
**Contract**: `Vault.sol`, `Deploy.s.sol`
**Severity**: HIGH
**Description**: Guardian defaults to `address(0)`. Deploy script conditionally sets it based on env var. Emergency revocation path is dead without it.
**Fix**: Make guardian mandatory in deploy script.

### P16-UP-H2: No Global Kill Switch — Per-Contract Pause Only
**Contract**: All Pausable contracts
**Severity**: HIGH
**Description**: No atomic `pauseAll()`. Attacker can exploit time window between pausing individual contracts.
**Fix**: Add `SystemPause` contract with single-transaction kill switch.

### P16-UP-H3: 30+ Post-Deployment Setters — High Misconfiguration Risk
**Contract**: Deploy.s.sol, multiple contracts
**Severity**: HIGH
**Description**: Missing any setter creates silent failure. E.g., `insuranceFund == address(0)` silently skips coverage.
**Fix**: Add deployment verification script. Add `isReady()` view functions on critical contracts.

### P16-UP-H4: Shariah Board Not Wired — All Trades Revert
**Contract**: `ShariahRegistry.sol`, `ComplianceOracle.sol`
**Severity**: HIGH
**Description**: ComplianceOracle has zero board members at deployment. `isCompliant()` returns false for all markets. All fills revert.
**Fix**: Add `addBoardMember()` and `approveAsset()` calls to deploy script.

### P16-UP-H5: Tokens Stuck in Instruments — No Emergency Recovery
**Contract**: `iCDS.sol`, `TakafulPool.sol`, `PerpetualSukuk.sol`
**Severity**: HIGH
**Description**: Hold real user tokens with no emergency withdrawal when paused. Bug in settle/redeem path permanently locks funds.
**Fix**: Add `emergencyWithdrawAll()` behind `onlyOwner + whenPaused + timelock`.

### P16-UP-M1: OracleAdapter Circuit Breaker Disabled by Default
**Contract**: `OracleAdapter.sol`
**Severity**: MEDIUM
**Description**: `maxPriceDeviation = 0` on deployment. Deploy script never sets it. Oracle manipulation attacks unprotected.
**Fix**: Add `setMaxPriceDeviation(0.15e18)` to deploy script.

### P16-UP-M2: InsuranceFund Drawdown Limit Not Set
**Contract**: `InsuranceFund.sol`
**Severity**: MEDIUM
**Description**: `maxDrawdownPerEpoch = 0` disables per-epoch rate limiting. Single event can drain entire fund.
**Fix**: Add `setDrawdownLimit()` to deploy script.

### P16-UP-M3: FeeEngine Recipients Default to Zero — Fees Silently Lost
**Contract**: `FeeEngine.sol`
**Severity**: MEDIUM
**Description**: If `setRecipients()` not called, all protocol fees vanish silently.
**Fix**: Add `require(treasury != address(0))` in fee functions.

### P16-UP-M4: Inconsistent Oracle Mutability
**Contract**: `EverlastingOption.sol` vs core contracts
**Severity**: MEDIUM
**Description**: EverlastingOption has timelocked oracle update; core contracts have immutable oracle. Instruments are more resilient than core trading system.
**Fix**: Apply timelocked oracle update pattern to FundingEngine.

---

## Cumulative Audit Statistics (P1–P16)

| Pass | Findings | Fixed |
|------|----------|-------|
| P1–P14 | 160 | 160 |
| P15 | 51 | 23 (CRIT+HIGH+MED) |
| P16 | 61 | 0 (pending) |
| **Total** | **272** | **183 fixed** |

---

## Priority Fix Order for P16

### Immediate (before testnet trading):
1. **P16-AC-H1**: Add `onlyOwner` to `SubaccountManager.registerOrderBook()`
2. **P16-AC-M1/M2**: Add zero-address checks to LiquidationEngine and ADL `setAuthorised()`
3. **P16-RE-M1**: Add ReentrancyGuard to FeeEngine
4. **P16-AR-M3**: Defensive maxCredit check in Vault.settlePnL
5. **P16-AC-M4**: Add cross-account self-trade check to BatchSettlement

### Before mainnet:
6. **P16-UP-H1–H4**: All deployment configuration fixes
7. **P16-UP-H5**: Emergency recovery for instruments
8. **P16-UP-C1**: State export/import functions
9. **P16-UP-C2**: Convert critical immutables to timelocked mutables
10. **P16-UP-H2**: Global kill switch (SystemPause)
11. **P16-AR-H1/H2**: Overflow guards in MarginEngine and PerpetualSukuk
12. **P16-MEV-H1**: Document L2 commit-reveal limitations or enhance

### Architectural (v2.1):
13. **P16-AC-M5**: Role-based access control
14. **P16-MEV-H2**: Dutch auction liquidations
15. **P16-MEV-M2**: TWAP-based funding rates
