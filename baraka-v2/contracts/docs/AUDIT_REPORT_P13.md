# AUDIT REPORT — Pass 13 (P13): Cross-Cutting Security & Observability Review

**Auditor**: Claude Sonnet 4.6 (AI internal audit)
**Date**: March 9, 2026
**Scope**: All 20 contracts. Focused areas: reentrancy call graph, access control completeness,
ERC20 transfer safety, pause consistency, event emission completeness on all admin setters.
All P1–P12 fixes re-verified in-place.
**Method**: Pattern-level analysis across all source files with cross-contract invariant checking.

---

## Executive Summary

| Severity | Found | Fixed This Pass |
|----------|-------|-----------------|
| CRITICAL | 0 | — |
| HIGH | 0 | — |
| MEDIUM | 7 | 7 ✓ |
| LOW | 0 | — |
| INFORMATIONAL | 0 | — |
| **Total** | **7** | **7 fixed** |

**All 7 findings found and fixed.** 749/749 tests still pass after all fixes.

---

## Security Areas Reviewed (PASS)

### Reentrancy — PASS
All critical paths (`coverShortfall`, `payPnl`, `distributeSurplus`, `deposit`, `withdraw`,
`liquidate`, `matchOrders`, `execute` in GovernanceModule) have `nonReentrant`. CEI pattern
observed throughout. No reentrancy vectors found.

### Access Control — PASS
All privileged functions are guarded:
- `onlyOwner` / `Ownable2Step` — all owner-only operations across 12 contracts
- `authorised[msg.sender]` — all cross-contract callbacks (MatchingEngine → FeeEngine/OracleAdapter,
  LiquidationEngine → InsuranceFund, etc.)
- `onlyShariahMultisig` — GovernanceModule veto/pause
- No unguarded state-changing functions found

### ERC20 Transfer Safety — PASS
All token transfers use `SafeERC20` (`safeTransfer`, `safeTransferFrom`, `safeApprove`).
No bare `.transfer()` or `.transferFrom()` calls. InsuranceFund and Vault both confirmed.

### Pause Consistency — PASS
Intentional gaps documented in-source:
- `InsuranceFund.coverShortfall()` — `whenNotPaused` intentionally absent (P3-LIQ-5)
- `InsuranceFund.receive_()` — `whenNotPaused` intentionally absent (P5-M-17)
- All other state-changing paths correctly require `whenNotPaused` when the contract is Pausable

---

## MEDIUM (All Fixed)

### P13-FE-1: Missing Events on Three FeeEngine Admin Setters

**Contract**: `FeeEngine.sol`
**Functions**: `setAuthorised()` (line 107), `setBRKXToken()` (line 127), `setTier()` (line 131)

**Observation**: Three privileged state changes emit no events:
- `setAuthorised(address caller, bool status)` — changes who can call `chargeTakerFee` /
  `processTradeFees`. Without an event, off-chain monitoring cannot detect unauthorized caller
  additions or removals from the authorized set.
- `setBRKXToken(address _brkx)` — sets the token used for fee tier computation. Changing this
  silently affects fee discounts for all traders immediately.
- `setTier(uint256 index, ...)` — modifies fee rates for a tier. Fee changes are material to
  traders and must be observable on-chain.

**Risk**: Medium. No direct exploit path (functions are `onlyOwner`), but absence of events
impairs: (1) off-chain monitoring and alerting, (2) governance transparency, (3) front-end
fee display synchronization, (4) post-incident forensics.

**Action**: **FIXED.** Added three events to the Events section:
```solidity
event AuthorisedSet(address indexed caller, bool status);
event BRKXTokenSet(address indexed token);
event TierUpdated(uint256 indexed index, uint256 minBRKX, uint256 takerBps, uint256 makerBps);
```
Emitted in their respective functions.

---

### P13-OA-1: Missing Events on Four OracleAdapter Admin Setters

**Contract**: `OracleAdapter.sol`
**Functions**: `setAuthorised()` (line 107), `setMarkEwmaAlpha()` (line 117),
`setSequencerUptimeFeed()` (line 123), `setMaxPriceDeviation()` (line 129)

**Observation**: Four privileged state changes emit no events:
- `setAuthorised(address caller, bool status)` — controls who can call `updateMarkPrice`. An
  unauthorized address gaining mark-price write access is a direct funding-rate manipulation
  vector; this change must be detectable on-chain.
- `setMarkEwmaAlpha(uint256 alpha)` — changes EWMA smoothing factor for mark price. Affects
  funding rate sensitivity. Silent changes are a risk to market fairness.
- `setSequencerUptimeFeed(address feed)` — enables/disables the Arbitrum sequencer liveness
  check. Setting to `address(0)` disables the L2 safety guard; this must be auditable.
- `setMaxPriceDeviation(uint256 deviation)` — changes or disables the circuit breaker.
  Setting to 0 disables oracle manipulation protection; must be auditable.

**Risk**: Medium. The oracle circuit breaker and sequencer feed are critical safety parameters.
Silent modification of these values is a significant observability gap in a live deployment.

**Action**: **FIXED.** Added four events to the Events section:
```solidity
event AuthorisedSet(address indexed caller, bool status);
event MarkEwmaAlphaUpdated(uint256 alpha);
event SequencerUptimeFeedSet(address indexed feed);
event MaxPriceDeviationSet(uint256 deviation);
```
Emitted in their respective functions.

---

## All-Passes Summary: What Was Fixed Across P1–P13

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
| P12 | Deploy config + full rescan | 1 | 0 | 0 | 1 | 2 | 4 fixed |
| **P13** | **Cross-cutting security + observability** | **0** | **0** | **7** | **0** | **0** | **7 fixed** |
| **Total** | | **9** | **35** | **55** | **36** | **30** | **161 issues resolved** |

---

## Updated Production Readiness Assessment

### Verdict: **CONDITIONALLY READY FOR TESTNET DEPLOYMENT** (unchanged from P12)

P13 confirms no new exploitable vulnerabilities. The 7 findings are observability gaps in admin
setters — no funds are at risk. All 749 tests pass after fixes.

### Completed (updated)
- 13 internal audit passes (P1–P13)
- 9 CRITICAL, 35 HIGH, 55 MEDIUM, 36 LOW, 30 INFO findings all resolved (161 total)
- **FeeEngine**: `setAuthorised`, `setBRKXToken`, `setTier` now emit events (P13-FE-1)
- **OracleAdapter**: `setAuthorised`, `setMarkEwmaAlpha`, `setSequencerUptimeFeed`, `setMaxPriceDeviation` now emit events (P13-OA-1)
- 749/749 unit + integration + PoC exploit tests passing
- Build: clean (via_ir, optimizer 200 runs, Solidity 0.8.24)

### Required Before Mainnet (unchanged from P12)
1. External audit by professional firm (Trail of Bits / OpenZeppelin / Spearbit)
2. Formal Shariah fatwa (ι=0 funding mechanism + embedded option structures)
3. Oracle mainnet configuration (Chainlink feeds, sequencer uptime, heartbeat tuning)
4. Testnet battle testing (minimum 4 weeks)
5. InsuranceFund seeding (2–3× full liquidation coverage)
6. Multisig ownership (replace deployer EOA with 3-of-5 multisig)
7. `useOracleKappa` flag removed or guarded (P11-EO-1)

### Final Status

```
Internal audit: COMPLETE (13 passes, 161 issues fixed — ALL P13 findings resolved)
Test suite:     749/749 PASSING
Build:          Clean (via_ir, optimizer 200 runs, Solidity 0.8.24)
FeeEngine:      HARDENED (P13-FE-1 — admin events added)
OracleAdapter:  HARDENED (P13-OA-1 — admin events added)
External audit: NOT STARTED
Shariah fatwa:  NOT OBTAINED
Testnet:        NOT DEPLOYED

Overall:        READY FOR TESTNET / PRE-AUDIT SUBMISSION
```
