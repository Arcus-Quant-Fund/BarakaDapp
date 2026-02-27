// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/interfaces/IOracleAdapter.sol";

/// @notice Mock oracle for testing — returns configurable prices
contract MockOracle is IOracleAdapter {
    mapping(address => uint256) public indexPrices;
    mapping(address => uint256) public markPrices;

    function setIndexPrice(address asset, uint256 price) external {
        indexPrices[asset] = price;
    }

    function setMarkPrice(address asset, uint256 price) external {
        markPrices[asset] = price;
    }

    function getIndexPrice(address asset) external view override returns (uint256) {
        uint256 p = indexPrices[asset];
        require(p > 0, "MockOracle: no price set");
        return p;
    }

    function getMarkPrice(address asset, uint256) external view override returns (uint256) {
        uint256 p = markPrices[asset];
        if (p == 0) return indexPrices[asset]; // fallback to index
        require(p > 0, "MockOracle: no price set");
        return p;
    }
}
