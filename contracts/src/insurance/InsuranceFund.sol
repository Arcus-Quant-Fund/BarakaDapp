// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IInsuranceFund.sol";

/**
 * @title InsuranceFund
 * @author Baraka Protocol
 * @notice Socialises rare shortfall losses when liquidations are insufficient.
 *
 * Islamic finance basis:
 *   This fund operates on the principle of Tabarru (voluntary contribution).
 *   Each trader implicitly contributes by accepting the protocol's liquidation
 *   mechanics. In the event of a shortfall, the fund covers the gap — a form
 *   of mutual guarantee (Kafala) rather than interest-bearing debt.
 *
 *   NO yield is generated on idle capital. Funds are held as cash reserves only.
 *   This avoids riba on reserves.
 *
 * @dev This is the SEED of Layer 3: Takaful Protocol.
 *      As the fund matures, it will evolve into a fully-fledged mutual insurance
 *      pool (Takaful) with Shariah-compliant surplus distribution and re-Takaful.
 *
 * Sources:
 *   - AAOIFI Shariah Standard No. 26 (Islamic Insurance)
 *   - El-Gamal (2006), "Islamic Finance: Law, Economics, and Practice"
 */
contract InsuranceFund is IInsuranceFund, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice Authorised callers (LiquidationEngine, PositionManager)
    mapping(address => bool) public authorised;

    /// @notice Token balances held by the fund
    mapping(address => uint256) private _fundBalance;

    /// @notice Weekly average claims tracker (simple 7-day rolling sum)
    mapping(address => uint256) public weeklyClaimsSum;
    mapping(address => uint256) public lastClaimReset;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event FundReceived(address indexed token, uint256 amount, address indexed from);
    event ShortfallCovered(address indexed token, uint256 amount, address indexed beneficiary);
    event SurplusDistributed(address indexed token, uint256 amount);
    event AuthorisedSet(address indexed caller, bool status);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

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
    // IInsuranceFund
    // ─────────────────────────────────────────────────────

    /**
     * @notice Receive funds from liquidation penalties (50% share).
     *         Also receives 10% of protocol trading fees.
     *         NO yield is generated on these funds — they sit as cash reserves.
     */
    function receiveFromLiquidation(address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(authorised[msg.sender], "InsuranceFund: not authorised");
        require(amount > 0, "InsuranceFund: zero amount");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _fundBalance[token] += amount;
        emit FundReceived(token, amount, msg.sender);
    }

    /**
     * @notice Cover a shortfall when a liquidation is insufficient.
     *         Called by PositionManager when the liquidated collateral < position loss.
     *
     * @param token       The collateral token.
     * @param amount      The shortfall amount to cover.
     */
    function coverShortfall(address token, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
    {
        require(authorised[msg.sender], "InsuranceFund: not authorised");
        require(amount > 0, "InsuranceFund: zero amount");
        require(_fundBalance[token] >= amount, "InsuranceFund: insufficient reserves");

        _fundBalance[token] -= amount;

        // Track weekly claims for surplus distribution logic
        _updateWeeklyClaims(token, amount);

        IERC20(token).safeTransfer(msg.sender, amount);
        emit ShortfallCovered(token, amount, msg.sender);
    }

    /**
     * @notice Returns the current fund balance for a token.
     */
    function fundBalance(address token) external view override returns (uint256) {
        return _fundBalance[token];
    }

    // ─────────────────────────────────────────────────────
    // Surplus distribution
    // ─────────────────────────────────────────────────────

    /**
     * @notice Distribute surplus to a designated recipient (e.g. Takaful pool).
     *         Only distributes if fund > 2x the weekly average claims.
     *         Governed by Shariah board approval (owner = Shariah-governed multisig).
     *
     * @param token     Token to distribute.
     * @param recipient Address to receive the surplus.
     */
    function distributeSurplus(address token, address recipient)
        external
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        uint256 balance = _fundBalance[token];
        uint256 avgWeekly = weeklyClaimsSum[token]; // simplified: 1-week rolling sum

        require(balance > 2 * avgWeekly, "InsuranceFund: no surplus to distribute");

        uint256 surplus = balance - 2 * avgWeekly;
        _fundBalance[token] -= surplus;

        IERC20(token).safeTransfer(recipient, surplus);
        emit SurplusDistributed(token, surplus);
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    function _updateWeeklyClaims(address token, uint256 amount) internal {
        // Reset weekly counter every 7 days
        if (block.timestamp >= lastClaimReset[token] + 7 days) {
            weeklyClaimsSum[token] = 0;
            lastClaimReset[token]  = block.timestamp;
        }
        weeklyClaimsSum[token] += amount;
    }
}
