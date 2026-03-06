// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ILiquidationEngine.sol";
import "../interfaces/IInsuranceFund.sol";
import "../interfaces/ICollateralVault.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title LiquidationEngine
 * @author Baraka Protocol
 * @notice Liquidates underwater positions. Incentivises liquidators with a fair penalty split.
 *
 * Parameters:
 *   Maintenance margin: 2% of position notional
 *   Liquidation penalty: 1% of position notional
 *   Penalty split: 50% to InsuranceFund (Takaful seed), 50% to liquidator
 *   Minimum delay: 1 block between position open and liquidation eligibility
 *   Partial liquidation: reduce to safe leverage before full close
 */
contract LiquidationEngine is ILiquidationEngine, Ownable2Step, Pausable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 public constant MAINTENANCE_MARGIN_BPS = 200;  // 2%
    uint256 public constant LIQUIDATION_PENALTY_BPS = 100; // 1%
    uint256 public constant INSURANCE_SPLIT_BPS     = 5000; // 50% to InsuranceFund
    uint256 public constant BPS_DENOM               = 10000;

    // ─────────────────────────────────────────────────────
    // Dependencies (set post-deploy)
    // ─────────────────────────────────────────────────────

    IInsuranceFund   public immutable insuranceFund;
    ICollateralVault public immutable vault;

    /// @notice Reference to PositionManager for position data reads
    address public positionManager;

    /// @notice Oracle for current price lookups (optional — set post-deploy via setOracle).
    ///         When not set, isLiquidatable falls back to snapshot collateral only.
    IOracleAdapter public oracle;

    // ─────────────────────────────────────────────────────
    // State — position snapshot (pushed by PositionManager)
    // ─────────────────────────────────────────────────────

    struct LiqSnapshot {
        address trader;
        address asset;
        address collateralToken;
        uint256 collateral;    // current collateral (shrinks with funding)
        uint256 notional;      // size * entry price
        uint256 entryPrice;    // oracle price at open (1e18) — used for unrealizedPnl
        uint256 openBlock;     // block number when position was opened
        bool    isLong;
    }

    mapping(bytes32 => LiqSnapshot) public snapshots;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event Liquidated(
        bytes32 indexed positionId,
        address indexed liquidator,
        address indexed trader,
        uint256 penalty,
        uint256 liquidatorShare,
        uint256 insuranceShare,
        uint256 timestamp
    );
    event SnapshotUpdated(bytes32 indexed positionId);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _insuranceFund,
        address _vault
    ) Ownable(initialOwner) {
        require(_insuranceFund != address(0), "LiquidationEngine: zero InsuranceFund");
        require(_vault         != address(0), "LiquidationEngine: zero Vault");
        insuranceFund = IInsuranceFund(_insuranceFund);
        vault         = ICollateralVault(_vault);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setPositionManager(address pm) external onlyOwner {
        require(pm != address(0), "LiquidationEngine: zero PM");
        positionManager = pm;
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "LiquidationEngine: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    modifier onlyPositionManager() {
        require(msg.sender == positionManager, "LiquidationEngine: not PositionManager");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Called by PositionManager to keep snapshots current
    // ─────────────────────────────────────────────────────

    function updateSnapshot(
        bytes32 positionId,
        address trader,
        address asset,
        address collateralToken,
        uint256 collateral,
        uint256 notional,
        uint256 entryPrice,
        uint256 openBlock,
        bool    isLong
    ) external onlyPositionManager {
        snapshots[positionId] = LiqSnapshot({
            trader:          trader,
            asset:           asset,
            collateralToken: collateralToken,
            collateral:      collateral,
            notional:        notional,
            entryPrice:      entryPrice,
            openBlock:       openBlock,
            isLong:          isLong
        });
        emit SnapshotUpdated(positionId);
    }

    function removeSnapshot(bytes32 positionId) external onlyPositionManager {
        delete snapshots[positionId];
    }

    // ─────────────────────────────────────────────────────
    // ILiquidationEngine
    // ─────────────────────────────────────────────────────

    /**
     * @notice Returns true if a position's current equity has fallen below maintenance margin.
     *         When oracle is set, equity = collateral + unrealizedPnL(currentPrice).
     *         When oracle is not set or entryPrice is zero, falls back to snapshot collateral.
     */
    function isLiquidatable(bytes32 positionId) external view override returns (bool) {
        LiqSnapshot storage snap = snapshots[positionId];
        if (snap.trader == address(0)) return false;
        // Minimum 1-block delay
        if (block.number <= snap.openBlock) return false;

        uint256 maintenanceMargin = snap.notional * MAINTENANCE_MARGIN_BPS / BPS_DENOM;
        return _currentEquity(snap) < int256(maintenanceMargin);
    }

    /**
     * @notice Liquidate an underwater position.
     *         Anyone can call this when isLiquidatable() returns true.
     *         Penalty: 1% of notional → 50% to caller, 50% to InsuranceFund.
     */
    function liquidate(bytes32 positionId) external override nonReentrant whenNotPaused {
        LiqSnapshot storage snap = snapshots[positionId];
        require(snap.trader != address(0), "LiquidationEngine: position not found");
        require(block.number > snap.openBlock, "LiquidationEngine: too soon (1-block delay)");

        uint256 maintenanceMargin = snap.notional * MAINTENANCE_MARGIN_BPS / BPS_DENOM;
        require(_currentEquity(snap) < int256(maintenanceMargin), "LiquidationEngine: position healthy");

        uint256 available     = snap.collateral;

        // Compute shares directly from notional to avoid divide-before-multiply precision loss
        // insuranceShare  = notional * penaltyBps * splitBps / (BPS_DENOM^2)
        // liquidatorShare = notional * penaltyBps / BPS_DENOM - insuranceShare
        uint256 penalty       = snap.notional * LIQUIDATION_PENALTY_BPS / BPS_DENOM;

        // Cap penalty to available collateral before splitting
        if (penalty > available) penalty = available;

        uint256 insuranceShare  = snap.notional * LIQUIDATION_PENALTY_BPS * INSURANCE_SPLIT_BPS
                                  / (BPS_DENOM * BPS_DENOM);
        // Cap insurance share proportionally if penalty was capped
        if (insuranceShare > penalty / 2) insuranceShare = penalty / 2;
        uint256 liquidatorShare = penalty - insuranceShare;
        uint256 remaining       = available - penalty;

        address trader          = snap.trader;
        address collateralToken = snap.collateralToken;

        // Clear snapshot first (re-entrancy protection)
        delete snapshots[positionId];

        // Return remaining collateral to trader
        if (remaining > 0) {
            vault.unlockCollateral(trader, collateralToken, remaining);
        }

        // Send liquidator share
        if (liquidatorShare > 0) {
            vault.transferCollateral(trader, msg.sender, collateralToken, liquidatorShare);
        }

        // Send insurance share — vault transfers to InsuranceFund address
        // (InsuranceFund.receiveFromLiquidation pulls from vault via approve flow)
        if (insuranceShare > 0) {
            vault.transferCollateral(trader, address(insuranceFund), collateralToken, insuranceShare);
        }

        emit Liquidated(
            positionId,
            msg.sender,
            trader,
            penalty,
            liquidatorShare,
            insuranceShare,
            block.timestamp
        );
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /**
     * @notice Compute current economic equity for a snapshot.
     *         equity = collateral + unrealizedPnL(currentOraclePrice)
     *
     *         Fallback to snapshot collateral when:
     *           - oracle is not yet set (address(oracle) == 0)
     *           - entryPrice is zero (snapshot predates oracle integration)
     *           - oracle returns zero price (stale or broken feed)
     */
    function _currentEquity(LiqSnapshot storage snap) internal view returns (int256) {
        if (address(oracle) == address(0) || snap.entryPrice == 0) {
            return int256(snap.collateral);
        }
        uint256 currentPrice = oracle.getIndexPrice(snap.asset);
        if (currentPrice == 0) return int256(snap.collateral);

        int256 priceDelta    = int256(currentPrice) - int256(snap.entryPrice);
        int256 unrealizedPnl = priceDelta * int256(snap.notional) / int256(snap.entryPrice);
        if (!snap.isLong) unrealizedPnl = -unrealizedPnl;
        return int256(snap.collateral) + unrealizedPnl;
    }
}
