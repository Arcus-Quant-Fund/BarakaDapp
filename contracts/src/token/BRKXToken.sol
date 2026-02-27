// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title BRKXToken
 * @author Baraka Protocol
 * @notice Governance and utility token for the Baraka Protocol.
 *
 * Properties:
 *   - Fixed supply: 100M BRKX minted once to treasury at deploy.
 *   - No further minting ever (no mint function).
 *   - Holders can burn their own tokens.
 *   - ERC20Votes: compatible with GovernanceModule on-chain voting.
 *   - ERC20Permit: gasless approvals (EIP-2612).
 *   - Ownable2Step: two-step ownership transfer for governance handover safety.
 *
 * Utility:
 *   - Holding BRKX in your wallet (no lock-up) reduces trading fees on
 *     PositionManager. Tiers: 1k / 10k / 50k BRKX (see PositionManager._collectFee).
 *   - Governance voting weight in GovernanceModule DAO track.
 *
 * Shariah note:
 *   - BRKX value derives from utility (fee discount) and governance rights — NOT
 *     from yield on capital. No riba element.
 *   - Fee discount = loyalty programme (permissible under AAOIFI standards).
 */
contract BRKXToken is ERC20, ERC20Votes, ERC20Permit, Ownable2Step {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 public constant MAX_SUPPLY = 100_000_000e18; // 100 million BRKX

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    /**
     * @param treasury Address that receives the full 100M supply at deployment.
     *                 On testnet: deployer address.
     *                 On mainnet: Baraka Protocol treasury multisig.
     */
    constructor(address treasury)
        ERC20("Baraka Token", "BRKX")
        ERC20Permit("Baraka Token")
        Ownable(treasury)
    {
        require(treasury != address(0), "BRKX: zero treasury");
        _mint(treasury, MAX_SUPPLY);
    }

    // ─────────────────────────────────────────────────────
    // Burn
    // ─────────────────────────────────────────────────────

    /**
     * @notice Burn `amount` of the caller's BRKX.
     *         Reduces total supply permanently.
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────
    // ERC20Votes overrides (required by OZ v5 multi-inheritance)
    // ─────────────────────────────────────────────────────

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
