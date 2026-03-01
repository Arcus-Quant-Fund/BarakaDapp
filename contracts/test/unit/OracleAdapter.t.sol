// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracle/OracleAdapter.sol";

/**
 * @title OracleAdapterTest
 * @notice Coverage tests for OracleAdapter branches not covered by KappaSignal.t.sol.
 *
 * Branches covered:
 *   setOracle()         — zero asset / primary / secondary reverts; emits OracleSet
 *   pause / unpause     — only owner; blocks all external view functions + snapshotPrice
 *   getIndexPrice()     — both fresh (weighted avg), single-feed fallback (p1 stale / p2 stale),
 *                         all stale revert, oracle divergence revert, negative answer stale,
 *                         unregistered asset revert
 *   circuit breaker     — price spike >20% reverts; within range succeeds; inactive before first snapshot
 *   getMarkPrice()      — <2 obs falls back to index; 2+ obs returns TWAP; all obs outside window
 *   recordMarkPrice()   — zero price reverts; ring buffer wraps at 60 entries; paused reverts
 *   snapshotPrice()     — updates lastValidPrice; emits PriceRecorded
 */
contract OracleAdapterTest is Test {

    OracleAdapter public adapter;

    address public owner = address(0xABCD);
    address public asset = address(0x1234);

    MockChainlinkFeed public feedA;
    MockChainlinkFeed public feedB;

    // $50k in 18-decimal scale.
    // For an 8-decimal Chainlink feed: $50,000 = 50,000 * 1e8 = 5e12 (feed answer).
    // OracleAdapter normalises: 5e12 * 10^(18-8) = 5e12 * 1e10 = 5e22 = 50_000e18 = BASE.
    uint256 constant BASE     = 50_000e18;
    uint256 constant FEED_ANS = 5_000_000_000_000; // 5e12

    function setUp() public {
        // Advance time so staleness tests work (makeStale sets _updatedAt=0;
        // staleness check is block.timestamp - 0 > 300, so need timestamp > 300).
        vm.warp(1 days);

        vm.startPrank(owner);
        adapter = new OracleAdapter(owner);
        feedA   = new MockChainlinkFeed(int256(FEED_ANS), 8);
        feedB   = new MockChainlinkFeed(int256(FEED_ANS), 8);
        adapter.setOracle(asset, address(feedA), address(feedB));
        // Seed lastValidPrice so circuit breaker is active for subsequent tests
        adapter.snapshotPrice(asset);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // setOracle() — zero address guards
    // ─────────────────────────────────────────────────────

    function test_setOracle_zeroAssetReverts() public {
        vm.prank(owner);
        vm.expectRevert("Zero asset");
        adapter.setOracle(address(0), address(feedA), address(feedB));
    }

    function test_setOracle_zeroPrimaryReverts() public {
        vm.prank(owner);
        vm.expectRevert("Zero primary");
        adapter.setOracle(asset, address(0), address(feedB));
    }

    function test_setOracle_zeroSecondaryReverts() public {
        vm.prank(owner);
        vm.expectRevert("Zero secondary");
        adapter.setOracle(asset, address(feedA), address(0));
    }

    function test_setOracle_emitsOracleSetEvent() public {
        address asset2 = address(0x9999);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit OracleAdapter.OracleSet(asset2, address(feedA), address(feedB));
        adapter.setOracle(asset2, address(feedA), address(feedB));
    }

    function test_setOracle_resetsLastValidPrice() public {
        // lastValidPrice is non-zero after setUp
        assertGt(adapter.lastValidPrice(asset), 0);

        // Re-registering same asset resets lastValidPrice to 0
        vm.prank(owner);
        adapter.setOracle(asset, address(feedA), address(feedB));
        assertEq(adapter.lastValidPrice(asset), 0);
    }

    // ─────────────────────────────────────────────────────
    // pause / unpause
    // ─────────────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        adapter.pause();
    }

    function test_pause_blocksGetIndexPrice() public {
        vm.prank(owner); adapter.pause();
        vm.expectRevert();
        adapter.getIndexPrice(asset);
    }

    function test_pause_blocksGetMarkPrice() public {
        vm.prank(owner); adapter.pause();
        vm.expectRevert();
        adapter.getMarkPrice(asset, 30 minutes);
    }

    function test_pause_blocksGetPremium() public {
        vm.prank(owner); adapter.pause();
        vm.expectRevert();
        adapter.getPremium(asset);
    }

    function test_pause_blocksGetKappaSignal() public {
        vm.prank(owner); adapter.pause();
        vm.expectRevert();
        adapter.getKappaSignal(asset);
    }

    function test_pause_blocksSnapshotPrice() public {
        vm.prank(owner); adapter.pause();
        vm.prank(owner);
        vm.expectRevert();
        adapter.snapshotPrice(asset);
    }

    function test_pause_blocksRecordMarkPrice() public {
        vm.prank(owner); adapter.pause();
        vm.expectRevert();
        adapter.recordMarkPrice(asset, BASE);
    }

    function test_unpause_restoresFunctionality() public {
        vm.prank(owner); adapter.pause();
        vm.prank(owner); adapter.unpause();

        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, BASE);
    }

    // ─────────────────────────────────────────────────────
    // getIndexPrice() — oracle resolution branches
    // ─────────────────────────────────────────────────────

    function test_getIndexPrice_bothFreshReturnsWeightedAverage() public {
        // p1 = p2 = BASE → weighted avg = BASE
        assertEq(adapter.getIndexPrice(asset), BASE);
    }

    function test_getIndexPrice_primaryStaleFallsBackToSecondary() public {
        feedA.makeStale();
        // p1ok = false, p2ok = true → price = p2 = BASE
        assertEq(adapter.getIndexPrice(asset), BASE);
    }

    function test_getIndexPrice_secondaryStaleFallsBackToPrimary() public {
        feedB.makeStale();
        assertEq(adapter.getIndexPrice(asset), BASE);
    }

    function test_getIndexPrice_allOracles_stale_reverts() public {
        feedA.makeStale();
        feedB.makeStale();
        vm.expectRevert("All oracles stale");
        adapter.getIndexPrice(asset);
    }

    function test_getIndexPrice_oracleDivergence_reverts() public {
        // feedB 1% above feedA (> 0.5% DEVIATION_TOLERANCE)
        feedB.setAnswer(int256(FEED_ANS * 101 / 100));
        vm.expectRevert("Oracle divergence");
        adapter.getIndexPrice(asset);
    }

    function test_getIndexPrice_negativeAnswerTreatedAsStale() public {
        // feedA returns negative → treated as stale → falls back to feedB
        feedA.setAnswer(-1);
        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, BASE);
    }

    function test_getIndexPrice_unregisteredAssetReverts() public {
        vm.expectRevert("Oracle not configured");
        adapter.getIndexPrice(address(0xFFFF));
    }

    // ─────────────────────────────────────────────────────
    // Circuit breaker
    // ─────────────────────────────────────────────────────

    function test_circuitBreaker_priceSpikeReverts() public {
        // 25% above BASE — exceeds 20% circuit breaker
        feedA.setAnswer(int256(FEED_ANS * 125 / 100));
        feedB.setAnswer(int256(FEED_ANS * 125 / 100));
        vm.expectRevert("Circuit breaker: price spike");
        adapter.getIndexPrice(asset);
    }

    function test_circuitBreaker_withinRange_succeeds() public {
        // 5% increase — within 20% limit
        feedA.setAnswer(int256(FEED_ANS * 105 / 100));
        feedB.setAnswer(int256(FEED_ANS * 105 / 100));
        uint256 price = adapter.getIndexPrice(asset);
        assertGt(price, BASE);
    }

    function test_circuitBreaker_inactiveBeforeFirstSnapshot() public {
        // Fresh adapter with no lastValidPrice → circuit breaker inactive (last == 0)
        vm.startPrank(owner);
        OracleAdapter fresh = new OracleAdapter(owner);
        fresh.setOracle(asset, address(feedA), address(feedB));
        vm.stopPrank();

        // Any price accepted regardless of magnitude
        uint256 price = fresh.getIndexPrice(asset);
        assertGt(price, 0);
    }

    // ─────────────────────────────────────────────────────
    // getMarkPrice()
    // ─────────────────────────────────────────────────────

    function test_getMarkPrice_fallsBackToIndexWhenLessThan2Obs() public {
        // setUp has 0 TWAP obs → count < TWAP_MIN_OBSERVATIONS → index fallback
        assertEq(adapter.getMarkPrice(asset, 30 minutes), BASE);
    }

    function test_getMarkPrice_returnsTWAPWith2Obs() public {
        uint256 markPrice = BASE + BASE / 100; // 1% above index
        adapter.recordMarkPrice(asset, markPrice);
        vm.warp(block.timestamp + 60);
        // Refresh feeds to stay within staleness threshold
        feedA.setAnswer(int256(FEED_ANS));
        feedB.setAnswer(int256(FEED_ANS));
        adapter.recordMarkPrice(asset, markPrice);

        uint256 mark = adapter.getMarkPrice(asset, 30 minutes);
        assertGt(mark, 0);
        // TWAP of constant markPrice should equal markPrice
        assertApproxEqAbs(mark, markPrice, 1e15);
    }

    function test_getMarkPrice_allObsOutsideWindowFallsBackToIndex() public {
        uint256 T = block.timestamp;

        adapter.recordMarkPrice(asset, BASE + BASE / 100);
        vm.warp(T + 60);
        feedA.setAnswer(int256(FEED_ANS));
        feedB.setAnswer(int256(FEED_ANS));
        adapter.recordMarkPrice(asset, BASE + BASE / 100);

        // Advance 2 hours — obs at T and T+60 are now outside any short window
        vm.warp(T + 60 + 2 hours);
        feedA.setAnswer(int256(FEED_ANS));
        feedB.setAnswer(int256(FEED_ANS));
        // Update circuit breaker baseline
        vm.prank(owner);
        adapter.snapshotPrice(asset);

        // 1-second window → both observations are outside → totalTime = 0 → index fallback
        uint256 mark = adapter.getMarkPrice(asset, 1);
        assertEq(mark, BASE);
    }

    // ─────────────────────────────────────────────────────
    // recordMarkPrice()
    // ─────────────────────────────────────────────────────

    function test_recordMarkPrice_zeroReverts() public {
        vm.expectRevert("Zero price");
        adapter.recordMarkPrice(asset, 0);
    }

    function test_recordMarkPrice_wrapsRingBuffer() public {
        // Fill the 60-slot ring buffer and add 5 more (65 total) to confirm wrap-around works.
        // Each iteration advances time by 1 second; total = 65s, well within the 5-min
        // staleness threshold, so feeds remain fresh for any fallback path.
        for (uint256 i = 0; i < 65; i++) {
            adapter.recordMarkPrice(asset, BASE + i);
            vm.warp(block.timestamp + 1);
        }
        // Should not revert; TWAP must remain computable
        uint256 mark = adapter.getMarkPrice(asset, 30 minutes);
        assertGt(mark, 0);
    }

    // ─────────────────────────────────────────────────────
    // snapshotPrice()
    // ─────────────────────────────────────────────────────

    function test_snapshotPrice_updatesLastValidPrice() public {
        // 5% price increase (within 20% circuit breaker)
        // FEED_ANS = 5e12; 5% up = 5.25e12
        uint256 newFeedAns    = FEED_ANS * 105 / 100; // 5_250_000_000_000
        uint256 expectedPrice = newFeedAns * 1e10;    // 5.25e22 = 52_500e18

        feedA.setAnswer(int256(newFeedAns));
        feedB.setAnswer(int256(newFeedAns));

        vm.prank(owner);
        uint256 returnedPrice = adapter.snapshotPrice(asset);

        assertEq(adapter.lastValidPrice(asset), expectedPrice);
        assertEq(returnedPrice, expectedPrice);
    }

    function test_snapshotPrice_emitsPriceRecorded() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false); // only check event type + indexed asset
        emit OracleAdapter.PriceRecorded(asset, 0, 0);
        adapter.snapshotPrice(asset);
    }

    // ─────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────

    function testFuzz_recordMarkPriceNeverReverts(uint256 price) public {
        price = bound(price, 1, type(uint128).max);
        adapter.recordMarkPrice(asset, price); // must not revert for any price > 0
    }

    function testFuzz_getMarkPriceAlwaysPositive(uint256 markBps) public {
        // markBps bounded to avoid circuit breaker (< 20%)
        markBps = bound(markBps, 0, 15);
        uint256 mark = BASE + BASE * markBps / 10000;

        adapter.recordMarkPrice(asset, mark);
        vm.warp(block.timestamp + 1);
        feedA.setAnswer(int256(FEED_ANS));
        feedB.setAnswer(int256(FEED_ANS));
        adapter.recordMarkPrice(asset, mark);

        uint256 twap = adapter.getMarkPrice(asset, 30 minutes);
        assertGt(twap, 0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockChainlinkFeed — minimal controllable Chainlink-style feed
// ─────────────────────────────────────────────────────────────────────────────

contract MockChainlinkFeed {
    int256  private _answer;
    uint8   private _decimals;
    uint256 private _updatedAt;

    constructor(int256 ans, uint8 dec) {
        _answer    = ans;
        _decimals  = dec;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 ans) external {
        _answer    = ans;
        _updatedAt = block.timestamp;
    }

    /// @notice Force the feed to appear stale (updatedAt = 0 → always beyond threshold)
    function makeStale() external {
        _updatedAt = 0;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, _updatedAt, 1);
    }

    function decimals() external view returns (uint8) { return _decimals; }
}
