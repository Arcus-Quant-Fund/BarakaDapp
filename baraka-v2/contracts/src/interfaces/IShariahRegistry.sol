// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IShariahRegistry
 * @notice Shariah compliance enforcement. Called before every fill.
 */
interface IShariahRegistry {
    function isApprovedAsset(bytes32 marketId) external view returns (bool);
    function isApprovedCollateral(address token) external view returns (bool);
    function maxLeverage(bytes32 marketId) external view returns (uint256);
    function validateOrder(bytes32 subaccount, bytes32 marketId, int256 newSize, uint256 collateral) external view;
    function isProtocolHalted() external view returns (bool);
}
