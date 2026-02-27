// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAdapter {
    function getIndexPrice(address asset) external view returns (uint256);
    function getMarkPrice(address asset, uint256 twapWindow) external view returns (uint256);

    /// @notice Current premium F = (mark − index) / index (1e18 scale, signed).
    ///         Positive = perpetual at premium (longs pay). Negative = at discount (shorts pay).
    function getPremium(address asset) external view returns (int256 premium);

    /// @notice κ-convergence signal derived from TWAP history.
    /// @return kappa   Rate of basis convergence per second (1e18 scale).
    ///                 Positive → basis shrinking (healthy). Negative → basis growing (risk).
    /// @return premium Current F = (mark − index) / index (1e18 scale).
    /// @return regime  Risk tier: 0=NORMAL(<15bps) 1=ELEVATED(15-40bps) 2=HIGH(40-60bps) 3=CRITICAL(≥60bps)
    function getKappaSignal(address asset)
        external view
        returns (int256 kappa, int256 premium, uint8 regime);
}
