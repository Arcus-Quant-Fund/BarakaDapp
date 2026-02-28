// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/insurance/InsuranceFund.sol";
import "../mocks/MockERC20.sol";

/**
 * @title InsuranceFundTest
 * @notice Full unit test coverage for InsuranceFund.sol
 *
 * Tests cover:
 *   - setAuthorised() — only owner, emits event, tracks mapping
 *   - receiveFromLiquidation() — basic receive, zero amount, not authorised, paused
 *   - coverShortfall() — basic cover, insufficient reserves, not authorised, paused
 *   - fundBalance() — accurate after receive/cover operations
 *   - distributeSurplus() — surplus condition (balance > 2x weekly), fails when not enough
 *   - Weekly claims tracker — reset after 7 days
 *   - pause/unpause — only owner, blocks receive/cover
 *   - Fuzz: coverShortfall never exceeds balance
 *   - Full lifecycle: receive -> cover -> surplus distribution
 */
contract InsuranceFundTest is Test {

    InsuranceFund public fund;
    MockERC20     public usdc;

    address public owner        = address(0xABCD);
    address public liquidator   = address(0xCAFE); // authorised caller
    address public pm           = address(0xBEEF); // another authorised caller (PositionManager)
    address public recipient    = address(0x7777); // surplus recipient
    address public attacker     = address(0xDEAD);

    uint256 constant SEED = 10_000e6; // 10,000 USDC seeded into fund

    function setUp() public {
        vm.startPrank(owner);
        fund = new InsuranceFund(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Authorise the liquidator and PM as callers
        fund.setAuthorised(liquidator, true);
        fund.setAuthorised(pm,         true);
        vm.stopPrank();

        // Seed fund with initial balance via authorised path
        usdc.mint(liquidator, SEED);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), SEED);
        fund.receiveFromLiquidation(address(usdc), SEED);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // setAuthorised()
    // ─────────────────────────────────────────────────────

    function test_setAuthorised_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        fund.setAuthorised(attacker, true);
    }

    function test_setAuthorised_setsMapping() public {
        address newCaller = address(0x9999);
        assertFalse(fund.authorised(newCaller));

        vm.prank(owner);
        fund.setAuthorised(newCaller, true);
        assertTrue(fund.authorised(newCaller));
    }

    function test_setAuthorised_canRevoke() public {
        assertTrue(fund.authorised(liquidator));
        vm.prank(owner);
        fund.setAuthorised(liquidator, false);
        assertFalse(fund.authorised(liquidator));
    }

    function test_setAuthorised_emitsEvent() public {
        address newCaller = address(0x9999);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit InsuranceFund.AuthorisedSet(newCaller, true);
        fund.setAuthorised(newCaller, true);
    }

    // ─────────────────────────────────────────────────────
    // receiveFromLiquidation()
    // ─────────────────────────────────────────────────────

    function test_receive_increasesBalance() public {
        uint256 before = fund.fundBalance(address(usdc));
        uint256 extra  = 500e6;

        usdc.mint(liquidator, extra);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), extra);
        fund.receiveFromLiquidation(address(usdc), extra);
        vm.stopPrank();

        assertEq(fund.fundBalance(address(usdc)), before + extra);
    }

    function test_receive_emitsEvent() public {
        uint256 amount = 200e6;
        usdc.mint(liquidator, amount);

        vm.startPrank(liquidator);
        usdc.approve(address(fund), amount);
        vm.expectEmit(true, false, true, true);
        emit InsuranceFund.FundReceived(address(usdc), amount, liquidator);
        fund.receiveFromLiquidation(address(usdc), amount);
        vm.stopPrank();
    }

    function test_receive_zeroAmountReverts() public {
        vm.prank(liquidator);
        vm.expectRevert("InsuranceFund: zero amount");
        fund.receiveFromLiquidation(address(usdc), 0);
    }

    function test_receive_notAuthorisedReverts() public {
        usdc.mint(attacker, 100e6);
        vm.startPrank(attacker);
        usdc.approve(address(fund), 100e6);
        vm.expectRevert("InsuranceFund: not authorised");
        fund.receiveFromLiquidation(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_receive_pausedReverts() public {
        vm.prank(owner);
        fund.pause();

        usdc.mint(liquidator, 100e6);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), 100e6);
        vm.expectRevert();
        fund.receiveFromLiquidation(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_receive_revokedCallerReverts() public {
        vm.prank(owner);
        fund.setAuthorised(liquidator, false);

        usdc.mint(liquidator, 100e6);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), 100e6);
        vm.expectRevert("InsuranceFund: not authorised");
        fund.receiveFromLiquidation(address(usdc), 100e6);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // coverShortfall()
    // ─────────────────────────────────────────────────────

    function test_coverShortfall_transfersToCallerAndReducesBalance() public {
        uint256 shortfall = 1_000e6;
        uint256 before    = fund.fundBalance(address(usdc));
        uint256 pmBefore  = usdc.balanceOf(pm);

        vm.prank(pm);
        fund.coverShortfall(address(usdc), shortfall);

        assertEq(fund.fundBalance(address(usdc)), before - shortfall);
        assertEq(usdc.balanceOf(pm),              pmBefore + shortfall);
    }

    function test_coverShortfall_emitsEvent() public {
        uint256 shortfall = 500e6;
        vm.prank(pm);
        vm.expectEmit(true, false, true, true);
        emit InsuranceFund.ShortfallCovered(address(usdc), shortfall, pm);
        fund.coverShortfall(address(usdc), shortfall);
    }

    function test_coverShortfall_zeroAmountReverts() public {
        vm.prank(pm);
        vm.expectRevert("InsuranceFund: zero amount");
        fund.coverShortfall(address(usdc), 0);
    }

    function test_coverShortfall_insufficientReverts() public {
        uint256 tooMuch = fund.fundBalance(address(usdc)) + 1;
        vm.prank(pm);
        vm.expectRevert("InsuranceFund: insufficient reserves");
        fund.coverShortfall(address(usdc), tooMuch);
    }

    function test_coverShortfall_notAuthorisedReverts() public {
        vm.prank(attacker);
        vm.expectRevert("InsuranceFund: not authorised");
        fund.coverShortfall(address(usdc), 100e6);
    }

    function test_coverShortfall_pausedReverts() public {
        vm.prank(owner);
        fund.pause();

        vm.prank(pm);
        vm.expectRevert();
        fund.coverShortfall(address(usdc), 100e6);
    }

    function test_coverShortfall_exactBalanceSucceeds() public {
        uint256 total = fund.fundBalance(address(usdc));
        vm.prank(pm);
        fund.coverShortfall(address(usdc), total);
        assertEq(fund.fundBalance(address(usdc)), 0);
    }

    // ─────────────────────────────────────────────────────
    // fundBalance()
    // ─────────────────────────────────────────────────────

    function test_fundBalance_startsAtSeedAmount() public view {
        assertEq(fund.fundBalance(address(usdc)), SEED);
    }

    function test_fundBalance_unknownTokenIsZero() public view {
        assertEq(fund.fundBalance(address(0xDEAD)), 0);
    }

    function test_fundBalance_reflectsReceiveAndCover() public {
        uint256 extra = 3_000e6;
        usdc.mint(liquidator, extra);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), extra);
        fund.receiveFromLiquidation(address(usdc), extra);
        vm.stopPrank();

        uint256 afterReceive = fund.fundBalance(address(usdc));
        assertEq(afterReceive, SEED + extra);

        uint256 cover = 1_000e6;
        vm.prank(pm);
        fund.coverShortfall(address(usdc), cover);

        assertEq(fund.fundBalance(address(usdc)), SEED + extra - cover);
    }

    // ─────────────────────────────────────────────────────
    // distributeSurplus()
    // ─────────────────────────────────────────────────────

    function test_distributeSurplus_whenNoClaimsDistributesAll() public {
        // No coverShortfall calls -> weeklyClaimsSum = 0
        // balance(10_000) > 2 * 0 = 0 -> surplus = 10_000
        uint256 before = fund.fundBalance(address(usdc));
        usdc.mint(address(fund), 0); // ensure fund actually holds tokens (seeded via constructor)

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        // surplus = balance - 2*0 = balance -> all distributed
        assertEq(fund.fundBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(recipient), before);
    }

    function test_distributeSurplus_emitsEvent() public {
        uint256 surplus = fund.fundBalance(address(usdc));
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit InsuranceFund.SurplusDistributed(address(usdc), surplus);
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_failsWhenNoSurplus() public {
        // Create a large weekly claim so balance is not > 2x weekly
        uint256 balance = fund.fundBalance(address(usdc));
        // cover half the balance — weeklyClaimsSum = balance/2
        // Then balance becomes balance/2, which is NOT > 2 * (balance/2) = balance
        uint256 claimAmt = balance / 2;
        vm.prank(pm);
        fund.coverShortfall(address(usdc), claimAmt);

        // Now: balance = balance/2, weeklyClaimsSum = balance/2
        // Condition: balance > 2 * weeklyClaimsSum => balance/2 > balance => false
        vm.prank(owner);
        vm.expectRevert("InsuranceFund: no surplus to distribute");
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_pausedReverts() public {
        vm.prank(owner);
        fund.pause();
        vm.prank(owner);
        vm.expectRevert();
        fund.distributeSurplus(address(usdc), recipient);
    }

    // ─────────────────────────────────────────────────────
    // Weekly claims tracker
    // ─────────────────────────────────────────────────────

    function test_weeklyClaimsSum_accumulatesWithinWeek() public {
        uint256 c1 = 200e6;
        uint256 c2 = 300e6;

        vm.prank(pm); fund.coverShortfall(address(usdc), c1);
        vm.warp(block.timestamp + 3 days); // still within 7-day window
        vm.prank(pm); fund.coverShortfall(address(usdc), c2);

        assertEq(fund.weeklyClaimsSum(address(usdc)), c1 + c2);
    }

    function test_weeklyClaimsSum_resetsAfterSevenDays() public {
        uint256 c1 = 500e6;
        vm.prank(pm);
        fund.coverShortfall(address(usdc), c1);
        assertEq(fund.weeklyClaimsSum(address(usdc)), c1);

        // Advance past 7 days
        vm.warp(block.timestamp + 7 days + 1);

        uint256 c2 = 100e6;
        vm.prank(pm);
        fund.coverShortfall(address(usdc), c2);

        // weeklyClaimsSum should reset to c2 only (c1 is gone)
        assertEq(fund.weeklyClaimsSum(address(usdc)), c2);
    }

    function test_lastClaimReset_updatedOnReset() public {
        vm.prank(pm);
        fund.coverShortfall(address(usdc), 100e6);
        uint256 firstReset = fund.lastClaimReset(address(usdc));

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(pm);
        fund.coverShortfall(address(usdc), 50e6);
        uint256 secondReset = fund.lastClaimReset(address(usdc));

        assertGt(secondReset, firstReset);
    }

    // ─────────────────────────────────────────────────────
    // pause / unpause
    // ─────────────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        fund.pause();
    }

    function test_unpause_restoresReceive() public {
        vm.prank(owner); fund.pause();
        vm.prank(owner); fund.unpause();

        uint256 amount = 100e6;
        usdc.mint(liquidator, amount);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), amount);
        fund.receiveFromLiquidation(address(usdc), amount);
        vm.stopPrank();

        assertEq(fund.fundBalance(address(usdc)), SEED + amount);
    }

    // ─────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────

    /**
     * @notice coverShortfall can never reduce fundBalance below zero.
     *         The contract reverts before that can happen.
     */
    function testFuzz_coverNeverExceedsBalance(uint256 amount) public {
        uint256 balance = fund.fundBalance(address(usdc));
        amount = bound(amount, 1, type(uint128).max);

        if (amount > balance) {
            vm.prank(pm);
            vm.expectRevert("InsuranceFund: insufficient reserves");
            fund.coverShortfall(address(usdc), amount);
        } else {
            vm.prank(pm);
            fund.coverShortfall(address(usdc), amount);
            assertGe(fund.fundBalance(address(usdc)), 0);
        }
    }

    /**
     * @notice Multiple receives always increase balance correctly.
     */
    function testFuzz_receiveAccumulates(uint256 a, uint256 b) public {
        a = bound(a, 1, 1_000_000e6);
        b = bound(b, 1, 1_000_000e6);

        uint256 before = fund.fundBalance(address(usdc));

        usdc.mint(liquidator, a + b);
        vm.startPrank(liquidator);
        usdc.approve(address(fund), a + b);
        fund.receiveFromLiquidation(address(usdc), a);
        fund.receiveFromLiquidation(address(usdc), b);
        vm.stopPrank();

        assertEq(fund.fundBalance(address(usdc)), before + a + b);
    }
}
