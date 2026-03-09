// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IInsuranceFund
 * @notice Socialises shortfall losses via Tabarru (voluntary contribution).
 */
interface IInsuranceFund {
    /// @notice Receive funds (from fees, liquidation penalties).
    function receive_(address token, uint256 amount) external;

    /// @notice Cover a shortfall from an underwater liquidation.
    /// @return actualCovered Amount actually socialized (may be less than `amount` due to per-event cap).
    function coverShortfall(address token, uint256 amount) external returns (uint256 actualCovered);

    /// @notice Pay profit to a recipient (for PnL settlement when counterparty can't pay).
    function payPnl(address token, uint256 amount, address recipient) external;

    /// @notice Current fund balance for a token.
    function fundBalance(address token) external view returns (uint256);
}
