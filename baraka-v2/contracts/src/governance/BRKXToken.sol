// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title BRKXToken
 * @author Baraka Protocol v2
 * @notice Governance and utility token. Fixed 100M supply, ERC20Votes.
 *
 *         Identical to v1 — no changes needed for v2 integration.
 *         - Fee discount tiers via FeeEngine
 *         - Governance voting via GovernanceModule
 *         - Burn function for deflationary tokenomics
 *
 *         Shariah: value derives from utility (fee discount) + governance, not yield.
 */
contract BRKXToken is ERC20, ERC20Votes, ERC20Permit, Ownable2Step {

    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    constructor(address treasury)
        ERC20("Baraka Token", "BRKX")
        ERC20Permit("Baraka Token")
        Ownable(treasury)
    {
        require(treasury != address(0), "BRKX: zero treasury");
        _mint(treasury, MAX_SUPPLY);
    }

    /// @dev INFO (L5-I-1): No mint function by design — fixed 100M supply, deflationary via burn only.
    ///      Shariah: value derives from utility (fee discount) + governance, not inflationary yield.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function renounceOwnership() public pure override {
        revert("BRKXToken: renounce disabled");
    }

    function _update(address from, address to, uint256 value)
        internal override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public view override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
