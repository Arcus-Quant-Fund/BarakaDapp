// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/FeeEngine.sol";
import "../../src/core/Vault.sol";
import "../../src/core/SubaccountManager.sol";
import "../mocks/MockERC20.sol";

/**
 * @title FeeEngineTest
 * @notice Comprehensive unit tests for FeeEngine: tier construction,
 *         fee computation, fee charging with vault integration, access control,
 *         and admin setters.
 */
contract FeeEngineTest is Test {

    // ─────────────────────────────────────────────────────
    // Constants (mirror FeeEngine internals)
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;
    uint256 constant BPS = 1e14; // 1 basis point in WAD scale

    // ─────────────────────────────────────────────────────
    // Contracts under test
    // ─────────────────────────────────────────────────────

    FeeEngine         feeEngine;
    Vault             vault;
    SubaccountManager sam;
    MockERC20         usdc;

    // ─────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────

    address owner     = address(0xABCD);
    address alice     = address(0x1111);
    address bob       = address(0x2222);
    address treasury  = address(0x3333);
    address insurance = address(0x4444);
    address stakers   = address(0x5555);
    address matching  = address(0x6666); // mock MatchingEngine (authorised caller)

    // ─────────────────────────────────────────────────────
    // Subaccounts
    // ─────────────────────────────────────────────────────

    bytes32 aliceSub;
    bytes32 bobSub;

    // ─────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        // Deploy USDC (6 decimals)
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy Vault
        vault = new Vault(owner);
        vault.setApprovedToken(address(usdc), true);

        // Deploy SubaccountManager
        sam = new SubaccountManager();

        // Deploy FeeEngine
        feeEngine = new FeeEngine(owner, address(vault), address(usdc), address(sam));

        // Authorise FeeEngine on Vault (so it can call chargeFee / settlePnL)
        vault.setAuthorised(address(feeEngine), true);

        // Authorise `owner` on Vault so we can deposit tokens directly for tests
        vault.setAuthorised(owner, true);

        // Authorise `matching` on FeeEngine (simulates MatchingEngine)
        feeEngine.setAuthorised(matching, true);

        // Set fee recipients
        feeEngine.setRecipients(treasury, insurance, stakers);

        vm.stopPrank();

        // Create subaccounts
        vm.prank(alice);
        aliceSub = sam.createSubaccount(0);

        vm.prank(bob);
        bobSub = sam.createSubaccount(0);

        // Fund subaccounts via Vault.deposit (owner is authorised)
        _fundSubaccount(aliceSub, 100_000e6);
        _fundSubaccount(bobSub, 100_000e6);
    }

    /// @dev Mint USDC to owner, approve vault, deposit for subaccount.
    function _fundSubaccount(bytes32 sub, uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.deposit(sub, address(usdc), amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 1. Constructor & tier initialisation
    // ═══════════════════════════════════════════════════════

    function test_constructor_setsVaultAndCollateral() public view {
        assertEq(address(feeEngine.vault()), address(vault));
        assertEq(feeEngine.collateralToken(), address(usdc));
    }

    function test_constructor_collateralScale_6decimals() public view {
        // USDC has 6 decimals → collateralScale = 10^(18-6) = 1e12
        assertEq(feeEngine.collateralScale(), 1e12, "collateralScale should be 1e12 for 6-decimal token");
    }

    function test_constructor_collateralScale_18decimals() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        vm.prank(owner);
        FeeEngine fe18 = new FeeEngine(owner, address(vault), address(dai), address(sam));
        assertEq(fe18.collateralScale(), 1, "collateralScale should be 1 for 18-decimal token");
    }

    function test_constructor_4tiers() public view {
        assertEq(feeEngine.getTierCount(), 4, "Should have 4 tiers");
    }

    function test_constructor_tier0_baseTier() public view {
        IFeeEngine.FeeTier memory t = feeEngine.getTier(0);
        assertEq(t.minBRKX, 0, "Tier 0 minBRKX");
        assertEq(t.takerFeeBps, 5 * BPS, "Tier 0 taker = 5 bps");
        assertEq(t.makerFeeBps, BPS / 2, "Tier 0 maker = 0.5 bps");
    }

    function test_constructor_tier1() public view {
        IFeeEngine.FeeTier memory t = feeEngine.getTier(1);
        assertEq(t.minBRKX, 1_000e18, "Tier 1 minBRKX");
        assertEq(t.takerFeeBps, 4 * BPS, "Tier 1 taker = 4 bps");
        assertEq(t.makerFeeBps, 1 * BPS, "Tier 1 maker = 1 bps");
    }

    function test_constructor_tier2() public view {
        IFeeEngine.FeeTier memory t = feeEngine.getTier(2);
        assertEq(t.minBRKX, 10_000e18, "Tier 2 minBRKX");
        assertEq(t.takerFeeBps, 35 * BPS / 10, "Tier 2 taker = 3.5 bps");
        assertEq(t.makerFeeBps, 15 * BPS / 10, "Tier 2 maker = 1.5 bps");
    }

    function test_constructor_tier3() public view {
        IFeeEngine.FeeTier memory t = feeEngine.getTier(3);
        assertEq(t.minBRKX, 50_000e18, "Tier 3 minBRKX");
        assertEq(t.takerFeeBps, 25 * BPS / 10, "Tier 3 taker = 2.5 bps");
        assertEq(t.makerFeeBps, 2 * BPS, "Tier 3 maker = 2 bps");
    }

    function test_constructor_reverts_zeroVault() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero vault");
        new FeeEngine(owner, address(0), address(usdc), address(sam));
    }

    function test_constructor_reverts_zeroCollateral() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero collateral");
        new FeeEngine(owner, address(vault), address(0), address(sam));
    }

    // ═══════════════════════════════════════════════════════
    // 2. computeTakerFee — base tier (no BRKX)
    // ═══════════════════════════════════════════════════════

    function test_computeTakerFee_baseTier() public view {
        // Notional = 50,000 in WAD = 50_000e18
        // Fee = 50_000e18 * 5e14 / 1e18 = 25e18
        uint256 notional = 50_000e18;
        uint256 fee = feeEngine.computeTakerFee(aliceSub, notional);

        uint256 expected = notional * 5 * BPS / WAD;
        assertEq(fee, expected, "5 bps of notional");
    }

    function test_computeTakerFee_1BTC_at50k() public view {
        // 1 BTC at $50,000: notional = 50_000e18
        // fee = 50_000e18 * 5e14 / 1e18 = 25e18 (WAD scale)
        // In token terms: 25e18 / 1e12 = 25e6 = 25 USDC (6 dec)
        uint256 fee = feeEngine.computeTakerFee(aliceSub, 50_000e18);
        assertEq(fee, 25e18, "Fee in WAD scale");

        uint256 feeTokens = fee / feeEngine.collateralScale();
        assertEq(feeTokens, 25e6, "25 USDC in 6-decimal token units");
    }

    function test_computeTakerFee_correctMath() public view {
        // 1 BTC at $50,000 → notional = 50_000e18 (WAD scale)
        // Base tier taker fee = 5 bps = 5e14 (WAD scale)
        // fee = notional * takerFeeBps / WAD = 50_000e18 * 5e14 / 1e18
        //     = 50_000 * 5e14 = 250_000e14 = 25e18
        // In token (USDC 6 dec): 25e18 / 1e12 = 25e6 = 25.000000 USDC
        // => $25 fee on $50,000 notional = 5 bps. Correct.

        uint256 notional = 50_000e18;
        uint256 fee = feeEngine.computeTakerFee(aliceSub, notional);
        assertEq(fee, 25e18, "5 bps of 50k = $25 in WAD");

        uint256 feeTokens = fee / feeEngine.collateralScale();
        assertEq(feeTokens, 25e6, "25 USDC in 6-decimal");
    }

    function test_computeTakerFee_smallNotional() public view {
        // $100 notional → fee = $0.05 in WAD = 5e16
        uint256 notional = 100e18;
        uint256 fee = feeEngine.computeTakerFee(aliceSub, notional);
        assertEq(fee, 5e16, "5 bps of $100 = $0.05 in WAD");

        uint256 feeTokens = fee / feeEngine.collateralScale();
        assertEq(feeTokens, 50_000, "0.05 USDC in 6-decimal = 50000");
    }

    function test_computeTakerFee_zeroNotional() public view {
        uint256 fee = feeEngine.computeTakerFee(aliceSub, 0);
        assertEq(fee, 0, "Zero notional => zero fee");
    }

    // ═══════════════════════════════════════════════════════
    // 3. computeMakerRebate — base tier (no BRKX)
    // ═══════════════════════════════════════════════════════

    function test_computeMakerRebate_baseTier() public view {
        // Base maker rebate = 0.5 bps = BPS/2 = 5e13
        // $50,000 notional: rebate = 50_000e18 * 5e13 / 1e18 = 250_000e13 = 25e17 = 2.5e18
        // In token terms: 2.5e18 / 1e12 = 2.5e6 = 2.5 USDC
        uint256 notional = 50_000e18;
        uint256 rebate = feeEngine.computeMakerRebate(aliceSub, notional);

        uint256 expected = notional * (BPS / 2) / WAD;
        assertEq(rebate, expected, "0.5 bps of notional");
        assertEq(rebate, 25e17, "0.5 bps of 50k = $2.50 in WAD");

        uint256 rebateTokens = rebate / feeEngine.collateralScale();
        assertEq(rebateTokens, 25e5, "2.5 USDC in 6-decimal");
    }

    function test_computeMakerRebate_zeroNotional() public view {
        uint256 rebate = feeEngine.computeMakerRebate(aliceSub, 0);
        assertEq(rebate, 0, "Zero notional => zero rebate");
    }

    // ═══════════════════════════════════════════════════════
    // 4. chargeTakerFee — vault integration
    // ═══════════════════════════════════════════════════════

    function test_chargeTakerFee_splits60_20_20() public {
        // Notional $10,000 → fee = $5 (5 bps)
        // In 6-dec USDC: 5e6
        // Split: 60% treasury = 3e6, 20% insurance = 1e6, 20% stakers = 1e6
        uint256 notional = 10_000e18;

        uint256 vaultBalBefore = vault.balance(aliceSub, address(usdc));
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 insuranceBefore = usdc.balanceOf(insurance);
        uint256 stakersBefore = usdc.balanceOf(stakers);

        vm.prank(matching);
        uint256 fee = feeEngine.chargeTakerFee(aliceSub, notional);

        // Fee in WAD
        assertEq(fee, 5e18, "Fee = $5 in WAD");

        // Token amounts
        uint256 feeTokens = fee / feeEngine.collateralScale();
        assertEq(feeTokens, 5e6, "5 USDC in token decimals");

        uint256 toTreasury = feeTokens * 60 / 100; // 3e6
        uint256 toInsurance = feeTokens * 20 / 100; // 1e6
        uint256 toStakers = feeTokens - toTreasury - toInsurance; // 1e6

        // Verify vault balance decreased
        assertEq(
            vault.balance(aliceSub, address(usdc)),
            vaultBalBefore - toTreasury - toInsurance - toStakers,
            "Vault balance decreased by total fee"
        );

        // Verify recipients received tokens
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, toTreasury, "Treasury got 60%");
        assertEq(usdc.balanceOf(insurance) - insuranceBefore, toInsurance, "Insurance got 20%");
        assertEq(usdc.balanceOf(stakers) - stakersBefore, toStakers, "Stakers got 20%");
    }

    function test_chargeTakerFee_emitsEvent() public {
        uint256 notional = 10_000e18;

        vm.prank(matching);
        vm.expectEmit(true, false, false, true);
        emit FeeEngine.TakerFeeCharged(aliceSub, notional, 5e18);
        feeEngine.chargeTakerFee(aliceSub, notional);
    }

    function test_chargeTakerFee_zeroNotional_returnsZero() public {
        vm.prank(matching);
        uint256 fee = feeEngine.chargeTakerFee(aliceSub, 0);
        assertEq(fee, 0, "Zero notional => zero fee => no transfers");
    }

    function test_chargeTakerFee_reverts_notAuthorised() public {
        vm.prank(alice);
        vm.expectRevert("FE: not authorised");
        feeEngine.chargeTakerFee(aliceSub, 10_000e18);
    }

    function test_chargeTakerFee_largeNotional() public {
        // Fund alice with a lot more
        _fundSubaccount(aliceSub, 10_000_000e6);

        // $1,000,000 notional → fee = $500 (5 bps)
        uint256 notional = 1_000_000e18;

        vm.prank(matching);
        uint256 fee = feeEngine.chargeTakerFee(aliceSub, notional);

        assertEq(fee, 500e18, "Fee = $500 in WAD");

        uint256 feeTokens = fee / feeEngine.collateralScale();
        assertEq(feeTokens, 500e6, "500 USDC");

        // Verify split
        uint256 toTreasury = feeTokens * 60 / 100; // 300e6
        uint256 toInsurance = feeTokens * 20 / 100; // 100e6
        uint256 toStakers = feeTokens - toTreasury - toInsurance; // 100e6

        assertEq(usdc.balanceOf(treasury), toTreasury, "Treasury 300 USDC");
        assertEq(usdc.balanceOf(insurance), toInsurance, "Insurance 100 USDC");
        assertEq(usdc.balanceOf(stakers), toStakers, "Stakers 100 USDC");
    }

    function test_chargeTakerFee_noStakerPool_redirectsToTreasury() public {
        // AUDIT FIX (L1B-M-5): stakerPool=0 redirects staker share to treasury
        vm.prank(owner);
        feeEngine.setRecipients(treasury, insurance, address(0));

        uint256 notional = 10_000e18;

        uint256 vaultBalBefore = vault.balance(aliceSub, address(usdc));

        vm.prank(matching);
        feeEngine.chargeTakerFee(aliceSub, notional);

        // feeTokens = 5e6. treasury = 3e6, insurance = 1e6, stakers = 1e6 → redirected to treasury.
        // All 5e6 deducted from vault (staker share goes to treasury)
        assertEq(
            vault.balance(aliceSub, address(usdc)),
            vaultBalBefore - 5e6,
            "All fee portions deducted, staker share redirected to treasury"
        );
        // Treasury gets 3e6 + 1e6 (staker redirect) = 4e6
        assertEq(usdc.balanceOf(treasury), 4e6, "Treasury got its share + staker redirect");
    }

    // ═══════════════════════════════════════════════════════
    // 5. processTradeFees — atomic taker fee + maker rebate
    //    (payMakerRebate deprecated — AUDIT FIX L1B-H-3)
    // ═══════════════════════════════════════════════════════

    function test_payMakerRebate_reverts_deprecated() public {
        vm.prank(matching);
        vm.expectRevert("FE: use processTradeFees()");
        feeEngine.payMakerRebate(bobSub, 10_000e18);
    }

    function test_processTradeFees_transfersRebateToMaker() public {
        // $10,000 notional → taker fee = 5 bps = $5 (5e18 WAD) = 5e6 tokens
        // maker rebate = 0.5 bps = $0.50 (5e17 WAD) = 5e5 tokens
        // remaining fee = 5e6 - 5e5 = 4_500_000 tokens → split to recipients
        uint256 notional = 10_000e18;

        uint256 aliceBalBefore = vault.balance(aliceSub, address(usdc));
        uint256 bobBalBefore = vault.balance(bobSub, address(usdc));

        vm.prank(matching);
        feeEngine.processTradeFees(aliceSub, bobSub, notional);

        uint256 rebateTokens = 500_000; // 0.5 USDC
        uint256 totalFeeTokens = 5e6;   // 5 USDC

        // Maker (bob) balance increased by rebate
        assertEq(
            vault.balance(bobSub, address(usdc)),
            bobBalBefore + rebateTokens,
            "Maker vault balance credited with rebate"
        );

        // Taker (alice) balance decreased by total fee (rebate + remaining split)
        assertEq(
            vault.balance(aliceSub, address(usdc)),
            aliceBalBefore - totalFeeTokens,
            "Taker vault balance debited by total fee"
        );
    }

    function test_processTradeFees_emitsEvents() public {
        uint256 notional = 10_000e18;

        vm.prank(matching);
        // Expect both MakerRebatePaid and TakerFeeCharged events
        vm.expectEmit(true, false, false, true);
        emit FeeEngine.MakerRebatePaid(bobSub, notional, 5e17);
        vm.expectEmit(true, false, false, true);
        emit FeeEngine.TakerFeeCharged(aliceSub, notional, 5e18);
        feeEngine.processTradeFees(aliceSub, bobSub, notional);
    }

    function test_processTradeFees_zeroNotional() public {
        uint256 aliceBalBefore = vault.balance(aliceSub, address(usdc));
        uint256 bobBalBefore = vault.balance(bobSub, address(usdc));

        vm.prank(matching);
        feeEngine.processTradeFees(aliceSub, bobSub, 0);

        assertEq(vault.balance(aliceSub, address(usdc)), aliceBalBefore, "No taker change");
        assertEq(vault.balance(bobSub, address(usdc)), bobBalBefore, "No maker change");
    }

    function test_processTradeFees_reverts_notAuthorised() public {
        vm.prank(alice);
        vm.expectRevert("FE: not authorised");
        feeEngine.processTradeFees(aliceSub, bobSub, 10_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 6. setRecipients — only owner
    // ═══════════════════════════════════════════════════════

    function test_setRecipients_updatesAll() public {
        address newT = address(0x7777);
        address newI = address(0x8888);
        address newS = address(0x9999);

        vm.prank(owner);
        feeEngine.setRecipients(newT, newI, newS);

        assertEq(feeEngine.treasury(), newT);
        assertEq(feeEngine.insuranceFund(), newI);
        assertEq(feeEngine.stakerPool(), newS);
    }

    function test_setRecipients_reverts_zeroTreasury() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero recipient");
        feeEngine.setRecipients(address(0), insurance, stakers);
    }

    function test_setRecipients_reverts_zeroInsurance() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero recipient");
        feeEngine.setRecipients(treasury, address(0), stakers);
    }

    function test_setRecipients_allowsZeroStakerPool() public {
        // The contract only checks treasury and insurance, not stakerPool
        vm.prank(owner);
        feeEngine.setRecipients(treasury, insurance, address(0));
        assertEq(feeEngine.stakerPool(), address(0));
    }

    function test_setRecipients_reverts_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        feeEngine.setRecipients(treasury, insurance, stakers);
    }

    // ═══════════════════════════════════════════════════════
    // 7. setFeeSplit — must sum to WAD
    // ═══════════════════════════════════════════════════════

    function test_setFeeSplit_updates() public {
        vm.prank(owner);
        feeEngine.setFeeSplit(0.50e18, 0.30e18, 0.20e18);

        assertEq(feeEngine.treasuryShare(), 0.50e18);
        assertEq(feeEngine.insuranceShare(), 0.30e18);
        assertEq(feeEngine.stakerShare(), 0.20e18);
    }

    function test_setFeeSplit_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit FeeEngine.FeeSplitUpdated(0.50e18, 0.30e18, 0.20e18);
        feeEngine.setFeeSplit(0.50e18, 0.30e18, 0.20e18);
    }

    function test_setFeeSplit_reverts_notSumToWAD() public {
        vm.prank(owner);
        vm.expectRevert("FE: split != 100%");
        feeEngine.setFeeSplit(0.50e18, 0.30e18, 0.10e18); // sums to 0.90e18
    }

    function test_setFeeSplit_reverts_overflow() public {
        vm.prank(owner);
        vm.expectRevert("FE: split != 100%");
        feeEngine.setFeeSplit(WAD, 1, 0); // sums to WAD + 1
    }

    function test_setFeeSplit_allToTreasury() public {
        vm.prank(owner);
        feeEngine.setFeeSplit(WAD, 0, 0);

        assertEq(feeEngine.treasuryShare(), WAD);
        assertEq(feeEngine.insuranceShare(), 0);
        assertEq(feeEngine.stakerShare(), 0);
    }

    function test_setFeeSplit_reverts_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        feeEngine.setFeeSplit(0.60e18, 0.20e18, 0.20e18);
    }

    function test_setFeeSplit_appliedToCharge() public {
        // Change split to 100% treasury
        vm.prank(owner);
        feeEngine.setFeeSplit(WAD, 0, 0);

        // $10,000 notional → $5 fee → 5e6 tokens, all to treasury
        uint256 notional = 10_000e18;

        vm.prank(matching);
        feeEngine.chargeTakerFee(aliceSub, notional);

        assertEq(usdc.balanceOf(treasury), 5e6, "All fee to treasury");
        assertEq(usdc.balanceOf(insurance), 0, "Nothing to insurance");
        assertEq(usdc.balanceOf(stakers), 0, "Nothing to stakers");
    }

    // ═══════════════════════════════════════════════════════
    // 8. setAuthorised — only owner, zero address reverts
    // ═══════════════════════════════════════════════════════

    function test_setAuthorised_grants() public {
        address newCaller = address(0xBEEF);

        vm.prank(owner);
        feeEngine.setAuthorised(newCaller, true);

        assertTrue(feeEngine.authorised(newCaller));
    }

    function test_setAuthorised_revokes() public {
        vm.prank(owner);
        feeEngine.setAuthorised(matching, false);

        assertFalse(feeEngine.authorised(matching));

        // Confirm it's actually revoked
        vm.prank(matching);
        vm.expectRevert("FE: not authorised");
        feeEngine.chargeTakerFee(aliceSub, 10_000e18);
    }

    function test_setAuthorised_reverts_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("FE: zero address");
        feeEngine.setAuthorised(address(0), true);
    }

    function test_setAuthorised_reverts_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        feeEngine.setAuthorised(address(0xBEEF), true);
    }

    // ═══════════════════════════════════════════════════════
    // 9. setTier — updates tier correctly
    // ═══════════════════════════════════════════════════════

    function test_setTier_updatesTier0() public {
        vm.prank(owner);
        feeEngine.setTier(0, 0, 10 * BPS, 2 * BPS);

        IFeeEngine.FeeTier memory t = feeEngine.getTier(0);
        assertEq(t.minBRKX, 0);
        assertEq(t.takerFeeBps, 10 * BPS, "Taker updated to 10 bps");
        assertEq(t.makerFeeBps, 2 * BPS, "Maker updated to 2 bps");
    }

    function test_setTier_affectsComputation() public {
        // Update base tier to 10 bps taker
        vm.prank(owner);
        feeEngine.setTier(0, 0, 10 * BPS, 1 * BPS);

        // $10,000 notional at 10 bps = $10 fee
        uint256 fee = feeEngine.computeTakerFee(aliceSub, 10_000e18);
        assertEq(fee, 10e18, "10 bps of $10k = $10 in WAD");
    }

    function test_setTier_reverts_invalidIndex() public {
        vm.prank(owner);
        vm.expectRevert("FE: invalid tier");
        feeEngine.setTier(4, 0, 5 * BPS, BPS / 2); // only indices 0-3 valid
    }

    function test_setTier_reverts_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        feeEngine.setTier(0, 0, 10 * BPS, BPS);
    }

    // ═══════════════════════════════════════════════════════
    // 10. setBRKXToken — only owner
    // ═══════════════════════════════════════════════════════

    function test_setBRKXToken_setsAddress() public {
        address brkx = address(0xBB);

        vm.prank(owner);
        feeEngine.setBRKXToken(brkx);

        assertEq(feeEngine.brkxToken(), brkx);
    }

    function test_setBRKXToken_canSetToZero() public {
        vm.prank(owner);
        feeEngine.setBRKXToken(address(0xBB));

        vm.prank(owner);
        feeEngine.setBRKXToken(address(0));

        assertEq(feeEngine.brkxToken(), address(0), "Can disable BRKX tiers");
    }

    function test_setBRKXToken_reverts_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        feeEngine.setBRKXToken(address(0xBB));
    }

    // ═══════════════════════════════════════════════════════
    // 11. Zero notional → zero fee (already partially tested above)
    // ═══════════════════════════════════════════════════════

    function test_zeroNotional_computeTakerFee() public view {
        assertEq(feeEngine.computeTakerFee(aliceSub, 0), 0);
    }

    function test_zeroNotional_computeMakerRebate() public view {
        assertEq(feeEngine.computeMakerRebate(aliceSub, 0), 0);
    }

    function test_zeroNotional_chargeTakerFee_noStateChange() public {
        uint256 balBefore = vault.balance(aliceSub, address(usdc));

        vm.prank(matching);
        uint256 fee = feeEngine.chargeTakerFee(aliceSub, 0);

        assertEq(fee, 0);
        assertEq(vault.balance(aliceSub, address(usdc)), balBefore, "No balance change");
    }

    function test_zeroNotional_processTradeFees_noStateChange() public {
        uint256 aliceBalBefore = vault.balance(aliceSub, address(usdc));
        uint256 bobBalBefore = vault.balance(bobSub, address(usdc));

        vm.prank(matching);
        feeEngine.processTradeFees(aliceSub, bobSub, 0);

        assertEq(vault.balance(aliceSub, address(usdc)), aliceBalBefore, "No taker change");
        assertEq(vault.balance(bobSub, address(usdc)), bobBalBefore, "No maker change");
    }

    // ═══════════════════════════════════════════════════════
    // 12. Fee computation with USDC (6 decimals) — collateralScale
    // ═══════════════════════════════════════════════════════

    function test_collateralScale_USDC_is_1e12() public view {
        assertEq(feeEngine.collateralScale(), 1e12, "USDC 6 decimals => scale 1e12");
    }

    function test_feeConversion_WAD_to_6dec() public {
        // Verify the full flow: WAD-scale fee -> 6-decimal token transfer
        // $20,000 notional → 5 bps = $10 fee in WAD = 10e18
        // Token: 10e18 / 1e12 = 10e6 USDC
        uint256 notional = 20_000e18;

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 insuranceBefore = usdc.balanceOf(insurance);
        uint256 stakersBefore = usdc.balanceOf(stakers);

        vm.prank(matching);
        uint256 fee = feeEngine.chargeTakerFee(aliceSub, notional);

        assertEq(fee, 10e18, "Fee in WAD");

        uint256 feeTokens = 10e6; // 10 USDC
        uint256 toTreasury = feeTokens * 60 / 100;  // 6e6
        uint256 toInsurance = feeTokens * 20 / 100;  // 2e6
        uint256 toStakers = feeTokens - toTreasury - toInsurance; // 2e6

        assertEq(usdc.balanceOf(treasury) - treasuryBefore, toTreasury, "6 USDC to treasury");
        assertEq(usdc.balanceOf(insurance) - insuranceBefore, toInsurance, "2 USDC to insurance");
        assertEq(usdc.balanceOf(stakers) - stakersBefore, toStakers, "2 USDC to stakers");
    }

    function test_collateralScale_8decimals() public {
        // WBTC has 8 decimals → scale = 10^(18-8) = 1e10
        MockERC20 wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        vm.prank(owner);
        FeeEngine fe8 = new FeeEngine(owner, address(vault), address(wbtc), address(sam));

        assertEq(fe8.collateralScale(), 1e10, "WBTC 8 decimals => scale 1e10");
    }

    // ═══════════════════════════════════════════════════════
    // Edge cases
    // ═══════════════════════════════════════════════════════

    function test_chargeTakerFee_tinyNotional_belowTokenPrecision() public {
        // Very small notional where fee in token terms rounds to 0
        // fee = notional * 5e14 / 1e18
        // For feeTokens = fee / 1e12 to be 0, we need fee < 1e12
        // fee < 1e12 => notional * 5e14 / 1e18 < 1e12
        // notional < 1e12 * 1e18 / 5e14 = 1e30 / 5e14 = 2e15
        // So notional = 1e15 ($0.001 in WAD)
        // fee = 1e15 * 5e14 / 1e18 = 5e11
        // feeTokens = 5e11 / 1e12 = 0 → early return
        uint256 notional = 1e15;

        uint256 balBefore = vault.balance(aliceSub, address(usdc));

        vm.prank(matching);
        uint256 fee = feeEngine.chargeTakerFee(aliceSub, notional);

        // fee > 0 in WAD but feeTokens = 0, so function returns 0
        // Actually, the function returns `fee` (WAD), but checks feeTokens:
        // Looking at code: fee = notional * tier.takerFeeBps / WAD = 5e11
        // fee != 0, so it doesn't return 0 at line 151
        // feeTokens = 5e11 / 1e12 = 0, so it returns 0 at line 155
        assertEq(fee, 0, "Fee rounds to zero when below token precision");
        assertEq(vault.balance(aliceSub, address(usdc)), balBefore, "No balance change");
    }

    function test_chargeTakerFee_insufficientBalance_capsAtAvailable() public {
        // AUDIT FIX (L0-M-2): Vault.chargeFee caps at available balance instead of reverting
        vm.prank(alice);
        bytes32 poorSub = sam.createSubaccount(1);
        _fundSubaccount(poorSub, 1e6); // 1 USDC

        // $1,000,000 notional → $500 fee → 500e6 tokens needed
        // Subaccount only has 1e6 → each split call caps at available balance
        // Treasury call (first) caps at 1e6, insurance and stakers get 0
        vm.prank(matching);
        feeEngine.chargeTakerFee(poorSub, 1_000_000e18);

        // Balance fully drained by first split (treasury)
        assertEq(vault.balance(poorSub, address(usdc)), 0, "Balance drained to zero");
        // Treasury got the full 1e6 (capped from the requested 300e6)
        assertEq(usdc.balanceOf(treasury), 1e6, "Treasury got all available");
    }

    function test_multipleCharges_accumulate() public {
        uint256 balBefore = vault.balance(aliceSub, address(usdc));

        // Charge twice
        vm.startPrank(matching);
        feeEngine.chargeTakerFee(aliceSub, 10_000e18); // $5 fee
        feeEngine.chargeTakerFee(aliceSub, 20_000e18); // $10 fee
        vm.stopPrank();

        // Total: $15 = 15e6 tokens deducted
        assertEq(
            vault.balance(aliceSub, address(usdc)),
            balBefore - 15e6,
            "Two charges deducted correctly"
        );

        // Treasury got 60% of each: 3e6 + 6e6 = 9e6
        assertEq(usdc.balanceOf(treasury), 9e6, "Treasury accumulated");
    }

    // ═══════════════════════════════════════════════════════
    // getTierCount / getTier views
    // ═══════════════════════════════════════════════════════

    function test_getTierCount() public view {
        assertEq(feeEngine.getTierCount(), 4);
    }

    function test_getTier_outOfBounds_reverts() public {
        vm.expectRevert(); // array out of bounds
        feeEngine.getTier(99);
    }

    // ═══════════════════════════════════════════════════════
    // Default fee split values
    // ═══════════════════════════════════════════════════════

    function test_defaultFeeSplit() public view {
        assertEq(feeEngine.treasuryShare(), 0.60e18, "Default 60% treasury");
        assertEq(feeEngine.insuranceShare(), 0.20e18, "Default 20% insurance");
        assertEq(feeEngine.stakerShare(), 0.20e18, "Default 20% stakers");
    }

    // ═══════════════════════════════════════════════════════
    // Ownership (Ownable2Step)
    // ═══════════════════════════════════════════════════════

    function test_owner_isInitialOwner() public view {
        assertEq(feeEngine.owner(), owner);
    }

    function test_ownership_twoStep() public {
        address newOwner = address(0xDEAD);

        vm.prank(owner);
        feeEngine.transferOwnership(newOwner);

        // Pending owner, not yet active
        assertEq(feeEngine.owner(), owner, "Still old owner");

        vm.prank(newOwner);
        feeEngine.acceptOwnership();

        assertEq(feeEngine.owner(), newOwner, "New owner accepted");
    }
}
