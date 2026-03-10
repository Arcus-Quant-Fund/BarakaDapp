// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/ILiquidationEngine.sol";
import "../interfaces/IMarginEngine.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IAutoDeleveraging.sol";
import "../interfaces/IInsuranceFund.sol";
/// AUDIT FIX (P3-LIQ-3): Import ISubaccountManager for self-liquidation guard
import "../interfaces/ISubaccountManager.sol";
/// AUDIT FIX (P7-L-1): Import IFundingEngine for funding-aware shortfall computation
import "../interfaces/IFundingEngine.sol";

/**
 * @title LiquidationEngine
 * @author Baraka Protocol v2
 * @notice Three-tier liquidation cascade (dYdX v4 pattern):
 *
 *         Tier 1 — Partial liquidation:
 *           Reduce position size to bring equity back above MMR.
 *           Only closes the minimum amount needed.
 *
 *         Tier 2 — Full liquidation:
 *           If partial isn't sufficient (equity < 0 after partial),
 *           close the entire position. Remaining collateral → InsuranceFund.
 *
 *         Tier 3 — Auto-Deleveraging (ADL):
 *           If InsuranceFund can't cover the shortfall, trigger ADL.
 *           Profitable opposing positions are reduced pro-rata.
 *
 *         Liquidation fee: split between liquidator (incentive) and InsuranceFund.
 *         Shariah: max 5x leverage enforced at open, liquidation at any level.
 */
contract LiquidationEngine is ILiquidationEngine, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 constant WAD = 1e18;

    /// AUDIT FIX (P15-M-13): Minimum viable position size — prevents dust positions
    /// that are too small to be economically liquidated again but still consume
    /// storage and margin accounting overhead.
    uint256 constant MIN_POSITION_SIZE = 0.001e18;

    /// AUDIT FIX (P16-UP-C2): Timelocked dependency update to prevent brick risk
    uint256 constant DEPENDENCY_TIMELOCK = 48 hours;

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P16-UP-C2): Removed immutable from marginEngine and oracle to allow timelocked updates
    IMarginEngine      public marginEngine;
    IVault             public immutable vault;
    IOracleAdapter     public oracle;
    /// AUDIT FIX (P3-LIQ-3): SubaccountManager ref for self-liquidation guard
    ISubaccountManager public immutable subaccountManager;

    /// AUDIT FIX (P7-I-2): Made immutable — set in constructor, never modified.
    /// Saves ~2,100 gas per read (SLOAD → inline constant).
    address public immutable collateralToken;
    uint256 public immutable collateralScale;

    IAutoDeleveraging  public adl;
    address            public insuranceFund;

    /// AUDIT FIX (P7-L-1): FundingEngine reference for funding-aware shortfall computation.
    IFundingEngine     public fundingEngine;

    /// AUDIT FIX (P16-UP-C2): Timelocked dependency update state
    address public pendingOracle;
    uint256 public pendingOracleTimestamp;
    address public pendingMarginEngine;
    uint256 public pendingMarginEngineTimestamp;

    // ─────────────────────────────────────────────────────
    // Parameters
    // ─────────────────────────────────────────────────────

    /// @notice Liquidation penalty rate (WAD scale). e.g. 0.025e18 = 2.5%
    uint256 public liquidationPenaltyRate = 0.025e18;

    /// @notice Share of penalty that goes to liquidator (WAD scale). e.g. 0.50e18 = 50%
    uint256 public liquidatorShareRate = 0.50e18;

    /// @notice Authorised callers
    mapping(address => bool) public authorised;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event Liquidated(
        bytes32 indexed subaccount,
        bytes32 indexed marketId,
        address indexed liquidator,
        uint256 sizeClosed,
        int256 pnlRealized,
        uint256 penalty
    );
    event ADLTriggered(bytes32 indexed subaccount, bytes32 indexed marketId, uint256 shortfall);
    /// AUDIT FIX (L3-M-6): Emitted when account is still liquidatable after single-market close
    event SubaccountStillLiquidatable(bytes32 indexed subaccount);

    /// AUDIT FIX (P16-UP-C2): Timelocked dependency update events
    event OracleUpdateInitiated(address indexed newOracle, uint256 effectiveAt);
    event OracleUpdated(address indexed newOracle);
    event MarginEngineUpdateInitiated(address indexed newMarginEngine, uint256 effectiveAt);
    event MarginEngineUpdated(address indexed newMarginEngine);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _marginEngine,
        address _vault,
        address _oracle,
        address _collateralToken,
        /// AUDIT FIX (P3-LIQ-3): Accept SubaccountManager address for self-liquidation guard
        address _subaccountManager
    ) Ownable(initialOwner) {
        require(_marginEngine != address(0), "LE: zero ME");
        require(_vault != address(0), "LE: zero vault");
        require(_oracle != address(0), "LE: zero oracle");
        require(_collateralToken != address(0), "LE: zero collateral");
        /// AUDIT FIX (P3-LIQ-3): Validate SubaccountManager address
        require(_subaccountManager != address(0), "LE: zero SAM");

        marginEngine = IMarginEngine(_marginEngine);
        vault = IVault(_vault);
        oracle = IOracleAdapter(_oracle);
        subaccountManager = ISubaccountManager(_subaccountManager);
        collateralToken = _collateralToken;

        // Compute scale factor
        (bool ok, bytes memory data) = _collateralToken.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && data.length >= 32, "LE: no decimals");
        uint8 dec = abi.decode(data, (uint8));
        /// AUDIT FIX (L3-L-3): Validate token decimals ≤ 18 — overflow on 10**(18-dec)
        require(dec <= 18, "LE: decimals > 18");
        collateralScale = 10 ** (18 - dec);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P19-M-9): After finalize(), instant setters disabled — only timelocked paths work.
    bool public finalized;

    function finalize() external onlyOwner {
        finalized = true;
    }

    /// AUDIT FIX (L3-L-1): Validate ADL address — zero address corrupts liquidation cascade
    function setADL(address _adl) external onlyOwner {
        require(!finalized, "LE: use timelocked update");
        require(_adl != address(0), "LE: zero ADL");
        adl = IAutoDeleveraging(_adl);
    }

    function setInsuranceFund(address _if) external onlyOwner {
        require(!finalized, "LE: use timelocked update");
        require(_if != address(0), "LE: zero IF");
        insuranceFund = _if;
    }

    /// AUDIT FIX (P7-L-1): Set FundingEngine for funding-aware shortfall computation.
    function setFundingEngine(address _fundingEngine) external onlyOwner {
        require(!finalized, "LE: use timelocked update");
        require(_fundingEngine != address(0), "LE: zero FE");
        fundingEngine = IFundingEngine(_fundingEngine);
    }

    /// AUDIT FIX (P19-M-9): Timelocked ADL update — consistent with oracle/ME timelocks.
    address public pendingADL;
    uint256 public pendingADLTimestamp;
    event ADLUpdateInitiated(address indexed newADL, uint256 effectiveTime);
    event ADLUpdated(address indexed newADL);
    event ADLUpdateCancelled(address indexed cancelled);

    function initiateADLUpdate(address newADL) external onlyOwner {
        require(newADL != address(0), "LE: zero ADL");
        pendingADL = newADL;
        pendingADLTimestamp = block.timestamp;
        emit ADLUpdateInitiated(newADL, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyADLUpdate() external onlyOwner {
        require(pendingADL != address(0), "LE: no pending update");
        require(block.timestamp >= pendingADLTimestamp + DEPENDENCY_TIMELOCK, "LE: timelock active");
        adl = IAutoDeleveraging(pendingADL);
        emit ADLUpdated(pendingADL);
        pendingADL = address(0);
        pendingADLTimestamp = 0;
    }

    function cancelADLUpdate() external onlyOwner {
        require(pendingADL != address(0), "LE: no pending update");
        emit ADLUpdateCancelled(pendingADL);
        pendingADL = address(0);
        pendingADLTimestamp = 0;
    }

    /// AUDIT FIX (P19-M-9): Timelocked InsuranceFund update.
    address public pendingInsuranceFund;
    uint256 public pendingInsuranceFundTimestamp;
    event InsuranceFundUpdateInitiated(address indexed newIF, uint256 effectiveTime);
    event InsuranceFundUpdated(address indexed newIF);
    event InsuranceFundUpdateCancelled(address indexed cancelled);

    function initiateInsuranceFundUpdate(address newIF) external onlyOwner {
        require(newIF != address(0), "LE: zero IF");
        pendingInsuranceFund = newIF;
        pendingInsuranceFundTimestamp = block.timestamp;
        emit InsuranceFundUpdateInitiated(newIF, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyInsuranceFundUpdate() external onlyOwner {
        require(pendingInsuranceFund != address(0), "LE: no pending update");
        require(block.timestamp >= pendingInsuranceFundTimestamp + DEPENDENCY_TIMELOCK, "LE: timelock active");
        insuranceFund = pendingInsuranceFund;
        emit InsuranceFundUpdated(pendingInsuranceFund);
        pendingInsuranceFund = address(0);
        pendingInsuranceFundTimestamp = 0;
    }

    function cancelInsuranceFundUpdate() external onlyOwner {
        require(pendingInsuranceFund != address(0), "LE: no pending update");
        emit InsuranceFundUpdateCancelled(pendingInsuranceFund);
        pendingInsuranceFund = address(0);
        pendingInsuranceFundTimestamp = 0;
    }

    /// AUDIT FIX (P19-M-9): Timelocked FundingEngine update.
    address public pendingFundingEngine;
    uint256 public pendingFundingEngineTimestamp;
    event FundingEngineUpdateInitiated(address indexed newFE, uint256 effectiveTime);
    event FundingEngineUpdated_(address indexed newFE);
    event FundingEngineUpdateCancelled_(address indexed cancelled);

    function initiateFundingEngineUpdate(address newFE) external onlyOwner {
        require(newFE != address(0), "LE: zero FE");
        pendingFundingEngine = newFE;
        pendingFundingEngineTimestamp = block.timestamp;
        emit FundingEngineUpdateInitiated(newFE, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyFundingEngineUpdate() external onlyOwner {
        require(pendingFundingEngine != address(0), "LE: no pending update");
        require(block.timestamp >= pendingFundingEngineTimestamp + DEPENDENCY_TIMELOCK, "LE: timelock active");
        fundingEngine = IFundingEngine(pendingFundingEngine);
        emit FundingEngineUpdated_(pendingFundingEngine);
        pendingFundingEngine = address(0);
        pendingFundingEngineTimestamp = 0;
    }

    function cancelFundingEngineUpdate() external onlyOwner {
        require(pendingFundingEngine != address(0), "LE: no pending update");
        emit FundingEngineUpdateCancelled_(pendingFundingEngine);
        pendingFundingEngine = address(0);
        pendingFundingEngineTimestamp = 0;
    }

    function setLiquidationPenalty(uint256 rate) external onlyOwner {
        require(rate <= 0.10e18, "LE: penalty > 10%");
        liquidationPenaltyRate = rate;
    }

    /// AUDIT FIX (L3-I-4): Cap at 80% — 100% leaves zero for InsuranceFund, weakening backstop
    function setLiquidatorShare(uint256 rate) external onlyOwner {
        require(rate <= 0.80e18, "LE: share > 80%");
        liquidatorShareRate = rate;
    }

    /// AUDIT FIX (P16-AC-M1): Zero-address check — prevents accidentally authorising address(0)
    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "LE: zero address");
        authorised[caller] = status;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P2-HIGH-8): Prevent ownership renouncement — protocol requires owner for param updates.
    function renounceOwnership() public view override onlyOwner {
        revert("LE: renounce disabled");
    }

    /// AUDIT FIX (P16-UP-C2): Timelocked oracle update to prevent brick risk
    function initiateOracleUpdate(address newOracle) external onlyOwner {
        require(newOracle != address(0), "LE: zero address");
        pendingOracle = newOracle;
        pendingOracleTimestamp = block.timestamp;
        emit OracleUpdateInitiated(newOracle, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyOracleUpdate() external onlyOwner {
        require(pendingOracle != address(0), "LE: no pending update");
        require(block.timestamp >= pendingOracleTimestamp + DEPENDENCY_TIMELOCK, "LE: timelock active");
        oracle = IOracleAdapter(pendingOracle);
        emit OracleUpdated(pendingOracle);
        pendingOracle = address(0);
        pendingOracleTimestamp = 0;
    }

    /// AUDIT FIX (P18-H-3): Cancel pending oracle update
    /// AUDIT FIX (P19-M-2): Emit event for off-chain monitoring
    function cancelOracleUpdate() external onlyOwner {
        require(pendingOracle != address(0), "LE: no pending update");
        emit OracleUpdateCancelled(pendingOracle);
        pendingOracle = address(0);
        pendingOracleTimestamp = 0;
    }
    event OracleUpdateCancelled(address indexed cancelled);

    /// AUDIT FIX (P16-UP-C2): Timelocked marginEngine update to prevent brick risk
    function initiateMarginEngineUpdate(address newMarginEngine) external onlyOwner {
        require(newMarginEngine != address(0), "LE: zero address");
        pendingMarginEngine = newMarginEngine;
        pendingMarginEngineTimestamp = block.timestamp;
        emit MarginEngineUpdateInitiated(newMarginEngine, block.timestamp + DEPENDENCY_TIMELOCK);
    }

    function applyMarginEngineUpdate() external onlyOwner {
        require(pendingMarginEngine != address(0), "LE: no pending update");
        require(block.timestamp >= pendingMarginEngineTimestamp + DEPENDENCY_TIMELOCK, "LE: timelock active");
        marginEngine = IMarginEngine(pendingMarginEngine);
        emit MarginEngineUpdated(pendingMarginEngine);
        pendingMarginEngine = address(0);
        pendingMarginEngineTimestamp = 0;
    }

    /// AUDIT FIX (P18-H-3): Cancel pending marginEngine update
    /// AUDIT FIX (P19-M-2): Emit event for off-chain monitoring
    function cancelMarginEngineUpdate() external onlyOwner {
        require(pendingMarginEngine != address(0), "LE: no pending update");
        emit MarginEngineUpdateCancelled(pendingMarginEngine);
        pendingMarginEngine = address(0);
        pendingMarginEngineTimestamp = 0;
    }
    event MarginEngineUpdateCancelled(address indexed cancelled);

    // ─────────────────────────────────────────────────────
    // Core — liquidation
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P2-CRIT-3): Removed whenNotPaused — liquidations must proceed even during
    /// emergency pause. Blocking liquidations while paused allows underwater positions to
    /// accumulate losses, potentially depleting the InsuranceFund upon unpause.
    function liquidate(bytes32 subaccount, bytes32 marketId)
        external
        override
        nonReentrant
        returns (uint256 sizeClosed, int256 pnlRealized)
    {
        // AUDIT FIX (P3-LIQ-3): Block self-liquidation — owner extracting liquidator fee at 50% discount
        {
            address _owner = subaccountManager.getOwner(subaccount);
            require(msg.sender != _owner, "LE: self-liquidation");
        }

        require(marginEngine.isLiquidatable(subaccount), "LE: not liquidatable");

        /// AUDIT FIX (L3-M-3): Oracle staleness check before liquidation
        require(!oracle.isStale(marketId), "LE: stale oracle");

        IMarginEngine.Position memory pos = marginEngine.getPosition(subaccount, marketId);
        require(pos.size != 0, "LE: no position");

        uint256 indexPrice = oracle.getIndexPrice(marketId);
        uint256 absSize = _abs(pos.size);

        // Tier 1: Try partial liquidation — close enough to restore MMR
        uint256 closeSize = _computePartialClose(subaccount, marketId, absSize, indexPrice);

        /// AUDIT FIX (P15-M-13): If partial liquidation would leave a dust position
        /// (below MIN_POSITION_SIZE), liquidate the full position instead.
        if (closeSize > 0 && closeSize < absSize) {
            uint256 remaining = absSize - closeSize;
            if (remaining > 0 && remaining < MIN_POSITION_SIZE) {
                closeSize = absSize; // full liquidation to avoid dust
            }
        }

        if (closeSize == 0) {
            // Tier 2: Full liquidation
            closeSize = absSize;
        }

        // AUDIT FIX (L3-H-3): Save original direction before close (position zeroed by updatePosition)
        bool wasLong = pos.size > 0;

        /// AUDIT FIX (P17-H-1): Enable liquidation mode for full liquidation to prevent triple-dip.
        /// MarginEngine accumulates shortfalls instead of calling IF directly, allowing a single
        /// IF call below that respects the 10% per-event cap per liquidation (not per sub-call).
        bool isFullLiq = (closeSize == absSize);
        if (isFullLiq) {
            marginEngine.setLiquidationMode(true);
        }

        // Execute the close via MarginEngine
        /// AUDIT NOTE (L3-M-1): PnL is settled inside MarginEngine.updatePosition() via vault.settlePnL()
        int256 sizeDelta = wasLong ? -int256(closeSize) : int256(closeSize);
        marginEngine.updatePosition(subaccount, marketId, sizeDelta, indexPrice);

        // Compute realized PnL
        int256 priceDelta = int256(indexPrice) - int256(pos.entryPrice);
        pnlRealized = priceDelta * int256(closeSize) / int256(WAD);
        if (!wasLong) pnlRealized = -pnlRealized;

        // Compute penalty
        uint256 notional = closeSize * indexPrice / WAD;
        /// AUDIT FIX (P16-AR-M1): Combined mulDiv reduces truncation from sequential divisions
        uint256 penalty = Math.mulDiv(
            Math.mulDiv(closeSize, indexPrice, WAD),
            liquidationPenaltyRate,
            WAD
        );
        uint256 penaltyTokens = penalty / collateralScale;
        /// AUDIT FIX (L3-M-10): Minimum 1 token penalty — prevents zero incentive on micro-positions
        if (penaltyTokens == 0 && notional > 0) penaltyTokens = 1;

        // Charge penalty from subaccount
        uint256 subBalance = vault.balance(subaccount, collateralToken);
        uint256 actualPenalty = penaltyTokens > subBalance ? subBalance : penaltyTokens;

        if (actualPenalty > 0) {
            // Split: liquidator gets their share, rest to InsuranceFund
            uint256 toLiquidator = actualPenalty * liquidatorShareRate / WAD;
            uint256 toInsurance = actualPenalty - toLiquidator;

            if (toLiquidator > 0) {
                vault.chargeFee(subaccount, collateralToken, toLiquidator, msg.sender);
            }
            if (toInsurance > 0 && insuranceFund != address(0)) {
                vault.chargeFee(subaccount, collateralToken, toInsurance, insuranceFund);
            }
        }

        // After full liquidation: three-tier cascade (dYdX v4 pattern)
        if (closeSize == absSize) {
            // AUDIT FIX (L3-H-5): Sweep residual collateral to InsuranceFund
            uint256 residual = vault.balance(subaccount, collateralToken);
            if (residual > 0 && insuranceFund != address(0)) {
                vault.chargeFee(subaccount, collateralToken, residual, insuranceFund);
            }

            /// AUDIT FIX (P17-H-1): Use ME's accumulated shortfall — exact token-level gap from
            /// all vault.settlePnL caps during this liquidation. Replaces the previous theoretical
            /// shortfall computation that could diverge from actual settlement reality.
            /// Single IF call prevents triple-dip (funding + PnL + external = 3 × 10% = 30% drain).
            uint256 shortfallTokens = marginEngine.consumeAccumulatedShortfall();

            if (shortfallTokens > 0) {
                // AUDIT FIX (L3-H-4): Try InsuranceFund BEFORE ADL — single call per liquidation
                // Guard: only call if insuranceFund is a contract (not EOA)
                if (insuranceFund != address(0) && insuranceFund.code.length > 0) {
                    try IInsuranceFund(insuranceFund).fundBalance(collateralToken) returns (uint256 ifBalance) {
                        uint256 covered = shortfallTokens > ifBalance ? ifBalance : shortfallTokens;
                        if (covered > 0) {
                            /// AUDIT FIX (P15-M-14): Use returned actualCovered — IF caps at 10% of pool.
                            uint256 actualCovered = IInsuranceFund(insuranceFund).coverShortfall(collateralToken, covered);
                            /// AUDIT FIX (P2-HIGH-9): Forward IF payout to Vault to back winner's
                            /// phantom settlePnL credit.
                            IERC20(collateralToken).safeTransfer(address(vault), actualCovered);
                            shortfallTokens -= actualCovered;
                        }
                    } catch {
                        // InsuranceFund not available — proceed to ADL
                    }
                }

                // ADL only if InsuranceFund couldn't fully cover the shortfall
                if (shortfallTokens > 0 && address(adl) != address(0)) {
                    uint256 shortfallWad = shortfallTokens * collateralScale;
                    adl.executeADL(subaccount, marketId, shortfallWad, wasLong);
                    emit ADLTriggered(subaccount, marketId, shortfallWad);
                }
            }
        }

        sizeClosed = closeSize;
        emit Liquidated(subaccount, marketId, msg.sender, closeSize, pnlRealized, actualPenalty);

        /// AUDIT FIX (L3-M-6): Warn if account is still liquidatable after single-market close
        /// Keepers should call liquidate for each market with open positions
        if (marginEngine.isLiquidatable(subaccount)) {
            emit SubaccountStillLiquidatable(subaccount);
        }
    }

    function canLiquidate(bytes32 subaccount) external view override returns (bool) {
        return marginEngine.isLiquidatable(subaccount);
    }

    /// @dev INFO (L3-I-5): Positions in unapproved markets CAN be liquidated — this is correct.
    ///      If a market is later unapproved, existing positions must still be closeable.
    /// @dev INFO (L3-I-6): Theoretical overflow in pnl/notional math is bounded by
    ///      realistic price/size ranges (uint256 overflow requires ~1e77 USD notional).
    /// @dev INFO (L3-I-8): Oracle staleness is checked at top of liquidate() (L3-M-3 fix).

    // ─────────────────────────────────────────────────────
    // Internal — partial liquidation math
    // ─────────────────────────────────────────────────────

    /// @notice Compute the minimum size to close to restore equity > MMR.
    ///         If partial close can't restore, returns 0 (signals full liquidation).
    /// AUDIT FIX (P5-H-4): Account for realized PnL when computing partial close amount.
    /// Previously, the formula only considered freed margin requirement. For losing positions,
    /// closing units realizes a loss that reduces equity, requiring more units to close.
    function _computePartialClose(
        bytes32 subaccount,
        bytes32 marketId,
        uint256 absSize,
        uint256 indexPrice
    ) internal view returns (uint256) {
        int256 equity = marginEngine.getEquity(subaccount);
        uint256 mmr = marginEngine.getMaintenanceMarginReq(subaccount);

        // If equity is already negative, partial won't help
        if (equity <= 0) return 0;

        // How much equity deficit do we need to cover?
        // deficit = mmr - equity (amount we need to free up)
        int256 deficit = int256(mmr) - equity;
        if (deficit <= 0) return 0; // shouldn't happen (not liquidatable), but defensive

        IMarginEngine.MarketParams memory params = marginEngine.getMarketParams(marketId);
        IMarginEngine.Position memory pos = marginEngine.getPosition(subaccount, marketId);

        // Each unit closed frees margin AND realizes PnL
        uint256 marginPerUnit = indexPrice * params.maintenanceMarginRate / WAD;

        // Compute per-unit realized loss (positive = loss per unit)
        int256 lossPerUnit;
        if (pos.size > 0) {
            // Long: loss if price dropped
            lossPerUnit = int256(pos.entryPrice) - int256(indexPrice);
        } else {
            // Short: loss if price rose
            lossPerUnit = int256(indexPrice) - int256(pos.entryPrice);
        }

        // Net equity freed per unit = margin freed - loss realized (if losing)
        int256 netFreePerUnit = int256(marginPerUnit) - (lossPerUnit > 0 ? lossPerUnit : int256(0));
        if (netFreePerUnit <= 0) return 0; // partial won't help → full liquidation

        /// AUDIT FIX (P16-AR-M4): mulDiv prevents deficit * WAD overflow
        uint256 unitsToClose = Math.mulDiv(uint256(deficit), WAD, uint256(netFreePerUnit), Math.Rounding.Ceil);

        // Cap at full position size, minimum 1
        if (unitsToClose > absSize) return 0; // need full liquidation
        if (unitsToClose == 0) unitsToClose = 1;

        return unitsToClose;
    }

    /// AUDIT FIX (L3-L-2): Guard against type(int256).min overflow (no positive equivalent)
    function _abs(int256 x) internal pure returns (uint256) {
        require(x != type(int256).min, "LE: int256 min overflow");
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
