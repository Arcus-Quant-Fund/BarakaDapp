// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/FundingEngine.sol";
import "../mocks/MockOracleAdapter.sol";

/**
 * @title FundingEngineTest
 * @notice Unit tests for FundingEngine: initialization, funding accrual,
 *         premium computation, clamping, clock freeze on staleness,
 *         elapsed cap, pending funding, and admin controls.
 */
contract FundingEngineTest is Test {

    uint256 constant WAD = 1e18;
    uint256 constant FUNDING_PERIOD = 8 hours;
    bytes32 constant BTC = keccak256("BTC-USD");

    FundingEngine     fundingEngine;
    MockOracleAdapter oracle;

    address owner = address(0xABCD);

    function setUp() public {
        vm.startPrank(owner);
        oracle = new MockOracleAdapter();
        fundingEngine = new FundingEngine(owner, address(oracle));

        // Set default clamp rate: (20% IMR - 5% MMR) * 0.9 = 13.5%
        fundingEngine.setClampRate(BTC, 0.135e18);
        vm.stopPrank();

        // Set oracle prices: mark = index = 50000
        oracle.setIndexPrice(BTC, 50_000e18);
        oracle.setMarkPrice(BTC, 50_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 1. Constructor
    // ═══════════════════════════════════════════════════════

    function test_constructor_setsOracle() public view {
        assertEq(address(fundingEngine.oracle()), address(oracle));
    }

    function test_constructor_revert_zeroOracle() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero oracle");
        new FundingEngine(owner, address(0));
    }

    // ═══════════════════════════════════════════════════════
    // 2. Clamp rate admin
    // ═══════════════════════════════════════════════════════

    function test_setClampRate_basic() public {
        vm.prank(owner);
        fundingEngine.setClampRate(BTC, 0.10e18);
        assertEq(fundingEngine.clampRate(BTC), 0.10e18);
    }

    function test_setClampRate_revert_zero() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero clamp rate");
        fundingEngine.setClampRate(BTC, 0);
    }

    function test_setClampRate_revert_tooHigh() public {
        vm.prank(owner);
        vm.expectRevert("FE: clamp rate > 100% per 8h");
        fundingEngine.setClampRate(BTC, WAD + 1);
    }

    function test_setClampRate_revert_nonOwner() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        fundingEngine.setClampRate(BTC, 0.10e18);
    }

    // ═══════════════════════════════════════════════════════
    // 3. First updateFunding — initialization
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_firstCall_initializesTime() public {
        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, 0);
        (,uint256 lastUpdate,) = fundingEngine.fundingState(BTC);
        assertEq(lastUpdate, block.timestamp);
    }

    function test_updateFunding_sameBlock_noOp() public {
        fundingEngine.updateFunding(BTC);
        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, 0); // No time elapsed
    }

    // ═══════════════════════════════════════════════════════
    // 4. Funding accrual — zero premium
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_zeroPremium_noAccrual() public {
        // mark == index → premium = 0
        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + 1 hours);

        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, 0);
    }

    // ═══════════════════════════════════════════════════════
    // 5. Funding accrual — positive premium (longs pay)
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_positivePremium() public {
        // mark = 51000, index = 50000 → premium = 1000/50000 = 0.02 per 8h
        oracle.setMarkPrice(BTC, 51_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + FUNDING_PERIOD);

        int256 idx = fundingEngine.updateFunding(BTC);
        // rate = 0.02e18, elapsed = 8h, accrual = 0.02e18 * 28800 / 28800 = 0.02e18
        assertEq(idx, 0.02e18);
    }

    // ═══════════════════════════════════════════════════════
    // 6. Funding accrual — negative premium (shorts pay)
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_negativePremium() public {
        // mark = 49000, index = 50000 → premium = -1000/50000 = -0.02 per 8h
        oracle.setMarkPrice(BTC, 49_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + FUNDING_PERIOD);

        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, -0.02e18);
    }

    // ═══════════════════════════════════════════════════════
    // 7. Clamping
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_clampedAtMax() public {
        // mark = 100000, index = 50000 → premium = 1.0 per 8h, clamped to 0.135
        oracle.setMarkPrice(BTC, 100_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + FUNDING_PERIOD);

        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, 0.135e18);
    }

    function test_updateFunding_clampedAtMin() public {
        // mark = 1000, index = 50000 → premium = -0.98 per 8h, clamped to -0.135
        oracle.setMarkPrice(BTC, 1_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + FUNDING_PERIOD);

        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, -0.135e18);
    }

    // ═══════════════════════════════════════════════════════
    // 8. Elapsed time cap
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_elapsedCappedAtFundingPeriod() public {
        oracle.setMarkPrice(BTC, 51_000e18); // 2% premium

        fundingEngine.updateFunding(BTC);
        // Advance 24 hours (3x funding period)
        vm.warp(block.timestamp + 24 hours);

        int256 idx = fundingEngine.updateFunding(BTC);
        // Capped at 8h: accrual = 0.02 * 28800 / 28800 = 0.02
        assertEq(idx, 0.02e18);
    }

    // ═══════════════════════════════════════════════════════
    // 9. Clock freeze during oracle staleness
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_freezesDuringStaleOracle() public {
        oracle.setMarkPrice(BTC, 51_000e18);
        oracle.setIndexPrice(BTC, 50_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + 1 hours);

        // Make oracle stale
        oracle.setIndexPrice(BTC, 0);

        // Should return unchanged index (clock frozen, wasStale flag set)
        int256 idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, 0);

        // Restore oracle
        oracle.setIndexPrice(BTC, 50_000e18);
        vm.warp(block.timestamp + 4 hours);

        // P10-M-7: First call after recovery resets the clock without accruing.
        // Prevents a retroactive funding spike at post-recovery rates for the entire outage duration.
        idx = fundingEngine.updateFunding(BTC);
        assertEq(idx, 0, "P10-M-7: no retroactive spike on oracle recovery");

        // Normal accrual resumes from the reset point
        vm.warp(block.timestamp + FUNDING_PERIOD);
        idx = fundingEngine.updateFunding(BTC);
        // rate = 0.02, elapsed = 8h, accrual = 0.02 * 28800 / 28800 = 0.02
        assertEq(idx, 0.02e18, "P10-M-7: normal accrual resumes after recovery");
    }

    // ═══════════════════════════════════════════════════════
    // 10. getCurrentRate
    // ═══════════════════════════════════════════════════════

    function test_getCurrentRate_zeroPremium() public view {
        assertEq(fundingEngine.getCurrentRate(BTC), 0);
    }

    function test_getCurrentRate_positivePremium() public {
        oracle.setMarkPrice(BTC, 51_000e18);
        // premium = 1000/50000 = 0.02
        assertEq(fundingEngine.getCurrentRate(BTC), 0.02e18);
    }

    function test_getCurrentRate_zeroWhenStale() public {
        oracle.setMarkPrice(BTC, 51_000e18);
        oracle.setIndexPrice(BTC, 0); // stale
        assertEq(fundingEngine.getCurrentRate(BTC), 0);
    }

    // ═══════════════════════════════════════════════════════
    // 11. getPendingFunding
    // ═══════════════════════════════════════════════════════

    function test_getPendingFunding_longPaysPositivePremium() public {
        oracle.setMarkPrice(BTC, 51_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + FUNDING_PERIOD);

        // 1 BTC long, entry at cumulative=0
        int256 pending = fundingEngine.getPendingFunding(BTC, 1e18, 0);
        // indexDelta = 0.02e18 (will include accrued + pending)
        // funding = 0.02 * 1 = 0.02e18 → positive = position owes
        assertGt(pending, 0);
    }

    function test_getPendingFunding_shortReceivesPositivePremium() public {
        oracle.setMarkPrice(BTC, 51_000e18);

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + FUNDING_PERIOD);

        // 1 BTC short
        int256 pending = fundingEngine.getPendingFunding(BTC, -1e18, 0);
        assertLt(pending, 0); // Negative = receives funding
    }

    function test_getPendingFunding_uninitializedMarket_returnsZero() public view {
        bytes32 fakeMarket = keccak256("FAKE");
        assertEq(fundingEngine.getPendingFunding(fakeMarket, 1e18, 0), 0);
    }

    // ═══════════════════════════════════════════════════════
    // 12. Permissionless — anyone can call updateFunding
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_permissionless() public {
        address randomKeeper = address(0x9999);
        vm.prank(randomKeeper);
        fundingEngine.updateFunding(BTC);
        (,uint256 lastUpdate,) = fundingEngine.fundingState(BTC);
        assertEq(lastUpdate, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════
    // 13. Clamp rate must be set
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_revert_noClampRate() public {
        bytes32 noClampMarket = keccak256("NO-CLAMP");
        oracle.setIndexPrice(noClampMarket, 50_000e18);
        oracle.setMarkPrice(noClampMarket, 51_000e18);

        fundingEngine.updateFunding(noClampMarket); // init
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert("FE: clamp rate not set");
        fundingEngine.updateFunding(noClampMarket);
    }

    // ═══════════════════════════════════════════════════════
    // 14. Renounce ownership
    // ═══════════════════════════════════════════════════════

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert("FE: renounce disabled");
        fundingEngine.renounceOwnership();
    }

    // ═══════════════════════════════════════════════════════
    // 15. Partial period accrual
    // ═══════════════════════════════════════════════════════

    function test_updateFunding_halfPeriod() public {
        oracle.setMarkPrice(BTC, 51_000e18); // 2% premium

        fundingEngine.updateFunding(BTC);
        vm.warp(block.timestamp + 4 hours); // half period

        int256 idx = fundingEngine.updateFunding(BTC);
        // accrual = 0.02 * 14400 / 28800 = 0.01
        assertEq(idx, 0.01e18);
    }
}
