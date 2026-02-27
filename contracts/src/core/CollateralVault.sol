// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ICollateralVault.sol";
import "../interfaces/IShariahGuard.sol";

/**
 * @title CollateralVault
 * @author Baraka Protocol
 * @notice Custodian of user collateral. Strict no-rehypothecation policy.
 *
 * Islamic finance basis:
 *   - Qabdh (possession): collateral tokens represent real, approved assets.
 *     PAXG = 1 troy oz physical gold (Paxos). XAUT = Tether Gold (physical).
 *   - No rehypothecation: funds are never lent, staked, or yield-farmed.
 *     This avoids riba on reserves.
 *   - 24-hour withdrawal cooldown: protects against flash manipulation.
 *
 * Accepted collateral (Arbitrum One):
 *   USDC  = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
 *   PAXG  = 0xfEb4DfC8C4Cf7Ed305bb08065D08eC6ee6728429
 *   XAUT  = 0xf9b276a1a05934ccD953861E8E59c6Bc428c8cbD
 */
contract CollateralVault is ICollateralVault, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 public constant WITHDRAWAL_COOLDOWN = 24 hours;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    IShariahGuard public immutable shariahGuard;

    /// @notice Authorised callers (PositionManager, LiquidationEngine)
    mapping(address => bool) public authorised;

    /// @notice user → token → free balance (not locked by any position)
    mapping(address => mapping(address => uint256)) private _freeBalance;

    /// @notice user → token → locked balance (held against open positions)
    mapping(address => mapping(address => uint256)) private _lockedBalance;

    /// @notice user → token → timestamp of last deposit (for withdrawal cooldown)
    mapping(address => mapping(address => uint256)) private _lastDeposit;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event CollateralLocked(address indexed user, address indexed token, uint256 amount);
    event CollateralUnlocked(address indexed user, address indexed token, uint256 amount);
    event CollateralTransferred(address indexed from, address indexed to, address indexed token, uint256 amount);
    event AuthorisedSet(address indexed caller, bool status);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner, address _shariahGuard) Ownable(initialOwner) {
        require(_shariahGuard != address(0), "CollateralVault: zero ShariahGuard");
        shariahGuard = IShariahGuard(_shariahGuard);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        authorised[caller] = status;
        emit AuthorisedSet(caller, status);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────
    // User-facing
    // ─────────────────────────────────────────────────────

    /**
     * @notice Deposit Shariah-approved collateral.
     * @param token  Must be approved by ShariahGuard.
     * @param amount Amount to deposit (in token's native decimals).
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(shariahGuard.isApproved(token), "CollateralVault: token not Shariah-approved");
        require(amount > 0, "CollateralVault: zero amount");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _freeBalance[msg.sender][token] += amount;
        _lastDeposit[msg.sender][token]  = block.timestamp;

        emit Deposited(msg.sender, token, amount);
    }

    /**
     * @notice Withdraw free (unlocked) collateral.
     *         Subject to 24-hour cooldown from last deposit.
     *         Cooldown is bypassed if the protocol is paused (emergency exit).
     */
    function withdraw(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "CollateralVault: zero amount");
        require(_freeBalance[msg.sender][token] >= amount, "CollateralVault: insufficient free balance");

        // Enforce cooldown unless protocol is paused (emergency exit)
        if (!paused()) {
            require(
                block.timestamp >= _lastDeposit[msg.sender][token] + WITHDRAWAL_COOLDOWN,
                "CollateralVault: withdrawal cooldown active"
            );
        }

        _freeBalance[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount);
    }

    // ─────────────────────────────────────────────────────
    // ICollateralVault — called by PositionManager / LiquidationEngine
    // ─────────────────────────────────────────────────────

    /**
     * @notice Move funds from user's free balance to locked balance.
     *         Called when opening a position.
     */
    function lockCollateral(address user, address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(authorised[msg.sender],          "CollateralVault: not authorised");
        require(_freeBalance[user][token] >= amount, "CollateralVault: insufficient free balance");

        _freeBalance[user][token]   -= amount;
        _lockedBalance[user][token] += amount;

        emit CollateralLocked(user, token, amount);
    }

    /**
     * @notice Move funds from locked balance back to free balance.
     *         Called when closing or liquidating a position.
     */
    function unlockCollateral(address user, address token, uint256 amount)
        external
        override
        nonReentrant
    {
        require(authorised[msg.sender],               "CollateralVault: not authorised");
        require(_lockedBalance[user][token] >= amount, "CollateralVault: insufficient locked balance");

        _lockedBalance[user][token] -= amount;
        _freeBalance[user][token]   += amount;

        emit CollateralUnlocked(user, token, amount);
    }

    /**
     * @notice Transfer locked collateral from one user to another.
     *         Used in liquidation: loser's collateral → liquidator's free balance.
     */
    function transferCollateral(address from, address to, address token, uint256 amount)
        external
        override
        nonReentrant
    {
        require(authorised[msg.sender],                  "CollateralVault: not authorised");
        require(_lockedBalance[from][token] >= amount,   "CollateralVault: insufficient locked balance");

        _lockedBalance[from][token] -= amount;
        _freeBalance[to][token]     += amount;

        emit CollateralTransferred(from, to, token, amount);
    }

    /**
     * @notice Deduct `amount` from `from`'s FREE balance and send ERC-20 tokens to caller.
     *         Used by PositionManager to collect trading fees directly as tokens,
     *         which are then routed to InsuranceFund and treasury.
     *
     * @param from   The user whose free balance is charged.
     * @param token  The collateral token.
     * @param amount Fee amount to deduct (in token's native decimals).
     */
    function chargeFromFree(address from, address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(authorised[msg.sender],                "CollateralVault: not authorised");
        require(_freeBalance[from][token] >= amount,   "CollateralVault: insufficient free balance");

        _freeBalance[from][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit CollateralTransferred(from, msg.sender, token, amount);
    }

    // ─────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────

    function balance(address user, address token) external view override returns (uint256) {
        return _freeBalance[user][token] + _lockedBalance[user][token];
    }

    function freeBalance(address user, address token) external view returns (uint256) {
        return _freeBalance[user][token];
    }

    function lockedBalance(address user, address token) external view returns (uint256) {
        return _lockedBalance[user][token];
    }
}
