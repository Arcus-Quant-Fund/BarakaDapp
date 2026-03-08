// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IMarginEngine.sol";
import "../interfaces/IVault.sol";
import "../interfaces/ISubaccountManager.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IFundingEngine.sol";

/**
 * @title MarginEngine
 * @author Baraka Protocol v2
 * @notice Cross-margin account management (dYdX v4's key innovation).
 *
 *         All positions in a subaccount share collateral. Equity is computed as:
 *           equity = collateral_balance + Σ(unrealized_pnl) - Σ(pending_funding)
 *
 *         Margin requirements:
 *           IMR = Σ(|position_size| × oracle_price × market.initialMarginRate)
 *           MMR = Σ(|position_size| × oracle_price × market.maintenanceMarginRate)
 *
 *         Free collateral = equity - IMR  (must be >= 0 to open new positions)
 *         Liquidatable = equity < MMR
 */
contract MarginEngine is IMarginEngine, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;

    /// @notice Collateral token for margin (single-collateral for simplicity; v2.1 can add multi-collateral)
    address public immutable collateralToken;

    /// @notice Scale factor to convert token amount → WAD (e.g. 1e12 for 6-decimal USDC → 1e18)
    uint256 public immutable collateralScale;

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    IVault              public immutable vault;
    ISubaccountManager  public immutable subaccountManager;
    IOracleAdapter      public immutable oracle;
    IFundingEngine      public immutable fundingEngine;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice Market parameters: marketId → params
    mapping(bytes32 => MarketParams) private _marketParams;

    /// @notice Positions: subaccount → marketId → Position
    mapping(bytes32 => mapping(bytes32 => Position)) private _positions;

    /// @notice List of markets a subaccount has positions in (for iteration)
    mapping(bytes32 => bytes32[]) private _subaccountMarkets;

    /// @notice Track if subaccount has a position in a market (avoid duplicates in array)
    mapping(bytes32 => mapping(bytes32 => bool)) private _hasPosition;

    /// @notice Authorised callers (MatchingEngine, LiquidationEngine)
    mapping(address => bool) public authorised;

    /// @notice All registered market IDs (for enumeration)
    bytes32[] public markets;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event MarketCreated(bytes32 indexed marketId, uint256 imr, uint256 mmr, uint256 maxPositionSize);
    event MarketUpdated(bytes32 indexed marketId, uint256 imr, uint256 mmr);
    event PositionUpdated(bytes32 indexed subaccount, bytes32 indexed marketId, int256 newSize, uint256 entryPrice);
    event AuthorisedSet(address indexed caller, bool status);

    // ─────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────

    modifier onlyAuthorised() {
        require(authorised[msg.sender], "ME: not authorised");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _vault,
        address _subaccountManager,
        address _oracle,
        address _fundingEngine,
        address _collateralToken
    ) Ownable(initialOwner) {
        require(_vault != address(0), "ME: zero vault");
        require(_subaccountManager != address(0), "ME: zero SAM");
        require(_oracle != address(0), "ME: zero oracle");
        require(_fundingEngine != address(0), "ME: zero funding");
        require(_collateralToken != address(0), "ME: zero collateral");

        vault = IVault(_vault);
        subaccountManager = ISubaccountManager(_subaccountManager);
        oracle = IOracleAdapter(_oracle);
        fundingEngine = IFundingEngine(_fundingEngine);
        collateralToken = _collateralToken;

        // Compute scale factor: 10^(18 - tokenDecimals)
        // e.g. USDC (6 dec) → scale = 1e12, so 50_000e6 * 1e12 = 50_000e18
        uint8 dec = _getDecimals(_collateralToken);
        collateralScale = 10 ** (18 - dec);
    }

    function _getDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, "ME: no decimals");
        return abi.decode(data, (uint8));
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "ME: zero address");
        authorised[caller] = status;
        emit AuthorisedSet(caller, status);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Create a new perpetual market.
    function createMarket(
        bytes32 marketId,
        uint256 initialMarginRate,
        uint256 maintenanceMarginRate,
        uint256 maxPositionSize
    ) external onlyOwner {
        require(!_marketParams[marketId].active, "ME: market exists");
        require(initialMarginRate > maintenanceMarginRate, "ME: IMR <= MMR");
        require(maintenanceMarginRate > 0, "ME: zero MMR");
        require(initialMarginRate <= WAD, "ME: IMR > 100%");
        require(maxPositionSize > 0, "ME: zero max size");

        _marketParams[marketId] = MarketParams({
            initialMarginRate:     initialMarginRate,
            maintenanceMarginRate: maintenanceMarginRate,
            maxPositionSize:       maxPositionSize,
            active:                true
        });
        markets.push(marketId);

        emit MarketCreated(marketId, initialMarginRate, maintenanceMarginRate, maxPositionSize);
    }

    /// @notice Update market margin parameters.
    function updateMarket(bytes32 marketId, uint256 imr, uint256 mmr) external onlyOwner {
        require(_marketParams[marketId].active, "ME: market not active");
        require(imr > mmr, "ME: IMR <= MMR");
        require(mmr > 0, "ME: zero MMR");

        _marketParams[marketId].initialMarginRate = imr;
        _marketParams[marketId].maintenanceMarginRate = mmr;

        emit MarketUpdated(marketId, imr, mmr);
    }

    // ─────────────────────────────────────────────────────
    // Deposit / Withdraw (user-facing, routed through Vault)
    // ─────────────────────────────────────────────────────

    /// @notice Deposit collateral into a subaccount.
    function deposit(bytes32 subaccount, uint256 amount) external nonReentrant whenNotPaused {
        require(subaccountManager.getOwner(subaccount) == msg.sender, "ME: not owner");
        /// AUDIT FIX (P7-L-2): Enforce subaccount existence — closed subaccounts cannot receive deposits.
        require(subaccountManager.exists(subaccount), "ME: subaccount closed");
        require(amount > 0, "ME: zero amount");

        // Transfer tokens from user to this contract, then deposit into vault
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(collateralToken).forceApprove(address(vault), amount);
        vault.deposit(subaccount, collateralToken, amount);
    }

    /// @notice Withdraw collateral from a subaccount (if free collateral allows).
    function withdraw(bytes32 subaccount, uint256 amount) external nonReentrant whenNotPaused {
        require(subaccountManager.getOwner(subaccount) == msg.sender, "ME: not owner");
        require(amount > 0, "ME: zero amount");

        // Check free collateral allows withdrawal (normalize amount to WAD)
        int256 freeCol = _computeFreeCollateral(subaccount);
        require(freeCol >= int256(amount * collateralScale), "ME: insufficient free collateral");

        vault.withdraw(subaccount, collateralToken, amount, msg.sender);
    }

    /// @notice Transfer collateral between own subaccounts.
    function transferBetweenSubaccounts(bytes32 from, bytes32 to, uint256 amount) external nonReentrant whenNotPaused {
        require(subaccountManager.getOwner(from) == msg.sender, "ME: not owner of source");
        require(subaccountManager.getOwner(to) == msg.sender, "ME: not owner of dest");
        require(amount > 0, "ME: zero amount");

        // Check source has sufficient free collateral (normalize to WAD)
        int256 freeCol = _computeFreeCollateral(from);
        require(freeCol >= int256(amount * collateralScale), "ME: insufficient free collateral");

        vault.transferInternal(from, to, collateralToken, amount);
    }

    // ─────────────────────────────────────────────────────
    // Position updates (called by MatchingEngine after fills)
    // ─────────────────────────────────────────────────────

    /// @notice Update a position after a fill. Called by MatchingEngine and LiquidationEngine.
    ///         Handles position increase, decrease, and flip.
    /// AUDIT FIX (P3-LIQ-1): Removed whenNotPaused — LiquidationEngine.liquidate() and
    /// AutoDeleveraging.executeADL() call updatePosition() during the liquidation cascade.
    /// MarginEngine pause must not block liquidations (same rationale as P2-CRIT-3 / P2-HIGH-4).
    function updatePosition(
        bytes32 subaccount,
        bytes32 marketId,
        int256  sizeDelta,   // positive = buy, negative = sell
        uint256 fillPrice
    ) external onlyAuthorised {
        require(_marketParams[marketId].active, "ME: market not active");
        require(sizeDelta != 0, "ME: zero delta");

        Position storage pos = _positions[subaccount][marketId];

        // Track market for this subaccount
        /// AUDIT FIX (P5-M-20): Cap active markets per subaccount to prevent gas DoS on isLiquidatable.
        /// An attacker opening dust positions in 100+ markets makes equity iteration exceed gas limits.
        if (!_hasPosition[subaccount][marketId]) {
            require(_subaccountMarkets[subaccount].length < 20, "ME: max 20 markets per subaccount");
            _hasPosition[subaccount][marketId] = true;
            _subaccountMarkets[subaccount].push(marketId);
        }

        int256 oldSize = pos.size;
        int256 newSize = oldSize + sizeDelta;

        if (oldSize == 0) {
            // New position
            pos.size = newSize;
            pos.entryPrice = fillPrice;
            pos.marketId = marketId;
            pos.entryFundingIndex = fundingEngine.getCumulativeFunding(marketId);
        } else if (_sameSign(oldSize, sizeDelta)) {
            // Increasing position — weighted average entry price
            /// AUDIT FIX (P5-H-13): Settle funding before increasing position.
            /// Previously, entryFundingIndex was not updated on increase, causing the
            /// additional portion to be charged funding from the original entry time.
            /// Example: open 10 at t=0, increase to 20 at t=4h, close at t=8h →
            /// overcharged 33% because added 10 units charged from t=0 not t=4h.
            _settleFundingForPosition(subaccount, marketId);
            /// AUDIT FIX (P2-HIGH-7): Use Math.mulDiv to prevent intermediate overflow and reduce truncation
            uint256 oldNotional = Math.mulDiv(_abs(oldSize), pos.entryPrice, WAD);
            uint256 addNotional = Math.mulDiv(_abs(sizeDelta), fillPrice, WAD);
            pos.entryPrice = Math.mulDiv(oldNotional + addNotional, WAD, _abs(newSize));
            pos.size = newSize;
        } else {
            // Reducing or flipping
            /// AUDIT FIX (P2-CRIT-1): Settle accumulated funding before realizing PnL.
            /// Without this, funding payments since position open are permanently lost on close.
            _settleFundingForPosition(subaccount, marketId);

            if (_abs(sizeDelta) <= _abs(oldSize)) {
                // Partial close — realize PnL, entry price unchanged
                int256 pnl = _computePositionPnl(oldSize, pos.entryPrice, _abs(sizeDelta), fillPrice);
                // Convert WAD PnL to token decimals for vault settlement
                /// AUDIT FIX (P5-H-9): Use protocol-favorable rounding for PnL settlement
                vault.settlePnL(subaccount, collateralToken, _wadToTokens(pnl));
                pos.size = newSize;
                if (newSize == 0) {
                    _cleanupPosition(subaccount, marketId);
                }
            } else {
                // Flip — close entire old position, open new in opposite direction
                int256 closePnl = _computePositionPnl(oldSize, pos.entryPrice, _abs(oldSize), fillPrice);
                /// AUDIT FIX (P5-H-9): Use protocol-favorable rounding for PnL settlement
                vault.settlePnL(subaccount, collateralToken, _wadToTokens(closePnl));
                int256 remaining = newSize; // what's left after closing old
                pos.size = remaining;
                pos.entryPrice = fillPrice;
                pos.entryFundingIndex = fundingEngine.getCumulativeFunding(marketId);
            }
        }

        // Validate margin after update
        if (newSize != 0) {
            // Check position size limit
            uint256 absNotional = _abs(newSize) * oracle.getIndexPrice(marketId) / WAD;
            require(absNotional <= _marketParams[marketId].maxPositionSize, "ME: exceeds max position");

            // If position increased, check initial margin
            if (_abs(newSize) > _abs(oldSize)) {
                int256 freeCol = _computeFreeCollateral(subaccount);
                require(freeCol >= 0, "ME: insufficient margin");
            }
        }

        emit PositionUpdated(subaccount, marketId, newSize, pos.entryPrice);
    }

    // ─────────────────────────────────────────────────────
    // Funding settlement
    // ─────────────────────────────────────────────────────

    /// @notice Settle pending funding for all positions in a subaccount.
    function settleFunding(bytes32 subaccount) external nonReentrant whenNotPaused {
        bytes32[] storage mktList = _subaccountMarkets[subaccount];
        for (uint256 i = 0; i < mktList.length; i++) {
            _settleFundingForPosition(subaccount, mktList[i]);
        }
    }

    function _settleFundingForPosition(bytes32 subaccount, bytes32 marketId) internal {
        Position storage pos = _positions[subaccount][marketId];
        if (pos.size == 0) return;

        int256 currentIndex = fundingEngine.updateFunding(marketId);
        int256 funding = fundingEngine.getPendingFunding(marketId, pos.size, pos.entryFundingIndex);

        if (funding != 0) {
            /// AUDIT FIX (P5-H-9): Use protocol-favorable rounding for funding settlement
            vault.settlePnL(subaccount, collateralToken, _wadToTokens(-funding));
        }

        pos.entryFundingIndex = currentIndex;
    }

    // ─────────────────────────────────────────────────────
    // View — IMarginEngine
    // ─────────────────────────────────────────────────────

    function getEquity(bytes32 subaccount) external view override returns (int256) {
        return _computeEquity(subaccount);
    }

    function getFreeCollateral(bytes32 subaccount) external view override returns (int256) {
        return _computeFreeCollateral(subaccount);
    }

    function getInitialMarginReq(bytes32 subaccount) external view override returns (uint256) {
        return _computeIMR(subaccount);
    }

    function getMaintenanceMarginReq(bytes32 subaccount) external view override returns (uint256) {
        return _computeMMR(subaccount);
    }

    function isLiquidatable(bytes32 subaccount) external view override returns (bool) {
        int256 equity = _computeEquity(subaccount);
        uint256 mmr = _computeMMR(subaccount);
        return equity < int256(mmr);
    }

    function getPosition(bytes32 subaccount, bytes32 marketId) external view override returns (Position memory) {
        return _positions[subaccount][marketId];
    }

    function getMarketParams(bytes32 marketId) external view override returns (MarketParams memory) {
        return _marketParams[marketId];
    }

    function getSubaccountMarkets(bytes32 subaccount) external view returns (bytes32[] memory) {
        return _subaccountMarkets[subaccount];
    }

    // ─────────────────────────────────────────────────────
    // Internal — margin calculations
    // ─────────────────────────────────────────────────────

    function _computeEquity(bytes32 subaccount) internal view returns (int256) {
        uint256 bal = vault.balance(subaccount, collateralToken);
        // Normalize to WAD scale (e.g. 50_000e6 USDC → 50_000e18)
        int256 equity = int256(bal * collateralScale);

        bytes32[] storage mktList = _subaccountMarkets[subaccount];
        for (uint256 i = 0; i < mktList.length; i++) {
            Position storage pos = _positions[subaccount][mktList[i]];
            if (pos.size == 0) continue;

            // Unrealized PnL
            /// AUDIT FIX (P5-H-1): Use last known price instead of skipping stale markets entirely.
            /// Previous fix (P2-HIGH-5) skipped stale markets to prevent revert, but this excluded
            /// unrealized losses from equity, enabling undercollateralized withdrawals.
            /// getIndexPrice() returns the cached lastIndexPrice regardless of staleness.
            /// Staleness is checked at liquidation entry (LiquidationEngine) and new position opening.
            uint256 indexPrice = oracle.getIndexPrice(mktList[i]);
            int256 pnl = (int256(indexPrice) - int256(pos.entryPrice)) * pos.size / int256(WAD);
            equity += pnl;

            // Pending funding
            int256 funding = fundingEngine.getPendingFunding(mktList[i], pos.size, pos.entryFundingIndex);
            equity -= funding; // funding owed reduces equity
        }

        return equity;
    }

    function _computeFreeCollateral(bytes32 subaccount) internal view returns (int256) {
        int256 equity = _computeEquity(subaccount);
        uint256 imr = _computeIMR(subaccount);
        return equity - int256(imr);
    }

    /// AUDIT FIX (L1-M-6): Use Math.mulDiv to reduce precision loss from sequential division
    function _computeIMR(bytes32 subaccount) internal view returns (uint256) {
        uint256 total;
        bytes32[] storage mktList = _subaccountMarkets[subaccount];
        for (uint256 i = 0; i < mktList.length; i++) {
            Position storage pos = _positions[subaccount][mktList[i]];
            if (pos.size == 0) continue;
            uint256 indexPrice = oracle.getIndexPrice(mktList[i]);
            uint256 notional = Math.mulDiv(_abs(pos.size), indexPrice, WAD);
            total += Math.mulDiv(notional, _marketParams[mktList[i]].initialMarginRate, WAD);
        }
        return total;
    }

    /// AUDIT FIX (L1-M-6): Use Math.mulDiv to reduce precision loss from sequential division
    function _computeMMR(bytes32 subaccount) internal view returns (uint256) {
        uint256 total;
        bytes32[] storage mktList = _subaccountMarkets[subaccount];
        for (uint256 i = 0; i < mktList.length; i++) {
            Position storage pos = _positions[subaccount][mktList[i]];
            if (pos.size == 0) continue;
            uint256 indexPrice = oracle.getIndexPrice(mktList[i]);
            uint256 notional = Math.mulDiv(_abs(pos.size), indexPrice, WAD);
            total += Math.mulDiv(notional, _marketParams[mktList[i]].maintenanceMarginRate, WAD);
        }
        return total;
    }

    // ─────────────────────────────────────────────────────
    // Internal — PnL computation
    // ─────────────────────────────────────────────────────

    /// @dev Compute realized PnL for closing `closeSize` of a position.
    function _computePositionPnl(
        int256 posSize,
        uint256 entryPrice,
        uint256 closeSize,
        uint256 exitPrice
    ) internal pure returns (int256) {
        int256 priceDelta = int256(exitPrice) - int256(entryPrice);
        int256 pnl = priceDelta * int256(closeSize) / int256(WAD);
        // Short position: invert PnL
        if (posSize < 0) pnl = -pnl;
        return pnl;
    }

    /// AUDIT FIX (L1-M-5): Remove market from _subaccountMarkets to prevent unbounded growth
    function _cleanupPosition(bytes32 subaccount, bytes32 marketId) internal {
        delete _positions[subaccount][marketId];
        _hasPosition[subaccount][marketId] = false;

        // Remove from _subaccountMarkets array (swap-and-pop)
        bytes32[] storage mktList = _subaccountMarkets[subaccount];
        for (uint256 i = 0; i < mktList.length; i++) {
            if (mktList[i] == marketId) {
                mktList[i] = mktList[mktList.length - 1];
                mktList.pop();
                break;
            }
        }
    }

    /// AUDIT FIX (P2-CRIT-2): Guard against type(int256).min — uint256(-min) overflows silently
    function _abs(int256 x) internal pure returns (uint256) {
        require(x != type(int256).min, "ME: int256 min overflow");
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    /// @notice Override to prevent ownership renouncement — protocol requires an owner for admin ops.
    /// AUDIT FIX (P2-HIGH-8): Renouncing ownership on MarginEngine bricks market creation permanently.
    function renounceOwnership() public view override onlyOwner {
        revert("ME: renounce disabled");
    }

    function _sameSign(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    /// AUDIT FIX (P5-H-9): Protocol-favorable WAD-to-token conversion.
    /// Floor division on negative values rounds toward zero, systematically undercharging users.
    /// Fix: round debits UP (away from zero), credits DOWN (toward zero).
    function _wadToTokens(int256 wadAmount) internal view returns (int256) {
        if (wadAmount >= 0) return wadAmount / int256(collateralScale);
        return -((-wadAmount + int256(collateralScale) - 1) / int256(collateralScale));
    }
}
