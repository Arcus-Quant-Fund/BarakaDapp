// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IFeeEngine
 * @notice Maker-taker fee model with BRKX discount tiers.
 */
interface IFeeEngine {
    struct FeeTier {
        uint256 minBRKX;     // minimum BRKX balance for this tier
        uint256 takerFeeBps; // taker fee in WAD scale (e.g. 5e14 = 5 bps)
        uint256 makerFeeBps; // maker rebate in WAD scale (e.g. 5e13 = 0.5 bps)
    }

    /// @notice Compute taker fee for a fill.
    /// @return fee The fee amount in WAD (positive = charge)
    function computeTakerFee(bytes32 subaccount, uint256 notional) external view returns (uint256 fee);

    /// @notice Compute maker rebate for a fill.
    /// @return rebate The rebate amount in WAD (positive = pay to maker)
    function computeMakerRebate(bytes32 subaccount, uint256 notional) external view returns (uint256 rebate);

    /// @notice Charge taker fee from subaccount, splitting to treasury/insurance/stakers.
    function chargeTakerFee(bytes32 subaccount, uint256 notional) external returns (uint256 fee);

    /// @notice Pay maker rebate to subaccount.
    function payMakerRebate(bytes32 subaccount, uint256 notional) external returns (uint256 rebate);

    /// @notice Process trade fees atomically: charge taker, rebate maker from collected fees.
    ///         AUDIT FIX (L1B-H-3): Replaces separate chargeTakerFee + payMakerRebate
    ///         which created unbacked phantom balance via settlePnL.
    function processTradeFees(bytes32 takerSubaccount, bytes32 makerSubaccount, uint256 notional) external;
}
