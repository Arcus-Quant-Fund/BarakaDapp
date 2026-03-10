// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IOracleAdapter
 * @notice Dual-source oracle (Chainlink + TWAP) for margin/liquidation.
 *         NOT used for trade execution (orderbook prices are market-driven).
 */
interface IOracleAdapter {
    function getIndexPrice(bytes32 marketId) external view returns (uint256);
    function getMarkPrice(bytes32 marketId) external view returns (uint256);
    function isStale(bytes32 marketId) external view returns (bool);
    /// @notice Update EWMA mark price with a fill price. Called by MatchingEngine after each trade.
    function updateMarkPrice(bytes32 marketId, uint256 tradePrice) external;
    /// AUDIT FIX (P15-H-6): Expose lastUpdateTime for oracle recovery detection.
    /// Used by iCDS to extend grace period after oracle outage.
    function getLastUpdateTime(bytes32 marketId) external view returns (uint256);
}
