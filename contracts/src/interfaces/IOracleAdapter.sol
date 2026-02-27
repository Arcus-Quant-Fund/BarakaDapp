// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapter {
    function getIndexPrice(address asset) external view returns (uint256);
    function getMarkPrice(address asset, uint256 twapWindow) external view returns (uint256);
}
