// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ILiquidationEngine {
    function isLiquidatable(bytes32 positionId) external view returns (bool);
    function liquidate(bytes32 positionId) external;
}
