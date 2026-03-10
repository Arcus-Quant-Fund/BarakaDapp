// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "../../src/core/SubaccountManager.sol";
import "../mocks/MockERC20.sol";

/**
 * @title VaultTest
 * @notice Unit tests for Vault: deposit, withdraw, internal transfer, settlePnL,
 *         chargeFee, access control, guardian, pause, ETH rejection.
 */
contract VaultTest is Test {

    Vault             vault;
    SubaccountManager sam;
    MockERC20         usdc;

    address owner    = address(0xABCD);
    address alice    = address(0x1111);
    address bob      = address(0x2222);
    address guardian = address(0x7777);
    address treasury = address(0x8888);

    bytes32 aliceSub;
    bytes32 bobSub;

    function setUp() public {
        vm.startPrank(owner);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new Vault(owner);
        vault.setApprovedToken(address(usdc), true);
        vault.setAuthorised(owner, true);
        vm.stopPrank();

        sam = new SubaccountManager();

        vm.prank(alice);
        aliceSub = sam.createSubaccount(0);
        vm.prank(bob);
        bobSub = sam.createSubaccount(0);
    }

    function _deposit(bytes32 sub, uint256 amount) internal {
        usdc.mint(owner, amount);
        vm.startPrank(owner);
        usdc.approve(address(vault), amount);
        vault.deposit(sub, address(usdc), amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 1. Deposit
    // ═══════════════════════════════════════════════════════

    function test_deposit_basic() public {
        _deposit(aliceSub, 1000e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 1000e6);
    }

    function test_deposit_multipleDeposits() public {
        _deposit(aliceSub, 500e6);
        _deposit(aliceSub, 300e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 800e6);
    }

    function test_deposit_emitsEvent() public {
        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), 100e6);
        vm.expectEmit(true, true, true, true);
        emit Vault.Deposited(aliceSub, address(usdc), 100e6);
        vault.deposit(aliceSub, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_deposit_revert_notAuthorised() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert("Vault: not authorised");
        vault.deposit(aliceSub, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_deposit_revert_tokenNotApproved() public {
        MockERC20 badToken = new MockERC20("Bad", "BAD", 18);
        badToken.mint(owner, 100e18);
        vm.startPrank(owner);
        badToken.approve(address(vault), 100e18);
        vm.expectRevert("Vault: token not approved");
        vault.deposit(aliceSub, address(badToken), 100e18);
        vm.stopPrank();
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("Vault: zero amount");
        vault.deposit(aliceSub, address(usdc), 0);
    }

    function test_deposit_revert_insufficientAllowance() public {
        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        // no approve
        vm.expectRevert("Vault: insufficient allowance");
        vault.deposit(aliceSub, address(usdc), 100e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 2. Withdraw
    // ═══════════════════════════════════════════════════════

    function test_withdraw_basic() public {
        _deposit(aliceSub, 1000e6);
        vm.prank(owner);
        vault.withdraw(aliceSub, address(usdc), 400e6, alice);
        assertEq(vault.balance(aliceSub, address(usdc)), 600e6);
        assertEq(usdc.balanceOf(alice), 400e6);
    }

    function test_withdraw_emitsEvent() public {
        _deposit(aliceSub, 1000e6);
        vm.expectEmit(true, true, true, true);
        emit Vault.Withdrawn(aliceSub, address(usdc), 400e6, alice);
        vm.prank(owner);
        vault.withdraw(aliceSub, address(usdc), 400e6, alice);
    }

    function test_withdraw_revert_insufficientBalance() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vm.expectRevert("Vault: insufficient balance");
        vault.withdraw(aliceSub, address(usdc), 200e6, alice);
    }

    function test_withdraw_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert("Vault: zero amount");
        vault.withdraw(aliceSub, address(usdc), 0, alice);
    }

    function test_withdraw_revert_zeroRecipient() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vm.expectRevert("Vault: zero recipient");
        vault.withdraw(aliceSub, address(usdc), 50e6, address(0));
    }

    // ═══════════════════════════════════════════════════════
    // 3. Internal transfer
    // ═══════════════════════════════════════════════════════

    function test_transferInternal_basic() public {
        _deposit(aliceSub, 1000e6);
        vm.prank(owner);
        vault.transferInternal(aliceSub, bobSub, address(usdc), 300e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 700e6);
        assertEq(vault.balance(bobSub, address(usdc)), 300e6);
    }

    function test_transferInternal_emitsEvent() public {
        _deposit(aliceSub, 1000e6);
        vm.expectEmit(true, true, true, true);
        emit Vault.InternalTransfer(aliceSub, bobSub, address(usdc), 300e6);
        vm.prank(owner);
        vault.transferInternal(aliceSub, bobSub, address(usdc), 300e6);
    }

    function test_transferInternal_revert_insufficientBalance() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vm.expectRevert("Vault: insufficient balance");
        vault.transferInternal(aliceSub, bobSub, address(usdc), 200e6);
    }

    // ═══════════════════════════════════════════════════════
    // 4. SettlePnL
    // ═══════════════════════════════════════════════════════

    function test_settlePnL_credit() public {
        _deposit(aliceSub, 1000e6);
        // P15-C-2: Credit requires backing tokens — simulate counterparty debit or IF coverage
        usdc.mint(address(vault), 500e6);
        vm.prank(owner);
        int256 settled = vault.settlePnL(aliceSub, address(usdc), 500e6);
        assertEq(settled, 500e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 1500e6);
    }

    function test_settlePnL_debit() public {
        _deposit(aliceSub, 1000e6);
        vm.prank(owner);
        int256 settled = vault.settlePnL(aliceSub, address(usdc), -400e6);
        assertEq(settled, -400e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 600e6);
    }

    function test_settlePnL_debitCapsAtBalance() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        int256 settled = vault.settlePnL(aliceSub, address(usdc), -500e6);
        // Capped at available balance
        assertEq(settled, -100e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 0);
    }

    function test_settlePnL_zero() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        int256 settled = vault.settlePnL(aliceSub, address(usdc), 0);
        assertEq(settled, 0);
        assertEq(vault.balance(aliceSub, address(usdc)), 100e6);
    }

    function test_settlePnL_worksWhenPaused() public {
        _deposit(aliceSub, 100e6);
        // P15-C-2: Credit requires backing tokens
        usdc.mint(address(vault), 50e6);
        vm.prank(owner);
        vault.pause();
        // settlePnL must work during pause (liquidation path)
        vm.prank(owner);
        int256 settled = vault.settlePnL(aliceSub, address(usdc), 50e6);
        assertEq(settled, 50e6);
    }

    // ═══════════════════════════════════════════════════════
    // 5. ChargeFee
    // ═══════════════════════════════════════════════════════

    function test_chargeFee_basic() public {
        _deposit(aliceSub, 1000e6);
        vm.prank(owner);
        uint256 charged = vault.chargeFee(aliceSub, address(usdc), 100e6, treasury);
        assertEq(charged, 100e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 900e6);
        assertEq(usdc.balanceOf(treasury), 100e6);
    }

    function test_chargeFee_capsAtBalance() public {
        _deposit(aliceSub, 50e6);
        vm.prank(owner);
        uint256 charged = vault.chargeFee(aliceSub, address(usdc), 100e6, treasury);
        assertEq(charged, 50e6);
        assertEq(vault.balance(aliceSub, address(usdc)), 0);
    }

    function test_chargeFee_worksWhenPaused() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vault.pause();
        vm.prank(owner);
        uint256 charged = vault.chargeFee(aliceSub, address(usdc), 50e6, treasury);
        assertEq(charged, 50e6);
    }

    function test_chargeFee_revert_zeroFee() public {
        vm.prank(owner);
        vm.expectRevert("Vault: zero fee");
        vault.chargeFee(aliceSub, address(usdc), 0, treasury);
    }

    function test_chargeFee_revert_zeroRecipient() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vm.expectRevert("Vault: zero recipient");
        vault.chargeFee(aliceSub, address(usdc), 50e6, address(0));
    }

    // ═══════════════════════════════════════════════════════
    // 6. Access control
    // ═══════════════════════════════════════════════════════

    function test_setAuthorised_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setAuthorised(alice, true);
    }

    function test_setAuthorised_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Vault: zero address");
        vault.setAuthorised(address(0), true);
    }

    function test_setApprovedToken_revert_zeroToken() public {
        vm.prank(owner);
        vm.expectRevert("Vault: zero token");
        vault.setApprovedToken(address(0), true);
    }

    // ═══════════════════════════════════════════════════════
    // 7. Guardian
    // ═══════════════════════════════════════════════════════

    function test_guardian_setAndRevoke() public {
        vm.prank(owner);
        vault.setGuardian(guardian);
        assertEq(vault.guardian(), guardian);

        // Guardian can revoke
        vm.prank(guardian);
        vault.emergencyRevokeAuthorised(owner);
        assertFalse(vault.authorised(owner));
    }

    function test_guardian_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("Vault: zero guardian");
        vault.setGuardian(address(0));
    }

    function test_guardian_revert_sameAsOwner() public {
        vm.prank(owner);
        vm.expectRevert("Vault: guardian must differ from owner");
        vault.setGuardian(owner);
    }

    function test_guardian_revert_notGuardian() public {
        vm.prank(owner);
        vault.setGuardian(guardian);

        vm.prank(alice);
        vm.expectRevert("Vault: not guardian");
        vault.emergencyRevokeAuthorised(owner);
    }

    // ═══════════════════════════════════════════════════════
    // 8. Pause
    // ═══════════════════════════════════════════════════════

    function test_pause_blocksDeposit() public {
        vm.prank(owner);
        vault.pause();

        usdc.mint(owner, 100e6);
        vm.startPrank(owner);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert();
        vault.deposit(aliceSub, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_pause_blocksWithdraw() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert();
        vault.withdraw(aliceSub, address(usdc), 50e6, alice);
    }

    function test_pause_blocksTransferInternal() public {
        _deposit(aliceSub, 100e6);
        vm.prank(owner);
        vault.pause();

        vm.prank(owner);
        vm.expectRevert();
        vault.transferInternal(aliceSub, bobSub, address(usdc), 50e6);
    }

    // ═══════════════════════════════════════════════════════
    // 9. ETH rejection
    // ═══════════════════════════════════════════════════════

    function test_rejectETH() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, ) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "ETH transfer should have been rejected");
    }

    // ═══════════════════════════════════════════════════════
    // 10. Renounce ownership disabled
    // ═══════════════════════════════════════════════════════

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert("Vault: renounce disabled");
        vault.renounceOwnership();
    }
}
