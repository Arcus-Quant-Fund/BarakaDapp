// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/credit/iCDS.sol";
import "../../src/core/EverlastingOption.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracle.sol";

/**
 * @title iCDSTest
 * @notice Unit tests for iCDS (Layer 4 Islamic Credit Default Swap).
 *
 * Test setup:
 *   - Real EverlastingOption (BTC-like: sigma²=0.64, kappa=0.08)
 *   - MockOracle at $50k BTC
 *   - MockERC20 token (18 decimals)
 *   - Protection: notional=10,000 tokens, recovery=40%, tenor=365 days
 *   - Recovery floor = 40% × $50k = $20k
 */
contract iCDSTest is Test {

    iCDS              cds;
    EverlastingOption eo;
    MockOracle        mockOracle;
    MockERC20         token;

    address constant OWNER  = address(0xBEEF);
    address constant SELLER = address(0x5E11);
    address constant BUYER  = address(0xB0EE);
    address constant KEEPER = address(0xBEAD);

    address constant ASSET = address(0xBBCC);

    uint256 constant SIGMA2         = 64e16;
    uint256 constant KAPPA          = 8e16;
    uint256 constant SPOT_WAD       = 50_000e18;
    uint256 constant WAD            = 1e18;

    // NOTIONAL = 1 WAD unit so that:
    //   premium = quotePut × 1e18 / 1e18 = quotePut value (≈ 27k tokens 18-dec)
    //   LGD     = 1e18 × (1 − recovery) / 1e18 = (1 − recovery) tokens
    // Both are non-zero and affordable with a 100M token mint for BUYER.
    uint256 constant NOTIONAL       = 1e18;        // 1 WAD unit
    uint256 constant RECOVERY_WAD   = 40e16;       // 40% recovery
    uint256 constant TENOR_DAYS     = 365;

    function setUp() public {
        vm.startPrank(OWNER);

        mockOracle = new MockOracle();
        mockOracle.setIndexPrice(ASSET, SPOT_WAD);

        eo = new EverlastingOption(OWNER, address(mockOracle));
        eo.setMarket(ASSET, SIGMA2, KAPPA, false);

        token = new MockERC20("Credit Token", "CRDT", 18);

        cds = new iCDS(OWNER, address(eo), address(mockOracle));
        cds.setKeeper(KEEPER, true);

        vm.stopPrank();

        // Fund actors
        // SELLER: 5 × NOTIONAL covers collateral deposits across all tests
        // BUYER: 100M tokens — quotePut ≈ 27k tokens (18-dec) per 1-WAD notional;
        //        100M covers worst-case near-ATM premium in fuzz tests
        token.mint(SELLER, NOTIONAL * 5);
        token.mint(BUYER,  100_000_000e18);

        vm.prank(SELLER); token.approve(address(cds), type(uint256).max);
        vm.prank(BUYER);  token.approve(address(cds), type(uint256).max);
    }

    // ─── Helper: open + accept protection ─────────────────────────
    function _openAndAccept() internal returns (uint256 id) {
        vm.prank(SELLER);
        id = cds.openProtection(ASSET, address(token), NOTIONAL, RECOVERY_WAD, TENOR_DAYS);
        vm.prank(BUYER);
        cds.acceptProtection(id);
    }

    // ─── 1. Open protection ───────────────────────────────────────

    function test_openProtection_sellerDepositsNotional() public {
        uint256 sellerBefore = token.balanceOf(SELLER);

        vm.prank(SELLER);
        uint256 id = cds.openProtection(ASSET, address(token), NOTIONAL, RECOVERY_WAD, TENOR_DAYS);

        assertEq(token.balanceOf(SELLER),      sellerBefore - NOTIONAL, "seller deposited");
        assertEq(token.balanceOf(address(cds)), NOTIONAL,               "cds holds notional");

        (address seller,,,,,,,,,,,iCDS.Status status) = cds.protections(id);
        assertEq(seller, SELLER,            "seller recorded");
        assertEq(uint8(status), uint8(iCDS.Status.Open), "status=Open");
    }

    function test_openProtection_recoveryFloorComputed() public {
        vm.prank(SELLER);
        uint256 id = cds.openProtection(ASSET, address(token), NOTIONAL, RECOVERY_WAD, TENOR_DAYS);

        (,,,,,, uint256 floorWad,,,,, ) = cds.protections(id);
        // recoveryFloor = recoveryRate × spot = 40% × 50_000e18 = 20_000e18
        assertEq(floorWad, (SPOT_WAD * RECOVERY_WAD) / WAD, "recovery floor correct");
    }

    function test_openProtection_invalidReverts() public {
        vm.prank(SELLER);
        vm.expectRevert("iCDS: zero notional");
        cds.openProtection(ASSET, address(token), 0, RECOVERY_WAD, TENOR_DAYS);

        vm.prank(SELLER);
        vm.expectRevert("iCDS: recovery >= 100%");
        cds.openProtection(ASSET, address(token), NOTIONAL, WAD, TENOR_DAYS);
    }

    // ─── 2. Accept protection ─────────────────────────────────────

    function test_acceptProtection_statusActive() public {
        uint256 id = _openAndAccept();
        (, address buyer,,,,,,,,,,  iCDS.Status status) = cds.protections(id);
        assertEq(buyer, BUYER,                        "buyer set");
        assertEq(uint8(status), uint8(iCDS.Status.Active), "status=Active");
    }

    function test_acceptProtection_firstPremiumPaid() public {
        vm.prank(SELLER);
        uint256 id = cds.openProtection(ASSET, address(token), NOTIONAL, RECOVERY_WAD, TENOR_DAYS);

        uint256 sellerBefore = token.balanceOf(SELLER);
        vm.prank(BUYER);
        cds.acceptProtection(id);

        // Seller should have received first premium
        assertGt(token.balanceOf(SELLER), sellerBefore, "seller received first premium");
    }

    function test_acceptProtection_doubleAcceptReverts() public {
        uint256 id = _openAndAccept();
        vm.prank(address(0xDEAD));
        vm.expectRevert("iCDS: not open"); // status is Active after first accept
        cds.acceptProtection(id);
    }

    // ─── 3. Premium payment ───────────────────────────────────────

    function test_payPremium_afterOnePeriod() public {
        uint256 id = _openAndAccept();

        // Capture lastPremiumAt set by acceptProtection
        (,,,,,,,, uint256 lastAtBefore,,,) = cds.protections(id);

        // Fast-forward 91 days (> PREMIUM_PERIOD = 90 days)
        vm.warp(block.timestamp + 91 days);

        uint256 sellerBefore = token.balanceOf(SELLER);
        vm.prank(BUYER);
        cds.payPremium(id);
        assertGt(token.balanceOf(SELLER), sellerBefore, "seller received premium");

        // H-6 fix: lastPremiumAt must advance by exactly one PREMIUM_PERIOD,
        // NOT jump to block.timestamp — prevents buyers from skipping periods.
        (,,,,,,,, uint256 lastAt,,,) = cds.protections(id);
        assertEq(lastAt, lastAtBefore + cds.PREMIUM_PERIOD(), "lastPremiumAt advances by one period");
    }

    function test_payPremium_multiplePeriodsSkipped_requiresMultipleCalls() public {
        uint256 id = _openAndAccept();
        (,,,,,,,, uint256 lastAtBefore,,,) = cds.protections(id);

        // Jump 2.5 periods — buyer must pay 2 separate premiums to catch up
        vm.warp(block.timestamp + 91 days * 2 + 10 days);

        vm.prank(BUYER);
        cds.payPremium(id); // pays period 1

        (,,,,,,,, uint256 lastAt1,,,) = cds.protections(id);
        assertEq(lastAt1, lastAtBefore + cds.PREMIUM_PERIOD(), "after call 1: advanced by 1 period");

        // Second period is now due (lastAt1 + PREMIUM_PERIOD <= block.timestamp)
        vm.prank(BUYER);
        cds.payPremium(id); // pays period 2

        (,,,,,,,, uint256 lastAt2,,,) = cds.protections(id);
        assertEq(lastAt2, lastAtBefore + 2 * cds.PREMIUM_PERIOD(), "after call 2: advanced by 2 periods");
    }

    function test_payPremium_tooSoonReverts() public {
        uint256 id = _openAndAccept();
        // Only 10 days passed
        vm.warp(block.timestamp + 10 days);
        vm.prank(BUYER);
        vm.expectRevert("iCDS: too soon");
        cds.payPremium(id);
    }

    function test_premium_dynamic_withSpotChange() public {
        vm.prank(SELLER);
        uint256 id = cds.openProtection(ASSET, address(token), NOTIONAL, RECOVERY_WAD, TENOR_DAYS);

        // Premium at high spot
        uint256 premiumHigh = cds.computePremium(id);

        // Drop spot toward recovery floor
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 25_000e18); // $25k (nearer recovery floor of $20k)
        uint256 premiumLow = cds.computePremium(id);

        // Premium should increase as spot approaches floor (ITM put)
        assertGt(premiumLow, premiumHigh, "premium increases as spot falls");
    }

    // ─── 4. Credit event trigger ──────────────────────────────────

    function test_triggerCreditEvent_whenFloorBreached() public {
        uint256 id = _openAndAccept();

        // Drop spot to recovery floor level (≤ $20k)
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);

        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        (,,,,,,,,,,,iCDS.Status status) = cds.protections(id);
        assertEq(uint8(status), uint8(iCDS.Status.Triggered), "status=Triggered");
    }

    function test_triggerCreditEvent_requiresFloorBreach() public {
        uint256 id = _openAndAccept();
        // Spot still above floor ($50k > $20k floor)
        vm.prank(KEEPER);
        vm.expectRevert("iCDS: no default");
        cds.triggerCreditEvent(id);
    }

    function test_triggerCreditEvent_requiresKeeper() public {
        uint256 id = _openAndAccept();
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(BUYER); // not a keeper
        vm.expectRevert("iCDS: not keeper");
        cds.triggerCreditEvent(id);
    }

    // ─── 5. Settlement ────────────────────────────────────────────

    function test_settle_buyerReceivesLGD() public {
        uint256 id = _openAndAccept();

        // Trigger default
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        uint256 buyerBefore  = token.balanceOf(BUYER);
        uint256 sellerBefore = token.balanceOf(SELLER);

        vm.prank(BUYER);
        cds.settle(id);

        // Loss-given-default = notional × (1 − recovery) = 10_000 × 60% = 6_000 tokens
        uint256 expectedPayout  = (NOTIONAL * (WAD - RECOVERY_WAD)) / WAD;
        uint256 expectedReturn  = NOTIONAL - expectedPayout;

        assertApproxEqAbs(token.balanceOf(BUYER) - buyerBefore, expectedPayout, 1, "buyer payout");
        assertApproxEqAbs(token.balanceOf(SELLER) - sellerBefore, expectedReturn, 1, "seller return");

        (,,,,,,,,,,,iCDS.Status status) = cds.protections(id);
        assertEq(uint8(status), uint8(iCDS.Status.Settled), "status=Settled");
    }

    function test_settle_requiresTriggered() public {
        uint256 id = _openAndAccept();
        vm.prank(BUYER);
        vm.expectRevert("iCDS: not triggered");
        cds.settle(id);
    }

    function test_settle_onlyBuyer() public {
        uint256 id = _openAndAccept();
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        vm.prank(SELLER); // not the buyer
        vm.expectRevert("iCDS: not buyer");
        cds.settle(id);
    }

    // ─── 6. Expiry (no default) ───────────────────────────────────

    function test_expire_sellerReclaimsCollateral() public {
        uint256 id = _openAndAccept();

        // Fast-forward past tenor
        vm.warp(block.timestamp + TENOR_DAYS * 1 days + 1);

        uint256 sellerBefore = token.balanceOf(SELLER);
        vm.prank(SELLER);
        cds.expire(id);

        assertEq(token.balanceOf(SELLER) - sellerBefore, NOTIONAL, "full notional returned");

        (,,,,,,,,,,,iCDS.Status status) = cds.protections(id);
        assertEq(uint8(status), uint8(iCDS.Status.Expired), "status=Expired");
    }

    function test_expire_beforeTenorReverts() public {
        uint256 id = _openAndAccept();
        vm.prank(SELLER);
        vm.expectRevert("iCDS: not expired");
        cds.expire(id);
    }

    function test_expire_onlyAcceptedByBuyer_thenSellerExpires() public {
        // Unaccepted protection can also expire
        vm.prank(SELLER);
        uint256 id = cds.openProtection(ASSET, address(token), NOTIONAL, RECOVERY_WAD, TENOR_DAYS);
        vm.warp(block.timestamp + TENOR_DAYS * 1 days + 1);

        uint256 sellerBefore = token.balanceOf(SELLER);
        vm.prank(SELLER);
        cds.expire(id);

        assertEq(token.balanceOf(SELLER) - sellerBefore, NOTIONAL, "unaccepted notional returned");
    }

    // ─── 7. Settlement window (C-4 fix) ──────────────────────────

    function test_settle_rejectsAfterWindow() public {
        uint256 id = _openAndAccept();

        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        // Fast-forward past settlement window
        vm.warp(block.timestamp + cds.SETTLEMENT_WINDOW() + 1);

        vm.prank(BUYER);
        vm.expectRevert("iCDS: settlement window expired");
        cds.settle(id);
    }

    function test_expireTrigger_returnsSellerCollateral() public {
        uint256 id = _openAndAccept();

        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        // Fast-forward past settlement window
        vm.warp(block.timestamp + cds.SETTLEMENT_WINDOW() + 1);

        uint256 sellerBefore = token.balanceOf(SELLER);
        // Permissionless — anyone can call expireTrigger
        cds.expireTrigger(id);

        assertEq(token.balanceOf(SELLER) - sellerBefore, NOTIONAL, "full notional returned to seller");

        (,,,,,,,,,,,iCDS.Status status) = cds.protections(id);
        assertEq(uint8(status), uint8(iCDS.Status.Expired), "status=Expired");
    }

    function test_expireTrigger_revertsIfWindowStillOpen() public {
        uint256 id = _openAndAccept();

        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        // Window not yet expired
        vm.expectRevert("iCDS: window still open");
        cds.expireTrigger(id);
    }

    function test_settle_worksWithinWindow() public {
        uint256 id = _openAndAccept();

        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 19_000e18);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        // Warp to just before window closes
        vm.warp(block.timestamp + cds.SETTLEMENT_WINDOW() - 1);

        uint256 buyerBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        cds.settle(id); // must not revert

        assertGt(token.balanceOf(BUYER), buyerBefore, "buyer received payout within window");
    }

    // ─── 8. Fuzz: recovery rate ───────────────────────────────────

    function testFuzz_settlement_lgdCorrect(uint256 recovery) public {
        recovery = bound(recovery, 1e16, 99e16); // 1% to 99% recovery

        vm.prank(SELLER);
        uint256 id = cds.openProtection(ASSET, address(token), NOTIONAL, recovery, TENOR_DAYS);
        vm.prank(BUYER);
        cds.acceptProtection(id);

        // Trigger default
        vm.prank(OWNER);
        mockOracle.setIndexPrice(ASSET, 0); // Price = 0 → always ≤ floor
        // But MockOracle requires > 0: use 1 wei
        mockOracle.setIndexPrice(ASSET, 1);
        vm.prank(KEEPER);
        cds.triggerCreditEvent(id);

        uint256 buyerBefore = token.balanceOf(BUYER);
        vm.prank(BUYER);
        cds.settle(id);

        uint256 expectedPayout = (NOTIONAL * (WAD - recovery)) / WAD;
        assertApproxEqAbs(
            token.balanceOf(BUYER) - buyerBefore,
            expectedPayout,
            1,
            "LGD correct for any recovery rate"
        );
    }
}
