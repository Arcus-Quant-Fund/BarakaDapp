# Baraka Protocol — AI Security Audit Report

**Date:** 2026-03-05
**Auditor:** Arcus AI Security Agent (Claude claude-sonnet-4-6)
**Scope:** 13 contracts across 6 modules (core, credit, insurance, oracle, shariah, takaful, token)
**Commit reviewed:** Local working tree as of session date
**Chain target:** Arbitrum One (Arbitrum Sepolia for testnet)

---

## Executive Summary

This report covers a first-principles security audit focused on business logic bugs, cross-contract interaction bugs, and incentive/game-theory attacks. Static analysis issues (reentrancy, integer overflow under Solidity 0.8.x) are noted only where they interact with logic bugs.

| Severity | Count |
|---|---|
| Critical | 4 |
| High | 6 |
| Medium | 7 |
| Low | 5 |
| Informational | 6 |

**Overall assessment:** The protocol has a coherent academic foundation and several strong design decisions (CEI ordering in most paths, isolated margin, immutable leverage cap, dual-oracle with staleness checks). However, four critical bugs exist that can result in direct, quantifiable loss of user funds or permanent systemic insolvency before the protocol ever reaches mainnet scale. These must be fixed before any mainnet deployment handling real capital.

---

## Critical Findings

### C-1: PerpetualSukuk — All Investors Race for the Same Contract Balance; Principal Theft Is Possible

**Contract:** `/contracts/src/credit/PerpetualSukuk.sol`
**Lines:** 269–294 (redeem), 231–244 (claimProfit)
**Severity:** Critical

**Description:**

`PerpetualSukuk` holds a single ERC-20 balance for each deployed sukuk instance. That balance is funded by the issuer's `parValue` deposit at issuance. Both `claimProfit()` and `redeem()` draw from the raw `IERC20(s.token).balanceOf(address(this))` of the contract — the same pot shared by every sukuk ID ever created in the same contract deployment.

Crucially, every sukuk is deployed in the same contract (the contract manages all sukuk IDs). The redemption logic at lines 285–292 reads:

```solidity
uint256 balance = IERC20(s.token).balanceOf(address(this));
uint256 toPay   = principal > balance ? balance : principal;
if (toPay > 0) IERC20(s.token).safeTransfer(msg.sender, toPay);

uint256 remaining = IERC20(s.token).balanceOf(address(this));
uint256 actualCall = callUpside > remaining ? remaining : callUpside;
if (actualCall > 0) IERC20(s.token).safeTransfer(msg.sender, actualCall);
```

There is no per-sukuk-ID accounting of token balances. `balanceOf(address(this))` returns the combined balance of all sukuks and all undistributed profits from all issuers. This creates two attack vectors:

**Attack scenario A — Issuer steals other issuers' principal:**
1. Issuer A issues sukuk ID 0 with parValue = 1,000 USDC. Investors subscribe.
2. Issuer B issues sukuk ID 1 with parValue = 100,000 USDC. Investors subscribe. Contract now holds ~101,000 USDC.
3. Sukuk ID 0 matures. An investor with 500 USDC subscribed calls `redeem(0)`. The contract reads `balanceOf(this) = 101,000` and pays out principal (500 USDC) and then callUpside computed against the full 101,000 USDC remaining. The call upside ratio `callRateWad` is dimensionless but the `actualCall = callRateWad * principal / WAD` could be substantial, drawing from Sukuk 1's funds.

**Attack scenario B — First redeemer takes everything:**
1. Multiple investors subscribe to sukuk ID 0. Investor A has 600 USDC subscribed, Investor B has 400 USDC subscribed. Issuer deposited 1,000 USDC.
2. After profit distributions reduce the balance to, say, 700 USDC, Investor A calls `redeem(0)`.
3. Line 285: `balance = 700`. `toPay = min(600, 700) = 600`. Transfer 600. Now `remaining = 100`.
4. Investor B calls `redeem(0)`. `balance = 100`. `toPay = min(400, 100) = 100`. Investor B receives only 100/400 = 25% of their principal. The remaining 300 USDC is permanently lost.

**Attack scenario C — Profit distribution drains principal:**
If profit rates are generous (up to 99%/year as allowed by the `profitRateWad < WAD` check), long-duration sukuks will have profit distributions that drain the issuer's collateral before all investors redeem. Investors who redeem last receive zero principal.

**Impact:** Complete loss of principal for late-redeeming investors. Magnitude: up to 100% of subscribed amount per affected investor. An adversarial issuer can drain the entire contract balance using sukuk ID N after other issuers have deposited for sukuk IDs 0 through N-1.

**Recommendation:**
Implement per-sukuk-ID internal accounting:
```solidity
mapping(uint256 => uint256) private _sukukReserve;  // parValue deposited per sukuk
```
Deduct from `_sukukReserve[id]` on profit claims and redemptions. Reject if insufficient. Never use `balanceOf(address(this))` for payout logic.

---

### C-2: LiquidationEngine — Snapshot Is Stale; Positions Cannot Be Liquidated After Funding Moves Collateral Below Zero

**Contract:** `/contracts/src/core/LiquidationEngine.sol`
**Lines:** 144–152 (isLiquidatable), 159–215 (liquidate)
**Severity:** Critical

**Description:**

The LiquidationEngine operates entirely on `LiqSnapshot` data pushed to it by PositionManager. The snapshot holds `collateral` as last updated. However, funding payments in `_settleFundingInternal` (PositionManager.sol lines 404–415) can reduce `pos.collateral` to 0 (clamped at line 406) and then push an updated snapshot.

The critical bug is that `_settleFundingInternal` is only called in two paths: (a) when a position is closed by its owner, and (b) when `settleFunding(positionId)` is called externally. If neither happens, the snapshot sitting in LiquidationEngine can be arbitrarily stale.

Specifically at LiquidationEngine line 164–165:
```solidity
uint256 maintenanceMargin = snap.notional * MAINTENANCE_MARGIN_BPS / BPS_DENOM;
require(snap.collateral < maintenanceMargin, "LiquidationEngine: position healthy");
```

The `snap.collateral` is the value from the last `_pushLiqSnapshot` call — which happens at position open and at each `settleFunding` call. It does NOT reflect ongoing price movements. The collateral in the snapshot does NOT include unrealized PnL. A position could be deeply underwater (unrealized loss exceeds collateral) while the snapshot still shows the original collateral amount from open, making `isLiquidatable()` return false.

**Worse:** The LiquidationEngine's `isLiquidatable` and `liquidate` do not call the oracle or check current prices at all. They check only the stale collateral against the notional maintenance margin. A position that opened at 5x leverage requires only a 2% adverse move to breach maintenance margin (2% notional = collateral at 5x = 20% of collateral). But if funding has not been settled, the snapshot shows the original collateral and liquidation is impossible.

**Attack scenario (unliquidatable zombie position):**
1. Trader opens 5x long position. Collateral = 1,000 USDC, notional = 5,000 USDC. Maintenance margin = 100 USDC.
2. Market moves 20% against trader. Unrealized loss = 1,000 USDC = full collateral. Position is insolvent.
3. No one has called `settleFunding`. Snapshot shows `collateral = 1,000`. `isLiquidatable()` returns false (1,000 >= 100).
4. Position cannot be liquidated. Continues to accrue funding losses. Counterparty loss socialises to InsuranceFund.
5. When the trader eventually closes or funding settles, `finalCollateral` is deeply negative. The contract enters the `else` branch at line 295–300 of PositionManager which attempts `chargeFromFree` — but the trader's free balance is likely zero, causing a revert.

**Impact:** Insolvent positions remain open indefinitely. InsuranceFund is the ultimate payer. In a cascade scenario (rapid adverse market), many positions become simultaneously unliquidatable, causing protocol insolvency.

**Recommendation:**
1. The liquidation check MUST incorporate current oracle price and compute current equity (collateral + unrealized PnL). Pass the oracle address to LiquidationEngine.
2. Any keeper calling `liquidate` should be able to also call `settleFunding` first, or the liquidate function itself should settle funding before checking the threshold.
3. Consider a keeper-accessible `settleAndLiquidate(positionId)` that does both atomically.

---

### C-3: PositionManager.closePosition — Charging fundingCost From Free Balance After collateral Has Already Been Decremented Is Economically Incoherent and Causes Double-Deduction

**Contract:** `/contracts/src/core/PositionManager.sol`
**Lines:** 280–301 (closePosition, the settlement block)
**Severity:** Critical

**Description:**

In `closePosition`, the sequence is:
1. `pos.open = false` (CEI)
2. `_settleFundingInternal(positionId)` — this decrements `pos.collateral` by the funding payment amount
3. `vault.unlockCollateral(msg.sender, pos.collateralToken, pos.initialCollateral)` — this moves `initialCollateral` from locked to free
4. Then at lines 287–291:
```solidity
if (pos.initialCollateral > pos.collateral) {
    uint256 fundingCost = pos.initialCollateral - pos.collateral;
    vault.chargeFromFree(msg.sender, pos.collateralToken, fundingCost);
    IERC20(pos.collateralToken).forceApprove(address(insuranceFund), fundingCost);
    insuranceFund.receiveFromLiquidation(pos.collateralToken, fundingCost);
}
```

The problem: `_settleFundingInternal` does NOT transfer any actual ERC-20 tokens. It only updates the in-memory `pos.collateral` accounting variable. The actual USDC locked in the vault has NOT been reduced — the full `initialCollateral` amount is still sitting in the vault as locked balance.

Then `unlockCollateral` releases `initialCollateral` to free. Then `chargeFromFree` deducts `fundingCost` from the now-free balance. Then this deducted amount is forwarded to InsuranceFund.

But the funding cost was already economically borne by the counterparty (the funding payment model means longs pay shorts or vice versa). In a proper perpetual design, funding is transferred between long and short accounts directly. Here, funding is:
- Notionally deducted from `pos.collateral` (an accounting variable only)
- Then re-charged as actual USDC from the trader's free balance on close
- Then sent to InsuranceFund

This means the trader pays the funding cost TWICE in a sense: once as an accounting deduction affecting their PnL calculation, and once as a real USDC deduction at close. The PnL at line 271-272 uses `pos.entryPrice` not collateral, so the PnL calculation is separately correct — but `finalCollateral = int256(pos.collateral) + pnl` at line 274 uses the already-decremented collateral, and then the code ALSO charges `fundingCost` from free balance.

Furthermore, if the trader has no free balance (they deposited exactly `collateral` and nothing more), `chargeFromFree` will revert with "insufficient free balance", permanently trapping the position in the closed state (since `pos.open = false` was already set).

**Attack scenario (griefing / stuck positions):**
1. Trader deposits exactly 1,000 USDC. Opens position using all of it as collateral. Free balance = 0.
2. Position accrues 50 USDC of funding payments (collateral decremented to 950).
3. Trader calls `closePosition`. At step 3, `unlockCollateral` moves 1,000 USDC to free. Now free = 1,000.
4. `chargeFromFree(1000 - 950 = 50)` succeeds. Free = 950. Sent to InsuranceFund.
5. But trader also has a PnL loss or gain — if PnL is negative, no USDC is returned at all. If PnL is positive, the PnL is never actually paid out (see comment at line 293: "PnL settlement handled off-chain via InsuranceFund / counterparty matching").
6. The trader effectively gets back 0 from the protocol despite only having a 50 USDC funding loss on a 1,000 USDC position. The remaining 950 USDC is simply unlocked (free balance = 950 after the charge, then... nothing transfers it back to the trader).

The comment "PnL settlement handled off-chain" at line 293–294 is a massive red flag: the protocol as written does NOT actually transfer profits to winning traders. The `finalCollateral > 0` branch does nothing but the chargeFromFree call. There is no `vault.transfer` or ERC20 transfer sending profit to the trader. Traders with positive PnL receive zero.

**Impact:** (a) Traders with positive PnL receive 0; all profit is silently absorbed. (b) Traders with no free balance and any accumulated funding cost have their close permanently DoS'd. (c) The protocol's PnL settlement model is fundamentally incomplete for MVP deployment with real money.

**Recommendation:**
1. Implement proper counterparty matching or an AMM-style virtual reserve that actually pays winning traders.
2. Do not call `chargeFromFree` for funding cost if funding was already reflected in `pos.collateral`. Pick one accounting model.
3. If funding reduces the locked collateral accounting, ensure unlockCollateral releases only the current collateral, not `initialCollateral`.

---

### C-4: iCDS — Keeper-Triggered Credit Event Accepts Stale Oracle; No Time Validation After Trigger; Buyer Can Wait Indefinitely to Settle

**Contract:** `/contracts/src/credit/iCDS.sol`
**Lines:** 292–303 (triggerCreditEvent), 320–337 (settle)
**Severity:** Critical

**Description:**

**Part A — Keeper centralization and oracle gaming:**
`triggerCreditEvent` requires `authorisedKeepers[msg.sender]` — a whitelist controlled by the owner. The credit event trigger relies on a single oracle read:
```solidity
uint256 spotWad = oracle.getIndexPrice(prot.refAsset);
require(spotWad <= prot.recoveryFloorWad, "iCDS: no default");
```
The OracleAdapter's `getIndexPrice` has a 5-minute staleness threshold (`STALENESS_THRESHOLD = 5 minutes`). If both Chainlink feeds are stale (network congestion, oracle downtime), the function reverts ("All oracles stale"). This means:
- During the brief window when spot is at or below the recovery floor, if the oracle is stale, the keeper cannot trigger the credit event.
- An adversarial seller can predict oracle staleness windows (e.g., Chainlink heartbeat gaps) to create protection they know will default but time oracle staleness to prevent the trigger.

**Part B — No settlement deadline after trigger:**
After `triggerCreditEvent` sets `prot.status = Status.Triggered`, there is no time limit for the buyer to call `settle()`. The seller's full notional collateral remains locked in the contract indefinitely. There is no `expire` path for the Triggered state. A buyer can hold the triggered state open forever, preventing the seller from recovering collateral even in scenarios where the price has recovered above the floor.

This is the inverse of the oracle gaming above: a malicious buyer can wait until spot recovers above floor (so the seller feels the "default" was temporary), then settle anyway and receive the full LGD payout.

**Part C — No verification at settle time:**
`settle()` does not re-check the oracle. It only checks `prot.status == Status.Triggered`. If a keeper was corrupted or made an error (spot briefly touched floor due to fat-finger trade, then immediately recovered), the buyer receives full LGD payout on a non-default.

**Attack scenario (seller griefing via oracle timing):**
1. Seller opens 100,000 USDC protection with 40% recovery floor.
2. Reference asset spot = 100. Floor = 40.
3. Asset crashes to 38 (below floor). Buyer calls keeper to trigger. But Chainlink is in its 5-minute heartbeat gap. Call fails.
4. Asset bounces to 42 within 5 minutes. Keeper can no longer trigger (spot > floor).
5. Buyer paid premiums for quarters; seller retains collateral and premiums.

**Attack scenario (buyer exploit):**
1. Credit event triggered at spot = 38.
2. Seller cannot call expire (status = Triggered, not Active/Open).
3. Asset recovers to 200. Buyer has legal right to call settle() and receive (1 - 0.4) * 100,000 = 60,000 USDC.
4. Buyer waits arbitrarily long, keeping capital locked.

**Impact:** Up to 100% of notional locked indefinitely (seller side). Up to LGD * notional in unjustified payouts (buyer side if trigger was erroneous).

**Recommendation:**
1. Add a `SETTLEMENT_WINDOW` (e.g. 7 days) after which a triggered protection can be auto-expired if buyer has not settled.
2. Add a re-check of `spotWad <= prot.recoveryFloorWad` inside `settle()` or require a TWAP confirmation (not just spot) before triggering.
3. Add fallback logic for oracle staleness in `triggerCreditEvent` (e.g. use TWAP mark if spot is stale).

---

## High Findings

### H-1: FundingEngine — Single Rate Applied Uniformly Across All Elapsed Intervals; Oracle Manipulation Can Silently Inject Extreme Funding

**Contract:** `/contracts/src/core/FundingEngine.sol`
**Lines:** 151–185 (updateCumulativeFunding), 195–207 (_computeFundingRate)
**Severity:** High

**Description:**

When `updateCumulativeFunding` is called after `N` missed intervals, it computes a single current rate `rate = _computeFundingRate(market)` and applies it uniformly:
```solidity
cumulativeFundingIndex[market] += rate * int256(intervals);
```
This is a snapshot of the current moment's premium, backfilled for all elapsed intervals. If the funding engine has not been updated for 48 hours (48 intervals) and the current mark/index premium is at the circuit-breaker maximum of 75 bps, the cumulative index jumps by 48 * 0.0075 = 36%. All positions settled against this new index bear a 36% notional funding payment for what should have been smoothed over time.

Additionally, `lastFundingTime` is advanced by exactly `intervals * FUNDING_INTERVAL` not by the actual elapsed time. Partial intervals are silently dropped. In a low-activity market, funding can be undercollected indefinitely.

**Attack scenario (keeper griefing):**
1. Keeper stops calling `updateCumulativeFunding` for 48 hours (no new position opens to trigger it).
2. During this window, an adversary accumulates a large short position via the oracle's TWAP manipulation (pushing mark price up).
3. After 48 hours, adversary calls any function that triggers the update. Rate is at +75 bps (maximum). 48 intervals * 75 bps = 3,600 bps (36%) charged to all longs.
4. Adversary (short) receives 36% of their notional in 36% funding income. All longs are wiped out.

**Recommendation:** Apply the per-interval rate at the mark/index price that existed at each interval boundary, not the current price. This requires storing historical oracle observations. Alternatively, cap the number of intervals that can be back-applied in a single call (e.g., max 8 intervals = 8 hours), refusing to process more.

---

### H-2: OracleAdapter — TWAP Ring Buffer Corruption When recordMarkPrice Is Called More Than 60 Times Without TWAP Consumption

**Contract:** `/contracts/src/oracle/OracleAdapter.sol`
**Lines:** 222–232 (recordMarkPrice), 353–380 (_computeTWAP)
**Severity:** High

**Description:**

The ring buffer is of fixed size 60. `_twapHead` advances modulo 60. `_twapCount` is capped at 60. The TWAP computation at `_computeTWAP` iterates from the most recent observation backwards:
```solidity
for (uint256 i = 1; i <= count; i++) {
    uint256 idx = (head + 60 - i) % 60;
    ...
    if (obs.timestamp < cutoff) break;
}
```

If `recordMarkPrice` is called more than once in the same block (which is allowed — there is no duplicate-timestamp guard), multiple entries will have the same `obs.timestamp`. The TWAP loop computes `dt = prevTimestamp - obs.timestamp`. When two consecutive observations have the same timestamp, `dt = 0`, meaning `weightedSum += price * 0 = 0` and `totalTime += 0`. These entries contribute zero weight to the TWAP.

More critically: if a malicious keeper (note: `recordMarkPrice` has NO access control — it is callable by anyone) calls it 60 times in a single block with a manipulated price, the entire ring buffer is overwritten with that price and timestamp. `totalTime = 0` for all entries (same block), so `_computeTWAP` falls back to `_resolveIndexPrice` — the spot oracle. The TWAP protection is nullified.

**Access control issue:** `recordMarkPrice` at line 222 has no `onlyOwner` or authorised-caller guard. Anyone can call it. The comment in PositionManager line 231 says "OracleAdapter.recordMarkPrice is called externally by keeper in production." This means an adversary can freely spam price observations.

**Attack scenario:**
1. Asset spot = 50,000. Attacker calls `recordMarkPrice(asset, 75_000)` 60 times in one block. Ring buffer filled with 75,000 at current timestamp.
2. TWAP window = 30 minutes. All 60 entries have identical timestamps (current block). `totalTime = 0`. Fallback to spot oracle.
3. BUT in the next block, if 1 more observation with a different timestamp is added, `_computeTWAP` sees 1 entry (the new one) and 59 entries from the previous block. It calculates dt for the newest entry vs current timestamp. If the new entry was legitimate (price = 50,000), TWAP ≈ 50,000 weighted by seconds since last block. The 59 manipulated entries are all at the same timestamp and contribute 0 time weight. So the manipulation is self-neutralizing unless carefully timed.
4. The actual risk is: a legitimate keeper adds 1 price at $75,000 (manipulated via a flash trade), then attacker calls recordMarkPrice 59 more times at $75,000. Now all 60 entries have prices ≈ $75,000, and since they span different blocks, they DO have different timestamps. TWAP = $75,000 for the next 30 minutes. Funding rate = (75,000 - 50,000) / 50,000 = 50% → clamped to 75 bps. Maximum funding charged for 30+ minutes.

**Recommendation:**
1. Add an `authorised[msg.sender]` guard to `recordMarkPrice`.
2. Add a minimum time gap between observations (e.g., 1 minute).
3. Consider using Uniswap V3 TWAP or Chainlink price feeds directly for mark price rather than a self-maintained ring buffer.

---

### H-3: CollateralVault — chargeFromFree Has No whenNotPaused Check But Is Called During Close/Liquidation Flows That Assume It Succeeds

**Contract:** `/contracts/src/core/CollateralVault.sol`
**Lines:** 210–223 (chargeFromFree)
**Severity:** High

**Description:**

`chargeFromFree` has `whenNotPaused` modifier. However, `unlockCollateral` at line 169 does NOT have `whenNotPaused`. This means:

During a vault pause:
- `unlockCollateral` succeeds: locked balance moves to free balance (internal accounting)
- `chargeFromFree` fails: the actual ERC-20 transfer that charges fees/funding is blocked

In `PositionManager.closePosition`:
1. `vault.unlockCollateral(msg.sender, pos.collateralToken, pos.initialCollateral)` — succeeds even when paused
2. `vault.chargeFromFree(msg.sender, pos.collateralToken, fundingCost)` — reverts when paused

The close is now in a half-executed state: locked balance has been released to free, but the position is marked `pos.open = false`. The position is permanently closed (cannot be reopened) but the user has their collateral freed without paying the funding cost. The InsuranceFund does not receive its share.

Additionally, `withdraw` at line 119 does NOT have `whenNotPaused`, and the comment at line 124 explicitly allows withdrawal when paused after 72 hours. If a user can trigger a vault pause themselves (they cannot directly, but a governance attack could), they would free their collateral via the buggy close flow and withdraw immediately.

**Recommendation:** Add `whenNotPaused` to `unlockCollateral` OR remove `whenNotPaused` from `chargeFromFree` for consistency. More practically: ensure atomic operations (unlock + charge) cannot be split by a pause.

---

### H-4: ShariahGuard — validatePosition Checks collateralToken Asset Approval But Uses asset (Market ID) for pausedMarkets; Collateral Token Bypass

**Contract:** `/contracts/src/shariah/ShariahGuard.sol`
**Lines:** 144–157 (validatePosition)
**Severity:** High

**Description:**

`validatePosition(asset, collateral, notional)` checks:
```solidity
require(approvedAssets[asset], "ShariahGuard: asset not approved");
require(!pausedMarkets[asset], "ShariahGuard: market paused");
```

The `asset` parameter is the market identifier (e.g., WBTC address used as market key). The `collateralToken` is not passed to `validatePosition` at all. In `CollateralVault.deposit`, collateral token approval IS checked:
```solidity
require(shariahGuard.isApproved(token), "CollateralVault: token not Shariah-approved");
```

However, a user could deposit an approved collateral token (USDC), then call `openPosition` with:
- `asset` = WBTC (approved market)
- `collateralToken` = some non-Shariah-approved token that was NOT deposited through `deposit` but was directly `safeTransfer`'d to the vault

Wait — `lockCollateral` reads from `_freeBalance[user][token]`, which can only be non-zero if funds went through `deposit`. So the collateral token check in `deposit` does effectively gate collateral tokens. This is fine.

However, the `validatePosition` check does not verify that `collateralToken` is still approved at position-open time. A collateral token could be revoked by the Shariah board AFTER a user deposits but BEFORE they open a position. `deposit` approved it, `revokeAsset` revokes it, then `openPosition` does not re-check. The position opens with a now-prohibited collateral token. This is a compliance violation, not a direct financial loss.

More importantly: `pausedMarkets` is separate from `approvedAssets`. Revoking an asset (`approvedAssets[token] = false`) does NOT automatically pause the market. A market can be in the state `approvedAssets[asset] = false` but `pausedMarkets[asset] = false`. In that case, `validatePosition` would correctly reject (first require fails). But there is no function to pause markets in batch — each must be done individually. During the window between a Shariah board revocation decision and individual market pauses, positions can be opened on revoked assets via any market that uses that asset as both market ID and collateral.

**Recommendation:**
1. Pass `collateralToken` to `validatePosition` and re-check `approvedAssets[collateralToken]` inside it.
2. Add a function that atomically revokes an asset AND pauses all markets using that asset.

---

### H-5: GovernanceModule — No Quorum Requirement; Single Token Holder Can Pass Any Proposal

**Contract:** `/contracts/src/shariah/GovernanceModule.sol`
**Lines:** 168–177 (queue)
**Severity:** High

**Description:**

The `queue` function passes a proposal with:
```solidity
require(p.votesFor > p.votesAgainst, "Governance: did not pass");
```

There is no minimum quorum. A whale holding 1 BRKX token who votes FOR with 1 BRKX against a proposal with 0 votes against can queue any proposal with 1 > 0. With 100M BRKX minted to treasury at launch, whoever controls treasury controls all governance with no opposition.

Furthermore, voting weight is computed at vote time:
```solidity
uint256 weight = IERC20(governanceToken).balanceOf(msg.sender);
```

This is a live balance check, not a historical snapshot. An attacker can:
1. Borrow 50M BRKX via flash loan or market purchase.
2. Cast vote in the same block.
3. Pass governance with 50M votes FOR, 0 against.
4. Queue and execute after 48-hour timelock.

The flash-loan attack is somewhat mitigated by the 48-hour timelock (attacker must hold tokens for 48 hours to execute), but a whale with sustained holdings can trivially pass any proposal.

**Recommendation:**
1. Add a `QUORUM_BPS` (e.g., 10% of total supply = 10M BRKX must participate).
2. Use snapshot-based voting weights (`ERC20Votes.getPastVotes`) rather than live balances. `BRKXToken` already extends `ERC20Votes`, but `GovernanceModule` does not use `getPastVotes`.
3. Add a `VOTING_PERIOD` after which votes close before queuing is allowed.

---

### H-6: TakafulPool and iCDS — Double-Dip Risk: No Linkage Between iCDS Payout and TakafulPool Claim

**Contracts:** `/contracts/src/credit/iCDS.sol`, `/contracts/src/takaful/TakafulPool.sol`
**Severity:** High

**Description:**

The protocol layers iCDS (credit default swap) and TakafulPool (mutual insurance) as independent contracts with no shared state. A protection buyer holding an iCDS contract on an asset that falls below the recovery floor can simultaneously:

1. Trigger the credit event on iCDS → settle and receive LGD payout from seller's collateral.
2. Call TakafulPool.payClaim (via a keeper) for the same asset falling below the floor, receiving an additional payout from the mutual pool.

Both contracts independently check `spotWad < floorWad` (TakafulPool line 280) and `spotWad <= recoveryFloorWad` (iCDS line 299). There is no cross-contract registry of who has received what payout for which event.

The TakafulPool keeper is authorised by the TakafulPool owner. If the same entity is both a protection buyer in iCDS and a pool member in TakafulPool, and they are also the keeper, they can pay themselves twice.

Even without the keeper being the same entity: the pool pays the claim to `beneficiary` specified by the keeper. The keeper has no on-chain constraint preventing them from designating the iCDS buyer as the TakafulPool beneficiary.

**Impact:** Double-counting of losses. The iCDS seller loses their collateral. The TakafulPool contributors lose their tabarru funds. The buyer profits from both. This violates the Islamic finance principle of indemnity (takaful is for actual loss compensation, not profit).

**Recommendation:**
1. Maintain a shared registry mapping (asset, event_timestamp) → claimants who have received payout.
2. Require the TakafulPool keeper to provide proof (or attestation) that no iCDS settlement has been received for the same credit event by the same beneficiary.
3. Consider deploying a unified claim settlement contract that orchestrates both layers.

---

## Medium Findings

### M-1: FundingEngine — Funding Accumulates Against a Single Rate for Multi-Hour Gaps With No Circuit Breaker on Total Accumulated Delta

**Contract:** `/contracts/src/core/FundingEngine.sol`
**Lines:** 168–177
**Severity:** Medium

The circuit breaker is per-rate (±75 bps per interval) but not per-total. If funding is not settled for 100 intervals (100 hours), total cumulative can move by 100 * 75 bps = 75%. For a 5x levered position, this exceeds total collateral (5x leverage means 20% collateral). After ~27 missed intervals at max rate, any open position at max leverage is technically insolvent. The missing piece is a position-level circuit breaker that auto-liquidates or freezes positions after a threshold total funding exposure.

---

### M-2: CollateralVault — Withdrawal Cooldown Applies Per-Token, Not Per-Position; Can Be Gamed With Multiple Tokens

**Contract:** `/contracts/src/core/CollateralVault.sol`
**Lines:** 119–140 (withdraw), 103–112 (deposit)
**Severity:** Medium

The 24-hour cooldown is tracked per `_lastDeposit[user][token]`. A user depositing USDC must wait 24 hours to withdraw USDC. However, a user can deposit PAXG (a different token), immediately open a PAXG-collateral position (locking PAXG), then withdraw the existing USDC (which has its own separate cooldown). The cooldown is not correlated to position activity — it only tracks the most recent deposit of that specific token. This means the cooldown provides much weaker protection than intended against a pattern of: deposit → manipulation → withdraw.

---

### M-3: PerpetualSukuk — Profit Drain Attack: Rapid claimProfit Calls Can Exhaust Issuer Collateral Before Maturity

**Contract:** `/contracts/src/credit/PerpetualSukuk.sol`
**Lines:** 231–244 (claimProfit)
**Severity:** Medium

`claimProfit` has no minimum elapsed time before a claim. A small `elapsed` gives a small but non-zero `profit` only if `amount * profitRateWad * elapsed` overflows the WAD denominator. For very large subscriptions and high profit rates (up to 99%/year), even 1-second elapsed times yield non-zero profit. More importantly, there is no limit on how many times per day this can be called. Each call updates `lastProfitAt = block.timestamp`, resetting the clock. Multiple investors calling every second would create significant gas costs but also systematically drain the balance in micro-increments. While the economic impact per call is small, over millions of calls it creates unpredictable depletion of the issuer's collateral before maturity.

**Recommendation:** Enforce a minimum profit claim interval (e.g., 1 day).

---

### M-4: OracleAdapter — Circuit Breaker Compares Against lastValidPrice Which Is Only Updated by Explicit snapshotPrice Calls; New Assets Have No Baseline

**Contract:** `/contracts/src/oracle/OracleAdapter.sol`
**Lines:** 261–265 (_resolveIndexPrice circuit breaker block), 116–124 (snapshotPrice)
**Severity:** Medium

When a new asset is configured via `setOracle`, `lastValidPrice[asset]` is explicitly set to 0:
```solidity
lastValidPrice[asset] = 0; // explicit init; circuit breaker seeds on first snapshotPrice call
```
Until `snapshotPrice` is called, `lastValidPrice[asset] == 0`, so the circuit breaker check:
```solidity
if (last > 0) { ... require(...); }
```
is skipped entirely. Any price is accepted without the 20% deviation check. If `snapshotPrice` is never called (forgotten by operator), the circuit breaker is permanently disabled for that asset.

**Recommendation:** Call `snapshotPrice` atomically in `setOracle`, or require `lastValidPrice > 0` before allowing `getIndexPrice` to be used in financial functions.

---

### M-5: LiquidationEngine — Liquidation Split Calculation Has Off-by-One When Penalty Is Capped

**Contract:** `/contracts/src/core/LiquidationEngine.sol`
**Lines:** 172–182
**Severity:** Medium

```solidity
uint256 penalty       = snap.notional * LIQUIDATION_PENALTY_BPS / BPS_DENOM;
if (penalty > available) penalty = available;

uint256 insuranceShare  = snap.notional * LIQUIDATION_PENALTY_BPS * INSURANCE_SPLIT_BPS
                          / (BPS_DENOM * BPS_DENOM);
if (insuranceShare > penalty / 2) insuranceShare = penalty / 2;
uint256 liquidatorShare = penalty - insuranceShare;
```

When `penalty` is capped to `available`, `insuranceShare` is recomputed from the uncapped `notional` (using the original formula), then capped to `penalty / 2`. If `penalty = available = 5` (odd), `penalty / 2 = 2` (integer division truncates). `insuranceShare = 2`, `liquidatorShare = 3`. Then `remaining = available - penalty = 0`. The split is 2+3=5=available, which is correct. However, the `remaining` calculation at line 183 `available - penalty` can underflow if `penalty` was not properly capped before this subtraction — but `penalty` IS capped to `available` above, so `remaining = 0` correctly. The mathematical precision loss is small but the comment "Cap penalty to available collateral before splitting" suggests the intent was to split evenly, not to over-allocate to the liquidator.

**Recommendation:** Recompute `insuranceShare = penalty / 2` after the penalty cap, not from the original notional formula.

---

### M-6: EverlastingOption — _expWad Uses Bitshift for 2^k Reconstruction Which Destroys WAD Precision for Large k

**Contract:** `/contracts/src/core/EverlastingOption.sol`
**Lines:** 499–511 (_expWad reconstruction)
**Severity:** Medium

```solidity
if (k >= 0) {
    ...
    return (er << uk);   // e^r * 2^k (WAD-correct since 2^k shifts)
} else {
    ...
    return (er >> uk);   // e^r / 2^k
}
```

`er` is `uint256` representing `e^r` in WAD (1e18 = 1.0). Multiplying by `2^k` via left-shift is only WAD-correct when `k = 0`. For `k > 0`, `er << k` is NOT `e^r * 2^k` in WAD — it is `e^r_raw * 2^k` where `e^r_raw` already incorporates the 1e18 scale. This gives a result that is `2^k` times too large in WAD terms.

Example: `x = ln(2) ≈ 0.693e18` (WAD). Expected result: `e^x = 2e18`. Range reduction gives `k=1`, `r = x - ln2 ≈ 0`. `er = e^0 = 1e18`. `er << 1 = 2e18`. OK, this case works.

Example: `x = 2*ln(2) ≈ 1.386e18`. Expected: `e^x = 4e18`. `k=2`, `r ≈ 0`, `er ≈ 1e18`. `er << 2 = 4e18`. Also works.

Actually the shift IS mathematically correct for the specific range reduction used here because `e^x = e^r * 2^k` and the shift represents multiplication by 2^k. The WAD scale of `er` is preserved because `er` is a WAD value and `2^k` is an integer multiplier, not a WAD multiplier. This is correct.

However, for negative `k`, `er >> uk` is integer division by `2^uk`. For large negative exponents (e.g., `x = -60e18`), `k = -60/ln(2) ≈ -86`, `uk = 86`, `er ≈ 1e18` (e^r near 1), and `er >> 86 = 0` since 2^86 >> 1e18 (which is ~2^60). This would correctly return 0 for very negative exponents. The earlier guard `if (exponent < -88 * int256(WAD)) return 0` catches the extreme cases. This appears mathematically sound.

**Revised assessment:** This is informational, not medium severity. The math is correct. Downgraded below.

---

### M-7: InsuranceFund — receiveFromLiquidation Requires Caller to Pre-Approve Tokens But Caller Is PositionManager Which Does Not Hold Tokens; Double-Transfer Inefficiency

**Contract:** `/contracts/src/insurance/InsuranceFund.sol`
**Lines:** 86–97 (receiveFromLiquidation)
**Severity:** Medium

`InsuranceFund.receiveFromLiquidation` calls `IERC20(token).safeTransferFrom(msg.sender, address(this), amount)`. This requires `msg.sender` (PositionManager) to have: (a) the tokens in its balance, and (b) an approval to the InsuranceFund.

In `PositionManager._collectFee`:
1. `vault.chargeFromFree(user, collToken, feeAmount)` — vault safeTransfers `feeAmount` to PositionManager.
2. `IERC20(collToken).forceApprove(address(insuranceFund), half)` — PositionManager approves InsuranceFund.
3. `insuranceFund.receiveFromLiquidation(collToken, half)` — InsuranceFund pulls from PositionManager.

This triple-hop (vault → PM → InsuranceFund) works correctly but is gas-inefficient. More importantly, `forceApprove` (which sets approval to 0 then to the new value) leaves a residual approval risk window. If PositionManager is called by multiple concurrent transactions (not possible on EVM but worth noting for future parallel chain deployments), the approval could be consumed by a different path.

Also: `vault.chargeFromFree` sends ERC-20 to the caller (PositionManager) at line 220 of CollateralVault: `IERC20(token).safeTransfer(msg.sender, amount)`. But PositionManager is not expected to hold tokens — it's a logic contract. Tokens sitting in PositionManager between steps 1 and 3 are a custody risk (any bug or reentrancy in step 2–3 could strand them).

**Recommendation:** Have CollateralVault directly transfer to InsuranceFund by adding a `chargeAndSendTo(from, token, amount, recipient)` function, eliminating the transit through PositionManager.

---

## Low Findings

### L-1: ShariahGuard — transferShariahMultisig Has No Two-Step Confirmation; Typo Can Transfer Control Permanently

**Contract:** `/contracts/src/shariah/ShariahGuard.sol`
**Lines:** 128–132
**Severity:** Low

`transferShariahMultisig` immediately sets `shariahMultisig = newMultisig` without any acceptance step. If the new multisig address is mistyped or is an EOA with a lost key, Shariah compliance enforcement is permanently compromised. Contrast with `Ownable2Step` used elsewhere in the protocol. The same issue exists in GovernanceModule lines 239–243.

**Recommendation:** Implement a two-step transfer: propose new multisig, require new multisig to call `acceptShariahMultisig()`.

---

### L-2: PositionManager — _collectFee Comment Says "divide by 100,000" But Math Is Inconsistent With the feeBps Unit Description

**Contract:** `/contracts/src/core/PositionManager.sol`
**Lines:** 349–359
**Severity:** Low

The comment says feeBps are "in units of 0.001 bps × 10 = 0.01 bps" but the code says `feeAmount = (notional * feeBps) / 100_000`. For feeBps = 50 (5.0 bps), `50 / 100_000 = 0.05%` = 5 bps. That is correct. But the comment description is misleading and could cause future maintainer errors. The division by 100,000 (not 10,000) is the source of confusion — standard BPS uses 10,000 as denominator for percentage. Here 100,000 is used to support half-basis-point precision. The comment should be clarified.

---

### L-3: BRKXToken — Voting Weight in GovernanceModule Uses Live Balance Not Checkpoint; BRKX Must Be Delegated for ERC20Votes to Work But Delegation Is Not Required

**Contract:** `/contracts/src/token/BRKXToken.sol`, `/contracts/src/shariah/GovernanceModule.sol`
**Lines:** GovernanceModule lines 150–151
**Severity:** Low

`BRKXToken` extends `ERC20Votes`, which requires holders to `delegate` before their votes are counted in `getPastVotes`. However, `GovernanceModule.castVote` uses `IERC20(governanceToken).balanceOf(msg.sender)` (raw ERC20 balance), NOT `IVotes(governanceToken).getPastVotes(msg.sender, block.number - 1)`. This means: (a) the `ERC20Votes` extension in BRKXToken is wasted — delegation is irrelevant; (b) the raw balance approach is vulnerable to flash-loan manipulation (mitigated by timelock but not eliminated).

---

### L-4: TakafulPool — operator Is immutable; Cannot Be Changed If Operator Key Is Compromised

**Contract:** `/contracts/src/takaful/TakafulPool.sol`
**Lines:** 75 (immutable operator), 139
**Severity:** Low

The Wakala fee recipient is `immutable`. If the operator's private key is compromised, all future Wakala fees go to an adversary. There is no emergency override mechanism. `operator` should be a mutable admin-controlled address.

---

### L-5: iCDS — Seller Can Open Multiple Protections With the Same notional; No Aggregate Exposure Limit Per Seller

**Contract:** `/contracts/src/credit/iCDS.sol`
**Lines:** 176–211 (openProtection)
**Severity:** Low

A seller can open arbitrarily many protection contracts. Each requires depositing the full `notional`, so the collateral requirement is enforced per-contract. However, the protocol has no registry of a seller's aggregate exposure across all active contracts. In a correlated default scenario, all contracts default simultaneously. The seller is fully collateralized for each, so this is not a direct bug — but it means large sellers can concentrate systemic risk in the protocol, and there is no governance-level cap on total iCDS notional outstanding.

---

## Business Logic Analysis

### On-Chain Formula vs. Paper Math

**FundingEngine vs. Paper 1:**
The paper establishes that at ι=0, `f_t = x_t` (perpetual price equals spot). The on-chain formula `F = (mark - index) / index` is correct as the per-interval rate; it represents the proportional basis. The circuit breaker at ±75 bps is a reasonable engineering choice not mathematically specified in the paper — the paper operates in continuous time. The discrete-time accumulation `cumulativeIndex += rate * intervals` is a correct first-order approximation of the continuous integral `∫κ dt` but uses a stale rate (see H-1).

**EverlastingOption vs. Paper 2 (Proposition 6):**
The characteristic equation implementation at EverlastingOption lines 340–352:
```
D = 1/4 + 2κ/σ²
sqrtD = √D
β₋ = 1/2 - sqrtD
β₊ = 1/2 + sqrtD
denom = 2 * sqrtD = β₊ - β₋
```
This correctly implements the paper's formula `β = ½ ± √(¼ + 2κ/σ²)`. The put and call pricing formulas in `_quotePut` and `_quoteCall` correctly implement `Π_put = [K^{1-β₋}/(β₊-β₋)] * x^{β₋}` in log-space. The log-space computation is the right approach for numerical stability.

**However, there is a precision issue:** The `_lnWad` function uses 60 iterations of the binary expansion for the fractional log₂. The fractional correction constant `794_705_707_972_521_572` (the fractional bits of log₂(1e18)) may have accumulated rounding error from the binary expansion itself — this should be verified against a reference implementation (e.g., PRBMath's `ln`). An error in this constant propagates to all option prices.

**kappa estimation (OracleAdapter.getKappaSignal vs. Paper 3):**
The paper defines κ as the convergence intensity of the OU process: `dP = -κP dt + σ dW`. The on-chain estimator uses:
```
κ̂ = (P_old - P_new) / (P_old × Δt)
```
This is a valid discrete-time approximation of `κ ≈ -ΔP/(P * Δt)` = first-order OU speed. However, it uses only two observations and the current index price as the reference for both historical bases `P_old` and `P_new`:
```solidity
int256 P_old = (int256(obsOld.price) - int256(indexPrice)) * 1e18 / int256(indexPrice);
int256 P_new = (int256(obsNew.price) - int256(indexPrice)) * 1e18 / int256(indexPrice);
```
Using the current index price for both historical observations is incorrect: the historical basis should be computed against the index price at the time of observation. For slowly moving indices this is a small error, but during fast-moving markets (when κ estimation is most critical), the bias can be substantial. The paper implicitly assumes basis is computed against contemporaneous index.

**PerpetualSukuk callUpside vs. Paper 2:**
The paper's credit equivalence theorem establishes that the stopping time θ maps to the Poisson arrival of a "claim settlement event," and the embedded call is fairly priced at `Π_call(spot, par)`. The implementation correctly applies `callRateWad = Π_call(spot, parValue)` and `callUpside = callRateWad * principal / WAD`. The dimensionless WAD ratio interpretation is correct.

**Critical deviation:** The paper's sukuk model assumes the call upside is funded by the issuer (e.g., from investment returns on the deployed principal). The implementation instead draws call upside from the same balance as principal repayment — meaning call upside directly reduces the ability to repay principal. If `callRateWad` is large (high volatility, asset near par), all investors redeeming simultaneously will exhaust the balance. The paper did not anticipate this balance-sharing bug (C-1 above).

---

## Cross-Contract Interaction Analysis

### Call Graph: Oracle Staleness During Liquidation

```
LiquidationEngine.liquidate()
    → does NOT call oracle
    → uses only LiqSnapshot.collateral (stale)
    → vault.unlockCollateral() → CollateralVault (no oracle)
    → vault.transferCollateral() → CollateralVault (no oracle)
    → insuranceFund.receive...  [if applicable]
```

**Finding:** LiquidationEngine never calls the oracle. It relies entirely on the snapshot pushed by PositionManager. If PositionManager's `settleFunding` (which triggers `_pushLiqSnapshot`) has not been called recently, the snapshot is stale. A rapid oracle price crash that moves a position from healthy to deeply underwater in one block will leave the snapshot showing the pre-crash collateral. `isLiquidatable()` returns false. No liquidation is possible until someone triggers a funding update. This is the core of C-2.

### Call Graph: Collateral Withdrawal vs. Liquidation Race

```
User calls CollateralVault.withdraw(token, freeBalance)  — no lock check on positions
LiquidationEngine.liquidate() reads LiqSnapshot.collateral — stale locked balance
```

The race condition between user withdrawal and liquidation is partially protected: `withdraw` only touches `_freeBalance`, while `liquidate` touches `_lockedBalance`. A user cannot withdraw locked collateral. The race is thus NOT exploitable in the sense that users cannot steal locked collateral before liquidation.

However, there is a related issue: a user with 1,000 USDC free balance and a healthy position can withdraw all 1,000 USDC during the 24-hour cooldown window reset (if they time their deposit-withdrawal correctly), leaving zero free balance. When their position later becomes liquidatable and `remainig = snap.collateral - penalty`, the trader receives `remaining` back as unlocked (free) balance. But if the trader then needs to meet a closing fee (via `chargeFromFree`), the free balance might be insufficient.

### Call Graph: InsuranceFund Empty During Cascade

```
LiquidationEngine.liquidate()
    → does NOT call InsuranceFund.coverShortfall()
    → InsuranceFund only receives (not pays) during liquidation
```

Wait — LiquidationEngine transfers penalty shares to InsuranceFund but does NOT call `coverShortfall`. The shortfall coverage path is in PositionManager's close logic (conceptually — but in practice, PositionManager does NOT call `coverShortfall` either; it calls `receiveFromLiquidation` only). The `coverShortfall` function exists but is never called by any contract in the current codebase.

**This means: the InsuranceFund never actually covers shortfalls.** It receives inflows (from fees and liquidation penalties) but `coverShortfall` is an authorised function that no contract ever calls. During a cascade liquidation where positions are insolvent beyond their collateral, no protocol mechanism routes InsuranceFund reserves to cover the gap. Losing traders simply receive zero; the bad debt is unrecovered.

### Call Graph: ShariahGuard Bypass Paths

All paths to `PositionManager.openPosition` call `shariahGuard.validatePosition`. This is the primary entry point.

**Bypass check:** Can `vault.lockCollateral` be called without going through PositionManager? Only by authorised callers (`authorised[msg.sender]`). LiquidationEngine and PositionManager are authorised. LiquidationEngine does NOT call `lockCollateral`. PositionManager always calls `validatePosition` before `lockCollateral`. So no bypass exists in the current code.

**However:** The ShariahGuard's `whenNotPaused` modifier (inherited from `Pausable`) means if ShariahGuard is paused, `validatePosition` reverts. This effectively pauses ALL position openings. The ShariahGuard has no `owner` — only `shariahMultisig` can pause it. But note ShariahGuard extends `Pausable` which has no `owner`; it inherits `_pause()` and `_unpause()` but never exposes them via any function. So ShariahGuard can NEVER be paused by anyone — the `whenNotPaused` in `validatePosition` is a dead code path. `pause()` and `unpause()` are not defined in ShariahGuard, and Pausable's internal `_pause/_unpause` are not exposed.

**Actually:** Looking more carefully — `ShariahGuard` extends `Pausable` but does NOT define `pause()` or `unpause()` functions. The `Pausable` base contract's `_pause()` and `_unpause()` are internal and can only be called by functions defined in the child. Since no such functions exist, `paused()` will always return false, and `whenNotPaused` is always satisfied. This is dead code but not a vulnerability in the current state.

---

## Incentive Attack Surface

### Kappa-Rate Manipulation

The funding rate `F = (mark - index) / index` can be manipulated by moving the mark price. The mark price is a 30-minute TWAP of `recordMarkPrice` observations. `recordMarkPrice` has no access control (H-2). An attacker can spam manipulated mark price observations.

**Capital required to move the TWAP for 30 minutes:**
If legitimate mark price observations are recorded once per position open (by a keeper in production), and observations are also recorded by `openPosition` indirectly, the attacker needs to either:
(a) Outpace legitimate observations with 60 manipulated ones in the ring buffer, OR
(b) Move the actual Chainlink spot price (very expensive for BTC/ETH) to create a real premium.

Path (a) is free — `recordMarkPrice` has no access control. The attacker calls it 60 times with a high price in consecutive blocks. After 30 minutes, the TWAP is computed over these manipulated observations. Maximum manipulation: 75 bps per interval per 30-minute window = negligible but compounds over time.

Realistic profit: At 5x leverage and 75 bps per-interval funding income, a large short position gains `notional * 75 bps * intervals`. For a $10M notional short, 8 hours of max funding = $10M * 0.0075 * 8 = $600,000 funding income extracted from longs.

### Liquidation MEV / Sandwich

A liquidator can front-run a keeper's `settleFunding` call: see that a position will become liquidatable after funding is settled, and immediately call `liquidate` in the same block (or next block, since there's a 1-block delay requirement). Since `liquidate` is open to anyone and pays a 1% penalty to the caller, this is standard MEV. On Arbitrum, sequencer ordering provides some protection, but in a decentralized sequencer future, this is fully exploitable.

**Self-sandwich by liquidator:** A liquidator who also controls mark price observations can:
1. Record manipulated mark price observations pushing funding rate to max.
2. Position holder's collateral drops after funding settlement.
3. Liquidator calls `settleFunding` then `liquidate` atomically.
4. Receive 0.5% of notional as liquidator share plus the premium arbitrage.

### TakafulPool Contribution Timing Game

The tabarru amount is priced at `Π_put(spot, floor)`. This put price is lowest when spot is far above the floor. A rational actor who expects the asset to fall toward the floor can:

1. When spot is high (put is cheap), contribute a large tabarru and obtain coverage for a large `coverageAmount`.
2. Wait for spot to fall toward floor.
3. Have the keeper trigger `payClaim` for their `coverageAmount`.
4. Receive payout >> tabarru paid.

This is not a bug — it's the designed mechanism (analogous to buying insurance before a storm). However, if the everlasting option pricing `Π_put` does not fully account for the current IV term structure (because σ² is set by admin rather than derived from market implied volatility), the pricing can systematically underprice the put, allowing participants to buy protection below actuarially fair value.

**Admin-set σ² risk:** The `sigmaSquaredWad` parameter in `EverlastingOption.setMarket` is set by the contract owner, not derived from observed option markets. If set too low (underestimating volatility), all puts are underpriced, all tabarru contributions are below actuarially fair value, and the TakafulPool will eventually be insolvent.

### iCDS Seller Moral Hazard

The iCDS contract allows a seller to set the `recoveryRateWad` (recovery assumption). A seller who sets `recoveryRateWad = 0.01e18` (1% recovery = 99% LGD) will price a very expensive put premium (buyer pays more) and also face a 99% LGD on default. However, the seller can set `recoveryRateWad` optimally to maximize premium income versus default risk. There is no requirement that the recovery rate be consistent with market-observed recovery rates or any oracle-verified floor.

A more concerning scenario: a seller opens multiple protections on the same reference asset with different recovery floors, collecting premiums from multiple buyers. If the asset defaults on all of them simultaneously, the seller's collateral (fully deposited) covers each separately. This is well-designed. But the seller could create a protection on an asset they know will default (insider information), collect premium, and then the asset defaults. The "anti-naked-CDS" collateral requirement does not prevent this moral hazard — it only ensures the seller CAN pay, not that they acted in good faith.

### InsuranceFund Drain via Controlled Account

The `distributeSurplus` function requires `balance > 2 * weeklyClaimsSum`. An attacker controlling an account that generates frequent small shortfalls (via positions that go barely insolvent) can repeatedly trigger `coverShortfall` (if any contract calls it — currently none do) to keep `weeklyClaimsSum` high and prevent surplus distribution. However, since no contract currently calls `coverShortfall`, this attack is not currently possible.

### Governance: Single Multisig Key Blast Radius

If `shariahMultisig` is compromised:
1. All `approvedAssets` can be revoked, halting all new position openings.
2. All markets can be paused via `emergencyPause`, freezing existing positions.
3. All governance proposals can be vetoed, preventing any DAO response.
4. The multisig can be transferred to an attacker-controlled address via `transferShariahMultisig`, making the compromise permanent.
5. The governance token itself can be pointed to any address via `GovernanceModule.setGovernanceToken` (callable by `shariahMultisig`).

**The `shariahMultisig` is described as a "3-of-5 multisig" in comments, but this is not enforced on-chain.** The contract stores a plain `address` and checks `msg.sender == shariahMultisig`. Whether that address is actually a 3-of-5 Safe multisig or a single EOA is completely unverifiable on-chain. If deployed with an EOA as `shariahMultisig`, a single key compromise gives unlimited control over Shariah compliance enforcement, governance vetoes, and governance token configuration.

**Recommendation:** Enforce that `shariahMultisig` is a contract with a minimum-threshold check, or at minimum document and verify the Safe multisig address on-chain via interface ID check.

---

## What This Audit Cannot Catch

**1. Chainlink feed reliability and manipulation capital requirements.** This audit notes that the circuit breaker threshold (20% deviation) might be too wide for certain assets. The actual capital required to move a Chainlink BTC/ETH feed by 20% on Arbitrum was not computed — it depends on DEX liquidity, arbitrage bots, and Chainlink's own circuit breakers. A qualified market structure analyst should compute this.

**2. Economic viability of the κ-rate as a pricing parameter.** The papers establish the mathematical framework. Whether κ as implemented (using two TWAP observations and a current index price) will produce stable, non-manipulable option prices in live markets is an empirical question. The simulation results in paper 3 are cadCAD-based and may not capture the adversarial behavior of real arbitrageurs.

**3. Shariah compliance of the specific implementation.** This audit checks whether the code matches the stated Shariah compliance claims in comments and papers. Whether those claims are themselves jurisprudentially correct (e.g., whether the tabarru/wakala structure truly avoids riba) requires an AAOIFI-certified scholar review, not a code audit.

**4. Arbitrum-specific risks.** The protocol targets Arbitrum One. Arbitrum's sequencer centralization, L1-L2 message delays, and force-inclusion mechanisms were not analyzed. In particular, if the Arbitrum sequencer is offline, no funding settlements occur, compounding the batch-funding issue in H-1.

**5. Upgrade/proxy risk.** No contracts use the proxy pattern, so there is no upgrade risk. This is a deliberate design choice. However, if bugs are found post-launch, there is no upgrade path — the entire protocol must be redeployed and liquidity migrated.

**6. Front-end / off-chain keeper reliability.** The protocol critically depends on keepers to call `settleFunding`, `snapshotPrice`, `recordMarkPrice`, and `triggerCreditEvent` regularly. The security of the keeper system (key management, MEV protection, uptime SLA) was not reviewed.

**7. Gas limit risks.** The 60-observation TWAP loop and the 60-iteration `_lnWad` binary expansion were not profiled for gas usage at Arbitrum's block gas limits. In theory, 60 iterations of a simple loop is well within limits, but this should be verified with hardhat-gas-reporter on the actual deployment configuration.

**8. Token economics and BRKX supply concentration.** 100M BRKX minted to a single treasury address. The governance security against that address (or whoever controls it) was not analyzed.

---

## Appendix: File-to-Finding Cross-Reference

| Contract | Findings |
|---|---|
| PositionManager.sol | C-3, H-3 (interaction), L-2 |
| CollateralVault.sol | H-3, M-2 |
| FundingEngine.sol | H-1, M-1 |
| LiquidationEngine.sol | C-2, M-5 |
| EverlastingOption.sol | M-6 (downgraded to info) |
| PerpetualSukuk.sol | C-1, M-3 |
| iCDS.sol | C-4, H-6, L-5 |
| InsuranceFund.sol | (cross-ref C-2, C-3), M-7 |
| OracleAdapter.sol | H-2, M-4 |
| ShariahGuard.sol | H-4, L-1 |
| GovernanceModule.sol | H-5, L-1, L-3 |
| TakafulPool.sol | H-6, L-4 |
| BRKXToken.sol | L-3 |

---

*This report was generated by an AI agent and represents automated first-principles analysis. It is not a substitute for a full human audit by a qualified smart contract security firm (e.g., Trail of Bits, Zellic, OtterSec). All Critical and High findings should be independently confirmed before mainnet deployment.*

---

## Slither Static Analysis Results (our contracts only)

**Tool:** Slither 0.10.x via `forge build --build-info`
**Total results:** 131 across 58 contracts (library + src). Below: findings in `src/` only.

### S-1: PerpetualSukuk.claimProfit — Dangerous Strict Equality (Medium)
**File:** `src/credit/PerpetualSukuk.sol:239`
`if (profit == 0) revert` — strict equality on a token amount can be bypassed by sending 1 wei of profit, and may malfunction with fee-on-transfer tokens where `balanceOf` differs by 1 from expected.
**Fix:** Use `if (profit < MINIMUM_CLAIM_AMOUNT)` or document intentionally.

### S-2: EverlastingOption._getKappaAnnual — Unused Return Value (Low)
**File:** `src/core/EverlastingOption.sol:365`
`(kappaPerSec,None,None) = oracle.getKappaSignal(asset)` — the second and third return values (regime, lastUpdate) are silently discarded. If the regime indicates CRITICAL, the option price calculation should respond differently.
**Fix:** Use all return values and apply regime-aware dampening.

### S-3: EverlastingOption._expWad — Divide-Before-Multiply (Low)
**File:** `src/core/EverlastingOption.sol:468,484–496`
Taylor series accumulation divides then multiplies across terms, accumulating precision loss for large inputs. Not exploitable in normal ranges but could cause option mispricing at extreme volatility.

### S-4: OracleAdapter._kappaSignal — Divide-Before-Multiply (Medium)
**File:** `src/oracle/OracleAdapter.sol:341,350`
`P_old = (price - index) * 1e18 / index` then `kappa = (P_old - P_new) * 1e18 / (P_old * dt)` — nested division before multiplication. At low prices (near 1e-4 USD assets), precision loss can produce systematically wrong kappa signals.
**Fix:** Use `mulDiv` from OZ Math library for all intermediate calculations.

### S-5: TakafulPool.contribute — Divide-Before-Multiply (Low)
**File:** `src/takaful/TakafulPool.sol:208,212`
`tabarruGross = (putRateWad * coverage) / WAD` then `wakala = (tabarruGross * WAKALA_FEE_BPS) / 10_000` — rounding down twice. Systematically under-charges tabarru at small coverage amounts.

### S-6: LiquidationEngine.setPositionManager — Missing Emit (Low)
**File:** `src/core/LiquidationEngine.sol:94–97`
Critical admin function with no event. Monitoring systems cannot detect if the positionManager address is changed.
**Fix:** Add `emit PositionManagerSet(pm)`.

### S-7: GovernanceModule Constructor — Missing Zero-Address Check (Low)
**File:** `src/shariah/GovernanceModule.sol:94,97`
If `_governanceToken = address(0)` is passed at deploy, governance is permanently broken (no votes possible). No zero-check.
**Fix:** `require(_governanceToken != address(0))`.

### S-8: PositionManager.openPosition — Benign Reentrancy (Informational)
**File:** `src/core/PositionManager.sol:197–224`
External calls to fundingEngine, vault, insuranceFund before positionId is written. All three external contracts are trusted/owned. Low risk, but CEI pattern violated.

### S-9: GovernanceModule.execute — Low-Level Call Return Not Handled (Medium)
**File:** `src/shariah/GovernanceModule.sol:190`
`(ok, err) = p.target.call(p.callData)` — `ok` is checked (`require(ok, ...)`) but the return data `err` is ignored. Revert reason is lost. Governance proposals that fail silently produce unhelpful error messages.

### S-10: BRKXToken.nonces — Variable Shadowing (Informational)
**File:** `src/token/BRKXToken.sol:81`
Local variable `owner` shadows `Ownable.owner()`. No functional impact but lowers readability.

### S-11: Pragma Version Fragmentation (Informational)
5 different Solidity version constraints across OZ library and project contracts. Project contracts correctly use `^0.8.24` (which resolves `VerbatimInvalidDeduplication` and other compiler bugs present in `^0.8.20` used by OZ). No action needed — this is an OZ library version issue.

---

## What This AI Audit Cannot Catch

1. **Economic parameter calibration**: The κ-rate sensitivity analysis in Paper 3 shows the system is stable for β ∈ [0.02, 0.08]. Whether the deployed `KAPPA_SENSITIVITY` constant matches this range requires running the simulation with mainnet-realistic liquidity.

2. **Chainlink oracle reliability on Arbitrum**: The staleness threshold (5 min) may be inappropriate for Arbitrum's sequencer uptime. Arbitrum can experience sequencer downtime → Chainlink stops updating → all oracle reads revert → protocol frozen. Needs sequencer uptime check (L2Sequencer feed).

3. **Gas economics under Arbitrum L1 data posting**: The TWAP ring buffer writes (60 storage slots) are expensive. Under L1 congestion, gas spikes could make keeper maintenance economically unviable.

4. **Cross-chain MEV from Arbitrum block proposer**: The block proposer on Arbitrum has limited MEV compared to Ethereum L1, but L1-L2 message ordering is still exploitable by sophisticated actors.

5. **Real AAOIFI scholar review**: Whether the iCDS mechanism is genuinely Shariah-compliant (as argued in Paper 2) requires sign-off from a qualified scholar. The code implements what the paper describes; whether the paper's argument is acceptable to Islamic finance scholars is out of scope.

6. **Social engineering of shariahMultisig**: If shariahMultisig is a single EOA (as currently deployed on testnet), physical/social compromise of that key means the entire Shariah compliance layer can be bypassed. Requires hardware wallet and multi-party scheme.

---

## Summary for Code4rena / Sherlock Submission

This pre-audit found **4 Critical**, **6 High**, **7 Medium**, **5 Low**, **6 Informational** findings. All 4 Critical findings should be fixed before submitting to a competitive audit. Submitting with known Criticals artificially inflates the prize pool and attracts lower-quality wardens. Fix C-1 through C-4 first, then submit with this report as context for wardens.

**Estimated fix effort:**
- C-1 (PerpetualSukuk balance isolation): 2–4 hours
- C-2 (LiquidationEngine oracle integration): 4–8 hours + tests
- C-3 (PositionManager PnL settlement): 8–16 hours (requires architectural decision on AMM vs off-chain PnL)
- C-4 (iCDS settlement window): 2 hours

Total: 1–3 days to fix all Criticals. Then re-run this audit + forge tests before submitting to Code4rena.
