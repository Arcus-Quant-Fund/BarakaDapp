// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IVault.sol";

/**
 * @title Vault
 * @author Baraka Protocol v2
 * @notice Central collateral custodian. All ERC-20 tokens flow through here.
 *         No rehypothecation — idle capital stays in contract (Shariah requirement).
 *
 *         Subaccount balances are tracked internally. The Vault holds the actual tokens.
 *         Only authorised contracts (MarginEngine, MatchingEngine, LiquidationEngine)
 *         can call settlement functions.
 */
contract Vault is IVault, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice subaccount → token → balance
    mapping(bytes32 => mapping(address => uint256)) private _balances;

    /// @notice Approved collateral tokens
    mapping(address => bool) public approvedTokens;

    /// @notice Authorised callers (MarginEngine, MatchingEngine, etc.)
    mapping(address => bool) public authorised;

    /// @notice Guardian — can revoke authorised callers but cannot grant (from v1 CV-M-4)
    address public guardian;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event Deposited(bytes32 indexed subaccount, address indexed token, uint256 amount);
    event Withdrawn(bytes32 indexed subaccount, address indexed token, uint256 amount, address indexed to);
    event InternalTransfer(bytes32 indexed from, bytes32 indexed to, address indexed token, uint256 amount);
    event PnLSettled(bytes32 indexed subaccount, address indexed token, int256 amount);
    event FeeCharged(bytes32 indexed subaccount, address indexed token, uint256 amount, address indexed recipient);
    event AuthorisedSet(address indexed caller, bool status);
    event GuardianSet(address indexed guardian);
    event TokenApproved(address indexed token, bool approved);

    // ─────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────

    modifier onlyAuthorised() {
        require(authorised[msg.sender], "Vault: not authorised");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "Vault: zero address");
        authorised[caller] = status;
        emit AuthorisedSet(caller, status);
    }

    /// AUDIT FIX (L0-M-3): Prevent setting guardian to zero — disables emergency revocation
    /// AUDIT FIX (P5-M-18): Prevent setting guardian to owner — defeats independent safety net.
    function setGuardian(address _guardian) external onlyOwner {
        require(_guardian != address(0), "Vault: zero guardian");
        require(_guardian != owner(), "Vault: guardian must differ from owner");
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    /// @notice Guardian can only revoke, never grant — independent emergency path
    function emergencyRevokeAuthorised(address caller) external {
        require(msg.sender == guardian, "Vault: not guardian");
        authorised[caller] = false;
        emit AuthorisedSet(caller, false);
    }

    function setApprovedToken(address token, bool approved) external onlyOwner {
        require(token != address(0), "Vault: zero token");
        approvedTokens[token] = approved;
        emit TokenApproved(token, approved);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────
    // Deposit / Withdraw (user-facing)
    // ─────────────────────────────────────────────────────

    /// @notice Deposit collateral into a subaccount. Caller must own the subaccount
    ///         (ownership verified by SubaccountManager, called by MarginEngine).
    ///         For direct deposits, the authorised MarginEngine calls this.
    function deposit(bytes32 subaccount, address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(authorised[msg.sender], "Vault: not authorised");
        require(approvedTokens[token], "Vault: token not approved");
        require(amount > 0, "Vault: zero amount");

        /// AUDIT FIX (L0-M-4): Check allowance before transfer for descriptive error
        require(IERC20(token).allowance(msg.sender, address(this)) >= amount, "Vault: insufficient allowance");
        // AUDIT FIX (L0-M-1): Fee-on-transfer check — verify actual received amount
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        require(received == amount, "Vault: fee-on-transfer not supported");

        _balances[subaccount][token] += amount;

        emit Deposited(subaccount, token, amount);
    }

    /// @notice Withdraw collateral from a subaccount to an external address.
    ///         Only authorised (MarginEngine checks free collateral before calling).
    function withdraw(bytes32 subaccount, address token, uint256 amount, address to)
        external
        override
        nonReentrant
        whenNotPaused
        onlyAuthorised
    {
        require(amount > 0, "Vault: zero amount");
        require(to != address(0), "Vault: zero recipient");
        require(_balances[subaccount][token] >= amount, "Vault: insufficient balance");

        _balances[subaccount][token] -= amount;
        IERC20(token).safeTransfer(to, amount);

        emit Withdrawn(subaccount, token, amount, to);
    }

    // ─────────────────────────────────────────────────────
    // Internal transfers (between subaccounts of same owner)
    // ─────────────────────────────────────────────────────

    function transferInternal(bytes32 from, bytes32 to, address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        onlyAuthorised
    {
        require(amount > 0, "Vault: zero amount");
        require(_balances[from][token] >= amount, "Vault: insufficient balance");

        _balances[from][token] -= amount;
        _balances[to][token] += amount;

        emit InternalTransfer(from, to, token, amount);
    }

    // ─────────────────────────────────────────────────────
    // Settlement (called by MatchingEngine / LiquidationEngine)
    // ─────────────────────────────────────────────────────

    /// @notice Settle PnL for a subaccount. Positive = credit, negative = debit.
    ///         Used by MatchingEngine after fills and by LiquidationEngine.
    ///         Returns actual settled amount (may differ from requested on shortfall).
    ///
    ///         AUDIT FIX (L0-H-1): Debit caps at available balance but returns actual
    ///         amount so callers can detect shortfall instead of silent loss.
    ///         AUDIT FIX (L0-H-2): Credits are tracked; callers must ensure backing.
    /// AUDIT FIX (P2-HIGH-4): Removed whenNotPaused — settlePnL must work during pause so
    /// liquidation cascade (LiquidationEngine → MarginEngine.updatePosition → settlePnL) is
    /// never blocked. Funding settlement also relies on this path. Trading (deposit/withdraw)
    /// remains paused; only internal accounting is allowed.
    function settlePnL(bytes32 subaccount, address token, int256 amount)
        external
        override
        nonReentrant
        onlyAuthorised
        returns (int256 actualSettled)
    {
        if (amount > 0) {
            _balances[subaccount][token] += uint256(amount);
            actualSettled = amount;
        } else if (amount < 0) {
            uint256 debit = uint256(-amount);
            uint256 bal = _balances[subaccount][token];
            // Cap debit at available balance — caller must check return for shortfall
            if (debit > bal) {
                debit = bal;
            }
            _balances[subaccount][token] -= debit;
            actualSettled = -int256(debit);
        }

        emit PnLSettled(subaccount, token, actualSettled);
    }

    /// @notice Charge a fee from subaccount and send to recipient (treasury, insurance, etc.)
    /// AUDIT FIX (L0-M-2): Cap fee at available balance to prevent revert in liquidation flows.
    /// Returns actual amount charged (may be less than requested if subaccount underfunded).
    /// AUDIT FIX (P3-LIQ-9): Removed whenNotPaused — chargeFee() is called three times during
    /// liquidation (liquidator reward, insurance share, residual sweep). Vault pause must not
    /// block the liquidation penalty path; same rationale as settlePnL() (P2-HIGH-4).
    function chargeFee(bytes32 subaccount, address token, uint256 amount, address recipient)
        external
        override
        nonReentrant
        onlyAuthorised
        returns (uint256 charged)
    {
        require(amount > 0, "Vault: zero fee");
        require(recipient != address(0), "Vault: zero recipient");

        uint256 bal = _balances[subaccount][token];
        charged = amount > bal ? bal : amount;
        if (charged == 0) return 0;

        _balances[subaccount][token] -= charged;
        IERC20(token).safeTransfer(recipient, charged);

        emit FeeCharged(subaccount, token, charged, recipient);
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    function balance(bytes32 subaccount, address token) external view override returns (uint256) {
        return _balances[subaccount][token];
    }

    // ─────────────────────────────────────────────────────
    // INFO fixes
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P2-HIGH-8): Renouncing ownership on Vault bricks all admin ops permanently.
    function renounceOwnership() public view override onlyOwner {
        revert("Vault: renounce disabled");
    }

    /// AUDIT FIX (L0-I-4): Reject accidental ETH sends — Vault handles only ERC-20
    receive() external payable {
        revert("Vault: no ETH");
    }

    /// @dev INFO (L0-I-1): deposit follows CEI — state updated after transfer check (by design).
    /// @dev INFO (L0-I-2): PnLSettled event emits actualSettled, not requested amount (implemented).
    /// @dev INFO (L0-I-7): int256 casts are bounded by uint256 balance (safe for real-world amounts).
    /// @dev INFO (L0-I-8): Custom errors deferred — require strings preferred for readability during audit.
    /// @dev INFO (L0-I-9): Deposit uses safeTransferFrom (approval required beforehand by design).
    /// @dev INFO (L0-I-10): Pragma ^0.8.24 is intentional — allows patch upgrades within 0.8.x.
}
