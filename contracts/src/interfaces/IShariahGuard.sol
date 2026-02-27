// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IShariahGuard {
    function validatePosition(address asset, uint256 collateral, uint256 notional) external view;
    function isApproved(address asset) external view returns (bool);
    function MAX_LEVERAGE() external view returns (uint256);
}
