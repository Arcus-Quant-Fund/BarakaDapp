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

    function getPremium(address asset) external view override returns (int256) {
        uint256 mark  = markPrices[asset] > 0 ? markPrices[asset] : indexPrices[asset];
        uint256 index = indexPrices[asset];
        if (index == 0) return 0;
        return (int256(mark) - int256(index)) * 1e18 / int256(index);
    }

    function getKappaSignal(address asset)
        external view override
        returns (int256 kappa, int256 premium, uint8 regime)
    {
        premium = this.getPremium(asset);
        int256 abs = premium < 0 ? -premium : premium;
        if      (abs < 15e14) regime = 0;
        else if (abs < 40e14) regime = 1;
        else if (abs < 60e14) regime = 2;
        else                  regime = 3;
        kappa = 0; // no history in mock
    }
}
