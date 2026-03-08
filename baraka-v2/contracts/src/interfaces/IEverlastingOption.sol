// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IEverlastingOption
 * @notice Everlasting option pricer (Ackerer Prop 6, iota=0).
 */
interface IEverlastingOption {
    function quotePut(bytes32 marketId, uint256 xWad, uint256 kWad) external view returns (uint256);
    function quoteCall(bytes32 marketId, uint256 xWad, uint256 kWad) external view returns (uint256);
    function quoteAtSpot(bytes32 marketId, uint256 kWad) external view returns (
        uint256 putPriceWad, uint256 callPriceWad, uint256 spotWad,
        uint256 kappaWad, int256 betaNegWad, int256 betaPosWad
    );
    function getExponents(bytes32 marketId) external view returns (int256 betaNegWad, int256 betaPosWad, uint256 denomWad);
}
