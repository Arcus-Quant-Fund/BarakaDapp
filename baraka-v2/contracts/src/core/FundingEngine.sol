// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IFundingEngine.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title FundingEngine
 * @author Baraka Protocol v2
 * @notice Premium-only funding rate (ι=0). Per-second accrual on 8-hour basis.
 *
 *         Formula (from dYdX v4, adapted for Shariah — no interest component):
 *           premium = (mark_price - index_price) / index_price
 *           rate_per_second = premium / (8 * 3600)
 *           clamped at ±(IMR - MMR) × 0.9 per 8h period
 *
 *         Ackerer, Hugonnier & Jermann (2024/2025) proved convergence with ι=0.
 *         dYdX v4 uses interest=0% in practice. This makes it explicit and permanent.
 */
contract FundingEngine is IFundingEngine, Ownable2Step, Pausable {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;
    uint256 constant FUNDING_PERIOD = 8 hours;

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    IOracleAdapter public immutable oracle;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    struct FundingState {
        int256  cumulativeIndex;  // cumulative funding index (1e18)
        uint256 lastUpdateTime;   // last time funding was accrued
        int256  lastRate;         // last computed funding rate per 8h (1e18)
    }

    /// @notice Per-market funding state
    mapping(bytes32 => FundingState) public fundingState;

    /// @notice Per-market clamp rate: (IMR - MMR) × 0.9 per 8h period
    mapping(bytes32 => uint256) public clampRate;

    /// AUDIT FIX (P10-M-7): Track whether the previous updateFunding call saw a stale oracle.
    /// Used to detect oracle recovery so the clock can be reset without a retroactive accrual spike.
    mapping(bytes32 => bool) private _wasStaleOnLastCall;

    /// AUDIT FIX (P6-I-2): Removed dead `authorised` mapping and `setAuthorised()` — updateFunding()
    /// is intentionally permissionless (any keeper can accrue). The mapping was never checked.

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event FundingUpdated(bytes32 indexed marketId, int256 rate, int256 cumulativeIndex, uint256 elapsed);
    event ClampRateSet(bytes32 indexed marketId, uint256 clampRate);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner, address _oracle) Ownable(initialOwner) {
        require(_oracle != address(0), "FE: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    /// @notice Set the clamp rate for a market. Called when market is created.
    ///         clamp = (IMR - MMR) × 0.9 (per 8h period)
    /// AUDIT FIX (L1B-L-6): Validate clamp rate is positive — zero disables clamping
    /// AUDIT FIX (P2-MEDIUM-13): Add upper bound — clampRate near int256.max causes overflow
    ///         in rate * elapsed multiplication (int256(clamp) overflows if clamp > int256.max).
    function setClampRate(bytes32 marketId, uint256 _clampRate) external onlyOwner {
        require(_clampRate > 0, "FE: zero clamp rate");
        require(_clampRate <= WAD, "FE: clamp rate > 100% per 8h");
        clampRate[marketId] = _clampRate;
        emit ClampRateSet(marketId, _clampRate);
    }

    /// AUDIT FIX (P2-HIGH-8): Prevent ownership renouncement — FundingEngine requires owner for clamp rates.
    function renounceOwnership() public view override onlyOwner {
        revert("FE: renounce disabled");
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────
    // Core
    // ─────────────────────────────────────────────────────

    /// @notice Accrue funding for a market. Returns updated cumulative index.
    /// AUDIT FIX (P3-FE-1): Removed whenNotPaused — updateFunding() is called by _settleFundingForPosition()
    /// during liquidation close path. FundingEngine pause must not block liquidations (same rationale as
    /// P2-CRIT-3 which removed whenNotPaused from LiquidationEngine.liquidate()).
    function updateFunding(bytes32 marketId) external override returns (int256) {
        FundingState storage state = fundingState[marketId];

        if (state.lastUpdateTime == 0) {
            // First call — initialize
            state.lastUpdateTime = block.timestamp;
            return state.cumulativeIndex;
        }

        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        if (elapsed == 0) return state.cumulativeIndex;

        /// AUDIT FIX (P6-M-1): Do NOT advance clock during oracle staleness.
        /// _computePremiumRate returns 0 when stale (P5-M-7), but if we advance lastUpdateTime,
        /// the funding for the stale period is permanently lost (0 × elapsed = 0).
        /// A griefer calling updateFunding() every block during an oracle outage would
        /// zero out all accrual for that period. By freezing the clock, funding resumes
        /// retroactively when the oracle comes back online (capped at FUNDING_PERIOD).
        if (oracle.isStale(marketId)) {
            /// AUDIT FIX (P10-M-7): Record staleness so oracle recovery can be detected on next call.
            _wasStaleOnLastCall[marketId] = true;
            return state.cumulativeIndex;
        }

        /// AUDIT FIX (P10-M-7): Oracle recovery — reset clock without accruing.
        /// When the oracle just recovered from a stale period, elapsed equals the entire
        /// outage duration. Applying FUNDING_PERIOD retroactively at the post-recovery rate
        /// can produce a sharp spike that extracts significant value from one side (e.g. if
        /// mark/index basis blew out during the outage). Reset the clock clean from now.
        if (_wasStaleOnLastCall[marketId]) {
            _wasStaleOnLastCall[marketId] = false;
            state.lastUpdateTime = block.timestamp;
            return state.cumulativeIndex;
        }

        /// AUDIT FIX (L1B-M-7): Cap elapsed time — prevent stale rate applied retroactively
        if (elapsed > FUNDING_PERIOD) elapsed = FUNDING_PERIOD;

        // Compute current premium rate
        int256 rate = _computePremiumRate(marketId);

        // Clamp rate
        /// AUDIT FIX (L1B-M-6): Require clamp rate to be set (0 = unbounded funding)
        uint256 clamp = clampRate[marketId];
        require(clamp > 0, "FE: clamp rate not set");
        if (rate > int256(clamp)) rate = int256(clamp);
        if (rate < -int256(clamp)) rate = -int256(clamp);

        // Accrue: index += rate × elapsed / FUNDING_PERIOD
        int256 accrual = rate * int256(elapsed) / int256(FUNDING_PERIOD);
        state.cumulativeIndex += accrual;
        state.lastUpdateTime = block.timestamp;
        state.lastRate = rate;

        emit FundingUpdated(marketId, rate, state.cumulativeIndex, elapsed);
        return state.cumulativeIndex;
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    function getCumulativeFunding(bytes32 marketId) external view override returns (int256) {
        return fundingState[marketId].cumulativeIndex;
    }

    function getCurrentRate(bytes32 marketId) external view override returns (int256) {
        return _computePremiumRate(marketId);
    }

    /// @notice Compute pending funding payment for a position.
    ///         Positive = position owes funding. Negative = position receives funding.
    ///         Longs pay when mark > index (positive premium).
    ///         Shorts pay when mark < index (negative premium).
    function getPendingFunding(
        bytes32 marketId,
        int256  positionSize,
        int256  entryFundingIndex
    ) external view override returns (int256) {
        int256 currentIndex = fundingState[marketId].cumulativeIndex;

        // Also accrue pending (not yet updated) funding
        /// AUDIT FIX (L1B-L-5): Guard against uninitialized market (lastUpdateTime == 0)
        uint256 lastUpdate = fundingState[marketId].lastUpdateTime;
        if (lastUpdate == 0) return 0;
        uint256 elapsed = block.timestamp - lastUpdate;
        /// AUDIT FIX (L1B-M-7): Cap elapsed time in view too
        if (elapsed > FUNDING_PERIOD) elapsed = FUNDING_PERIOD;
        if (elapsed > 0) {
            int256 rate = _computePremiumRate(marketId);
            uint256 clamp = clampRate[marketId];
            if (clamp > 0) {
                if (rate > int256(clamp)) rate = int256(clamp);
                if (rate < -int256(clamp)) rate = -int256(clamp);
            }
            currentIndex += rate * int256(elapsed) / int256(FUNDING_PERIOD);
        }

        int256 indexDelta = currentIndex - entryFundingIndex;
        // funding = indexDelta × positionSize / WAD
        // Long (positive size) with positive indexDelta → pays funding
        return indexDelta * positionSize / int256(WAD);
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /// @dev Premium rate = (mark - index) / index per 8h period.
    ///      Pure convergence mechanism — no interest component (ι=0).
    /// @dev INFO (L1B-I-2): Clamping logic appears in both updateFunding and getPendingFunding.
    ///      Kept inline for clarity — extracting a helper saves ~20 bytes but reduces readability.
    /// @dev INFO (L1-I-3): updateFunding is permissionless by design — keepers or anyone can accrue.
    /// @dev INFO (P5-M-1): `authorised` mapping is dead code — updateFunding() is intentionally
    ///      permissionless so any keeper can accrue funding. The mapping exists but is never checked.
    function _computePremiumRate(bytes32 marketId) internal view returns (int256) {
        /// AUDIT FIX (P5-M-7): Return 0 when oracle is stale — prevents funding accrual
        /// at a stale rate, which could extract value from counterparties.
        if (oracle.isStale(marketId)) return 0;

        uint256 indexPrice = oracle.getIndexPrice(marketId);
        uint256 markPrice  = oracle.getMarkPrice(marketId);

        if (indexPrice == 0) return 0;

        // premium = (mark - index) / index
        return (int256(markPrice) - int256(indexPrice)) * int256(WAD) / int256(indexPrice);
    }
}
