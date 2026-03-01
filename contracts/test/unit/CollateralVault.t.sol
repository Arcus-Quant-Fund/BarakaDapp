// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/CollateralVault.sol";
import "../../src/interfaces/IShariahGuard.sol";
import "../mocks/MockERC20.sol";

/// @notice Minimal ShariahGuard mock — approves/revokes tokens on demand
contract MockShariahGuardCV is IShariahGuard {
    mapping(address => bool) private _approved;

    function approveToken(address token) external { _approved[token] = true; }
    function revokeToken(address token)  external { _approved[token] = false; }

    function isApproved(address token) external view override returns (bool) {
        return _approved[token];
    }
    function validatePosition(address, uint256, uint256) external view override {}
    function MAX_LEVERAGE() external view override returns (uint256) { return 5; }
}

/**
 * @title CollateralVaultTest
 * @notice Full unit test coverage for CollateralVault.sol
 *
 * Branches covered:
 *   deposit()          — paused, unapproved token, zero amount, happy path + event
 *   withdraw()         — zero amount, insufficient balance, cooldown active,
 *                        emergency exit (paused bypass), after-cooldown success + event
 *   lockCollateral()   — not authorised, paused, insufficient free balance, success + event
 *   unlockCollateral() — not authorised, insufficient locked balance, success + event
 *   transferCollateral() — not authorised, insufficient locked balance, success + event
 *   chargeFromFree()   — not authorised, paused, insufficient balance, success
 *   setAuthorised()    — only owner, emits AuthorisedSet event
 *   Views              — balance(), freeBalance(), lockedBalance()
 *   Constructor        — zero ShariahGuard reverts
 *   Fuzz               — deposit/withdraw roundtrip; lock/unlock roundtrip
 */
contract CollateralVaultTest is Test {

    CollateralVault    public vault;
    MockShariahGuardCV public sg;
    MockERC20          public usdc;

    address public owner    = address(0xABCD);
    address public pm       = address(0xCAFE);  // authorised caller
    address public user     = address(0xBEEF);
    address public attacker = address(0xDEAD);

    uint256 constant DEPOSIT = 10_000e6;

    function setUp() public {
        vm.startPrank(owner);
        sg    = new MockShariahGuardCV();
        vault = new CollateralVault(owner, address(sg));
        usdc  = new MockERC20("USD Coin", "USDC", 6);

        sg.approveToken(address(usdc));
        vault.setAuthorised(pm, true);
        vm.stopPrank();

        // Seed user with USDC and deposit into vault
        usdc.mint(user, DEPOSIT);
        vm.startPrank(user);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(address(usdc), DEPOSIT);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    function test_constructor_zeroShariahGuardReverts() public {
        vm.expectRevert("CollateralVault: zero ShariahGuard");
        new CollateralVault(owner, address(0));
    }

    // ─────────────────────────────────────────────────────
    // setAuthorised()
    // ─────────────────────────────────────────────────────

    function test_setAuthorised_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setAuthorised(attacker, true);
    }

    function test_setAuthorised_setsAndRevokes() public {
        address newCaller = address(0x5555);
        assertFalse(vault.authorised(newCaller));

        vm.prank(owner);
        vault.setAuthorised(newCaller, true);
        assertTrue(vault.authorised(newCaller));

        vm.prank(owner);
        vault.setAuthorised(newCaller, false);
        assertFalse(vault.authorised(newCaller));
    }

    function test_setAuthorised_emitsEvent() public {
        address newCaller = address(0x5555);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit CollateralVault.AuthorisedSet(newCaller, true);
        vault.setAuthorised(newCaller, true);
    }

    // ─────────────────────────────────────────────────────
    // deposit()
    // ─────────────────────────────────────────────────────

    function test_deposit_pausedReverts() public {
        vm.prank(owner); vault.pause();

        usdc.mint(user, 100e6);
        vm.startPrank(user);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert();
        vault.deposit(address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_deposit_unapprovedTokenReverts() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(user, 1e18);
        vm.startPrank(user);
        other.approve(address(vault), 1e18);
        vm.expectRevert("CollateralVault: token not Shariah-approved");
        vault.deposit(address(other), 1e18);
        vm.stopPrank();
    }

    function test_deposit_zeroAmountReverts() public {
        vm.prank(user);
        vm.expectRevert("CollateralVault: zero amount");
        vault.deposit(address(usdc), 0);
    }

    function test_deposit_increasesBalance() public {
        uint256 extra = 500e6;
        usdc.mint(user, extra);
        vm.startPrank(user);
        usdc.approve(address(vault), extra);
        vault.deposit(address(usdc), extra);
        vm.stopPrank();

        assertEq(vault.freeBalance(user, address(usdc)), DEPOSIT + extra);
    }

    function test_deposit_emitsEvent() public {
        uint256 extra = 200e6;
        usdc.mint(user, extra);
        vm.startPrank(user);
        usdc.approve(address(vault), extra);
        vm.expectEmit(true, true, false, true);
        emit CollateralVault.Deposited(user, address(usdc), extra);
        vault.deposit(address(usdc), extra);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // withdraw()
    // ─────────────────────────────────────────────────────

    function test_withdraw_zeroAmountReverts() public {
        vm.warp(block.timestamp + 25 hours);
        vm.prank(user);
        vm.expectRevert("CollateralVault: zero amount");
        vault.withdraw(address(usdc), 0);
    }

    function test_withdraw_insufficientFreeBalanceReverts() public {
        vm.warp(block.timestamp + 25 hours);
        vm.prank(user);
        vm.expectRevert("CollateralVault: insufficient free balance");
        vault.withdraw(address(usdc), DEPOSIT + 1);
    }

    function test_withdraw_cooldownActiveReverts() public {
        // Cooldown is 24h — try immediately after setUp deposit
        vm.prank(user);
        vm.expectRevert("CollateralVault: withdrawal cooldown active");
        vault.withdraw(address(usdc), 100e6);
    }

    function test_withdraw_afterCooldownSucceeds() public {
        vm.warp(block.timestamp + 24 hours + 1);
        uint256 amount = 1_000e6;
        vm.prank(user);
        vault.withdraw(address(usdc), amount);

        assertEq(vault.freeBalance(user, address(usdc)), DEPOSIT - amount);
        assertEq(usdc.balanceOf(user), amount);
    }

    function test_withdraw_emergencyExitBypassesCooldown() public {
        // Paused → cooldown not enforced (emergency exit)
        vm.prank(owner); vault.pause();

        uint256 amount = 500e6;
        vm.prank(user);
        vault.withdraw(address(usdc), amount);
        assertEq(vault.freeBalance(user, address(usdc)), DEPOSIT - amount);
    }

    function test_withdraw_emitsEvent() public {
        vm.warp(block.timestamp + 25 hours);
        uint256 amount = 300e6;
        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit CollateralVault.Withdrawn(user, address(usdc), amount);
        vault.withdraw(address(usdc), amount);
    }

    // ─────────────────────────────────────────────────────
    // lockCollateral()
    // ─────────────────────────────────────────────────────

    function test_lockCollateral_notAuthorisedReverts() public {
        vm.prank(attacker);
        vm.expectRevert("CollateralVault: not authorised");
        vault.lockCollateral(user, address(usdc), 100e6);
    }

    function test_lockCollateral_pausedReverts() public {
        vm.prank(owner); vault.pause();
        vm.prank(pm);
        vm.expectRevert();
        vault.lockCollateral(user, address(usdc), 100e6);
    }

    function test_lockCollateral_insufficientFreeBalanceReverts() public {
        vm.prank(pm);
        vm.expectRevert("CollateralVault: insufficient free balance");
        vault.lockCollateral(user, address(usdc), DEPOSIT + 1);
    }

    function test_lockCollateral_movesBalances() public {
        uint256 amount = 3_000e6;
        vm.prank(pm);
        vault.lockCollateral(user, address(usdc), amount);

        assertEq(vault.freeBalance(user,   address(usdc)), DEPOSIT - amount);
        assertEq(vault.lockedBalance(user, address(usdc)), amount);
    }

    function test_lockCollateral_emitsEvent() public {
        vm.prank(pm);
        vm.expectEmit(true, true, false, true);
        emit CollateralVault.CollateralLocked(user, address(usdc), 500e6);
        vault.lockCollateral(user, address(usdc), 500e6);
    }

    // ─────────────────────────────────────────────────────
    // unlockCollateral()
    // ─────────────────────────────────────────────────────

    function test_unlockCollateral_notAuthorisedReverts() public {
        vm.prank(attacker);
        vm.expectRevert("CollateralVault: not authorised");
        vault.unlockCollateral(user, address(usdc), 100e6);
    }

    function test_unlockCollateral_insufficientLockedReverts() public {
        vm.prank(pm);
        vm.expectRevert("CollateralVault: insufficient locked balance");
        vault.unlockCollateral(user, address(usdc), 1); // nothing locked
    }

    function test_unlockCollateral_movesBalancesBack() public {
        uint256 lock = 2_000e6;
        vm.prank(pm); vault.lockCollateral(user, address(usdc), lock);
        vm.prank(pm); vault.unlockCollateral(user, address(usdc), lock);

        assertEq(vault.freeBalance(user,   address(usdc)), DEPOSIT);
        assertEq(vault.lockedBalance(user, address(usdc)), 0);
    }

    function test_unlockCollateral_emitsEvent() public {
        uint256 lock = 1_000e6;
        vm.prank(pm); vault.lockCollateral(user, address(usdc), lock);
        vm.prank(pm);
        vm.expectEmit(true, true, false, true);
        emit CollateralVault.CollateralUnlocked(user, address(usdc), lock);
        vault.unlockCollateral(user, address(usdc), lock);
    }

    // ─────────────────────────────────────────────────────
    // transferCollateral()
    // ─────────────────────────────────────────────────────

    function test_transferCollateral_notAuthorisedReverts() public {
        vm.prank(attacker);
        vm.expectRevert("CollateralVault: not authorised");
        vault.transferCollateral(user, attacker, address(usdc), 100e6);
    }

    function test_transferCollateral_insufficientLockedReverts() public {
        // Nothing locked yet
        vm.prank(pm);
        vm.expectRevert("CollateralVault: insufficient locked balance");
        vault.transferCollateral(user, address(0x9999), address(usdc), 1);
    }

    function test_transferCollateral_movesBalances() public {
        address recipient = address(0x9999);
        uint256 lock = 2_000e6;
        vm.prank(pm); vault.lockCollateral(user, address(usdc), lock);
        vm.prank(pm); vault.transferCollateral(user, recipient, address(usdc), lock);

        assertEq(vault.lockedBalance(user,     address(usdc)), 0);
        assertEq(vault.freeBalance(recipient,  address(usdc)), lock);
    }

    function test_transferCollateral_emitsEvent() public {
        address recipient = address(0x9999);
        uint256 lock = 500e6;
        vm.prank(pm); vault.lockCollateral(user, address(usdc), lock);
        vm.prank(pm);
        vm.expectEmit(true, true, true, true);
        emit CollateralVault.CollateralTransferred(user, recipient, address(usdc), lock);
        vault.transferCollateral(user, recipient, address(usdc), lock);
    }

    // ─────────────────────────────────────────────────────
    // chargeFromFree()
    // ─────────────────────────────────────────────────────

    function test_chargeFromFree_notAuthorisedReverts() public {
        vm.prank(attacker);
        vm.expectRevert("CollateralVault: not authorised");
        vault.chargeFromFree(user, address(usdc), 100e6);
    }

    function test_chargeFromFree_pausedReverts() public {
        vm.prank(owner); vault.pause();
        vm.prank(pm);
        vm.expectRevert();
        vault.chargeFromFree(user, address(usdc), 100e6);
    }

    function test_chargeFromFree_insufficientFreeReverts() public {
        vm.prank(pm);
        vm.expectRevert("CollateralVault: insufficient free balance");
        vault.chargeFromFree(user, address(usdc), DEPOSIT + 1);
    }

    function test_chargeFromFree_deductsBalanceAndSendsTokensToCaller() public {
        uint256 fee      = 50e6;
        uint256 pmBefore = usdc.balanceOf(pm);
        vm.prank(pm);
        vault.chargeFromFree(user, address(usdc), fee);

        assertEq(vault.freeBalance(user, address(usdc)), DEPOSIT - fee);
        assertEq(usdc.balanceOf(pm), pmBefore + fee);
    }

    // ─────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────

    function test_balance_sumsFreeAndLocked() public {
        uint256 lock = 2_000e6;
        vm.prank(pm); vault.lockCollateral(user, address(usdc), lock);

        // balance() = free + locked = DEPOSIT always
        assertEq(vault.balance(user, address(usdc)), DEPOSIT);
    }

    function test_freeBalance_initiallyDeposit() public view {
        assertEq(vault.freeBalance(user, address(usdc)), DEPOSIT);
    }

    function test_lockedBalance_zeroInitially() public view {
        assertEq(vault.lockedBalance(user, address(usdc)), 0);
    }

    function test_unknownUserAndTokenReturnsZero() public view {
        assertEq(vault.balance(attacker, address(usdc)), 0);
        assertEq(vault.freeBalance(attacker, address(usdc)), 0);
        assertEq(vault.lockedBalance(attacker, address(usdc)), 0);
    }

    // ─────────────────────────────────────────────────────
    // pause / unpause
    // ─────────────────────────────────────────────────────

    function test_pause_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
    }

    function test_unpause_restoresDeposit() public {
        vm.prank(owner); vault.pause();
        vm.prank(owner); vault.unpause();

        uint256 extra = 100e6;
        usdc.mint(user, extra);
        vm.startPrank(user);
        usdc.approve(address(vault), extra);
        vault.deposit(address(usdc), extra);
        vm.stopPrank();

        assertEq(vault.freeBalance(user, address(usdc)), DEPOSIT + extra);
    }

    // ─────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────

    function testFuzz_depositWithdrawRoundtrip(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e6);

        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount);
        vm.stopPrank();

        uint256 freeBefore = vault.freeBalance(user, address(usdc));

        vm.warp(block.timestamp + 25 hours);
        vm.prank(user);
        vault.withdraw(address(usdc), amount);

        assertEq(vault.freeBalance(user, address(usdc)), freeBefore - amount);
    }

    function testFuzz_lockUnlockRoundtrip(uint256 lockAmt) public {
        lockAmt = bound(lockAmt, 1, DEPOSIT);
        vm.prank(pm); vault.lockCollateral(user, address(usdc), lockAmt);
        vm.prank(pm); vault.unlockCollateral(user, address(usdc), lockAmt);

        assertEq(vault.freeBalance(user,   address(usdc)), DEPOSIT);
        assertEq(vault.lockedBalance(user, address(usdc)), 0);
    }

    function testFuzz_transferNeverExceedsLocked(uint256 lockAmt, uint256 transferAmt) public {
        lockAmt     = bound(lockAmt,     1, DEPOSIT);
        transferAmt = bound(transferAmt, 1, DEPOSIT);
        address recipient = address(0x7777);

        vm.prank(pm); vault.lockCollateral(user, address(usdc), lockAmt);

        if (transferAmt > lockAmt) {
            vm.prank(pm);
            vm.expectRevert("CollateralVault: insufficient locked balance");
            vault.transferCollateral(user, recipient, address(usdc), transferAmt);
        } else {
            vm.prank(pm);
            vault.transferCollateral(user, recipient, address(usdc), transferAmt);
            assertEq(vault.lockedBalance(user, address(usdc)), lockAmt - transferAmt);
            assertEq(vault.freeBalance(recipient, address(usdc)), transferAmt);
        }
    }
}
