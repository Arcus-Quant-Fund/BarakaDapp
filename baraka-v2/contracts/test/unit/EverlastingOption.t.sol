// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/instruments/EverlastingOption.sol";
import "../mocks/MockOracleAdapter.sol";

/**
 * @title EverlastingOptionTest
 * @notice Comprehensive unit tests for EverlastingOption pricing engine.
 *
 *         Covers: setMarket, quotePut, quoteCall, put-call parity, quoteAtSpot,
 *         getExponents, zero-price revert, out-of-range revert, inactive-market revert,
 *         oracle timelock lifecycle, pause functionality.
 */
contract EverlastingOptionTest is Test {

    EverlastingOption  eo;
    MockOracleAdapter  oracle;

    address owner = address(0xABCD);
    address alice = address(0x1111);

    bytes32 constant BTC = keccak256("BTC-USD");
    bytes32 constant ETH = keccak256("ETH-USD");

    uint256 constant WAD = 1e18;

    // Reasonable market params: sigma^2 = 0.5 (50% annual variance), kappa = 5% annual
    uint256 constant SIGMA2 = 0.5e18;
    uint256 constant KAPPA  = 0.05e18;

    function setUp() public {
        vm.startPrank(owner);
        oracle = new MockOracleAdapter();
        eo = new EverlastingOption(owner, address(oracle));

        // Set up BTC market with default params
        eo.setMarket(BTC, SIGMA2, KAPPA, false);

        // Set oracle price for BTC
        oracle.setIndexPrice(BTC, 50_000e18);

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 1. setMarket — access control and bounds
    // ═══════════════════════════════════════════════════════

    function test_setMarket_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        eo.setMarket(ETH, SIGMA2, KAPPA, false);
    }

    function test_setMarket_ownerSucceeds() public {
        vm.prank(owner);
        eo.setMarket(ETH, SIGMA2, KAPPA, false);

        (uint256 s2, uint256 k, bool useOracle, bool active) = eo.markets(ETH);
        assertEq(s2, SIGMA2, "sigma2 stored");
        assertEq(k, KAPPA, "kappa stored");
        assertFalse(useOracle, "useOracle=false");
        assertTrue(active, "market active");
    }

    function test_setMarket_sigmaTooSmall_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: sigma too small");
        eo.setMarket(ETH, 1e14 - 1, KAPPA, false);
    }

    function test_setMarket_sigmaMinBoundary() public {
        vm.prank(owner);
        eo.setMarket(ETH, 1e14, KAPPA, false);
        (uint256 s2,,,) = eo.markets(ETH);
        assertEq(s2, 1e14);
    }

    function test_setMarket_sigmaTooLarge_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: sigma too large");
        eo.setMarket(ETH, 100e18 + 1, KAPPA, false);
    }

    function test_setMarket_sigmaMaxBoundary() public {
        vm.prank(owner);
        eo.setMarket(ETH, 100e18, KAPPA, false);
        (uint256 s2,,,) = eo.markets(ETH);
        assertEq(s2, 100e18);
    }

    function test_setMarket_zeroKappa_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: zero kappa");
        eo.setMarket(ETH, SIGMA2, 0, false);
    }

    function test_setMarket_kappaTooHigh_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: kappa > 100%/yr");
        eo.setMarket(ETH, SIGMA2, WAD + 1, false);
    }

    function test_setMarket_kappaMaxBoundary() public {
        vm.prank(owner);
        eo.setMarket(ETH, SIGMA2, WAD, false);
        (, uint256 k,,) = eo.markets(ETH);
        assertEq(k, WAD);
    }

    function test_setMarket_useOracleKappa_zeroKappaAllowed() public {
        // When useOracleKappa=true, kappa=0 should not revert
        vm.prank(owner);
        eo.setMarket(ETH, SIGMA2, 0, true);
        (,, bool useOracle, bool active) = eo.markets(ETH);
        assertTrue(useOracle);
        assertTrue(active);
    }

    function test_setMarket_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit EverlastingOption.MarketSet(ETH, SIGMA2, KAPPA, false);
        eo.setMarket(ETH, SIGMA2, KAPPA, false);
    }

    // ═══════════════════════════════════════════════════════
    // 2. quotePut — returns positive price
    // ═══════════════════════════════════════════════════════

    function test_quotePut_positivePrice() public view {
        // OTM put: spot=50000, strike=45000
        uint256 putPrice = eo.quotePut(BTC, 50_000e18, 45_000e18);
        assertGt(putPrice, 0, "Put price should be positive");
    }

    function test_quotePut_ATM() public view {
        // At the money
        uint256 putPrice = eo.quotePut(BTC, 50_000e18, 50_000e18);
        assertGt(putPrice, 0, "ATM put should be positive");
    }

    function test_quotePut_deepITM() public view {
        // Deep ITM put: spot=30000, strike=50000
        uint256 putPrice = eo.quotePut(BTC, 30_000e18, 50_000e18);
        assertGt(putPrice, 0, "Deep ITM put should be positive");
    }

    function test_quotePut_OTM_lessThan_ITM() public view {
        // An OTM put should be cheaper than a deep ITM put (same spot, different strikes)
        uint256 otmPut = eo.quotePut(BTC, 50_000e18, 40_000e18); // OTM
        uint256 itmPut = eo.quotePut(BTC, 50_000e18, 60_000e18); // ITM
        assertGt(itmPut, otmPut, "ITM put > OTM put");
    }

    // ═══════════════════════════════════════════════════════
    // 3. quoteCall — returns positive price
    // ═══════════════════════════════════════════════════════

    function test_quoteCall_positivePrice() public view {
        // OTM call: spot=50000, strike=55000
        uint256 callPrice = eo.quoteCall(BTC, 50_000e18, 55_000e18);
        assertGt(callPrice, 0, "Call price should be positive");
    }

    function test_quoteCall_ATM() public view {
        uint256 callPrice = eo.quoteCall(BTC, 50_000e18, 50_000e18);
        assertGt(callPrice, 0, "ATM call should be positive");
    }

    function test_quoteCall_deepITM() public view {
        // Deep ITM call: spot=70000, strike=50000
        uint256 callPrice = eo.quoteCall(BTC, 70_000e18, 50_000e18);
        assertGt(callPrice, 0, "Deep ITM call should be positive");
    }

    function test_quoteCall_OTM_lessThan_ITM() public view {
        uint256 otmCall = eo.quoteCall(BTC, 50_000e18, 60_000e18); // OTM
        uint256 itmCall = eo.quoteCall(BTC, 50_000e18, 40_000e18); // ITM
        assertGt(itmCall, otmCall, "ITM call > OTM call");
    }

    // ═══════════════════════════════════════════════════════
    // 4. Put-call parity sanity check
    // ═══════════════════════════════════════════════════════

    function test_putCallParity_sanity() public view {
        // For everlasting options, strict put-call parity doesn't hold like for vanillas.
        // But at ATM (x == K), put and call should be roughly similar in magnitude.
        uint256 spot = 50_000e18;
        uint256 strike = 50_000e18;

        uint256 putPrice  = eo.quotePut(BTC, spot, strike);
        uint256 callPrice = eo.quoteCall(BTC, spot, strike);

        // Both should be positive
        assertGt(putPrice, 0, "ATM put > 0");
        assertGt(callPrice, 0, "ATM call > 0");

        // At ATM, neither should dominate the other by 100x
        assertLt(putPrice * 100, callPrice * 10000, "Put and call in reasonable ratio");
        assertLt(callPrice * 100, putPrice * 10000, "Call and put in reasonable ratio");
    }

    function test_putCallParity_varyingStrikes() public view {
        // As strike increases: put value goes up, call value goes down
        uint256 spot = 50_000e18;

        uint256 putLow   = eo.quotePut(BTC, spot, 40_000e18);
        uint256 putHigh  = eo.quotePut(BTC, spot, 60_000e18);
        uint256 callLow  = eo.quoteCall(BTC, spot, 40_000e18);
        uint256 callHigh = eo.quoteCall(BTC, spot, 60_000e18);

        assertGt(putHigh, putLow, "Higher strike -> higher put");
        assertGt(callLow, callHigh, "Lower strike -> higher call");
    }

    // ═══════════════════════════════════════════════════════
    // 5. quoteAtSpot — uses oracle price
    // ═══════════════════════════════════════════════════════

    function test_quoteAtSpot_usesOraclePrice() public view {
        // Oracle price is 50_000e18 (set in setUp)
        (uint256 putPrice, uint256 callPrice, uint256 spotWad,,,) =
            eo.quoteAtSpot(BTC, 45_000e18);

        assertEq(spotWad, 50_000e18, "Should use oracle spot");
        assertGt(putPrice, 0, "Put price > 0");
        assertGt(callPrice, 0, "Call price > 0");
    }

    function test_quoteAtSpot_returnsExponents() public view {
        (,, uint256 spotWad,, int256 betaNeg, int256 betaPos) =
            eo.quoteAtSpot(BTC, 50_000e18);

        assertEq(spotWad, 50_000e18);
        assertLt(betaNeg, 0, "betaNeg < 0");
        assertGt(betaPos, 0, "betaPos > 0");
    }

    function test_quoteAtSpot_zeroStrike_reverts() public {
        vm.expectRevert("EO: strike out of range");
        eo.quoteAtSpot(BTC, 0);
    }

    function test_quoteAtSpot_strikeTooLarge_reverts() public {
        vm.expectRevert("EO: strike out of range");
        eo.quoteAtSpot(BTC, 1e36 + 1);
    }

    function test_quoteAtSpot_oracleZeroSpot_reverts() public {
        // Set up a new market with zero oracle price
        vm.prank(owner);
        eo.setMarket(ETH, SIGMA2, KAPPA, false);
        // oracle price for ETH not set (defaults to 0)

        vm.expectRevert("EO: spot out of range");
        eo.quoteAtSpot(ETH, 50_000e18);
    }

    function test_quoteAtSpot_matchesManualQuote() public view {
        uint256 strike = 45_000e18;
        (uint256 putAtSpot, uint256 callAtSpot, uint256 spotWad,,,) =
            eo.quoteAtSpot(BTC, strike);

        // quoteAtSpot should give the same result as quotePut/quoteCall with oracle spot
        uint256 putManual  = eo.quotePut(BTC, spotWad, strike);
        uint256 callManual = eo.quoteCall(BTC, spotWad, strike);

        assertEq(putAtSpot, putManual, "quoteAtSpot put == manual quotePut");
        assertEq(callAtSpot, callManual, "quoteAtSpot call == manual quoteCall");
    }

    // ═══════════════════════════════════════════════════════
    // 6. getExponents — betaNeg < 0, betaPos > 0
    // ═══════════════════════════════════════════════════════

    function test_getExponents_signs() public view {
        (int256 betaNeg, int256 betaPos, uint256 denom) = eo.getExponents(BTC);
        assertLt(betaNeg, 0, "betaNeg must be negative");
        assertGt(betaPos, int256(WAD), "betaPos must be > 1 (i.e. > WAD)");
        assertGt(denom, 0, "denom must be positive");
    }

    function test_getExponents_denomEquality() public view {
        // denom = betaPos - betaNeg = 2 * sqrtD
        (int256 betaNeg, int256 betaPos, uint256 denom) = eo.getExponents(BTC);
        uint256 betaDiff = uint256(betaPos - betaNeg);
        assertEq(denom, betaDiff, "denom == betaPos - betaNeg");
    }

    function test_getExponents_differentMarkets() public {
        // BTC: sigma2=0.5, kappa=0.05 -> ratio kappa/sigma2 = 0.1
        // ETH: sigma2=2.0, kappa=0.05 -> ratio kappa/sigma2 = 0.025 (different ratio)
        vm.prank(owner);
        eo.setMarket(ETH, 2e18, 0.05e18, false);

        (int256 btcBetaNeg,,) = eo.getExponents(BTC);
        (int256 ethBetaNeg,,) = eo.getExponents(ETH);

        assertTrue(btcBetaNeg != ethBetaNeg, "Different kappa/sigma2 ratio -> different exponents");
    }

    // ═══════════════════════════════════════════════════════
    // 7. Zero price reverts ("EO: zero price")
    // ═══════════════════════════════════════════════════════

    function test_quotePut_zeroSpot_reverts() public {
        vm.expectRevert("EO: zero price");
        eo.quotePut(BTC, 0, 50_000e18);
    }

    function test_quotePut_zeroStrike_reverts() public {
        vm.expectRevert("EO: zero price");
        eo.quotePut(BTC, 50_000e18, 0);
    }

    function test_quoteCall_zeroSpot_reverts() public {
        vm.expectRevert("EO: zero price");
        eo.quoteCall(BTC, 0, 50_000e18);
    }

    function test_quoteCall_zeroStrike_reverts() public {
        vm.expectRevert("EO: zero price");
        eo.quoteCall(BTC, 50_000e18, 0);
    }

    function test_quotePut_bothZero_reverts() public {
        vm.expectRevert("EO: zero price");
        eo.quotePut(BTC, 0, 0);
    }

    // ═══════════════════════════════════════════════════════
    // 8. Price out of range reverts (>1e36)
    // ═══════════════════════════════════════════════════════

    function test_quotePut_spotTooLarge_reverts() public {
        vm.expectRevert("EO: price out of range");
        eo.quotePut(BTC, 1e36 + 1, 50_000e18);
    }

    function test_quotePut_strikeTooLarge_reverts() public {
        vm.expectRevert("EO: price out of range");
        eo.quotePut(BTC, 50_000e18, 1e36 + 1);
    }

    function test_quoteCall_spotTooLarge_reverts() public {
        vm.expectRevert("EO: price out of range");
        eo.quoteCall(BTC, 1e36 + 1, 50_000e18);
    }

    function test_quoteCall_strikeTooLarge_reverts() public {
        vm.expectRevert("EO: price out of range");
        eo.quoteCall(BTC, 50_000e18, 1e36 + 1);
    }

    function test_quotePut_maxBoundary_succeeds() public view {
        // Exactly 1e36 should not revert
        uint256 price = eo.quotePut(BTC, 1e36, 1e36);
        // Just assert it didn't revert; price can be any value
        assertTrue(price >= 0);
    }

    function test_quoteCall_maxBoundary_succeeds() public view {
        uint256 price = eo.quoteCall(BTC, 1e36, 1e36);
        assertTrue(price >= 0);
    }

    // ═══════════════════════════════════════════════════════
    // 9. Inactive market reverts
    // ═══════════════════════════════════════════════════════

    function test_quotePut_inactiveMarket_reverts() public {
        bytes32 FAKE = keccak256("FAKE-USD");
        vm.expectRevert("EO: market inactive");
        eo.quotePut(FAKE, 50_000e18, 45_000e18);
    }

    function test_quoteCall_inactiveMarket_reverts() public {
        bytes32 FAKE = keccak256("FAKE-USD");
        vm.expectRevert("EO: market inactive");
        eo.quoteCall(FAKE, 50_000e18, 55_000e18);
    }

    function test_getExponents_inactiveMarket_reverts() public {
        bytes32 FAKE = keccak256("FAKE-USD");
        vm.expectRevert("EO: market inactive");
        eo.getExponents(FAKE);
    }

    function test_quoteAtSpot_inactiveMarket_reverts() public {
        bytes32 FAKE = keccak256("FAKE-USD");
        // Set oracle price so spot check passes, but market is not activated
        oracle.setIndexPrice(FAKE, 50_000e18);
        vm.expectRevert("EO: market inactive");
        eo.quoteAtSpot(FAKE, 50_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 10. Oracle timelock: initiate -> wait 48h -> apply
    // ═══════════════════════════════════════════════════════

    function test_initiateOracleUpdate() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.prank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        assertEq(eo.pendingOracle(), address(newOracle));
        assertEq(eo.oraclePendingAfter(), block.timestamp + 48 hours);
    }

    function test_initiateOracleUpdate_onlyOwner() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();
        vm.prank(alice);
        vm.expectRevert();
        eo.initiateOracleUpdate(address(newOracle));
    }

    function test_initiateOracleUpdate_zeroAddress_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: zero oracle");
        eo.initiateOracleUpdate(address(0));
    }

    function test_initiateOracleUpdate_sameOracle_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: same oracle");
        eo.initiateOracleUpdate(address(oracle));
    }

    function test_initiateOracleUpdate_emitsEvent() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit EverlastingOption.OracleUpdateInitiated(address(newOracle), block.timestamp + 48 hours);
        eo.initiateOracleUpdate(address(newOracle));
    }

    /// AUDIT FIX (EO-M-2): applyOracleUpdate now requires onlyOwner
    function test_applyOracleUpdate_afterTimelock() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        // Warp past 48h
        vm.warp(block.timestamp + 48 hours);
        eo.applyOracleUpdate();
        vm.stopPrank();

        assertEq(address(eo.oracle()), address(newOracle), "Oracle updated");
        assertEq(eo.pendingOracle(), address(0), "Pending cleared");
        assertEq(eo.oraclePendingAfter(), 0, "Timestamp cleared");
    }

    function test_applyOracleUpdate_emitsEvent() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        vm.warp(block.timestamp + 48 hours);
        vm.expectEmit(true, true, false, false);
        emit EverlastingOption.OracleUpdated(address(oracle), address(newOracle));
        eo.applyOracleUpdate();
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 11. Oracle update too early reverts
    // ═══════════════════════════════════════════════════════

    function test_applyOracleUpdate_tooEarly_reverts() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        // Warp only 47 hours — too early
        vm.warp(block.timestamp + 47 hours);
        vm.expectRevert("EO: timelock not elapsed");
        eo.applyOracleUpdate();
        vm.stopPrank();
    }

    function test_applyOracleUpdate_noPending_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: no pending oracle");
        eo.applyOracleUpdate();
    }

    function test_applyOracleUpdate_exactTimelock() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        // Warp exactly 48h — should succeed
        vm.warp(block.timestamp + 48 hours);
        eo.applyOracleUpdate();
        vm.stopPrank();
        assertEq(address(eo.oracle()), address(newOracle));
    }

    function test_applyOracleUpdate_onlyOwner_reverts() public {
        // AUDIT FIX (EO-M-2): applyOracleUpdate is now onlyOwner
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.prank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(alice);
        vm.expectRevert();
        eo.applyOracleUpdate();
    }

    // ═══════════════════════════════════════════════════════
    // 12. cancelOracleUpdate clears pending
    // ═══════════════════════════════════════════════════════

    function test_cancelOracleUpdate() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();

        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));
        eo.cancelOracleUpdate();
        vm.stopPrank();

        assertEq(eo.pendingOracle(), address(0), "Pending cleared");
        assertEq(eo.oraclePendingAfter(), 0, "Timestamp cleared");
        // Original oracle unchanged
        assertEq(address(eo.oracle()), address(oracle), "Oracle unchanged");
    }

    function test_cancelOracleUpdate_onlyOwner() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();
        vm.prank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        vm.prank(alice);
        vm.expectRevert();
        eo.cancelOracleUpdate();
    }

    function test_cancelOracleUpdate_noPending_reverts() public {
        vm.prank(owner);
        vm.expectRevert("EO: no pending oracle");
        eo.cancelOracleUpdate();
    }

    function test_cancelOracleUpdate_emitsEvent() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();
        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));

        vm.expectEmit(true, false, false, false);
        emit EverlastingOption.OracleUpdateCancelled(address(newOracle));
        eo.cancelOracleUpdate();
        vm.stopPrank();
    }

    function test_cancelOracleUpdate_thenApply_reverts() public {
        MockOracleAdapter newOracle = new MockOracleAdapter();
        vm.startPrank(owner);
        eo.initiateOracleUpdate(address(newOracle));
        eo.cancelOracleUpdate();

        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert("EO: no pending oracle");
        eo.applyOracleUpdate();
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 13. Pause blocks pricing
    // ═══════════════════════════════════════════════════════

    function test_pause_blocksQuotePut() public {
        vm.prank(owner);
        eo.pause();

        vm.expectRevert();
        eo.quotePut(BTC, 50_000e18, 45_000e18);
    }

    function test_pause_blocksQuoteCall() public {
        vm.prank(owner);
        eo.pause();

        vm.expectRevert();
        eo.quoteCall(BTC, 50_000e18, 55_000e18);
    }

    function test_pause_blocksQuoteAtSpot() public {
        vm.prank(owner);
        eo.pause();

        vm.expectRevert();
        eo.quoteAtSpot(BTC, 50_000e18);
    }

    function test_pause_blocksGetExponents() public {
        vm.prank(owner);
        eo.pause();

        vm.expectRevert();
        eo.getExponents(BTC);
    }

    function test_unpause_restoresPricing() public {
        vm.startPrank(owner);
        eo.pause();
        eo.unpause();
        vm.stopPrank();

        uint256 putPrice = eo.quotePut(BTC, 50_000e18, 45_000e18);
        assertGt(putPrice, 0, "Pricing restored after unpause");
    }

    function test_pause_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        eo.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        eo.pause();

        vm.prank(alice);
        vm.expectRevert();
        eo.unpause();
    }

    // ═══════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════

    function test_constructor_zeroOracle_reverts() public {
        vm.expectRevert("EO: zero oracle");
        new EverlastingOption(owner, address(0));
    }

    function test_constructor_setsOracle() public view {
        assertEq(address(eo.oracle()), address(oracle));
    }

    function test_constructor_setsOwner() public view {
        assertEq(eo.owner(), owner);
    }
}
