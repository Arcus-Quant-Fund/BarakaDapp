// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IShariahGuard.sol";
import "../interfaces/IFundingEngine.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/ICollateralVault.sol";
import "../interfaces/ILiquidationEngine.sol";
import "../interfaces/IInsuranceFund.sol";

/**
 * @title PositionManager
 * @author Baraka Protocol
 * @notice Core trading logic: open, close, and settle perpetual futures positions.
 *
 *   - Isolated margin only (no cross-margin). Each position has its own collateral.
 *   - ShariahGuard is called before every position open — no exceptions.
 *   - Funding accrues hourly via FundingEngine (ι=0 formula).
 *   - Unrealized PnL: (currentPrice − entryPrice) * size / entryPrice
 */
contract PositionManager is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────

    struct Position {
        address trader;
        address asset;            // market (e.g. WBTC address used as market ID)
        address collateralToken;  // USDC / PAXG / XAUT
        uint256 size;             // notional size in 1e18 (collateral units)
        uint256 collateral;       // current collateral backing (shrinks with funding losses)
        uint256 entryPrice;       // oracle index price at open (1e18)
        int256  fundingIndexAtOpen; // cumulative funding index at position open
        uint256 openBlock;
        uint256 openTimestamp;
        bool    isLong;
        bool    open;
    }

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    IShariahGuard      public immutable shariahGuard;
    IFundingEngine     public immutable fundingEngine;
    IOracleAdapter     public immutable oracle;
    ICollateralVault   public immutable vault;
    ILiquidationEngine public immutable liquidationEngine;
    IInsuranceFund     public immutable insuranceFund;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    mapping(bytes32 => Position) public positions;

    /// @notice BRKX token used for hold-based fee discounts.
    ///         When address(0), fee collection is disabled (protocol-off state).
    IERC20  public brkxToken;

    /// @notice Treasury address — receives 50% of collected trading fees.
    address public treasury;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        address indexed asset,
        address collateralToken,
        uint256 size,
        uint256 collateral,
        uint256 entryPrice,
        bool    isLong
    );
    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        int256  realizedPnl,
        uint256 exitPrice
    );
    event FundingSettled(
        bytes32 indexed positionId,
        int256  fundingPayment,
        uint256 newCollateral
    );
    event FeeCollected(
        address indexed trader,
        address indexed token,
        uint256 amount,
        uint256 feeBps
    );
    event BrkxTokenSet(address indexed brkxToken);
    event TreasurySet(address indexed treasury);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _shariahGuard,
        address _fundingEngine,
        address _oracle,
        address _vault,
        address _liquidationEngine,
        address _insuranceFund
    ) Ownable(initialOwner) {
        require(_shariahGuard      != address(0), "PM: zero ShariahGuard");
        require(_fundingEngine     != address(0), "PM: zero FundingEngine");
        require(_oracle            != address(0), "PM: zero Oracle");
        require(_vault             != address(0), "PM: zero Vault");
        require(_liquidationEngine != address(0), "PM: zero LiqEngine");
        require(_insuranceFund     != address(0), "PM: zero InsuranceFund");

        shariahGuard      = IShariahGuard(_shariahGuard);
        fundingEngine     = IFundingEngine(_fundingEngine);
        oracle            = IOracleAdapter(_oracle);
        vault             = ICollateralVault(_vault);
        liquidationEngine = ILiquidationEngine(_liquidationEngine);
        insuranceFund     = IInsuranceFund(_insuranceFund);
    }

    // ─────────────────────────────────────────────────────
    // Admin — fee configuration
    // ─────────────────────────────────────────────────────

    /**
     * @notice Set the BRKX token address to enable fee collection.
     *         Set to address(0) to disable fees (emergency off-switch).
     */
    function setBrkxToken(address _brkx) external onlyOwner {
        brkxToken = IERC20(_brkx);
        emit BrkxTokenSet(_brkx);
    }

    /**
     * @notice Set the treasury address that receives 50% of trading fees.
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "PM: zero treasury");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────
    // Core — open position
    // ─────────────────────────────────────────────────────

    /**
     * @notice Open a new isolated-margin perpetual position.
     *
     * @param asset           Market identifier (asset address, e.g. WBTC).
     * @param collateralToken Token used as collateral (USDC, PAXG, XAUT).
     * @param collateral      Collateral amount (in collateralToken decimals).
     * @param leverage        Desired leverage (1–5, enforced by ShariahGuard).
     * @param isLong          True = long, False = short.
     *
     * @return positionId Unique identifier for this position.
     */
    function openPosition(
        address asset,
        address collateralToken,
        uint256 collateral,
        uint256 leverage,
        bool    isLong
    ) external nonReentrant whenNotPaused returns (bytes32 positionId) {
        require(collateral > 0, "PM: zero collateral");
        require(leverage >= 1 && leverage <= 5, "PM: leverage out of range");

        uint256 indexPrice = oracle.getIndexPrice(asset);
        require(indexPrice > 0, "PM: zero index price");

        uint256 notional = collateral * leverage;

        // ── Shariah compliance check (reverts if non-compliant) ──
        shariahGuard.validatePosition(asset, collateral, notional);

        // ── Update funding before opening ──
        int256 currentFundingIndex = fundingEngine.updateCumulativeFunding(asset);

        // ── Lock collateral in vault ──
        vault.lockCollateral(msg.sender, collateralToken, collateral);

        // ── Collect opening fee (from trader's remaining free balance) ──
        _collectFee(msg.sender, collateralToken, notional);

        // ── Create position ──
        positionId = keccak256(
            abi.encodePacked(msg.sender, asset, collateralToken, block.timestamp, block.number)
        );

        positions[positionId] = Position({
            trader:            msg.sender,
            asset:             asset,
            collateralToken:   collateralToken,
            size:              notional,
            collateral:        collateral,
            entryPrice:        indexPrice,
            fundingIndexAtOpen: currentFundingIndex,
            openBlock:         block.number,
            openTimestamp:     block.timestamp,
            isLong:            isLong,
            open:              true
        });

        // ── Push snapshot to LiquidationEngine ──
        _pushLiqSnapshot(positionId);

        // ── Record mark price observation ──
        uint256 markPrice = oracle.getMarkPrice(asset, 30 minutes);
        // (OracleAdapter.recordMarkPrice is called externally by keeper in production)
        // Here we rely on the TWAP already being populated.

        emit PositionOpened(
            positionId, msg.sender, asset, collateralToken,
            notional, collateral, indexPrice, isLong
        );
    }

    // ─────────────────────────────────────────────────────
    // Core — close position
    // ─────────────────────────────────────────────────────

    /**
     * @notice Close an open position. Settles any pending funding first.
     *         Returns collateral ± realized PnL to trader.
     *
     * @param positionId The position to close.
     */
    function closePosition(bytes32 positionId)
        external
        nonReentrant
        whenNotPaused
    {
        Position storage pos = positions[positionId];
        require(pos.open,                   "PM: position not open");
        require(pos.trader == msg.sender,   "PM: not your position");

        // --- Effects: mark closed BEFORE any external calls (CEI pattern) ---
        pos.open = false;

        // Settle funding first
        _settleFundingInternal(positionId);

        uint256 exitPrice = oracle.getIndexPrice(pos.asset);
        require(exitPrice > 0, "PM: zero exit price");

        // Realized PnL: (exitPrice - entryPrice) / entryPrice * size
        int256 priceDelta = int256(exitPrice) - int256(pos.entryPrice);
        int256 pnl = priceDelta * int256(pos.size) / int256(pos.entryPrice);
        if (!pos.isLong) pnl = -pnl; // short positions: inverted

        int256 finalCollateral = int256(pos.collateral) + pnl;

        // Remove liquidation snapshot
        _removeLiqSnapshot(positionId);

        if (finalCollateral > 0) {
            // Return remaining collateral to trader
            vault.unlockCollateral(msg.sender, pos.collateralToken, pos.collateral);
            // PnL transfer handled off-chain via InsuranceFund / counterparty matching
            // (simplified for MVP — full AMM/orderbook integration in Phase 2)
        } else {
            // Loss exceeds collateral — liquidation should have occurred earlier
            vault.unlockCollateral(msg.sender, pos.collateralToken, 0);
        }

        // ── Collect closing fee (from just-unlocked free balance) ──
        _collectFee(msg.sender, pos.collateralToken, pos.size);

        emit PositionClosed(positionId, msg.sender, pnl, exitPrice);
    }

    // ─────────────────────────────────────────────────────
    // Core — settle funding
    // ─────────────────────────────────────────────────────

    /**
     * @notice Settle accumulated funding for a position.
     *         Can be called by anyone (keeper, trader, liquidator).
     *
     * @param positionId The position to settle.
     */
    function settleFunding(bytes32 positionId) external nonReentrant whenNotPaused {
        _settleFundingInternal(positionId);
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /**
     * @notice Collect a trading fee from the trader's free balance in the vault.
     *         No-op when brkxToken is not yet set (fees not enabled).
     *
     * Fee tiers (hold-based, BNB-style — no lock-up required):
     *   < 1,000  BRKX held  →  5.0 bps
     *   ≥ 1,000  BRKX held  →  4.0 bps  (−20%)
     *   ≥ 10,000 BRKX held  →  3.5 bps  (−30%)
     *   ≥ 50,000 BRKX held  →  2.5 bps  (−50%)
     *
     * Revenue split: 50% InsuranceFund (Takaful pool) + 50% treasury.
     *
     * @param user      Trader paying the fee.
     * @param collToken Collateral token address.
     * @param notional  Notional size of the position (collateral × leverage).
     */
    function _collectFee(address user, address collToken, uint256 notional) internal {
        // Fees are disabled until brkxToken is configured post-deploy.
        if (address(brkxToken) == address(0)) return;

        // ── Determine fee rate from BRKX wallet balance ──
        // feeBps unit: tenths of a basis point (×10 scale for half-bps precision)
        //   50 → 5.0 bps   40 → 4.0 bps   35 → 3.5 bps   25 → 2.5 bps
        uint256 held = brkxToken.balanceOf(user);
        uint256 feeBps;
        if      (held >= 50_000e18) feeBps = 25;
        else if (held >= 10_000e18) feeBps = 35;
        else if (held >=  1_000e18) feeBps = 40;
        else                        feeBps = 50;

        // feeAmount = notional × feeBps / 100_000
        // (divide by 100_000 because feeBps is in units of 0.001 bps × 10 = 0.01 bps)
        uint256 feeAmount = (notional * feeBps) / 100_000;
        if (feeAmount == 0) return;

        // ── Pull fee from trader's free balance as actual ERC-20 tokens ──
        // vault.chargeFromFree deducts _freeBalance[user] and safeTransfers to this contract.
        vault.chargeFromFree(user, collToken, feeAmount);

        // ── Split 50 / 50 ──
        uint256 half = feeAmount / 2;
        uint256 rem  = feeAmount - half; // handles odd-wei rounding — rem >= half always

        // 50% → InsuranceFund (Takaful pool)
        IERC20(collToken).forceApprove(address(insuranceFund), half);
        insuranceFund.receiveFromLiquidation(collToken, half);

        // 50% → Treasury
        IERC20(collToken).safeTransfer(treasury, rem);

        emit FeeCollected(user, collToken, feeAmount, feeBps);
    }

    function _settleFundingInternal(bytes32 positionId) internal {
        // ── Checks-Effects-Interactions (CEI) ─────────────────────────────
        // 1. READ all relevant state into memory before any external call.
        address asset          = positions[positionId].asset;
        int256  fundingAtOpen  = positions[positionId].fundingIndexAtOpen;
        uint256 size           = positions[positionId].size;
        bool    isLong         = positions[positionId].isLong;
        uint256 collateral     = positions[positionId].collateral;

        // 2. INTERACTION: external call to FundingEngine (trusted contract, nonReentrant guards all callers).
        // slither-disable-next-line reentrancy-no-eth (FundingEngine is trusted; all callers are nonReentrant; state written in step 4 below, after full computation)
        int256 currentIndex = fundingEngine.updateCumulativeFunding(asset);
        int256 fundingDelta = currentIndex - fundingAtOpen;

        // slither-disable-next-line incorrect-equality (0 delta is a valid early return — not an equality check on a variable that could skip non-zero)
        if (fundingDelta == 0) return;

        // 3. COMPUTE payment in memory (no state reads after external call).
        // Funding payment: delta * size / 1e18
        // Positive delta + long = longs pay (reduce collateral)
        // Positive delta + short = shorts receive (increase collateral)
        int256 payment = fundingDelta * int256(size) / 1e18;
        if (!isLong) payment = -payment;

        uint256 newCollateral;
        if (payment > 0) {
            newCollateral = int256(collateral) <= payment ? 0 : collateral - uint256(payment);
        } else if (payment < 0) {
            newCollateral = collateral + uint256(-payment);
        } else {
            newCollateral = collateral;
        }

        // 4. EFFECTS: write state after all computation is done.
        positions[positionId].collateral         = newCollateral;
        positions[positionId].fundingIndexAtOpen = currentIndex;

        // 5. INTERACTIONS: downstream calls after state is fully consistent.
        _pushLiqSnapshot(positionId);

        emit FundingSettled(positionId, payment, newCollateral);
    }

    function _pushLiqSnapshot(bytes32 positionId) internal {
        Position storage pos = positions[positionId];
        // Interface via external call to LiquidationEngine.updateSnapshot
        // (we cast to a concrete type here — LiquidationEngine exposes this publicly)
        (bool ok,) = address(liquidationEngine).call(
            abi.encodeWithSignature(
                "updateSnapshot(bytes32,address,address,address,uint256,uint256,uint256,bool)",
                positionId,
                pos.trader,
                pos.asset,
                pos.collateralToken,
                pos.collateral,
                pos.size,
                pos.openBlock,
                pos.isLong
            )
        );
        require(ok, "PM: snapshot update failed");
    }

    function _removeLiqSnapshot(bytes32 positionId) internal {
        (bool ok,) = address(liquidationEngine).call(
            abi.encodeWithSignature("removeSnapshot(bytes32)", positionId)
        );
        require(ok, "PM: snapshot removal failed");
    }

    // ─────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────

    function getPosition(bytes32 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    function getUnrealizedPnl(bytes32 positionId) external view returns (int256 pnl) {
        Position storage pos = positions[positionId];
        if (!pos.open) return 0;

        uint256 currentPrice = oracle.getIndexPrice(pos.asset);
        int256 priceDelta    = int256(currentPrice) - int256(pos.entryPrice);
        pnl = priceDelta * int256(pos.size) / int256(pos.entryPrice);
        if (!pos.isLong) pnl = -pnl;
    }
}
