// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFundingEngine
 * @notice Premium-only funding (ι=0). 8-hour basis, continuous per-second accrual.
 *         F = premium / 8h where premium = (mark - index) / index.
 *         Clamped at ±(IMR - MMR) × 0.9.
 */
interface IFundingEngine {
    function updateFunding(bytes32 marketId) external returns (int256 cumulativeIndex);
    function getCumulativeFunding(bytes32 marketId) external view returns (int256);
    function getCurrentRate(bytes32 marketId) external view returns (int256);
    function getPendingFunding(bytes32 marketId, int256 positionSize, int256 entryFundingIndex)
        external view returns (int256);
}
