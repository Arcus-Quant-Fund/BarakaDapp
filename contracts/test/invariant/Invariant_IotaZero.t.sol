// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/FundingEngine.sol";
import "../mocks/MockOracle.sol";

// ══════════════════════════════════════════════════════════════
//  HANDLER
//  The fuzzer randomly calls these functions in any order.
//  Each function represents a realistic action an actor can
//  take against the FundingEngine.
// ══════════════════════════════════════════════════════════════

contract FundingEngineHandler is Test {
    FundingEngine public engine;
    MockOracle    public oracle;
    address       public market;
    address       public owner;

    // Ghost variables: track state for invariant assertions
    uint256 public calls;
    uint256 public markBelowOrEqualCount;
    uint256 public markAboveCount;

    constructor(FundingEngine _engine, MockOracle _oracle, address _market, address _owner) {
        engine = _engine;
        oracle = _oracle;
        market = _market;
        owner  = _owner;
    }

    /// @notice Set mark above index (normal premium, positive funding).
    function setMarkAbove(uint256 indexSeed, uint256 premiumBps) external {
        uint256 index   = bound(indexSeed, 1e6, 1_000_000e18);
        uint256 bps     = bound(premiumBps, 1, 1000); // 0.01% to 10%
        uint256 mark    = index + (index * bps) / 10_000;
        oracle.setIndexPrice(market, index);
        oracle.setMarkPrice(market, mark);
        markAboveCount++;
        calls++;
    }

    /// @notice Set mark below index (discount, negative funding - no riba floor).
    function setMarkBelow(uint256 indexSeed, uint256 discountBps) external {
        uint256 index   = bound(indexSeed, 1e6, 1_000_000e18);
        uint256 bps     = bound(discountBps, 1, 1000); // 0.01% to 10%
        uint256 mark    = index - (index * bps) / 10_000;
        oracle.setIndexPrice(market, index);
        oracle.setMarkPrice(market, mark);
        markBelowOrEqualCount++;
        calls++;
    }

    /// @notice Set mark exactly equal to index (perfectly anchored, F must be 0).
    function setMarkEqual(uint256 priceSeed) external {
        uint256 price = bound(priceSeed, 1e6, 1_000_000e18);
        oracle.setIndexPrice(market, price);
        oracle.setMarkPrice(market, price);
        markBelowOrEqualCount++;
        calls++;
    }

    /// @notice Advance blockchain time (simulates real time passing between calls).
    function advanceTime(uint256 hoursToAdd) external {
        uint256 hours_ = bound(hoursToAdd, 1, 72); // 1h to 3 days
        vm.warp(block.timestamp + hours_ * 1 hours);
    }

    /// @notice Trigger a cumulative funding update (as a keeper would in production).
    function updateCumulativeFunding() external {
        // Prices must be set before calling - guard against zero-price state
        try engine.updateCumulativeFunding(market) {} catch {}
    }

    /// @notice Owner pauses and unpauses (should not affect iota=0 invariant).
    function pauseUnpause(bool pauseNow) external {
        vm.startPrank(owner);
        if (pauseNow) {
            engine.pause();
        } else {
            engine.unpause();
        }
        vm.stopPrank();
    }
}

// ══════════════════════════════════════════════════════════════
//  INVARIANT TEST
// ══════════════════════════════════════════════════════════════

/**
 * @title Invariant_IotaZero
 * @notice Proves that FundingEngine always satisfies the iota=0 Shariah requirement:
 *
 *   INVARIANT 1: When mark_price <= index_price, getFundingRate() must be <= 0.
 *     Rationale: A positive floor when mark = index would be riba (as on CEX: iota = 0.01%/8h).
 *     Our circuit breaker is symmetric - it can be negative. There is no interest floor.
 *
 *   INVARIANT 2: getFundingRate() is always within [-75bps, +75bps].
 *     Rationale: The symmetric circuit breaker never adds a net positive bias.
 *
 *   INVARIANT 3: The cumulative funding index sign follows mark/index relationship.
 *     If mark < index throughout all intervals, cumulative must be <= 0.
 *
 * Mathematical basis: Ackerer, Hugonnier & Jermann (2024) Theorem 3 / Proposition 3.
 * For stablecoin-margined perps (r_a = r_b), no-arbitrage forces iota = 0 uniquely.
 */
contract Invariant_IotaZero is Test {
    FundingEngine        public engine;
    MockOracle           public oracle;
    FundingEngineHandler public handler;

    address public owner  = address(0xABCD);
    address public market = address(0x1111);

    function setUp() public {
        vm.startPrank(owner);
        oracle  = new MockOracle();
        engine  = new FundingEngine(owner, address(oracle));
        handler = new FundingEngineHandler(engine, oracle, market, owner);

        // Seed initial prices so the engine is in a valid state
        oracle.setIndexPrice(market, 50_000e18);
        oracle.setMarkPrice(market,  50_000e18);

        // Initialise cumulative funding index
        engine.updateCumulativeFunding(market);
        vm.stopPrank();

        // Direct the fuzzer to only call the handler
        targetContract(address(handler));
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 1: iota = 0 - no positive interest floor
    // ─────────────────────────────────────────────────────

    /**
     * @notice When mark_price <= index_price, getFundingRate() must return <= 0.
     *
     * This is the core Islamic finance invariant. On CEX perpetuals, I = 0.01%/8h
     * (a positive interest floor). Baraka has no such floor - when mark = index,
     * F = 0 exactly. When mark < index, F < 0 (shorts pay to longs). Never positive.
     */
    function invariant_noPositiveFloorWhenMarkAtOrBelowIndex() public {
        uint256 mark  = oracle.markPrices(market);
        uint256 index = oracle.indexPrices(market);

        // Skip if prices not set or engine paused (invariant holds vacuously)
        if (index == 0) return;
        if (engine.paused()) return;

        // If mark price not set, MockOracle falls back to index
        uint256 effectiveMark = mark == 0 ? index : mark;

        if (effectiveMark <= index) {
            int256 rate = engine.getFundingRate(market);
            assertLe(
                rate,
                0,
                "IOTA=0 VIOLATION: rate is positive when mark <= index (would be riba)"
            );
        }
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 2: Symmetric circuit breaker
    // ─────────────────────────────────────────────────────

    /**
     * @notice getFundingRate() must always be within [-75bps, +75bps].
     *         Both bounds must be respected - the cap is symmetric around zero.
     */
    function invariant_rateAlwaysWithinCircuitBreaker() public {
        if (oracle.indexPrices(market) == 0) return;
        if (engine.paused()) return;

        int256 rate    = engine.getFundingRate(market);
        int256 maxRate = engine.MAX_FUNDING_RATE(); // +75e14
        int256 minRate = engine.MIN_FUNDING_RATE(); // -75e14

        assertGe(rate, minRate, "Rate below -75bps circuit breaker");
        assertLe(rate, maxRate, "Rate above +75bps circuit breaker");
    }

    /**
     * @notice The circuit breaker bounds are themselves symmetric around zero.
     *         MAX_FUNDING_RATE == -MIN_FUNDING_RATE - not biased positive.
     */
    function invariant_circuitBreakerIsSymmetric() public view {
        assertEq(
            engine.MAX_FUNDING_RATE(),
            -engine.MIN_FUNDING_RATE(),
            "Circuit breaker is not symmetric - would introduce positive bias"
        );
    }

    // ─────────────────────────────────────────────────────
    // INVARIANT 3: Cumulative sign follows prices
    // ─────────────────────────────────────────────────────

    /**
     * @notice After the handler has called setMarkBelow/setMarkEqual at least once
     *         and never setMarkAbove, the cumulative index must be <= 0.
     *
     * This catches any scenario where the cumulative index drifts positive
     * despite all funding intervals having a negative or zero rate.
     */
    function invariant_cumulativeSignConsistentWithRates() public {
        // Only check if handler has called setMarkBelow/setMarkEqual
        // but never setMarkAbove (pure discount / at-par environment)
        if (handler.markBelowOrEqualCount() == 0) return;
        if (handler.markAboveCount() > 0)         return;
        if (engine.paused())                       return;

        int256 cumulative = engine.cumulativeFundingIndex(market);
        assertLe(
            cumulative,
            0,
            "Cumulative index positive despite mark always <= index - iota=0 drift violation"
        );
    }

    /**
     * @notice The zero-price state never causes a positive cumulative index.
     *         When no trading occurs (cumulativeFundingIndex not updated), it stays at 0.
     */
    function invariant_initialCumulativeIsZeroOrNegative() public {
        if (handler.calls() > 0) return; // only check pre-state
        int256 cumulative = engine.cumulativeFundingIndex(market);
        assertLe(cumulative, 0, "Cumulative started positive without any updates");
    }
}
