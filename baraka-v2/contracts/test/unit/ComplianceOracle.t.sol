// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/shariah/ComplianceOracle.sol";

/**
 * @title ComplianceOracleTest
 * @notice Comprehensive unit tests for ComplianceOracle governance contract.
 */
contract ComplianceOracleTest is Test {

    ComplianceOracle oracle;

    address owner   = address(0xABCD);
    address member1 = address(0x1001);
    address member2 = address(0x1002);
    address member3 = address(0x1003);
    address member4 = address(0x1004);
    address member5 = address(0x1005);
    address outsider = address(0xBEEF);

    bytes32 constant BTC_MARKET = keccak256("BTC-USD");
    bytes32 constant ETH_MARKET = keccak256("ETH-USD");
    // AUDIT FIX: contentHash must now encode execution params for binding verification
    bytes32 constant CONTENT_HASH = keccak256("attestation-content-v1"); // for non-execution tests only
    bytes32 constant CONTENT_HASH_2 = keccak256("attestation-content-v2"); // for non-execution tests only

    /// @dev Generate contentHash for asset compliance execution
    function _complianceHash(bytes32 marketId, bool compliant) internal pure returns (bytes32) {
        return keccak256(abi.encode("ASSET_COMPLIANCE", marketId, compliant));
    }

    /// @dev Generate contentHash for fatwa update execution
    function _fatwaHash(bytes32 marketId, string memory cid) internal pure returns (bytes32) {
        return keccak256(abi.encode("FATWA_UPDATE", marketId, cid));
    }

    // ─────────────────────────────────────────────────────
    // Setup
    // ─────────────────────────────────────────────────────

    function setUp() public {
        vm.prank(owner);
        oracle = new ComplianceOracle(owner);
    }

    /// @dev Helper: add N board members (1-5) and set quorum.
    function _addMembers(uint256 count) internal {
        address[5] memory members = [member1, member2, member3, member4, member5];
        vm.startPrank(owner);
        for (uint256 i = 0; i < count; i++) {
            oracle.addBoardMember(members[i]);
        }
        vm.stopPrank();
    }

    /// @dev Helper: submit attestation from member1 and return its id.
    function _submitAttestation(bytes32 contentHash) internal returns (bytes32) {
        vm.prank(member1);
        bytes32 attId = oracle.submitAttestation(contentHash);
        return attId;
    }

    /// @dev Helper: gather quorum (3 sigs) on an attestation.
    ///      member1 already signed via submitAttestation, so member2 + member3 sign here.
    function _gatherQuorum(bytes32 attId) internal {
        vm.prank(member2);
        oracle.signAttestation(attId);
        vm.prank(member3);
        oracle.signAttestation(attId);
    }

    // ─────────────────────────────────────────────────────
    // 1. addBoardMember
    // ─────────────────────────────────────────────────────

    function test_addBoardMember_success() public {
        vm.prank(owner);
        oracle.addBoardMember(member1);

        assertTrue(oracle.isBoardMember(member1));
        assertEq(oracle.getBoardMemberCount(), 1);
        assertEq(oracle.boardMembers(0), member1);
    }

    function test_addBoardMember_multiple() public {
        _addMembers(3);

        assertTrue(oracle.isBoardMember(member1));
        assertTrue(oracle.isBoardMember(member2));
        assertTrue(oracle.isBoardMember(member3));
        assertEq(oracle.getBoardMemberCount(), 3);
    }

    function test_addBoardMember_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ComplianceOracle.BoardMemberAdded(member1);
        oracle.addBoardMember(member1);
    }

    function test_addBoardMember_revertsIfNotOwner() public {
        vm.prank(outsider);
        vm.expectRevert();
        oracle.addBoardMember(member1);
    }

    function test_addBoardMember_revertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert("CO: zero address");
        oracle.addBoardMember(address(0));
    }

    function test_addBoardMember_revertsIfDuplicate() public {
        vm.startPrank(owner);
        oracle.addBoardMember(member1);
        vm.expectRevert("CO: already member");
        oracle.addBoardMember(member1);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────
    // 2. removeBoardMember
    // ─────────────────────────────────────────────────────

    function test_removeBoardMember_success() public {
        _addMembers(4); // Need 4 so removing 1 still satisfies quorum of 3

        vm.prank(owner);
        oracle.removeBoardMember(member2);

        assertFalse(oracle.isBoardMember(member2));
        assertEq(oracle.getBoardMemberCount(), 3);
    }

    function test_removeBoardMember_swapAndPop() public {
        // Add 4 members: [member1, member2, member3, member4] — need 4 for quorum guard
        _addMembers(4);

        // Remove member1 (index 0). member4 should swap into index 0.
        vm.prank(owner);
        oracle.removeBoardMember(member1);

        assertEq(oracle.getBoardMemberCount(), 3);
        // member4 was last, should now be at index 0
        assertEq(oracle.boardMembers(0), member4);
        assertEq(oracle.boardMembers(1), member2);
        assertEq(oracle.boardMembers(2), member3);
    }

    function test_removeBoardMember_removeLast() public {
        _addMembers(4); // Need 4 so removing 1 keeps 3 >= quorum

        // Remove member4 (last element) -- no swap needed, just pop.
        vm.prank(owner);
        oracle.removeBoardMember(member4);

        assertEq(oracle.getBoardMemberCount(), 3);
        assertEq(oracle.boardMembers(0), member1);
        assertEq(oracle.boardMembers(1), member2);
        assertEq(oracle.boardMembers(2), member3);
    }

    function test_removeBoardMember_emitsEvent() public {
        _addMembers(4); // Need 4 so removing 1 keeps 3 >= quorum

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit ComplianceOracle.BoardMemberRemoved(member4);
        oracle.removeBoardMember(member4);
    }

    function test_removeBoardMember_revertsIfNotOwner() public {
        _addMembers(1);

        vm.prank(outsider);
        vm.expectRevert();
        oracle.removeBoardMember(member1);
    }

    function test_removeBoardMember_revertsIfNotMember() public {
        vm.prank(owner);
        vm.expectRevert("CO: not member");
        oracle.removeBoardMember(outsider);
    }

    // ─────────────────────────────────────────────────────
    // 3. setQuorum
    // ─────────────────────────────────────────────────────

    function test_setQuorum_success() public {
        _addMembers(5);

        vm.prank(owner);
        oracle.setQuorum(4);

        assertEq(oracle.quorum(), 4);
    }

    function test_setQuorum_emitsEvent() public {
        _addMembers(5);

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ComplianceOracle.QuorumUpdated(2);
        oracle.setQuorum(2);
    }

    function test_setQuorum_canSetToMemberCount() public {
        _addMembers(3);

        vm.prank(owner);
        oracle.setQuorum(3);
        assertEq(oracle.quorum(), 3);
    }

    function test_setQuorum_canSetToOne() public {
        _addMembers(3);

        vm.prank(owner);
        oracle.setQuorum(1);
        assertEq(oracle.quorum(), 1);
    }

    function test_setQuorum_revertsIfNotOwner() public {
        _addMembers(3);

        vm.prank(outsider);
        vm.expectRevert();
        oracle.setQuorum(2);
    }

    function test_setQuorum_revertsIfZero() public {
        _addMembers(3);

        vm.prank(owner);
        vm.expectRevert("CO: invalid quorum");
        oracle.setQuorum(0);
    }

    function test_setQuorum_revertsIfExceedsMemberCount() public {
        _addMembers(3);

        vm.prank(owner);
        vm.expectRevert("CO: invalid quorum");
        oracle.setQuorum(4);
    }

    function test_setQuorum_revertsIfNoMembers() public {
        // No members added, length = 0. Any quorum > 0 exceeds length.
        vm.prank(owner);
        vm.expectRevert("CO: invalid quorum");
        oracle.setQuorum(1);
    }

    // ─────────────────────────────────────────────────────
    // 4. submitAttestation
    // ─────────────────────────────────────────────────────

    function test_submitAttestation_success() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        vm.prank(member1);
        bytes32 attId = oracle.submitAttestation(CONTENT_HASH);

        // Verify attestation was created
        (bytes32 contentHash, uint256 timestamp, uint256 sigCount, bool executed) = oracle.attestations(attId);
        assertEq(contentHash, CONTENT_HASH);
        assertEq(timestamp, block.timestamp);
        assertEq(sigCount, 1);
        assertFalse(executed);

        // Submitter is auto-signed
        assertTrue(oracle.hasSignedAttestation(attId, member1));
    }

    function test_submitAttestation_emitsEvents() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        vm.prank(member1);
        // We cannot predict attId before the call since it depends on block.timestamp,
        // so we just check that both events are emitted (no topic check).
        vm.expectEmit(false, false, false, false);
        emit ComplianceOracle.AttestationSubmitted(bytes32(0), CONTENT_HASH, member1);
        oracle.submitAttestation(CONTENT_HASH);
    }

    function test_submitAttestation_revertsIfNotBoardMember() public {
        _addMembers(3);

        vm.prank(outsider);
        vm.expectRevert("CO: not board member");
        oracle.submitAttestation(CONTENT_HASH);
    }

    function test_submitAttestation_differentMembersDifferentIds() public {
        _addMembers(3);

        vm.prank(member1);
        bytes32 attId1 = oracle.submitAttestation(CONTENT_HASH);

        vm.prank(member2);
        bytes32 attId2 = oracle.submitAttestation(CONTENT_HASH);

        // Same content hash but different submitters -> different attestation ids
        assertTrue(attId1 != attId2);
    }

    // ─────────────────────────────────────────────────────
    // 5. signAttestation
    // ─────────────────────────────────────────────────────

    function test_signAttestation_success() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        vm.prank(member2);
        oracle.signAttestation(attId);

        (, , uint256 sigCount, ) = oracle.attestations(attId);
        assertEq(sigCount, 2);
        assertTrue(oracle.hasSignedAttestation(attId, member2));
    }

    function test_signAttestation_emitsEvent() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        vm.prank(member2);
        vm.expectEmit(true, true, false, false);
        emit ComplianceOracle.AttestationSigned(attId, member2);
        oracle.signAttestation(attId);
    }

    function test_signAttestation_revertsIfNotBoardMember() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        vm.prank(outsider);
        vm.expectRevert("CO: not board member");
        oracle.signAttestation(attId);
    }

    function test_signAttestation_revertsIfDoubleSigned() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        // member1 already signed via submit
        vm.prank(member1);
        vm.expectRevert("CO: already signed");
        oracle.signAttestation(attId);
    }

    function test_signAttestation_revertsIfNoSuchAttestation() public {
        _addMembers(3);

        vm.prank(member1);
        vm.expectRevert("CO: no such attestation");
        oracle.signAttestation(bytes32(uint256(0xdead)));
    }

    function test_signAttestation_revertsIfAlreadyExecuted() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId);

        // Execute
        vm.prank(member1);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);

        // Try to sign after execution
        vm.prank(member4);
        // member4 is not added yet, but let's add and try
        vm.stopPrank();
        vm.prank(owner);
        oracle.addBoardMember(member4);

        vm.prank(member4);
        vm.expectRevert("CO: already executed");
        oracle.signAttestation(attId);
    }

    // ─────────────────────────────────────────────────────
    // 6. hasQuorum
    // ─────────────────────────────────────────────────────

    function test_hasQuorum_falseBeforeQuorum() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        // Only 1 signature (submitter)
        assertFalse(oracle.hasQuorum(attId));

        // 2 signatures
        vm.prank(member2);
        oracle.signAttestation(attId);
        assertFalse(oracle.hasQuorum(attId));
    }

    function test_hasQuorum_trueAtQuorum() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);
        _gatherQuorum(attId);

        assertTrue(oracle.hasQuorum(attId));
    }

    function test_hasQuorum_trueAboveQuorum() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);
        _gatherQuorum(attId);

        // 4th signature
        vm.prank(member4);
        oracle.signAttestation(attId);

        assertTrue(oracle.hasQuorum(attId));
    }

    function test_hasQuorum_falseForNonexistent() public view {
        assertFalse(oracle.hasQuorum(bytes32(uint256(0xdead))));
    }

    // ─────────────────────────────────────────────────────
    // 7. executeAssetCompliance
    // ─────────────────────────────────────────────────────

    function test_executeAssetCompliance_success() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId);

        vm.prank(member1);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);

        assertTrue(oracle.assetCompliance(BTC_MARKET));
        assertTrue(oracle.isCompliant(BTC_MARKET));

        (, , , bool executed) = oracle.attestations(attId);
        assertTrue(executed);
    }

    function test_executeAssetCompliance_setFalse() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        // First set to true
        bytes32 attId1 = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId1);

        vm.prank(member1);
        oracle.executeAssetCompliance(attId1, BTC_MARKET, true);
        assertTrue(oracle.isCompliant(BTC_MARKET));

        // Now set to false with a new attestation
        vm.warp(block.timestamp + 1); // ensure different attestation id
        bytes32 attId2 = _submitAttestation(_complianceHash(BTC_MARKET, false));
        _gatherQuorum(attId2);

        vm.prank(member1);
        oracle.executeAssetCompliance(attId2, BTC_MARKET, false);
        assertFalse(oracle.isCompliant(BTC_MARKET));
    }

    function test_executeAssetCompliance_emitsEvents() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId);

        vm.prank(member1);
        vm.expectEmit(true, false, false, false);
        emit ComplianceOracle.AttestationExecuted(attId);
        vm.expectEmit(true, false, false, true);
        emit ComplianceOracle.AssetComplianceSet(BTC_MARKET, true);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);
    }

    function test_executeAssetCompliance_revertsIfNotBoardMember() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);
        _gatherQuorum(attId);

        vm.prank(outsider);
        vm.expectRevert("CO: not board member");
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);
    }

    // ─────────────────────────────────────────────────────
    // 8. executeFatwaUpdate
    // ─────────────────────────────────────────────────────

    function test_executeFatwaUpdate_success() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        string memory cid = "QmTestFatwaCID123";
        bytes32 attId = _submitAttestation(_fatwaHash(BTC_MARKET, cid));
        _gatherQuorum(attId);

        vm.prank(member1);
        oracle.executeFatwaUpdate(attId, BTC_MARKET, cid);

        assertEq(oracle.fatwaCID(BTC_MARKET), cid);

        (, , , bool executed) = oracle.attestations(attId);
        assertTrue(executed);
    }

    function test_executeFatwaUpdate_emitsEvents() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        string memory cid = "QmTestFatwaCID123";
        bytes32 attId = _submitAttestation(_fatwaHash(BTC_MARKET, cid));
        _gatherQuorum(attId);

        vm.prank(member1);
        vm.expectEmit(true, false, false, false);
        emit ComplianceOracle.AttestationExecuted(attId);
        vm.expectEmit(true, false, false, true);
        emit ComplianceOracle.FatwaUpdated(BTC_MARKET, cid);
        oracle.executeFatwaUpdate(attId, BTC_MARKET, cid);
    }

    function test_executeFatwaUpdate_revertsIfNotBoardMember() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);
        _gatherQuorum(attId);

        vm.prank(outsider);
        vm.expectRevert("CO: not board member");
        oracle.executeFatwaUpdate(attId, BTC_MARKET, "QmTest");
    }

    // ─────────────────────────────────────────────────────
    // 9. Cannot execute without quorum
    // ─────────────────────────────────────────────────────

    function test_executeAssetCompliance_revertsWithoutQuorum() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);
        // Only 1 signature (submitter), quorum is 3

        vm.prank(member1);
        vm.expectRevert("CO: quorum not met");
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);
    }

    function test_executeFatwaUpdate_revertsWithoutQuorum() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        vm.prank(member1);
        vm.expectRevert("CO: quorum not met");
        oracle.executeFatwaUpdate(attId, BTC_MARKET, "QmTest");
    }

    function test_executeAssetCompliance_revertsWithPartialQuorum() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(CONTENT_HASH);

        // Only 2 signatures (1 short of quorum)
        vm.prank(member2);
        oracle.signAttestation(attId);

        vm.prank(member1);
        vm.expectRevert("CO: quorum not met");
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);
    }

    // ─────────────────────────────────────────────────────
    // 10. Cannot re-execute
    // ─────────────────────────────────────────────────────

    function test_executeAssetCompliance_revertsIfAlreadyExecuted() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId);

        vm.prank(member1);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);

        vm.prank(member1);
        vm.expectRevert("CO: already executed");
        oracle.executeAssetCompliance(attId, ETH_MARKET, true);
    }

    function test_executeFatwaUpdate_revertsIfAlreadyExecuted() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_fatwaHash(BTC_MARKET, "QmTest1"));
        _gatherQuorum(attId);

        vm.prank(member1);
        oracle.executeFatwaUpdate(attId, BTC_MARKET, "QmTest1");

        vm.prank(member1);
        vm.expectRevert("CO: already executed");
        oracle.executeFatwaUpdate(attId, BTC_MARKET, "QmTest2");
    }

    function test_executeAssetCompliance_thenFatwaUpdate_revertsSecond() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId);

        // Execute as asset compliance first
        vm.prank(member1);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);

        // Try to re-execute as fatwa update
        vm.prank(member1);
        vm.expectRevert("CO: already executed");
        oracle.executeFatwaUpdate(attId, BTC_MARKET, "QmTest");
    }

    // ─────────────────────────────────────────────────────
    // 11. isCompliant view
    // ─────────────────────────────────────────────────────

    function test_isCompliant_defaultFalse() public view {
        assertFalse(oracle.isCompliant(BTC_MARKET));
        assertFalse(oracle.isCompliant(ETH_MARKET));
    }

    function test_isCompliant_reflectsAssetCompliance() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId);

        vm.prank(member1);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);

        assertTrue(oracle.isCompliant(BTC_MARKET));
        assertFalse(oracle.isCompliant(ETH_MARKET)); // unaffected
    }

    // ─────────────────────────────────────────────────────
    // 12. getBoardMemberCount view
    // ─────────────────────────────────────────────────────

    function test_getBoardMemberCount_initiallyZero() public view {
        assertEq(oracle.getBoardMemberCount(), 0);
    }

    function test_getBoardMemberCount_afterAdds() public {
        _addMembers(5);
        assertEq(oracle.getBoardMemberCount(), 5);
    }

    function test_getBoardMemberCount_afterRemove() public {
        _addMembers(5);

        vm.prank(owner);
        oracle.removeBoardMember(member3);

        assertEq(oracle.getBoardMemberCount(), 4);
    }

    // ─────────────────────────────────────────────────────
    // 13. Full flow: 5 members, submit, 3 sign, execute
    // ─────────────────────────────────────────────────────

    function test_fullFlow_assetCompliance() public {
        // Step 1: Owner adds 5 board members
        _addMembers(5);
        assertEq(oracle.getBoardMemberCount(), 5);

        // Step 2: Owner sets quorum to 3
        vm.prank(owner);
        oracle.setQuorum(3);
        assertEq(oracle.quorum(), 3);

        // Step 3: member1 submits attestation (auto-signs, count = 1)
        vm.prank(member1);
        bytes32 attId = oracle.submitAttestation(_complianceHash(BTC_MARKET, true));

        (, , uint256 sigCount, ) = oracle.attestations(attId);
        assertEq(sigCount, 1);
        assertFalse(oracle.hasQuorum(attId));

        // Step 4: member2 signs (count = 2, still no quorum)
        vm.prank(member2);
        oracle.signAttestation(attId);

        (, , sigCount, ) = oracle.attestations(attId);
        assertEq(sigCount, 2);
        assertFalse(oracle.hasQuorum(attId));

        // Step 5: member3 signs (count = 3, quorum reached)
        vm.prank(member3);
        oracle.signAttestation(attId);

        (, , sigCount, ) = oracle.attestations(attId);
        assertEq(sigCount, 3);
        assertTrue(oracle.hasQuorum(attId));

        // Step 6: Compliance not yet set
        assertFalse(oracle.isCompliant(BTC_MARKET));

        // Step 7: Execute — sets BTC-USD as compliant
        vm.prank(member4);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);

        assertTrue(oracle.isCompliant(BTC_MARKET));

        // Step 8: Attestation is now marked executed
        (, , , bool executed) = oracle.attestations(attId);
        assertTrue(executed);

        // Step 9: Cannot re-execute
        vm.prank(member5);
        vm.expectRevert("CO: already executed");
        oracle.executeAssetCompliance(attId, ETH_MARKET, true);
    }

    function test_fullFlow_fatwaUpdate() public {
        // Step 1: Add 5 members, set quorum
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        // Step 2: Submit + gather quorum
        string memory cid = "QmShariah2024FinalReviewBTC";
        bytes32 attId = _submitAttestation(_fatwaHash(BTC_MARKET, cid));
        _gatherQuorum(attId);
        assertTrue(oracle.hasQuorum(attId));

        // Step 3: Execute fatwa update

        vm.prank(member2);
        oracle.executeFatwaUpdate(attId, BTC_MARKET, cid);

        assertEq(oracle.fatwaCID(BTC_MARKET), cid);

        (, , , bool executed) = oracle.attestations(attId);
        assertTrue(executed);
    }

    // ─────────────────────────────────────────────────────
    // Edge cases
    // ─────────────────────────────────────────────────────

    function test_executeAssetCompliance_revertsForNonexistentAttestation() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        vm.prank(member1);
        vm.expectRevert("CO: no such attestation");
        oracle.executeAssetCompliance(bytes32(uint256(0xdead)), BTC_MARKET, true);
    }

    function test_executeFatwaUpdate_revertsForNonexistentAttestation() public {
        _addMembers(3);
        vm.prank(owner);
        oracle.setQuorum(3);

        vm.prank(member1);
        vm.expectRevert("CO: no such attestation");
        oracle.executeFatwaUpdate(bytes32(uint256(0xdead)), BTC_MARKET, "QmTest");
    }

    function test_quorumOfOne_immediateExecution() public {
        _addMembers(1);

        vm.prank(owner);
        oracle.setQuorum(1);

        // Submit auto-signs (count = 1), quorum = 1 -> immediately executable
        bytes32 attId = _submitAttestation(_complianceHash(BTC_MARKET, true));
        assertTrue(oracle.hasQuorum(attId));

        vm.prank(member1);
        oracle.executeAssetCompliance(attId, BTC_MARKET, true);
        assertTrue(oracle.isCompliant(BTC_MARKET));
    }

    function test_defaultQuorumIsThree() public view {
        assertEq(oracle.quorum(), 3);
    }

    function test_multipleMarketsIndependent() public {
        _addMembers(5);
        vm.prank(owner);
        oracle.setQuorum(3);

        // Attestation 1: BTC compliant
        bytes32 attId1 = _submitAttestation(_complianceHash(BTC_MARKET, true));
        _gatherQuorum(attId1);
        vm.prank(member1);
        oracle.executeAssetCompliance(attId1, BTC_MARKET, true);

        // Attestation 2: ETH non-compliant
        vm.warp(block.timestamp + 1);
        bytes32 attId2 = _submitAttestation(_complianceHash(ETH_MARKET, false));
        _gatherQuorum(attId2);
        vm.prank(member1);
        oracle.executeAssetCompliance(attId2, ETH_MARKET, false);

        assertTrue(oracle.isCompliant(BTC_MARKET));
        assertFalse(oracle.isCompliant(ETH_MARKET));
    }
}
