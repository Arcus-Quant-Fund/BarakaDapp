// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICollateralVault {
    function lockCollateral(address user, address token, uint256 amount) external;
    function unlockCollateral(address user, address token, uint256 amount) external;
    function transferCollateral(address from, address to, address token, uint256 amount) external;
    function chargeFromFree(address from, address token, uint256 amount) external;
    function balance(address user, address token) external view returns (uint256);
}
