// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    IMarginEngine      public immutable marginEngine;
    IVault             public immutable vault;
    IOracleAdapter     public immutable oracle;
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

    /// AUDIT FIX (L3-L-1): Validate ADL address — zero address corrupts liquidation cascade
    function setADL(address _adl) external onlyOwner {
        require(_adl != address(0), "LE: zero ADL");
        adl = IAutoDeleveraging(_adl);
    }

    function setInsuranceFund(address _if) external onlyOwner {
        require(_if != address(0), "LE: zero IF");
        insuranceFund = _if;
    }

    /// AUDIT FIX (P7-L-1): Set FundingEngine for funding-aware shortfall computation.
    function setFundingEngine(address _fundingEngine) external onlyOwner {
        require(_fundingEngine != address(0), "LE: zero FE");
        fundingEngine = IFundingEngine(_fundingEngine);
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

    function setAuthorised(address caller, bool status) external onlyOwner {
        authorised[caller] = status;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P2-HIGH-8): Prevent ownership renouncement — protocol requires owner for param updates.
    function renounceOwnership() public view override onlyOwner {
        revert("LE: renounce disabled");
    }

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

        if (closeSize == 0) {
            // Tier 2: Full liquidation
            closeSize = absSize;
        }

        // AUDIT FIX (L3-H-3): Save original direction before close (position zeroed by updatePosition)
        bool wasLong = pos.size > 0;

        // Capture balance before close for shortfall computation
        uint256 balanceBeforeClose = vault.balance(subaccount, collateralToken);

        /// AUDIT FIX (P7-L-1): Compute pending funding BEFORE close (position state is
        /// modified by updatePosition). Funding settled inside updatePosition changes the
        /// effective available collateral — ignoring it misstates shortfall.
        int256 _pendingFunding;
        if (address(fundingEngine) != address(0)) {
            _pendingFunding = fundingEngine.getPendingFunding(marketId, pos.size, pos.entryFundingIndex);
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
        uint256 penalty = notional * liquidationPenaltyRate / WAD;
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

            // Compute shortfall: loss that exceeded available collateral
            // AUDIT FIX (P3-LIQ-2): Subtract actualPenalty from available collateral.
            // AUDIT FIX (P7-L-1): Also subtract funding owed from available collateral.
            // balanceBeforeClose was captured BEFORE updatePosition() which settles both
            // funding AND PnL. If the bankrupt position owed funding, the actual collateral
            // available to absorb losses is reduced by the funding amount.
            uint256 shortfallTokens;
            if (pnlRealized < 0) {
                /// AUDIT FIX (P5-H-10): Ceiling division — floor truncation understates loss,
                /// causing InsuranceFund/ADL to cover less than actual shortfall.
                uint256 lossTokens = (uint256(-pnlRealized) + collateralScale - 1) / collateralScale;
                uint256 availableCollateral = balanceBeforeClose > actualPenalty
                    ? balanceBeforeClose - actualPenalty
                    : 0;
                /// AUDIT FIX (P7-L-1): Adjust for funding settled inside updatePosition.
                /// Funding > 0 means position owed funding → reduces available collateral.
                /// Funding < 0 means position received funding → increases available.
                if (_pendingFunding > 0) {
                    uint256 fundingTokens = uint256(_pendingFunding) / collateralScale;
                    availableCollateral = availableCollateral > fundingTokens
                        ? availableCollateral - fundingTokens
                        : 0;
                } else if (_pendingFunding < 0) {
                    availableCollateral += uint256(-_pendingFunding) / collateralScale;
                }
                shortfallTokens = lossTokens > availableCollateral ? lossTokens - availableCollateral : 0;
            }

            if (shortfallTokens > 0) {
                // AUDIT FIX (L3-H-4): Try InsuranceFund BEFORE ADL
                // Guard: only call if insuranceFund is a contract (not EOA)
                if (insuranceFund != address(0) && insuranceFund.code.length > 0) {
                    try IInsuranceFund(insuranceFund).fundBalance(collateralToken) returns (uint256 ifBalance) {
                        uint256 covered = shortfallTokens > ifBalance ? ifBalance : shortfallTokens;
                        if (covered > 0) {
                            IInsuranceFund(insuranceFund).coverShortfall(collateralToken, covered);
                            /// AUDIT FIX (P2-HIGH-9): Forward IF payout to Vault to back winner's
                            /// phantom settlePnL credit. Without this, tokens sit in LiquidationEngine
                            /// and Vault's actual token balance stays below sum of internal balances.
                            IERC20(collateralToken).safeTransfer(address(vault), covered);
                            shortfallTokens -= covered;
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

        uint256 unitsToClose = (uint256(deficit) * WAD + uint256(netFreePerUnit) - 1) / uint256(netFreePerUnit); // ceil division

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
