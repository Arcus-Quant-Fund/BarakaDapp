// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPositionManager
 * @notice Minimal interface for external callers (governance, scripts, tests).
 */
interface IPositionManager {
    function setBrkxToken(address brkx) external;
    function setTreasury(address treasury) external;
}
