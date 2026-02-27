// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/FundingEngine.sol";
import "../mocks/MockOracle.sol";

contract FundingEngineTest is Test {
    FundingEngine public engine;
    MockOracle    public oracle;

    address public owner  = address(0xABCD);
    address public market = address(0x1234); // arbitrary market ID

    uint256 constant ONE_ETH = 1e18;

    function setUp() public {
        vm.startPrank(owner);
        oracle = new MockOracle();
        engine = new FundingEngine(owner, address(oracle));
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // Core formula: F = (mark - index) / index
    // ─────────────────────────────────────────────────────

    function test_FundingRateZeroWhenMarkEqualsIndex() public {
        oracle.setIndexPrice(market, 50_000e18);
        oracle.setMarkPrice(market,  50_000e18);

        int256 rate = engine.getFundingRate(market);
        assertEq(rate, 0, "F must be 0 when mark == index");
    }

    function test_FundingRatePositiveWhenMarkAboveIndex() public {
        // mark 1% above index → longs pay shorts
        oracle.setIndexPrice(market, 50_000e18);
        oracle.setMarkPrice(market,  50_500e18); // +1%

        int256 rate = engine.getFundingRate(market);
        assertGt(rate, 0, "F must be positive when mark > index");
    }

    function test_FundingRateNegativeWhenMarkBelowIndex() public {
        // mark 1% below index → shorts pay longs
        oracle.setIndexPrice(market, 50_000e18);
        oracle.setMarkPrice(market,  49_500e18); // -1%

        int256 rate = engine.getFundingRate(market);
        assertLt(rate, 0, "F must be negative when mark < index");
    }

    // ─────────────────────────────────────────────────────
    // KEY TEST: No interest floor anywhere
    // ─────────────────────────────────────────────────────

    function test_NoInterestFloorWhenMarkBelowIndex() public {
        // Even when mark << index, funding rate must stay negative (not clamped to positive floor)
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  90e18); // -10%

        int256 rate = engine.getFundingRate(market);
        // Rate must be negative — there is NO floor (unlike CEX I = +0.01%/8h)
        assertLt(rate, 0, "No interest floor: rate must remain negative");

        // Specifically must NOT be positive (would indicate riba floor)
        assertTrue(rate < 0, unicode"iota=0: funding rate has no positive floor");
    }

    function test_NoInterestFloorWhenMarkEqualsIndex() public {
        // When mark == index, rate must be exactly 0 — not a positive constant
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  100e18);

        int256 rate = engine.getFundingRate(market);
        // CEX formula gives I = 0.01%/8h here (riba). Ours must give 0.
        assertEq(rate, 0, "iota=0: when mark==index, rate must be exactly 0, not a positive constant");
    }

    // ─────────────────────────────────────────────────────
    // Circuit breaker is symmetric (not a floor)
    // ─────────────────────────────────────────────────────

    function test_CircuitBreakerClampsPositive() public {
        // 5% premium → should be clamped to +75bps (MAX)
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  105e18);

        int256 rate = engine.getFundingRate(market);
        assertEq(rate, engine.MAX_FUNDING_RATE(), "Should clamp to +75bps max");
    }

    function test_CircuitBreakerClampsNegative() public {
        // 5% discount → should be clamped to -75bps (MIN)
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  95e18);

        int256 rate = engine.getFundingRate(market);
        assertEq(rate, engine.MIN_FUNDING_RATE(), "Should clamp to -75bps min");
    }

    function test_CircuitBreakerIsSymmetric() public {
        int256 maxRate = engine.MAX_FUNDING_RATE();
        int256 minRate = engine.MIN_FUNDING_RATE();
        assertEq(maxRate, -minRate, "Circuit breaker must be symmetric around zero");
    }

    // ─────────────────────────────────────────────────────
    // Fuzz tests
    // ─────────────────────────────────────────────────────

    /**
     * @notice Fuzz: verify ι=0 in all possible price combinations.
     *         The funding rate must NEVER have a positive interest floor.
     *         When mark <= index, rate must be <= 0.
     */
    function testFuzz_NeverHasInterestFloor(uint256 markSeed, uint256 indexSeed) public {
        // Bound to reasonable price range (1 wei to 1M ETH)
        uint256 index = bound(indexSeed, 1e6, 1_000_000e18);
        uint256 mark  = bound(markSeed,  1e6, 1_000_000e18);

        oracle.setIndexPrice(market, index);
        oracle.setMarkPrice(market,  mark);

        int256 rate = engine.getFundingRate(market);

        if (mark <= index) {
            // Rate must be <= 0 — no riba floor pulling it positive
            assertLe(rate, 0, "iota=0: when mark <= index, rate must be <= 0");
        } else {
            // Rate must be >= 0 when mark > index.
            // Note: integer truncation can round a tiny positive premium to 0
            // (e.g. diff=1 when index=1e24). This is correct — it is NOT a
            // negative interest floor. The invariant is rate >= 0, not rate > 0.
            assertGe(rate, 0, "Rate must be non-negative when mark > index");
        }
    }

    /**
     * @notice Fuzz: rate must always stay within ±75bps circuit breaker.
     */
    function testFuzz_AlwaysWithinCircuitBreaker(uint256 markSeed, uint256 indexSeed) public {
        uint256 index = bound(indexSeed, 1e6, 1_000_000e18);
        uint256 mark  = bound(markSeed,  1e6, 1_000_000e18);

        oracle.setIndexPrice(market, index);
        oracle.setMarkPrice(market,  mark);

        int256 rate    = engine.getFundingRate(market);
        int256 maxRate = engine.MAX_FUNDING_RATE();
        int256 minRate = engine.MIN_FUNDING_RATE();

        assertGe(rate, minRate, "Rate must not go below -75bps");
        assertLe(rate, maxRate, "Rate must not exceed +75bps");
    }

    // ─────────────────────────────────────────────────────
    // Cumulative funding updates
    // ─────────────────────────────────────────────────────

    function test_CumulativeFundingAccruesOverTime() public {
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  101e18); // 1% premium

        // Initialise
        vm.prank(owner);
        engine.updateCumulativeFunding(market);

        // Advance 3 hours → 3 intervals should accrue
        vm.warp(block.timestamp + 3 hours);

        vm.prank(owner);
        int256 cumulative = engine.updateCumulativeFunding(market);

        assertGt(cumulative, 0, "Cumulative index should be positive after 3 intervals with mark > index");
    }

    function test_CumulativeFundingNegativeWhenMarkBelowIndex() public {
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  99e18); // -1% discount

        vm.prank(owner);
        engine.updateCumulativeFunding(market);

        vm.warp(block.timestamp + 3 hours);

        vm.prank(owner);
        int256 cumulative = engine.updateCumulativeFunding(market);

        assertLt(cumulative, 0, "Cumulative index should be negative when mark < index");
    }

    // ─────────────────────────────────────────────────────
    // Access control
    // ─────────────────────────────────────────────────────

    function test_PauseStopsFundingRate() public {
        oracle.setIndexPrice(market, 100e18);
        oracle.setMarkPrice(market,  100e18);

        vm.prank(owner);
        engine.pause();

        vm.expectRevert();
        engine.getFundingRate(market);
    }

    function test_OnlyOwnerCanSetOracle() public {
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert();
        engine.setOracle(address(0x1));
    }
}
