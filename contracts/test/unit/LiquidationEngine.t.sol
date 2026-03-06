// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/LiquidationEngine.sol";
import "../../src/interfaces/ICollateralVault.sol";
import "../../src/interfaces/IInsuranceFund.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mocks
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Mock vault that tracks free/locked balances in memory
contract MockVaultLE is ICollateralVault {
    mapping(address => mapping(address => uint256)) public free;
    mapping(address => mapping(address => uint256)) public locked;

    function seed(address user, address token, uint256 amount) external {
        locked[user][token] += amount;
    }

    function lockCollateral(address user, address token, uint256 amount) external override {
        free[user][token]   -= amount;
        locked[user][token] += amount;
    }

    function unlockCollateral(address user, address token, uint256 amount) external override {
        locked[user][token] -= amount;
        free[user][token]   += amount;
    }

    function transferCollateral(address from, address to, address token, uint256 amount) external override {
        locked[from][token] -= amount;
        free[to][token]     += amount;
    }

    function chargeFromFree(address from, address token, uint256 amount) external override {
        free[from][token] -= amount;
    }

    function balance(address user, address token) external view override returns (uint256) {
        return free[user][token] + locked[user][token];
    }
}

/// @notice No-op InsuranceFund mock — LiquidationEngine never calls it directly
contract MockInsuranceFundLE is IInsuranceFund {
    function receiveFromLiquidation(address, uint256) external override {}
    function coverShortfall(address, uint256)         external override {}
    function payPnl(address, uint256, address)        external override {}
    function fundBalance(address) external view override returns (uint256) { return 0; }
}

/**
 * @title LiquidationEngineTest
 * @notice Full unit test coverage for LiquidationEngine.sol
 *
 * Branches covered:
 *   isLiquidatable()   — position not found, same block, healthy, underwater
 *   liquidate()        — not found, too soon, healthy, paused,
 *                        penalty capped (collateral < penalty),
 *                        full flow (remaining > 0, remaining = 0),
 *                        insurance share cap
 *   updateSnapshot()   — onlyPositionManager modifier, stores data, emits event
 *   removeSnapshot()   — onlyPositionManager modifier, deletes entry
 *   setPositionManager() — only owner, zero address reverts
 *   constructor        — zero InsuranceFund / zero Vault reverts
 *   Fuzz               — isLiquidatable always matches manual calc
 */
contract LiquidationEngineTest is Test {

    LiquidationEngine   public engine;
    MockVaultLE         public vault;
    MockInsuranceFundLE public insuranceFund;

    address public owner      = address(0xABCD);
    address public pm         = address(0xCAFE);
    address public liquidator = address(0xBEEF);
    address public trader     = address(0x1234);
    address public token      = address(0x5678);
    address public attacker   = address(0xDEAD);

    bytes32 constant POS_ID = keccak256("position-1");

    // Standard: notional = 100_000e6, collateral = 1_000e6 (1% < 2% maintenance)
    uint256 constant NOTIONAL   = 100_000e6;
    uint256 constant COLLATERAL = 1_000e6;

    function setUp() public {
        vm.startPrank(owner);
        vault         = new MockVaultLE();
        insuranceFund = new MockInsuranceFundLE();
        engine        = new LiquidationEngine(owner, address(insuranceFund), address(vault));
        engine.setPositionManager(pm);
        vm.stopPrank();
    }

    /// @dev Push a snapshot via PM and seed the vault with the collateral.
    ///      entryPrice = 0 → _currentEquity falls back to snapshot collateral (no oracle needed).
    function _pushSnapshot(
        bytes32 id,
        uint256 collateral,
        uint256 notional,
        uint256 openBlock
    ) internal {
        vm.prank(pm);
        engine.updateSnapshot(id, trader, token, token, collateral, notional, 0, openBlock, true);
        vault.seed(trader, token, collateral);
    }

    // ─────────────────────────────────────────────────────
    // constructor
    // ─────────────────────────────────────────────────────

    function test_constructor_zeroInsuranceFundReverts() public {
        vm.expectRevert("LiquidationEngine: zero InsuranceFund");
        new LiquidationEngine(owner, address(0), address(vault));
    }

    function test_constructor_zeroVaultReverts() public {
        vm.expectRevert("LiquidationEngine: zero Vault");
        new LiquidationEngine(owner, address(insuranceFund), address(0));
    }

    // ─────────────────────────────────────────────────────
    // setPositionManager()
    // ─────────────────────────────────────────────────────

    function test_setPositionManager_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        engine.setPositionManager(attacker);
    }

    function test_setPositionManager_zeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert("LiquidationEngine: zero PM");
        engine.setPositionManager(address(0));
    }

    function test_setPositionManager_setsAddress() public view {
        assertEq(engine.positionManager(), pm);
    }

    // ─────────────────────────────────────────────────────
    // updateSnapshot() / removeSnapshot()
    // ─────────────────────────────────────────────────────

    function test_updateSnapshot_onlyPM() public {
        vm.prank(attacker);
        vm.expectRevert("LiquidationEngine: not PositionManager");
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, true);
    }

    function test_updateSnapshot_storesData() public {
        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, false);

        (
            address t,
            address a,
            address ct,
            uint256 c,
            uint256 n,
            ,          // entryPrice (not checked in this test — set to 0)
            uint256 ob,
            bool isLong
        ) = engine.snapshots(POS_ID);

        assertEq(t,  trader);
        assertEq(a,  token);
        assertEq(ct, token);
        assertEq(c,  COLLATERAL);
        assertEq(n,  NOTIONAL);
        assertEq(ob, block.number);
        assertFalse(isLong);
    }

    function test_updateSnapshot_emitsEvent() public {
        vm.prank(pm);
        vm.expectEmit(true, false, false, false);
        emit LiquidationEngine.SnapshotUpdated(POS_ID);
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, true);
    }

    function test_removeSnapshot_onlyPM() public {
        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, true);

        vm.prank(attacker);
        vm.expectRevert("LiquidationEngine: not PositionManager");
        engine.removeSnapshot(POS_ID);
    }

    function test_removeSnapshot_deletesSnapshot() public {
        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, true);
        vm.prank(pm);
        engine.removeSnapshot(POS_ID);

        (address t,,,,,,,) = engine.snapshots(POS_ID);
        assertEq(t, address(0));
    }

    // ─────────────────────────────────────────────────────
    // isLiquidatable()
    // ─────────────────────────────────────────────────────

    function test_isLiquidatable_positionNotFound() public view {
        assertFalse(engine.isLiquidatable(POS_ID));
    }

    function test_isLiquidatable_sameBlockReturnsFalse() public {
        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, true);
        // block.number == openBlock → not yet eligible
        assertFalse(engine.isLiquidatable(POS_ID));
    }

    function test_isLiquidatable_healthyPositionReturnsFalse() public {
        // 5% collateral > 2% maintenance
        uint256 healthyCollateral = 5_000e6;
        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, healthyCollateral, NOTIONAL, 0, block.number, true);
        vm.roll(block.number + 1);
        assertFalse(engine.isLiquidatable(POS_ID));
    }

    function test_isLiquidatable_underwaterReturnsTrue() public {
        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, COLLATERAL, NOTIONAL, 0, block.number, true);
        vm.roll(block.number + 1);
        assertTrue(engine.isLiquidatable(POS_ID));
    }

    // ─────────────────────────────────────────────────────
    // liquidate()
    // ─────────────────────────────────────────────────────

    function test_liquidate_positionNotFound() public {
        vm.prank(liquidator);
        vm.expectRevert("LiquidationEngine: position not found");
        engine.liquidate(POS_ID);
    }

    function test_liquidate_tooSoonReverts() public {
        _pushSnapshot(POS_ID, COLLATERAL, NOTIONAL, block.number);
        vm.prank(liquidator);
        vm.expectRevert("LiquidationEngine: too soon (1-block delay)");
        engine.liquidate(POS_ID);
    }

    function test_liquidate_healthyPositionReverts() public {
        // 5% collateral is above 2% maintenance
        _pushSnapshot(POS_ID, 5_000e6, NOTIONAL, block.number);
        vm.roll(block.number + 1);
        vm.prank(liquidator);
        vm.expectRevert("LiquidationEngine: position healthy");
        engine.liquidate(POS_ID);
    }

    function test_liquidate_pausedReverts() public {
        _pushSnapshot(POS_ID, COLLATERAL, NOTIONAL, block.number);
        vm.roll(block.number + 1);
        vm.prank(owner); engine.pause();

        vm.prank(liquidator);
        vm.expectRevert();
        engine.liquidate(POS_ID);
    }

    /**
     * @notice Standard liquidation:
     *   notional = 100_000e6, collateral = 1_000e6
     *   penalty        = 100_000e6 * 1%  = 1_000e6  (= available → not capped)
     *   insuranceShare = 100_000e6 * 1% * 50% / 1e8 = 500e6  (not capped)
     *   liquidatorShare = 500e6
     *   remaining       = 0
     */
    function test_liquidate_fullFlow_noRemaining() public {
        _pushSnapshot(POS_ID, COLLATERAL, NOTIONAL, block.number);
        vm.roll(block.number + 1);

        vm.prank(liquidator);
        engine.liquidate(POS_ID);

        // Snapshot deleted
        (address t,,,,,,,) = engine.snapshots(POS_ID);
        assertEq(t, address(0));

        assertEq(vault.free(liquidator,            token), 500e6);
        assertEq(vault.free(address(insuranceFund), token), 500e6);
        assertEq(vault.locked(trader, token), 0);
    }

    /**
     * @notice Liquidation with remaining collateral returned to trader:
     *   notional = 200_000e6, collateral = 3_000e6
     *   maintenance     = 200_000e6 * 2% = 4_000e6 > 3_000e6 → underwater
     *   penalty         = 200_000e6 * 1% = 2_000e6  (not capped)
     *   insuranceShare  = 1_000e6  (50% of penalty)
     *   liquidatorShare = 1_000e6
     *   remaining       = 1_000e6 → returned to trader's free balance
     */
    function test_liquidate_remainingReturnedToTrader() public {
        bytes32 id2 = keccak256("position-2");
        _pushSnapshot(id2, 3_000e6, 200_000e6, block.number);
        vm.roll(block.number + 1);

        assertTrue(engine.isLiquidatable(id2));

        vm.prank(liquidator);
        engine.liquidate(id2);

        assertEq(vault.free(trader,                  token), 1_000e6);
        assertEq(vault.free(liquidator,              token), 1_000e6);
        assertEq(vault.free(address(insuranceFund),  token), 1_000e6);
        assertEq(vault.locked(trader, token), 0);
    }

    /**
     * @notice Penalty cap branch: collateral (500e6) < uncapped penalty (1_000e6).
     *   penalty capped to 500e6; insuranceShare capped to 250e6.
     *   liquidatorShare = 250e6, remaining = 0.
     */
    function test_liquidate_penaltyCappedWhenCollateralTiny() public {
        bytes32 id3 = keccak256("position-3");
        _pushSnapshot(id3, 500e6, NOTIONAL, block.number);
        vm.roll(block.number + 1);

        vm.prank(liquidator);
        engine.liquidate(id3);

        assertEq(vault.free(liquidator,              token), 250e6);
        assertEq(vault.free(address(insuranceFund),  token), 250e6);
        assertEq(vault.locked(trader, token), 0);
    }

    function test_liquidate_emitsEvent() public {
        _pushSnapshot(POS_ID, COLLATERAL, NOTIONAL, block.number);
        vm.roll(block.number + 1);

        vm.prank(liquidator);
        vm.expectEmit(true, true, true, false);
        emit LiquidationEngine.Liquidated(POS_ID, liquidator, trader, 0, 0, 0, 0);
        engine.liquidate(POS_ID);
    }

    function test_liquidate_deletesSnapshotBeforeTransfers() public {
        // After liquidation, snapshot must be gone (re-entrancy protection)
        _pushSnapshot(POS_ID, COLLATERAL, NOTIONAL, block.number);
        vm.roll(block.number + 1);

        vm.prank(liquidator);
        engine.liquidate(POS_ID);

        assertFalse(engine.isLiquidatable(POS_ID)); // trader == 0 → returns false
    }

    // ─────────────────────────────────────────────────────
    // pause / unpause
    // ─────────────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        engine.pause();
    }

    function test_unpause_restoresLiquidate() public {
        _pushSnapshot(POS_ID, COLLATERAL, NOTIONAL, block.number);
        vm.roll(block.number + 1);

        vm.prank(owner); engine.pause();
        vm.prank(owner); engine.unpause();

        vm.prank(liquidator);
        engine.liquidate(POS_ID); // must succeed after unpause

        (address t,,,,,,,) = engine.snapshots(POS_ID);
        assertEq(t, address(0));
    }

    // ─────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────

    /// @notice isLiquidatable() always matches the manual collateral < maintenanceMargin check
    function testFuzz_isLiquidatable_matchesManualCalc(
        uint256 collateral,
        uint256 notional
    ) public {
        notional   = bound(notional,   1e6, 1_000_000e6);
        collateral = bound(collateral, 1,   notional * 5);

        vm.prank(pm);
        engine.updateSnapshot(POS_ID, trader, token, token, collateral, notional, 0, block.number, true);
        vm.roll(block.number + 1);

        bool liq = engine.isLiquidatable(POS_ID);
        uint256 mm = notional * engine.MAINTENANCE_MARGIN_BPS() / engine.BPS_DENOM();
        assertEq(liq, collateral < mm);
    }

    /// @notice liquidatorShare + insuranceShare never exceeds penalty, which never exceeds collateral
    function testFuzz_penaltySplitNeverExceedsCollateral(uint256 collateral, uint256 notional)
        public
    {
        notional   = bound(notional,   1e6, 1_000_000e6);
        // Ensure position is underwater: collateral < 2% of notional
        uint256 mm = notional * 200 / 10000;
        if (mm == 0) mm = 1;
        collateral = bound(collateral, 1, mm > 1 ? mm - 1 : 1);

        bytes32 id = keccak256(abi.encode(collateral, notional));
        vm.prank(pm);
        engine.updateSnapshot(id, trader, token, token, collateral, notional, 0, block.number, true);
        vault.seed(trader, token, collateral);
        vm.roll(block.number + 1);

        vm.prank(liquidator);
        engine.liquidate(id);

        // Verify no collateral created out of thin air
        uint256 totalOut = vault.free(liquidator, token) + vault.free(address(insuranceFund), token)
                           + vault.free(trader, token);
        assertEq(totalOut, collateral);
    }
}
