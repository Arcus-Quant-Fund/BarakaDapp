// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/credit/PerpetualSukuk.sol";
import "../../src/core/EverlastingOption.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracle.sol";

/**
 * @title PerpetualSukukTest
 * @notice Unit tests for PerpetualSukuk (Layer 2 Islamic capital market instrument).
 *
 * Test setup:
 *   - Real EverlastingOption (BTC-like: sigma²=0.64, kappa=0.08)
 *   - MockOracle at $50k BTC
 *   - MockERC20 token (18 decimals for simplicity)
 *   - Sukuk: par = 1_000_000 (1M tokens), 5%/year profit, 1 year maturity
 */
contract PerpetualSukukTest is Test {

    PerpetualSukuk    sukuk;
    EverlastingOption eo;
    MockOracle        mockOracle;
    MockERC20         token;

    address constant OWNER    = address(0xBEEF);
    address constant ISSUER   = address(0xB001);
    address constant INVESTOR = address(0xB002);
    address constant INVESTOR2 = address(0xB003);

    address constant ASSET    = address(0xBBCC);

    uint256 constant SIGMA2   = 64e16;
    uint256 constant KAPPA    = 8e16;
    uint256 constant SPOT_WAD = 50_000e18;
    uint256 constant WAD      = 1e18;

    // Sukuk params
    uint256 constant PAR_VALUE       = 1_000_000e18; // 1M tokens (18-decimal)
    uint256 constant PROFIT_RATE_WAD = 5e16;         // 5%/year
    uint256          MATURITY;

    uint256 sukukId;

    function setUp() public {
        vm.startPrank(OWNER);

        mockOracle = new MockOracle();
        mockOracle.setIndexPrice(ASSET, SPOT_WAD);

        eo = new EverlastingOption(OWNER, address(mockOracle));
        eo.setMarket(ASSET, SIGMA2, KAPPA, false);

        token = new MockERC20("Sukuk Token", "STKN", 18);

        sukuk = new PerpetualSukuk(OWNER, address(eo), address(mockOracle));

        vm.stopPrank();

        // Fund actors
        token.mint(ISSUER,    PAR_VALUE * 2);
        token.mint(INVESTOR,  PAR_VALUE);
        token.mint(INVESTOR2, PAR_VALUE);

        vm.prank(ISSUER);    token.approve(address(sukuk), type(uint256).max);
        vm.prank(INVESTOR);  token.approve(address(sukuk), type(uint256).max);
        vm.prank(INVESTOR2); token.approve(address(sukuk), type(uint256).max);

        // Issue sukuk (maturity = 1 year from now)
        MATURITY = block.timestamp + 365 days;
        vm.prank(ISSUER);
        sukukId = sukuk.issue(ASSET, address(token), PAR_VALUE, PROFIT_RATE_WAD, MATURITY);
    }

    // ─── 1. Issuance ──────────────────────────────────────────────

    function test_issue_sukukCreated() public view {
        (
            address issuer,
            address asset,
            address tok,
            uint256 par,
            uint256 rate,
            uint256 maturity,
            ,
            uint256 totalSub,
            bool redeemed
        ) = sukuk.sukuks(sukukId);

        assertEq(issuer,   ISSUER,            "issuer");
        assertEq(asset,    ASSET,             "asset");
        assertEq(tok,      address(token),    "token");
        assertEq(par,      PAR_VALUE,         "par");
        assertEq(rate,     PROFIT_RATE_WAD,   "rate");
        assertEq(maturity, MATURITY,          "maturity");
        assertEq(totalSub, 0,                 "no subs yet");
        assertFalse(redeemed,                 "not redeemed");
    }

    function test_issue_collateralDeposited() public view {
        // Issuer deposits parValue → contract holds it
        assertEq(token.balanceOf(address(sukuk)), PAR_VALUE, "contract holds par");
    }

    function test_issue_pastMaturityReverts() public {
        vm.prank(ISSUER);
        vm.expectRevert("PS: past maturity");
        sukuk.issue(ASSET, address(token), PAR_VALUE, PROFIT_RATE_WAD, block.timestamp - 1);
    }

    function test_issue_zeroProfitRateReverts() public {
        vm.prank(ISSUER);
        vm.expectRevert("PS: bad rate");
        sukuk.issue(ASSET, address(token), PAR_VALUE, 0, block.timestamp + 365 days);
    }

    // ─── 2. Subscription ──────────────────────────────────────────

    function test_subscribe_recordsInvestor() public {
        uint256 amount = 100_000e18;
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, amount);

        (uint256 sub, , bool redeemed) = sukuk.subscriptions(sukukId, INVESTOR);
        assertEq(sub,     amount, "subscribed amount");
        assertFalse(redeemed,     "not redeemed");

        (,,,, uint256 totalSub,,,) = _getSukukFields(sukukId);
        assertEq(totalSub, amount, "totalSubscribed updated");
    }

    function test_subscribe_overCapacityReverts() public {
        vm.prank(INVESTOR);
        vm.expectRevert("PS: over capacity");
        sukuk.subscribe(sukukId, PAR_VALUE + 1);
    }

    function test_subscribe_afterMaturityReverts() public {
        vm.warp(MATURITY + 1);
        vm.prank(INVESTOR);
        vm.expectRevert("PS: matured");
        sukuk.subscribe(sukukId, 100_000e18);
    }

    function test_subscribe_multipleInvestors() public {
        uint256 half = PAR_VALUE / 2;
        vm.prank(INVESTOR);  sukuk.subscribe(sukukId, half);
        vm.prank(INVESTOR2); sukuk.subscribe(sukukId, half);

        (,,,, uint256 totalSub,,,) = _getSukukFields(sukukId);
        assertEq(totalSub, PAR_VALUE, "full subscription");
    }

    // ─── 3. Profit distribution ───────────────────────────────────

    function test_claimProfit_accruesCorrectly() public {
        uint256 subAmount = 365_000e18; // round number for easy math

        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, subAmount);

        // Fast-forward 30 days
        uint256 elapsed = 30 days;
        vm.warp(block.timestamp + elapsed);

        uint256 balBefore = token.balanceOf(INVESTOR);
        vm.prank(INVESTOR);
        sukuk.claimProfit(sukukId);

        // Expected profit = amount × 5% × 30/365 = 365_000 × 0.05 × 30/365 ≈ 1_500 tokens
        // = 365_000e18 × 5e16 × 30days / (1e18 × 365days)
        uint256 expectedProfit = (subAmount * PROFIT_RATE_WAD * elapsed) / (WAD * 365 days);
        assertApproxEqRel(
            token.balanceOf(INVESTOR) - balBefore,
            expectedProfit,
            1e16, // 1% tolerance for timestamp precision
            "profit amount"
        );
    }

    function test_claimProfit_notSubscribedReverts() public {
        vm.warp(block.timestamp + 30 days);
        vm.prank(address(0xDEAD));
        sukuk.claimProfit(sukukId);
        // Should silently return (sub.amount == 0)
    }

    function test_getAccruedProfit_viewConsistency() public {
        uint256 subAmount = 365_000e18;
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, subAmount);

        vm.warp(block.timestamp + 30 days);

        uint256 accrued = sukuk.getAccruedProfit(sukukId, INVESTOR);
        assertGt(accrued, 0, "accrued must be positive after 30 days");

        // claimProfit should pay approximately this amount
        uint256 balBefore = token.balanceOf(INVESTOR);
        vm.prank(INVESTOR);
        sukuk.claimProfit(sukukId);
        assertApproxEqRel(token.balanceOf(INVESTOR) - balBefore, accrued, 1e15, "view matches actual");
    }

    // ─── 4. Redemption ────────────────────────────────────────────

    function test_redeem_atMaturity_principalReturned() public {
        uint256 subAmount = 100_000e18;
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, subAmount);

        // Advance to maturity
        vm.warp(MATURITY);

        uint256 balBefore = token.balanceOf(INVESTOR);
        vm.prank(INVESTOR);
        sukuk.redeem(sukukId);

        uint256 received = token.balanceOf(INVESTOR) - balBefore;
        // Must receive at least principal
        assertGe(received, subAmount, "investor receives at least principal");
    }

    function test_redeem_includesCallUpside() public {
        uint256 subAmount = 100_000e18;
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, subAmount);

        // Move spot UP significantly → larger call upside
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 80_000e18); // $80k (above par/any strike)

        vm.warp(MATURITY);

        uint256 balBefore = token.balanceOf(INVESTOR);
        vm.prank(INVESTOR);
        sukuk.redeem(sukukId);

        uint256 received = token.balanceOf(INVESTOR) - balBefore;
        // Should be > principal since call is ITM
        assertGt(received, subAmount, "call upside added at high spot");
    }

    function test_redeem_beforeMaturityReverts() public {
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, 100_000e18);

        vm.prank(INVESTOR);
        vm.expectRevert("PS: not matured");
        sukuk.redeem(sukukId);
    }

    function test_redeem_doubleRedeemReverts() public {
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, 100_000e18);
        vm.warp(MATURITY);

        vm.prank(INVESTOR);
        sukuk.redeem(sukukId);

        vm.prank(INVESTOR);
        vm.expectRevert("PS: already redeemed");
        sukuk.redeem(sukukId);
    }

    // ─── 5. Embedded call sensitivity ─────────────────────────────

    function test_embeddedCallIncreases_withSpot() public {
        uint256 subAmount = 100_000e18;
        vm.prank(INVESTOR);
        sukuk.subscribe(sukukId, subAmount);

        // Low spot
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, SPOT_WAD); // $50k
        (uint256 callLow,) = sukuk.getEmbeddedCallValue(sukukId, INVESTOR);

        // High spot
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 100_000e18); // $100k
        (uint256 callHigh,) = sukuk.getEmbeddedCallValue(sukukId, INVESTOR);

        assertGt(callHigh, callLow, "call value increases with spot price");
    }

    // ─── Helpers ──────────────────────────────────────────────────

    function _getSukukFields(uint256 id) internal view returns (
        address issuer, address asset, address tok, uint256 par,
        uint256 totalSub, uint256 issuedAt, uint256 maturity,
        uint256 profitRate
    ) {
        PerpetualSukuk.SukukInfo memory s;
        (
            s.issuer, s.asset, s.token, s.parValue,
            s.profitRateWad, s.maturityEpoch, s.issuedAt,
            s.totalSubscribed, s.redeemed
        ) = sukuk.sukuks(id);
        return (s.issuer, s.asset, s.token, s.parValue,
                s.totalSubscribed, s.issuedAt, s.maturityEpoch, s.profitRateWad);
    }
}
