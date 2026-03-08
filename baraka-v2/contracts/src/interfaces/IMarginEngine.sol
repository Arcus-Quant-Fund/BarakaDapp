// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IMarginEngine
 * @notice Cross-margin calculations. Computes equity, margin requirements,
 *         and liquidation status for subaccounts.
 */
interface IMarginEngine {
    struct Position {
        bytes32 marketId;
        int256  size;       // positive = long, negative = short (1e18)
        uint256 entryPrice; // volume-weighted average entry (1e18)
        int256  entryFundingIndex; // cumulative funding at open
    }

    struct MarketParams {
        uint256 initialMarginRate;     // IMR in 1e18 (e.g. 0.1e18 = 10% = 10x max leverage)
        uint256 maintenanceMarginRate; // MMR in 1e18 (e.g. 0.05e18 = 5%)
        uint256 maxPositionSize;       // max notional per subaccount per market
        bool    active;
    }

    function getEquity(bytes32 subaccount) external view returns (int256);
    function getFreeCollateral(bytes32 subaccount) external view returns (int256);
    function getInitialMarginReq(bytes32 subaccount) external view returns (uint256);
    function getMaintenanceMarginReq(bytes32 subaccount) external view returns (uint256);
    function isLiquidatable(bytes32 subaccount) external view returns (bool);
    function getPosition(bytes32 subaccount, bytes32 marketId) external view returns (Position memory);
    function getMarketParams(bytes32 marketId) external view returns (MarketParams memory);

    function updatePosition(bytes32 subaccount, bytes32 marketId, int256 sizeDelta, uint256 fillPrice) external;
    function settleFunding(bytes32 subaccount) external;
}
