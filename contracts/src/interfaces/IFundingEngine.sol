// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFundingEngine {
    function getFundingRate(address market) external view returns (int256);
    function updateCumulativeFunding(address market) external returns (int256 cumulativeIndex);
    function cumulativeFundingIndex(address market) external view returns (int256);
}
