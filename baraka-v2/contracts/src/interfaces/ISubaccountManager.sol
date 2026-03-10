// SPDX-License-Identifier: BUSL-1.1
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
    /// AUDIT FIX (P19-L-2): Renamed `owner` → `user` to avoid shadowing Ownable2Step.owner().
    function getSubaccountId(address user, uint8 index) external pure returns (bytes32);
    function getOwner(bytes32 subaccountId) external view returns (address);
    function exists(bytes32 subaccountId) external view returns (bool);
    /// AUDIT FIX (P19-L-2): Renamed `owner` → `user` to avoid shadowing Ownable2Step.owner().
    function subaccountCount(address user) external view returns (uint256);
}
