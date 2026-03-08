// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISubaccountManager
 * @notice Manages cross-margin subaccounts (dYdX v4 pattern).
 *         Each address can have up to 256 subaccounts.
 *         Subaccount ID = keccak256(owner, index).
 */
interface ISubaccountManager {
    struct SubaccountInfo {
        address owner;
        uint8   index;
        bool    exists;
    }

    function createSubaccount(uint8 index) external returns (bytes32 subaccountId);
    function getSubaccountId(address owner, uint8 index) external pure returns (bytes32);
    function getOwner(bytes32 subaccountId) external view returns (address);
    function exists(bytes32 subaccountId) external view returns (bool);
    function subaccountCount(address owner) external view returns (uint256);
}
