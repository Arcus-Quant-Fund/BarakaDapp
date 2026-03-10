// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../../src/interfaces/IOracleAdapter.sol";

/// @notice Simple mock oracle for testing. Prices set manually.
contract MockOracleAdapter is IOracleAdapter {
    mapping(bytes32 => uint256) public indexPrices;
    mapping(bytes32 => uint256) public markPrices;

    function setIndexPrice(bytes32 marketId, uint256 price) external {
        indexPrices[marketId] = price;
    }

    function setMarkPrice(bytes32 marketId, uint256 price) external {
        markPrices[marketId] = price;
    }

    function getIndexPrice(bytes32 marketId) external view override returns (uint256) {
        return indexPrices[marketId];
    }

    function getMarkPrice(bytes32 marketId) external view override returns (uint256) {
        uint256 mark = markPrices[marketId];
        return mark > 0 ? mark : indexPrices[marketId];
    }

    function isStale(bytes32 marketId) external view override returns (bool) {
        return indexPrices[marketId] == 0;
    }

    function updateMarkPrice(bytes32 marketId, uint256 tradePrice) external override {
        markPrices[marketId] = tradePrice;
    }

    function getLastUpdateTime(bytes32 /* marketId */) external pure override returns (uint256) {
        return 0; // Default: no oracle recovery scenario in unit tests
    }
}
