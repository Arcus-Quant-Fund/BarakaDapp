// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/instruments/PerpetualSukuk.sol";
import "../../src/interfaces/IEverlastingOption.sol";
import "../mocks/MockOracleAdapter.sol";
import "../mocks/MockERC20.sol";

/**
 * @title MockEverlastingOption
 * @notice Minimal mock implementing IEverlastingOption for PerpetualSukuk tests.
 *         Returns a configurable call rate so we can test embedded upside logic.
 */
contract MockEverlastingOption is IEverlastingOption {
    uint256 public callRate; // WAD-denominated rate returned by quoteCall
    uint256 public putRate;  // WAD-denominated rate returned by quotePut

    function setCallRate(uint256 _rate) external {
        callRate = _rate;
    }

    function setPutRate(uint256 _rate) external {
        putRate = _rate;
    }

    function quotePut(bytes32, uint256, uint256) external view override returns (uint256) {
        return putRate;
    }

    function quoteCall(bytes32, uint256, uint256) external view override returns (uint256) {
        return callRate;
    }

    function quoteAtSpot(bytes32, uint256) external view override returns (
        uint256 putPriceWad, uint256 callPriceWad, uint256 spotWad,
        uint256 kappaWad, int256 betaNegWad, int256 betaPosWad
    ) {
        return (putRate, callRate, 0, 0, int256(0), int256(0));
    }

    function getExponents(bytes32) external pure override returns (
        int256 betaNegWad, int256 betaPosWad, uint256 denomWad
    ) {
        return (-1e18, 2e18, 3e18);
    }
}

/**
 * @title PerpetualSukukTest
 * @notice Comprehensive unit tests for PerpetualSukuk.
 *
 *         Covers: issue, subscribe, claimProfit, redeem, PS-H-1 (auto-claim on re-subscribe),
 *         PS-M-4 (auto-claim on redeem), I-7 (clock advances even if reserve exhausted),
 *         L-10 (global redeemed set), over-capacity revert, not-matured revert,
 *         fee-on-transfer check.
 */
contract PerpetualSukukTest is Test {

    PerpetualSukuk         ps;
    MockEverlastingOption  mockEO;
    MockOracleAdapter      oracle;
    MockERC20              usdc;

    address owner    = address(0xABCD);
    address issuer   = address(0x1111);
    address alice    = address(0x2222);
    address bob      = address(0x3333);

    bytes32 constant BTC = keccak256("BTC-USD");

    uint256 constant WAD           = 1e18;
    uint256 constant PAR_VALUE     = 100_000e6;    // 100k USDC (6 decimals)
    uint256 constant PROFIT_RATE   = 0.05e18;      // 5% annual
    uint256 constant SECS_PER_YEAR = 365 days;

    function setUp() public {
        oracle = new MockOracleAdapter();
        mockEO = new MockEverlastingOption();

        vm.prank(owner);
        ps = new PerpetualSukuk(owner, address(mockEO), address(oracle));

        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Set oracle price for embedded call calculations
        oracle.setIndexPrice(BTC, 50_000e18);

        // Set a small call rate (1% of principal as embedded upside)
        mockEO.setCallRate(0.01e18);

        // Mint tokens to issuer and investors
        usdc.mint(issuer, 1_000_000e6);
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    // ─────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────

    /// @dev Issue a standard sukuk and return its ID.
    function _issue() internal returns (uint256 id) {
        return _issueCustom(PAR_VALUE, PROFIT_RATE, block.timestamp + 365 days);
    }

    function _issueCustom(uint256 par, uint256 rate, uint256 maturity)
        internal returns (uint256 id)
    {
        vm.startPrank(issuer);
        usdc.approve(address(ps), par);
        id = ps.issue(BTC, address(usdc), par, rate, maturity);
        vm.stopPrank();
    }

    /// @dev Subscribe alice with given amount to given sukuk ID.
    function _subscribe(uint256 id, address investor, uint256 amount) internal {
        vm.startPrank(investor);
        usdc.approve(address(ps), amount);
        ps.subscribe(id, amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════

    function test_constructor_zeroEvOption_reverts() public {
        vm.expectRevert("PS: zero evOption");
        new PerpetualSukuk(owner, address(0), address(oracle));
    }

    function test_constructor_zeroOracle_reverts() public {
        vm.expectRevert("PS: zero oracle");
        new PerpetualSukuk(owner, address(mockEO), address(0));
    }

    function test_constructor_setsImmutables() public view {
        assertEq(address(ps.evOption()), address(mockEO));
        assertEq(address(ps.oracle()), address(oracle));
    }

    // ═══════════════════════════════════════════════════════
    // 1. issue() — issuer deposits parValue, sukuk created
    // ═══════════════════════════════════════════════════════

    function test_issue_createsRecord() public {
        uint256 id = _issue();

        (
            address sIssuer,
            bytes32 sAsset,
            address sToken,
            uint256 sPar,
            uint256 sRate,
            uint256 sMat,
            uint256 sIssuedAt,
            uint256 sTotalSub,
            bool    sRedeemed,
            uint256 sCallStrikeWad
        ) = ps.sukuks(id);

        assertEq(sIssuer, issuer, "issuer");
        assertEq(sAsset, BTC, "asset");
        assertEq(sToken, address(usdc), "token");
        assertEq(sPar, PAR_VALUE, "par value");
        assertEq(sRate, PROFIT_RATE, "profit rate");
        assertGt(sMat, block.timestamp, "maturity in future");
        assertEq(sIssuedAt, block.timestamp, "issuedAt");
        assertEq(sTotalSub, 0, "no subscriptions yet");
        assertFalse(sRedeemed, "not redeemed");
        assertGt(sCallStrikeWad, 0, "call strike set");
    }

    function test_issue_transfersTokens() public {
        uint256 issuerBefore = usdc.balanceOf(issuer);
        uint256 psBefore = usdc.balanceOf(address(ps));

        uint256 id = _issue();

        assertEq(usdc.balanceOf(issuer), issuerBefore - PAR_VALUE, "Issuer debited");
        assertEq(usdc.balanceOf(address(ps)), psBefore + PAR_VALUE, "PS credited");
        assertEq(ps.issuerReserve(id), PAR_VALUE, "Reserve set");
    }

    function test_issue_incrementsId() public {
        assertEq(ps.nextId(), 0);
        uint256 id0 = _issue();
        assertEq(id0, 0);
        assertEq(ps.nextId(), 1);
        uint256 id1 = _issue();
        assertEq(id1, 1);
        assertEq(ps.nextId(), 2);
    }

    function test_issue_emitsEvent() public {
        vm.startPrank(issuer);
        usdc.approve(address(ps), PAR_VALUE);

        vm.expectEmit(true, true, false, true);
        emit PerpetualSukuk.SukukIssued(0, issuer, BTC, address(usdc), PAR_VALUE, PROFIT_RATE, block.timestamp + 365 days);
        ps.issue(BTC, address(usdc), PAR_VALUE, PROFIT_RATE, block.timestamp + 365 days);
        vm.stopPrank();
    }

    function test_issue_zeroToken_reverts() public {
        vm.prank(issuer);
        vm.expectRevert("PS: zero addr");
        ps.issue(BTC, address(0), PAR_VALUE, PROFIT_RATE, block.timestamp + 365 days);
    }

    function test_issue_zeroPar_reverts() public {
        vm.prank(issuer);
        vm.expectRevert("PS: zero par");
        ps.issue(BTC, address(usdc), 0, PROFIT_RATE, block.timestamp + 365 days);
    }

    function test_issue_zeroRate_reverts() public {
        vm.prank(issuer);
        vm.expectRevert("PS: bad rate");
        ps.issue(BTC, address(usdc), PAR_VALUE, 0, block.timestamp + 365 days);
    }

    function test_issue_rateAtWAD_reverts() public {
        vm.prank(issuer);
        vm.expectRevert("PS: bad rate");
        ps.issue(BTC, address(usdc), PAR_VALUE, WAD, block.timestamp + 365 days);
    }

    function test_issue_pastMaturity_reverts() public {
        vm.prank(issuer);
        vm.expectRevert("PS: past maturity");
        ps.issue(BTC, address(usdc), PAR_VALUE, PROFIT_RATE, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════
    // 2. subscribe() — investor deposits, principal tracked
    // ═══════════════════════════════════════════════════════

    function test_subscribe_recordsSubscription() public {
        uint256 id = _issue();
        _subscribe(id, alice, 10_000e6);

        (uint256 amount, uint256 lastProfitAt, bool redeemed) = ps.subscriptions(id, alice);
        assertEq(amount, 10_000e6, "subscription amount");
        assertEq(lastProfitAt, block.timestamp, "lastProfitAt set");
        assertFalse(redeemed, "not redeemed");
    }

    function test_subscribe_tracksPrincipal() public {
        uint256 id = _issue();
        _subscribe(id, alice, 10_000e6);

        assertEq(ps.investorPrincipal(id), 10_000e6, "principal tracked");
    }

    function test_subscribe_updatesTotalSubscribed() public {
        uint256 id = _issue();
        _subscribe(id, alice, 10_000e6);

        (,,, uint256 par,,,,uint256 totalSub,,) = ps.sukuks(id);
        assertEq(totalSub, 10_000e6, "totalSubscribed updated");
        assertEq(par, PAR_VALUE, "par unchanged");
    }

    function test_subscribe_transfersTokens() public {
        uint256 id = _issue();
        uint256 aliceBefore = usdc.balanceOf(alice);

        _subscribe(id, alice, 10_000e6);

        assertEq(usdc.balanceOf(alice), aliceBefore - 10_000e6, "Alice debited");
    }

    function test_subscribe_multipleInvestors() public {
        uint256 id = _issue();
        _subscribe(id, alice, 30_000e6);
        _subscribe(id, bob, 40_000e6);

        assertEq(ps.investorPrincipal(id), 70_000e6);
        (,,,,,,,uint256 totalSub,,) = ps.sukuks(id);
        assertEq(totalSub, 70_000e6);
    }

    function test_subscribe_emitsEvent() public {
        uint256 id = _issue();

        vm.startPrank(alice);
        usdc.approve(address(ps), 10_000e6);
        vm.expectEmit(true, true, false, true);
        emit PerpetualSukuk.Subscribed(id, alice, 10_000e6);
        ps.subscribe(id, 10_000e6);
        vm.stopPrank();
    }

    function test_subscribe_zeroAmount_reverts() public {
        uint256 id = _issue();
        vm.prank(alice);
        vm.expectRevert("PS: zero amount");
        ps.subscribe(id, 0);
    }

    function test_subscribe_afterMaturity_reverts() public {
        uint256 id = _issue();
        vm.warp(block.timestamp + 366 days);

        vm.startPrank(alice);
        usdc.approve(address(ps), 10_000e6);
        vm.expectRevert("PS: matured");
        ps.subscribe(id, 10_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 3. claimProfit() — accrues based on profitRateWad
    // ═══════════════════════════════════════════════════════

    function test_claimProfit_accruedCorrectly() public {
        uint256 id = _issue();
        _subscribe(id, alice, 100_000e6); // Full subscription

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.claimProfit(id);
        uint256 aliceAfter = usdc.balanceOf(alice);

        uint256 profit = aliceAfter - aliceBefore;
        // Expected: 100_000e6 * 0.05 * 1 year / 1 year = 5_000e6
        assertEq(profit, 5_000e6, "5% annual profit on 100k");
    }

    function test_claimProfit_partialYear() public {
        uint256 id = _issue();
        _subscribe(id, alice, 100_000e6);

        // Advance 6 months (half year)
        vm.warp(block.timestamp + 182.5 days);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.claimProfit(id);
        uint256 profit = usdc.balanceOf(alice) - aliceBefore;

        // Expected: ~2500e6 (half of 5%)
        assertApproxEqAbs(profit, 2_500e6, 1e6, "~2500 USDC for half year");
    }

    function test_claimProfit_multipleClaimsNoDoubleCounting() public {
        uint256 id = _issue();
        _subscribe(id, alice, 100_000e6);

        uint256 halfYear = 365 days / 2;
        uint256 firstClaimTs  = 1 + halfYear;
        uint256 secondClaimTs = 1 + 2 * halfYear;

        // Claim after 6 months
        vm.warp(firstClaimTs);
        vm.prank(alice);
        ps.claimProfit(id);

        uint256 balAfterFirst = usdc.balanceOf(alice);

        // Claim again after another 6 months (total 1 year from subscribe)
        vm.warp(secondClaimTs);
        vm.prank(alice);
        ps.claimProfit(id);

        uint256 secondProfit = usdc.balanceOf(alice) - balAfterFirst;
        // Should be roughly another ~2500
        assertApproxEqAbs(secondProfit, 2_500e6, 1e6, "No double counting");
    }

    function test_claimProfit_emitsEvent() public {
        uint256 id = _issue();
        _subscribe(id, alice, 100_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit PerpetualSukuk.ProfitClaimed(id, alice, 5_000e6);
        ps.claimProfit(id);
    }

    function test_claimProfit_noSub_noop() public {
        uint256 id = _issue();
        // alice has no subscription — should silently return
        vm.prank(alice);
        ps.claimProfit(id); // no revert, no transfer
    }

    function test_claimProfit_zeroElapsed_noop() public {
        uint256 id = _issue();
        _subscribe(id, alice, 100_000e6);

        // Claim immediately — 0 elapsed
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.claimProfit(id);
        assertEq(usdc.balanceOf(alice), balBefore, "No profit for 0 elapsed");
    }

    // ═══════════════════════════════════════════════════════
    // 4. redeem() — at maturity, returns principal + profit + call upside
    // ═══════════════════════════════════════════════════════

    function test_redeem_returnsPrincipalAndCallUpside() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);

        // Skip to maturity
        vm.warp(block.timestamp + 365 days);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.redeem(id);
        uint256 aliceAfter = usdc.balanceOf(alice);

        uint256 received = aliceAfter - aliceBefore;

        // Expected: principal (50_000e6) + profit (50_000 * 5% = 2_500e6) + call upside
        // callRate = 0.01e18, callUpside = 0.01 * 50_000e6 / 1e18 = 500e6
        // But callUpside is capped by issuerReserve
        uint256 expectedProfit = 2_500e6;
        uint256 expectedCall = 500e6;
        uint256 expectedTotal = 50_000e6 + expectedProfit + expectedCall;

        assertEq(received, expectedTotal, "principal + profit + call upside");
    }

    function test_redeem_marksSubRedeemed() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        ps.redeem(id);

        (, , bool redeemed) = ps.subscriptions(id, alice);
        assertTrue(redeemed, "Subscription marked redeemed");
    }

    function test_redeem_alreadyRedeemed_reverts() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        ps.redeem(id);

        vm.prank(alice);
        vm.expectRevert("PS: already redeemed");
        ps.redeem(id);
    }

    function test_redeem_emitsEvent() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);
        vm.warp(block.timestamp + 365 days);

        // callUpside = 0.01 * 50_000e6 / 1e18 = 500e6
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit PerpetualSukuk.Redeemed(id, alice, 50_000e6, 500e6);
        ps.redeem(id);
    }

    function test_redeem_noSubscription_reverts() public {
        uint256 id = _issue();
        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        vm.expectRevert("PS: not subscribed");
        ps.redeem(id);
    }

    // ═══════════════════════════════════════════════════════
    // 5. PS-H-1 fix: auto-claim on re-subscribe
    // ═══════════════════════════════════════════════════════

    function test_PSH1_autoClaimOnResubscribe() public {
        uint256 id = _issue();

        // Alice subscribes for 50k
        _subscribe(id, alice, 50_000e6);

        // Wait 6 months — profit accrues
        vm.warp(block.timestamp + 182.5 days);

        uint256 aliceBefore = usdc.balanceOf(alice);

        // Alice subscribes again for 10k more — should auto-claim accrued profit
        _subscribe(id, alice, 10_000e6);

        uint256 aliceAfter = usdc.balanceOf(alice);

        // Alice paid 10k for new subscription but received ~1250 profit (50k * 5% * 0.5yr)
        // Net change = -10_000e6 + ~1250e6 = ~-8750e6
        int256 netChange = int256(aliceAfter) - int256(aliceBefore);
        int256 expectedNet = -10_000e6 + 1_250e6; // approximate
        assertApproxEqAbs(netChange, expectedNet, 1e6, "Auto-claim on re-subscribe");

        // Verify the subscription amount is now 60k
        (uint256 amount,,) = ps.subscriptions(id, alice);
        assertEq(amount, 60_000e6, "Subscription amount accumulated");
    }

    function test_PSH1_firstSubscribe_noAutoClaim() public {
        uint256 id = _issue();

        // First subscription should not trigger auto-claim path (sub.amount == 0)
        uint256 aliceBefore = usdc.balanceOf(alice);
        _subscribe(id, alice, 10_000e6);
        uint256 aliceAfter = usdc.balanceOf(alice);

        assertEq(aliceBefore - aliceAfter, 10_000e6, "Only subscription deducted, no claim");
    }

    // ═══════════════════════════════════════════════════════
    // 6. PS-M-4 fix: auto-claim on redeem
    // ═══════════════════════════════════════════════════════

    function test_PSM4_autoClaimOnRedeem() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);

        // Never claim profit manually. Warp to maturity.
        vm.warp(block.timestamp + 365 days);

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.redeem(id);
        uint256 received = usdc.balanceOf(alice) - aliceBefore;

        // Should include: principal (50k) + auto-claimed profit (2.5k) + call upside (500)
        uint256 expectedProfit = 2_500e6;
        uint256 expectedCall   = 500e6;
        uint256 expectedTotal  = 50_000e6 + expectedProfit + expectedCall;

        assertEq(received, expectedTotal, "Redeem auto-claims accrued profit");
    }

    function test_PSM4_partialClaimThenRedeem() public {
        uint256 startTs = block.timestamp;
        uint256 maturity = startTs + 365 days;
        uint256 id = _issueCustom(PAR_VALUE, PROFIT_RATE, maturity);
        _subscribe(id, alice, 50_000e6);

        // Claim at 6 months
        uint256 halfYear = 365 days / 2;
        vm.warp(startTs + halfYear);
        vm.prank(alice);
        ps.claimProfit(id);

        // Warp to maturity
        vm.warp(maturity);
        uint256 balBeforeRedeem = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.redeem(id);
        uint256 redeemReceived = usdc.balanceOf(alice) - balBeforeRedeem;

        // Redeem should include: principal + remaining profit + call upside
        // Remaining profit: ~1250 (second half year)
        uint256 expectedSecondProfit = 50_000e6 * 5 / 100 / 2; // ~1250e6
        uint256 expectedCall = 500e6;

        assertApproxEqAbs(
            redeemReceived,
            50_000e6 + expectedSecondProfit + expectedCall,
            1e6,
            "Redeem auto-claims only remaining profit"
        );
    }

    // ═══════════════════════════════════════════════════════
    // 7. I-7 fix: clock always advances even if reserve exhausted
    // ═══════════════════════════════════════════════════════

    function test_I7_clockAdvancesWhenReserveExhausted() public {
        // Issue with tiny reserve so it will be exhausted
        uint256 id = _issueCustom(1_000e6, PROFIT_RATE, block.timestamp + 730 days);
        _subscribe(id, alice, 1_000e6);

        // Claim multiple times with large time gaps.
        // First claim after 2 years: profit = 1000 * 5% * 2 = 100. Reserve = 1000 - 100 = 900.
        // But actually reserve is 0 (investor principal is separate). Wait, issuerReserve = parValue = 1000
        // Profit at 2yr = 1000 * 0.05 * 2 = 100 USDC. Reserve goes from 1000 to 900.

        // Let's exhaust by waiting a very long time
        vm.warp(block.timestamp + 365 days * 100); // 100 years
        // Profit would be 1000 * 0.05 * 100 = 5000 but reserve is only 1000
        // So profit is capped at 1000

        vm.prank(alice);
        ps.claimProfit(id);

        // Check that lastProfitAt was advanced even though profit was capped
        (, uint256 lastProfitAt,) = ps.subscriptions(id, alice);
        assertEq(lastProfitAt, block.timestamp, "Clock advanced despite capped profit");

        // Reserve should be 0 now
        assertEq(ps.issuerReserve(id), 0, "Reserve exhausted");

        // Another claim — should not accrue anything but clock still advances
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        ps.claimProfit(id);

        (, uint256 lastProfitAt2,) = ps.subscriptions(id, alice);
        assertEq(lastProfitAt2, block.timestamp, "Clock advances on zero-profit claim too");
    }

    // ═══════════════════════════════════════════════════════
    // 8. L-10 fix: global redeemed set when all principal withdrawn
    // ═══════════════════════════════════════════════════════

    function test_L10_globalRedeemedWhenAllPrincipalWithdrawn() public {
        uint256 id = _issue();

        // Two investors subscribe for the full par value
        _subscribe(id, alice, 60_000e6);
        _subscribe(id, bob, 40_000e6);

        vm.warp(block.timestamp + 365 days);

        // Alice redeems — not all principal withdrawn yet
        vm.prank(alice);
        ps.redeem(id);

        (,,,,,,,,bool redeemed1,) = ps.sukuks(id);
        assertFalse(redeemed1, "Not globally redeemed yet - Bob still in");

        // Bob redeems — now all principal withdrawn
        vm.prank(bob);
        ps.redeem(id);

        (,,,,,,,,bool redeemed2,) = ps.sukuks(id);
        assertTrue(redeemed2, "Globally redeemed when all principal withdrawn");
    }

    function test_L10_singleInvestor_globalRedeemed() public {
        uint256 id = _issue();
        _subscribe(id, alice, PAR_VALUE);

        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        ps.redeem(id);

        (,,,,,,,,bool redeemed,) = ps.sukuks(id);
        assertTrue(redeemed, "Globally redeemed with single investor");
    }

    function test_L10_globalRedeemed_blocksNewSubscriptions() public {
        uint256 id = _issue();
        _subscribe(id, alice, PAR_VALUE);

        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        ps.redeem(id);

        // Now try to subscribe again — should be blocked
        vm.startPrank(bob);
        usdc.approve(address(ps), 10_000e6);
        vm.expectRevert("PS: redeemed");
        ps.subscribe(id, 10_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 9. Over-capacity reverts
    // ═══════════════════════════════════════════════════════

    function test_overCapacity_reverts() public {
        uint256 id = _issue();
        _subscribe(id, alice, PAR_VALUE); // Fully subscribed

        vm.startPrank(bob);
        usdc.approve(address(ps), 1e6);
        vm.expectRevert("PS: over capacity");
        ps.subscribe(id, 1e6);
        vm.stopPrank();
    }

    function test_overCapacity_exactFit() public {
        uint256 id = _issue();
        _subscribe(id, alice, PAR_VALUE - 1e6);

        // Exact remaining capacity — should succeed
        _subscribe(id, bob, 1e6);

        (,,,,,,,uint256 totalSub,,) = ps.sukuks(id);
        assertEq(totalSub, PAR_VALUE, "Exactly at capacity");
    }

    function test_overCapacity_oneOverExact() public {
        uint256 id = _issue();
        _subscribe(id, alice, PAR_VALUE - 1e6);

        // One unit over capacity
        vm.startPrank(bob);
        usdc.approve(address(ps), 1e6 + 1);
        vm.expectRevert("PS: over capacity");
        ps.subscribe(id, 1e6 + 1);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 10. Not matured reverts on redeem
    // ═══════════════════════════════════════════════════════

    function test_notMatured_redeemReverts() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);

        // Don't warp to maturity
        vm.prank(alice);
        vm.expectRevert("PS: not matured");
        ps.redeem(id);
    }

    function test_notMatured_oneSecondBefore() public {
        uint256 maturity = block.timestamp + 365 days;
        uint256 id = _issueCustom(PAR_VALUE, PROFIT_RATE, maturity);
        _subscribe(id, alice, 50_000e6);

        vm.warp(maturity - 1);
        vm.prank(alice);
        vm.expectRevert("PS: not matured");
        ps.redeem(id);
    }

    function test_matured_exactTimestamp() public {
        uint256 maturity = block.timestamp + 365 days;
        uint256 id = _issueCustom(PAR_VALUE, PROFIT_RATE, maturity);
        _subscribe(id, alice, 50_000e6);

        vm.warp(maturity);
        vm.prank(alice);
        ps.redeem(id); // Should not revert
    }

    // ═══════════════════════════════════════════════════════
    // 11. Fee-on-transfer check
    // ═══════════════════════════════════════════════════════

    function test_feeOnTransfer_issue_reverts() public {
        // Deploy a fee-on-transfer token
        FeeOnTransferToken feeToken = new FeeOnTransferToken("Fee", "FEE");
        feeToken.mint(issuer, 1_000_000e18);

        vm.startPrank(issuer);
        feeToken.approve(address(ps), 100_000e18);
        vm.expectRevert("PS: fee-on-transfer not supported");
        ps.issue(BTC, address(feeToken), 100_000e18, PROFIT_RATE, block.timestamp + 365 days);
        vm.stopPrank();
    }

    function test_feeOnTransfer_subscribe_reverts() public {
        // Issue with normal token, then try to subscribe with a fee token
        // We need a sukuk that uses a fee token
        FeeOnTransferToken feeToken = new FeeOnTransferToken("Fee", "FEE");
        feeToken.mint(issuer, 1_000_000e18);
        feeToken.mint(alice, 1_000_000e18);

        // First disable fee so issue succeeds
        feeToken.setFee(0);
        vm.startPrank(issuer);
        feeToken.approve(address(ps), 100_000e18);
        uint256 id = ps.issue(BTC, address(feeToken), 100_000e18, PROFIT_RATE, block.timestamp + 365 days);
        vm.stopPrank();

        // Now enable fee
        feeToken.setFee(100); // 1% fee

        vm.startPrank(alice);
        feeToken.approve(address(ps), 50_000e18);
        vm.expectRevert("PS: fee-on-transfer not supported");
        ps.subscribe(id, 50_000e18);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // Additional edge cases
    // ═══════════════════════════════════════════════════════

    function test_pause_blocksIssue() public {
        vm.prank(owner);
        ps.pause();

        vm.startPrank(issuer);
        usdc.approve(address(ps), PAR_VALUE);
        vm.expectRevert();
        ps.issue(BTC, address(usdc), PAR_VALUE, PROFIT_RATE, block.timestamp + 365 days);
        vm.stopPrank();
    }

    function test_pause_blocksSubscribe() public {
        uint256 id = _issue();

        vm.prank(owner);
        ps.pause();

        vm.startPrank(alice);
        usdc.approve(address(ps), 10_000e6);
        vm.expectRevert();
        ps.subscribe(id, 10_000e6);
        vm.stopPrank();
    }

    function test_pause_blocksClaimProfit() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);
        vm.warp(block.timestamp + 30 days);

        vm.prank(owner);
        ps.pause();

        vm.prank(alice);
        vm.expectRevert();
        ps.claimProfit(id);
    }

    function test_pause_blocksRedeem() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(owner);
        ps.pause();

        vm.prank(alice);
        vm.expectRevert();
        ps.redeem(id);
    }

    function test_getAccruedProfit() public {
        uint256 id = _issue();
        _subscribe(id, alice, 100_000e6);

        vm.warp(block.timestamp + 365 days);
        uint256 accrued = ps.getAccruedProfit(id, alice);
        assertEq(accrued, 5_000e6, "Accrued = 5% of 100k");
    }

    function test_getEmbeddedCallValue() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);

        (uint256 callRateWad, uint256 callUpside) = ps.getEmbeddedCallValue(id, alice);
        assertEq(callRateWad, 0.01e18, "Call rate from mock");
        // callUpside = 0.01 * 50_000e6 / 1e18 = 500e6
        assertEq(callUpside, 500e6, "Call upside");
    }

    function test_redeem_callUpsideCappedByReserve() public {
        // Issue with low reserve and high call rate
        mockEO.setCallRate(1e18); // 100% call rate — very high

        uint256 id = _issue();
        _subscribe(id, alice, PAR_VALUE);

        vm.warp(block.timestamp + 365 days);

        // Reserve after profit payout = PAR_VALUE - (PAR_VALUE * 5%) = 95_000e6
        // callUpside = 1.0 * 100_000e6 = 100_000e6
        // actualCall = min(100_000e6, 95_000e6) = 95_000e6 (capped)

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        ps.redeem(id);
        uint256 received = usdc.balanceOf(alice) - aliceBefore;

        // principal + profit + capped call
        uint256 expectedProfit = 5_000e6;
        uint256 expectedCall = 95_000e6; // capped at remaining reserve
        uint256 expectedTotal = PAR_VALUE + expectedProfit + expectedCall;

        assertEq(received, expectedTotal, "Call upside capped by reserve");
    }

    function test_investorPrincipal_decreasesOnRedeem() public {
        uint256 id = _issue();
        _subscribe(id, alice, 50_000e6);
        _subscribe(id, bob, 40_000e6);

        assertEq(ps.investorPrincipal(id), 90_000e6);

        vm.warp(block.timestamp + 365 days);

        vm.prank(alice);
        ps.redeem(id);
        assertEq(ps.investorPrincipal(id), 40_000e6, "Principal decreased by alice amount");

        vm.prank(bob);
        ps.redeem(id);
        assertEq(ps.investorPrincipal(id), 0, "All principal withdrawn");
    }
}

// ─────────────────────────────────────────────────────
// Fee-on-transfer ERC20 for testing
// ─────────────────────────────────────────────────────

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FeeOnTransferToken is ERC20 {
    uint256 public fee; // basis points (e.g. 100 = 1%)

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        fee = 100; // 1% default
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 _fee) external {
        fee = _fee;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 feeAmount = (amount * fee) / 10_000;
        uint256 net = amount - feeAmount;
        if (feeAmount > 0) {
            super.transfer(address(0xdead), feeAmount);
        }
        return super.transfer(to, net);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 feeAmount = (amount * fee) / 10_000;
        uint256 net = amount - feeAmount;
        // Spend full allowance
        _spendAllowance(from, _msgSender(), amount);
        if (feeAmount > 0) {
            _transfer(from, address(0xdead), feeAmount);
        }
        _transfer(from, to, net);
        return true;
    }
}
