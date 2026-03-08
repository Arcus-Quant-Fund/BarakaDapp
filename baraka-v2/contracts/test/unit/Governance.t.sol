// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/governance/BRKXToken.sol";
import "../../src/governance/GovernanceModule.sol";

// ──────────────────────────────────────────────────────
// Mock target: simple counter that GovernanceModule can call
// ──────────────────────────────────────────────────────

contract MockTarget {
    uint256 public counter;
    bool public paused;

    function increment() external {
        require(!paused, "paused");
        counter++;
    }

    function pause() external {
        paused = true;
    }

    function failAlways() external pure {
        revert("always fails");
    }
}

// Non-pausable target (no pause() function)
contract NonPausableTarget {
    uint256 public value;

    function setValue(uint256 v) external {
        value = v;
    }
}

// ══════════════════════════════════════════════════════
//                   BRKXToken Tests
// ══════════════════════════════════════════════════════

contract BRKXTokenTest is Test {
    BRKXToken token;
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new BRKXToken(treasury);
    }

    // ── Constructor ──────────────────────────────────

    function test_constructor_mintsMaxSupplyToTreasury() public view {
        assertEq(token.balanceOf(treasury), 100_000_000e18);
        assertEq(token.totalSupply(), 100_000_000e18);
    }

    function test_constructor_setsOwnerToTreasury() public view {
        assertEq(token.owner(), treasury);
    }

    function test_constructor_setsNameAndSymbol() public view {
        assertEq(token.name(), "Baraka Token");
        assertEq(token.symbol(), "BRKX");
    }

    function test_constructor_revertsOnZeroTreasury() public {
        // OZ5 Ownable constructor reverts before the require check
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BRKXToken(address(0));
    }

    // ── MAX_SUPPLY constant ──────────────────────────

    function test_maxSupplyConstant() public view {
        assertEq(token.MAX_SUPPLY(), 100_000_000e18);
    }

    // ── Burn ─────────────────────────────────────────

    function test_burn_reducesTotalSupply() public {
        uint256 burnAmount = 1_000e18;
        vm.prank(treasury);
        token.burn(burnAmount);

        assertEq(token.totalSupply(), 100_000_000e18 - burnAmount);
        assertEq(token.balanceOf(treasury), 100_000_000e18 - burnAmount);
    }

    function test_burn_revertsIfInsufficientBalance() public {
        vm.prank(alice); // alice has 0 tokens
        vm.expectRevert();
        token.burn(1);
    }

    // ── Renounce ownership ───────────────────────────

    function test_renounceOwnership_reverts() public {
        vm.prank(treasury);
        vm.expectRevert("BRKXToken: renounce disabled");
        token.renounceOwnership();
    }

    function test_renounceOwnership_revertsForAnyone() public {
        vm.prank(alice);
        vm.expectRevert("BRKXToken: renounce disabled");
        token.renounceOwnership();
    }

    // ── Transfer ─────────────────────────────────────

    function test_transfer_updatesBalances() public {
        uint256 amount = 500e18;
        vm.prank(treasury);
        token.transfer(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(treasury), 100_000_000e18 - amount);
    }

    function test_transfer_revertsIfInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
    }

    // ── Delegation & Voting Power ────────────────────

    function test_delegate_selfActivatesVotingPower() public {
        uint256 amount = 10_000e18;
        vm.prank(treasury);
        token.transfer(alice, amount);

        // Before delegation: voting power is 0
        assertEq(token.getVotes(alice), 0);

        // Self-delegate
        vm.prank(alice);
        token.delegate(alice);

        assertEq(token.getVotes(alice), amount);
    }

    function test_delegate_canDelegateToOther() public {
        uint256 amount = 10_000e18;
        vm.prank(treasury);
        token.transfer(alice, amount);

        vm.prank(alice);
        token.delegate(bob);

        assertEq(token.getVotes(bob), amount);
        assertEq(token.getVotes(alice), 0);
    }

    // ── getPastVotes ─────────────────────────────────

    function test_getPastVotes_returnsCorrectValueAfterDelegation() public {
        uint256 amount = 50_000e18;
        vm.prank(treasury);
        token.transfer(alice, amount);

        uint256 b1 = block.number + 1;
        vm.roll(b1);

        vm.prank(alice);
        token.delegate(alice);

        // Roll forward so we can query a past block
        vm.roll(b1 + 5);

        assertEq(token.getPastVotes(alice, b1), amount);
    }

    function test_getPastVotes_returnsZeroBeforeDelegation() public {
        uint256 amount = 50_000e18;

        uint256 b0 = block.number + 1;
        vm.roll(b0);
        uint256 beforeBlock = b0;

        vm.roll(b0 + 1);

        vm.prank(treasury);
        token.transfer(alice, amount);

        vm.prank(alice);
        token.delegate(alice);

        vm.roll(b0 + 2);

        // Before the delegation block, voting power was 0
        assertEq(token.getPastVotes(alice, beforeBlock), 0);
    }

    function test_getPastVotes_updatesAfterTransfer() public {
        uint256 amount = 20_000e18;

        uint256 b0 = block.number + 1;
        vm.roll(b0);

        // Treasury delegates to self
        vm.prank(treasury);
        token.delegate(treasury);

        uint256 b1 = b0 + 1;
        vm.roll(b1);

        // Transfer to alice (who also self-delegates)
        vm.prank(treasury);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.delegate(alice);

        vm.roll(b1 + 5);

        assertEq(token.getPastVotes(alice, b1), amount);
        assertEq(token.getPastVotes(treasury, b1), 100_000_000e18 - amount);
    }
}

// ══════════════════════════════════════════════════════
//              GovernanceModule Tests
// ══════════════════════════════════════════════════════

contract GovernanceModuleTest is Test {
    BRKXToken token;
    GovernanceModule gov;
    MockTarget target;

    address treasury = makeAddr("treasury");
    address shariah = makeAddr("shariah");
    address proposer = makeAddr("proposer");
    address voter1 = makeAddr("voter1");
    address voter2 = makeAddr("voter2");
    address voter3 = makeAddr("voter3");
    address nobody = makeAddr("nobody");

    uint256 constant TOTAL_SUPPLY = 100_000_000e18;

    // The auto-generated getter for the proposals mapping returns ALL 13 struct
    // fields including dynamic types (bytes callData, string description).
    // Field order:
    //   0  id                        uint256
    //   1  proposer                  address
    //   2  target                    address
    //   3  callData                  bytes
    //   4  description               string
    //   5  votesFor                  uint256
    //   6  votesAgainst              uint256
    //   7  createdAt                 uint256
    //   8  snapshotBlock             uint256
    //   9  governanceTokenAtCreation address
    //  10  queuedAt                  uint256
    //  11  status                    ProposalStatus
    //  12  shariahVetoed             bool

    function setUp() public {
        // Deploy token
        token = new BRKXToken(treasury);

        // Deploy governance
        gov = new GovernanceModule(shariah, address(token));

        // Deploy target
        target = new MockTarget();

        // ── Distribute tokens ──
        vm.startPrank(treasury);
        // Proposer needs >= 1e18 for MIN_PROPOSER_BALANCE
        token.transfer(proposer, 100e18);
        // voter1 gets 5% of supply (enough for quorum alone)
        token.transfer(voter1, 5_000_000e18);
        // voter2 gets 2%
        token.transfer(voter2, 2_000_000e18);
        // voter3 gets 1%
        token.transfer(voter3, 1_000_000e18);
        vm.stopPrank();

        // ── Self-delegate (MUST happen before proposal snapshot) ──
        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);
        vm.prank(voter3);
        token.delegate(voter3);

        // Roll forward past SNAPSHOT_DELAY (256 blocks) so getPastVotes works at the snapshot block
        // AUDIT FIX: GovernanceModule now uses block.number - 256 for flash-loan resistance
        vm.roll(block.number + 300);
    }

    // ── Internal helpers (all use 13-field destructuring) ──

    function _propose() internal returns (uint256) {
        vm.prank(proposer);
        return gov.propose(
            address(target),
            abi.encodeWithSelector(MockTarget.increment.selector),
            "Increment counter"
        );
    }

    function _proposeAndVote() internal returns (uint256 pid) {
        pid = _propose();
        vm.prank(voter1);
        gov.castVote(pid, true);
    }

    function _proposeVoteAndQueue() internal returns (uint256 pid) {
        pid = _proposeAndVote();
        vm.warp(block.timestamp + 48 hours);
        gov.queue(pid);
    }

    function _status(uint256 pid) internal view returns (GovernanceModule.ProposalStatus s) {
        (,,,,,,,,,,,s,) = gov.proposals(pid);
    }

    function _vetoed(uint256 pid) internal view returns (bool v) {
        (,,,,,,,,,,,,v) = gov.proposals(pid);
    }

    function _votes(uint256 pid) internal view returns (uint256 f, uint256 a) {
        (,,,,,f,a,,,,,,) = gov.proposals(pid);
    }

    function _queuedAt(uint256 pid) internal view returns (uint256 q) {
        (,,,,,,,,,,q,,) = gov.proposals(pid);
    }

    // ── Constructor ──────────────────────────────────

    function test_constructor_setsShariahMultisig() public view {
        assertEq(gov.shariahMultisig(), shariah);
    }

    function test_constructor_setsGovernanceToken() public view {
        assertEq(gov.governanceToken(), address(token));
    }

    function test_constructor_revertsOnZeroMultisig() public {
        vm.expectRevert("Governance: zero multisig");
        new GovernanceModule(address(0), address(token));
    }

    // ── propose() ────────────────────────────────────

    function test_propose_returnsProposalId() public {
        uint256 pid = _propose();
        assertEq(pid, 1);
    }

    function test_propose_incrementsProposalCount() public {
        _propose();
        assertEq(gov.proposalCount(), 1);
        _propose();
        assertEq(gov.proposalCount(), 2);
    }

    function test_propose_storesProposalFields() public {
        uint256 pid = _propose();

        (
            uint256 id,
            address prop,
            address tgt,
            ,               // callData
            ,               // description
            uint256 vFor,
            uint256 vAgainst,
            uint256 createdAt,
            uint256 snap,
            address tokenAt,
            uint256 qAt,
            GovernanceModule.ProposalStatus st,
            bool vet
        ) = gov.proposals(pid);

        assertEq(id, 1);
        assertEq(prop, proposer);
        assertEq(tgt, address(target));
        assertEq(vFor, 0);
        assertEq(vAgainst, 0);
        assertEq(createdAt, block.timestamp);
        // AUDIT FIX: snapshot now uses SNAPSHOT_DELAY (256) for flash-loan resistance
        assertEq(snap, block.number - gov.SNAPSHOT_DELAY());
        assertEq(tokenAt, address(token));
        assertEq(qAt, 0);
        assertEq(uint8(st), uint8(GovernanceModule.ProposalStatus.Pending));
        assertFalse(vet);
    }

    function test_propose_revertsIfInsufficientBalance() public {
        vm.prank(nobody);
        vm.expectRevert("Governance: insufficient proposer balance");
        gov.propose(address(target), hex"", "test");
    }

    function test_propose_revertsOnZeroTarget() public {
        vm.prank(proposer);
        vm.expectRevert("Governance: zero target");
        gov.propose(address(0), hex"", "test");
    }

    function test_propose_revertsOnSelfTarget() public {
        vm.prank(proposer);
        vm.expectRevert("Governance: self-call forbidden");
        gov.propose(address(gov), hex"", "test");
    }

    function test_propose_revertsOnEmptyDescription() public {
        vm.prank(proposer);
        vm.expectRevert("Governance: empty description");
        gov.propose(address(target), hex"", "");
    }

    function test_propose_revertsWhenGovernanceTokenNotSet() public {
        GovernanceModule gov2 = new GovernanceModule(shariah, address(0));
        vm.prank(proposer);
        vm.expectRevert("Governance: token not set");
        gov2.propose(address(target), hex"aa", "test");
    }

    // ── castVote() ───────────────────────────────────

    function test_castVote_recordsForVote() public {
        uint256 pid = _propose();

        vm.prank(voter1);
        gov.castVote(pid, true);

        (uint256 vFor, uint256 vAgainst) = _votes(pid);
        assertEq(vFor, 5_000_000e18);
        assertEq(vAgainst, 0);
    }

    function test_castVote_recordsAgainstVote() public {
        uint256 pid = _propose();

        vm.prank(voter1);
        gov.castVote(pid, false);

        (uint256 vFor, uint256 vAgainst) = _votes(pid);
        assertEq(vFor, 0);
        assertEq(vAgainst, 5_000_000e18);
    }

    function test_castVote_setsHasVoted() public {
        uint256 pid = _propose();

        assertFalse(gov.hasVoted(pid, voter1));

        vm.prank(voter1);
        gov.castVote(pid, true);

        assertTrue(gov.hasVoted(pid, voter1));
    }

    function test_castVote_preventsDoubleVoting() public {
        uint256 pid = _propose();

        vm.prank(voter1);
        gov.castVote(pid, true);

        vm.prank(voter1);
        vm.expectRevert("Governance: already voted");
        gov.castVote(pid, true);
    }

    function test_castVote_revertsWithZeroWeight() public {
        uint256 pid = _propose();

        vm.prank(nobody);
        vm.expectRevert("Governance: zero weight");
        gov.castVote(pid, true);
    }

    function test_castVote_revertsIfNotPending() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.prank(voter2);
        vm.expectRevert("Governance: not pending");
        gov.castVote(pid, true);
    }

    function test_castVote_multipleVotersAccumulate() public {
        uint256 pid = _propose();

        vm.prank(voter1);
        gov.castVote(pid, true);
        vm.prank(voter2);
        gov.castVote(pid, true);

        (uint256 vFor,) = _votes(pid);
        assertEq(vFor, 5_000_000e18 + 2_000_000e18);
    }

    // ── queue() ──────────────────────────────────────

    function test_queue_succeedsWithMajorityAndQuorum() public {
        uint256 pid = _proposeAndVote();

        vm.warp(block.timestamp + 48 hours);
        gov.queue(pid);

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Queued));
    }

    function test_queue_revertsIfNoMajority() public {
        uint256 pid = _propose();

        vm.prank(voter1);
        gov.castVote(pid, false);

        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert("Governance: did not pass");
        gov.queue(pid);
    }

    function test_queue_revertsIfQuorumNotReached() public {
        uint256 pid = _propose();

        // voter3 has 1% -- less than 4% quorum
        vm.prank(voter3);
        gov.castVote(pid, true);

        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert("Governance: quorum not reached");
        gov.queue(pid);
    }

    function test_queue_revertsIfVotingPeriodNotOver() public {
        uint256 pid = _proposeAndVote();

        vm.expectRevert("Governance: voting period not over");
        gov.queue(pid);
    }

    function test_queue_revertsIfNotPending() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.expectRevert("Governance: not pending");
        gov.queue(pid);
    }

    function test_queue_setsQueuedAt() public {
        uint256 pid = _proposeAndVote();
        uint256 queueTime = block.timestamp + 48 hours;
        vm.warp(queueTime);
        gov.queue(pid);

        assertEq(_queuedAt(pid), queueTime);
    }

    // ── execute() ────────────────────────────────────

    function test_execute_callsTargetSuccessfully() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.warp(block.timestamp + 72 hours + 1); // AUDIT FIX (P4-A2-5): strict > requires 1s past boundary
        gov.execute(pid);

        assertEq(target.counter(), 1);
        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Executed));
    }

    function test_execute_revertsBeforeTimelockExpires() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert("GM: timelock not elapsed"); // AUDIT FIX (P3-CROSS-1): updated error string
        gov.execute(pid);
    }

    function test_execute_revertsAfterProposalExpiry() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.warp(block.timestamp + 15 days);
        vm.expectRevert("Governance: proposal expired");
        gov.execute(pid);
    }

    function test_execute_revertsIfNotQueued() public {
        uint256 pid = _propose();

        vm.expectRevert("Governance: not queued");
        gov.execute(pid);
    }

    function test_execute_revertsIfVetoed() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.prank(shariah);
        gov.vetoProposal(pid, "Shariah non-compliant");

        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert("Governance: not queued");
        gov.execute(pid);
    }

    function test_execute_revertsIfTargetCallFails() public {
        vm.prank(proposer);
        uint256 pid = gov.propose(
            address(target),
            abi.encodeWithSelector(MockTarget.failAlways.selector),
            "Call that fails"
        );

        vm.prank(voter1);
        gov.castVote(pid, true);
        vm.warp(block.timestamp + 48 hours);
        gov.queue(pid);
        vm.warp(block.timestamp + 48 hours);

        vm.expectRevert();
        gov.execute(pid);
    }

    // ── vetoProposal() ──────────────────────────────

    function test_veto_pendingProposal() public {
        uint256 pid = _propose();

        vm.prank(shariah);
        gov.vetoProposal(pid, "Not compliant");

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Vetoed));
        assertTrue(_vetoed(pid));
    }

    function test_veto_queuedProposalWithinWindow() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.warp(block.timestamp + 24 hours);
        vm.prank(shariah);
        gov.vetoProposal(pid, "Shariah concern");

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Vetoed));
        assertTrue(_vetoed(pid));
    }

    function test_veto_revertsAfterVetoWindow() public {
        uint256 pid = _proposeVoteAndQueue();

        // AUDIT FIX (GOV-M-1): Veto window is now 72 hours (was 48h)
        vm.warp(block.timestamp + 73 hours);
        vm.prank(shariah);
        vm.expectRevert("Governance: veto window expired");
        gov.vetoProposal(pid, "Too late");
    }

    function test_veto_revertsIfNotShariahMultisig() public {
        uint256 pid = _propose();

        vm.prank(nobody);
        vm.expectRevert("Governance: not Shariah board");
        gov.vetoProposal(pid, "reason");
    }

    function test_veto_revertsOnExecutedProposal() public {
        uint256 pid = _proposeVoteAndQueue();
        vm.warp(block.timestamp + 72 hours + 1); // AUDIT FIX (P4-A2-5): strict > requires 1s past boundary
        gov.execute(pid);

        vm.prank(shariah);
        vm.expectRevert("Governance: cannot veto");
        gov.vetoProposal(pid, "Too late, already executed");
    }

    function test_veto_revertsOnCancelledProposal() public {
        uint256 pid = _propose();
        vm.prank(proposer);
        gov.cancel(pid);

        vm.prank(shariah);
        vm.expectRevert("Governance: cannot veto");
        gov.vetoProposal(pid, "Already cancelled");
    }

    // ── cancel() ─────────────────────────────────────

    function test_cancel_byProposer() public {
        uint256 pid = _propose();

        vm.prank(proposer);
        gov.cancel(pid);

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Cancelled));
    }

    function test_cancel_revertsIfNotProposer() public {
        uint256 pid = _propose();

        vm.prank(nobody);
        vm.expectRevert("Governance: not proposer");
        gov.cancel(pid);
    }

    function test_cancel_revertsIfNotPending() public {
        uint256 pid = _proposeVoteAndQueue();

        vm.prank(proposer);
        vm.expectRevert("Governance: not pending");
        gov.cancel(pid);
    }

    // ── emergencyPause() ─────────────────────────────

    function test_emergencyPause_callsPauseOnTarget() public {
        // AUDIT FIX (P5-H-7): Must whitelist target before pausing
        vm.prank(shariah);
        gov.setPausableTarget(address(target), true);

        vm.prank(shariah);
        gov.emergencyPause(address(target));

        assertTrue(target.paused());
    }

    function test_emergencyPause_revertsIfNotShariah() public {
        vm.prank(nobody);
        vm.expectRevert("Governance: not Shariah board");
        gov.emergencyPause(address(target));
    }

    function test_emergencyPause_revertsOnZeroTarget() public {
        vm.prank(shariah);
        vm.expectRevert("Governance: zero target");
        gov.emergencyPause(address(0));
    }

    function test_emergencyPause_revertsIfTargetHasNoPause() public {
        NonPausableTarget npt = new NonPausableTarget();
        // AUDIT FIX (P5-H-7): Whitelist target first, then verify pause() call fails
        vm.prank(shariah);
        gov.setPausableTarget(address(npt), true);

        vm.prank(shariah);
        vm.expectRevert("Governance: pause failed");
        gov.emergencyPause(address(npt));
    }

    // ── transferShariahMultisig / acceptShariahMultisig ──

    function test_transferShariahMultisig_setsPending() public {
        address newMultisig = address(0xBEEF);

        vm.prank(shariah);
        gov.transferShariahMultisig(newMultisig);

        assertEq(gov.pendingShariahMultisig(), newMultisig);
        assertEq(gov.shariahMultisig(), shariah);
    }

    function test_transferShariahMultisig_revertsOnZero() public {
        vm.prank(shariah);
        vm.expectRevert("Governance: zero address");
        gov.transferShariahMultisig(address(0));
    }

    function test_transferShariahMultisig_revertsIfNotShariah() public {
        vm.prank(nobody);
        vm.expectRevert("Governance: not Shariah board");
        gov.transferShariahMultisig(address(0xBEEF));
    }

    function test_acceptShariahMultisig_completes2StepTransfer() public {
        address newMultisig = address(0xBEEF);

        vm.prank(shariah);
        gov.transferShariahMultisig(newMultisig);

        vm.prank(newMultisig);
        gov.acceptShariahMultisig();

        assertEq(gov.shariahMultisig(), newMultisig);
        assertEq(gov.pendingShariahMultisig(), address(0));
    }

    function test_acceptShariahMultisig_revertsIfNotPending() public {
        vm.prank(nobody);
        vm.expectRevert("Governance: not pending multisig");
        gov.acceptShariahMultisig();
    }

    function test_shariahTransfer_oldMultisigLosesAccess() public {
        address newMultisig = address(0xBEEF);

        vm.prank(shariah);
        gov.transferShariahMultisig(newMultisig);
        vm.prank(newMultisig);
        gov.acceptShariahMultisig();

        // Old shariah can no longer act
        vm.prank(shariah);
        vm.expectRevert("Governance: not Shariah board");
        gov.emergencyPause(address(target));
    }

    // ── setGovernanceToken() ─────────────────────────

    /// AUDIT FIX (P5-H-6): Token is immutable — can only be set once.
    /// Test on fresh governance with address(0) token, then verify single set works.
    function test_setGovernanceToken_updatesToken() public {
        GovernanceModule gov2 = new GovernanceModule(shariah, address(0));
        BRKXToken newToken = new BRKXToken(treasury);

        vm.roll(block.number + 1);

        vm.prank(shariah);
        gov2.setGovernanceToken(address(newToken));

        assertEq(gov2.governanceToken(), address(newToken));

        // Second set must revert — token is immutable
        BRKXToken anotherToken = new BRKXToken(treasury);
        vm.prank(shariah);
        vm.expectRevert("Governance: token already set (immutable)");
        gov2.setGovernanceToken(address(anotherToken));
    }

    /// AUDIT FIX (P5-H-6): Token is immutable — zero address reverts.
    function test_setGovernanceToken_revertsOnZeroAddress() public {
        // Use a fresh governance with no token set
        GovernanceModule gov2 = new GovernanceModule(shariah, address(0));

        vm.prank(shariah);
        vm.expectRevert("Governance: zero token");
        gov2.setGovernanceToken(address(0));
    }

    /// AUDIT FIX (P5-H-6): Token is immutable — test on fresh governance where token is not yet set.
    function test_setGovernanceToken_revertsIfNotIVotes() public {
        GovernanceModule gov2 = new GovernanceModule(shariah, address(0));

        vm.prank(shariah);
        vm.expectRevert("Governance: token must implement IVotes");
        gov2.setGovernanceToken(address(target));
    }

    function test_setGovernanceToken_revertsIfNotShariah() public {
        vm.prank(nobody);
        vm.expectRevert("Governance: not Shariah board");
        gov.setGovernanceToken(address(token));
    }

    // ══════════════════════════════════════════════════
    //              Full Lifecycle Tests
    // ══════════════════════════════════════════════════

    function test_lifecycle_proposeVoteQueueExecute() public {
        // 1. Propose
        vm.prank(proposer);
        uint256 pid = gov.propose(
            address(target),
            abi.encodeWithSelector(MockTarget.increment.selector),
            "Increment the counter"
        );
        assertEq(pid, 1);

        // 2. Vote (voter1 = 5%, voter2 = 2% -> 7% > 4% quorum)
        vm.prank(voter1);
        gov.castVote(pid, true);
        vm.prank(voter2);
        gov.castVote(pid, true);

        (uint256 vFor, uint256 vAgainst) = _votes(pid);
        assertEq(vFor, 7_000_000e18);
        assertEq(vAgainst, 0);

        // 3. Wait MIN_VOTING_PERIOD then queue
        uint256 t1 = block.timestamp + 48 hours;
        vm.warp(t1);
        gov.queue(pid);

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Queued));
        assertGt(_queuedAt(pid), 0);

        // 4. Wait TIMELOCK_DELAY then execute
        vm.warp(t1 + 48 hours);
        gov.execute(pid);

        assertEq(target.counter(), 1);
        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Executed));
    }

    function test_lifecycle_proposeVoteQueueVeto() public {
        uint256 pid = _proposeVoteAndQueue();

        // Veto within window (12h after queue)
        uint256 qa = _queuedAt(pid);
        vm.warp(qa + 12 hours);
        vm.prank(shariah);
        gov.vetoProposal(pid, "Shariah non-compliant after review");

        // Cannot execute
        vm.warp(qa + 60 hours);
        vm.expectRevert("Governance: not queued");
        gov.execute(pid);

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Vetoed));
        assertTrue(_vetoed(pid));
    }

    function test_lifecycle_proposeCancelCannotVote() public {
        uint256 pid = _propose();

        vm.prank(proposer);
        gov.cancel(pid);

        vm.prank(voter1);
        vm.expectRevert("Governance: not pending");
        gov.castVote(pid, true);
    }

    function test_lifecycle_multipleProposalsIndependent() public {
        uint256 pid1 = _propose();
        uint256 pid2 = _propose();
        assertEq(pid1, 1);
        assertEq(pid2, 2);

        vm.prank(voter1);
        gov.castVote(pid1, true);

        vm.prank(proposer);
        gov.cancel(pid2);

        uint256 t1 = block.timestamp + 48 hours;
        vm.warp(t1);
        gov.queue(pid1);
        vm.warp(t1 + 48 hours);
        gov.execute(pid1);

        assertEq(target.counter(), 1);
        assertEq(uint8(_status(pid1)), uint8(GovernanceModule.ProposalStatus.Executed));
        assertEq(uint8(_status(pid2)), uint8(GovernanceModule.ProposalStatus.Cancelled));
    }

    function test_lifecycle_executeAtExactTimelockBoundary() public {
        uint256 pid = _proposeVoteAndQueue();

        // AUDIT FIX (P4-A2-5): strict > means boundary is exclusive — must be 1s past T+72h
        vm.warp(block.timestamp + 72 hours + 1);
        gov.execute(pid);

        assertEq(target.counter(), 1);
    }

    function test_lifecycle_executeAtExactExpiryBoundary() public {
        uint256 pid = _proposeVoteAndQueue();

        uint256 qa = _queuedAt(pid);
        vm.warp(qa + 14 days);
        gov.execute(pid);

        assertEq(target.counter(), 1);
    }

    function test_lifecycle_vetoAtExactWindowBoundary() public {
        uint256 pid = _proposeVoteAndQueue();

        uint256 qa = _queuedAt(pid);
        vm.warp(qa + 48 hours);
        vm.prank(shariah);
        gov.vetoProposal(pid, "Last second veto");

        assertEq(uint8(_status(pid)), uint8(GovernanceModule.ProposalStatus.Vetoed));
    }
}
