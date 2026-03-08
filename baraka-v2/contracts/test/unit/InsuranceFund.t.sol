// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/risk/InsuranceFund.sol";
import "../mocks/MockERC20.sol";

/**
 * @title InsuranceFundTest
 * @notice Comprehensive unit tests for the InsuranceFund contract.
 */
contract InsuranceFundTest is Test {
    InsuranceFund fund;
    MockERC20 usdc;
    MockERC20 weth;

    address owner    = address(0xABCD);
    address authorisedCaller = address(0x1111);
    address alice    = address(0x2222);
    address bob      = address(0x3333);
    address recipient = address(0x4444);
    address stranger = address(0x9999);

    uint256 constant WAD = 1e18;
    uint256 constant USDC_UNIT = 1e6;

    event FundReceived(address indexed token, uint256 amount, address indexed from);
    event ShortfallCovered(address indexed token, uint256 amount, address indexed beneficiary);
    event PnlPaid(address indexed token, uint256 amount, address indexed recipient);
    event PnlUnderpaid(address indexed token, uint256 requested, uint256 paid, address indexed recipient);
    event SurplusDistributed(address indexed token, uint256 amount, address indexed recipient);
    event AuthorisedSet(address indexed caller, bool status);

    function setUp() public {
        vm.startPrank(owner);

        fund = new InsuranceFund(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);

        // Authorise the caller
        fund.setAuthorised(authorisedCaller, true);

        // Approve the surplus recipient
        fund.setSurplusRecipient(recipient, true);

        vm.stopPrank();

        // Mint tokens for the authorised caller
        usdc.mint(authorisedCaller, 1_000_000 * USDC_UNIT);
        weth.mint(authorisedCaller, 1_000 * WAD);

        // Approve InsuranceFund to spend tokens
        vm.prank(authorisedCaller);
        usdc.approve(address(fund), type(uint256).max);
        vm.prank(authorisedCaller);
        weth.approve(address(fund), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════
    //  receive_()
    // ═══════════════════════════════════════════════════════

    function test_receive_happyPath() public {
        uint256 amount = 5000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), amount);

        assertEq(fund.fundBalance(address(usdc)), amount);
        assertEq(usdc.balanceOf(address(fund)), amount);
    }

    function test_receive_emitsEvent() public {
        uint256 amount = 1000 * USDC_UNIT;

        vm.expectEmit(true, true, true, true);
        emit FundReceived(address(usdc), amount, authorisedCaller);

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), amount);
    }

    function test_receive_multipleDeposits() public {
        uint256 first = 1000 * USDC_UNIT;
        uint256 second = 2000 * USDC_UNIT;

        vm.startPrank(authorisedCaller);
        fund.receive_(address(usdc), first);
        fund.receive_(address(usdc), second);
        vm.stopPrank();

        assertEq(fund.fundBalance(address(usdc)), first + second);
    }

    function test_receive_revertsUnauthorised() public {
        vm.prank(stranger);
        vm.expectRevert("IF: not authorised");
        fund.receive_(address(usdc), 1000);
    }

    function test_receive_revertsZeroAmount() public {
        vm.prank(authorisedCaller);
        vm.expectRevert("IF: zero amount");
        fund.receive_(address(usdc), 0);
    }

    /// AUDIT FIX (P5-M-17): receive_() no longer has whenNotPaused — fund must be
    /// replenishable during pause. Verify it succeeds when paused.
    function test_receive_succeedsWhenPaused() public {
        vm.prank(owner);
        fund.pause();

        uint256 amount = 1000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), amount);

        assertEq(fund.fundBalance(address(usdc)), amount);
    }

    // ═══════════════════════════════════════════════════════
    //  coverShortfall()
    // ═══════════════════════════════════════════════════════

    function test_coverShortfall_happyPath() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 shortfall = 3_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        uint256 callerBefore = usdc.balanceOf(authorisedCaller);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), shortfall);

        assertEq(fund.fundBalance(address(usdc)), deposit - shortfall);
        assertEq(usdc.balanceOf(authorisedCaller), callerBefore + shortfall);
    }

    function test_coverShortfall_emitsEvent() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 shortfall = 1_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.expectEmit(true, true, true, true);
        emit ShortfallCovered(address(usdc), shortfall, authorisedCaller);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), shortfall);
    }

    function test_coverShortfall_updatesWeeklyClaims() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 shortfall = 1_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), shortfall);

        assertEq(fund.weeklyClaimsSum(address(usdc)), shortfall);
    }

    function test_coverShortfall_revertsUnauthorised() public {
        vm.prank(stranger);
        vm.expectRevert("IF: not authorised");
        fund.coverShortfall(address(usdc), 1000);
    }

    function test_coverShortfall_revertsZeroAmount() public {
        vm.prank(authorisedCaller);
        vm.expectRevert("IF: zero amount");
        fund.coverShortfall(address(usdc), 0);
    }

    function test_coverShortfall_revertsInsufficientReserves() public {
        uint256 deposit = 1_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        vm.expectRevert("IF: insufficient reserves");
        fund.coverShortfall(address(usdc), deposit + 1);
    }

    /// P3-LIQ-5 FIX: coverShortfall() no longer blocked by pause — liquidation shortfall coverage
    /// must be pause-immune (same rationale as P2-CRIT-3 / P2-HIGH-4). Test updated to verify
    /// coverShortfall() succeeds even when IF is paused.
    function test_coverShortfall_succeedsWhenPaused() public {
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 10_000 * USDC_UNIT);

        vm.prank(owner);
        fund.pause();

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1000); // must NOT revert
        assertEq(fund.fundBalance(address(usdc)), 10_000 * USDC_UNIT - 1000);
    }

    // ═══════════════════════════════════════════════════════
    //  payPnl()
    // ═══════════════════════════════════════════════════════

    function test_payPnl_fullPayment() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 pnl = 2_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), pnl, alice);

        assertEq(fund.fundBalance(address(usdc)), deposit - pnl);
        assertEq(usdc.balanceOf(alice), pnl);
    }

    function test_payPnl_emitsPnlPaid() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 pnl = 2_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.expectEmit(true, true, true, true);
        emit PnlPaid(address(usdc), pnl, alice);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), pnl, alice);
    }

    function test_payPnl_partialPayment_capsAtBalance() public {
        uint256 deposit = 1_000 * USDC_UNIT;
        uint256 requested = 5_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), requested, alice);

        // Should have paid the full balance
        assertEq(usdc.balanceOf(alice), deposit);
        assertEq(fund.fundBalance(address(usdc)), 0);
    }

    function test_payPnl_partialPayment_emitsPnlUnderpaid() public {
        uint256 deposit = 1_000 * USDC_UNIT;
        uint256 requested = 5_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.expectEmit(true, true, true, true);
        emit PnlPaid(address(usdc), deposit, alice);
        vm.expectEmit(true, true, true, true);
        emit PnlUnderpaid(address(usdc), requested, deposit, alice);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), requested, alice);
    }

    function test_payPnl_zeroBalance_noTransfer() public {
        // Fund has zero balance for this token. payPnl should not revert but
        // should do nothing (early return when actual == 0).
        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), 1_000 * USDC_UNIT, alice);

        assertEq(usdc.balanceOf(alice), 0);
        assertEq(fund.fundBalance(address(usdc)), 0);
    }

    function test_payPnl_revertsUnauthorised() public {
        vm.prank(stranger);
        vm.expectRevert("IF: not authorised");
        fund.payPnl(address(usdc), 1000, alice);
    }

    function test_payPnl_revertsZeroAmount() public {
        vm.prank(authorisedCaller);
        vm.expectRevert("IF: zero amount");
        fund.payPnl(address(usdc), 0, alice);
    }

    function test_payPnl_revertsZeroRecipient() public {
        vm.prank(authorisedCaller);
        vm.expectRevert("IF: zero recipient");
        fund.payPnl(address(usdc), 1000, address(0));
    }

    function test_payPnl_revertsWhenPaused() public {
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 10_000 * USDC_UNIT);

        vm.prank(owner);
        fund.pause();

        vm.prank(authorisedCaller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fund.payPnl(address(usdc), 1000, alice);
    }

    function test_payPnl_updatesWeeklyClaims() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 pnl = 2_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), pnl, alice);

        assertEq(fund.weeklyClaimsSum(address(usdc)), pnl);
    }

    // ═══════════════════════════════════════════════════════
    //  distributeSurplus()
    // ═══════════════════════════════════════════════════════

    function test_distributeSurplus_happyPath() public {
        // Deposit a large amount with zero claims -> floor = 20% of balance
        uint256 deposit = 100_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // surplus = balance - max(2*weeklyClaims, 20%*balance)
        // weeklyClaims = 0, so floor = 20% of 100_000 = 20_000
        // surplus = 100_000 - 20_000 = 80_000
        uint256 expectedSurplus = 80_000 * USDC_UNIT;

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        assertEq(usdc.balanceOf(recipient), expectedSurplus);
        assertEq(fund.fundBalance(address(usdc)), deposit - expectedSurplus);
    }

    function test_distributeSurplus_emitsEvent() public {
        uint256 deposit = 100_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        uint256 expectedSurplus = 80_000 * USDC_UNIT;

        vm.expectEmit(true, true, true, true);
        emit SurplusDistributed(address(usdc), expectedSurplus, recipient);

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_revertsUnapprovedRecipient() public {
        vm.prank(owner);
        vm.expectRevert("IF: recipient not approved");
        fund.distributeSurplus(address(usdc), stranger);
    }

    function test_distributeSurplus_7dayCooldownBetweenDistributions() public {
        uint256 deposit = 100_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        // Deposit more to make surplus available again
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 100_000 * USDC_UNIT);

        // Immediately try again — should fail
        vm.prank(owner);
        vm.expectRevert("IF: distribution cooldown");
        fund.distributeSurplus(address(usdc), recipient);

        // Warp 6 days 23 hours — still too early
        vm.warp(block.timestamp + 7 days - 1);
        vm.prank(owner);
        vm.expectRevert("IF: distribution cooldown");
        fund.distributeSurplus(address(usdc), recipient);

        // Warp 1 more second (exactly 7 days) — should succeed
        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_24hCooldownAfterWeeklyReset() public {
        uint256 deposit = 100_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // Make a claim to set lastClaimReset
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1_000 * USDC_UNIT);

        // Warp 7 days to trigger the EWMA reset on next claim
        vm.warp(block.timestamp + 7 days);

        // Another claim triggers the weekly reset (lastClaimReset = now)
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 50_000 * USDC_UNIT); // top up
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 100 * USDC_UNIT);

        // Now lastClaimReset = block.timestamp. Try distribution immediately.
        vm.prank(owner);
        vm.expectRevert("IF: cooldown after weekly reset");
        fund.distributeSurplus(address(usdc), recipient);

        // Warp 24 hours
        vm.warp(block.timestamp + 24 hours);

        // Now it should pass the 24h cooldown (also need to clear 7-day
        // distribution cooldown — but lastDistribution is still 0 so that's fine)
        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_revertsNoSurplus() public {
        // Deposit a small amount, then claim most of it so floor > balance
        uint256 deposit = 10_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // Claim 8000 -> weeklyClaims = 8000, balance = 2000
        // floor = max(2*8000, 20%*2000) = max(16000, 400) = 16000
        // 2000 > 16000 is false -> no surplus
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 8_000 * USDC_UNIT);

        // Warp past 24h cooldown (coverShortfall sets lastClaimReset)
        vm.warp(block.timestamp + 24 hours);

        vm.prank(owner);
        vm.expectRevert("IF: no surplus");
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_distributeSurplus_revertsWhenPaused() public {
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(owner);
        fund.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fund.distributeSurplus(address(usdc), recipient);
    }

    // ═══════════════════════════════════════════════════════
    //  Surplus calculation: floor = max(2x claims, 20% bal)
    // ═══════════════════════════════════════════════════════

    function test_surplusCalc_claimsFloorDominates() public {
        // balance = 100_000, weeklyClaims = 30_000
        // claimsFloor = 60_000, reserveFloor = 20_000 -> floor = 60_000
        // surplus = 40_000
        uint256 deposit = 100_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 30_000 * USDC_UNIT);
        // balance now 70_000, weeklyClaims = 30_000

        // Top up back to 100_000
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 30_000 * USDC_UNIT);
        // balance = 100_000, weeklyClaims = 30_000

        // Warp past 24h cooldown (coverShortfall sets lastClaimReset)
        vm.warp(block.timestamp + 24 hours);

        // floor = max(2*30_000, 20%*100_000) = max(60_000, 20_000) = 60_000
        // surplus = 100_000 - 60_000 = 40_000
        uint256 expectedSurplus = 40_000 * USDC_UNIT;

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        assertEq(usdc.balanceOf(recipient), expectedSurplus);
    }

    function test_surplusCalc_reserveFloorDominates() public {
        // balance = 100_000, weeklyClaims = 5_000
        // claimsFloor = 10_000, reserveFloor = 20_000 -> floor = 20_000
        // surplus = 80_000
        uint256 deposit = 100_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 5_000 * USDC_UNIT);

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 5_000 * USDC_UNIT);
        // balance = 100_000, weeklyClaims = 5_000

        // Warp past 24h cooldown (coverShortfall sets lastClaimReset)
        vm.warp(block.timestamp + 24 hours);

        // floor = max(10_000, 20_000) = 20_000
        // surplus = 80_000
        uint256 expectedSurplus = 80_000 * USDC_UNIT;

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        assertEq(usdc.balanceOf(recipient), expectedSurplus);
    }

    function test_surplusCalc_equalFloors() public {
        // Want: 2*weeklyClaims == 20%*balance
        // 2*W = 0.2*B  ->  W = 0.1*B
        // balance = 100_000, weeklyClaims = 10_000
        // floor = max(20_000, 20_000) = 20_000
        // surplus = 80_000

        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 10_000 * USDC_UNIT);

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 10_000 * USDC_UNIT);

        // Warp past 24h cooldown (coverShortfall sets lastClaimReset)
        vm.warp(block.timestamp + 24 hours);

        uint256 expectedSurplus = 80_000 * USDC_UNIT;

        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        assertEq(usdc.balanceOf(recipient), expectedSurplus);
    }

    // ═══════════════════════════════════════════════════════
    //  EWMA decay: weeklyClaims halved after 7 days
    // ═══════════════════════════════════════════════════════

    function test_ewmaDecay_claimsHalvedAfter7Days() public {
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // Claim 10_000
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 10_000 * USDC_UNIT);
        assertEq(fund.weeklyClaimsSum(address(usdc)), 10_000 * USDC_UNIT);

        // Warp 7 days and trigger another claim
        vm.warp(block.timestamp + 7 days);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 2_000 * USDC_UNIT);

        // Previous 10_000 decayed to 5_000, plus new 2_000 = 7_000
        assertEq(fund.weeklyClaimsSum(address(usdc)), 7_000 * USDC_UNIT);
    }

    function test_ewmaDecay_multipleDecayPeriods() public {
        // Use explicit absolute timestamps to avoid any ambiguity
        uint256 t0 = block.timestamp;
        uint256 deposit = 500_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // Claim 40_000 at t0
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 40_000 * USDC_UNIT);
        assertEq(fund.weeklyClaimsSum(address(usdc)), 40_000 * USDC_UNIT);

        // Warp to t0 + 7 days, claim 1 to trigger decay
        vm.warp(t0 + 7 days);
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1 * USDC_UNIT);
        // 40_000 / 2 + 1 = 20_001
        assertEq(fund.weeklyClaimsSum(address(usdc)), 20_001 * USDC_UNIT);

        // Warp to t0 + 14 days, claim 1 to trigger decay
        // L3-M-9: multi-period decay — 2 periods elapsed since lastClaimReset,
        // so claims halved twice: 20_001_000_000 / 4 = 5_000_250_000
        // Plus new claim: 5_000_250_000 + 1_000_000 = 5_001_250_000
        vm.warp(t0 + 14 days);
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1 * USDC_UNIT);
        assertEq(fund.weeklyClaimsSum(address(usdc)), 5_001_250_000);
    }

    function test_ewmaDecay_noDecayWithin7Days() public {
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 10_000 * USDC_UNIT);

        // Warp only 6 days - no decay
        vm.warp(block.timestamp + 6 days);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 5_000 * USDC_UNIT);

        // No decay, just accumulation: 10_000 + 5_000 = 15_000
        assertEq(fund.weeklyClaimsSum(address(usdc)), 15_000 * USDC_UNIT);
    }

    function test_ewmaDecay_viaPayPnl() public {
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // payPnl also calls _updateWeeklyClaims
        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), 8_000 * USDC_UNIT, alice);
        assertEq(fund.weeklyClaimsSum(address(usdc)), 8_000 * USDC_UNIT);

        vm.warp(block.timestamp + 7 days);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), 2_000 * USDC_UNIT, bob);
        // Decayed: 8_000 / 2 + 2_000 = 6_000
        assertEq(fund.weeklyClaimsSum(address(usdc)), 6_000 * USDC_UNIT);
    }

    // ═══════════════════════════════════════════════════════
    //  setAuthorised()
    // ═══════════════════════════════════════════════════════

    function test_setAuthorised_grant() public {
        vm.prank(owner);
        fund.setAuthorised(alice, true);

        assertTrue(fund.authorised(alice));
    }

    function test_setAuthorised_revoke() public {
        vm.prank(owner);
        fund.setAuthorised(alice, true);

        vm.prank(owner);
        fund.setAuthorised(alice, false);

        assertFalse(fund.authorised(alice));
    }

    function test_setAuthorised_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit AuthorisedSet(alice, true);

        vm.prank(owner);
        fund.setAuthorised(alice, true);
    }

    function test_setAuthorised_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.setAuthorised(alice, true);
    }

    function test_setAuthorised_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("IF: zero address");
        fund.setAuthorised(address(0), true);
    }

    // ═══════════════════════════════════════════════════════
    //  setSurplusRecipient()
    // ═══════════════════════════════════════════════════════

    function test_setSurplusRecipient_approve() public {
        vm.prank(owner);
        fund.setSurplusRecipient(alice, true);

        assertTrue(fund.approvedSurplusRecipients(alice));
    }

    function test_setSurplusRecipient_revoke() public {
        vm.prank(owner);
        fund.setSurplusRecipient(alice, true);
        vm.prank(owner);
        fund.setSurplusRecipient(alice, false);

        assertFalse(fund.approvedSurplusRecipients(alice));
    }

    function test_setSurplusRecipient_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.setSurplusRecipient(alice, true);
    }

    function test_setSurplusRecipient_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("IF: zero recipient");
        fund.setSurplusRecipient(address(0), true);
    }

    // ═══════════════════════════════════════════════════════
    //  recoverToken()
    // ═══════════════════════════════════════════════════════

    function test_recoverToken_happyPath() public {
        uint256 deposit = 10_000 * USDC_UNIT;
        uint256 accidental = 500 * USDC_UNIT;

        // Proper deposit via receive_
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // Accidentally send tokens directly (not tracked)
        usdc.mint(address(fund), accidental);

        // Actual = deposit + accidental, tracked = deposit
        // Excess = accidental
        vm.prank(owner);
        fund.recoverToken(address(usdc), alice);

        assertEq(usdc.balanceOf(alice), accidental);
        // Fund balance unchanged
        assertEq(fund.fundBalance(address(usdc)), deposit);
    }

    function test_recoverToken_revertsNothingToRecover() public {
        uint256 deposit = 10_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        // No excess — actual == tracked
        vm.prank(owner);
        vm.expectRevert("IF: nothing to recover");
        fund.recoverToken(address(usdc), alice);
    }

    function test_recoverToken_revertsZeroTo() public {
        vm.prank(owner);
        vm.expectRevert("IF: zero to");
        fund.recoverToken(address(usdc), address(0));
    }

    function test_recoverToken_revertsNotOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.recoverToken(address(usdc), alice);
    }

    function test_recoverToken_untrackedToken() public {
        // Send a token that was never deposited via receive_
        uint256 amount = 1_000 * WAD;
        weth.mint(address(fund), amount);

        vm.prank(owner);
        fund.recoverToken(address(weth), alice);

        assertEq(weth.balanceOf(alice), amount);
        assertEq(fund.fundBalance(address(weth)), 0);
    }

    // ═══════════════════════════════════════════════════════
    //  Pause / Unpause
    // ═══════════════════════════════════════════════════════

    function test_pause_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.pause();
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        fund.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        fund.unpause();
    }

    function test_unpause_resumesOperations() public {
        uint256 amount = 5_000 * USDC_UNIT;

        vm.prank(owner);
        fund.pause();

        vm.prank(owner);
        fund.unpause();

        // Should work again
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), amount);

        assertEq(fund.fundBalance(address(usdc)), amount);
    }

    function test_pause_blocksAllMutativeOps() public {
        uint256 deposit = 50_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(owner);
        fund.pause();

        // receive_ — pause-immune (P5-M-17 fix); should succeed
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 1000);

        // coverShortfall — pause-immune (P3-LIQ-5 fix); should succeed
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1000);

        // payPnl
        vm.prank(authorisedCaller);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fund.payPnl(address(usdc), 1000, alice);

        // distributeSurplus
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_pause_viewFunctionsStillWork() public {
        uint256 deposit = 5_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(owner);
        fund.pause();

        // View functions should still work
        assertEq(fund.fundBalance(address(usdc)), deposit);
        assertTrue(fund.authorised(authorisedCaller));
    }

    // ═══════════════════════════════════════════════════════
    //  Multiple tokens tracked independently
    // ═══════════════════════════════════════════════════════

    function test_multipleTokens_independentBalances() public {
        uint256 usdcAmount = 10_000 * USDC_UNIT;
        uint256 wethAmount = 5 * WAD;

        vm.startPrank(authorisedCaller);
        fund.receive_(address(usdc), usdcAmount);
        fund.receive_(address(weth), wethAmount);
        vm.stopPrank();

        assertEq(fund.fundBalance(address(usdc)), usdcAmount);
        assertEq(fund.fundBalance(address(weth)), wethAmount);
    }

    function test_multipleTokens_independentClaims() public {
        vm.startPrank(authorisedCaller);
        fund.receive_(address(usdc), 100_000 * USDC_UNIT);
        fund.receive_(address(weth), 100 * WAD);

        fund.coverShortfall(address(usdc), 5_000 * USDC_UNIT);
        fund.coverShortfall(address(weth), 10 * WAD);
        vm.stopPrank();

        assertEq(fund.weeklyClaimsSum(address(usdc)), 5_000 * USDC_UNIT);
        assertEq(fund.weeklyClaimsSum(address(weth)), 10 * WAD);
    }

    function test_multipleTokens_independentDistributionCooldowns() public {
        // Deposit into both
        vm.startPrank(authorisedCaller);
        fund.receive_(address(usdc), 100_000 * USDC_UNIT);
        fund.receive_(address(weth), 100 * WAD);
        vm.stopPrank();

        // Approve another recipient for weth
        vm.prank(owner);
        fund.setSurplusRecipient(bob, true);

        // Distribute USDC surplus
        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        // WETH should still be distributable (independent cooldown)
        vm.prank(owner);
        fund.distributeSurplus(address(weth), bob);

        // USDC should be on cooldown
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), 100_000 * USDC_UNIT);

        vm.prank(owner);
        vm.expectRevert("IF: distribution cooldown");
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_multipleTokens_independentEwmaDecay() public {
        vm.startPrank(authorisedCaller);
        fund.receive_(address(usdc), 200_000 * USDC_UNIT);
        fund.receive_(address(weth), 200 * WAD);

        fund.coverShortfall(address(usdc), 20_000 * USDC_UNIT);
        fund.coverShortfall(address(weth), 40 * WAD);
        vm.stopPrank();

        // Warp 7 days
        vm.warp(block.timestamp + 7 days);

        // Trigger decay only for USDC
        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1_000 * USDC_UNIT);

        // USDC decayed: 20_000 / 2 + 1_000 = 11_000
        assertEq(fund.weeklyClaimsSum(address(usdc)), 11_000 * USDC_UNIT);
        // WETH not yet decayed (no claim triggered)
        assertEq(fund.weeklyClaimsSum(address(weth)), 40 * WAD);
    }

    // ═══════════════════════════════════════════════════════
    //  Edge cases
    // ═══════════════════════════════════════════════════════

    function test_coverShortfall_exactBalance() public {
        uint256 deposit = 5_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), deposit);

        assertEq(fund.fundBalance(address(usdc)), 0);
    }

    function test_payPnl_exactBalance() public {
        uint256 deposit = 5_000 * USDC_UNIT;

        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.payPnl(address(usdc), deposit, alice);

        assertEq(fund.fundBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(alice), deposit);
    }

    function test_distributeSurplus_setsLastDistributionTimestamp() public {
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        uint256 ts = block.timestamp;
        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);

        assertEq(fund.lastDistribution(address(usdc)), ts);
    }

    function test_distributeSurplus_firstDistribution_noCooldownIssue() public {
        // When lastDistribution[token] == 0 and lastClaimReset[token] == 0,
        // both cooldown checks pass.
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        assertEq(fund.lastDistribution(address(usdc)), 0);
        assertEq(fund.lastClaimReset(address(usdc)), 0);

        // Should succeed
        vm.prank(owner);
        fund.distributeSurplus(address(usdc), recipient);
    }

    function test_ewmaDecay_claimsResetSetsLastClaimReset() public {
        uint256 deposit = 100_000 * USDC_UNIT;
        vm.prank(authorisedCaller);
        fund.receive_(address(usdc), deposit);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 1_000 * USDC_UNIT);

        uint256 resetTime = block.timestamp;

        // Warp 7 days to trigger reset
        vm.warp(resetTime + 7 days);

        vm.prank(authorisedCaller);
        fund.coverShortfall(address(usdc), 100 * USDC_UNIT);

        assertEq(fund.lastClaimReset(address(usdc)), resetTime + 7 days);
    }

    function test_authorisedRevoked_cannotOperate() public {
        // Revoke authorisation
        vm.prank(owner);
        fund.setAuthorised(authorisedCaller, false);

        vm.prank(authorisedCaller);
        vm.expectRevert("IF: not authorised");
        fund.receive_(address(usdc), 1000);

        vm.prank(authorisedCaller);
        vm.expectRevert("IF: not authorised");
        fund.coverShortfall(address(usdc), 1000);

        vm.prank(authorisedCaller);
        vm.expectRevert("IF: not authorised");
        fund.payPnl(address(usdc), 1000, alice);
    }

    function test_multipleAuthorisedCallers() public {
        // Authorise alice and bob
        vm.startPrank(owner);
        fund.setAuthorised(alice, true);
        fund.setAuthorised(bob, true);
        vm.stopPrank();

        // Mint and approve for alice
        usdc.mint(alice, 50_000 * USDC_UNIT);
        vm.prank(alice);
        usdc.approve(address(fund), type(uint256).max);

        // Mint and approve for bob
        usdc.mint(bob, 50_000 * USDC_UNIT);
        vm.prank(bob);
        usdc.approve(address(fund), type(uint256).max);

        // Both can deposit
        vm.prank(alice);
        fund.receive_(address(usdc), 20_000 * USDC_UNIT);

        vm.prank(bob);
        fund.receive_(address(usdc), 30_000 * USDC_UNIT);

        assertEq(fund.fundBalance(address(usdc)), 50_000 * USDC_UNIT);
    }

    function test_constants() public view {
        assertEq(fund.MIN_RESERVE_BPS(), 2000);
        assertEq(fund.DISTRIBUTION_COOLDOWN(), 24 hours);
    }
}
