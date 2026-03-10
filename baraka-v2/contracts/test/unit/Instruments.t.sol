// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/instruments/iCDS.sol";
import "../../src/instruments/TakafulPool.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracleAdapter.sol";
import "../mocks/MockEverlastingOption.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Fee-on-transfer token for negative-path tests
// ════════════════════════════════════════════════════════════════════════════

contract FeeOnTransferToken is MockERC20 {
    uint256 public feeBps = 100; // 1 %

    constructor() MockERC20("FeeToken", "FEE", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        super.transfer(to, amount - fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeBps) / 10_000;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount - fee);
        // fee stays in `from` — net received < amount
        return true;
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  iCDS Unit Tests
// ════════════════════════════════════════════════════════════════════════════

contract iCDSTest is Test {
    iCDS internal cds;
    MockERC20 internal usdc;
    MockOracleAdapter internal oracle;
    MockEverlastingOption internal evOption;

    address owner   = address(0xABCD);
    address seller  = address(0x1111);
    address buyer   = address(0x2222);
    address keeper  = address(0x3333);
    address nobody  = address(0x4444);

    bytes32 constant MARKET = keccak256("ETH-USD");
    uint256 constant WAD    = 1e18;

    // ── helpers ──────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);
        usdc     = new MockERC20("USD Coin", "USDC", 18);
        oracle   = new MockOracleAdapter();
        evOption = new MockEverlastingOption();

        cds = new iCDS(owner, address(evOption), address(oracle));
        cds.setKeeper(keeper, true);
        vm.stopPrank();

        oracle.setIndexPrice(MARKET, 2000e18); // ETH @ $2 000
        evOption.setPutRate(0.05e18);           // 5 % premium

        usdc.mint(seller, 1_000_000e18);
        usdc.mint(buyer,  1_000_000e18);

        vm.prank(seller);
        usdc.approve(address(cds), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(cds), type(uint256).max);
    }

    /// @dev Open a standard protection and return its id.
    function _open() internal returns (uint256 id) {
        vm.prank(seller);
        id = cds.openProtection(MARKET, address(usdc), 100_000e18, 0.6e18, 365);
    }

    /// @dev Open and accept a protection, returning its id.
    function _openAndAccept() internal returns (uint256 id) {
        id = _open();
        vm.prank(buyer);
        cds.acceptProtection(id);
    }

    /// @dev Read status from protections mapping (field 11 of 12).
    function _status(uint256 id) internal view returns (iCDS.Status s) {
        (,,,,,,,,,,,s) = cds.protections(id);
    }

    /// @dev Read triggeredAt from protections mapping (field 10 of 12).
    function _triggeredAt(uint256 id) internal view returns (uint256 t) {
        (,,,,,,,,,,t,) = cds.protections(id);
    }

    /// @dev Read lastPremiumAt (field 8) and premiumsCollected (field 9).
    function _premiumInfo(uint256 id) internal view returns (uint256 lastPremiumAt, uint256 premCollected) {
        (,,,,,,,,lastPremiumAt,premCollected,,) = cds.protections(id);
    }

    // ── 1. openProtection ───────────────────────────────────────────────

    function test_openProtection_createsOpen() public {
        uint256 id = _open();

        (
            address s,
            address b,
            bytes32 refAsset,
            address token,
            uint256 notional,
            uint256 recoveryRateWad,
            uint256 recoveryFloorWad,
            uint256 tenorEnd,
            uint256 lastPremiumAt,
            uint256 premiumsCollected,
            uint256 triggeredAt,
            iCDS.Status status
        ) = cds.protections(id);

        assertEq(s, seller, "seller stored");
        assertEq(b, address(0), "no buyer yet");
        assertEq(refAsset, MARKET, "refAsset");
        assertEq(token, address(usdc), "token");
        assertEq(notional, 100_000e18, "notional");
        assertEq(recoveryRateWad, 0.6e18, "recoveryRate");
        // recoveryFloor = spot * recoveryRate = 2000e18 * 0.6e18 / 1e18 = 1200e18
        assertEq(recoveryFloorWad, 1200e18, "recoveryFloor");
        assertEq(tenorEnd, block.timestamp + 365 days, "tenorEnd");
        assertEq(lastPremiumAt, 0, "no premium yet");
        assertEq(premiumsCollected, 0, "no premiums");
        assertEq(triggeredAt, 0, "not triggered");
        assertTrue(status == iCDS.Status.Open, "status Open");

        // notional transferred into contract
        assertEq(usdc.balanceOf(address(cds)), 100_000e18, "contract holds notional");
    }

    function test_openProtection_reverts_zeroToken() public {
        vm.prank(seller);
        vm.expectRevert("iCDS: zero addr");
        cds.openProtection(MARKET, address(0), 100_000e18, 0.6e18, 365);
    }

    function test_openProtection_reverts_zeroNotional() public {
        vm.prank(seller);
        vm.expectRevert("iCDS: zero notional");
        cds.openProtection(MARKET, address(usdc), 0, 0.6e18, 365);
    }

    function test_openProtection_reverts_badRecoveryRate_zero() public {
        vm.prank(seller);
        vm.expectRevert("iCDS: bad recovery rate");
        cds.openProtection(MARKET, address(usdc), 100_000e18, 0, 365);
    }

    function test_openProtection_reverts_badRecoveryRate_atWad() public {
        vm.prank(seller);
        vm.expectRevert("iCDS: bad recovery rate");
        cds.openProtection(MARKET, address(usdc), 100_000e18, WAD, 365);
    }

    function test_openProtection_reverts_badTenor_zero() public {
        vm.prank(seller);
        vm.expectRevert("iCDS: bad tenor");
        cds.openProtection(MARKET, address(usdc), 100_000e18, 0.6e18, 0);
    }

    function test_openProtection_reverts_badTenor_tooLarge() public {
        vm.prank(seller);
        vm.expectRevert("iCDS: bad tenor");
        cds.openProtection(MARKET, address(usdc), 100_000e18, 0.6e18, 3651);
    }

    // ── 2. cancelProtection ─────────────────────────────────────────────

    function test_cancelProtection_returnsNotional() public {
        uint256 id = _open();
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(seller);
        cds.cancelProtection(id);

        assertTrue(_status(id) == iCDS.Status.Expired, "status Expired after cancel");
        assertEq(usdc.balanceOf(seller), sellerBefore + 100_000e18, "notional returned");
        assertEq(usdc.balanceOf(address(cds)), 0, "contract empty");
    }

    function test_cancelProtection_reverts_notSeller() public {
        uint256 id = _open();
        vm.prank(buyer);
        vm.expectRevert("iCDS: not seller");
        cds.cancelProtection(id);
    }

    function test_cancelProtection_reverts_notOpen() public {
        uint256 id = _openAndAccept();
        vm.prank(seller);
        vm.expectRevert("iCDS: not open");
        cds.cancelProtection(id);
    }

    // ── 3. acceptProtection ─────────────────────────────────────────────

    function test_acceptProtection_paysPremium() public {
        uint256 id = _open();
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        cds.acceptProtection(id);

        (, address b,,,,,,,,,, ) = cds.protections(id);
        assertEq(b, buyer, "buyer set");
        assertTrue(_status(id) == iCDS.Status.Active, "status Active");

        // Premium = putRate * notional / WAD = 0.05e18 * 100_000e18 / 1e18 = 5_000e18
        uint256 expectedPremium = 5_000e18;
        (, uint256 premCollected) = _premiumInfo(id);
        assertEq(premCollected, expectedPremium, "premiums collected");
        assertEq(usdc.balanceOf(buyer), buyerBefore - expectedPremium, "buyer paid premium");
        assertEq(usdc.balanceOf(seller), sellerBefore + expectedPremium, "seller received premium");
    }

    function test_acceptProtection_reverts_expired() public {
        uint256 id = _open();
        // Warp past tenorEnd
        vm.warp(block.timestamp + 366 days);
        vm.prank(buyer);
        vm.expectRevert("iCDS: expired");
        cds.acceptProtection(id);
    }

    function test_acceptProtection_reverts_alreadyActive() public {
        uint256 id = _openAndAccept();
        vm.prank(nobody);
        vm.expectRevert("iCDS: not open");
        cds.acceptProtection(id);
    }

    // ── 4. payPremium — H-6: advance by exactly one period ──────────────

    function test_payPremium_advancesByOnePeriod() public {
        uint256 id = _openAndAccept();
        uint256 acceptTime = block.timestamp;

        // Warp past one premium period
        vm.warp(acceptTime + 90 days);

        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.prank(buyer);
        cds.payPremium(id);

        (uint256 lastPremiumAt, uint256 premCollected) = _premiumInfo(id);

        // H-6 fix: lastPremiumAt advanced by exactly PREMIUM_PERIOD from the previous value
        assertEq(lastPremiumAt, acceptTime + 90 days, "lastPremiumAt advanced by one period");

        uint256 expectedPremium = 5_000e18;
        // premiumsCollected should be initial + second
        assertEq(premCollected, 2 * expectedPremium, "two premiums collected");
        assertEq(usdc.balanceOf(buyer), buyerBefore - expectedPremium, "buyer paid second premium");
    }

    function test_payPremium_reverts_tooSoon() public {
        uint256 id = _openAndAccept();
        // Only move forward 89 days (less than PREMIUM_PERIOD)
        vm.warp(block.timestamp + 89 days);
        vm.prank(buyer);
        vm.expectRevert("iCDS: too soon");
        cds.payPremium(id);
    }

    function test_payPremium_reverts_notBuyer() public {
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 90 days);
        vm.prank(seller);
        vm.expectRevert("iCDS: not buyer");
        cds.payPremium(id);
    }

    function test_payPremium_reverts_notActive() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 90 days);
        vm.prank(buyer);
        vm.expectRevert("iCDS: not active");
        cds.payPremium(id);
    }

    // ── 5. triggerCreditEvent ───────────────────────────────────────────

    function test_triggerCreditEvent_setsTriggered() public {
        uint256 id = _openAndAccept();

        // Drop spot below recovery floor (1200e18)
        oracle.setIndexPrice(MARKET, 1000e18);

        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        assertTrue(_status(id) == iCDS.Status.Triggered, "status Triggered");
        assertEq(_triggeredAt(id), block.timestamp, "triggeredAt set");
    }

    function test_triggerCreditEvent_atExactFloor() public {
        uint256 id = _openAndAccept();
        // Set spot exactly at recovery floor
        oracle.setIndexPrice(MARKET, 1200e18);

        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        assertTrue(_status(id) == iCDS.Status.Triggered, "trigger at exact floor");
    }

    function test_triggerCreditEvent_reverts_notKeeper() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(nobody);
        vm.expectRevert("iCDS: not keeper");
        cds.triggerCreditEvent(id);
    }

    function test_triggerCreditEvent_reverts_spotAboveFloor() public {
        uint256 id = _openAndAccept();
        // Spot still at 2000e18, floor is 1200e18
        vm.prank(keeper);
        vm.expectRevert("iCDS: no default");
        cds.triggerCreditEvent(id);
    }

    function test_triggerCreditEvent_reverts_notActive() public {
        uint256 id = _open(); // still Open, not Active
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(keeper);
        vm.expectRevert("iCDS: not active");
        cds.triggerCreditEvent(id);
    }

    function test_triggerCreditEvent_reverts_pastTenorEnd() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.warp(block.timestamp + 366 days);
        vm.prank(keeper);
        vm.expectRevert("iCDS: expired");
        cds.triggerCreditEvent(id);
    }

    // ── 6. settle ───────────────────────────────────────────────────────

    function test_settle_paysBuyerCorrectly() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);

        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        cds.settle(id);

        assertTrue(_status(id) == iCDS.Status.Settled, "status Settled");

        // loss = notional * (1 - recoveryRate) / WAD = 100_000e18 * 0.4e18 / 1e18 = 40_000e18
        uint256 expectedPayout = 40_000e18;
        uint256 expectedSellerReturn = 60_000e18;

        assertEq(usdc.balanceOf(buyer), buyerBefore + expectedPayout, "buyer payout");
        assertEq(usdc.balanceOf(seller), sellerBefore + expectedSellerReturn, "seller return");
        assertEq(usdc.balanceOf(address(cds)), 0, "contract drained");
    }

    function test_settle_reverts_notTriggered() public {
        uint256 id = _openAndAccept();
        vm.prank(buyer);
        vm.expectRevert("iCDS: not triggered");
        cds.settle(id);
    }

    function test_settle_reverts_notBuyer() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        vm.prank(seller);
        vm.expectRevert("iCDS: not buyer");
        cds.settle(id);
    }

    function test_settle_reverts_afterSettlementWindow() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        // Warp past settlement window (7 days + 1 second)
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(buyer);
        vm.expectRevert("iCDS: settlement window expired");
        cds.settle(id);
    }

    function test_settle_withinLastSecondOfWindow() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        uint256 triggerTime = block.timestamp;
        // Warp to the very last second of the window
        vm.warp(triggerTime + 7 days);

        vm.prank(buyer);
        cds.settle(id); // should NOT revert

        assertTrue(_status(id) == iCDS.Status.Settled, "settled at window edge");
    }

    // ── 7. expire ───────────────────────────────────────────────────────

    function test_expire_sellerRecoversNotional() public {
        uint256 id = _openAndAccept();
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.warp(block.timestamp + 365 days);

        vm.prank(seller);
        cds.expire(id);

        assertTrue(_status(id) == iCDS.Status.Expired, "status Expired");
        assertEq(usdc.balanceOf(seller), sellerBefore + 100_000e18, "notional returned");
    }

    function test_expire_reverts_notExpired() public {
        uint256 id = _openAndAccept();
        vm.prank(seller);
        vm.expectRevert("iCDS: not expired");
        cds.expire(id);
    }

    function test_expire_reverts_notSeller() public {
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 365 days);
        vm.prank(buyer);
        vm.expectRevert("iCDS: not seller");
        cds.expire(id);
    }

    function test_expire_canExpireOpenProtection() public {
        uint256 id = _open(); // Open, not Active
        vm.warp(block.timestamp + 365 days);
        vm.prank(seller);
        cds.expire(id);

        assertTrue(_status(id) == iCDS.Status.Expired, "open protection expired");
    }

    // ── 8. terminateForNonPayment — iCDS-H-2 ───────────────────────────

    function test_terminateForNonPayment_afterGracePeriod() public {
        uint256 id = _openAndAccept();
        uint256 acceptTime = block.timestamp;

        // Warp past premium period + grace period + 1 second
        vm.warp(acceptTime + 90 days + 7 days + 1);

        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(seller);
        cds.terminateForNonPayment(id);

        assertTrue(_status(id) == iCDS.Status.Expired, "terminated");
        assertEq(usdc.balanceOf(seller), sellerBefore + 100_000e18, "notional returned");
    }

    function test_terminateForNonPayment_reverts_graceNotElapsed() public {
        uint256 id = _openAndAccept();
        // Warp to just premium period + grace period (exactly at boundary — not past)
        vm.warp(block.timestamp + 90 days + 7 days);
        vm.prank(seller);
        vm.expectRevert("iCDS: grace period not elapsed");
        cds.terminateForNonPayment(id);
    }

    function test_terminateForNonPayment_reverts_notSeller() public {
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 90 days + 7 days + 1);
        vm.prank(buyer);
        vm.expectRevert("iCDS: only seller");
        cds.terminateForNonPayment(id);
    }

    function test_terminateForNonPayment_reverts_duringCreditEvent_H2() public {
        // iCDS-H-2: cannot terminate when spot <= recoveryFloor (credit event active)
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 90 days + 7 days + 1);

        // Drop spot below floor
        oracle.setIndexPrice(MARKET, 1000e18);

        vm.prank(seller);
        vm.expectRevert("iCDS: credit event active, cannot terminate");
        cds.terminateForNonPayment(id);
    }

    function test_terminateForNonPayment_reverts_atExactFloor_H2() public {
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 90 days + 7 days + 1);

        // Spot exactly at floor
        oracle.setIndexPrice(MARKET, 1200e18);

        vm.prank(seller);
        vm.expectRevert("iCDS: credit event active, cannot terminate");
        cds.terminateForNonPayment(id);
    }

    function test_terminateForNonPayment_allowedWhenSpotAboveFloor() public {
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 90 days + 7 days + 1);

        // Spot above floor — termination allowed
        oracle.setIndexPrice(MARKET, 1201e18);

        vm.prank(seller);
        cds.terminateForNonPayment(id); // should not revert

        assertTrue(_status(id) == iCDS.Status.Expired, "terminated successfully");
    }

    function test_terminateForNonPayment_revertsWhenOracleStale() public {
        // AUDIT FIX (ICDS-M-1): spot == 0 means oracle outage — termination blocked
        uint256 id = _openAndAccept();
        vm.warp(block.timestamp + 90 days + 7 days + 1);

        oracle.setIndexPrice(MARKET, 0);

        vm.prank(seller);
        vm.expectRevert("iCDS: oracle stale");
        cds.terminateForNonPayment(id);
    }

    // ── 9. expireTrigger ────────────────────────────────────────────────

    function test_expireTrigger_afterSettlementWindow() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        uint256 sellerBefore = usdc.balanceOf(seller);

        // Warp past settlement window
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(seller); // AUDIT FIX (L4-L-3): restricted to keeper or seller
        cds.expireTrigger(id);

        assertTrue(_status(id) == iCDS.Status.Expired, "trigger expired");
        assertEq(usdc.balanceOf(seller), sellerBefore + 100_000e18, "notional to seller");
    }

    function test_expireTrigger_reverts_windowStillOpen() public {
        uint256 id = _openAndAccept();
        oracle.setIndexPrice(MARKET, 1000e18);
        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        vm.warp(block.timestamp + 7 days); // exactly at boundary — window still open
        vm.prank(nobody);
        vm.expectRevert("iCDS: window still open");
        cds.expireTrigger(id);
    }

    function test_expireTrigger_reverts_notTriggered() public {
        uint256 id = _openAndAccept();
        vm.prank(nobody);
        vm.expectRevert("iCDS: not triggered");
        cds.expireTrigger(id);
    }

    // ── 10. Fee-on-transfer check ───────────────────────────────────────

    function test_openProtection_reverts_feeOnTransfer() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(seller, 1_000_000e18);
        vm.prank(seller);
        fot.approve(address(cds), type(uint256).max);

        vm.prank(seller);
        vm.expectRevert("iCDS: fee-on-transfer not supported");
        cds.openProtection(MARKET, address(fot), 100_000e18, 0.6e18, 365);
    }

    // ── Additional edge cases ───────────────────────────────────────────

    function test_constructorRevertsZeroEvOption() public {
        vm.expectRevert("iCDS: zero evOption");
        new iCDS(owner, address(0), address(oracle));
    }

    function test_constructorRevertsZeroOracle() public {
        vm.expectRevert("iCDS: zero oracle");
        new iCDS(owner, address(evOption), address(0));
    }

    function test_keeperAuthorisation() public {
        assertFalse(cds.authorisedKeepers(nobody), "nobody not keeper");
        assertTrue(cds.authorisedKeepers(keeper), "keeper authorised");

        vm.prank(owner);
        cds.setKeeper(keeper, false);
        assertFalse(cds.authorisedKeepers(keeper), "keeper removed");
    }

    function test_pauseBlocksOpen() public {
        vm.prank(owner);
        cds.pause();

        vm.prank(seller);
        vm.expectRevert();
        cds.openProtection(MARKET, address(usdc), 100_000e18, 0.6e18, 365);
    }

    function test_computePremium_view() public {
        uint256 id = _open();
        uint256 premium = cds.computePremium(id);
        // putRate * notional / WAD = 0.05e18 * 100_000e18 / 1e18 = 5_000e18
        assertEq(premium, 5_000e18, "computed premium");
    }

    function test_settle_highRecoveryRate() public {
        // Recovery rate = 0.99e18 => loss = 1% of notional = 1_000e18
        vm.prank(seller);
        uint256 id = cds.openProtection(MARKET, address(usdc), 100_000e18, 0.99e18, 365);
        vm.prank(buyer);
        cds.acceptProtection(id);

        // recoveryFloor = 2000e18 * 0.99e18 / 1e18 = 1980e18
        oracle.setIndexPrice(MARKET, 1900e18); // below floor
        vm.prank(keeper);
        cds.triggerCreditEvent(id);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        cds.settle(id);

        uint256 expectedPayout = 1_000e18; // 1% loss
        assertEq(usdc.balanceOf(buyer) - buyerBefore, expectedPayout, "1% payout");
    }

    function test_multipleProtections_independentIds() public {
        uint256 id0 = _open();
        uint256 id1 = _open();
        assertEq(id0, 0, "first id is 0");
        assertEq(id1, 1, "second id is 1");
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  TakafulPool Unit Tests
// ════════════════════════════════════════════════════════════════════════════

contract TakafulPoolTest is Test {
    TakafulPool internal pool;
    MockERC20 internal usdc;
    MockOracleAdapter internal oracle;
    MockEverlastingOption internal evOption;

    address owner    = address(0xABCD);
    address operator = address(0xBBBB);
    address keeper   = address(0x3333);
    address alice    = address(0x1111);
    address bob      = address(0x2222);
    address nobody   = address(0x4444);

    bytes32 constant MARKET  = keccak256("ETH-USD");
    bytes32 constant POOL_ID = keccak256("TAKAFUL-ETH-1");
    uint256 constant WAD     = 1e18;

    // ── helpers ──────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);
        usdc     = new MockERC20("USD Coin", "USDC", 18);
        oracle   = new MockOracleAdapter();
        evOption = new MockEverlastingOption();

        pool = new TakafulPool(owner, address(evOption), address(oracle), operator);
        pool.setKeeper(keeper, true);
        pool.setMaxClaimRatioWad(WAD); // disable per-claim cap for existing tests (P3-INST-8 cap = 100%)
        pool.setContributionCooldown(0); // disable cooldown for existing tests (P4-A3-5 default = 60s)
        vm.stopPrank();

        oracle.setIndexPrice(MARKET, 2000e18);
        evOption.setPutRate(0.05e18); // 5 %

        usdc.mint(alice, 1_000_000e18);
        usdc.mint(bob,   1_000_000e18);

        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pool), type(uint256).max);
    }

    /// @dev Create the standard pool.
    function _createPool() internal {
        vm.prank(owner);
        pool.createPool(POOL_ID, MARKET, address(usdc), 1800e18);
    }

    /// @dev Create pool and have alice contribute.
    function _createAndContribute(uint256 coverageAmount) internal {
        _createPool();
        vm.prank(alice);
        pool.contribute(POOL_ID, coverageAmount);
        vm.roll(block.number + 1); // advance past same-block cooldown (P3-INST-7 fix)
    }

    // ── 1. createPool ───────────────────────────────────────────────────

    function test_createPool_setsFields() public {
        _createPool();

        (bytes32 asset, address token, uint256 floorWad, bool active) = pool.pools(POOL_ID);
        assertEq(asset, MARKET, "asset");
        assertEq(token, address(usdc), "token");
        assertEq(floorWad, 1800e18, "floorWad");
        assertTrue(active, "active");
    }

    function test_createPool_reverts_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        pool.createPool(POOL_ID, MARKET, address(usdc), 1800e18);
    }

    function test_createPool_reverts_zeroToken() public {
        vm.prank(owner);
        vm.expectRevert("TP: zero addr");
        pool.createPool(POOL_ID, MARKET, address(0), 1800e18);
    }

    function test_createPool_reverts_zeroFloor() public {
        vm.prank(owner);
        vm.expectRevert("TP: zero floor");
        pool.createPool(POOL_ID, MARKET, address(usdc), 0);
    }

    function test_createPool_reverts_duplicate() public {
        _createPool();
        vm.prank(owner);
        vm.expectRevert("TP: pool exists");
        pool.createPool(POOL_ID, MARKET, address(usdc), 1800e18);
    }

    // ── 2. contribute ───────────────────────────────────────────────────

    function test_contribute_calculatesCorrectly() public {
        _createPool();
        uint256 coverageAmount = 100_000e18;
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 operatorBefore = usdc.balanceOf(operator);

        vm.prank(alice);
        pool.contribute(POOL_ID, coverageAmount);

        // tabarruGross = putRate * coverage / WAD = 0.05e18 * 100_000e18 / 1e18 = 5_000e18
        uint256 tabarruGross = 5_000e18;
        // wakala = tabarruGross * 1000 / 10_000 = 500e18
        uint256 expectedWakala = 500e18;
        uint256 expectedTabarru = tabarruGross - expectedWakala;

        // Alice paid tabarruGross
        assertEq(usdc.balanceOf(alice), aliceBefore - tabarruGross, "alice paid tabarruGross");
        // Operator received wakala
        assertEq(usdc.balanceOf(operator), operatorBefore + expectedWakala, "operator got wakala");
        // Pool balance = tabarru (net of wakala)
        assertEq(pool.poolBalance(POOL_ID), expectedTabarru, "pool balance = tabarru");

        // Member state
        (uint256 totalCoverage, uint256 totalTabarru,) = pool.members(POOL_ID, alice);
        assertEq(totalCoverage, coverageAmount, "member coverage");
        assertEq(totalTabarru, expectedTabarru, "member tabarru");
    }

    function test_contribute_reverts_zeroCoverage() public {
        _createPool();
        vm.prank(alice);
        vm.expectRevert("TP: zero coverage");
        pool.contribute(POOL_ID, 0);
    }

    function test_contribute_reverts_inactivePool() public {
        vm.prank(alice);
        vm.expectRevert("TP: pool inactive");
        pool.contribute(POOL_ID, 100_000e18);
    }

    function test_contribute_reverts_zeroSpot() public {
        _createPool();
        oracle.setIndexPrice(MARKET, 0);
        vm.prank(alice);
        vm.expectRevert("TP: zero spot");
        pool.contribute(POOL_ID, 100_000e18);
    }

    function test_contribute_feeOnTransfer_reverts() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(alice, 1_000_000e18);
        vm.prank(alice);
        fot.approve(address(pool), type(uint256).max);

        bytes32 fotPoolId = keccak256("FOT-POOL");
        vm.prank(owner);
        pool.createPool(fotPoolId, MARKET, address(fot), 1800e18);

        vm.prank(alice);
        vm.expectRevert("TP: fee-on-transfer not supported");
        pool.contribute(fotPoolId, 100_000e18);
    }

    function test_contribute_multipleContributions() public {
        _createPool();

        vm.prank(alice);
        pool.contribute(POOL_ID, 50_000e18);
        vm.prank(alice);
        pool.contribute(POOL_ID, 50_000e18);

        (uint256 totalCoverage, uint256 totalTabarru,) = pool.members(POOL_ID, alice);
        assertEq(totalCoverage, 100_000e18, "cumulative coverage");

        // Each contribution: tabarruGross = 2_500e18, wakala = 250e18, net = 2_250e18
        assertEq(totalTabarru, 2 * 2_250e18, "cumulative tabarru");
    }

    // ── 3. payClaim ─────────────────────────────────────────────────────

    function test_payClaim_paysCorrectAmount() public {
        _createAndContribute(100_000e18);

        // Drop spot below floor (1800e18)
        oracle.setIndexPrice(MARKET, 1500e18);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 claimAmount = 1_000e18;

        vm.prank(keeper);
        pool.payClaim(POOL_ID, alice, claimAmount);

        assertEq(usdc.balanceOf(alice), aliceBefore + claimAmount, "claim paid to alice");
        // poolBalance was 4500e18, now 4500 - 1000 = 3500
        assertEq(pool.poolBalance(POOL_ID), 4_500e18 - claimAmount, "pool balance reduced");
        assertEq(pool.totalClaimsPaid(POOL_ID), claimAmount, "total claims tracked");
    }

    function test_payClaim_capsAtPoolBalance() public {
        _createAndContribute(100_000e18);
        oracle.setIndexPrice(MARKET, 1500e18);

        uint256 balance = pool.poolBalance(POOL_ID);
        // Claim more than pool balance — should be capped
        uint256 bigClaim = balance + 1_000e18;

        // Coverage must be >= amount to pass the require check; alice has 100k coverage
        vm.prank(keeper);
        pool.payClaim(POOL_ID, alice, bigClaim);

        // Payout capped at pool balance
        assertEq(pool.poolBalance(POOL_ID), 0, "pool drained");
    }

    function test_payClaim_reverts_notKeeper() public {
        _createAndContribute(100_000e18);
        oracle.setIndexPrice(MARKET, 1500e18);

        vm.prank(nobody);
        vm.expectRevert("TP: not keeper");
        pool.payClaim(POOL_ID, alice, 100e18);
    }

    function test_payClaim_reverts_floorNotBreached() public {
        _createAndContribute(100_000e18);
        // Spot still at 2000e18, above floor of 1800e18
        vm.prank(keeper);
        vm.expectRevert("TP: floor not breached");
        pool.payClaim(POOL_ID, alice, 100e18);
    }

    function test_payClaim_reverts_spotAtExactFloor() public {
        _createAndContribute(100_000e18);
        // Spot exactly at floor — not breached (strict less-than)
        oracle.setIndexPrice(MARKET, 1800e18);
        vm.prank(keeper);
        vm.expectRevert("TP: floor not breached");
        pool.payClaim(POOL_ID, alice, 100e18);
    }

    function test_payClaim_reverts_notMember() public {
        _createAndContribute(100_000e18);
        oracle.setIndexPrice(MARKET, 1500e18);

        vm.prank(keeper);
        vm.expectRevert("TP: not a member");
        pool.payClaim(POOL_ID, bob, 100e18);
    }

    function test_payClaim_reverts_exceedsCoverage() public {
        _createAndContribute(100_000e18);
        oracle.setIndexPrice(MARKET, 1500e18);

        vm.prank(keeper);
        vm.expectRevert("TP: exceeds coverage");
        pool.payClaim(POOL_ID, alice, 100_001e18);
    }

    function test_payClaim_reverts_zeroBeneficiary() public {
        _createAndContribute(100_000e18);
        oracle.setIndexPrice(MARKET, 1500e18);

        vm.prank(keeper);
        vm.expectRevert("TP: zero beneficiary");
        pool.payClaim(POOL_ID, address(0), 100e18);
    }

    function test_payClaim_reverts_zeroAmount() public {
        _createAndContribute(100_000e18);
        oracle.setIndexPrice(MARKET, 1500e18);

        vm.prank(keeper);
        vm.expectRevert("TP: zero amount");
        pool.payClaim(POOL_ID, alice, 0);
    }

    // ── 4. distributeSurplus ────────────────────────────────────────────

    function test_distributeSurplus_respectsReserveFloor() public {
        // Build up a large pool balance
        _createPool();
        // Contribute enough to create meaningful surplus
        vm.prank(alice);
        pool.contribute(POOL_ID, 1_000_000e18);
        // poolBalance = putRate * coverage * (1 - wakalaFee) = 0.05 * 1M * 0.9 = 45_000e18

        uint256 balance = pool.poolBalance(POOL_ID);
        assertEq(balance, 45_000e18, "pool balance sanity check");

        uint256 recipientBefore = usdc.balanceOf(alice);

        // No claims paid, so claimsReserve = 0
        // pctReserve = 45_000 * 30% = 13_500
        // reserve = max(0, 13_500) = 13_500
        // surplus = 45_000 - 13_500 = 31_500

        vm.startPrank(owner);
        pool.setSurplusRecipient(POOL_ID, alice, true);
        pool.distributeSurplus(POOL_ID, alice);
        vm.stopPrank();

        assertEq(pool.poolBalance(POOL_ID), 13_500e18, "reserve kept");
        assertEq(usdc.balanceOf(alice), recipientBefore + 31_500e18, "surplus distributed");
    }

    function test_distributeSurplus_30dayCooldown() public {
        _createPool();
        vm.prank(alice);
        pool.contribute(POOL_ID, 1_000_000e18);

        vm.startPrank(owner);
        pool.setSurplusRecipient(POOL_ID, alice, true);
        pool.distributeSurplus(POOL_ID, alice);
        vm.stopPrank();

        // Contribute more so surplus exists for next attempt
        vm.prank(alice);
        pool.contribute(POOL_ID, 1_000_000e18);

        // Second call within 30 days should revert
        vm.warp(block.timestamp + 29 days);
        vm.prank(owner);
        vm.expectRevert("TP: surplus cooldown");
        pool.distributeSurplus(POOL_ID, alice);
    }

    function test_distributeSurplus_cooldownSucceedsAfter30Days() public {
        _createPool();
        vm.prank(alice);
        pool.contribute(POOL_ID, 1_000_000e18);

        vm.startPrank(owner);
        pool.setSurplusRecipient(POOL_ID, alice, true);
        pool.distributeSurplus(POOL_ID, alice);
        vm.stopPrank();

        // Contribute more to create new surplus
        vm.prank(alice);
        pool.contribute(POOL_ID, 1_000_000e18);

        vm.warp(block.timestamp + 30 days);

        vm.prank(owner);
        pool.distributeSurplus(POOL_ID, alice); // should succeed
    }

    function test_distributeSurplus_reverts_notOwner() public {
        _createAndContribute(1_000_000e18);

        vm.prank(alice);
        vm.expectRevert();
        pool.distributeSurplus(POOL_ID, alice);
    }

    function test_distributeSurplus_reverts_noSurplus() public {
        _createPool();
        // No contributions → no balance
        vm.startPrank(owner);
        pool.setSurplusRecipient(POOL_ID, alice, true);
        vm.expectRevert("TP: no surplus");
        pool.distributeSurplus(POOL_ID, alice);
        vm.stopPrank();
    }

    function test_distributeSurplus_reverts_zeroRecipient() public {
        _createAndContribute(1_000_000e18);
        vm.prank(owner);
        vm.expectRevert("TP: zero recipient");
        pool.distributeSurplus(POOL_ID, address(0));
    }

    function test_distributeSurplus_usesClaimsReserveWhenLarger() public {
        _createPool();
        vm.prank(alice);
        pool.contribute(POOL_ID, 1_000_000e18);
        // poolBalance = 45_000e18
        vm.roll(block.number + 1); // advance past same-block cooldown (P3-INST-7 fix)

        // Pay some claims to inflate claimsReserve
        oracle.setIndexPrice(MARKET, 1500e18);
        vm.prank(keeper);
        pool.payClaim(POOL_ID, alice, 10_000e18);
        // totalClaimsPaid = 10_000e18
        // poolBalance = 35_000e18

        // Restore spot so we can distribute surplus
        oracle.setIndexPrice(MARKET, 2000e18);

        // claimsReserve = 2 * 10_000 = 20_000
        // pctReserve = 35_000 * 30% = 10_500
        // reserve = max(20_000, 10_500) = 20_000
        // surplus = 35_000 - 20_000 = 15_000

        uint256 recipientBefore = usdc.balanceOf(bob);
        vm.startPrank(owner);
        pool.setSurplusRecipient(POOL_ID, bob, true);
        pool.distributeSurplus(POOL_ID, bob);
        vm.stopPrank();

        assertEq(pool.poolBalance(POOL_ID), 20_000e18, "claims reserve kept");
        assertEq(usdc.balanceOf(bob), recipientBefore + 15_000e18, "surplus to bob");
    }

    // ── 5. Minimum wakala fee (TP-M-5) ──────────────────────────────────

    function test_contribute_minimumWakalaFee_TPM5() public {
        _createPool();

        // Set a very small put rate so that tabarruGross > 0 but wakala truncates to 0
        // wakala = (tabarruGross * 1000) / 10_000
        // For wakala to be 0 (before fix): tabarruGross must be < 10
        // tabarruGross = putRate * coverageAmount / WAD
        // If putRate = 1 and coverageAmount = 9e18, tabarruGross = 9 (rounds down to 9)
        // wakala = (9 * 1000) / 10_000 = 0 (integer math) -> fix forces to 1

        evOption.setPutRate(1); // 1 wei rate
        uint256 coverageAmount = 9e18;

        uint256 operatorBefore = usdc.balanceOf(operator);

        vm.prank(alice);
        pool.contribute(POOL_ID, coverageAmount);

        // tabarruGross = 1 * 9e18 / 1e18 = 9
        // wakala = (9 * 1000) / 10_000 = 0 -> set to 1 (TP-M-5 fix)
        // tabarru = 9 - 1 = 8

        assertEq(usdc.balanceOf(operator), operatorBefore + 1, "minimum wakala of 1 wei");
        assertEq(pool.poolBalance(POOL_ID), 8, "pool balance = tabarruGross - 1");
    }

    function test_contribute_normalWakalaNotAffectedByMinFix() public {
        _createPool();
        // With normal rates, wakala > 0 naturally, so TP-M-5 guard should not interfere
        uint256 coverageAmount = 100_000e18;

        uint256 operatorBefore = usdc.balanceOf(operator);

        vm.prank(alice);
        pool.contribute(POOL_ID, coverageAmount);

        // tabarruGross = 5_000e18, wakala = 500e18
        assertEq(usdc.balanceOf(operator), operatorBefore + 500e18, "normal wakala unaffected");
    }

    // ── Additional edge cases ───────────────────────────────────────────

    function test_constructorRevertsZeroEvOption() public {
        vm.expectRevert("TP: zero evOption");
        new TakafulPool(owner, address(0), address(oracle), operator);
    }

    function test_constructorRevertsZeroOracle() public {
        vm.expectRevert("TP: zero oracle");
        new TakafulPool(owner, address(evOption), address(0), operator);
    }

    function test_constructorRevertsZeroOperator() public {
        vm.expectRevert("TP: zero operator");
        new TakafulPool(owner, address(evOption), address(oracle), address(0));
    }

    function test_keeperAuthorisation() public {
        assertTrue(pool.authorisedKeepers(keeper), "keeper set");
        vm.prank(owner);
        pool.setKeeper(keeper, false);
        assertFalse(pool.authorisedKeepers(keeper), "keeper removed");
    }

    function test_pauseBlocksContribute() public {
        _createPool();
        vm.prank(owner);
        pool.pause();

        vm.prank(alice);
        vm.expectRevert();
        pool.contribute(POOL_ID, 100_000e18);
    }

    function test_getRequiredTabarru_view() public {
        _createPool();
        (uint256 tabarruGross, uint256 spotWad, uint256 putRateWad) =
            pool.getRequiredTabarru(POOL_ID, 100_000e18);

        assertEq(tabarruGross, 5_000e18, "tabarruGross");
        assertEq(spotWad, 2000e18, "spot");
        assertEq(putRateWad, 0.05e18, "putRate");
    }
}
