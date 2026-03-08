// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ISubaccountManager.sol";

/**
 * @title SubaccountManager
 * @author Baraka Protocol v2
 * @notice Manages cross-margin subaccounts (dYdX v4 pattern).
 *
 *         Each address can create up to 256 subaccounts (index 0-255).
 *         Subaccount ID = keccak256(abi.encodePacked(owner, index)).
 *
 *         Default subaccount (index 0) is auto-created on first deposit.
 *         Additional subaccounts enable isolated-margin-like behavior
 *         within the cross-margin system.
 *
 *         Example: A trader wants cross-margin for BTC+ETH but isolated for DOGE:
 *           - Subaccount 0: BTC long + ETH short (shared margin)
 *           - Subaccount 1: DOGE long (isolated — own collateral)
 */
contract SubaccountManager is ISubaccountManager, ReentrancyGuard {

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice subaccountId → owner address
    mapping(bytes32 => address) private _owners;

    /// @notice subaccountId → exists flag
    mapping(bytes32 => bool) private _exists;

    /// @notice owner → count of created subaccounts
    mapping(address => uint256) private _counts;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event SubaccountCreated(address indexed owner, uint8 index, bytes32 indexed subaccountId);
    event SubaccountClosed(address indexed owner, uint8 index, bytes32 indexed subaccountId);

    // ─────────────────────────────────────────────────────
    // Core
    // ─────────────────────────────────────────────────────

    /// @notice Create a new subaccount. Reverts if already exists.
    function createSubaccount(uint8 index) external override returns (bytes32 subaccountId) {
        subaccountId = getSubaccountId(msg.sender, index);
        require(!_exists[subaccountId], "SAM: already exists");

        _owners[subaccountId] = msg.sender;
        _exists[subaccountId] = true;
        _counts[msg.sender]++;

        emit SubaccountCreated(msg.sender, index, subaccountId);
    }

    /// AUDIT FIX (P6-L-4): Allow owners to close subaccounts for storage hygiene.
    /// Closed subaccounts can be re-created via createSubaccount().
    /// @dev Owner mapping preserved intentionally — downstream contracts use getOwner()
    ///      for position management. Closing only affects the `exists` flag and count.
    function closeSubaccount(uint8 index) external {
        bytes32 subaccountId = getSubaccountId(msg.sender, index);
        require(_exists[subaccountId], "SAM: not exists");
        require(_owners[subaccountId] == msg.sender, "SAM: not owner");

        _exists[subaccountId] = false;
        _counts[msg.sender]--;

        emit SubaccountClosed(msg.sender, index, subaccountId);
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    /// @notice Deterministic subaccount ID from owner + index.
    /// @dev INFO (L0-I-6): abi.encodePacked is safe here — (address, uint8) is a fixed-size
    ///      tuple with no collision risk (address=20 bytes, uint8=1 byte, no variable-length data).
    /// @dev INFO (L1-I-4): SubaccountManager is intentionally ownerless — minimal, immutable by design.
    function getSubaccountId(address owner, uint8 index) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(owner, index));
    }

    function getOwner(bytes32 subaccountId) external view override returns (address) {
        return _owners[subaccountId];
    }

    function exists(bytes32 subaccountId) external view override returns (bool) {
        return _exists[subaccountId];
    }

    function subaccountCount(address owner) external view override returns (uint256) {
        return _counts[owner];
    }
}
