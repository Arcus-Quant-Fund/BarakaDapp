# AUDIT REPORT — Pass 9 (P9): dYdX-Inspired Attack Vector Analysis

**Auditor**: Claude Opus 4.6 (AI internal audit)
**Date**: March 8, 2026
**Scope**: All 20 Baraka v2 contracts (~14,568 SLOC)
**Method**: Map 14 real-world DeFi perp exploits (dYdX, Hyperliquid, GMX, Mango, Perpetual Protocol, KiloEx) to Baraka v2 architecture. Test each attack vector.

---

## Executive Summary

| Severity | Found | Fixed |
|----------|-------|-------|
| CRITICAL | 2 | — |
| HIGH | 3 | — |
| MEDIUM | 4 | — |
| LOW | 2 | — |
| INFORMATIONAL | 2 | — |
| **Total** | **13** | **0** |

All previous 8 audit passes (291+ findings) addressed smart contract bugs. This P9 pass focuses on **economic/protocol-level attack vectors** — the kind that caused $180M+ in losses across dYdX ($9M), Mango ($117M), Hyperliquid ($17.5M), GMX ($43M), and KiloEx ($7.5M).

---

## CRITICAL

### P9-C-1: No Global Open Interest Cap Per Market

**File**: `src/core/MarginEngine.sol:144-166`
**Attack reference**: dYdX YFI/SUSHI ($9M, Nov 2023), Mango Markets ($117M, Oct 2022), Hyperliquid JELLY ($13.5M, Mar 2025)

**Vulnerability**: MarginEngine.createMarket() accepts a `maxPositionSize` (per-subaccount notional cap), but there is NO global open interest cap per market. The protocol tracks individual position sizes but never enforces aggregate OI limits.

**Attack scenario** (dYdX YFI replay):
1. Attacker creates 256 subaccounts per address × N addresses
2. Opens maximum-size long positions in a low-liquidity market across all subaccounts
3. Aggregate OI balloons to 100x the market's real liquidity depth
4. Attacker buys spot on external venues to pump the oracle price
5. Closes positions for profit — losses are absorbed by counterparties or insurance fund

**Impact**: Without OI caps, a single entity can dominate a market's open interest, making the protocol the sole counterparty to a manipulated position. Insurance fund drainage up to 100% of fund balance.

**Fix**:
```solidity
// In MarginEngine storage:
mapping(bytes32 => uint256) public totalLongOI;    // WAD-scale notional
mapping(bytes32 => uint256) public totalShortOI;
mapping(bytes32 => uint256) public maxOpenInterest; // set per market

// In createMarket():
maxOpenInterest[marketId] = _maxOpenInterest;

// In updatePosition(), after size check:
if (newSize > 0) {
    totalLongOI[marketId] += additionalNotional;
    require(totalLongOI[marketId] <= maxOpenInterest[marketId], "ME: OI cap exceeded");
} else {
    totalShortOI[marketId] += additionalNotional;
    require(totalShortOI[marketId] <= maxOpenInterest[marketId], "ME: OI cap exceeded");
}
```

---

### P9-C-2: Unrealized PnL Fully Withdrawable — Forced Liquidation Attack

**File**: `src/core/MarginEngine.sol:198-207`
**Attack reference**: Hyperliquid ETH Whale ($4M, Mar 2025)

**Vulnerability**: `withdraw()` checks `freeCol >= int256(amount * collateralScale)` where free collateral includes unrealized PnL. This means unrealized paper profits are withdrawable immediately.

**Attack scenario** (Hyperliquid ETH whale replay):
1. Attacker deposits $10,000 USDC, opens 5x long BTC at $50,000
2. BTC rises to $51,000 (+2%) → unrealized PnL = +$1,000 (in WAD)
3. Free collateral = equity ($11,000) - IMR ($5,100) = $5,900
4. Attacker withdraws $1,000 (the unrealized profit)
5. Now: actual collateral = $9,000, position notional = $51,000, equity = $10,000
6. BTC drops back to $49,000 → equity = $8,000, MMR = $2,450 → still OK
7. BTC drops to $47,000 → equity = $6,000, but position has $4,000 loss + only $9,000 actual collateral
8. Full liquidation → $4,000 loss against $9,000 collateral → $5,000 remains
9. But attacker already withdrew $1,000 → insurance fund covers $1,000 shortfall

At 50x leverage (if allowed by a market), this attack extracts up to 50% of the withdrawal amount from the insurance fund.

**Impact**: Systematic insurance fund drainage via unrealized PnL withdrawal + subsequent forced liquidation.

**Fix**: Add withdrawal buffer multiplier:
```solidity
// In withdraw():
uint256 WITHDRAWAL_BUFFER = 1.5e18; // 150% of IMR must remain
int256 freeCol = _computeFreeCollateral(subaccount);
uint256 imr = _computeIMR(subaccount);
int256 withdrawableExcess = freeCol - int256(imr * WITHDRAWAL_BUFFER / WAD - imr);
require(withdrawableExcess >= int256(amount * collateralScale), "ME: insufficient withdrawable margin");
```

OR exclude unrealized PnL from withdrawal calculations:
```solidity
// Alternative: use deposited collateral minus IMR, ignoring unrealized PnL
uint256 deposited = vault.balance(subaccount, collateralToken) * collateralScale;
int256 freeDeposited = int256(deposited) - int256(_computeIMR(subaccount));
require(freeDeposited >= int256(amount * collateralScale), "ME: insufficient deposited margin");
```

---

## HIGH

### P9-H-1: No Insurance Fund Drawdown Rate Limit

**File**: `src/risk/InsuranceFund.sol:131-146`
**Attack reference**: Perpetual Protocol bad debt attack, dYdX YFI ($9M fund drainage)

**Vulnerability**: `coverShortfall()` has no rate limit on drawdowns. `distributeSurplus()` has a 7-day cooldown between distributions and 24h cooldown after weekly reset, but `coverShortfall()` has no such protection. Multiple liquidations in a single block can drain the entire fund.

**Attack scenario**:
1. Attacker opens opposing positions across many subaccounts (long on subs A1-A100, short on subs B1-B100)
2. Price crashes (natural or manipulated)
3. All A-subaccounts become liquidatable simultaneously
4. Cascading liquidations drain insurance fund in one transaction batch
5. Remaining shortfalls trigger ADL against innocent counterparties

**Impact**: Complete insurance fund drainage in a single block, followed by unfair ADL against profitable traders.

**Fix**:
```solidity
// In InsuranceFund:
uint256 public maxDrawdownPerEpoch;     // e.g., 25% of fund per hour
uint256 public epochDrawdown;
uint256 public epochStart;

function coverShortfall(address token, uint256 amount) external override nonReentrant {
    // ... existing checks ...
    _enforceDrawdownLimit(token, amount);
    // ... rest of function ...
}

function _enforceDrawdownLimit(address token, uint256 amount) internal {
    if (block.timestamp >= epochStart + 1 hours) {
        epochDrawdown = 0;
        epochStart = block.timestamp;
    }
    epochDrawdown += amount;
    uint256 balance_ = IERC20(token).balanceOf(address(this));
    require(epochDrawdown <= balance_ * maxDrawdownPerEpoch / WAD, "IF: epoch drawdown exceeded");
}
```

**Note**: This must be balanced carefully — too strict a rate limit prevents legitimate liquidation cascade. Consider making it configurable and initially set to 50% per hour.

---

### P9-H-2: No Automatic Circuit Breaker on Extreme Price Movements

**File**: `src/oracle/OracleAdapter.sol:127-162`
**Attack reference**: Multiple incidents (flash crashes, oracle manipulation)

**Vulnerability**: `updateIndexPrice()` accepts any valid Chainlink price regardless of how far it deviates from the previous stored price. A 50% price drop in one Chainlink update (which has happened — FTT, LUNA, UST) triggers immediate mass liquidation with no grace period.

The existing protections:
- `setIndexPrice()` (admin) IS bounded to [ref/2, ref*2] vs Chainlink reference ✓
- `updateMarkPrice()` clamps trade price to ±10% of index ✓
- But `updateIndexPrice()` (permissionless keeper) has NO deviation check ✓ ← MISSING

**Attack scenario**:
1. Attacker manipulates a low-liquidity Chainlink feed (e.g., pays gas to push aggregator reports)
2. Or: natural black swan (LUNA-style collapse)
3. Price drops 80% in one update
4. All long positions immediately liquidatable
5. Insurance fund drained, ADL triggered against all remaining shorts

**Impact**: Mass liquidation cascade with no opportunity for orderly position reduction.

**Fix**:
```solidity
// In updateIndexPrice(), after price normalization:
uint256 oldPrice = mo.lastIndexPrice;
if (oldPrice > 0) {
    uint256 deviation = price > oldPrice
        ? (price - oldPrice) * WAD / oldPrice
        : (oldPrice - price) * WAD / oldPrice;
    require(deviation <= maxPriceDeviation, "OA: price deviation too large — manual review required");
}
```

With `maxPriceDeviation` initially set to `0.20e18` (20%). Larger moves require admin `setIndexPrice()` with Shariah board oversight.

---

### P9-H-3: ADL Participant List Grows Unboundedly, Stale Entries Block ADL

**File**: `src/risk/AutoDeleveraging.sol:107-113, 153-186`
**Attack reference**: Generic DeFi ADL DoS pattern

**Vulnerability**: `registerParticipant()` pushes to `marketParticipants[marketId]` on every fill. `removeParticipant()` exists but is only callable by authorised callers — there is no automatic cleanup when positions close. After thousands of trades, the array contains thousands of entries where most have zero positions.

`executeADL()` scans `MAX_ADL_SCAN = 200` entries from the start of the array. If the first 200 entries are all stale (closed positions), ADL finds zero counterparties and the shortfall goes uncovered.

**Attack scenario** (ADL griefing):
1. Attacker opens and closes 200+ tiny positions across different subaccounts
2. These 200 stale entries fill the first 200 slots of `marketParticipants`
3. Legitimate profitable counterparties are at index 201+
4. When ADL triggers, it scans 200 stale entries, finds nothing, and the shortfall is socialized silently

**Impact**: ADL fails to function, leaving bad debt unsocialized.

**Fix**: Cleanup on position close:
```solidity
// In MarginEngine._cleanupPosition() or in MatchingEngine after full close:
if (address(adl) != address(0) && newSize == 0) {
    try adl.removeParticipant(marketId, subaccount) {} catch {}
}
```

Or: Use a more efficient data structure (e.g., linked list with head pointer, or require off-chain keeper to submit ranked candidates).

---

## MEDIUM

### P9-M-1: Cross-Account Opposing Position Attack (Same Owner)

**File**: `src/core/MarginEngine.sol:231-315`, `src/orderbook/MatchingEngine.sol:200-248`
**Attack reference**: Perpetual Protocol bad debt exploit, generic Sybil pattern

**Vulnerability**: The same owner (address) can have 256 subaccounts. They can open a long on subaccount A and a short on subaccount B in the same market. OrderBook self-trade prevention only blocks same-subaccount, not same-owner.

**Attack scenario**:
1. Alice creates subaccounts A and B
2. Opens $10K long on A (10% IMR = $1K margin)
3. Opens $10K short on B ($1K margin)
4. Price drops 15% → A is liquidatable (equity < MMR)
5. A is liquidated — insurance fund covers the shortfall
6. B profits $1,500 — Alice withdraws

Net: Alice extracted insurance fund value at no real risk (her positions were delta-neutral).

**Impact**: Repeated extraction from insurance fund via risk-free opposing positions.

**Fix**: Block same-owner opposing positions:
```solidity
// In MarginEngine.updatePosition():
if (_abs(newSize) > _abs(oldSize)) { // increasing or new position
    // Check all subaccounts of the same owner for opposing positions
    address owner = subaccountManager.getOwner(subaccount);
    // This is expensive to check on-chain — may need off-chain monitoring
}
```

Or: in MatchingEngine._processFill(), check `subaccountManager.getOwner(fill.takerSubaccount) != subaccountManager.getOwner(fill.makerSubaccount)`.

---

### P9-M-2: maxPositionSize Check Uses Index Price, Not Fill Price

**File**: `src/core/MarginEngine.sol:303-305`
**Attack reference**: GMX zero-slippage oracle exploit ($565K)

**Vulnerability**: Position size limit is checked using `oracle.getIndexPrice()` instead of `fillPrice`:
```solidity
uint256 absNotional = _abs(newSize) * oracle.getIndexPrice(marketId) / WAD;
require(absNotional <= _marketParams[marketId].maxPositionSize, "ME: exceeds max position");
```

If index price is $50,000 and the fill happens at $55,000 (book is thin), the actual notional is 10% higher than the limit allows.

**Impact**: Positions slightly larger than intended maxPositionSize. In extreme cases (thin books), up to 10% above limit.

**Fix**: Use `max(indexPrice, fillPrice)` for the check:
```solidity
uint256 priceForCheck = fillPrice > indexPrice ? fillPrice : indexPrice;
uint256 absNotional = _abs(newSize) * priceForCheck / WAD;
```

---

### P9-M-3: Wash Trading via Multiple Subaccounts (Fee Tier Manipulation)

**File**: `src/orderbook/OrderBook.sol` (self-trade check), `src/core/FeeEngine.sol`
**Attack reference**: Generic wash trading pattern

**Vulnerability**: OrderBook's self-trade prevention only checks `taker == maker` at the subaccount level. Same owner can trade between subaccount A (buyer) and subaccount B (seller) to generate artificial volume. Current FeeEngine uses BRKX balance for tier lookup, not volume — so this is not immediately exploitable for fee discounts. However, this inflated volume appears in on-chain analytics and could be used to game future volume-based fee tiers.

**Impact**: Medium — currently limited to false volume metrics. Becomes HIGH if volume-based fee tiers are added.

**Fix**: Add same-owner self-trade prevention in MatchingEngine:
```solidity
function _processFill(bytes32 marketId, IOrderBook.Fill memory fill) internal {
    // Block same-owner fills
    address takerOwner = subaccountManager.getOwner(fill.takerSubaccount);
    address makerOwner = subaccountManager.getOwner(fill.makerSubaccount);
    require(takerOwner != makerOwner, "ME: self-trade across subaccounts");
    // ... rest of fill processing
}
```

---

### P9-M-4: BatchSettlement Price Band May Be Too Permissive

**File**: `src/settlement/BatchSettlement.sol`
**Attack reference**: KiloEx oracle access control exploit ($7.5M)

**Vulnerability**: BatchSettlement validates settlement price within ±5% of oracle index. This is reasonable for normal conditions but allows authorised callers (off-chain matcher) to systematically settle at the edge of the band (4.9% above index for longs, 4.9% below for shorts), extracting value over time.

The authorised caller is the only entity who can submit batch settlements. If this key is compromised or the operator is malicious, they can settle at systematically favorable prices within the ±5% band.

**Impact**: Gradual value extraction by compromised settlement operator, up to 4.9% per trade.

**Fix**: Tighten band to ±2%, or implement dynamic band that narrows during low-volatility periods, or require settlement price to match an on-chain reference within a tighter tolerance.

---

## LOW

### P9-L-1: No Chainlink Price Delta Check in updateIndexPrice

**File**: `src/oracle/OracleAdapter.sol:127-162`

**Vulnerability**: `updateIndexPrice()` validates Chainlink data quality (round completeness, heartbeat, positive price) but doesn't compare the new price against the previous stored price. A corrupted Chainlink feed could report a price 10x higher or lower.

**Mitigation already in place**: Chainlink aggregator consensus prevents single-feed manipulation. This is primarily a defense-in-depth concern.

**Fix**: See P9-H-2 (upgraded to HIGH due to combination with mass liquidation cascade risk).

---

### P9-L-2: commitRevealDelay Can Be Set to 0

**File**: `src/orderbook/MatchingEngine.sol:184-186`

**Vulnerability**: `setCommitRevealDelay(uint256 blocks)` has no minimum. Setting delay to 0 defeats the MEV protection purpose (reveal in same block as commit).

**Fix**: `require(blocks >= 1, "MaE: delay must be >= 1 block");`

---

## INFORMATIONAL

### P9-I-1: GovernanceModule execute() With Arbitrary Target

**File**: `src/governance/GovernanceModule.sol`

**Observation**: Governance proposals can call arbitrary external contracts with arbitrary calldata. The `target != address(this)` check prevents self-calls, but a proposal could still call `setOwner` on any Ownable contract in the system if it has the right address. This is by design (governance should be powerful) but creates a "god mode" that requires strong operational security for proposal review.

**Recommendation**: Document the threat model. Consider adding a whitelist of callable contracts.

### P9-I-2: FeeEngine staker share lost when stakerPool is zero

**File**: `src/core/FeeEngine.sol`

**Observation**: When `stakerPool == address(0)`, the staker share of fees is redirected to treasury. This is documented behavior. However, if treasury is also address(0) (should never happen given admin setters validate), the staker share would be deducted from the taker but never transferred — effectively burned. The contract handles this gracefully (no revert) but the fees are lost.

---

## What's Already Well-Protected

The codebase is remarkably well-hardened for the attack vectors tested. Specific protections:

| Attack Vector | Protection | Status |
|---|---|---|
| **Reentrancy** (GMX $42M) | ReentrancyGuard on all state-changing functions, checks-effects-interactions pattern | ✅ PROTECTED |
| **Oracle access control** (KiloEx $7.5M) | `onlyOwner` on price setters, `onlyAuthorised` on mark price, Chainlink reference bounds [ref/2, ref*2] | ✅ PROTECTED |
| **EWMA mark manipulation** (funding extraction) | Trade price clamped ±10% of index before EWMA, alpha capped at 20% | ✅ PROTECTED |
| **Flash loan governance** (generic) | `getPastVotes(block.number - 1)`, 256-block snapshot delay | ✅ PROTECTED |
| **Front-running** (Synthetix) | Commit-reveal scheme with block delay and expiry | ✅ PROTECTED |
| **Zero-slippage oracle execution** (GMX $565K) | CLOB with real price discovery — execution at orderbook prices, not oracle | ✅ PROTECTED |
| **Ownership renouncement** (generic) | `renounceOwnership()` disabled on all 10+ Ownable contracts | ✅ PROTECTED |
| **Sequencer downtime** (Arbitrum L2) | Sequencer uptime feed + 1h grace period | ✅ PROTECTED |
| **Paused liquidation DoS** (generic) | Liquidation cascade is pause-immune (P2-CRIT-3) | ✅ PROTECTED |
| **Fee-on-transfer tokens** (generic) | Balance before/after check in Vault.deposit() | ✅ PROTECTED |
| **int256.min overflow** (generic) | `_abs()` guard on all contracts | ✅ PROTECTED |
| **Precision loss** (generic) | Math.mulDiv, protocol-favorable rounding, ceiling division | ✅ PROTECTED |
| **Supply chain** (dYdX npm) | Not applicable (on-chain contracts only) | N/A |
| **DNS hijack** (dYdX frontend) | Not applicable (smart contract audit only) | N/A |

---

## PoC Tests

Exploit proof-of-concept tests are in `test/audit/P9_ExploitPoC.t.sol`.
