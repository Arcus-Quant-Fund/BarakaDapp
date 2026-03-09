// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IInsuranceFund.sol";

/**
 * @title InsuranceFund
 * @author Baraka Protocol v2
 * @notice Socialises rare shortfall losses when liquidations are insufficient.
 *
 *         Islamic finance basis (Tabarru / Kafala):
 *           - Each trader implicitly contributes via liquidation penalties and fee share.
 *           - NO yield is generated on idle capital (avoids riba on reserves).
 *           - Surplus distribution governed by Shariah board (EWMA weekly claims floor).
 *
 *         Enhanced from v1 with:
 *           - EWMA decay on weekly claims (no cliff reset exploit)
 *           - 24h cooldown after weekly reset before surplus distribution
 *           - 20% minimum reserve floor (absolute)
 *           - Approved surplus recipient whitelist
 *           - 7-day cooldown between distributions per token
 *
 * @dev Sources:
 *      AAOIFI Shariah Standard No. 26 (Islamic Insurance)
 *      El-Gamal (2006), "Islamic Finance: Law, Economics, and Practice"
 */
contract InsuranceFund is IInsuranceFund, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 public constant MIN_RESERVE_BPS = 2000; // 20% minimum reserve
    uint256 public constant DISTRIBUTION_COOLDOWN = 24 hours;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    mapping(address => bool) public authorised;
    mapping(address => bool) public approvedSurplusRecipients;
    mapping(address => uint256) private _fundBalance;
    mapping(address => uint256) public lastDistribution;
    mapping(address => uint256) public weeklyClaimsSum;
    mapping(address => uint256) public lastClaimReset;

    /// @notice P9-H-1: Epochal drawdown rate limit (prevents single-block fund drainage)
    uint256 public maxDrawdownPerEpoch;     // max tokens drainable per epoch (0 = unlimited)
    uint256 public epochDuration = 1 hours; // epoch length
    mapping(address => uint256) public epochDrawdownUsed;  // token -> amount drawn this epoch
    mapping(address => uint256) public epochStart;         // token -> epoch start timestamp

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event FundReceived(address indexed token, uint256 amount, address indexed from);
    event ShortfallCovered(address indexed token, uint256 amount, address indexed beneficiary);
    event PnlPaid(address indexed token, uint256 amount, address indexed recipient);
    event PnlUnderpaid(address indexed token, uint256 requested, uint256 paid, address indexed recipient);
    event SurplusDistributed(address indexed token, uint256 amount, address indexed recipient);
    event AuthorisedSet(address indexed caller, bool status);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "IF: zero address");
        authorised[caller] = status;
        emit AuthorisedSet(caller, status);
    }

    function setSurplusRecipient(address recipient, bool approved) external onlyOwner {
        require(recipient != address(0), "IF: zero recipient");
        approvedSurplusRecipients[recipient] = approved;
    }

    function recoverToken(address token, address to) external onlyOwner {
        require(to != address(0), "IF: zero to");
        uint256 actual = IERC20(token).balanceOf(address(this));
        uint256 tracked = _fundBalance[token];
        uint256 excess = actual > tracked ? actual - tracked : 0;
        require(excess > 0, "IF: nothing to recover");
        IERC20(token).safeTransfer(to, excess);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P2-HIGH-8): Prevent ownership renouncement — InsuranceFund requires owner for governance.
    function renounceOwnership() public view override onlyOwner {
        revert("IF: renounce disabled");
    }

    /// @notice P9-H-1: Set maximum insurance fund drawdown per epoch.
    /// @param _maxDrawdown Maximum tokens drainable per epoch (0 = unlimited).
    /// @param _epochDuration Epoch length in seconds (minimum 10 minutes).
    function setDrawdownLimit(uint256 _maxDrawdown, uint256 _epochDuration) external onlyOwner {
        require(_epochDuration >= 10 minutes, "IF: epoch too short");
        maxDrawdownPerEpoch = _maxDrawdown;
        epochDuration = _epochDuration;
    }

    // ─────────────────────────────────────────────────────
    // IInsuranceFund
    // ─────────────────────────────────────────────────────

    /// @notice Receive funds from liquidation penalties, fee share, etc.
    /// AUDIT FIX (P5-M-17): Removed whenNotPaused — fund must be replenishable during pause.
    /// coverShortfall() already lacks whenNotPaused (P3-LIQ-5). Without this fix, the fund
    /// can only decrease during pause (drainable but not replenishable).
    function receive_(address token, uint256 amount)
        external
        override
        nonReentrant
    {
        require(authorised[msg.sender], "IF: not authorised");
        require(amount > 0, "IF: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _fundBalance[token] += amount;
        emit FundReceived(token, amount, msg.sender);
    }

    /// @notice Cover a shortfall from an underwater liquidation.
    /// AUDIT FIX (P3-LIQ-5): Removed whenNotPaused — LiquidationEngine wraps this in try/catch
    /// and silently falls through to ADL on any revert including pause. IF pause must not trigger
    /// unnecessary ADL against profitable counterparties. Same pattern as P2-CRIT-3 / P2-HIGH-4.
    /// AUDIT FIX (P6-H-1): Use actual token balance instead of tracked _fundBalance.
    /// vault.chargeFee() sends liquidation penalties directly via ERC-20 transfer without
    /// calling receive_(), so _fundBalance understates reality. Without this fix,
    /// LiquidationEngine reads fundBalance() (actual=high), tries coverShortfall(amount),
    /// but the _fundBalance check reverts → unnecessary ADL against profitable counterparties.
    function coverShortfall(address token, uint256 amount)
        external
        override
        nonReentrant
    {
        require(authorised[msg.sender], "IF: not authorised");
        require(amount > 0, "IF: zero amount");
        uint256 actual = IERC20(token).balanceOf(address(this));
        require(actual >= amount, "IF: insufficient reserves");

        /// AUDIT FIX (P9-H-1): Enforce epochal drawdown limit
        _checkDrawdownLimit(token, amount);

        _updateWeeklyClaims(token, amount);
        IERC20(token).safeTransfer(msg.sender, amount);
        // Sync tracked balance to actual after transfer
        _fundBalance[token] = IERC20(token).balanceOf(address(this));
        emit ShortfallCovered(token, amount, msg.sender);
    }

    /// @notice Pay PnL profit. Caps at available balance (never reverts on undercapitalization).
    /// AUDIT FIX (P6-H-1): Use actual token balance — same desync issue as coverShortfall.
    function payPnl(address token, uint256 amount, address recipient)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(authorised[msg.sender], "IF: not authorised");
        require(amount > 0, "IF: zero amount");
        require(recipient != address(0), "IF: zero recipient");

        uint256 available = IERC20(token).balanceOf(address(this));
        uint256 payout = amount > available ? available : amount;
        if (payout == 0) return;

        _updateWeeklyClaims(token, payout);
        IERC20(token).safeTransfer(recipient, payout);
        // Sync tracked balance to actual after transfer
        _fundBalance[token] = IERC20(token).balanceOf(address(this));

        emit PnlPaid(token, payout, recipient);
        if (payout < amount) {
            emit PnlUnderpaid(token, amount, payout, recipient);
        }
    }

    /// AUDIT FIX (P5-M-5): Use actual token balance instead of tracked _fundBalance.
    /// vault.chargeFee() sends tokens directly via ERC-20 transfer without calling receive_(),
    /// so _fundBalance[token] understates actual holdings. Using balanceOf() prevents
    /// unnecessary ADL triggers when the fund actually has sufficient tokens.
    function fundBalance(address token) external view override returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ─────────────────────────────────────────────────────
    // Surplus distribution (Shariah board governed)
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P6-H-1): Use actual token balance — same desync issue as coverShortfall/payPnl.
    function distributeSurplus(address token, address recipient) external onlyOwner nonReentrant whenNotPaused {
        require(approvedSurplusRecipients[recipient], "IF: recipient not approved");

        // 24h cooldown after weekly reset
        require(
            lastClaimReset[token] == 0 ||
            block.timestamp >= lastClaimReset[token] + DISTRIBUTION_COOLDOWN,
            "IF: cooldown after weekly reset"
        );

        // 7-day cooldown between distributions
        require(
            lastDistribution[token] == 0 || block.timestamp >= lastDistribution[token] + 7 days,
            "IF: distribution cooldown"
        );

        uint256 balance_ = IERC20(token).balanceOf(address(this));
        uint256 avgWeekly = weeklyClaimsSum[token];

        // Floor = max(2× weekly claims, 20% of balance)
        /// @dev INFO (L3-I-1): Reserve floor uses claims-based and percentage-based minimum.
        ///      This is intentional — dual-floor ensures adequate reserves under all conditions.
        uint256 claimsFloor = 2 * avgWeekly;
        /// AUDIT FIX (P2-MEDIUM-12): Ceiling division — floor should round UP to protect reserves.
        /// Round-down was distributing 1 token more than the 20% minimum on odd balances.
        uint256 reserveFloor = (balance_ * MIN_RESERVE_BPS + 9_999) / 10_000;
        uint256 floor = claimsFloor > reserveFloor ? claimsFloor : reserveFloor;

        require(balance_ > floor, "IF: no surplus");

        uint256 surplus = balance_ - floor;
        lastDistribution[token] = block.timestamp;

        IERC20(token).safeTransfer(recipient, surplus);
        // Sync tracked balance to actual after transfer
        _fundBalance[token] = IERC20(token).balanceOf(address(this));
        emit SurplusDistributed(token, surplus, recipient);
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (L3-M-9): Apply decay for each elapsed period, not just once
    function _updateWeeklyClaims(address token, uint256 amount) internal {
        uint256 lastReset = lastClaimReset[token];
        if (lastReset > 0 && block.timestamp >= lastReset + 7 days) {
            uint256 periodsPassed = (block.timestamp - lastReset) / 7 days;
            uint256 claims = weeklyClaimsSum[token];
            // Apply halving for each elapsed period (capped at 10 to prevent gas waste)
            uint256 decays = periodsPassed > 10 ? 10 : periodsPassed;
            for (uint256 i = 0; i < decays; i++) {
                claims = claims / 2;
            }
            weeklyClaimsSum[token] = claims;
            lastClaimReset[token] = block.timestamp;
        } else if (lastReset == 0) {
            lastClaimReset[token] = block.timestamp;
        }
        weeklyClaimsSum[token] += amount;
    }

    /// @notice P9-H-1: Check and update epochal drawdown tracking.
    /// Prevents single-block insurance fund drainage (real-world: Hyperliquid JELLY exploit pattern).
    function _checkDrawdownLimit(address token, uint256 amount) internal {
        if (maxDrawdownPerEpoch == 0) return; // rate limiting disabled
        uint256 currentEpochStart = epochStart[token];
        if (currentEpochStart == 0) {
            epochStart[token] = block.timestamp;
            epochDrawdownUsed[token] = amount;
        } else if (block.timestamp >= currentEpochStart + epochDuration) {
            /// AUDIT FIX (P10-M-4): Advance epoch by epochDuration rather than resetting to block.timestamp.
            /// AUDIT FIX (P12-IF-1): Advance directly to the CURRENT epoch boundary (not just one ahead).
            /// Without this, if the fund is dormant for N epochs, the first N consecutive coverShortfall
            /// calls each advance one epoch and drain maxDrawdownPerEpoch per call — N × drawdown in one block.
            /// Computing epochsElapsed jumps the epoch anchor to the correct current boundary in one step.
            uint256 epochsElapsed = (block.timestamp - currentEpochStart) / epochDuration;
            epochStart[token] = currentEpochStart + epochsElapsed * epochDuration;
            epochDrawdownUsed[token] = amount;
        } else {
            epochDrawdownUsed[token] += amount;
        }
        require(epochDrawdownUsed[token] <= maxDrawdownPerEpoch, "IF: epoch drawdown limit exceeded");
    }
}
