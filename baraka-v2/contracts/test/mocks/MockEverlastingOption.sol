// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../src/interfaces/IEverlastingOption.sol";

/// @notice Configurable mock for IEverlastingOption. Returns fixed rates for put/call quotes.
contract MockEverlastingOption is IEverlastingOption {
    uint256 public putRate = 0.05e18; // 5% default
    uint256 public callRate = 0.05e18;

    function setPutRate(uint256 rate) external {
        putRate = rate;
    }

    function setCallRate(uint256 rate) external {
        callRate = rate;
    }

    function quotePut(bytes32, uint256, uint256) external view override returns (uint256) {
        return putRate;
    }

    function quoteCall(bytes32, uint256, uint256) external view override returns (uint256) {
        return callRate;
    }

    function quoteAtSpot(bytes32, uint256)
        external
        view
        override
        returns (uint256 putPriceWad, uint256 callPriceWad, uint256 spotWad, uint256 kappaWad, int256 betaNegWad, int256 betaPosWad)
    {
        return (putRate, callRate, 1e18, 0.1e18, -1e18, 2e18);
    }

    function getExponents(bytes32)
        external
        pure
        override
        returns (int256 betaNegWad, int256 betaPosWad, uint256 denomWad)
    {
        return (-1e18, 2e18, 3e18);
    }
}
