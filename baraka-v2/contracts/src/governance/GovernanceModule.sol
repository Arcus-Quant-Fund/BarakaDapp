// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title GovernanceModule
 * @author Baraka Protocol v2
 * @notice Dual-track governance: technical DAO + Shariah board multisig.
 *
 *         Ported from v1 with all audit fixes preserved.
 *         Track 1: DAO proposals (token-weighted voting, 48h timelock)
 *         Track 2: Shariah board veto (3-of-5 multisig, irrevocable)
 *
 *         v2 additions:
 *         - Emergency pause for any risk module (Shariah board only)
 */
contract GovernanceModule is ReentrancyGuard {

    uint256 public constant TIMELOCK_DELAY = 48 hours;
    /// AUDIT FIX (GOV-M-1): Veto window exceeds timelock — Shariah board has buffer
    uint256 public constant VETO_WINDOW = 72 hours;
    uint256 public constant QUORUM_BPS = 400;       // 4%
    uint256 public constant MIN_VOTING_PERIOD = 48 hours;
    uint256 public constant PROPOSAL_EXPIRY = 14 days;
    /// AUDIT FIX (P12-GM-1): Maximum time after creation during which a proposal can be queued.
    /// Without this, a winning proposal could be queued months after the voting window closed.
    /// 14 days = 7-day voting window + 7-day buffer. Proposals not queued within this window expire.
    uint256 public constant QUEUE_DEADLINE = 14 days;
    uint256 public constant MIN_PROPOSER_BALANCE = 1e18;
    /// AUDIT FIX (GOV-H-3): Snapshot delay prevents 1-block flash loan governance attacks
    uint256 public constant SNAPSHOT_DELAY = 256;
    /// AUDIT FIX (GOV-H-2): Voting window — votes rejected after this period
    uint256 public constant MAX_VOTING_PERIOD = 7 days;

    enum ProposalStatus { Pending, Queued, Executed, Vetoed, Cancelled }

    struct Proposal {
        uint256     id;
        address     proposer;
        address     target;
        bytes       callData;
        string      description;
        uint256     votesFor;
        uint256     votesAgainst;
        uint256     createdAt;
        uint256     snapshotBlock;
        address     governanceTokenAtCreation;
        uint256     queuedAt;
        ProposalStatus status;
        bool        shariahVetoed;
    }

    address public shariahMultisig;
    address public pendingShariahMultisig;
    address public governanceToken;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event ProposalCreated(uint256 indexed id, address proposer, address target, string description);
    event VoteCast(uint256 indexed id, address voter, bool support, uint256 weight);
    event ProposalQueued(uint256 indexed id, uint256 eta);
    event ProposalExecuted(uint256 indexed id);
    event ProposalVetoed(uint256 indexed id, string reason);
    event ProposalCancelled(uint256 indexed id);
    event ShariahMultisigTransferInitiated(address indexed current, address indexed pending);
    event ShariahMultisigTransferred(address indexed oldMultisig, address indexed newMultisig);
    event GovernanceTokenSet(address indexed token);
    event EmergencyPaused(address indexed target, address indexed caller);
    event EmergencyUnpaused(address indexed target, address indexed caller);

    modifier onlyShariahMultisig() {
        require(msg.sender == shariahMultisig, "Governance: not Shariah board");
        _;
    }

    constructor(address _shariahMultisig, address _governanceToken) {
        require(_shariahMultisig != address(0), "Governance: zero multisig");
        shariahMultisig = _shariahMultisig;
        governanceToken = _governanceToken;
    }

    function propose(
        address target,
        bytes calldata callData,
        string calldata description
    ) external returns (uint256 proposalId) {
        require(target != address(0), "Governance: zero target");
        require(target != address(this), "Governance: self-call forbidden");
        require(bytes(description).length > 0, "Governance: empty description");

        proposalId = ++proposalCount;
        require(governanceToken != address(0), "Governance: token not set");

        // AUDIT FIX (GOV-H-3): Use SNAPSHOT_DELAY to prevent flash-loan governance attack
        // Graceful fallback for early blocks (testnet/fresh chain) — uses block 0 if too early
        uint256 snapshotBlk = block.number > SNAPSHOT_DELAY ? block.number - SNAPSHOT_DELAY : 0;
        {
            uint256 proposerBalance = IVotes(governanceToken).getPastVotes(msg.sender, snapshotBlk);
            require(proposerBalance >= MIN_PROPOSER_BALANCE, "Governance: insufficient proposer balance");
        }

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            target: target,
            callData: callData,
            description: description,
            votesFor: 0,
            votesAgainst: 0,
            createdAt: block.timestamp,
            snapshotBlock: snapshotBlk,
            governanceTokenAtCreation: governanceToken,
            queuedAt: 0,
            status: ProposalStatus.Pending,
            shariahVetoed: false
        });

        emit ProposalCreated(proposalId, msg.sender, target, description);
    }

    function castVote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        address token = p.governanceTokenAtCreation;
        require(token != address(0), "Governance: token not set");
        require(p.status == ProposalStatus.Pending, "Governance: not pending");
        // AUDIT FIX (GOV-H-2): Enforce voting deadline — prevents indefinite vote accumulation
        require(block.timestamp <= p.createdAt + MAX_VOTING_PERIOD, "Governance: voting period ended");
        require(!hasVoted[proposalId][msg.sender], "Governance: already voted");

        uint256 weight = IVotes(token).getPastVotes(msg.sender, p.snapshotBlock);
        require(weight > 0, "Governance: zero weight");

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function queue(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Pending, "Governance: not pending");
        require(p.votesFor > p.votesAgainst, "Governance: did not pass");

        address token = p.governanceTokenAtCreation;
        require(token != address(0), "Governance: no governance token");
        {
            uint256 totalSupply = IVotes(token).getPastTotalSupply(p.snapshotBlock);
            uint256 totalVotes = p.votesFor + p.votesAgainst;
            require(totalVotes * 10_000 >= totalSupply * QUORUM_BPS, "Governance: quorum not reached");
        }

        require(block.timestamp >= p.createdAt + MIN_VOTING_PERIOD, "Governance: voting period not over");
        /// AUDIT FIX (P12-GM-1): Proposals must be queued within QUEUE_DEADLINE of creation.
        require(block.timestamp <= p.createdAt + QUEUE_DEADLINE, "Governance: queue deadline passed");

        p.status = ProposalStatus.Queued;
        p.queuedAt = block.timestamp;

        emit ProposalQueued(proposalId, block.timestamp + TIMELOCK_DELAY);
    }

    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Queued, "Governance: not queued");
        // AUDIT FIX (P3-CROSS-1): Execution must wait until BOTH the timelock AND the veto window
        // have fully elapsed. Previously execution was allowed at T+48h while the Shariah board's
        // veto window remained open until T+72h, allowing proposals to be executed before they
        // could be vetoed. Use the larger of the two delays as the effective execution delay.
        // AUDIT FIX (P4-A2-5): Use strict > instead of >= to close the exact-boundary race condition.
        // With >=, both execute() and vetoProposal() are valid at block.timestamp == T+72h,
        // allowing execution and veto to race in the same block with outcome determined by tx ordering.
        // Strict > ensures execution is only possible after the full veto window has completely closed.
        {
            uint256 execDelay = TIMELOCK_DELAY > VETO_WINDOW ? TIMELOCK_DELAY : VETO_WINDOW;
            require(block.timestamp > p.queuedAt + execDelay, "GM: timelock not elapsed");
        }
        require(block.timestamp <= p.queuedAt + PROPOSAL_EXPIRY, "Governance: proposal expired");
        require(!p.shariahVetoed, "Governance: vetoed by Shariah board");

        p.status = ProposalStatus.Executed;

        // AUDIT FIX (GOV-H-1): Was draining ALL ETH on every execution. Use value: 0.
        /// AUDIT FIX (P19-L-7): Bubble up raw revert data instead of garbling custom errors.
        /// Previously used `string(abi.encodePacked("...", err))` which produces garbage for
        /// ABI-encoded custom errors. Now re-throws the exact revert data from the target.
        (bool ok, bytes memory returnData) = p.target.call{value: 0}(p.callData);
        if (!ok) {
            if (returnData.length > 0) {
                assembly { revert(add(returnData, 32), mload(returnData)) }
            } else {
                revert("Governance: execution failed");
            }
        }

        emit ProposalExecuted(proposalId);
    }

    function vetoProposal(uint256 proposalId, string calldata reason) external onlyShariahMultisig {
        Proposal storage p = proposals[proposalId];
        require(
            p.status == ProposalStatus.Pending || p.status == ProposalStatus.Queued,
            "Governance: cannot veto"
        );
        if (p.status == ProposalStatus.Queued) {
            require(block.timestamp <= p.queuedAt + VETO_WINDOW, "Governance: veto window expired");
        }

        p.shariahVetoed = true;
        p.status = ProposalStatus.Vetoed;

        emit ProposalVetoed(proposalId, reason);
    }

    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.proposer == msg.sender, "Governance: not proposer");
        require(p.status == ProposalStatus.Pending, "Governance: not pending");
        p.status = ProposalStatus.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    // ─────────────────────────────────────────────────────
    // v2: Shariah board emergency pause (no DAO vote needed)
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P5-H-7): Whitelist of pausable targets — prevents Shariah multisig from
    /// calling pause() on arbitrary contracts (a compromised multisig could deploy a malicious
    /// contract with a pause() function that performs arbitrary actions as GovernanceModule).
    mapping(address => bool) public pausableTargets;
    event PausableTargetSet(address indexed target, bool allowed);

    function setPausableTarget(address target, bool allowed) external onlyShariahMultisig {
        require(target != address(0), "Governance: zero target");
        pausableTargets[target] = allowed;
        emit PausableTargetSet(target, allowed);
    }

    /// @notice Emergency pause any whitelisted Pausable contract. Shariah board only.
    /// AUDIT FIX (P16-RE-L1): Added nonReentrant — these make arbitrary .call() to targets.
    function emergencyPause(address target) external onlyShariahMultisig nonReentrant {
        require(target != address(0), "Governance: zero target");
        require(pausableTargets[target], "Governance: target not whitelisted");
        (bool ok,) = target.call(abi.encodeWithSignature("pause()"));
        require(ok, "Governance: pause failed");
        emit EmergencyPaused(target, msg.sender);
    }

    /// AUDIT FIX (GOV-M-2): Emergency unpause — prevents accidental pause requiring 96h+ to reverse
    /// AUDIT FIX (P16-RE-L1): Added nonReentrant — these make arbitrary .call() to targets.
    function emergencyUnpause(address target) external onlyShariahMultisig nonReentrant {
        require(target != address(0), "Governance: zero target");
        require(pausableTargets[target], "Governance: target not whitelisted");
        (bool ok,) = target.call(abi.encodeWithSignature("unpause()"));
        require(ok, "Governance: unpause failed");
        emit EmergencyUnpaused(target, msg.sender);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function transferShariahMultisig(address newMultisig) external onlyShariahMultisig {
        require(newMultisig != address(0), "Governance: zero address");
        pendingShariahMultisig = newMultisig;
        emit ShariahMultisigTransferInitiated(shariahMultisig, newMultisig);
    }

    function acceptShariahMultisig() external {
        require(msg.sender == pendingShariahMultisig, "Governance: not pending multisig");
        emit ShariahMultisigTransferred(shariahMultisig, pendingShariahMultisig);
        shariahMultisig = pendingShariahMultisig;
        pendingShariahMultisig = address(0);
    }

    /// AUDIT FIX (P5-H-6): Governance token is immutable after initial setup.
    /// Previously, Shariah multisig could replace the token with one where the attacker holds
    /// 100% of votes, collapsing the dual-track governance design. Now can only be set once.
    /// AUDIT FIX (P5-M-19): Removed unbounded loop over all proposals (DoS after thousands).
    function setGovernanceToken(address token) external onlyShariahMultisig {
        require(token != address(0), "Governance: zero token");
        require(governanceToken == address(0), "Governance: token already set (immutable)");
        uint256 checkBlock = block.number > 0 ? block.number - 1 : 0;
        try IVotes(token).getPastVotes(address(this), checkBlock) returns (uint256) {
        } catch {
            revert("Governance: token must implement IVotes");
        }
        governanceToken = token;
        emit GovernanceTokenSet(token);
    }

    /// @dev INFO (L5-I-2): No delegation incentive by design — voting power is its own incentive.
    ///      Vote escrow (veBRKX) is a future enhancement.
    /// @dev INFO (L5-I-3): Single-action proposals by design — batch proposals add complexity
    ///      and make Shariah board veto granularity harder. Multi-action via separate proposals.
    /// AUDIT FIX (P5-M-12): Reject ETH — execute() uses value:0, so ETH is permanently locked.
    receive() external payable {
        revert("Governance: no ETH");
    }
}
