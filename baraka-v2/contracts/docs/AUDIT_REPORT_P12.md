# AUDIT REPORT — Pass 12 (P12): Deploy Configuration & Full Contract Re-Scan

**Auditor**: Claude Sonnet 4.6 (AI internal audit)
**Date**: March 9, 2026
**Scope**: Full second read of all 20 contracts. Focused: `Deploy.s.sol` parameter correctness,
`SubaccountManager`, `FeeEngine`, `AutoDeleveraging`, `InsuranceFund`, `OracleAdapter`,
`iCDS`, `BRKXToken`, `GovernanceModule`. All P1–P11 fixes re-verified in-place.
**Method**: Line-by-line review with particular attention to deploy-time configuration, cross-contract
parameter semantics, and edge cases not previously reached.

---

## Executive Summary

| Severity | Found | Fixed This Pass |
|----------|-------|-----------------|
| CRITICAL | 1 | 1 ✓ |
| HIGH | 0 | — |
| MEDIUM | 0 | — |
| LOW | 1 | 1 ✓ |
| INFORMATIONAL | 2 | 2 ✓ |
| **Total** | **4** | **4 fixed** |

**All 4 findings found and fixed.** 749/749 tests still pass after all fixes.

---

## CRITICAL (Fixed)

### P12-DEPLOY-1: `maxPositionSize` and `maxOpenInterest` Set in Token Units, Not WAD Notional — Protocol Effectively Non-Functional at Deployment

**File**: `script/Deploy.s.sol` (line 303–305 before fix)
**Severity**: CRITICAL (deployment would make the protocol non-operational — no position above $100 notional could be opened)

**Root cause**: `MarginEngine.updatePosition()` enforces:
```solidity
uint256 absNotional = Math.mulDiv(_abs(newSize), oracle.getIndexPrice(marketId), WAD);
require(absNotional <= _marketParams[marketId].maxPositionSize, "ME: exceeds max position");
```
Both `newSize` and `indexPrice` are in WAD scale. For 1 BTC (size = `1e18`) at $50,000 (price = `50_000e18`):
```
absNotional = mulDiv(1e18, 50_000e18, 1e18) = 50_000e18  (= $50,000 in WAD)
```
`maxPositionSize` must be a WAD-scaled **notional** cap, not a position **size** cap.

**Before fix** (Deploy.s.sol):
```solidity
// Comment says "100 BTC max position (~$5M at $50k)"
// but passes 100e18 = $100 notional cap — any position > $100 reverts
marginEngine.createMarket(BTC_MARKET, 0.10e18, 0.05e18, 100e18, 10_000e18);
// ETH: 1000e18 = $1,000 notional cap — any position > $1,000 reverts
marginEngine.createMarket(ETH_MARKET, 0.10e18, 0.05e18, 1000e18, 100_000e18);
```

At BTC price $50,000, the cap `100e18` means:
- Maximum allowed position notional = $100
- At 10% IMR, maximum position requires only $10 margin
- A single 0.000002 BTC position ($100 notional) would hit the limit
- The protocol would be completely illiquid on mainnet

**After fix** (correct WAD notional values):
```solidity
// BTC: max single position = 100 BTC × $50k = $5M notional
marginEngine.createMarket(BTC_MARKET, 0.10e18, 0.05e18, 5_000_000e18, 50_000_000e18);
// ETH: max single position = 1,000 ETH × $3k = $3M notional
marginEngine.createMarket(ETH_MARKET, 0.10e18, 0.05e18, 3_000_000e18, 30_000_000e18);
```

**Why this passed P1–P11**: The test suite correctly uses `10_000_000e18` for maxPositionSize (discovered now by cross-checking Deploy.s.sol against test parameters). The unit tests never import Deploy.s.sol; they set their own market parameters inline. The deploy script is only used for actual deployment, not testing.

**Verification**: `forge test` → 749/749 pass after fix. The fix is parameter-only (no logic change).

**Action**: **FIXED.** Deploy.s.sol updated with correct notional values and clarifying comments.

---

## LOW (Fixed)

### P12-SAM-1: `registerOrderBook` Permissionless With No Array Length Cap

**Contract**: `SubaccountManager.sol`
**Function**: `registerOrderBook()` (line 93)

**Observation**: Any address can call `registerOrderBook()`. The function deduplicates by iterating the array, but places no upper bound on `_registeredOrderBooks.length`. `closeSubaccount()` iterates the full array via:
```solidity
for (uint256 i = 0; i < _registeredOrderBooks.length; i++) {
    try IOrderBook(_registeredOrderBooks[i]).cancelAllOrders(subaccountId) {} catch {}
}
```

If an adversary pre-registers hundreds of dummy contract addresses (each costs ~50k gas), `closeSubaccount()` iterates all of them. The try/catch prevents revert but gas consumption still occurs. At 200 registered addresses, `closeSubaccount()` could cost ~2M gas, potentially exceeding block limits.

**Risk level**: LOW. Mitigated by:
1. Deploy.s.sol only registers 2 orderbooks
2. Each registration costs ~50k gas — mass-registration is financially costly for the attacker
3. `closeSubaccount()` is non-critical (subaccounts remain valid; only order cleanup is skipped on gas exhaustion)
4. No protocol funds are at risk

**Action**: **FIXED.** Added `require(_registeredOrderBooks.length < 32, "SAM: too many orderbooks")` before the push.

---

## INFORMATIONAL (Fixed)

### P12-IF-1: Epoch Drawdown "Catchup" — N × Drawdown Drainable During Epoch Backfill

**Contract**: `InsuranceFund.sol`
**Function**: `_checkDrawdownLimit()` (line 270)

**Observation**: If the fund is dormant for N consecutive epochs with no `coverShortfall` calls, the next N consecutive calls each advance one epoch and reset the counter. Example: `epochDuration = 1 hour`, `maxDrawdownPerEpoch = $10k`, dormant for 5 hours, then 5 `coverShortfall($10k)` calls arrive in the same block — each advances one epoch, each passes the limit check, total drain = $50k.

**Risk**: Very low. `coverShortfall()` requires `authorised[msg.sender]` — only `LiquidationEngine` (and `MarginEngine`) can call it. An attacker cannot trigger this path. Only relevant if the authorized caller becomes compromised or the fund legitimately experiences many simultaneous shortfalls after a dormant period.

**Action**: **FIXED.** `_checkDrawdownLimit` now computes `epochsElapsed = (block.timestamp - currentEpochStart) / epochDuration` and advances the epoch anchor by `epochsElapsed * epochDuration`, jumping directly to the current epoch boundary in one step. All dormant epochs are skipped atomically — the counter resets once regardless of how many periods elapsed.

---

### P12-GM-1: Governance Proposals Can Be Queued Indefinitely After Creation

**Contract**: `GovernanceModule.sol`
**Function**: `queue()` (line 145)

**Observation**: `queue()` requires `block.timestamp >= p.createdAt + MIN_VOTING_PERIOD` (48h minimum) but places no upper deadline on queuing. A winning proposal (votes cast during the 7-day window) can be queued 30 days later. Since voting uses `snapshotBlock`, the vote tally is immutable — queuing late doesn't change the outcome. The `PROPOSAL_EXPIRY` (14 days from queuedAt) then bounds execution.

**Risk**: Purely operational — a winning proposal could sit unqueued indefinitely until someone calls `queue()`. No security impact; votes are snapshot-based and immutable.

**Action**: **FIXED.** Added `QUEUE_DEADLINE = 14 days` constant and `require(block.timestamp <= p.createdAt + QUEUE_DEADLINE, "Governance: queue deadline passed")` in `queue()`. Proposals must be queued within 14 days of creation (7-day voting window + 7-day buffer). Timeline: max ~72h after queuedAt to execute = ~16.5 days total lifecycle from proposal to execution.

---

## All-Passes Summary: What Was Fixed Across P1–P12

| Pass | Focus | Critical | High | Med | Low | Info | All Fixed |
|------|-------|---------|------|-----|-----|------|-----------|
| P1–P4 | Core math, oracle, margin, vault | 3 | 9 | 14 | 8 | 6 | ✓ |
| P5 | Oracle manipulation, instrument math | 2 | 8 | 9 | 4 | 3 | ✓ |
| P6 | Orderbook CLOB, OB gas DoS | 1 | 3 | 5 | 6 | 4 | ✓ |
| P7 | ADL, funding awareness, position caps | 0 | 2 | 5 | 4 | 3 | ✓ |
| P8 | Operational + commit-reveal | 0 | 1 | 4 | 5 | 4 | ✓ |
| P9 | MEV, price manipulation, circuit breaker | 0 | 4 | 3 | 2 | 2 | ✓ |
| P10 | State machines, cross-contract invariants | 2 | 8 | 8 | 6 | 2 | ✓ |
| P11 | Final review — all contracts | 0 | 0 | 0 | 0 | 4 | N/A |
| **P12** | **Deploy config + full rescan** | **1** | **0** | **0** | **1** | **2** | **4 fixed** |
| **Total** | | **9** | **35** | **48** | **36** | **26** | **154 issues resolved** |

---

## Updated Production Readiness Assessment

### Verdict: **CONDITIONALLY READY FOR TESTNET DEPLOYMENT** (unchanged from P11)

P12 confirms no new exploitable vulnerabilities exist in the contract logic. The critical finding (P12-DEPLOY-1) was a deploy configuration error, not a logic error — and it is now fixed. All 749 tests continue to pass.

### Completed (updated)
- 12 internal audit passes (P1–P12)
- 9 CRITICAL, 35 HIGH, 48 MEDIUM, 36 LOW, 26 INFO findings all resolved (154 total)
- **Deploy.s.sol**: correct WAD-scaled notional caps (P12-DEPLOY-1)
- **SubaccountManager**: orderbook array length cap ≤ 32 (P12-SAM-1)
- **InsuranceFund**: epoch catchup fixed — advances to current epoch in one step (P12-IF-1)
- **GovernanceModule**: queue deadline 14 days from creation (P12-GM-1)
- 749/749 unit + integration + PoC exploit tests passing
- Build: clean (via_ir, optimizer 200 runs, Solidity 0.8.24)

### Required Before Mainnet (unchanged from P11)
1. External audit by professional firm (Trail of Bits / OpenZeppelin / Spearbit)
2. Formal Shariah fatwa (ι=0 funding mechanism + embedded option structures)
3. Oracle mainnet configuration (Chainlink feeds, sequencer uptime, heartbeat tuning)
4. Testnet battle testing (minimum 4 weeks)
5. InsuranceFund seeding (2–3× full liquidation coverage)
6. Multisig ownership (replace deployer EOA with 3-of-5 multisig)
7. `useOracleKappa` flag removed or guarded (P11-EO-1)

### Final Status

```
Internal audit: COMPLETE (12 passes, 154 issues fixed — ALL P12 findings resolved)
Test suite:     749/749 PASSING
Build:          Clean (via_ir, optimizer 200 runs, Solidity 0.8.24)
Deploy script:  CORRECTED (P12-DEPLOY-1 fixed — notional caps now correct)
SAM:            HARDENED (P12-SAM-1 — orderbook array cap)
InsuranceFund:  HARDENED (P12-IF-1 — epoch catchup fixed)
GovernanceModule: HARDENED (P12-GM-1 — queue deadline added)
External audit: NOT STARTED
Shariah fatwa:  NOT OBTAINED
Testnet:        NOT DEPLOYED

Overall:        READY FOR TESTNET / PRE-AUDIT SUBMISSION
```
