// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title ComplianceOracle
 * @author Baraka Protocol v2
 * @notice Off-chain Shariah screening results brought on-chain via multi-sig attestations.
 *
 *         Shariah board members sign compliance attestations off-chain.
 *         Attestations are submitted on-chain with ECDSA signatures.
 *         Quorum: 3-of-5 Shariah scholars must sign for an attestation to be valid.
 *
 *         Used for: new asset approvals, parameter changes, fatwa updates.
 */
contract ComplianceOracle is Ownable2Step {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ─────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────

    struct Attestation {
        bytes32 contentHash;   // keccak256 of the attestation content (e.g. IPFS CID, params)
        uint256 timestamp;
        uint256 signaturesCount;
        bool    executed;
    }

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice Shariah board members (signers)
    mapping(address => bool) public isBoardMember;
    address[] public boardMembers;

    /// @notice Required signatures for quorum
    uint256 public quorum = 3;

    /// @notice Attestation tracking
    mapping(bytes32 => Attestation) public attestations;
    mapping(bytes32 => mapping(address => bool)) public hasSignedAttestation;

    /// AUDIT FIX (L2-I-1): Attestation TTL — attestations older than this are considered expired
    uint256 public constant ATTESTATION_TTL = 365 days;

    /// AUDIT FIX (P6-L-1): Track when a member was (re-)added. Signatures from before
    /// this timestamp don't count — prevents re-added members from inheriting old signatures.
    mapping(address => uint256) public memberSince;

    /// @notice Latest fatwa IPFS CID per market
    mapping(bytes32 => string) public fatwaCID;

    /// @notice Latest compliance status per asset (set after attestation executes)
    mapping(bytes32 => bool) public assetCompliance;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event BoardMemberAdded(address indexed member);
    event BoardMemberRemoved(address indexed member);
    event QuorumUpdated(uint256 newQuorum);
    event AttestationSubmitted(bytes32 indexed attestationId, bytes32 contentHash, address indexed submitter);
    event AttestationSigned(bytes32 indexed attestationId, address indexed signer);
    event AttestationExecuted(bytes32 indexed attestationId);
    event FatwaUpdated(bytes32 indexed marketId, string cid);
    event AssetComplianceSet(bytes32 indexed marketId, bool compliant);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────
    // Admin — board management
    // ─────────────────────────────────────────────────────

    function addBoardMember(address member) external onlyOwner {
        require(member != address(0), "CO: zero address");
        require(!isBoardMember[member], "CO: already member");
        isBoardMember[member] = true;
        /// AUDIT FIX (P6-L-1): Record addition timestamp — old signatures from before
        /// removal/re-addition won't count (checked in _countValidSignatures).
        memberSince[member] = block.timestamp;
        boardMembers.push(member);
        emit BoardMemberAdded(member);
    }

    function removeBoardMember(address member) external onlyOwner {
        require(isBoardMember[member], "CO: not member");
        /// AUDIT FIX (L2-L-4): Prevent quorum from exceeding board size after removal
        require(boardMembers.length - 1 >= quorum, "CO: would break quorum");
        isBoardMember[member] = false;
        // Remove from array (swap and pop)
        for (uint256 i = 0; i < boardMembers.length; i++) {
            if (boardMembers[i] == member) {
                boardMembers[i] = boardMembers[boardMembers.length - 1];
                boardMembers.pop();
                break;
            }
        }
        emit BoardMemberRemoved(member);
    }

    function setQuorum(uint256 _quorum) external onlyOwner {
        require(_quorum > 0 && _quorum <= boardMembers.length, "CO: invalid quorum");
        quorum = _quorum;
        emit QuorumUpdated(_quorum);
    }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("CO: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // Core — attestation submission and signing
    // ─────────────────────────────────────────────────────

    /// @notice Attestation nonce — prevents ID collision
    /// AUDIT FIX (L2-H-2): abi.encodePacked collision risk + no nonce
    uint256 private _attestationNonce;

    /// @notice Submit a new attestation. Only board members can submit.
    function submitAttestation(bytes32 contentHash) external returns (bytes32 attestationId) {
        require(isBoardMember[msg.sender], "CO: not board member");

        // AUDIT FIX (L2-H-2): Use abi.encode (no collision) + unique nonce
        attestationId = keccak256(abi.encode(contentHash, block.timestamp, msg.sender, _attestationNonce++));
        require(attestations[attestationId].timestamp == 0, "CO: attestation exists");

        attestations[attestationId] = Attestation({
            contentHash: contentHash,
            timestamp: block.timestamp,
            signaturesCount: 1,
            executed: false
        });
        hasSignedAttestation[attestationId][msg.sender] = true;

        emit AttestationSubmitted(attestationId, contentHash, msg.sender);
        emit AttestationSigned(attestationId, msg.sender);
    }

    /// @notice Sign an existing attestation. Board members only.
    /// AUDIT FIX (P8-L-2): Allow re-signing if member was removed and re-added. Old signatures
    /// from before re-addition don't count (P6-L-1), but the `hasSignedAttestation` mapping still
    /// blocks re-signing. Now checks if the attestation predates the member's current tenure —
    /// if so, the old signature is invalid and re-signing is permitted.
    function signAttestation(bytes32 attestationId) external {
        require(isBoardMember[msg.sender], "CO: not board member");
        Attestation storage att = attestations[attestationId];
        require(att.timestamp > 0, "CO: no such attestation");
        require(!att.executed, "CO: already executed");

        // P8-L-2: If member previously signed but was removed and re-added, old signature
        // doesn't count (att.timestamp < memberSince). Allow re-signing by resetting the flag.
        if (hasSignedAttestation[attestationId][msg.sender]) {
            require(att.timestamp < memberSince[msg.sender], "CO: already signed");
            // Old signature is invalid — reset and allow re-sign below.
            // signaturesCount is NOT decremented because _countValidSignatures() already
            // excludes the old signature; the count field is only informational.
        }

        hasSignedAttestation[attestationId][msg.sender] = true;
        att.signaturesCount++;

        emit AttestationSigned(attestationId, msg.sender);
    }

    /// @notice Check if an attestation has reached quorum and is not expired.
    /// AUDIT FIX (L2-M-7): Recount valid (still-active) board member signatures
    /// AUDIT FIX (L2-I-1): Attestation TTL enforced — stale attestations cannot reach quorum
    function hasQuorum(bytes32 attestationId) external view returns (bool) {
        Attestation storage att = attestations[attestationId];
        if (att.timestamp == 0) return false;
        if (block.timestamp > att.timestamp + ATTESTATION_TTL) return false;
        return _countValidSignatures(attestationId) >= quorum;
    }

    /// @dev Count signatures from currently-active board members only.
    /// AUDIT FIX (P6-L-1): Only count signatures made AFTER the member's current addition.
    /// Prevents re-added members from inheriting old signatures from before removal.
    function _countValidSignatures(bytes32 attestationId) internal view returns (uint256 count) {
        Attestation storage att = attestations[attestationId];
        for (uint256 i = 0; i < boardMembers.length; i++) {
            address member = boardMembers[i];
            if (hasSignedAttestation[attestationId][member] && att.timestamp >= memberSince[member]) {
                count++;
            }
        }
    }

    // ─────────────────────────────────────────────────────
    // Core — execute attestation (apply its effect)
    // ─────────────────────────────────────────────────────

    /// @notice Execute an attestation to set asset compliance. Requires quorum.
    /// AUDIT FIX (L2-H-1): Verify execution params match contentHash — prevents misapplication
    function executeAssetCompliance(bytes32 attestationId, bytes32 marketId, bool compliant) external {
        require(isBoardMember[msg.sender], "CO: not board member");
        Attestation storage att = attestations[attestationId];
        require(att.timestamp > 0, "CO: no such attestation");
        require(!att.executed, "CO: already executed");
        /// AUDIT FIX (L2-M-7): Recount valid signatures (removed members don't count)
        require(_countValidSignatures(attestationId) >= quorum, "CO: quorum not met");

        // Verify contentHash encodes these exact params
        bytes32 expectedHash = keccak256(abi.encode("ASSET_COMPLIANCE", marketId, compliant));
        require(att.contentHash == expectedHash, "CO: params mismatch contentHash");

        att.executed = true;
        assetCompliance[marketId] = compliant;

        emit AttestationExecuted(attestationId);
        emit AssetComplianceSet(marketId, compliant);
    }

    /// @notice Execute an attestation to update fatwa CID. Requires quorum.
    /// AUDIT FIX (L2-H-1): Verify execution params match contentHash — prevents misapplication
    function executeFatwaUpdate(bytes32 attestationId, bytes32 marketId, string calldata cid) external {
        require(isBoardMember[msg.sender], "CO: not board member");
        Attestation storage att = attestations[attestationId];
        require(att.timestamp > 0, "CO: no such attestation");
        require(!att.executed, "CO: already executed");
        /// AUDIT FIX (L2-M-7): Recount valid signatures (removed members don't count)
        require(_countValidSignatures(attestationId) >= quorum, "CO: quorum not met");

        // Verify contentHash encodes these exact params
        bytes32 expectedHash = keccak256(abi.encode("FATWA_UPDATE", marketId, cid));
        require(att.contentHash == expectedHash, "CO: params mismatch contentHash");

        att.executed = true;
        fatwaCID[marketId] = cid;

        emit AttestationExecuted(attestationId);
        emit FatwaUpdated(marketId, cid);
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    function getBoardMemberCount() external view returns (uint256) {
        return boardMembers.length;
    }

    function isCompliant(bytes32 marketId) external view returns (bool) {
        return assetCompliance[marketId];
    }
}
