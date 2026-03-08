// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/SubaccountManager.sol";

/**
 * @title SubaccountManagerTest
 * @notice Unit tests for SubaccountManager: creation, closure, re-creation,
 *         deterministic IDs, multi-user isolation, and edge cases.
 */
contract SubaccountManagerTest is Test {

    SubaccountManager sam;

    address alice   = address(0x1111);
    address bob     = address(0x2222);

    function setUp() public {
        sam = new SubaccountManager();
    }

    // ═══════════════════════════════════════════════════════
    // 1. Creation basics
    // ═══════════════════════════════════════════════════════

    function test_createSubaccount_index0() public {
        vm.prank(alice);
        bytes32 id = sam.createSubaccount(0);
        assertEq(sam.getOwner(id), alice);
        assertTrue(sam.exists(id));
        assertEq(sam.subaccountCount(alice), 1);
    }

    function test_createSubaccount_deterministicId() public {
        bytes32 expected = sam.getSubaccountId(alice, 0);
        vm.prank(alice);
        bytes32 actual = sam.createSubaccount(0);
        assertEq(actual, expected);
    }

    function test_createSubaccount_multipleIndexes() public {
        vm.startPrank(alice);
        bytes32 id0 = sam.createSubaccount(0);
        bytes32 id1 = sam.createSubaccount(1);
        bytes32 id255 = sam.createSubaccount(255);
        vm.stopPrank();

        assertTrue(id0 != id1);
        assertTrue(id1 != id255);
        assertEq(sam.subaccountCount(alice), 3);
    }

    function test_createSubaccount_revert_alreadyExists() public {
        vm.prank(alice);
        sam.createSubaccount(0);

        vm.expectRevert("SAM: already exists");
        vm.prank(alice);
        sam.createSubaccount(0);
    }

    function test_createSubaccount_differentUsers_sameIndex() public {
        vm.prank(alice);
        bytes32 aliceId = sam.createSubaccount(0);

        vm.prank(bob);
        bytes32 bobId = sam.createSubaccount(0);

        assertTrue(aliceId != bobId);
        assertEq(sam.getOwner(aliceId), alice);
        assertEq(sam.getOwner(bobId), bob);
    }

    function test_createSubaccount_emitsEvent() public {
        bytes32 expectedId = sam.getSubaccountId(alice, 5);

        vm.expectEmit(true, true, true, true);
        emit SubaccountManager.SubaccountCreated(alice, 5, expectedId);

        vm.prank(alice);
        sam.createSubaccount(5);
    }

    // ═══════════════════════════════════════════════════════
    // 2. Closure
    // ═══════════════════════════════════════════════════════

    function test_closeSubaccount_basic() public {
        vm.prank(alice);
        bytes32 id = sam.createSubaccount(0);

        vm.prank(alice);
        sam.closeSubaccount(0);

        assertFalse(sam.exists(id));
        assertEq(sam.subaccountCount(alice), 0);
        // Owner mapping preserved after close
        assertEq(sam.getOwner(id), alice);
    }

    function test_closeSubaccount_revert_notExists() public {
        vm.expectRevert("SAM: not exists");
        vm.prank(alice);
        sam.closeSubaccount(0);
    }

    function test_closeSubaccount_revert_notOwner_unreachable() public {
        // Note: closeSubaccount uses getSubaccountId(msg.sender, index),
        // so bob calling closeSubaccount(0) looks up keccak256(bob, 0)
        // which doesn't exist. The "not owner" check is a safety guard
        // that's unreachable in normal flow. We verify bob gets "not exists".
        vm.prank(alice);
        sam.createSubaccount(0);

        vm.expectRevert("SAM: not exists");
        vm.prank(bob);
        sam.closeSubaccount(0);
    }

    function test_closeSubaccount_emitsEvent() public {
        vm.prank(alice);
        bytes32 id = sam.createSubaccount(3);

        vm.expectEmit(true, true, true, true);
        emit SubaccountManager.SubaccountClosed(alice, 3, id);

        vm.prank(alice);
        sam.closeSubaccount(3);
    }

    // ═══════════════════════════════════════════════════════
    // 3. Re-creation after close
    // ═══════════════════════════════════════════════════════

    function test_reCreateAfterClose() public {
        vm.startPrank(alice);
        bytes32 id1 = sam.createSubaccount(0);
        sam.closeSubaccount(0);

        bytes32 id2 = sam.createSubaccount(0);
        vm.stopPrank();

        // Same deterministic ID
        assertEq(id1, id2);
        assertTrue(sam.exists(id2));
        assertEq(sam.subaccountCount(alice), 1);
    }

    // ═══════════════════════════════════════════════════════
    // 4. View functions — non-existent subaccount
    // ═══════════════════════════════════════════════════════

    function test_getOwner_nonExistent_returnsZero() public view {
        bytes32 fakeId = keccak256("nonexistent");
        assertEq(sam.getOwner(fakeId), address(0));
    }

    function test_exists_nonExistent_returnsFalse() public view {
        bytes32 fakeId = keccak256("nonexistent");
        assertFalse(sam.exists(fakeId));
    }

    function test_subaccountCount_noSubaccounts() public view {
        assertEq(sam.subaccountCount(alice), 0);
    }

    // ═══════════════════════════════════════════════════════
    // 5. getSubaccountId is pure and consistent
    // ═══════════════════════════════════════════════════════

    function test_getSubaccountId_pureConsistency() public view {
        bytes32 a = sam.getSubaccountId(alice, 0);
        bytes32 b = sam.getSubaccountId(alice, 0);
        assertEq(a, b);
    }

    function test_getSubaccountId_matchesEncodePacked() public view {
        bytes32 expected = keccak256(abi.encodePacked(alice, uint8(42)));
        assertEq(sam.getSubaccountId(alice, 42), expected);
    }

    // ═══════════════════════════════════════════════════════
    // 6. Multi-subaccount count tracking
    // ═══════════════════════════════════════════════════════

    function test_countTracking_createAndClose() public {
        vm.startPrank(alice);
        sam.createSubaccount(0);
        sam.createSubaccount(1);
        sam.createSubaccount(2);
        assertEq(sam.subaccountCount(alice), 3);

        sam.closeSubaccount(1);
        assertEq(sam.subaccountCount(alice), 2);

        sam.closeSubaccount(0);
        sam.closeSubaccount(2);
        assertEq(sam.subaccountCount(alice), 0);
        vm.stopPrank();
    }
}
