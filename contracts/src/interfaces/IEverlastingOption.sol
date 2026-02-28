// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IEverlastingOption
 * @author Baraka Protocol
 * @notice Interface for the EverlastingOption pricer (Ackerer, Hugonnier & Jermann 2024, Prop. 6 at ι=0).
 *
 * Used by TakafulPool, PerpetualSukuk, and iCDS to obtain risk-neutral pricing
 * of everlasting options with zero interest parameter (ι=0, Shariah-compliant).
 */
interface IEverlastingOption {

    /// @notice Everlasting put price Π_put(x, K) at ι=0.
    ///         Economic interpretation: fair tabarru for floor protection.
    ///         Returns a dimensionless WAD ratio: price per 1 unit of coverage.
    function quotePut(address asset, uint256 xWad, uint256 kWad)
        external view returns (uint256 putPriceWad);

    /// @notice Everlasting call price Π_call(x, K) at ι=0.
    ///         Economic interpretation: fair price for upside participation above K.
    ///         Returns a dimensionless WAD ratio: price per 1 unit of notional.
    function quoteCall(address asset, uint256 xWad, uint256 kWad)
        external view returns (uint256 callPriceWad);

    /// @notice Quote both options at the current oracle spot for strike kWad.
    function quoteAtSpot(address asset, uint256 kWad)
        external view returns (
            uint256 putPriceWad,
            uint256 callPriceWad,
            uint256 spotWad,
            uint256 kappaWad,
            int256  betaNegWad,
            int256  betaPosWad
        );

    /// @notice β exponents: β₋ (negative root), β₊ (> 1), denominator (β₊ − β₋).
    ///         Useful for off-chain display and calibration.
    function getExponents(address asset)
        external view returns (int256 betaNegWad, int256 betaPosWad, uint256 denomWad);
}
