// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/oracle/OracleAdapter.sol";

/**
 * @title OracleFailoverTest
 * @notice Integration tests for OracleAdapter staleness, failover, and circuit-breaker paths.
 *
 * Scenarios covered:
 *   1. Both feeds fresh → weighted average (60/40)
 *   2. Primary stale, secondary fresh → falls back to secondary only (emits OracleFallback)
 *   3. Secondary stale, primary fresh → falls back to primary only
 *   4. Both feeds stale → reverts "All oracles stale"
 *   5. Both fresh but diverge >0.5% → reverts "Oracle divergence"
 *   6. Circuit breaker inactive on first call (no baseline yet)
 *   7. Circuit breaker activates after snapshotPrice seeds baseline
 *   8. Price spike >20% trips circuit breaker
 *   9. Price movement exactly at 20% boundary is accepted
 *  10. After circuit breaker trip, corrected price succeeds
 */
contract OracleFailoverTest is Test {

    OracleAdapter public adapter;

    address public owner = address(0xA0);
    address public asset = address(0x01);

    MockFeed public primary;
    MockFeed public secondary;

    // 8-decimal Chainlink feed: $50,000 = 5e12 raw → normalised to 50_000e18
    uint256 constant BASE     = 50_000e18;
    uint256 constant FEED_ANS = 5_000_000_000_000; // 5e12 (8 dec)

    function setUp() public {
        // Advance time so staleness tests work (updatedAt=0 < 5 min staleness threshold)
        vm.warp(1 days);

        vm.startPrank(owner);
        adapter   = new OracleAdapter(owner);
        primary   = new MockFeed(int256(FEED_ANS), 8);
        secondary = new MockFeed(int256(FEED_ANS), 8);
        adapter.setOracle(asset, address(primary), address(secondary));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // 1. Both fresh → 60/40 weighted average
    // ─────────────────────────────────────────────────────

    function test_bothFresh_returnWeightedAverage() public view {
        // Both feeds return the same price → weighted avg = same price
        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, BASE);
    }

    function test_bothFresh_differentPrices_weightedAverage() public {
        // primary = $50,000, secondary = $50,200 (within 0.5% tolerance)
        // weighted avg = (50000*60 + 50200*40) / 100 = (3,000,000 + 2,008,000)/100 = 50,080
        int256 secAns = 5_020_000_000_000; // $50,200 in 8-dec
        secondary.setAnswer(secAns);

        uint256 expected = (BASE * 60 + (BASE + 200e18) * 40) / 100;
        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, expected);
    }

    // ─────────────────────────────────────────────────────
    // 2. Primary stale → fallback to secondary
    // ─────────────────────────────────────────────────────

    function test_primaryStale_fallsBackToSecondary() public {
        // getIndexPrice is a view function — cannot emit events.
        // Verify that when primary is stale the secondary price is returned.
        primary.makeStale();
        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, BASE); // secondary returns BASE
    }

    // ─────────────────────────────────────────────────────
    // 3. Secondary stale → falls back to primary
    // ─────────────────────────────────────────────────────

    function test_secondaryStale_fallsBackToPrimary() public {
        secondary.makeStale();
        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, BASE); // primary returns BASE
    }

    // ─────────────────────────────────────────────────────
    // 4. Both stale → reverts
    // ─────────────────────────────────────────────────────

    function test_bothStale_reverts() public {
        primary.makeStale();
        secondary.makeStale();
        vm.expectRevert("All oracles stale");
        adapter.getIndexPrice(asset);
    }

    // ─────────────────────────────────────────────────────
    // 5. Both fresh but diverge → reverts
    // ─────────────────────────────────────────────────────

    function test_divergedFeeds_reverts() public {
        // primary = $50,000, secondary = $51,000 → 2% divergence > 0.5% tolerance
        secondary.setAnswer(int256(5_100_000_000_000)); // $51,000
        vm.expectRevert("Oracle divergence");
        adapter.getIndexPrice(asset);
    }

    // ─────────────────────────────────────────────────────
    // 6. Circuit breaker inactive before first snapshotPrice
    // ─────────────────────────────────────────────────────

    function test_circuitBreaker_inactiveBeforeSnapshot() public view {
        // lastValidPrice = 0 → circuit breaker skipped, any price accepted
        assertEq(adapter.lastValidPrice(asset), 0);
        // getIndexPrice should succeed (returns current feed price)
        uint256 price = adapter.getIndexPrice(asset);
        assertGt(price, 0);
    }

    // ─────────────────────────────────────────────────────
    // 7. Circuit breaker seeded by snapshotPrice
    // ─────────────────────────────────────────────────────

    function test_circuitBreaker_seededBySnapshot() public {
        vm.prank(owner);
        adapter.snapshotPrice(asset);
        assertEq(adapter.lastValidPrice(asset), BASE);
    }

    // ─────────────────────────────────────────────────────
    // 8. Price spike >20% trips circuit breaker
    // ─────────────────────────────────────────────────────

    function test_circuitBreaker_spikeReverts() public {
        // Seed baseline at $50,000
        vm.prank(owner);
        adapter.snapshotPrice(asset);

        // Spike to $61,000 — 22% above baseline
        int256 spikeAns = 6_100_000_000_000; // $61,000 in 8-dec
        primary.setAnswer(spikeAns);
        secondary.setAnswer(spikeAns);

        vm.expectRevert("Circuit breaker: price spike");
        adapter.getIndexPrice(asset);
    }

    // ─────────────────────────────────────────────────────
    // 9. Exactly 20% move is accepted (boundary)
    // ─────────────────────────────────────────────────────

    function test_circuitBreaker_exactly20pct_accepted() public {
        // Seed baseline at $50,000
        vm.prank(owner);
        adapter.snapshotPrice(asset);

        // Move to exactly $60,000 — exactly 20% (≤ CIRCUIT_BREAKER_BPS = 2000)
        int256 ans20 = 6_000_000_000_000; // $60,000 in 8-dec
        primary.setAnswer(ans20);
        secondary.setAnswer(ans20);

        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, 60_000e18);
    }

    // ─────────────────────────────────────────────────────
    // 10. After circuit breaker trip, corrected price succeeds
    // ─────────────────────────────────────────────────────

    function test_circuitBreaker_afterTrip_correctedPriceSucceeds() public {
        // Seed baseline
        vm.prank(owner);
        adapter.snapshotPrice(asset);

        // Spike — circuit breaker trips
        primary.setAnswer(int256(6_100_000_000_000));
        secondary.setAnswer(int256(6_100_000_000_000));
        vm.expectRevert("Circuit breaker: price spike");
        adapter.getIndexPrice(asset);

        // Restore sane price within 20% of baseline
        primary.setAnswer(int256(FEED_ANS));
        secondary.setAnswer(int256(FEED_ANS));

        // Should succeed now (baseline unchanged; new price is same as baseline)
        uint256 price = adapter.getIndexPrice(asset);
        assertEq(price, BASE);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MockFeed — reuses the same interface as OracleAdapter.t.sol's MockChainlinkFeed
// ─────────────────────────────────────────────────────────────────────────────

contract MockFeed {
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
