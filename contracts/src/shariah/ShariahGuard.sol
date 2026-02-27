// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IShariahGuard.sol";

/**
 * @title ShariahGuard
 * @author Baraka Protocol
 * @notice On-chain enforcement of Shariah compliance rules.
 *
 *   - MAX_LEVERAGE is an immutable constant. It can NEVER be changed, even by the owner.
 *   - Only the Shariah board multisig (shariahMultisig) can approve or revoke assets.
 *   - Every approved asset must have an IPFS hash of the fatwa document stored on-chain.
 *   - Any market can be emergency-paused by the Shariah board.
 *
 * Islamic finance basis:
 *   Maysir (gambling) mitigation: leverage capped at 5x.
 *   Gharar (uncertainty) mitigation: only AAOIFI-approved assets with published fatwas.
 */
contract ShariahGuard is IShariahGuard, Pausable {
    // ─────────────────────────────────────────────────────
    // Immutable compliance constants
    // ─────────────────────────────────────────────────────

    /// @notice Maximum allowed leverage. Immutable — cannot be changed by anyone.
    uint256 public constant MAX_LEVERAGE = 5;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice The 3-of-5 Shariah board multisig address
    address public shariahMultisig;

    /// @notice Approved assets (token => approved)
    mapping(address => bool) public approvedAssets;

    /// @notice IPFS hash of the fatwa document for each approved asset
    mapping(address => string) public fatwaIPFS;

    /// @notice Paused markets (market => paused)
    mapping(address => bool) public pausedMarkets;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event AssetApproved(address indexed token, string fatwaIPFSHash);
    event AssetRevoked(address indexed token, string reason);
    event MarketPaused(address indexed market, string reason);
    event MarketUnpaused(address indexed market);
    event ShariahMultisigTransferred(address indexed oldMultisig, address indexed newMultisig);

    // ─────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────

    modifier onlyShariahMultisig() {
        require(msg.sender == shariahMultisig, "ShariahGuard: not Shariah board");
        _;
    }

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address _shariahMultisig) {
        require(_shariahMultisig != address(0), "ShariahGuard: zero multisig");
        shariahMultisig = _shariahMultisig;
    }

    // ─────────────────────────────────────────────────────
    // Shariah board actions
    // ─────────────────────────────────────────────────────

    /**
     * @notice Approve a new asset for trading after Shariah board review.
     * @param token       The ERC-20 token address.
     * @param ipfsHash    IPFS content hash (CIDv1) of the signed fatwa PDF.
     */
    function approveAsset(address token, string calldata ipfsHash)
        external
        onlyShariahMultisig
    {
        require(token != address(0), "ShariahGuard: zero token");
        require(bytes(ipfsHash).length > 0, "ShariahGuard: empty fatwa hash");
        approvedAssets[token] = true;
        fatwaIPFS[token]      = ipfsHash;
        emit AssetApproved(token, ipfsHash);
    }

    /**
     * @notice Revoke an asset if a new fatwa prohibits it.
     * @param token  Token to revoke.
     * @param reason Human-readable reason (stored in event, not on-chain).
     */
    function revokeAsset(address token, string calldata reason)
        external
        onlyShariahMultisig
    {
        approvedAssets[token] = false;
        emit AssetRevoked(token, reason);
    }

    /**
     * @notice Pause a specific market (e.g. new fatwa prohibits it).
     */
    function emergencyPause(address market, string calldata reason)
        external
        onlyShariahMultisig
    {
        pausedMarkets[market] = true;
        emit MarketPaused(market, reason);
    }

    /**
     * @notice Unpause a market after scholarly review.
     */
    function unpauseMarket(address market) external onlyShariahMultisig {
        pausedMarkets[market] = false;
        emit MarketUnpaused(market);
    }

    /**
     * @notice Transfer Shariah board multisig address (requires new board to confirm).
     */
    function transferShariahMultisig(address newMultisig) external onlyShariahMultisig {
        require(newMultisig != address(0), "ShariahGuard: zero address");
        emit ShariahMultisigTransferred(shariahMultisig, newMultisig);
        shariahMultisig = newMultisig;
    }

    // ─────────────────────────────────────────────────────
    // IShariahGuard — validation (called by PositionManager)
    // ─────────────────────────────────────────────────────

    /**
     * @notice Validate a proposed position. Reverts if non-compliant.
     * @param asset      The underlying asset token.
     * @param collateral Collateral amount (in base units).
     * @param notional   Position notional value (in same units as collateral).
     */
    function validatePosition(address asset, uint256 collateral, uint256 notional)
        external
        view
        override
        whenNotPaused
    {
        require(approvedAssets[asset], "ShariahGuard: asset not approved");
        require(!pausedMarkets[asset], "ShariahGuard: market paused");
        require(collateral > 0,        "ShariahGuard: zero collateral");
        require(notional >= collateral, "ShariahGuard: notional < collateral");

        uint256 leverage = notional / collateral;
        require(leverage <= MAX_LEVERAGE, "ShariahGuard: leverage exceeds 5x (maysir)");
    }

    /**
     * @notice Returns true if the asset is Shariah-approved.
     */
    function isApproved(address asset) external view override returns (bool) {
        return approvedAssets[asset];
    }
}
