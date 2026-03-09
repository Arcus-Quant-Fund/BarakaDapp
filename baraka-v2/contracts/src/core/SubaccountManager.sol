// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ISubaccountManager.sol";
import "../interfaces/IOrderBook.sol";

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

    /// AUDIT FIX (P16-AC-H1): Owner for access control on orderbook management.
    address public owner;

    /// @notice subaccountId → owner address
    mapping(bytes32 => address) private _owners;

    /// @notice subaccountId → exists flag
    mapping(bytes32 => bool) private _exists;

    /// @notice owner → count of created subaccounts
    mapping(address => uint256) private _counts;

    /// AUDIT FIX (P10-H-7): Registered orderbooks — iterated in closeSubaccount to cancel resting orders.
    address[] private _registeredOrderBooks;

    // ─────────────────────────────────────────────────────
    // Errors & Modifiers
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P16-AC-H1): Restrict orderbook management to deployer.
    modifier onlyOwner() {
        require(msg.sender == owner, "SAM: not contract owner");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P16-AC-H1): Set deployer as owner for orderbook access control.
    constructor() {
        owner = msg.sender;
    }

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event SubaccountCreated(address indexed owner, uint8 index, bytes32 indexed subaccountId);
    event SubaccountClosed(address indexed owner, uint8 index, bytes32 indexed subaccountId);
    event OrderBookRegistered(address indexed orderBook);
    /// AUDIT FIX (P16-AC-H1)
    event OrderBookRemoved(address indexed orderBook);

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
    /// AUDIT FIX (P10-H-7): Cancel all resting orders before closing. Without this,
    /// orders placed by a closed subaccount remain live in the orderbook. When filled,
    /// MatchingEngine's existence check (P7-L-2) fires at settlement — the order was
    /// already placed and sits in the book unguarded until matched or manually cancelled.
    function closeSubaccount(uint8 index) external {
        bytes32 subaccountId = getSubaccountId(msg.sender, index);
        require(_exists[subaccountId], "SAM: not exists");
        require(_owners[subaccountId] == msg.sender, "SAM: not owner");

        for (uint256 i = 0; i < _registeredOrderBooks.length; i++) {
            try IOrderBook(_registeredOrderBooks[i]).cancelAllOrders(subaccountId) {} catch {}
        }

        _exists[subaccountId] = false;
        _counts[msg.sender]--;

        emit SubaccountClosed(msg.sender, index, subaccountId);
    }

    /// AUDIT FIX (P10-H-7): Register an orderbook for resting-order cancellation on subaccount close.
    /// AUDIT FIX (P16-AC-H1): Restricted to owner — previously permissionless, allowing anyone
    /// to fill all 32 orderbook slots with dummy addresses, bricking removeOrderBook management
    /// and wasting gas in closeSubaccount's iteration loop.
    function registerOrderBook(address ob) external onlyOwner {
        require(ob != address(0), "SAM: zero orderbook");
        /// AUDIT FIX (P12-SAM-1): Cap array length to prevent gas exhaustion in closeSubaccount().
        require(_registeredOrderBooks.length < 32, "SAM: too many orderbooks");
        for (uint256 i = 0; i < _registeredOrderBooks.length; i++) {
            if (_registeredOrderBooks[i] == ob) return;
        }
        _registeredOrderBooks.push(ob);
        emit OrderBookRegistered(ob);
    }

    /// AUDIT FIX (P16-AC-H1): Remove an orderbook from the registered list.
    /// Swap-and-pop for O(1) removal. Order doesn't matter — closeSubaccount iterates all.
    function removeOrderBook(address ob) external onlyOwner {
        uint256 len = _registeredOrderBooks.length;
        for (uint256 i = 0; i < len; i++) {
            if (_registeredOrderBooks[i] == ob) {
                _registeredOrderBooks[i] = _registeredOrderBooks[len - 1];
                _registeredOrderBooks.pop();
                emit OrderBookRemoved(ob);
                return;
            }
        }
        revert("SAM: orderbook not found");
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    /// @notice Deterministic subaccount ID from owner + index.
    /// @dev INFO (L0-I-6): abi.encodePacked is safe here — (address, uint8) is a fixed-size
    ///      tuple with no collision risk (address=20 bytes, uint8=1 byte, no variable-length data).
    /// @dev INFO (L1-I-4): Owner added per AUDIT FIX (P16-AC-H1) for orderbook management access control.
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
