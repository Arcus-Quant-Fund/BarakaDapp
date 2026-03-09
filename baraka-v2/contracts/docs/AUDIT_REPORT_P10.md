# AUDIT REPORT — Pass 10 (P10): Deep State Machine & Cross-Contract Invariant Analysis

**Auditor**: Claude Sonnet 4.6 (AI internal audit)
**Date**: March 9, 2026
**Scope**: All 20 Baraka v2 contracts (~14,568 SLOC); focused on cross-contract state invariants, execution-path fallthrough, and deployment wiring
**Method**: Trace every execution path through `_processFill`, `settlePnL`, `updatePosition`, and `executeADL`. Audit cross-contract state assumptions. Review Deploy.s.sol wiring completeness. Verify all P1–P9 fixes are live at deployment.

---

## Executive Summary

| Severity | Found | Fixed |
|----------|-------|-------|
| CRITICAL | 2 | — |
| HIGH | 8 | — |
| MEDIUM | 8 | — |
| LOW | 6 | — |
| INFORMATIONAL | 2 | — |
| **Total** | **26** | **0** |

P10 shifts focus from known DeFi exploit patterns to **state machine correctness**: execution paths that produce inconsistent contract state, invariant violations that accumulate silently across fills, and deployment gaps that leave prior audit fixes deactivated. The two CRITICAL findings are the most dangerous class — they silently corrupt fundamental protocol invariants (OI balance, vault solvency) without any on-chain signal.

The most urgent issues for pre-deployment resolution are **P10-C-1**, **P10-C-2**, and **P10-H-8**. P10-H-8 is particularly insidious: fixes already coded for prior audit passes are unreachable in production because the deploy script omits their wiring calls.

---

## CRITICAL

### P10-C-1: `_processFill` Fallthrough — Fees Charged and Oracle Updated After Insolvent-Maker Unwind; Taker Reversal Failure Silently Breaks OI Invariant

**File**: `src/orderbook/MatchingEngine.sol:390-425`
**Attack reference**: dYdX OI inflation ($9M, 2022)

**Root cause**: `_processFill` is structured as three sequential sections separated from the insolvent-maker catch block. The oracle `updateMarkPrice` call (line 406) and fee `processTradeFees` call (line 413) execute unconditionally after the maker `try/catch` block — including in the insolvent-maker path where the taker's position was reversed.

In the insolvent-maker path the sequence is:
1. Taker position applied (`takerDelta`).
2. Maker `updatePosition` reverts → catch block runs.
3. Taker position reversed (`-takerDelta`).
4. **Code continues past the catch block.**
5. `oracle.updateMarkPrice(fill.price)` executes — EWMA is fed a phantom trade price for a fill that was unwound.
6. `feeEngine.processTradeFees(...)` executes — fees are charged against taker and maker for a fill that produced no position change.

Additionally, if the taker reversal in step 3 itself fails (inner try/catch silently swallows the error), the taker retains the applied `takerDelta` position while the maker has no corresponding position. Open interest becomes `|takerDelta|` on one side with zero on the other. No event is emitted for this state, no circuit breaker fires, and the `OI cap` added in P9-C-1 is never decremented — the cap silently becomes unrecoverable until manual admin intervention.

**Impact**:
- Fee extraction from users for economically null fills.
- Oracle EWMA contaminated by ghost fill prices, distorting funding rates and mark-based liquidations.
- In the taker-reversal-failure edge case: OI invariant permanently broken (sum of longs ≠ sum of shorts), creating unbounded funding settlement divergence and the same OI inflation attack vector documented in the dYdX $9M incident.

**Fix**:
```solidity
// In _processFill(), replace the current try/catch block with an explicit return:
} catch {
    // Insolvent maker path — reverse taker and return. Do NOT proceed to
    // fee/oracle updates for a fill that produced no net position change.
    bool takerReversed = false;
    try marginEngine.updatePosition(
        fill.takerSubaccount, marketId, -takerDelta, fill.price
    ) {
        takerReversed = true;
    } catch {
        // Taker reversal failed — OI invariant broken. Halt this market immediately.
        emit OIInvariantBroken(marketId, fill.takerSubaccount, takerDelta);
        // Trigger circuit breaker / pause this market
        _triggerMarketCircuitBreaker(marketId);
    }
    try ob.cancelOrder(fill.makerOrderId) {} catch {}
    emit MakerCancelledInsolvent(marketId, fill.makerOrderId, fill.makerSubaccount);
    if (!takerReversed) {
        emit TakerReversalFailed(marketId, fill.takerSubaccount, takerDelta);
    }
    return; // ← CRITICAL: skip oracle and fee updates for unwound fills
}
```

Add `OIInvariantBroken` and `TakerReversalFailed` events to the contract interface. Add a per-market circuit breaker flag that halts matching for that market without halting the full protocol.

---

### P10-C-2: Vault `settlePnL` Phantom Balances — `actualSettled` Return Value Ignored, Winner Credited Full Amount Regardless of Loser Solvency

**File**: `src/core/MarginEngine.sol:315, 324, 394` and `src/core/Vault.sol:187-208`

**Root cause**: `Vault.settlePnL()` returns `int256 actualSettled` — the amount actually transferred after capping at available balance for insolvent losers (implemented as `AUDIT FIX L0-H-1`). `MarginEngine.updatePosition()` calls `vault.settlePnL()` at three call sites but discards the return value at all three:

```solidity
// Line 315 — close with profit/loss:
vault.settlePnL(subaccount, collateralToken, _wadToTokens(pnl));   // return value discarded

// Line 324 — partial close PnL:
vault.settlePnL(subaccount, collateralToken, _wadToTokens(closePnl)); // return value discarded

// Line 394 — funding settlement:
vault.settlePnL(subaccount, collateralToken, _wadToTokens(-funding)); // return value discarded
```

When a loser's `settlePnL` call receives a negative `amount` and the loser has insufficient collateral, the vault caps the debit at the available balance and returns `actualSettled < amount`. The caller (MarginEngine) ignores this. The caller then proceeds to credit the winner's counterpart call with the full `amount`, not the capped `actualSettled`.

Over time, the vault issues more credits than it collects debits. The ERC-20 balance of the Vault contract does not grow to match `sum(_balances)`. Any trader attempting to withdraw in a depleted market will fail with a transfer error rather than a clean revert.

**Impact**: Silent vault insolvency. The protocol appears solvent by its own accounting but cannot fulfill withdrawals. This is structurally identical to fractional reserve collapse: the last withdrawers in any market bear the full accumulated bad debt. At scale (many small undercollateralised liquidations), the shortfall compounds daily.

**Fix**: At each call site, capture `actualSettled` and use it for the corresponding credit:

```solidity
// Example for close PnL (line 315):
int256 actualLoss  = vault.settlePnL(loserSubaccount,  collateralToken, _wadToTokens(-lossPnl));
int256 actualGain  = -actualLoss; // credit winner only what was actually collected
vault.settlePnL(winnerSubaccount, collateralToken, actualGain);
```

For funding (line 394): aggregate `actualSettled` across all funding payers before distributing to receivers; route any shortfall to the insurance fund before crediting receivers. If the insurance fund is also insufficient, the remainder must be socialized (ADL or reduced receiver credit) — leaving it as phantom balance is not acceptable.

---

## HIGH

### P10-H-1: ADL Storage Pointer Corrupted Mid-Iteration — `marketParticipants` Array Mutated During `executeADL` Loop

**File**: `src/risk/AutoDeleveraging.sol:153-231` and `src/core/MarginEngine.sol:574`
**Attack reference**: Hyperliquid JELLY ($13.5M, 2025)

**Root cause**: `executeADL()` takes a `bytes32[] storage participants = marketParticipants[marketId]` reference and iterates over it. Inside the loop, it calls `marginEngine.updatePosition()` for each counterparty. `updatePosition` may fully close the counterparty's position, which triggers `_cleanupPosition()`, which calls `adl.removeParticipant()`. `removeParticipant` performs a swap-and-pop on the same `participants` storage array that the outer loop is currently iterating.

The result is that a swap-and-pop at index `i` moves the element at `participants.length - 1` into position `i`, then decrements `participants.length`. The loop counter `i` then increments to `i+1`, skipping the element that was swapped into `i`. Elements are silently skipped; some counterparties are never evaluated for ADL.

**Impact**: ADL covers a smaller portion of the bankrupt position than intended. Shortfall is left uncovered. Insurance fund is charged for losses that available counterparties could have absorbed. In the worst case (many concurrent full-closes during ADL), the iteration skips the most profitable counterparties and the system takes maximum loss.

**Fix**: Copy the storage array into memory before iterating, or iterate in reverse (swap-and-pop from the end does not invalidate lower indices):

```solidity
// Option A — memory copy (gas cost scales with array length):
bytes32[] memory participantsSnapshot = marketParticipants[marketId];
for (uint256 i = 0; i < participantsSnapshot.length; i++) { ... }

// Option B — reverse iteration (O(1) extra gas, safe with swap-and-pop):
uint256 len = participants.length;
for (uint256 i = len; i > 0; ) {
    unchecked { --i; }
    // process participants[i]
}
```

---

### P10-H-2: `MarginEngine.updatePosition()` Missing `nonReentrant` — Reentrancy via ADL Callback

**File**: `src/core/MarginEngine.sol` (updatePosition function)
**Attack reference**: Hyperliquid JELLY ($13.5M, 2025) — partial-state reentrancy

**Root cause**: `updatePosition()` is not decorated with `nonReentrant`. During `_cleanupPosition()`, it calls `adl.removeParticipant()` (an external call to the ADL contract). A malicious or compromised ADL contract could re-enter `updatePosition()` at this point. At the moment of the callback, the position mapping has been deleted (`delete positions[subaccount][marketId]`) but the OI counters have not yet been decremented — the state is partially updated.

The re-entrant call sees a zeroed position but inflated OI, allowing it to open a new position in the same market while the OI cap check uses the stale (higher) denominator, bypassing the cap.

**Impact**: OI cap bypass via re-entrancy, same class as P9-C-1. A compromised ADL contract is an insider threat; this is a defence-in-depth gap that should be closed at the contract level regardless.

**Fix**: Add `nonReentrant` to `updatePosition()`. This is the standard fix and has no functional downside — `updatePosition()` should never be re-entered legitimately.

```solidity
function updatePosition(
    bytes32 subaccount,
    bytes32 marketId,
    int256 sizeDelta,
    uint256 fillPrice
) external override nonReentrant onlyAuthorised { ... }
```

---

### P10-H-3: Position Flip Bypasses IMR Check — Long-to-Short with Smaller Absolute Size Skips Margin Validation

**File**: `src/core/MarginEngine.sol:335-339`
**Attack reference**: Mango Markets ($117M, 2022) — insufficient margin enforcement on position direction change

**Root cause**: The initial margin requirement check at line 339 is guarded by:

```solidity
if (_abs(newSize) > _abs(oldSize)) {
    // IMR check
}
```

This condition is true only when the new absolute size is larger. In a position flip (e.g., long 100 → short 50), `_abs(newSize) = 50 < _abs(oldSize) = 100`, so the condition is false and the IMR check is entirely skipped — even though the trader has opened a brand-new short position of size 50.

**Impact**: A trader can flip from a large position to a new opposing position that they do not have sufficient margin to support, as long as the new position is smaller in absolute size. The MMR check (liquidation threshold) is still present, but the IMR check (entry margin) is the primary safeguard against undercollateralised position opening. Bypass of the IMR check allows entry into positions that are immediately at risk of liquidation.

**Fix**: The flip case must be handled separately. A flip always involves opening a new position in the opposing direction and must always pass the IMR check:

```solidity
bool isFlip = (oldSize > 0 && newSize < 0) || (oldSize < 0 && newSize > 0);
bool isIncreasing = _abs(newSize) > _abs(oldSize);
if (isFlip || isIncreasing) {
    // Full IMR check required
    uint256 absNotional = Math.mulDiv(_abs(newSize), oracle.getIndexPrice(marketId), WAD);
    uint256 imrRequired = absNotional * _marketParams[marketId].imr / WAD;
    require(int256(equity) >= int256(imrRequired), "ME: insufficient initial margin");
}
```

---

### P10-H-4: OracleAdapter Circuit Breaker First-Update Bypass — Malicious Feed Sets Arbitrary Anchor Price on Market Initialisation

**File**: `src/oracle/OracleAdapter.sol:167`
**Attack reference**: KiloEx oracle access control exploit ($7.5M, 2024)

**Root cause**: The circuit breaker condition added in P9-H-2 is:

```solidity
if (maxPriceDeviation > 0 && mo.lastIndexPrice > 0) {
    // deviation check
}
```

Both conditions must be true for the check to execute. On the first call to `updateIndexPrice()` for a new market, `mo.lastIndexPrice == 0`, so the circuit breaker is skipped entirely. A compromised or manipulated Chainlink feed can set an arbitrary anchor price on first call. All subsequent price updates are then constrained to ±`maxPriceDeviation` from this malicious anchor.

**Impact**: A compromised feed on market launch permanently anchors the circuit breaker to a manipulated baseline. All future circuit breaker checks are relative to the wrong reference. The attacker can then walk the price up or down by `maxPriceDeviation` per update until it reaches any desired value.

**Fix**: For the first update, validate the price against the Chainlink reference price (already stored as `mo.chainlinkReferencePrice` from `setMarketOracle`):

```solidity
if (maxPriceDeviation > 0) {
    uint256 reference = mo.lastIndexPrice > 0
        ? mo.lastIndexPrice
        : mo.chainlinkReferencePrice;  // use Chainlink anchor on first update
    if (reference > 0) {
        uint256 diff = price > reference ? price - reference : reference - price;
        require(diff * WAD / reference <= maxPriceDeviation, "OA: circuit breaker - price deviation too large");
    }
}
```

---

### P10-H-5: Commit-Reveal Hash Missing `chainId` and `address(this)` — Cross-Chain and Cross-Deployment Replay

**File**: `src/orderbook/MatchingEngine.sol:277-280`
**Attack reference**: Cross-chain replay — standard EIP-712 domain separation requirement

**Root cause**: The commit hash is computed as:

```solidity
bytes32 commitHash = keccak256(abi.encodePacked(
    marketId, subaccount, side, price, size, orderType, tif, nonce, msg.sender
));
```

Neither `block.chainid` nor `address(this)` is included. An order committed on Ethereum mainnet produces an identical hash on Arbitrum (same `chainId`-agnostic parameters). An order committed on a testnet deployment produces the same hash as a mainnet deployment of the same bytecode. An attacker who observes a valid commit on one chain/deployment can replay it on another where the trader has not committed.

**Impact**: Cross-chain and cross-deployment replay attacks. A trader on a testnet that has the same collateral token addresses as mainnet may inadvertently commit orders that can be replayed on mainnet by a MEV searcher.

**Fix**: Include domain separation in the commit hash:

```solidity
bytes32 commitHash = keccak256(abi.encodePacked(
    block.chainid,
    address(this),
    marketId, subaccount, side, price, size, orderType, tif, nonce, msg.sender
));
```

This mirrors the EIP-712 domain separator pattern and is a zero-cost fix.

---

### P10-H-6: `commitRevealDelay` Has No Minimum — Commit and Reveal in Same Transaction Defeats MEV Protection

**File**: `src/orderbook/MatchingEngine.sol:186-187`

**Root cause**: `setCommitRevealDelay(uint256 blocks)` has no lower bound:

```solidity
function setCommitRevealDelay(uint256 blocks) external onlyOwner {
    commitRevealDelay = blocks;
}
```

The `revealOrder()` check at line 282 is `block.number >= commitBlock + commitRevealDelay`. With `commitRevealDelay = 0`, this is satisfied in the same block. An owner (or governance action) can set delay to 0, and a malicious actor can commit and reveal in a single atomic transaction, seeing the full orderbook state before submitting — identical to having no MEV protection at all.

Note: P9-L-2 identified this as LOW. Upgrading to HIGH because this is an owner-settable parameter with no on-chain guard; the only protection is operational, not contractual.

**Fix**:

```solidity
function setCommitRevealDelay(uint256 blocks) external onlyOwner {
    require(blocks >= 1, "MaE: delay must be >= 1 block");
    require(blocks <= 256, "MaE: delay exceeds commit window");
    commitRevealDelay = blocks;
}
```

The upper bound prevents the owner from setting a delay that makes all commits expire before reveal (commit window is `commitRevealDelay + 256` blocks, so delay > 256 would mean the reveal window opens after the commit has already expired).

---

### P10-H-7: Resting Orders Survive Subaccount Closure — Fills Execute Against Orders from Non-Existent Subaccounts

**File**: `src/core/SubaccountManager.sol:65-71`, `src/orderbook/OrderBook.sol`

**Root cause**: `SubaccountManager.closeSubaccount()` sets `_exists[subaccountId] = false` but does not cancel or invalidate resting orders in the OrderBook. After closure, existing resting orders remain on the book with valid `orderId` entries.

When a taker fill matches against a closed subaccount's resting order, `_processFill` calls `marginEngine.updatePosition(fill.makerSubaccount, ...)`. `updatePosition` calls `subaccountManager.getOwner()` (not `exists()`) — the owner mapping is not cleared on closure, so this passes. The maker's position is opened on a subaccount the owner can no longer access via `placeOrder` (which checks `exists()`), but the position is now live and accruing funding.

**Impact**: Positions opened on closed subaccounts cannot be reduced by the owner (placeOrder rejects closed subaccounts). The subaccount's margin is trapped. If the position moves against the closed subaccount, it becomes liquidatable but the owner cannot self-hedge. Liquidation proceeds normally, but the owner has no recourse against unexpected fills after closure.

**Fix**: `closeSubaccount()` must cancel all resting orders before marking the subaccount as closed:

```solidity
function closeSubaccount(uint8 index) external {
    bytes32 subaccountId = _subaccountId(msg.sender, index);
    require(_exists[subaccountId], "SAM: not exists");
    // Cancel all resting orders across all registered orderbooks
    for (uint256 i = 0; i < registeredOrderBooks.length; i++) {
        try IOrderBook(registeredOrderBooks[i]).cancelAllOrders(subaccountId) {} catch {}
    }
    _exists[subaccountId] = false;
    emit SubaccountClosed(msg.sender, subaccountId);
}
```

Requires `SubaccountManager` to maintain a list of registered `OrderBook` addresses and `OrderBook` to implement `cancelAllOrders(bytes32 subaccount)`.

---

### P10-H-8: Deploy Script Missing 6 Wiring Calls — P1–P9 Audit Fixes Implemented in Code but Deactivated at Deployment

**File**: `script/Deploy.s.sol:233-315`

**Root cause**: `Deploy.s.sol` Phase 8 wiring section omits the following calls that are required to activate functionality implemented in the contracts:

| Missing Call | Effect of Omission |
|---|---|
| `batchSettlement.setFeeEngine(address(feeEngine))` | BatchSettlement never charges fees; fee bypass for all batch-settled trades |
| `feeEngine.setAuthorised(address(batchSettlement), true)` | BatchSettlement fee calls would revert even if wired above |
| `batchSettlement.setShariahRegistry(address(shariahRegistry))` | BatchSettlement skips Shariah compliance checks on all settlements |
| `liquidationEngine.setFundingEngine(address(fundingEngine))` | Liquidation does not settle outstanding funding before closing positions |
| `adl.setFundingEngine(address(fundingEngine))` | ADL does not settle funding before deleveraging; P10-M-8 ranking is also affected |
| `matchingEngine.setComplianceOracle(address(complianceOracle))` | ComplianceOracle attestation checks silently skipped for all matching-engine fills |

The ComplianceOracle integration was implemented in response to a prior audit pass. The `address(0)` guard in `_processFill` means it silently bypasses KYC/AML checks in production — the most directly exploitable gap.

**Impact**: Multiple security controls coded and audited across P1–P9 are non-functional in production. This is functionally equivalent to not having implemented the fixes. The dYdX OI incident ($9M) involved misconfigured risk parameters at deployment; this finding is in the same category.

**Fix**: Add all six wiring calls to `Deploy.s.sol` Phase 8. Also add a post-deployment validation function that asserts each critical address is non-zero:

```solidity
function _assertWiringComplete() internal view {
    require(batchSettlement.feeEngine() != address(0),         "Deploy: BS feeEngine not wired");
    require(batchSettlement.shariahRegistry() != address(0),   "Deploy: BS SR not wired");
    require(liquidationEngine.fundingEngine() != address(0),   "Deploy: LE FE not wired");
    require(adl.fundingEngine() != address(0),                 "Deploy: ADL FE not wired");
    require(matchingEngine.complianceOracle() != address(0),   "Deploy: ME CO not wired");
}
```

---

## MEDIUM

### P10-M-1: Stale `PriceLevel` on Level Reuse — Corrupted Linked List After Level Deletion and Re-creation at Same Price

**File**: `src/orderbook/OrderBook.sol` (`_cleanBidPrices`/`_cleanAskPrices`, `_addToLevel`)

**Root cause**: When all orders at a price level are cancelled or filled, `_cleanBidPrices`/`_cleanAskPrices` marks the level as `exists = false`. However, the `headOrderId` and `tailOrderId` fields on the `PriceLevel` struct are not zeroed out. When a new order arrives at the same price, `_addToLevel()` uses `tailOrderId == 0` to determine whether it is initialising a fresh level. Since `tailOrderId` retains the stale value from the previously-active level, `_addToLevel()` treats the level as already having a tail order and attempts to link the new order after it. The stale tail `orderId` no longer exists in the orders mapping (it was cancelled/filled). The new order is linked to a ghost node, producing a linked-list cycle or dead-end that breaks forward traversal during matching.

**Impact**: Future matching at that price level can skip orders, execute partial fills incorrectly, or loop infinitely (gas exhaustion). This can be triggered without special privileges by any trader who places and cancels enough orders to recycle a price level.

**Fix**: Zero out `headOrderId` and `tailOrderId` when a level is deactivated:

```solidity
function _deactivateLevel(bytes32 marketId, bool isBid, uint256 price) internal {
    PriceLevel storage level = isBid
        ? bidLevels[marketId][price]
        : askLevels[marketId][price];
    level.exists       = false;
    level.headOrderId  = bytes32(0);
    level.tailOrderId  = bytes32(0);
    level.totalSize    = 0;
}
```

---

### P10-M-2: `_computeWithdrawableFreeCollateral` Excludes Unrealized PnL but Not Positive Funding Receivables — Partial Bypass of P9-C-2

**File**: `src/core/MarginEngine.sol` (`_computeWithdrawableFreeCollateral`)

**Root cause**: The P9-C-2 fix excluded unrealized mark-to-market PnL from withdrawable free collateral. However, the implementation does not exclude unsettled funding receivables. A trader who is owed a large positive funding payment (e.g., held a short through a high positive funding rate period) has this amount reflected in their equity but it has not yet been transferred to the vault. The equity calculation includes it, and since it is not specifically excluded from the withdrawal buffer computation, it is withdrawable.

**Impact**: A trader can withdraw unsettled funding income before it is confirmed. If the counterparty funding payers are insolvent (their payments cannot be collected by FundingEngine), the withdrawn funding income becomes bad debt — the same insurance fund leak described in P9-C-2, now via funding receivables rather than mark PnL.

**Fix**: Extend the withdrawable free collateral computation to also exclude outstanding funding receivables:

```solidity
int256 pendingFunding = fundingEngine.pendingFundingReceivable(subaccount, marketId);
// Only subtract positive (owed to this account but not yet settled) funding
if (pendingFunding > 0) {
    equity -= pendingFunding;
}
```

---

### P10-M-3: `absNotional` Plain Multiplication Can Overflow — `_abs(newSize) * oracle.getIndexPrice()` Not Using `Math.mulDiv`

**File**: `src/core/MarginEngine.sol:335`

**Root cause**:

```solidity
uint256 absNotional = _abs(newSize) * oracle.getIndexPrice(marketId) / WAD;
```

`_abs(newSize)` is `uint256` (up to ~`1.15e77`). `oracle.getIndexPrice(marketId)` is `uint256` (WAD-scaled, typically `1e22` to `1e26` for high-value assets). The multiplication `_abs(newSize) * price` can overflow `uint256` for large positions in high-price markets. The rest of the codebase uses `Math.mulDiv` for all `size × price` operations (e.g., fee notional at line 417 uses `Math.mulDiv`), making this a clear inconsistency.

**Impact**: For a BTC market with `maxPositionSize = 100e18` (~100 BTC) at a price of `100_000e18` ($100k), the product is `100e18 * 100_000e18 = 1e25 * 1e18 = 1e43`, which overflows `uint256` (max ~`1.15e77`). At current prices this does not overflow, but at higher prices or larger position limits it will — causing `updatePosition` to revert for all users in that market (DoS).

**Fix**:

```solidity
uint256 absNotional = Math.mulDiv(_abs(newSize), oracle.getIndexPrice(marketId), WAD);
```

---

### P10-M-4: Epoch Drawdown Sliding Window Allows `2×maxDrawdownPerEpoch` at Epoch Boundary

**File**: `src/insurance/InsuranceFund.sol` (drawdown rate limiter added in P9-H-1)

**Root cause**: The epoch drawdown tracking uses a sliding window reset:

```solidity
if (block.timestamp >= epochStart[token] + epochDuration) {
    epochDrawdown[token] = 0;
    epochStart[token] = block.timestamp;
}
epochDrawdown[token] += amount;
require(epochDrawdown[token] <= balance * maxDrawdownPerEpoch / WAD, "IF: epoch drawdown exceeded");
```

In the final block before an epoch resets, an attacker drains `maxDrawdownPerEpoch - epsilon`. In the first block of the new epoch, they drain another `maxDrawdownPerEpoch`. The total extraction in a window of `epochDuration + 1 second` is `2 × maxDrawdownPerEpoch - epsilon`.

**Impact**: The effective rate limit is half the intended value. An attacker who can generate legitimate liquidation shortfalls (e.g., via P9-C-2 or well-timed positions) can drain twice the intended per-epoch cap.

**Fix**: Use a rolling window that tracks the total drawn in the last `epochDuration` seconds, not since the last reset:

```solidity
// Store a circular buffer of (timestamp, amount) pairs, or simplify:
// Track cumulative total and reset point; ensure new epoch starts from end of previous epoch:
epochStart[token] = epochStart[token] + epochDuration; // NOT block.timestamp
```

---

### P10-M-5: `setMaxOpenInterest` Emits No Event; `maxOpenInterest` Absent from `MarketCreated` Event — Off-Chain OI Cap Monitoring Blind

**File**: `src/core/MarginEngine.sol:184`

**Root cause**: `setMaxOpenInterest(bytes32 marketId, uint256 maxOI)` updates the critical `maxOpenInterest` parameter with no event emission. The `MarketCreated` event emitted at market creation also does not include the `maxOpenInterest` value set during `createMarket()`. Off-chain risk monitoring systems (dashboards, circuit breaker bots) cannot observe OI cap values or their changes from event logs alone.

**Impact**: An operator silently raising or lowering the OI cap (e.g., a compromised owner key) is undetectable by off-chain monitoring. This is a defence-in-depth gap, but given that the OI cap is the primary anti-manipulation control (P9-C-1), its changes must be auditable.

**Fix**:

```solidity
event MaxOpenInterestUpdated(bytes32 indexed marketId, uint256 oldMaxOI, uint256 newMaxOI);

function setMaxOpenInterest(bytes32 marketId, uint256 maxOI) external onlyOwner {
    uint256 old = _marketParams[marketId].maxOpenInterest;
    _marketParams[marketId].maxOpenInterest = maxOI;
    emit MaxOpenInterestUpdated(marketId, old, maxOI);
}
```

Also add `maxOpenInterest` to the `MarketCreated` event signature.

---

### P10-M-6: `ShariahRegistry` Permanent Halt — Only `shariahBoard` Can Unpause; No Governance Override

**File**: `src/shariah/ShariahRegistry.sol:151-153`

**Root cause**: `setHalt(bool halted)` is `onlyShariahBoard`. There is no secondary role (governance, timelock, emergency multisig) that can call `setHalt(false)`. If the Shariah board key is lost, stolen, or the multisig signers become unavailable, the protocol is permanently halted with no on-chain recovery path.

**Impact**: Permanent protocol freeze. All user funds are locked (positions cannot be reduced, withdrawals cannot be processed) until an off-chain social recovery process reconstitutes the board key — which has no defined on-chain procedure. This is operationally equivalent to an irreversible pause.

**Fix**: Add a time-locked governance override that can call `setHalt(false)` after a mandatory delay (e.g., 7 days) if the board has not acted:

```solidity
uint256 public haltOverrideProposedAt;
uint256 public constant HALT_OVERRIDE_DELAY = 7 days;

function proposeHaltOverride() external onlyOwner {
    require(_halted, "SR: not halted");
    haltOverrideProposedAt = block.timestamp;
    emit HaltOverrideProposed(block.timestamp);
}

function executeHaltOverride() external onlyOwner {
    require(_halted, "SR: not halted");
    require(haltOverrideProposedAt > 0, "SR: no override proposed");
    require(block.timestamp >= haltOverrideProposedAt + HALT_OVERRIDE_DELAY, "SR: override delay not elapsed");
    _halted = false;
    haltOverrideProposedAt = 0;
    emit ProtocolHalted(false);
}
```

The 7-day delay gives the board time to object or rotate keys before the override executes.

---

### P10-M-7: FundingEngine Retroactive Spike After Oracle Recovery — Up to 8 Hours of Funding at Manipulated Mark Price

**File**: `src/core/FundingEngine.sol`

**Root cause**: FundingEngine accumulates funding based on the EWMA mark price. During an oracle outage (Chainlink staleness triggers `isStale()`), the funding index continues accruing based on the last valid mark price. When the oracle recovers, the first trade feeds the recovery price into the EWMA. If the recovery price differs significantly from the pre-outage mark price (e.g., due to a flash manipulation at recovery), the EWMA jumps. All funding accrued over the outage period (up to the `maxFundingLookback`, currently 8 hours) is then settled at a rate that may include this jump.

**Impact**: Retroactive funding rates distorted by oracle manipulation at recovery. Traders cannot predict their funding exposure during outages because the settlement rate is determined by post-outage market conditions. A sophisticated attacker can time oracle manipulation to coincide with outage recovery to maximise funding extraction.

**Fix**: Cap the maximum funding rate that can accrue during any single settlement period to a multiple of the pre-outage rate. Alternatively, reset the funding accumulator on oracle recovery (accepting that funding during the outage is lost) rather than settling at the post-recovery rate:

```solidity
// On oracle recovery detection:
if (wasStale && !oracle.isStale(marketId)) {
    // Reset accumulator — do not retroactively apply outage-period funding
    lastFundingIndex[marketId] = currentFundingIndex(marketId);
    lastFundingTime[marketId] = block.timestamp;
}
```

---

### P10-M-8: ADL Ranking Ignores Accumulated Funding — Counterparty Profitability Overstated for Funding-Owing Positions

**File**: `src/risk/AutoDeleveraging.sol:157-186`

**Root cause**: `executeADL` ranks counterparty positions by unrealized price-PnL for deleveraging priority. A short position that is deeply in-the-money on price but owes a large accumulated funding payment appears more profitable than it actually is. The net equity of that position (after subtracting funding owed) may be near zero or negative.

ADL deleverages the most profitable positions first (to maximise recovery for the bankrupt). Selecting a position that appears profitable on price-PnL but is nearly insolvent after funding creates a situation where the selected counterparty cannot cover the bankrupt's shortfall, and ADL must run again — wasting gas and delaying recovery.

**Impact**: Inefficient ADL execution; potential under-recovery from counterparties. In extreme cases, a funding-insolvent counterparty is ADL'd, which simply creates another insolvent subaccount requiring further ADL.

**Fix**: Include pending funding in the profitability ranking:

```solidity
int256 pricePnl = _computeUnrealizedPnl(subaccount, marketId, indexPrice);
int256 pendingFunding = fundingEngine.pendingFundingPayable(subaccount, marketId);
int256 netPnl = pricePnl - pendingFunding; // funding payable reduces profitability
// Rank by netPnl, not pricePnl
```

This also requires P10-H-8 to be fixed first (FundingEngine must be wired to ADL).

---

## LOW

### P10-L-1: `removeParticipant` Emits No Event — Off-Chain ADL Participant Registry Blind to Removals

**File**: `src/risk/AutoDeleveraging.sol:240-254`

**Vulnerability**: `removeParticipant()` modifies `isParticipant` and performs a swap-and-pop on `marketParticipants` but emits no event. Off-chain monitoring tools that maintain a replica of the participant registry cannot observe removals and will have a stale view of which subaccounts are registered.

**Fix**: Add `event ParticipantRemoved(bytes32 indexed marketId, bytes32 indexed subaccount)` and emit it in `removeParticipant()`.

---

### P10-L-2: `commitRevealDelay` Has No Maximum — Owner Can Brick All Commit-Reveal Markets

**File**: `src/orderbook/MatchingEngine.sol:186`

**Vulnerability**: `setCommitRevealDelay` has no upper bound. Setting it to a value greater than 256 blocks means `revealOrder` can never succeed (the reveal window is `[commitBlock + delay, commitBlock + delay + 256]`; if `delay > 256`, the window opens after the commit has expired). All pending commits are permanently unrevealable — orders are committed but can never execute.

**Fix**: Add `require(blocks <= 256, "MaE: delay exceeds reveal window")` to `setCommitRevealDelay`. (Also covered in P10-H-6 fix above.)

---

### P10-L-3: ComplianceOracle Attestation TTL Not Enforced in Execution Functions — Expired Attestations Pass On-Chain Checks

**File**: `src/shariah/ComplianceOracle.sol`

**Vulnerability**: `ComplianceOracle` stores attestations with a `validUntil` timestamp. The `isCompliant()` function checks `validUntil`. However, if the matching engine's `complianceOracle` address is set (P10-H-8 fix applied), `_processFill` calls `isCompliant()` at execution time — which may be hours or days after the order was placed. An attestation that was valid at order placement may have expired by execution time. The current implementation does not distinguish between "never attested" and "attested but expired."

**Fix**: Ensure `isCompliant()` strictly checks `block.timestamp < validUntil` (not `<=`). Consider adding a grace period parameter for time-sensitive execution contexts. Emit a `ComplianceExpired` event on failed checks to aid monitoring.

---

### P10-L-4: FeeEngine Proportional Rebate Division-Before-Multiplication Truncation — Maker Rebate Under-Calculated

**File**: `src/core/FeeEngine.sol`

**Vulnerability**: Maker rebate computation divides before multiplying when the taker has a low balance relative to the rebate rate. The integer division truncates to zero for small notionals, meaning makers receive no rebate on small fills even when the rate is non-zero. This is a standard Solidity precision issue and does not affect correctness of the protocol (rebate under-payment is protocol-favorable), but it is a departure from the stated fee schedule.

**Fix**: Reorder operations to multiply before divide, or use `Math.mulDiv` for all rebate computations.

---

### P10-L-5: `getMarkPrice` Returns 0 Without Revert for Uninitialized Market — Inconsistent with `getIndexPrice`

**File**: `src/oracle/OracleAdapter.sol:272-274`

**Vulnerability**: `getIndexPrice` reverts on zero price (AUDIT FIX L1B-H-4). `getMarkPrice` does not:

```solidity
function getMarkPrice(bytes32 marketId) external view override returns (uint256) {
    uint256 mark = marketOracles[marketId].lastMarkPrice;
    return mark > 0 ? mark : marketOracles[marketId].lastIndexPrice;
}
```

If both `lastMarkPrice` and `lastIndexPrice` are zero (uninitialised market), this returns 0 silently. Any caller that uses `getMarkPrice` for margin computations and does not check for zero will treat the position as having zero notional value.

**Fix**: Add a zero-price revert to `getMarkPrice` consistent with `getIndexPrice`:

```solidity
require(price > 0, "OA: mark price not initialised");
```

---

### P10-L-6: `_wadToTokens` Overflow for `type(int256).min`

**File**: `src/core/MarginEngine.sol:597-603`

**Vulnerability**: `_wadToTokens(int256 wadAmount)` calls `_abs(wadAmount)` internally to handle the negative case. `_abs` on `MarginEngine` includes the `type(int256).min` guard. However, if `wadAmount == type(int256).min` is passed from a funding settlement computation, the guard reverts rather than returning a graceful result. While this prevents overflow, it causes a hard revert on `updatePosition` for any subaccount whose funding balance reaches the minimum `int256` value — an unlikely but possible edge case for long-running markets with extreme funding accumulation.

**Fix**: Add an explicit check and cap at the call sites (lines 315, 324, 394) before passing to `_wadToTokens`:

```solidity
int256 safePnl = pnl == type(int256).min ? type(int256).min + 1 : pnl;
vault.settlePnL(subaccount, collateralToken, _wadToTokens(safePnl));
```

---

## INFORMATIONAL

### P10-I-1: `setIndexPrice` Cannot Update `chainlinkReferencePrice` — Admin Price Setting Constrained by Stale Reference During Prolonged Chainlink Outage

**File**: `src/oracle/OracleAdapter.sol:228-234`

**Observation**: `setIndexPrice` (admin override) is bounded to the range `[chainlinkReferencePrice / 2, chainlinkReferencePrice * 2]`. During a prolonged Chainlink outage, `chainlinkReferencePrice` remains at the pre-outage value. If the true market price has moved more than 2× from the stale reference (e.g., after a significant macro event during the outage), the admin cannot set the correct current price via `setIndexPrice` — the bounds check will reject it.

**Recommendation**: Add a separate `setChainlinkReferencePrice(bytes32 marketId, uint256 price)` function callable by the owner that updates only the reference bound, requiring a timelocked governance action or multisig. This allows the bounds to be updated during prolonged outages without bypassing the circuit breaker for normal operations.

---

### P10-I-2: `markets[]` Array Grows Unboundedly — No Market Deactivation Mechanism

**File**: `src/core/MarginEngine.sol`

**Observation**: `createMarket()` appends to a `markets[]` array. There is no `deactivateMarket()` function. Functions that iterate over all markets (funding settlement, oracle price updates, liquidation scanning) scale linearly with the number of ever-created markets, including those with zero open interest. In a long-running protocol, this creates gas cost creep for keepers.

**Recommendation**: Add a `marketActive` flag to `MarketParams` and filter inactive markets in iteration loops. Alternatively, maintain a separate `activeMarkets` list that can be managed independently of the full `markets` history.

---

## What Remained Well-Protected

All protections confirmed in P1–P9 remain in place at the code level. The primary concern of P10 is that several of these protections are unreachable at deployment (P10-H-8). Once wiring is corrected, the following remain robust:

| Protection | Contract | P-Pass | Status |
|---|---|---|---|
| Global OI cap per market | MarginEngine | P9-C-1 | Code correct; wired |
| Unrealized PnL withdrawal buffer | MarginEngine | P9-C-2 | Code correct; wired |
| Insurance fund epoch drawdown limit | InsuranceFund | P9-H-1 | Code correct; boundary issue (P10-M-4) |
| Chainlink price deviation check | OracleAdapter | P9-H-2 | Code correct; first-update bypass (P10-H-4) |
| ADL stale participant cleanup | MarginEngine | P9-H-3 | Code correct; storage corruption (P10-H-1) |
| Reentrancy guards (all state-changing) | All contracts | P1-P8 | Correct; gap in updatePosition (P10-H-2) |
| Ownership renouncement disabled | All Ownable | P2 | Correct; no new gaps |
| Fee-on-transfer token protection | Vault | P3 | Correct; no new gaps |
| int256 overflow guards | All contracts | P4-P8 | Correct; _wadToTokens edge case (P10-L-6) |
| Commit-reveal MEV protection | MatchingEngine | P4 | Code correct; minimum gap (P10-H-6); replay gap (P10-H-5) |
| Self-trade prevention (subaccount) | OrderBook | P3 | Correct; cross-subaccount wash trading remains (P9-M-3) |
| Shariah halt integration | MatchingEngine, BatchSettlement | P4 | BatchSettlement gap requires P10-H-8 fix |

---

## PoC Tests

Exploit proof-of-concept tests are in `test/audit/P10_ExploitPoC.t.sol`.
