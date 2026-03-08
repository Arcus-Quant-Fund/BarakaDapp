// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ILiquidationEngine
 * @notice Partial liquidation engine with three-tier cascade.
 *         Tier 1: Partial — reduce position to restore MMR.
 *         Tier 2: Full — close entire position, remaining collateral to InsuranceFund.
 *         Tier 3: ADL — auto-deleverage profitable opposing positions.
 */
interface ILiquidationEngine {
    /// @notice Liquidate a subaccount's position in a market.
    /// @param subaccount The subaccount to liquidate.
    /// @param marketId   The market to liquidate.
    /// @return sizeClosed The absolute size closed.
    /// @return pnlRealized The realized PnL (negative = loss to fund).
    function liquidate(bytes32 subaccount, bytes32 marketId) external returns (uint256 sizeClosed, int256 pnlRealized);

    /// @notice Check if a subaccount can be liquidated.
    function canLiquidate(bytes32 subaccount) external view returns (bool);
}
