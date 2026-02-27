# BARAKA PROTOCOL — THINGS TO CONSIDER
*Critical notes, architectural decisions, edge cases, and open questions.*
*Updated: February 25, 2026*

---

## 1. SHARIAH COMPLIANCE EDGE CASES

### 1.1 The ι=0 Circuit Breaker Wording
The ±75bps circuit breaker must never be described as a "floor" or "ceiling" in documentation. It is a **symmetric clamp** that prevents market manipulation. Scholars may ask: why doesn't a 75bps positive cap constitute a guaranteed return? Answer: it only applies when mark is >75bps above index (indicating manipulation), and the symmetric negative side means shorts can also receive up to 75bps — it is risk-sharing, not guaranteed return.

### 1.2 PAXG/XAUT Collateral and Qabdh
Physical gold-backed tokens (PAXG/XAUT) may satisfy the `qabdh` (constructive possession) requirement for gold in Islamic finance. However, scholars differ. Consider getting a specific fatwa for PAXG/XAUT as collateral, separate from the perpetuals fatwa. Store the IPFS hash in `ShariahGuard.fatwaIPFS(paxgAddress)`.

### 1.3 Funding Payments — Is it Riba?
The funding mechanism transfers money between longs and shorts. Scholars may classify positive funding as riba if framed as "interest on position." Counter-argument: it is a **risk-sharing payment** between counterparties based on market premium/discount — closer to ta'widh (compensation for market imbalance) than riba. This framing should appear in the IPFS fatwa document.

### 1.4 Leverage — Maysir Claim
5x leverage could be flagged as excessive speculation (maysir). Mitigation:
- Cap is enforced at contract level (cannot be changed by anyone, not even Shariah board)
- Utility framing: hedging existing spot positions, not pure speculation
- Compare to conventional margin trading (often 10x-100x)
- Some scholars permit hedging leverage; some require 1:1 asset backing

### 1.5 Shariah Board Multisig Rotation
If a board member leaves, how is the multisig key rotated? `GovernanceModule.transferShariahMultisig()` allows this but requires a new multisig contract to be deployed. The 3-of-5 Gnosis Safe address needs to be set as `shariahMultisig` at deploy time. Document the rotation procedure clearly.

---

## 2. SECURITY CONSIDERATIONS

### 2.1 Oracle Manipulation
**Risk:** Attacker sets up large position, then manipulates mark price feed to trigger funding in their favor.
**Current mitigation:** 30-minute TWAP for mark price, 20% circuit breaker.
**Gap:** Single Chainlink feed for index price — if feed is compromised or stale, all positions use stale prices.
**Consider:** Add a second independent index price source (Pyth) for v2.

### 2.2 PositionManager Uses Low-Level `.call` to LiquidationEngine
`_pushLiqSnapshot` and `_removeLiqSnapshot` use `address(liquidationEngine).call(...)`. If LiquidationEngine is upgraded or replaced, the function signature must match exactly. A mismatch silently fails (the `require(ok, ...)` catches the failure, but the ABI must be exact).
**Fix for v2:** Add `ILiquidationEngine` interface methods `updateSnapshot` and `removeSnapshot`, use typed calls.

### 2.3 Integer Truncation in Funding Math
When `indexPrice` is very large (near 1e24 scale) and `markPrice - indexPrice = 1 wei`, the funding rate truncates to 0. This is correct behavior but means tiny premiums may not accrue. At normal price scales (1e18 = $1, prices in 1e22 range for BTC), this is unlikely to matter. Document this in NatSpec.

### 2.4 CollateralVault Withdrawal Cooldown Bypass
The 24-hour withdrawal cooldown is bypassed when the protocol is paused (emergency exit). This is intentional, but means: if the protocol is maliciously paused (owner compromised), users can immediately withdraw — which is actually the correct behavior (protects users). However, it also means the owner can trigger a "bank run" scenario by pausing.
**Consider:** Only allow emergency bypass if paused for >X hours (e.g., 72 hours).

### 2.5 Reentrancy in PositionManager.closePosition
`closePosition` calls `_settleFundingInternal` (which calls `fundingEngine`) then `vault.unlockCollateral`. The `nonReentrant` guard covers the full function, so cross-contract reentrancy should be blocked. But ensure vault never calls back into PositionManager.

### 2.6 LiquidationEngine: Anyone Can Liquidate
`liquidate(bytes32 positionId)` is callable by anyone. This is correct (keeper pattern), but consider: can a liquidator also hold an opposite position and benefit doubly? In isolated margin with no cross-margin, this should be fine. Verify in integration tests.

### 2.7 Governance: castVote Uses Unverified Weight
`castVote(proposalId, support, weight)` accepts weight as a parameter without verifying against a token balance snapshot. This is noted as "simplified" in NatSpec. **Before mainnet:** integrate ERC20Votes snapshot (OpenZeppelin Governor pattern). This is a significant security gap — anyone can claim any voting weight.

---

## 3. KNOWN LIMITATIONS (MVP)

### 3.1 No Partial Liquidation
LiquidationEngine MVP does full-close only. Partial liquidation (close enough to restore maintenance margin) is more user-friendly and industry standard (dYdX, GMX). Implement in v2.

### 3.2 No Pyth Integration
MVP uses dual Chainlink feeds. Pyth provides lower-latency prices and is widely used on Arbitrum. Add Pyth as the primary mark price oracle in v2.

### 3.3 PnL Transfer is "Off-Chain" / Not Implemented
In `closePosition`, the comment says "PnL transfer handled off-chain via InsuranceFund / counterparty matching." This is a major gap. In MVP:
- Positive PnL: trader gets collateral back but the protocol profit payout mechanism is not implemented
- This effectively makes the MVP a one-sided P&L system
**Before real money:** implement the PnL settlement mechanism via InsuranceFund or a proper AMM/orderbook matching system.

### 3.4 GovernanceModule: Token Voting Not Connected
`governanceToken` is set but `castVote` doesn't use it for weight verification. The dual-track governance is architecturally correct but the DAO track is not yet secure.

### 3.5 No Flash Loan Protection
Opening and closing positions in the same block is possible (no same-block restriction). Flash loan attacks on funding rates or liquidations are theoretically possible. **Consider:** Minimum position hold time of 1 block (already done for liquidation eligibility) — extend to position closing too.

---

## 4. PENDING ARCHITECTURAL DECISIONS

### 4.1 Pyth vs Chainlink vs Both
- MVP: dual Chainlink (60%/40%)
- v2 options: add Pyth as primary mark price feed, Chainlink as primary index feed
- Decision needed before mainnet

### 4.2 AMM vs Orderbook
The research paper and blueprint describe a hybrid AMM/orderbook. MVP has no matching engine — positions are opened against the protocol (synthetic counterparty). Real liquidity requires either:
- vAMM (virtual AMM, like Perpetual Protocol) — simpler to implement
- Orderbook with market makers — more complex, better price discovery
- Decision needed for v2

### 4.3 Governance Token
What token will be used for DAO voting? Options:
- Launch new BARAKA token
- Use existing token (not applicable yet)
- One-token-one-vote (centralized risk)
- Time-weighted voting (fairer for long-term holders)
- Quadratic voting (Sybil resistant)

### 4.4 Insurance Fund Seeding
Who seeds the InsuranceFund at launch? Options:
- Protocol treasury (Arcus Quant Fund as initial LP)
- Community crowdfund
- BARAKA token issuance
- Dr. Bhuyan's $50k pilot AUM

### 4.5 Multi-Market vs Single Market MVP
Should the MVP launch with one market (BTC-USDC) or multiple? Starting with one market simplifies liquidity, oracle setup, and testing. **Recommend: BTC-USDC perp only for MVP.**

---

## 5. INTEGRATION TEST PRIORITIES (NEXT SESSION)

Write these in order of importance:

### Priority 1: Full Position Lifecycle
```
Deploy all 8 contracts → Setup MockOracle → Approve USDC in ShariahGuard →
Deposit USDC to Vault → Open long BTC position (3x) → Advance time 3 hours →
settleFunding() → Close position → Withdraw USDC
```
Expected: collateral returned ± PnL, funding accrued correctly

### Priority 2: Liquidation Flow
```
Open position → Oracle drops price to below maintenance margin →
Anyone calls liquidate() → Position closed → InsuranceFund + liquidator receive penalty
```
Expected: position closed, penalty split 50/50

### Priority 3: Shariah Guard Blocks Non-Compliant
```
Try to open position with leverage=6 → revert
Try to open position with unapproved asset → revert
Shariah board pauses market → try to open position → revert
```

### Priority 4: Oracle Staleness
```
Set primary Chainlink feed stale (>5 min) → OracleAdapter falls back to secondary
Set both feeds stale → OracleAdapter reverts
```

---

## 6. DEPLOYMENT ORDER (FOR Deploy.s.sol)

Contract deployment must follow dependency order:
```
1. MockOracle / OracleAdapter (no dependencies)
2. ShariahGuard(shariahMultisig)
3. FundingEngine(owner, oracleAddr)
4. InsuranceFund(owner)
5. CollateralVault(owner, shariahGuardAddr)
6. LiquidationEngine(owner, oracleAddr, insuranceFundAddr)
7. PositionManager(owner, shariahGuard, fundingEngine, oracle, vault, liquidationEngine)
8. GovernanceModule(shariahMultisig, governanceToken)
```
Then post-deploy setup:
- `CollateralVault.setPositionManager(positionManagerAddr)` — authorize caller
- `LiquidationEngine.setPositionManager(positionManagerAddr)` — authorize caller
- `InsuranceFund.addAuthorizedCaller(liquidationEngineAddr)`
- `ShariahGuard.approveAsset(usdcAddr, "ipfs://QmFatwaHash...")`
- `ShariahGuard.approveAsset(paxgAddr, "ipfs://QmFatwaHashPAXG...")`
- `ShariahGuard.approveAsset(xautAddr, "ipfs://QmFatwaHashXAUT...")`

---

## 7. MATH EDGE CASES

### 7.1 Funding Rate at Zero Index Price
`getFundingRate()` would divide by zero if `indexPrice = 0`. OracleAdapter has a `require(price > 0)` guard. But this check should also exist in FundingEngine as a defense-in-depth. Currently not present — add in next iteration.

### 7.2 Overflow in Cumulative Funding
`cumulativeFundingIndex` is `int256`. With MAX_FUNDING_RATE = 75e14 and accruing every hour, in a theoretical worst case:
- 75e14 × 24 × 365 = 65.7e15 per year
- Over 1000 years: 65.7e18 — well within int256 range (max ~5.8e76). No overflow risk.

### 7.3 Collateral Underflow in Funding Settlement
If `payment > pos.collateral`, the code explicitly checks and sets `pos.collateral = 0` instead of underflowing. This is correct. But the position remains open with zero collateral — it should be eligible for immediate liquidation. Ensure LiquidationEngine snapshot is updated after zero-collateral state.

### 7.4 PnL Calculation Rounding
PnL = `priceDelta * size / entryPrice` — integer division truncates. For small positions or small price movements, PnL can be 0 even when there is a fractional gain/loss. This is standard Solidity behavior and acceptable.

---

## 8. API KEYS STILL NEEDED

| Key | Where to Get | Used For |
|---|---|---|
| Alchemy Arbitrum Sepolia RPC | alchemy.com → Create App → Arbitrum Sepolia | `foundry.toml` arbitrum_sepolia endpoint |
| Alchemy Arbitrum Mainnet RPC | alchemy.com → Create App → Arbitrum One | `foundry.toml` arbitrum_mainnet endpoint |
| Arbiscan API key | arbiscan.io → Sign up → API Keys | Contract verification |
| Pinata JWT | pinata.cloud → API Keys | Uploading fatwa IPFS documents |
| Deployer wallet private key | New MetaMask wallet (NEVER personal) | Signing deploy transactions |

---

## 9. SLITHER EXPECTED WARNINGS (TO SUPPRESS OR FIX)

When Slither runs, expect these common issues:
- `low-level-calls` detector: `_pushLiqSnapshot` and `_removeLiqSnapshot` use `.call()` → **Fix in v2 with typed interface calls**
- `reentrancy-benign`: FundingEngine.updateCumulativeFunding modifies state then calls oracle → protected by nonReentrant
- `assembly`: None expected (no assembly in MVP contracts)
- `unchecked-transfer`: SafeERC20 should handle this — verify CollateralVault uses SafeERC20
- `events-access`: Ensure all state-changing functions emit events — verify GovernanceModule.setGovernanceToken emits an event (currently missing)

---

## 10. PRE-MAINNET CHECKLIST (NOT YET STARTED)

- [ ] Third-party security audit (Trail of Bits, Sherlock, or Code4rena contest)
- [ ] AAOIFI-certified scholar review of ι=0 mechanism
- [ ] Formal fatwa document for perpetuals structure
- [ ] Legal opinion: is Baraka Protocol a regulated derivative?
- [ ] VASP registration in UAE if needed
- [ ] Token launch legal structure (if BARAKA token launched)
- [ ] Bug bounty program on Immunefi
- [ ] Multisig setup for Shariah board (Gnosis Safe, 3-of-5)

---

*Document started: February 25, 2026*
*Update this document whenever a new edge case, risk, or open question is discovered.*
