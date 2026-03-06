// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidationEngine {
    function isLiquidatable(bytes32 positionId) external view returns (bool);
    function liquidate(bytes32 positionId) external;

    function updateSnapshot(
        bytes32 positionId,
        address trader,
        address asset,
        address collateralToken,
        uint256 collateral,
        uint256 notional,
        uint256 entryPrice,
        uint256 openBlock,
        bool    isLong
    ) external;

    function removeSnapshot(bytes32 positionId) external;
}
