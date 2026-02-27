// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GovernanceModule
 * @author Baraka Protocol
 * @notice Dual-track governance: technical DAO + Shariah board multisig.
 *
 *   Track 1 — Technical DAO:
 *     Token holders vote on technical parameters (fees, risk params, upgrades).
 *     Proposals require 48-hour timelock before execution.
 *     Simple majority (> 50% of participating votes) passes.
 *
 *   Track 2 — Shariah Board:
 *     3-of-5 multisig of AAOIFI-certified scholars.
 *     Has VETO power over any DAO proposal.
 *     Can unilaterally pause markets (ShariahGuard.emergencyPause).
 *     Cannot be overridden by token holders under any circumstances.
 *
 * This design ensures:
 *   - Shariah compliance cannot be voted away by token holders.
 *   - Technical parameters remain community-governed.
 *   - Full transparency: all proposals and votes are on-chain.
 */
contract GovernanceModule is ReentrancyGuard {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 public constant TIMELOCK_DELAY   = 48 hours;
    uint256 public constant VETO_WINDOW      = 48 hours; // Shariah board veto window

    // ─────────────────────────────────────────────────────
    // Structs
    // ─────────────────────────────────────────────────────

    enum ProposalStatus { Pending, Queued, Executed, Vetoed, Cancelled }

    struct Proposal {
        uint256     id;
        address     proposer;
        address     target;       // contract to call
        bytes       callData;     // encoded function call
        string      description;
        uint256     votesFor;
        uint256     votesAgainst;
        uint256     createdAt;
        uint256     queuedAt;     // 0 if not yet queued
        ProposalStatus status;
        bool        shariahVetoed;
    }

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    address public shariahMultisig;
    address public governanceToken; // ERC-20 voting token (set post-deploy)

    uint256 public proposalCount;
    mapping(uint256 => Proposal)         public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event ProposalCreated(uint256 indexed id, address proposer, address target, string description);
    event VoteCast(uint256 indexed id, address voter, bool support, uint256 weight);
    event ProposalQueued(uint256 indexed id, uint256 eta);
    event ProposalExecuted(uint256 indexed id);
    event ProposalVetoed(uint256 indexed id, string reason);
    event ProposalCancelled(uint256 indexed id);
    event ShariahMultisigTransferred(address oldMultisig, address newMultisig);

    // ─────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────

    modifier onlyShariahMultisig() {
        require(msg.sender == shariahMultisig, "Governance: not Shariah board");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address _shariahMultisig, address _governanceToken) {
        require(_shariahMultisig  != address(0), "Governance: zero multisig");
        shariahMultisig  = _shariahMultisig;
        governanceToken  = _governanceToken; // can be address(0) initially
    }

    // ─────────────────────────────────────────────────────
    // Track 1 — DAO proposals
    // ─────────────────────────────────────────────────────

    /**
     * @notice Create a new governance proposal.
     * @param target      Contract to call if proposal passes.
     * @param callData    ABI-encoded function call.
     * @param description Human-readable description of the proposal.
     */
    function propose(
        address target,
        bytes calldata callData,
        string calldata description
    ) external returns (uint256 proposalId) {
        require(target != address(0),       "Governance: zero target");
        require(bytes(description).length > 0, "Governance: empty description");

        proposalId = ++proposalCount;
        proposals[proposalId] = Proposal({
            id:            proposalId,
            proposer:      msg.sender,
            target:        target,
            callData:      callData,
            description:   description,
            votesFor:      0,
            votesAgainst:  0,
            createdAt:     block.timestamp,
            queuedAt:      0,
            status:        ProposalStatus.Pending,
            shariahVetoed: false
        });

        emit ProposalCreated(proposalId, msg.sender, target, description);
    }

    /**
     * @notice Cast a vote on a pending proposal.
     * @param proposalId  The proposal to vote on.
     * @param support     True = for, False = against.
     * @param weight      Voting weight (simplified — production uses token balance snapshot).
     */
    function castVote(uint256 proposalId, bool support, uint256 weight) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Pending, "Governance: not pending");
        require(!hasVoted[proposalId][msg.sender],  "Governance: already voted");
        require(weight > 0,                         "Governance: zero weight");

        hasVoted[proposalId][msg.sender] = true;

        if (support) {
            p.votesFor += weight;
        } else {
            p.votesAgainst += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Queue a proposal for execution after the timelock.
     *         Requires more votes for than against.
     */
    function queue(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Pending, "Governance: not pending");
        require(p.votesFor > p.votesAgainst,        "Governance: did not pass");

        p.status   = ProposalStatus.Queued;
        p.queuedAt = block.timestamp;

        emit ProposalQueued(proposalId, block.timestamp + TIMELOCK_DELAY);
    }

    /**
     * @notice Execute a queued proposal after the timelock and veto window.
     */
    function execute(uint256 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        require(p.status == ProposalStatus.Queued,                             "Governance: not queued");
        require(block.timestamp >= p.queuedAt + TIMELOCK_DELAY,                "Governance: timelock active");
        require(!p.shariahVetoed,                                              "Governance: vetoed by Shariah board");

        p.status = ProposalStatus.Executed;

        (bool ok, bytes memory err) = p.target.call(p.callData);
        require(ok, string(abi.encodePacked("Governance: execution failed: ", err)));

        emit ProposalExecuted(proposalId);
    }

    // ─────────────────────────────────────────────────────
    // Track 2 — Shariah board veto
    // ─────────────────────────────────────────────────────

    /**
     * @notice Veto a queued proposal. Only the Shariah board can call this.
     *         Can be exercised at any time before execution.
     *         This power cannot be removed or limited by the DAO.
     *
     * @param proposalId The proposal to veto.
     * @param reason     Human-readable veto reason (stored in event).
     */
    function vetoProposal(uint256 proposalId, string calldata reason)
        external
        onlyShariahMultisig
    {
        Proposal storage p = proposals[proposalId];
        require(
            p.status == ProposalStatus.Pending || p.status == ProposalStatus.Queued,
            "Governance: cannot veto"
        );

        p.shariahVetoed = true;
        p.status        = ProposalStatus.Vetoed;

        emit ProposalVetoed(proposalId, reason);
    }

    /**
     * @notice Cancel a proposal (proposer only).
     */
    function cancel(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.proposer == msg.sender,           "Governance: not proposer");
        require(p.status == ProposalStatus.Pending, "Governance: not pending");
        p.status = ProposalStatus.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function transferShariahMultisig(address newMultisig) external onlyShariahMultisig {
        require(newMultisig != address(0), "Governance: zero address");
        emit ShariahMultisigTransferred(shariahMultisig, newMultisig);
        shariahMultisig = newMultisig;
    }

    function setGovernanceToken(address token) external onlyShariahMultisig {
        governanceToken = token;
    }
}
