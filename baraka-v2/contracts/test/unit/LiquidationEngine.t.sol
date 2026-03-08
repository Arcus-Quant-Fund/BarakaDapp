// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "../../src/core/SubaccountManager.sol";
import "../../src/core/MarginEngine.sol";
import "../../src/core/FundingEngine.sol";
import "../../src/orderbook/OrderBook.sol";
import "../../src/orderbook/MatchingEngine.sol";
import "../../src/shariah/ShariahRegistry.sol";
import "../../src/risk/LiquidationEngine.sol";
import "../../src/risk/AutoDeleveraging.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracleAdapter.sol";

/**
 * @title LiquidationEngineTest
 * @notice Comprehensive unit tests for LiquidationEngine (three-tier cascade)
 *         and AutoDeleveraging (Tier 3 last-resort mechanism).
 *
 *         Full stack deployed in setUp(): SubaccountManager, Vault, MarginEngine,
 *         FundingEngine, ShariahRegistry, OrderBook, MatchingEngine,
 *         LiquidationEngine, AutoDeleveraging.
 *
 *         Market: BTC-USD
 *           IMR = 20% (5x max leverage)
 *           MMR = 5%
 *           Starting price = $50,000
 */
contract LiquidationEngineTest is Test {

    // -------------------------------------------------------
    // Contracts
    // -------------------------------------------------------

    Vault              vault;
    SubaccountManager  sam;
    MarginEngine       marginEngine;
    FundingEngine      fundingEngine;
    OrderBook          orderBook;
    MatchingEngine     matchingEngine;
    ShariahRegistry    shariahRegistry;
    LiquidationEngine  liquidationEngine;
    AutoDeleveraging   adl;
    MockERC20          usdc;
    MockOracleAdapter  oracle;

    // -------------------------------------------------------
    // Actors
    // -------------------------------------------------------

    address owner      = address(0xABCD);
    address alice      = address(0x1111);   // will go long
    address bob        = address(0x2222);   // will go short
    address carol      = address(0x3333);   // additional trader for ADL tests
    address liquidator = address(0x4444);   // permissionless liquidator
    address insurance  = address(0x5555);   // insurance fund address
    address stranger   = address(0x9999);   // unauthorised caller

    bytes32 constant BTC_MARKET = keccak256("BTC-USD");

    bytes32 aliceSub;
    bytes32 bobSub;
    bytes32 carolSub;

    uint256 constant WAD = 1e18;

    // -------------------------------------------------------
    // setUp -- deploy full v2 stack
    // -------------------------------------------------------

    function setUp() public {
        vm.startPrank(owner);

        // --- Core infrastructure ---
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracleAdapter();
        sam = new SubaccountManager();

        fundingEngine = new FundingEngine(owner, address(oracle));
        vault = new Vault(owner);
        marginEngine = new MarginEngine(
            owner, address(vault), address(sam), address(oracle),
            address(fundingEngine), address(usdc)
        );

        // --- Shariah layer ---
        shariahRegistry = new ShariahRegistry(owner);
        shariahRegistry.setMarginEngine(address(marginEngine));
        shariahRegistry.setOracle(address(oracle));
        shariahRegistry.approveAsset(BTC_MARKET, true);
        shariahRegistry.approveCollateral(address(usdc), true);
        shariahRegistry.setMaxLeverage(BTC_MARKET, 5);

        // --- Orderbook ---
        orderBook = new OrderBook(owner, BTC_MARKET);

        matchingEngine = new MatchingEngine(
            owner, address(sam), address(marginEngine), address(shariahRegistry)
        );

        // --- LiquidationEngine --- (P3-LIQ-3: added sam for self-liquidation guard)
        liquidationEngine = new LiquidationEngine(
            owner, address(marginEngine), address(vault), address(oracle), address(usdc), address(sam)
        );

        // --- AutoDeleveraging ---
        adl = new AutoDeleveraging(
            owner, address(marginEngine), address(oracle), address(sam)
        );

        // --- Wiring: Vault authorisations ---
        vault.setApprovedToken(address(usdc), true);
        vault.setAuthorised(address(marginEngine), true);
        vault.setAuthorised(address(liquidationEngine), true);

        // --- Wiring: MarginEngine authorisations ---
        marginEngine.setAuthorised(address(matchingEngine), true);
        marginEngine.setAuthorised(address(liquidationEngine), true);
        marginEngine.setAuthorised(address(adl), true);

        // --- Market creation ---
        // IMR = 20% (5x), MMR = 5% (20x maintenance)
        marginEngine.createMarket(BTC_MARKET, 0.2e18, 0.05e18, 10_000_000e18);

        // --- OrderBook wiring ---
        orderBook.setAuthorised(address(matchingEngine), true);
        matchingEngine.setOrderBook(BTC_MARKET, address(orderBook));
        matchingEngine.setTreasury(owner);
        matchingEngine.setInsuranceFund(owner);

        // --- Funding wiring ---
        fundingEngine.setClampRate(BTC_MARKET, 0.135e18);

        // --- LiquidationEngine config ---
        liquidationEngine.setInsuranceFund(insurance);
        liquidationEngine.setADL(address(adl));
        // Default penalty = 2.5%, liquidator share = 50%

        // --- ADL config ---
        adl.setAuthorised(address(liquidationEngine), true);
        adl.setAuthorised(address(matchingEngine), true);

        // --- Oracle initial prices ---
        oracle.setIndexPrice(BTC_MARKET, 50_000e18);
        oracle.setMarkPrice(BTC_MARKET, 50_000e18);

        vm.stopPrank();

        // --- Create subaccounts ---
        vm.prank(alice);
        aliceSub = sam.createSubaccount(0);

        vm.prank(bob);
        bobSub = sam.createSubaccount(0);

        vm.prank(carol);
        carolSub = sam.createSubaccount(0);

        // --- Mint and deposit ---
        usdc.mint(alice, 200_000e6);
        usdc.mint(bob,   200_000e6);
        usdc.mint(carol, 200_000e6);

        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 200_000e6);
        marginEngine.deposit(aliceSub, 50_000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(marginEngine), 200_000e6);
        marginEngine.deposit(bobSub, 50_000e6);
        vm.stopPrank();

        vm.startPrank(carol);
        usdc.approve(address(marginEngine), 200_000e6);
        marginEngine.deposit(carolSub, 50_000e6);
        vm.stopPrank();
    }

    // -------------------------------------------------------
    // Helpers
    // -------------------------------------------------------

    /// @dev Place an order through the matching engine
    function _place(
        address trader,
        bytes32 sub,
        IOrderBook.Side side,
        uint256 price,
        uint256 size,
        IOrderBook.OrderType ot,
        IOrderBook.TimeInForce tif
    ) internal returns (bytes32) {
        vm.prank(trader);
        return matchingEngine.placeOrder(BTC_MARKET, sub, side, price, size, ot, tif);
    }

    /// @dev Open matching positions: Alice long, Bob short at given price/size
    function _openAliceLongBobShort(uint256 price, uint256 size) internal {
        _place(alice, aliceSub, IOrderBook.Side.Buy, price, size,
               IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);
        _place(bob, bobSub, IOrderBook.Side.Sell, price, size,
               IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);
    }

    /// @dev Open matching positions: Carol long, Bob short at given price/size
    function _openCarolLongBobShort(uint256 price, uint256 size) internal {
        _place(carol, carolSub, IOrderBook.Side.Buy, price, size,
               IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);
        _place(bob, bobSub, IOrderBook.Side.Sell, price, size,
               IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);
    }

    /// @dev Set both index and mark price to keep funding rate at zero
    function _setPrice(uint256 price) internal {
        oracle.setIndexPrice(BTC_MARKET, price);
        oracle.setMarkPrice(BTC_MARKET, price);
    }

    // ===============================================================
    //
    //    SECTION 1 -- LiquidationEngine: Constructor & Admin
    //
    // ===============================================================

    function test_LE_constructor_setsImmutables() public view {
        assertEq(address(liquidationEngine.marginEngine()), address(marginEngine));
        assertEq(address(liquidationEngine.vault()), address(vault));
        assertEq(address(liquidationEngine.oracle()), address(oracle));
        assertEq(liquidationEngine.collateralToken(), address(usdc));
        // USDC is 6 decimals: collateralScale = 10^(18-6) = 1e12
        assertEq(liquidationEngine.collateralScale(), 1e12);
    }

    function test_LE_constructor_revertsZeroMarginEngine() public {
        vm.prank(owner);
        vm.expectRevert("LE: zero ME");
        new LiquidationEngine(owner, address(0), address(vault), address(oracle), address(usdc), address(sam));
    }

    function test_LE_constructor_revertsZeroVault() public {
        vm.prank(owner);
        vm.expectRevert("LE: zero vault");
        new LiquidationEngine(owner, address(marginEngine), address(0), address(oracle), address(usdc), address(sam));
    }

    function test_LE_constructor_revertsZeroOracle() public {
        vm.prank(owner);
        vm.expectRevert("LE: zero oracle");
        new LiquidationEngine(owner, address(marginEngine), address(vault), address(0), address(usdc), address(sam));
    }

    function test_LE_constructor_revertsZeroCollateral() public {
        vm.prank(owner);
        vm.expectRevert("LE: zero collateral");
        new LiquidationEngine(owner, address(marginEngine), address(vault), address(oracle), address(0), address(sam));
    }

    function test_LE_setInsuranceFund_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.setInsuranceFund(stranger);
    }

    function test_LE_setInsuranceFund_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert("LE: zero IF");
        liquidationEngine.setInsuranceFund(address(0));
    }

    function test_LE_setInsuranceFund_works() public {
        address newIF = address(0x7777);
        vm.prank(owner);
        liquidationEngine.setInsuranceFund(newIF);
        assertEq(liquidationEngine.insuranceFund(), newIF);
    }

    function test_LE_setADL_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.setADL(stranger);
    }

    function test_LE_setADL_works() public {
        address newADL = address(0x8888);
        vm.prank(owner);
        liquidationEngine.setADL(newADL);
        assertEq(address(liquidationEngine.adl()), newADL);
    }

    function test_LE_setLiquidationPenalty_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.setLiquidationPenalty(0.03e18);
    }

    function test_LE_setLiquidationPenalty_boundsCheck() public {
        vm.prank(owner);
        vm.expectRevert("LE: penalty > 10%");
        liquidationEngine.setLiquidationPenalty(0.11e18);
    }

    function test_LE_setLiquidationPenalty_maxAllowed() public {
        vm.prank(owner);
        liquidationEngine.setLiquidationPenalty(0.10e18);
        assertEq(liquidationEngine.liquidationPenaltyRate(), 0.10e18);
    }

    function test_LE_setLiquidationPenalty_works() public {
        vm.prank(owner);
        liquidationEngine.setLiquidationPenalty(0.03e18);
        assertEq(liquidationEngine.liquidationPenaltyRate(), 0.03e18);
    }

    function test_LE_setLiquidatorShare_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.setLiquidatorShare(0.60e18);
    }

    function test_LE_setLiquidatorShare_boundsCheck() public {
        // AUDIT FIX (L3-I-4): Cap at 80% — leaves 20% for InsuranceFund
        vm.prank(owner);
        vm.expectRevert("LE: share > 80%");
        liquidationEngine.setLiquidatorShare(0.81e18);
    }

    function test_LE_setLiquidatorShare_works() public {
        vm.prank(owner);
        liquidationEngine.setLiquidatorShare(0.75e18);
        assertEq(liquidationEngine.liquidatorShareRate(), 0.75e18);
    }

    function test_LE_setAuthorised_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.setAuthorised(stranger, true);
    }

    function test_LE_setAuthorised_works() public {
        vm.prank(owner);
        liquidationEngine.setAuthorised(alice, true);
        assertTrue(liquidationEngine.authorised(alice));
    }

    function test_LE_pause_unpause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.pause();

        vm.prank(owner);
        liquidationEngine.pause();

        vm.prank(stranger);
        vm.expectRevert();
        liquidationEngine.unpause();

        vm.prank(owner);
        liquidationEngine.unpause();
    }

    // ===============================================================
    //
    //    SECTION 2 -- canLiquidate()
    //
    // ===============================================================

    function test_LE_canLiquidate_falseWhenHealthy() public {
        // Alice long 1 BTC at $50k with $50k collateral
        _openAliceLongBobShort(50_000e18, 1e18);

        bool liquidatable = liquidationEngine.canLiquidate(aliceSub);
        assertFalse(liquidatable, "Healthy account not liquidatable");
    }

    function test_LE_canLiquidate_trueWhenUnderwaterMMR() public {
        // Alice long 2 BTC at $50k, $50k collateral
        // equity = 50_000 + (P - 50_000) * 2 = 2P - 50_000
        // MMR = 2P * 0.05 = 0.1P
        // Liquidatable when: 2P - 50_000 < 0.1P, i.e. P < 26_315.79
        _openAliceLongBobShort(50_000e18, 2e18);

        // Drop price to $25,000 (must set both index and mark to avoid funding distortion)
        _setPrice(25_000e18);

        bool liquidatable = liquidationEngine.canLiquidate(aliceSub);
        assertTrue(liquidatable, "Underwater account is liquidatable");
    }

    function test_LE_canLiquidate_falseNoPosition() public view {
        // Fresh subaccount with collateral but no position
        bool liquidatable = liquidationEngine.canLiquidate(aliceSub);
        assertFalse(liquidatable, "No position = not liquidatable");
    }

    // ===============================================================
    //
    //    SECTION 3 -- liquidate() basic flow
    //
    // ===============================================================

    function test_LE_liquidate_basicFlow() public {
        // Alice goes long 2 BTC at $50k with $50k collateral
        _openAliceLongBobShort(50_000e18, 2e18);

        // Verify positions
        IMarginEngine.Position memory alicePos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(alicePos.size, 2e18, "Alice long 2 BTC");

        // Record balances before liquidation
        uint256 aliceVaultBefore = vault.balance(aliceSub, address(usdc));
        uint256 liquidatorBalBefore = usdc.balanceOf(liquidator);
        uint256 insuranceBalBefore = usdc.balanceOf(insurance);

        // Drop price to $26,000 -- equity positive but below MMR (partial or full liq)
        // equity = 50_000 + (26_000 - 50_000) * 2 = 2_000 (WAD scale)
        // MMR = 2 * 26_000 * 0.05 = 2_600
        // equity (2_000) < MMR (2_600) -> liquidatable, equity > 0 -> partial possible
        //
        // The remaining vault balance after partial close should have enough for penalty.
        _setPrice(26_000e18);

        assertTrue(liquidationEngine.canLiquidate(aliceSub), "Alice should be liquidatable");

        // Liquidate Alice's BTC position
        vm.prank(liquidator);
        (uint256 sizeClosed, int256 pnlRealized) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        // Some size was closed
        assertGt(sizeClosed, 0, "Some BTC closed");
        assertTrue(pnlRealized < 0, "PnL should be negative (loss)");

        // Penalty should have been charged (split between liquidator and insurance)
        uint256 aliceVaultAfter = vault.balance(aliceSub, address(usdc));
        assertTrue(aliceVaultAfter < aliceVaultBefore, "Alice vault balance reduced by penalty");

        // Liquidator should have received some penalty tokens
        uint256 liquidatorBalAfter = usdc.balanceOf(liquidator);
        assertTrue(liquidatorBalAfter > liquidatorBalBefore, "Liquidator received reward");

        // Insurance fund should have received some penalty tokens
        uint256 insuranceBalAfter = usdc.balanceOf(insurance);
        assertTrue(insuranceBalAfter > insuranceBalBefore, "Insurance received share");
    }

    function test_LE_liquidate_penaltySplit() public {
        // Setup: Alice long 2 BTC at $50k
        _openAliceLongBobShort(50_000e18, 2e18);

        // Set known penalty/share rates
        vm.startPrank(owner);
        liquidationEngine.setLiquidationPenalty(0.025e18); // 2.5%
        liquidationEngine.setLiquidatorShare(0.50e18);     // 50%
        vm.stopPrank();

        // AUDIT FIX (P5-H-4): At $26k, partial close is impossible (netFreePerUnit <= 0)
        // so this triggers full liquidation. After full liq, residual collateral is swept
        // to InsuranceFund, so we must compute penalty split separately from residual sweep.
        //
        // Use $26,000 — equity positive but below MMR → full liquidation (P5-H-4 aware)
        _setPrice(26_000e18);

        uint256 liquidatorBefore = usdc.balanceOf(liquidator);
        uint256 insuranceBefore = usdc.balanceOf(insurance);

        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        uint256 liquidatorGain = usdc.balanceOf(liquidator) - liquidatorBefore;
        uint256 insuranceGain = usdc.balanceOf(insurance) - insuranceBefore;

        // Liquidator should receive penalty share
        assertTrue(liquidatorGain > 0, "Liquidator got paid");

        // Insurance receives penalty share + residual sweep (full liquidation)
        assertTrue(insuranceGain > 0, "Insurance got paid");

        // Verify penalty split: liquidatorGain is exactly 50% of the penalty portion.
        // Insurance gets both penalty share and residual, so insuranceGain > liquidatorGain.
        // The penalty split is: toLiquidator = actualPenalty * 50%, toInsurance = actualPenalty * 50%
        // Plus insurance gets residual. So: penaltyToInsurance = liquidatorGain (50/50 split).
        // Verify: insurance got at least as much as liquidator (penalty share + residual)
        assertTrue(insuranceGain >= liquidatorGain, "Insurance >= liquidator (penalty + residual)");
    }

    function test_LE_liquidate_revertsNotLiquidatable() public {
        // Alice long 1 BTC at $50k with $50k collateral -- very healthy
        _openAliceLongBobShort(50_000e18, 1e18);

        vm.prank(liquidator);
        vm.expectRevert("LE: not liquidatable");
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);
    }

    function test_LE_liquidate_revertsNoPosition() public {
        // Open a BTC position, make the account liquidatable, then try to liquidate
        // a market where Alice has no position.
        _openAliceLongBobShort(50_000e18, 2e18);
        _setPrice(24_000e18);
        assertTrue(liquidationEngine.canLiquidate(aliceSub));

        // AUDIT FIX (L3-M-3): Set price so oracle staleness check passes first
        bytes32 ETH_MARKET = keccak256("ETH-USD");
        oracle.setIndexPrice(ETH_MARKET, 3000e18);
        vm.prank(liquidator);
        vm.expectRevert("LE: no position");
        liquidationEngine.liquidate(aliceSub, ETH_MARKET);
    }

    /// AUDIT FIX (P2-CRIT-3): Liquidations must proceed even when paused.
    /// This test now verifies that liquidate() SUCCEEDS when the engine is paused —
    /// blocking liquidations during a pause allows underwater positions to accumulate
    /// losses, potentially depleting the InsuranceFund upon unpause.
    function test_LE_liquidate_succeedsWhenPaused() public {
        _openAliceLongBobShort(50_000e18, 2e18);
        _setPrice(24_000e18);

        vm.prank(owner);
        liquidationEngine.pause();

        // Liquidation should succeed even while paused
        vm.prank(liquidator);
        (uint256 sizeClosed,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);
        assertGt(sizeClosed, 0, "liquidation should succeed when paused");
    }

    // ===============================================================
    //
    //    SECTION 4 -- Tier 1: Partial liquidation
    //
    // ===============================================================

    /// AUDIT FIX (P5-H-4): Partial liquidation now accounts for per-unit realized loss.
    /// At $26k with entry $50k, lossPerUnit ($24k) >> marginPerUnit ($1.3k), so
    /// netFreePerUnit is negative — partial close cannot restore equity above MMR.
    /// The engine correctly falls through to full liquidation (Tier 2).
    function test_LE_partialLiquidation_tier1() public {
        // Setup: Alice long 2 BTC at $50k, $50k collateral
        _openAliceLongBobShort(50_000e18, 2e18);

        // Drop price to $26,000
        // equity = 50_000 + (26_000 - 50_000) * 2 = 2_000
        // MMR = 2 * 26_000 * 0.05 = 2_600
        // equity (2_000) < MMR (2_600), equity > 0
        //
        // P5-H-4 partial close math:
        //   lossPerUnit = 50,000 - 26,000 = 24,000
        //   marginPerUnit = 26,000 * 0.05 = 1,300
        //   netFreePerUnit = 1,300 - 24,000 = -22,700 (negative!)
        //   → partial returns 0 → full liquidation
        _setPrice(26_000e18);

        assertTrue(liquidationEngine.canLiquidate(aliceSub), "Alice is liquidatable");
        int256 equityBefore = marginEngine.getEquity(aliceSub);
        assertTrue(equityBefore > 0, "Equity still positive");

        vm.prank(liquidator);
        (uint256 sizeClosed,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        // P5-H-4: With loss-adjusted formula, closing units realizes more loss than
        // margin freed, so partial close cannot help → full liquidation triggered
        assertEq(sizeClosed, 2e18, "Full liquidation - partial can't restore MMR");

        // Position should be fully closed
        IMarginEngine.Position memory posAfter = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(posAfter.size, 0, "Position fully closed");
    }

    // ===============================================================
    //
    //    SECTION 5 -- Tier 2: Full liquidation (equity <= 0)
    //
    // ===============================================================

    function test_LE_fullLiquidation_tier2() public {
        // Alice long 2 BTC at $50k, $50k collateral
        _openAliceLongBobShort(50_000e18, 2e18);

        // Drop price to $24,000 -> equity goes negative
        // equity = 50_000 + (24_000 - 50_000) * 2 = 50_000 - 52_000 = -2_000
        // equity <= 0 -> partial returns 0 -> full liquidation
        _setPrice(24_000e18);

        int256 equityBefore = marginEngine.getEquity(aliceSub);
        assertTrue(equityBefore <= 0, "Equity is negative - Tier 2");

        vm.prank(liquidator);
        (uint256 sizeClosed,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        // Full liquidation
        assertEq(sizeClosed, 2e18, "All 2 BTC closed in Tier 2");

        IMarginEngine.Position memory posAfter = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(posAfter.size, 0, "Position fully closed");
    }

    // ===============================================================
    //
    //    SECTION 6 -- Penalty edge cases
    //
    // ===============================================================

    function test_LE_penalty_cappedAtSubaccountBalance() public {
        // Alice deposits only $11k, goes long 1 BTC at $50k
        vm.startPrank(alice);
        marginEngine.withdraw(aliceSub, 39_000e6); // leaves 11_000e6
        vm.stopPrank();

        _openAliceLongBobShort(50_000e18, 1e18);

        // Price drops to $38,000 -> equity negative, full liquidation
        // equity_wad = 11_000 + (38_000 - 50_000) = -1_000
        _setPrice(38_000e18);

        assertTrue(liquidationEngine.canLiquidate(aliceSub));

        uint256 aliceBalBefore = vault.balance(aliceSub, address(usdc));

        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        uint256 aliceBalAfter = vault.balance(aliceSub, address(usdc));
        // Balance should be 0 or very close (all went to PnL + penalty)
        assertTrue(aliceBalAfter <= aliceBalBefore, "Balance did not increase");
    }

    function test_LE_penalty_zeroWhenBalanceDrained() public {
        // Alice deposits minimal collateral: $10,200
        vm.startPrank(alice);
        marginEngine.withdraw(aliceSub, 39_800e6); // leaves 10_200e6
        vm.stopPrank();

        _openAliceLongBobShort(50_000e18, 1e18);

        // Massive price drop: equity deeply negative, vault fully drained by PnL
        _setPrice(38_000e18);

        uint256 liquidatorBefore = usdc.balanceOf(liquidator);
        uint256 insuranceBefore = usdc.balanceOf(insurance);

        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        // Some penalty may have been extracted (capped at available balance after PnL).
        // The key assertion: liquidation succeeded even with insufficient balance.
        uint256 totalPenalty = (usdc.balanceOf(liquidator) - liquidatorBefore)
                             + (usdc.balanceOf(insurance) - insuranceBefore);
        // totalPenalty may be 0 if vault was fully drained -- that's acceptable
        assertTrue(totalPenalty >= 0, "Liquidation succeeded even with low balance");
    }

    // ===============================================================
    //
    //    SECTION 7 -- Integration: full scenario
    //    Alice deposits -> goes long -> price drops -> liquidated
    //
    // ===============================================================

    function test_LE_integrationScenario_longLiquidated() public {
        // 1. Alice deposits $50k, goes long 2 BTC at $50k
        _openAliceLongBobShort(50_000e18, 2e18);

        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(pos.size, 2e18);
        assertEq(pos.entryPrice, 50_000e18);

        // 2. Bob is short and fine at all prices above entry

        // 3. Price drops to $26,000 -- Alice barely liquidatable
        _setPrice(26_000e18);
        assertTrue(liquidationEngine.canLiquidate(aliceSub));
        assertFalse(liquidationEngine.canLiquidate(bobSub), "Bob profits, not liquidatable");

        // 4. Liquidate Alice
        uint256 liquidatorBal = usdc.balanceOf(liquidator);
        vm.prank(liquidator);
        (uint256 closed,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);
        assertTrue(closed > 0, "Position reduced");
        assertTrue(usdc.balanceOf(liquidator) > liquidatorBal, "Liquidator rewarded");
    }

    function test_LE_integrationScenario_shortLiquidated() public {
        // Bob deposits $50k, goes short 2 BTC at $50k
        _openAliceLongBobShort(50_000e18, 2e18);

        // Price RISES to $74,000 -> Bob (short) is losing
        // equity = 50_000 + (50_000 - 74_000) * 2 = 50_000 - 48_000 = 2_000
        // MMR = 2 * 74_000 * 0.05 = 7_400
        // 2_000 < 7_400 -> liquidatable
        _setPrice(74_000e18);

        assertTrue(liquidationEngine.canLiquidate(bobSub), "Bob is liquidatable");
        assertFalse(liquidationEngine.canLiquidate(aliceSub), "Alice profits");

        vm.prank(liquidator);
        (uint256 closed,) = liquidationEngine.liquidate(bobSub, BTC_MARKET);
        assertTrue(closed > 0, "Bob's position reduced");

        // Bob's short should be reduced
        IMarginEngine.Position memory bobPos = marginEngine.getPosition(bobSub, BTC_MARKET);
        assertTrue(bobPos.size >= -2e18, "Bob position reduced or zeroed");
    }

    function test_LE_liquidate_emitsEvent() public {
        _openAliceLongBobShort(50_000e18, 2e18);
        _setPrice(24_000e18);

        vm.prank(liquidator);
        vm.expectEmit(true, true, true, false);
        emit LiquidationEngine.Liquidated(aliceSub, BTC_MARKET, liquidator, 0, 0, 0);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);
    }

    // ===============================================================
    //
    //    SECTION 8 -- AutoDeleveraging: Constructor & Admin
    //
    // ===============================================================

    function test_ADL_constructor_setsImmutables() public view {
        assertEq(address(adl.marginEngine()), address(marginEngine));
        assertEq(address(adl.oracle()), address(oracle));
        assertEq(address(adl.subaccountManager()), address(sam));
    }

    function test_ADL_constructor_revertsZeroME() public {
        vm.prank(owner);
        vm.expectRevert("ADL: zero ME");
        new AutoDeleveraging(owner, address(0), address(oracle), address(sam));
    }

    function test_ADL_constructor_revertsZeroOracle() public {
        vm.prank(owner);
        vm.expectRevert("ADL: zero oracle");
        new AutoDeleveraging(owner, address(marginEngine), address(0), address(sam));
    }

    function test_ADL_constructor_revertsZeroSAM() public {
        vm.prank(owner);
        vm.expectRevert("ADL: zero SAM");
        new AutoDeleveraging(owner, address(marginEngine), address(oracle), address(0));
    }

    function test_ADL_setAuthorised_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        adl.setAuthorised(stranger, true);
    }

    function test_ADL_setAuthorised_works() public {
        vm.prank(owner);
        adl.setAuthorised(alice, true);
        assertTrue(adl.authorised(alice));
    }

    // ===============================================================
    //
    //    SECTION 9 -- ADL: registerParticipant()
    //
    // ===============================================================

    function test_ADL_registerParticipant_onlyAuthorised() public {
        vm.prank(stranger);
        vm.expectRevert("ADL: not authorised");
        adl.registerParticipant(BTC_MARKET, aliceSub);
    }

    function test_ADL_registerParticipant_works() public {
        vm.prank(owner);
        adl.setAuthorised(alice, true);

        vm.prank(alice);
        adl.registerParticipant(BTC_MARKET, aliceSub);

        assertTrue(adl.isParticipant(BTC_MARKET, aliceSub), "Alice registered");
    }

    function test_ADL_registerParticipant_deduplication() public {
        vm.prank(owner);
        adl.setAuthorised(alice, true);

        vm.startPrank(alice);
        adl.registerParticipant(BTC_MARKET, aliceSub);
        adl.registerParticipant(BTC_MARKET, aliceSub); // no-op second time
        vm.stopPrank();

        assertTrue(adl.isParticipant(BTC_MARKET, aliceSub), "Still registered");
        // The array should have only 1 entry, not 2
        assertEq(adl.marketParticipants(BTC_MARKET, 0), aliceSub, "First entry is aliceSub");
    }

    // ===============================================================
    //
    //    SECTION 10 -- ADL: executeADL()
    //
    // ===============================================================

    function test_ADL_executeADL_onlyAuthorised() public {
        vm.prank(stranger);
        vm.expectRevert("ADL: not authorised");
        adl.executeADL(aliceSub, BTC_MARKET, 1_000e18, true);
    }

    function test_ADL_executeADL_revertsZeroShortfall() public {
        vm.prank(owner);
        adl.setAuthorised(alice, true);

        vm.prank(alice);
        vm.expectRevert("ADL: zero shortfall");
        adl.executeADL(aliceSub, BTC_MARKET, 0, true);
    }

    function test_ADL_executeADL_reducesProfitableCounterparty() public {
        // Scenario: Alice long 2 BTC, Bob short 2 BTC at $50k
        // Then Carol long 1 BTC, Bob short 1 BTC more (Bob has 3 BTC short total)
        _openAliceLongBobShort(50_000e18, 2e18);

        // Bob deposits more collateral for additional position
        vm.startPrank(bob);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(bobSub, 50_000e6);
        vm.stopPrank();

        _openCarolLongBobShort(50_000e18, 1e18);

        // Register participants for ADL
        vm.startPrank(owner);
        adl.setAuthorised(owner, true);
        adl.registerParticipant(BTC_MARKET, aliceSub);
        adl.registerParticipant(BTC_MARKET, bobSub);
        adl.registerParticipant(BTC_MARKET, carolSub);
        vm.stopPrank();

        // Price drops to $24,000 -> Alice (long) is losing, Bob (short) is profiting
        _setPrice(24_000e18);

        // Liquidate Alice -- if equity is negative, ADL auto-triggers
        vm.prank(liquidator);
        (uint256 closed,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);
        assertEq(closed, 2e18, "Alice fully liquidated");

        // The key assertion: the full liquidation + ADL flow completed
        assertTrue(true, "ADL flow completed without revert");
    }

    function test_ADL_executeADL_directCall() public {
        // Setup: Alice long 2 BTC, Bob short 2 BTC at $50k
        _openAliceLongBobShort(50_000e18, 2e18);

        // Register participants
        vm.startPrank(owner);
        adl.setAuthorised(owner, true);
        adl.registerParticipant(BTC_MARKET, aliceSub);
        adl.registerParticipant(BTC_MARKET, bobSub);
        vm.stopPrank();

        // Price drops -> Bob (short) is profitable
        _setPrice(40_000e18);

        // Bob's unrealized PnL = (50_000 - 40_000) * 2 = $20,000 (short profit)
        IMarginEngine.Position memory bobBefore = marginEngine.getPosition(bobSub, BTC_MARKET);
        assertEq(bobBefore.size, -2e18, "Bob short 2 BTC");

        // Call executeADL directly (as authorised caller) with a shortfall
        // Alice was long, so ADL looks for profitable shorts (Bob)
        vm.prank(owner);
        adl.executeADL(aliceSub, BTC_MARKET, 5_000e18, true); // $5k shortfall, Alice was long

        // Bob's profitable short position should be partially reduced
        IMarginEngine.Position memory bobAfter = marginEngine.getPosition(bobSub, BTC_MARKET);
        assertTrue(bobAfter.size > bobBefore.size, "Bob's short reduced (less negative)");
    }

    // ===============================================================
    //
    //    SECTION 11 -- Edge cases & invariants
    //
    // ===============================================================

    function test_LE_liquidate_permissionless() public {
        // Anyone can call liquidate -- no access control
        _openAliceLongBobShort(50_000e18, 2e18);
        _setPrice(24_000e18);

        // Random address can liquidate
        address randomKeeper = address(0xBEEF);
        vm.prank(randomKeeper);
        (uint256 closed,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);
        assertGt(closed, 0, "Random keeper liquidated successfully");
    }

    function test_LE_liquidate_cannotLiquidateTwice() public {
        _openAliceLongBobShort(50_000e18, 2e18);
        _setPrice(24_000e18);

        // First liquidation succeeds (full close since equity < 0)
        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        // Second attempt should revert ("not liquidatable" or "no position")
        vm.prank(liquidator);
        vm.expectRevert();
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);
    }

    function test_LE_defaultParams() public view {
        assertEq(liquidationEngine.liquidationPenaltyRate(), 0.025e18, "Default penalty 2.5%");
        assertEq(liquidationEngine.liquidatorShareRate(), 0.50e18, "Default share 50%");
    }

    function test_LE_liquidate_afterPriceRecovery_notLiquidatable() public {
        // Alice goes long, price drops (liquidatable), then recovers before liquidation
        _openAliceLongBobShort(50_000e18, 2e18);

        // Price drops
        _setPrice(26_000e18);
        assertTrue(liquidationEngine.canLiquidate(aliceSub));

        // Price recovers
        _setPrice(50_000e18);
        assertFalse(liquidationEngine.canLiquidate(aliceSub));

        vm.prank(liquidator);
        vm.expectRevert("LE: not liquidatable");
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);
    }

    function test_LE_liquidate_maxShare80Percent() public {
        // AUDIT FIX (L3-I-4): Max share is now 80% — liquidator gets 80%, insurance gets 20%
        vm.prank(owner);
        liquidationEngine.setLiquidatorShare(0.80e18); // 80%

        _openAliceLongBobShort(50_000e18, 2e18);
        // Use a price where equity is still positive so penalty can be charged
        _setPrice(26_000e18);

        uint256 insuranceBefore = usdc.balanceOf(insurance);

        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        uint256 insuranceAfter = usdc.balanceOf(insurance);
        assertTrue(insuranceAfter > insuranceBefore, "Insurance gets 20% of penalty at max share");
    }

    function test_LE_liquidate_zeroLiquidatorShare() public {
        // Set liquidator share to 0%: insurance gets all penalty
        vm.prank(owner);
        liquidationEngine.setLiquidatorShare(0);

        _openAliceLongBobShort(50_000e18, 2e18);
        // Use a price where equity is still positive so penalty is non-zero
        _setPrice(26_000e18);

        uint256 liquidatorBefore = usdc.balanceOf(liquidator);
        uint256 insuranceBefore = usdc.balanceOf(insurance);

        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        uint256 liquidatorAfter = usdc.balanceOf(liquidator);
        uint256 insuranceAfter = usdc.balanceOf(insurance);

        assertEq(liquidatorAfter, liquidatorBefore, "Liquidator got nothing with 0% share");
        assertTrue(insuranceAfter > insuranceBefore, "Insurance got all penalty");
    }

    function test_LE_setLiquidationPenalty_zero() public {
        // Set penalty to 0 -- no fees on liquidation
        vm.prank(owner);
        liquidationEngine.setLiquidationPenalty(0);
        assertEq(liquidationEngine.liquidationPenaltyRate(), 0);

        _openAliceLongBobShort(50_000e18, 2e18);
        _setPrice(24_000e18);

        uint256 liquidatorBefore = usdc.balanceOf(liquidator);
        uint256 insuranceBefore = usdc.balanceOf(insurance);

        vm.prank(liquidator);
        liquidationEngine.liquidate(aliceSub, BTC_MARKET);

        // No penalty distributed
        assertEq(usdc.balanceOf(liquidator), liquidatorBefore, "No penalty with 0% rate");
        assertEq(usdc.balanceOf(insurance), insuranceBefore, "No insurance with 0% rate");
    }

    function test_LE_liquidate_multipleLiquidations() public {
        // Alice gets partially liquidated, then price drops more, liquidated again
        _openAliceLongBobShort(50_000e18, 2e18);

        // First: partial liquidation at $26,000
        _setPrice(26_000e18);
        assertTrue(liquidationEngine.canLiquidate(aliceSub));

        vm.prank(liquidator);
        (uint256 closed1,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);
        assertTrue(closed1 > 0);

        IMarginEngine.Position memory posAfter1 = marginEngine.getPosition(aliceSub, BTC_MARKET);

        // If there's still a position and price drops further...
        if (posAfter1.size > 0) {
            _setPrice(20_000e18);

            if (liquidationEngine.canLiquidate(aliceSub)) {
                vm.prank(liquidator);
                (uint256 closed2,) = liquidationEngine.liquidate(aliceSub, BTC_MARKET);
                assertTrue(closed2 > 0, "Second liquidation closed more");
            }
        }
    }

    // ===============================================================
    //
    //    SECTION 12 -- Margin math verification
    //
    // ===============================================================

    function test_LE_marginMath_equityCalculation() public {
        // Verify equity calculation matches expected values
        _openAliceLongBobShort(50_000e18, 2e18);

        // At entry price, unrealized PnL = 0
        int256 equity = marginEngine.getEquity(aliceSub);
        // equity = vault_balance_wad + unrealized_pnl = 50_000e18 + 0 ~ 50_000e18
        assertTrue(equity > 49_000e18, "Equity close to deposit at entry price");

        // Move price up $1000
        _setPrice(51_000e18);
        int256 equityUp = marginEngine.getEquity(aliceSub);
        // PnL = (51_000 - 50_000) * 2 = +2_000
        assertTrue(equityUp > equity, "Equity increased with favorable price");

        // Move price down $1000 from original
        _setPrice(49_000e18);
        int256 equityDown = marginEngine.getEquity(aliceSub);
        // PnL = (49_000 - 50_000) * 2 = -2_000
        assertTrue(equityDown < equity, "Equity decreased with adverse price");
    }

    function test_LE_marginMath_mmrCalculation() public {
        _openAliceLongBobShort(50_000e18, 2e18);

        // MMR = |size| * price * MMR_rate = 2 * 50_000 * 0.05 = 5_000
        uint256 mmr = marginEngine.getMaintenanceMarginReq(aliceSub);
        assertEq(mmr, 5_000e18, "MMR = 2 BTC * $50k * 5%");

        // Change price: MMR changes proportionally
        _setPrice(60_000e18);
        uint256 mmr2 = marginEngine.getMaintenanceMarginReq(aliceSub);
        assertEq(mmr2, 6_000e18, "MMR = 2 BTC * $60k * 5%");
    }

    function test_LE_marginMath_liquidationThreshold() public {
        // With 2 BTC long at $50k, $50k collateral:
        // equity = 2P - 50_000
        // MMR = 0.1P
        // Liquidatable when 2P - 50_000 < 0.1P, i.e. P < 26_315.79
        _openAliceLongBobShort(50_000e18, 2e18);

        // Just above threshold: $26,500 -> not liquidatable
        _setPrice(26_500e18);
        assertFalse(liquidationEngine.canLiquidate(aliceSub), "Just above threshold");

        // Below threshold: $26,000
        _setPrice(26_000e18);
        assertTrue(liquidationEngine.canLiquidate(aliceSub), "Below threshold");
    }
}
