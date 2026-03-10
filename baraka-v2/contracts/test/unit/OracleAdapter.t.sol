// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracle/OracleAdapter.sol";
import "../mocks/MockChainlinkAggregator.sol";

/**
 * @title OracleAdapterTest
 * @notice Unit tests for OracleAdapter: market setup, Chainlink index update,
 *         EWMA mark price, admin price overrides with bounds, staleness,
 *         sequencer uptime, and access control.
 */
contract OracleAdapterTest is Test {

    uint256 constant WAD = 1e18;
    bytes32 constant BTC = keccak256("BTC-USD");
    bytes32 constant ETH = keccak256("ETH-USD");

    OracleAdapter           oracle;
    MockChainlinkAggregator btcFeed;
    MockChainlinkAggregator sequencerFeed;

    address owner     = address(0xABCD);
    address matcher   = address(0x6666);
    address attacker  = address(0xDEAD);

    function setUp() public {
        vm.startPrank(owner);
        oracle = new OracleAdapter(owner);
        btcFeed = new MockChainlinkAggregator();
        sequencerFeed = new MockChainlinkAggregator();

        // Setup BTC market: 8-decimal feed, 1h heartbeat
        oracle.setMarketOracle(BTC, address(btcFeed), 3600, 8);
        oracle.setAuthorised(matcher, true);
        /// AUDIT FIX (P16-UP-M1): Circuit breaker must be configured before updateIndexPrice() works
        oracle.setMaxPriceDeviation(0.15e18); // 15%
        vm.stopPrank();

        // Set valid Chainlink round data: BTC = $50,000 (8 decimals)
        btcFeed.setRoundData(1, 50000e8, block.timestamp, block.timestamp, 1);
    }

    // ═══════════════════════════════════════════════════════
    // 1. Market oracle setup
    // ═══════════════════════════════════════════════════════

    function test_setMarketOracle_activatesMarket() public view {
        (address feed,,, ,,,bool active) = oracle.marketOracles(BTC);
        assertEq(feed, address(btcFeed));
        assertTrue(active);
    }

    function test_setMarketOracle_revert_zeroFeed() public {
        vm.prank(owner);
        vm.expectRevert("OA: zero feed");
        oracle.setMarketOracle(ETH, address(0), 3600, 8);
    }

    function test_setMarketOracle_revert_nonOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setMarketOracle(ETH, address(btcFeed), 3600, 8);
    }

    function test_setMarketOracle_preservesPricesOnReconfig() public {
        // First, set an index price
        oracle.updateIndexPrice(BTC);
        uint256 priceBefore = oracle.getIndexPrice(BTC);

        // Reconfigure with new feed
        MockChainlinkAggregator newFeed = new MockChainlinkAggregator();
        vm.prank(owner);
        oracle.setMarketOracle(BTC, address(newFeed), 7200, 8);

        // Price still readable (preserved)
        uint256 priceAfter = oracle.getIndexPrice(BTC);
        assertEq(priceBefore, priceAfter);

        // But market is stale (lastUpdateTime reset)
        assertTrue(oracle.isStale(BTC));
    }

    // ═══════════════════════════════════════════════════════
    // 2. Index price update from Chainlink
    // ═══════════════════════════════════════════════════════

    function test_updateIndexPrice_basic() public {
        oracle.updateIndexPrice(BTC);
        // 50000e8 * 1e18 / 1e8 = 50000e18
        assertEq(oracle.getIndexPrice(BTC), 50_000e18);
    }

    function test_updateIndexPrice_initializesMarkPrice() public {
        oracle.updateIndexPrice(BTC);
        // First update should set mark = index
        assertEq(oracle.getMarkPrice(BTC), 50_000e18);
    }

    function test_updateIndexPrice_setsChainlinkReference() public {
        oracle.updateIndexPrice(BTC);
        assertEq(oracle.chainlinkReferencePrice(BTC), 50_000e18);
    }

    function test_updateIndexPrice_revert_negativePrice() public {
        btcFeed.setRoundData(1, -100, block.timestamp, block.timestamp, 1);
        vm.expectRevert("OA: negative price");
        oracle.updateIndexPrice(BTC);
    }

    function test_updateIndexPrice_revert_staleFeed() public {
        // Warp forward so subtraction doesn't underflow
        vm.warp(10_000);
        btcFeed.setRoundData(1, 50000e8, block.timestamp, block.timestamp - 7200, 1);
        vm.expectRevert("OA: stale feed");
        oracle.updateIndexPrice(BTC);
    }

    function test_updateIndexPrice_revert_staleRound() public {
        // answeredInRound < roundId
        btcFeed.setRoundData(5, 50000e8, block.timestamp, block.timestamp, 4);
        vm.expectRevert("OA: stale round");
        oracle.updateIndexPrice(BTC);
    }

    function test_updateIndexPrice_revert_roundNotStarted() public {
        btcFeed.setRoundData(1, 50000e8, 0, block.timestamp, 1);
        vm.expectRevert("OA: round not started");
        oracle.updateIndexPrice(BTC);
    }

    function test_updateIndexPrice_revert_inactiveMarket() public {
        vm.expectRevert("OA: market not active");
        oracle.updateIndexPrice(ETH);
    }

    // ═══════════════════════════════════════════════════════
    // 3. Mark price EWMA
    // ═══════════════════════════════════════════════════════

    function test_updateMarkPrice_ewma() public {
        oracle.updateIndexPrice(BTC);

        // Trade at $51,000
        vm.prank(matcher);
        oracle.updateMarkPrice(BTC, 51_000e18);

        // EWMA: 0.1 * 51000 + 0.9 * 50000 = 50100
        assertEq(oracle.getMarkPrice(BTC), 50_100e18);
    }

    function test_updateMarkPrice_clampsAt10Percent() public {
        oracle.updateIndexPrice(BTC);

        // Trade at $100,000 (100% above index) — clamped to +10% = $55,000
        vm.prank(matcher);
        oracle.updateMarkPrice(BTC, 100_000e18);

        // EWMA: 0.1 * 55000 + 0.9 * 50000 = 50500
        assertEq(oracle.getMarkPrice(BTC), 50_500e18);
    }

    function test_updateMarkPrice_clampsBelow() public {
        oracle.updateIndexPrice(BTC);

        // Trade at $10,000 (80% below index) — clamped to -10% = $45,000
        vm.prank(matcher);
        oracle.updateMarkPrice(BTC, 10_000e18);

        // EWMA: 0.1 * 45000 + 0.9 * 50000 = 49500
        assertEq(oracle.getMarkPrice(BTC), 49_500e18);
    }

    function test_updateMarkPrice_revert_notAuthorised() public {
        vm.prank(attacker);
        vm.expectRevert("OA: not authorised");
        oracle.updateMarkPrice(BTC, 50_000e18);
    }

    function test_updateMarkPrice_initializesFromIndex() public {
        oracle.updateIndexPrice(BTC);

        // Reset mark to 0 via fresh market
        MockChainlinkAggregator ethFeed = new MockChainlinkAggregator();
        ethFeed.setRoundData(1, 3000e8, block.timestamp, block.timestamp, 1);
        vm.prank(owner);
        oracle.setMarketOracle(ETH, address(ethFeed), 3600, 8);
        oracle.updateIndexPrice(ETH);

        // Mark should be index (3000e18) since it was just initialized
        vm.prank(matcher);
        oracle.updateMarkPrice(ETH, 3100e18);
        // EWMA from 3000: 0.1 * 3100 + 0.9 * 3000 = 3010
        assertEq(oracle.getMarkPrice(ETH), 3010e18);
    }

    // ═══════════════════════════════════════════════════════
    // 4. EWMA alpha setter
    // ═══════════════════════════════════════════════════════

    function test_setMarkEwmaAlpha_valid() public {
        vm.prank(owner);
        oracle.setMarkEwmaAlpha(0.05e18);
        assertEq(oracle.markEwmaAlpha(), 0.05e18);
    }

    function test_setMarkEwmaAlpha_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert("OA: alpha out of range (max 20%)");
        oracle.setMarkEwmaAlpha(0);
    }

    function test_setMarkEwmaAlpha_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert("OA: alpha out of range (max 20%)");
        oracle.setMarkEwmaAlpha(0.25e18);
    }

    // ═══════════════════════════════════════════════════════
    // 5. Admin price overrides with bounds
    // ═══════════════════════════════════════════════════════

    function test_setIndexPrice_firstTimeUnbounded() public {
        // No Chainlink reference yet for ETH
        MockChainlinkAggregator ethFeed = new MockChainlinkAggregator();
        vm.prank(owner);
        oracle.setMarketOracle(ETH, address(ethFeed), 3600, 8);

        // First-time set is unrestricted
        vm.prank(owner);
        oracle.setIndexPrice(ETH, 999_999e18);
        assertEq(oracle.getIndexPrice(ETH), 999_999e18);
    }

    function test_setIndexPrice_boundedByChainlinkRef() public {
        oracle.updateIndexPrice(BTC); // ref = 50000e18

        // Within bounds (ref/2 = 25000, ref*2 = 100000)
        // Use 55_000 (within 15% circuit breaker) so subsequent updateIndexPrice doesn't trip
        vm.prank(owner);
        oracle.setIndexPrice(BTC, 55_000e18);
        assertEq(oracle.getIndexPrice(BTC), 55_000e18);

        // Update ref first to reset (circuit breaker: |55k - 50k|/55k = 9% < 15%)
        btcFeed.setRoundData(2, 50000e8, block.timestamp, block.timestamp, 2);
        oracle.updateIndexPrice(BTC);

        // Out of bounds (above ref*2)
        vm.prank(owner);
        vm.expectRevert("OA: price outside [ref/2, ref*2] bound");
        oracle.setIndexPrice(BTC, 150_000e18);
    }

    function test_setIndexPrice_revert_zeroPrice() public {
        vm.prank(owner);
        vm.expectRevert("OA: zero price");
        oracle.setIndexPrice(BTC, 0);
    }

    function test_setMarkPrice_boundedByChainlinkRef() public {
        oracle.updateIndexPrice(BTC); // ref = 50000e18

        vm.prank(owner);
        oracle.setMarkPrice(BTC, 60_000e18); // within [25000, 100000]
        assertEq(oracle.getMarkPrice(BTC), 60_000e18);

        // Out of bounds
        vm.prank(owner);
        vm.expectRevert("OA: mark outside [ref/2, ref*2] bound");
        oracle.setMarkPrice(BTC, 10_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 6. Staleness
    // ═══════════════════════════════════════════════════════

    function test_isStale_trueBeforeUpdate() public view {
        // lastUpdateTime = 0 after setMarketOracle
        assertTrue(oracle.isStale(BTC));
    }

    function test_isStale_falseAfterUpdate() public {
        oracle.updateIndexPrice(BTC);
        assertFalse(oracle.isStale(BTC));
    }

    function test_isStale_trueAfterHeartbeat() public {
        oracle.updateIndexPrice(BTC);

        // Advance past heartbeat (1h)
        vm.warp(block.timestamp + 3601);
        assertTrue(oracle.isStale(BTC));
    }

    function test_isStale_trueForInactiveMarket() public view {
        assertTrue(oracle.isStale(ETH));
    }

    // ═══════════════════════════════════════════════════════
    // 7. getIndexPrice / getMarkPrice edge cases
    // ═══════════════════════════════════════════════════════

    function test_getIndexPrice_revert_notSet() public {
        // ETH has no price set
        MockChainlinkAggregator ethFeed = new MockChainlinkAggregator();
        vm.prank(owner);
        oracle.setMarketOracle(ETH, address(ethFeed), 3600, 8);

        vm.expectRevert("OA: index price not set");
        oracle.getIndexPrice(ETH);
    }

    function test_getMarkPrice_fallsBackToIndex() public {
        oracle.updateIndexPrice(BTC);
        // Mark was auto-set to index on first updateIndexPrice
        // But for a fresh market where only setIndexPrice is used:
        MockChainlinkAggregator ethFeed = new MockChainlinkAggregator();
        vm.prank(owner);
        oracle.setMarketOracle(ETH, address(ethFeed), 3600, 8);
        vm.prank(owner);
        oracle.setIndexPrice(ETH, 3000e18);
        // setIndexPrice also sets mark if mark == 0
        assertEq(oracle.getMarkPrice(ETH), 3000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 8. Sequencer uptime feed
    // ═══════════════════════════════════════════════════════

    function test_sequencerDown_blocksUpdate() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));

        // Sequencer is DOWN (answer = 1)
        sequencerFeed.setRoundData(1, 1, block.timestamp, block.timestamp, 1);

        vm.expectRevert("OA: sequencer down");
        oracle.updateIndexPrice(BTC);
    }

    function test_sequencerGracePeriod_blocksUpdate() public {
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));

        // Sequencer UP (answer = 0) but just recovered (startedAt = now)
        sequencerFeed.setRoundData(1, 0, block.timestamp, block.timestamp, 1);

        vm.expectRevert("OA: sequencer grace period");
        oracle.updateIndexPrice(BTC);
    }

    function test_sequencerGracePeriod_passesAfterDelay() public {
        vm.warp(10_000);
        vm.prank(owner);
        oracle.setSequencerUptimeFeed(address(sequencerFeed));

        // Sequencer UP, recovered > 1h ago
        sequencerFeed.setRoundData(1, 0, block.timestamp - 7200, block.timestamp, 1);
        btcFeed.setRoundData(1, 50000e8, block.timestamp, block.timestamp, 1);

        oracle.updateIndexPrice(BTC);
        assertEq(oracle.getIndexPrice(BTC), 50_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 9. Renounce ownership
    // ═══════════════════════════════════════════════════════

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert("OA: renounce disabled");
        oracle.renounceOwnership();
    }
}
