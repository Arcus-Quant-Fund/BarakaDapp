// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/FundingEngine.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/CollateralVault.sol";
import "../../src/core/LiquidationEngine.sol";
import "../../src/insurance/InsuranceFund.sol";
import "../../src/shariah/ShariahGuard.sol";
import "../mocks/MockOracle.sol";
import "../mocks/MockERC20.sol";

/**
 * @title BarakaIntegrationTest
 * @notice End-to-end integration tests covering the full Baraka Protocol lifecycle.
 *
 * System under test (all 8 contracts wired together):
 *   ShariahGuard → FundingEngine → InsuranceFund → CollateralVault
 *   → LiquidationEngine → PositionManager → GovernanceModule (not tested here)
 *
 * Test categories:
 *   1. Full position lifecycle  — deposit → open → settle funding → close → withdraw
 *   2. Funding mechanics        — long pays when mark > index; short receives
 *   3. Liquidation flow         — funding erodes collateral below 2% → liquidate
 *   4. Shariah guard gate       — non-compliant positions always rejected
 *   5. Emergency controls       — Shariah pause and protocol pause block trading
 *   6. Edge cases               — total loss, withdrawal cooldown
 */
contract BarakaIntegrationTest is Test {

    // ─────────────────────────────────────────────────────
    // System contracts
    // ─────────────────────────────────────────────────────

    ShariahGuard      public guard;
    FundingEngine     public engine;
    InsuranceFund     public insurance;
    CollateralVault   public vault;
    LiquidationEngine public liqEngine;
    PositionManager   public pm;
    MockOracle        public oracle;

    // ─────────────────────────────────────────────────────
    // Test tokens / market IDs
    // ─────────────────────────────────────────────────────

    MockERC20 public usdc; // 6-decimal collateral token
    address   public wbtc = address(0x00B1C); // market identifier (no ERC-20 needed for market ID)

    // ─────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────

    address public owner        = address(0xABCD);
    address public shariahBoard = address(0xBEEF);
    address public trader       = address(0xCAFE);
    address public liquidator   = address(0xD00D);

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    string  constant FATWA          = "ipfs://QmFatwaTestHash";
    uint256 constant BTC_PRICE      = 50_000e18; // $50,000 in 1e18

    // Funding rate constants (mirror FundingEngine)
    int256  constant MAX_RATE       = 75e14;   // 0.75% per interval
    uint256 constant INTERVAL       = 1 hours;

    // ─────────────────────────────────────────────────────
    // setUp — deploy + wire the full system
    // ─────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy all infrastructure
        usdc      = new MockERC20("USD Coin", "USDC", 6);
        oracle    = new MockOracle();
        guard     = new ShariahGuard(shariahBoard);
        engine    = new FundingEngine(owner, address(oracle));
        insurance = new InsuranceFund(owner);
        vault     = new CollateralVault(owner, address(guard));
        liqEngine = new LiquidationEngine(owner, address(insurance), address(vault));
        pm        = new PositionManager(
            owner,
            address(guard),
            address(engine),
            address(oracle),
            address(vault),
            address(liqEngine),
            address(insurance)
        );

        // 2. Wire authorisations
        vault.setAuthorised(address(pm),        true);
        vault.setAuthorised(address(liqEngine), true);
        insurance.setAuthorised(address(pm),        true); // PM routes funding costs to InsuranceFund on close
        insurance.setAuthorised(address(liqEngine), true);
        liqEngine.setPositionManager(address(pm));
        liqEngine.setOracle(address(oracle));

        vm.stopPrank();

        // 3. Shariah board approves assets
        vm.startPrank(shariahBoard);
        guard.approveAsset(address(usdc), FATWA); // collateral token approval
        guard.approveAsset(wbtc,          FATWA); // market approval
        vm.stopPrank();

        // 4. Seed oracle prices (BTC = $50,000, mark = index → F = 0)
        oracle.setIndexPrice(wbtc, BTC_PRICE);
        oracle.setMarkPrice(wbtc,  BTC_PRICE);
    }

    // ─────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────

    /// @dev Mint USDC to trader and deposit into vault.
    function _depositForTrader(uint256 amount) internal {
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();
    }

    /// @dev Open a position as trader, return positionId.
    function _openPosition(
        uint256 collateral,
        uint256 leverage,
        bool    isLong
    ) internal returns (bytes32 positionId) {
        vm.prank(trader);
        positionId = pm.openPosition(wbtc, address(usdc), collateral, leverage, isLong);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 1. FULL POSITION LIFECYCLE — no funding, no PnL
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Complete happy path: deposit → open → close → withdraw.
     *
     * Conditions: mark == index throughout (F = 0), price unchanged.
     * Expected: trader gets back exactly the deposited collateral.
     */
    function test_FullLifecycle_NoFundingNoPnl() public {
        uint256 collateral = 1_000e6; // 1,000 USDC

        // ── Deposit ──
        _depositForTrader(collateral);
        assertEq(vault.freeBalance(trader, address(usdc)), collateral, "free after deposit");

        // ── Open 3x long ──
        bytes32 posId = _openPosition(collateral, 3, true);

        // Collateral moves from free → locked
        assertEq(vault.freeBalance(trader,   address(usdc)), 0,          "free after open");
        assertEq(vault.lockedBalance(trader, address(usdc)), collateral, "locked after open");

        // Position is recorded
        PositionManager.Position memory pos = pm.getPosition(posId);
        assertTrue(pos.open,                 "position open");
        assertEq(pos.trader,    trader,      "correct trader");
        assertEq(pos.size,      3_000e6,     "notional = 3x collateral");
        assertEq(pos.entryPrice, BTC_PRICE,  "entry price from oracle");
        assertTrue(pos.isLong,               "is long");

        // ── Advance time past 24h cooldown — no funding (mark == index) ──
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);

        // ── Close position ──
        vm.prank(trader);
        pm.closePosition(posId);

        // Position marked closed
        PositionManager.Position memory closed = pm.getPosition(posId);
        assertFalse(closed.open, "position closed");

        // All collateral returned (no PnL, no funding)
        assertEq(vault.freeBalance(trader, address(usdc)), collateral, "full collateral returned");

        // ── Withdraw ──
        vm.prank(trader);
        vault.withdraw(address(usdc), collateral);

        assertEq(vault.freeBalance(trader,   address(usdc)), 0, "free after withdraw");
        assertEq(usdc.balanceOf(trader),                collateral, "USDC back in wallet");
    }

    // ═══════════════════════════════════════════════════════════════════
    // 2. FUNDING MECHANICS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Long position pays funding when mark > index (F > 0).
     *
     * Oracle: index=$50,000 ; mark=$50,300 → premium 0.6% → rate=6e15 (below 75bps cap).
     * After 3 intervals the long's collateral must decrease.
     *
     * Payment = rate × intervals × size / 1e18
     *         = 6e15 × 3 × 3,000e6 / 1e18 = 54e6
     * Remaining collateral = 1,000e6 − 54e6 = 946e6
     */
    function test_LongPaysFundingWhenMarkAboveIndex() public {
        uint256 collateral = 1_000e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 3, true); // size = 3,000e6

        // Set mark 0.6% above index → rate = 6e15 (uncapped)
        oracle.setMarkPrice(wbtc, 50_300e18);

        // Advance exactly 3 intervals
        vm.warp(block.timestamp + 3 * INTERVAL);

        // Settle funding
        vm.prank(trader);
        pm.settleFunding(posId);

        PositionManager.Position memory pos = pm.getPosition(posId);

        // rate = (50300e18 - 50000e18) * 1e18 / 50000e18 = 6e15
        // payment = 6e15 * 3 * 3000e6 / 1e18 = 54e6
        uint256 expectedCollateral = collateral - 54e6;
        assertEq(pos.collateral, expectedCollateral, "long collateral reduced by funding");

        // Cumulative index must be positive (long paid, so index went positive)
        assertGt(engine.cumulativeFundingIndex(wbtc), 0, "cumulative index positive");
    }

    /**
     * @notice Short position RECEIVES funding when mark > index.
     *
     * Same oracle setup as above (mark $50,300). Short counterparty earns
     * what the long paid — collateral should INCREASE.
     *
     * Payment for short = −(rate × intervals × size / 1e18) = −18e6
     * (negative payment → trader receives → collateral increases)
     * Remaining collateral = 500e6 + 18e6 = 518e6
     */
    function test_ShortReceivesFundingWhenMarkAboveIndex() public {
        uint256 collateral = 500e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 2, false); // size = 1,000e6, isLong=false

        // Mark 0.6% above index
        oracle.setMarkPrice(wbtc, 50_300e18);
        vm.warp(block.timestamp + 3 * INTERVAL);

        vm.prank(trader);
        pm.settleFunding(posId);

        PositionManager.Position memory pos = pm.getPosition(posId);

        // rate = 6e15, fundingDelta = 18e15
        // For short: payment = -(18e15 * 1000e6 / 1e18) = -18e6 → collateral += 18e6
        uint256 expectedCollateral = collateral + 18e6;
        assertEq(pos.collateral, expectedCollateral, "short collateral increased by funding");
    }

    /**
     * @notice Multiple partial funding settlements accumulate correctly.
     *
     * Settle after 1 hour, then 2 more hours. Total should equal one 3-hour settlement.
     */
    function test_FundingAccumulatesAcrossMultipleSettlements() public {
        uint256 collateral = 1_000e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 3, true); // size = 3,000e6

        oracle.setMarkPrice(wbtc, 50_300e18); // rate = 6e15

        // First settlement: 1 interval
        vm.warp(block.timestamp + 1 * INTERVAL);
        vm.prank(trader);
        pm.settleFunding(posId);

        PositionManager.Position memory afterFirst = pm.getPosition(posId);
        uint256 collateralAfterOne = collateral - 18e6; // 6e15 * 1 * 3000e6 / 1e18 = 18e6
        assertEq(afterFirst.collateral, collateralAfterOne, "after 1 interval");

        // Second settlement: 2 more intervals
        vm.warp(block.timestamp + 2 * INTERVAL);
        vm.prank(trader);
        pm.settleFunding(posId);

        PositionManager.Position memory afterThird = pm.getPosition(posId);
        uint256 expectedFinal = collateral - 54e6; // same as 3 intervals at once
        assertEq(afterThird.collateral, expectedFinal, "cumulative 3 intervals");
    }

    /**
     * @notice Long RECEIVES funding when mark < index (negative funding rate).
     *
     * Oracle: index=$50,000 ; mark=$49,700 → discount 0.6% → rate=−6e15.
     * Long payment = −6e15 × 3 × 3000e6 / 1e18 = −54e6 → collateral increases.
     */
    function test_LongReceivesFundingWhenMarkBelowIndex() public {
        uint256 collateral = 1_000e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 3, true); // size = 3,000e6

        oracle.setMarkPrice(wbtc, 49_700e18); // 0.6% below index
        vm.warp(block.timestamp + 3 * INTERVAL);

        vm.prank(trader);
        pm.settleFunding(posId);

        PositionManager.Position memory pos = pm.getPosition(posId);

        // rate = (49700 - 50000) / 50000 = -6e15
        // For long: payment = -6e15 * 3 * 3000e6 / 1e18 = -54e6 (negative → receives)
        assertEq(pos.collateral, collateral + 54e6, "long collateral increased by negative funding");
    }

    // ═══════════════════════════════════════════════════════════════════
    // 3. LIQUIDATION FLOW
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Full liquidation lifecycle: funding erodes collateral below 2% → liquidate.
     *
     * Setup:
     *   collateral = 200e6  (200 USDC)
     *   leverage   = 5x     → size = 1,000e6
     *   mark       = $100,000 (100% premium, capped to MAX rate = 75e14)
     *
     * After 25 intervals of max-rate funding:
     *   payment = 75e14 × 25 × 1,000e6 / 1e18 = 187.5e6
     *   remaining collateral = 200e6 − 187.5e6 = 12.5e6
     *   maintenance margin  = 1,000e6 × 2% = 20e6
     *   12.5e6 < 20e6 → liquidatable
     *
     * Liquidation:
     *   penalty       = 1,000e6 × 1% = 10e6
     *   liquidator    = 5e6
     *   insurance     = 5e6
     *   returned to trader = 2.5e6
     */
    function test_LiquidationFlow() public {
        uint256 collateral = 200e6;
        _depositForTrader(collateral);

        // Set mark >> index — rate will be capped at MAX_RATE
        oracle.setMarkPrice(wbtc, 100_000e18);

        bytes32 posId = _openPosition(collateral, 5, true); // size = 1,000e6

        // Advance 1 block so the 1-block delay passes
        vm.roll(block.number + 1);

        // Accrue 25 intervals of max-rate funding
        vm.warp(block.timestamp + 25 * INTERVAL + 1);

        // Settle funding — this pushes the updated snapshot to LiquidationEngine
        vm.prank(trader);
        pm.settleFunding(posId);

        // Verify position is now liquidatable
        assertTrue(liqEngine.isLiquidatable(posId), "should be liquidatable after 25 intervals");

        // Record balances before liquidation
        uint256 liquidatorFreeBefore = vault.freeBalance(liquidator, address(usdc));
        uint256 insuranceFreeBefore  = vault.freeBalance(address(insurance), address(usdc));

        // Liquidate
        vm.prank(liquidator);
        liqEngine.liquidate(posId);

        // ── Assertions ──

        // Snapshot cleared
        (address snapTrader,,,,,,,) = liqEngine.snapshots(posId);
        assertEq(snapTrader, address(0), "snapshot cleared after liquidation");

        // Remaining collateral (2.5e6) returned to trader as free balance
        assertEq(
            vault.freeBalance(trader, address(usdc)),
            2_500_000, // 2.5e6
            "remaining collateral returned to trader"
        );

        // Liquidator received share (5e6)
        assertEq(
            vault.freeBalance(liquidator, address(usdc)) - liquidatorFreeBefore,
            5_000_000, // 5e6
            "liquidator received correct share"
        );

        // InsuranceFund received share (5e6) as vault free balance
        assertEq(
            vault.freeBalance(address(insurance), address(usdc)) - insuranceFreeBefore,
            5_000_000, // 5e6
            "insurance fund received correct share"
        );
    }

    /**
     * @notice A healthy position (collateral above maintenance margin) cannot be liquidated.
     */
    function test_HealthyPositionCannotBeLiquidated() public {
        _depositForTrader(1_000e6);
        bytes32 posId = _openPosition(1_000e6, 3, true);

        vm.roll(block.number + 1);

        assertFalse(liqEngine.isLiquidatable(posId), "healthy position should not be liquidatable");

        vm.prank(liquidator);
        vm.expectRevert("LiquidationEngine: position healthy");
        liqEngine.liquidate(posId);
    }

    /**
     * @notice Position cannot be liquidated in the same block it was opened.
     */
    function test_OneBlockDelayPreventsSameBlockLiquidation() public {
        _depositForTrader(200e6);
        oracle.setMarkPrice(wbtc, 100_000e18);
        bytes32 posId = _openPosition(200e6, 5, true);

        // Warp time but NOT roll block — still same block as open
        vm.warp(block.timestamp + 100 hours);
        vm.prank(trader);
        pm.settleFunding(posId);

        // isLiquidatable checks block.number > openBlock — same block → false
        assertFalse(liqEngine.isLiquidatable(posId), "same-block liquidation must be blocked");
    }

    // ═══════════════════════════════════════════════════════════════════
    // 4. SHARIAH GUARD — non-compliant positions always rejected
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Opening a position with an unapproved collateral token is blocked.
     */
    function test_ShariahGuard_BlocksUnapprovedCollateralToken() public {
        address haramToken = address(0xBAD1);
        MockERC20 bad = new MockERC20("Haram Token", "HARAM", 18);
        bad.mint(trader, 1_000e18);

        vm.prank(trader);
        bad.approve(address(vault), 1_000e18);

        // Deposit must fail — token not Shariah-approved
        vm.prank(trader);
        vm.expectRevert("CollateralVault: token not Shariah-approved");
        vault.deposit(address(bad), 1_000e18);
    }

    /**
     * @notice Opening a position with an unapproved market is blocked.
     */
    function test_ShariahGuard_BlocksUnapprovedMarket() public {
        address haramMarket = address(0xBAD2);
        oracle.setIndexPrice(haramMarket, BTC_PRICE);
        oracle.setMarkPrice(haramMarket,  BTC_PRICE);

        _depositForTrader(1_000e6);

        vm.prank(trader);
        vm.expectRevert("ShariahGuard: asset not approved");
        pm.openPosition(haramMarket, address(usdc), 1_000e6, 3, true);
    }

    /**
     * @notice Leverage above 5x is always blocked — two layers of enforcement.
     *
     * Layer 1: PositionManager checks `leverage <= 5` before calling ShariahGuard.
     * Layer 2: ShariahGuard.validatePosition checks `notional/collateral <= MAX_LEVERAGE`.
     *
     * Through openPosition the PM check fires first ("PM: leverage out of range").
     * Calling ShariahGuard.validatePosition directly triggers its own Maysir message.
     */
    function test_ShariahGuard_BlocksLeverageAboveFive() public {
        _depositForTrader(1_000e6);

        // ── Layer 1: PositionManager rejects leverage=6 before reaching ShariahGuard ──
        vm.prank(trader);
        vm.expectRevert("PM: leverage out of range");
        pm.openPosition(wbtc, address(usdc), 1_000e6, 6, true);

        // ── Layer 2: ShariahGuard itself rejects notional/collateral > 5 ──
        // Call validatePosition directly (notional = 6x collateral)
        vm.expectRevert("ShariahGuard: leverage exceeds 5x (maysir)");
        guard.validatePosition(wbtc, 1_000e6, 6_000e6);
    }

    /**
     * @notice Exactly 5x leverage is permitted (edge case at the limit).
     */
    function test_ShariahGuard_ExactlyFivexAllowed() public {
        _depositForTrader(1_000e6);

        vm.prank(trader);
        bytes32 posId = pm.openPosition(wbtc, address(usdc), 1_000e6, 5, true);

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertTrue(pos.open, "5x position should be open");
        assertEq(pos.size, 5_000e6, "5x notional correct");
    }

    /**
     * @notice Zero collateral is always rejected.
     */
    function test_ShariahGuard_RejectsZeroCollateral() public {
        _depositForTrader(1_000e6);

        vm.prank(trader);
        vm.expectRevert("PM: zero collateral");
        pm.openPosition(wbtc, address(usdc), 0, 3, true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 5. EMERGENCY CONTROLS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Shariah board emergency pause blocks all trading on that market.
     *
     * After emergencyPause, validatePosition reverts with "ShariahGuard: market paused",
     * which propagates through openPosition. After unpause, trading resumes.
     */
    function test_ShariahBoardEmergencyPauseBlocksTrading() public {
        _depositForTrader(1_000e6);

        // Board pauses the BTC market
        vm.prank(shariahBoard);
        guard.emergencyPause(wbtc, "Scholar issued new fatwa");

        // openPosition must revert
        vm.prank(trader);
        vm.expectRevert("ShariahGuard: market paused");
        pm.openPosition(wbtc, address(usdc), 1_000e6, 3, true);

        // Board unpauses
        vm.prank(shariahBoard);
        guard.unpauseMarket(wbtc);

        // Trading resumes
        vm.prank(trader);
        bytes32 posId = pm.openPosition(wbtc, address(usdc), 1_000e6, 3, true);
        assertTrue(pm.getPosition(posId).open, "position open after unpause");
    }

    /**
     * @notice Unauthorised caller cannot pause a market.
     */
    function test_OnlyShariahBoardCanPauseMarket() public {
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert("ShariahGuard: not Shariah board");
        guard.emergencyPause(wbtc, "malicious pause");
    }

    /**
     * @notice Pausing PositionManager blocks all position opens.
     */
    function test_ProtocolPauseBlocksPositionOpen() public {
        _depositForTrader(1_000e6);

        vm.prank(owner);
        pm.pause();

        vm.prank(trader);
        vm.expectRevert();
        pm.openPosition(wbtc, address(usdc), 1_000e6, 3, true);

        // Unpause restores functionality
        vm.prank(owner);
        pm.unpause();

        vm.prank(trader);
        bytes32 posId = pm.openPosition(wbtc, address(usdc), 1_000e6, 3, true);
        assertTrue(pm.getPosition(posId).open, "position open after unpause");
    }

    /**
     * @notice Pausing FundingEngine blocks position opens (updateCumulativeFunding fails).
     */
    function test_PausedFundingEngineBlocksPositionOpen() public {
        _depositForTrader(1_000e6);

        vm.prank(owner);
        engine.pause();

        vm.prank(trader);
        vm.expectRevert(); // FundingEngine reverts whenNotPaused
        pm.openPosition(wbtc, address(usdc), 1_000e6, 3, true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 6. COLLATERAL VAULT — withdrawal cooldown
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Withdrawal within 24h of deposit is blocked.
     */
    function test_WithdrawalBlockedDuringCooldown() public {
        _depositForTrader(1_000e6);

        // Try to withdraw immediately
        vm.prank(trader);
        vm.expectRevert("CollateralVault: withdrawal cooldown active");
        vault.withdraw(address(usdc), 1_000e6);
    }

    /**
     * @notice Withdrawal succeeds after 24h cooldown has elapsed.
     */
    function test_WithdrawalSucceedsAfterCooldown() public {
        _depositForTrader(1_000e6);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(trader);
        vault.withdraw(address(usdc), 1_000e6);

        assertEq(usdc.balanceOf(trader), 1_000e6, "USDC returned after cooldown");
    }

    /**
     * @notice Emergency withdrawal (vault paused) bypasses the cooldown.
     */
    function test_EmergencyWithdrawalBypassesCooldown() public {
        _depositForTrader(1_000e6);

        // Owner pauses vault (emergency state)
        vm.prank(owner);
        vault.pause();

        // 72h must elapse before emergency exit is available
        vm.warp(block.timestamp + 72 hours);

        // Trader can withdraw after 72h without the normal 24h deposit cooldown
        vm.prank(trader);
        vault.withdraw(address(usdc), 1_000e6);

        assertEq(usdc.balanceOf(trader), 1_000e6, "emergency withdrawal succeeded");
    }

    // ═══════════════════════════════════════════════════════════════════
    // 7. EDGE CASES
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice When realised loss exceeds collateral, trader receives 0 (total loss).
     *
     * Short position, price rises 50%:
     *   entryPrice = $50,000 ; exitPrice = $75,000
     *   size       = 5x × 100e6 = 500e6
     *   pnl        = −(25,000e18 × 500e6 / 50,000e18) = −250e6 (for short)
     *   finalCollateral = 100e6 − 250e6 = −150e6 (negative)
     *   → vault.unlockCollateral(trader, usdc, 0)
     */
    function test_TotalLossShortPositionPriceRises50Percent() public {
        uint256 collateral = 100e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 5, false); // short, size=500e6

        // Price rises 50% against the short
        oracle.setIndexPrice(wbtc, 75_000e18);

        // Warp past 24h so close doesn't hit other issues; roll to next block for same-block guard
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);

        vm.prank(trader);
        pm.closePosition(posId);

        // Trader gets 0 back (total loss)
        assertEq(vault.freeBalance(trader, address(usdc)), 0, "total loss: trader gets nothing");
    }

    /**
     * @notice Closing a profitable long position returns collateral (PnL not paid in MVP).
     *
     * Price rises 10%: pnl = (5000e18 × 3000e6) / 50000e18 = +300e6.
     * finalCollateral = 1000e6 + 300e6 > 0 → vault.unlockCollateral(trader, usdc, pos.collateral).
     *
     * IMPORTANT: mark price is updated to match new index so no funding accrues between
     * open and close (0 complete intervals elapsed). The vault's locked balance (1000e6)
     * therefore exactly covers the unlock amount.
     */
    function test_ProfitableLongClosedReturnsCollateral() public {
        uint256 collateral = 1_000e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 3, true); // size = 3000e6

        // Price rises 10% — update BOTH index and mark so F=0 (no funding between open/close)
        oracle.setIndexPrice(wbtc, 55_000e18);
        oracle.setMarkPrice(wbtc,  55_000e18);
        // Roll to next block for same-block close guard; no warp needed (no funding = 0 intervals)
        vm.roll(block.number + 1);

        vm.prank(trader);
        pm.closePosition(posId);

        // finalCollateral = 1000e6 + 300e6 = 1300e6 → netReturn=1300e6 > initialCollateral=1000e6
        // InsuranceFund.payPnl(300e6, trader) is called — IF has 0 balance so pays 0 silently.
        // Trader keeps initialCollateral=1000e6 in vault free; profit paid when IF is seeded.
        assertEq(
            vault.freeBalance(trader, address(usdc)),
            collateral,
            "initialCollateral returned to vault free on profitable close; profit from IF when funded"
        );
    }

    /**
     * @notice Unrealised PnL view function is correct after a price move.
     *
     * Long 3x, price +10%:
     *   pnl = 5000e18 × 3000e6 / 50000e18 = 300e6
     */
    function test_UnrealisedPnlComputedCorrectly() public {
        uint256 collateral = 1_000e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 3, true); // size=3000e6

        // Price rises 10%
        oracle.setIndexPrice(wbtc, 55_000e18);

        int256 pnl = pm.getUnrealizedPnl(posId);
        // (55000e18 - 50000e18) * 3000e6 / 50000e18 = 5000e18 * 3000e6 / 50000e18 = 300e6
        assertEq(pnl, 300e6, "unrealised PnL for long +10%");
    }

    /**
     * @notice Unrealised PnL is negative when price falls for a long.
     */
    function test_UnrealisedPnlNegativeForLongOnPriceDrop() public {
        uint256 collateral = 1_000e6;
        _depositForTrader(collateral);
        bytes32 posId = _openPosition(collateral, 3, true);

        // Price falls 10%
        oracle.setIndexPrice(wbtc, 45_000e18);

        int256 pnl = pm.getUnrealizedPnl(posId);
        // (-5000e18 * 3000e6) / 50000e18 = -300e6
        assertEq(pnl, -300e6, "unrealised PnL negative for long -10%");
    }

    /**
     * @notice Unrealised PnL is zero for a closed position.
     */
    function test_UnrealisedPnlZeroAfterClose() public {
        _depositForTrader(1_000e6);
        bytes32 posId = _openPosition(1_000e6, 3, true);

        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
        vm.prank(trader);
        pm.closePosition(posId);

        assertEq(pm.getUnrealizedPnl(posId), 0, "PnL zero after close");
    }

    // ═══════════════════════════════════════════════════════════════════
    // 8. GOVERNANCE — Shariah board controls
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Shariah board can revoke a previously approved asset.
     * After revocation, new deposits of that token are blocked.
     */
    function test_ShariahBoardCanRevokeAsset() public {
        // Approve then revoke USDC
        vm.prank(shariahBoard);
        guard.revokeAsset(address(usdc), "New fatwa prohibits stablecoin collateral");

        assertFalse(guard.approvedAssets(address(usdc)), "USDC revoked");

        // Deposit must now fail
        usdc.mint(trader, 1_000e6);
        vm.prank(trader);
        usdc.approve(address(vault), 1_000e6);

        vm.prank(trader);
        vm.expectRevert("CollateralVault: token not Shariah-approved");
        vault.deposit(address(usdc), 1_000e6);
    }

    /**
     * @notice Only the Shariah board can approve assets.
     */
    function test_OnlyShariahBoardCanApproveAsset() public {
        address newToken = address(0x9999);
        address attacker = address(0xDEAD);

        vm.prank(attacker);
        vm.expectRevert("ShariahGuard: not Shariah board");
        guard.approveAsset(newToken, FATWA);
    }

    /**
     * @notice Only the vault owner can add authorised callers.
     */
    function test_OnlyOwnerCanSetAuthorisedCaller() public {
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert();
        vault.setAuthorised(attacker, true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 9. FUZZ — cross-contract invariants
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Fuzz: opening any position always passes ShariahGuard when leverage ∈ [1, 5]
     *         and the collateral token and market are pre-approved.
     */
    function testFuzz_ValidPositionAlwaysOpens(
        uint256 collateralSeed,
        uint256 leverageSeed
    ) public {
        uint256 collateral = bound(collateralSeed, 1e6, 100_000e6); // 1 to 100k USDC
        uint256 leverage   = bound(leverageSeed,  1,   5);

        _depositForTrader(collateral);

        vm.prank(trader);
        bytes32 posId = pm.openPosition(wbtc, address(usdc), collateral, leverage, true);
        assertTrue(pm.getPosition(posId).open, "fuzz: valid position opened");
    }

    /**
     * @notice Fuzz: leverage > 5 always reverts regardless of collateral amount.
     */
    function testFuzz_LeverageAboveFiveAlwaysReverts(
        uint256 collateralSeed,
        uint256 leverageSeed
    ) public {
        uint256 collateral = bound(collateralSeed, 1e6, 100_000e6);
        uint256 leverage   = bound(leverageSeed,  6,   100);

        _depositForTrader(collateral);

        vm.prank(trader);
        vm.expectRevert();
        pm.openPosition(wbtc, address(usdc), collateral, leverage, true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // 10. PRODUCTION HARDENING — Session 14
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Closing a position in the same block it was opened must revert.
     *
     * The same-block guard mirrors the LiquidationEngine's one-block delay:
     * a flash-loan attacker cannot open and close in one transaction to
     * extract funding payments or manipulate accounting.
     */
    function test_closePosition_sameBlockReverts() public {
        _depositForTrader(1_000e6);
        bytes32 posId = _openPosition(1_000e6, 3, true);

        // Same block — no vm.roll — must revert
        vm.prank(trader);
        vm.expectRevert("PM: same-block close");
        pm.closePosition(posId);
    }

    /**
     * @notice Extreme funding over 28h drains collateral to 0, making
     *         the position liquidatable on the next block.
     *
     * Setup:
     *   collateral = 100e6  (100 USDC)
     *   leverage   = 5x     → size = 500e6
     *   mark       = $100,000 (100% premium → capped to MAX_RATE = 75e14)
     *
     * After 28 intervals of max-rate funding:
     *   payment = 75e14 × 28 × 500e6 / 1e18 = 105e6
     *   remaining collateral = max(100e6 − 105e6, 0) = 0
     *   maintenance margin  = 500e6 × 2% = 10e6
     *   0 < 10e6 → liquidatable
     */
    function test_ZeroCollateralBecomesLiquidatable() public {
        uint256 collateral = 100e6;
        _depositForTrader(collateral);

        oracle.setMarkPrice(wbtc, 100_000e18); // mark >> index → MAX_RATE

        bytes32 posId = _openPosition(collateral, 5, true); // size = 500e6

        // Accrue 28 intervals of max-rate funding — drains collateral to 0
        vm.warp(block.timestamp + 28 * INTERVAL + 1);
        vm.prank(trader);
        pm.settleFunding(posId);

        // Verify collateral drained to zero
        PositionManager.Position memory pos = pm.getPosition(posId);
        assertEq(pos.collateral, 0, "collateral drained to zero by extreme funding");

        // Roll to next block so liquidatability check passes
        vm.roll(block.number + 1);

        // Position is now liquidatable
        assertTrue(liqEngine.isLiquidatable(posId), "zero-collateral position must be liquidatable");
    }
}
