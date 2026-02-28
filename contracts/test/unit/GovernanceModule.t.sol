// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/shariah/GovernanceModule.sol";

/**
 * @title GovernanceModuleTest
 * @notice Full unit test coverage for GovernanceModule.sol
 *
 * Tests cover:
 *   - Proposal creation (propose)
 *   - Voting (castVote) — for / against / double-vote / zero-weight
 *   - Queuing (queue) — pass / fail / not-pending
 *   - Timelock (execute) — before/after 48h, vetoed, not-queued
 *   - Shariah board veto — pending and queued proposals
 *   - Cancellation by proposer
 *   - Admin — transferShariahMultisig, setGovernanceToken
 *   - Constants — TIMELOCK_DELAY = 48h, VETO_WINDOW = 48h
 *   - Full lifecycle: propose -> vote -> queue -> wait -> execute
 *   - Veto lifecycle: propose -> vote -> queue -> veto -> execute reverts
 */
contract GovernanceModuleTest is Test {

    GovernanceModule public gov;

    address public board    = address(0xBEEF); // Shariah board multisig
    address public proposer = address(0xCAFE);
    address public voter1   = address(0xABC1);
    address public voter2   = address(0xABC2);
    address public voter3   = address(0xABC3);
    address public attacker = address(0xDEAD);

    // Dummy target contract that does nothing (for execute tests)
    address public target;

    // Helper: deploy a proposal with sensible defaults
    function _propose() internal returns (uint256 id) {
        vm.prank(proposer);
        id = gov.propose(target, abi.encodeWithSignature("ping()"), "Test proposal: update risk parameters");
    }

    // Helper: pass a proposal with more votes for than against
    function _proposeAndPass() internal returns (uint256 id) {
        id = _propose();
        vm.prank(voter1);
        gov.castVote(id, true, 100);  // 100 for
        vm.prank(voter2);
        gov.castVote(id, false, 10);  // 10 against
        // votesFor(100) > votesAgainst(10) -> can queue
    }

    function setUp() public {
        gov    = new GovernanceModule(board, address(0));
        target = address(new DummyTarget());
    }

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    function test_timelockDelayIs48Hours() public view {
        assertEq(gov.TIMELOCK_DELAY(), 48 hours);
    }

    function test_vetoWindowIs48Hours() public view {
        assertEq(gov.VETO_WINDOW(), 48 hours);
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    function test_constructor_setsShariahMultisig() public view {
        assertEq(gov.shariahMultisig(), board);
    }

    function test_constructor_zeroMultisigReverts() public {
        vm.expectRevert("Governance: zero multisig");
        new GovernanceModule(address(0), address(0));
    }

    function test_constructor_governanceTokenCanBeZero() public {
        GovernanceModule g = new GovernanceModule(board, address(0));
        assertEq(g.governanceToken(), address(0));
    }

    // ─────────────────────────────────────────────────────
    // propose()
    // ─────────────────────────────────────────────────────

    function test_propose_createsProposal() public {
        uint256 id = _propose();
        assertEq(id, 1);
        assertEq(gov.proposalCount(), 1);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(p.proposer,    proposer);
        assertEq(p.target,      target);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Pending));
        assertEq(p.votesFor,    0);
        assertEq(p.votesAgainst, 0);
        assertFalse(p.shariahVetoed);
    }

    function test_propose_incrementsCounter() public {
        _propose();
        _propose();
        _propose();
        assertEq(gov.proposalCount(), 3);
    }

    function test_propose_emitsEvent() public {
        vm.prank(proposer);
        vm.expectEmit(true, false, false, true);
        emit GovernanceModule.ProposalCreated(1, proposer, target, "Test proposal: update risk parameters");
        gov.propose(target, "", "Test proposal: update risk parameters");
    }

    function test_propose_zeroTargetReverts() public {
        vm.prank(proposer);
        vm.expectRevert("Governance: zero target");
        gov.propose(address(0), "", "Description");
    }

    function test_propose_emptyDescriptionReverts() public {
        vm.prank(proposer);
        vm.expectRevert("Governance: empty description");
        gov.propose(target, "", "");
    }

    // ─────────────────────────────────────────────────────
    // castVote()
    // ─────────────────────────────────────────────────────

    function test_castVote_forIncrementsVotesFor() public {
        uint256 id = _propose();
        vm.prank(voter1);
        gov.castVote(id, true, 500);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(p.votesFor, 500);
        assertEq(p.votesAgainst, 0);
    }

    function test_castVote_againstIncrementsVotesAgainst() public {
        uint256 id = _propose();
        vm.prank(voter1);
        gov.castVote(id, false, 300);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(p.votesFor, 0);
        assertEq(p.votesAgainst, 300);
    }

    function test_castVote_multipleVoters() public {
        uint256 id = _propose();
        vm.prank(voter1); gov.castVote(id, true,  100);
        vm.prank(voter2); gov.castVote(id, true,  200);
        vm.prank(voter3); gov.castVote(id, false, 50);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(p.votesFor,     300);
        assertEq(p.votesAgainst, 50);
    }

    function test_castVote_emitsEvent() public {
        uint256 id = _propose();
        vm.prank(voter1);
        vm.expectEmit(true, false, false, true);
        emit GovernanceModule.VoteCast(id, voter1, true, 42);
        gov.castVote(id, true, 42);
    }

    function test_castVote_doubleVoteReverts() public {
        uint256 id = _propose();
        vm.startPrank(voter1);
        gov.castVote(id, true, 100);
        vm.expectRevert("Governance: already voted");
        gov.castVote(id, true, 100);
        vm.stopPrank();
    }

    function test_castVote_zeroWeightReverts() public {
        uint256 id = _propose();
        vm.prank(voter1);
        vm.expectRevert("Governance: zero weight");
        gov.castVote(id, true, 0);
    }

    function test_castVote_notPendingReverts() public {
        uint256 id = _proposeAndPass();
        gov.queue(id); // moves to Queued

        vm.prank(voter3);
        vm.expectRevert("Governance: not pending");
        gov.castVote(id, true, 100);
    }

    function test_castVote_hasVotedTracked() public {
        uint256 id = _propose();
        assertFalse(gov.hasVoted(id, voter1));
        vm.prank(voter1);
        gov.castVote(id, true, 100);
        assertTrue(gov.hasVoted(id, voter1));
    }

    // ─────────────────────────────────────────────────────
    // queue()
    // ─────────────────────────────────────────────────────

    function test_queue_movesStatusToQueued() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);
        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Queued));
    }

    function test_queue_setsQueuedAt() public {
        uint256 id = _proposeAndPass();
        uint256 before = block.timestamp;
        gov.queue(id);
        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(p.queuedAt, before);
    }

    function test_queue_emitsEvent() public {
        uint256 id = _proposeAndPass();
        vm.expectEmit(true, false, false, true);
        emit GovernanceModule.ProposalQueued(id, block.timestamp + 48 hours);
        gov.queue(id);
    }

    function test_queue_failsIfVotesAgainstWins() public {
        uint256 id = _propose();
        vm.prank(voter1); gov.castVote(id, false, 200); // more against
        vm.prank(voter2); gov.castVote(id, true,  100); // less for

        vm.expectRevert("Governance: did not pass");
        gov.queue(id);
    }

    function test_queue_failsIfTied() public {
        uint256 id = _propose();
        vm.prank(voter1); gov.castVote(id, true,  100);
        vm.prank(voter2); gov.castVote(id, false, 100); // tied

        vm.expectRevert("Governance: did not pass"); // requires strictly >
        gov.queue(id);
    }

    function test_queue_failsIfNotPending() public {
        uint256 id = _proposeAndPass();
        gov.queue(id); // queued

        vm.expectRevert("Governance: not pending");
        gov.queue(id); // double queue
    }

    // ─────────────────────────────────────────────────────
    // execute()
    // ─────────────────────────────────────────────────────

    function test_execute_afterTimelockSucceeds() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);

        vm.warp(block.timestamp + 48 hours + 1);
        gov.execute(id);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Executed));
    }

    function test_execute_beforeTimelockReverts() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);

        vm.warp(block.timestamp + 48 hours - 1); // 1 second short
        vm.expectRevert("Governance: timelock active");
        gov.execute(id);
    }

    function test_execute_exactlyAtTimelockSucceeds() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);
        uint256 queued = block.timestamp;

        vm.warp(queued + 48 hours); // exactly at boundary
        gov.execute(id);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Executed));
    }

    function test_execute_notQueuedReverts() public {
        uint256 id = _propose();
        vm.expectRevert("Governance: not queued");
        gov.execute(id);
    }

    function test_execute_vetoedReverts() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);

        vm.prank(board);
        gov.vetoProposal(id, "Shariah non-compliant");
        // vetoProposal sets status = Vetoed, so execute hits "not queued" first
        vm.warp(block.timestamp + 48 hours + 1);
        vm.expectRevert("Governance: not queued");
        gov.execute(id);
    }

    function test_execute_emitsEvent() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);
        vm.warp(block.timestamp + 48 hours + 1);

        vm.expectEmit(true, false, false, false);
        emit GovernanceModule.ProposalExecuted(id);
        gov.execute(id);
    }

    function test_execute_callsTarget() public {
        DummyTarget dt = new DummyTarget();
        bytes memory data = abi.encodeWithSignature("ping()");

        vm.prank(proposer);
        uint256 id = gov.propose(address(dt), data, "Ping the target contract");

        vm.prank(voter1); gov.castVote(id, true, 100);
        gov.queue(id);
        vm.warp(block.timestamp + 48 hours + 1);
        gov.execute(id);

        assertTrue(dt.pinged());
    }

    // ─────────────────────────────────────────────────────
    // vetoProposal()
    // ─────────────────────────────────────────────────────

    function test_veto_onPendingProposal() public {
        uint256 id = _propose();
        vm.prank(board);
        gov.vetoProposal(id, "Riba detected in proposal");

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Vetoed));
        assertTrue(p.shariahVetoed);
    }

    function test_veto_onQueuedProposal() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);

        vm.prank(board);
        gov.vetoProposal(id, "Gharar in execution parameters");

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Vetoed));
    }

    function test_veto_emitsEvent() public {
        uint256 id = _propose();
        vm.prank(board);
        vm.expectEmit(true, false, false, true);
        emit GovernanceModule.ProposalVetoed(id, "Riba");
        gov.vetoProposal(id, "Riba");
    }

    function test_veto_onlyShariahBoard() public {
        uint256 id = _propose();
        vm.prank(attacker);
        vm.expectRevert("Governance: not Shariah board");
        gov.vetoProposal(id, "Trying to veto");
    }

    function test_veto_cannotVetoExecuted() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);
        vm.warp(block.timestamp + 48 hours + 1);
        gov.execute(id);

        vm.prank(board);
        vm.expectRevert("Governance: cannot veto");
        gov.vetoProposal(id, "Too late");
    }

    function test_veto_cannotVetoCancelled() public {
        uint256 id = _propose();
        vm.prank(proposer);
        gov.cancel(id);

        vm.prank(board);
        vm.expectRevert("Governance: cannot veto");
        gov.vetoProposal(id, "Already cancelled");
    }

    // ─────────────────────────────────────────────────────
    // cancel()
    // ─────────────────────────────────────────────────────

    function test_cancel_byProposer() public {
        uint256 id = _propose();
        vm.prank(proposer);
        gov.cancel(id);

        GovernanceModule.Proposal memory p = _getProposal(id);
        assertEq(uint256(p.status), uint256(GovernanceModule.ProposalStatus.Cancelled));
    }

    function test_cancel_emitsEvent() public {
        uint256 id = _propose();
        vm.prank(proposer);
        vm.expectEmit(true, false, false, false);
        emit GovernanceModule.ProposalCancelled(id);
        gov.cancel(id);
    }

    function test_cancel_notProposerReverts() public {
        uint256 id = _propose();
        vm.prank(attacker);
        vm.expectRevert("Governance: not proposer");
        gov.cancel(id);
    }

    function test_cancel_notPendingReverts() public {
        uint256 id = _proposeAndPass();
        gov.queue(id);

        vm.prank(proposer);
        vm.expectRevert("Governance: not pending");
        gov.cancel(id);
    }

    // ─────────────────────────────────────────────────────
    // transferShariahMultisig()
    // ─────────────────────────────────────────────────────

    function test_transferMultisig_succeeds() public {
        address newBoard = address(0x4E3577);
        vm.prank(board);
        gov.transferShariahMultisig(newBoard);
        assertEq(gov.shariahMultisig(), newBoard);
    }

    function test_transferMultisig_emitsEvent() public {
        address newBoard = address(0x4E3577);
        vm.prank(board);
        vm.expectEmit(false, false, false, true);
        emit GovernanceModule.ShariahMultisigTransferred(board, newBoard);
        gov.transferShariahMultisig(newBoard);
    }

    function test_transferMultisig_zeroAddressReverts() public {
        vm.prank(board);
        vm.expectRevert("Governance: zero address");
        gov.transferShariahMultisig(address(0));
    }

    function test_transferMultisig_onlyShariahBoard() public {
        vm.prank(attacker);
        vm.expectRevert("Governance: not Shariah board");
        gov.transferShariahMultisig(address(0xABCD));
    }

    // ─────────────────────────────────────────────────────
    // setGovernanceToken()
    // ─────────────────────────────────────────────────────

    function test_setGovernanceToken_onlyShariahBoard() public {
        vm.prank(board);
        gov.setGovernanceToken(address(0x1234));
        assertEq(gov.governanceToken(), address(0x1234));
    }

    function test_setGovernanceToken_nonBoardReverts() public {
        vm.prank(attacker);
        vm.expectRevert("Governance: not Shariah board");
        gov.setGovernanceToken(address(0x1234));
    }

    // ─────────────────────────────────────────────────────
    // Full lifecycle
    // ─────────────────────────────────────────────────────

    function test_fullLifecycle_proposeVoteQueueExecute() public {
        // 1. Propose
        vm.prank(proposer);
        uint256 id = gov.propose(target, abi.encodeWithSignature("ping()"), "Adjust liquidation threshold to 1.5%");
        assertEq(uint256(_getProposal(id).status), uint256(GovernanceModule.ProposalStatus.Pending));

        // 2. Vote
        vm.prank(voter1); gov.castVote(id, true,  1000);
        vm.prank(voter2); gov.castVote(id, true,   500);
        vm.prank(voter3); gov.castVote(id, false,  200);
        assertEq(_getProposal(id).votesFor,     1500);
        assertEq(_getProposal(id).votesAgainst, 200);

        // 3. Queue
        gov.queue(id);
        assertEq(uint256(_getProposal(id).status), uint256(GovernanceModule.ProposalStatus.Queued));

        // 4. Wait for timelock
        vm.warp(block.timestamp + 48 hours + 1);

        // 5. Execute
        gov.execute(id);
        assertEq(uint256(_getProposal(id).status), uint256(GovernanceModule.ProposalStatus.Executed));
    }

    function test_fullLifecycle_vetoBlocksExecution() public {
        // Propose, vote, queue
        uint256 id = _proposeAndPass();
        gov.queue(id);

        // Shariah board vetoes during veto window
        vm.prank(board);
        gov.vetoProposal(id, "Proposal introduces maysir risk");
        assertEq(uint256(_getProposal(id).status), uint256(GovernanceModule.ProposalStatus.Vetoed));

        // Even after timelock, execution is blocked
        vm.warp(block.timestamp + 48 hours + 1);
        // vetoProposal sets status = Vetoed, so execute hits "not queued" before the veto check
        vm.expectRevert("Governance: not queued");
        gov.execute(id);
    }

    // ─────────────────────────────────────────────────────
    // Fuzz
    // ─────────────────────────────────────────────────────

    function testFuzz_proposalCountAlwaysIncreases(uint8 n) public {
        n = uint8(bound(uint256(n), 1, 20));
        for (uint8 i = 0; i < n; i++) {
            vm.prank(proposer);
            gov.propose(target, "", "Description");
        }
        assertEq(gov.proposalCount(), n);
    }

    function testFuzz_timelockMustElapse(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 48 hours - 1);

        uint256 id = _proposeAndPass();
        gov.queue(id);
        vm.warp(block.timestamp + elapsed);

        vm.expectRevert("Governance: timelock active");
        gov.execute(id);
    }

    // ─────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────

    function _getProposal(uint256 id) internal view returns (GovernanceModule.Proposal memory) {
        (
            uint256 pid,
            address pproposer,
            address ptarget,
            bytes memory pcallData,
            string memory pdescription,
            uint256 pvotesFor,
            uint256 pvotesAgainst,
            uint256 pcreatedAt,
            uint256 pqueuedAt,
            GovernanceModule.ProposalStatus pstatus,
            bool pvetoed
        ) = gov.proposals(id);
        return GovernanceModule.Proposal({
            id: pid,
            proposer: pproposer,
            target: ptarget,
            callData: pcallData,
            description: pdescription,
            votesFor: pvotesFor,
            votesAgainst: pvotesAgainst,
            createdAt: pcreatedAt,
            queuedAt: pqueuedAt,
            status: pstatus,
            shariahVetoed: pvetoed
        });
    }
}

/// @dev Minimal target contract for execute() tests
contract DummyTarget {
    bool public pinged;
    function ping() external { pinged = true; }
}
