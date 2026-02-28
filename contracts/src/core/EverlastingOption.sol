// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title EverlastingOption
 * @author Baraka Protocol
 * @notice On-chain pricing for everlasting (perpetual) options using the
 *         Ackerer, Hugonnier & Jermann (2024) framework at ι = 0.
 *
 * ══════════════════════════════════════════════════════════════════
 *  MATHEMATICAL BASIS
 * ══════════════════════════════════════════════════════════════════
 * Ackerer, Hugonnier & Jermann (2024), "Perpetual futures pricing",
 * Mathematical Finance, Proposition 6.
 *
 * At ι = 0 and r_a = r_b (Shariah-compliant conditions), the exponents
 * β satisfy the characteristic equation:
 *
 *   ½σ²β(β − 1) = κ                                       (Prop 6, ι=0)
 *
 * yielding two roots:
 *   β₋ = ½ − √(¼ + 2κ/σ²)   < 0     (put / floor exponent)
 *   β₊ = ½ + √(¼ + 2κ/σ²)   > 1     (call / cap exponent)
 *
 * For the everlasting put (protection against X falling below K):
 *
 *   Π_put(x, K) = [K^{1−β₋} / (β₊ − β₋)] · x^{β₋}
 *
 * For the everlasting call (participation above K):
 *
 *   Π_call(x, K) = [K^{1−β₊} / (β₊ − β₋)] · x^{β₊}
 *
 * The coefficient (β₊ − β₋) = 2√(¼ + 2κ/σ²) comes from matching
 * the ODE solution at the strike boundary x = K.
 *
 * ══════════════════════════════════════════════════════════════════
 *  ISLAMIC FINANCE PRINCIPLE — ι = 0
 * ══════════════════════════════════════════════════════════════════
 * The interest parameter ι = 0 by construction. No risk-free rate
 * appears. κ (convergence intensity) replaces r as the pricing
 * parameter — consistent with the κ-Rate monetary framework
 * (Ahmed, Bhuyan & Islam 2026, Paper 3).
 *
 * ══════════════════════════════════════════════════════════════════
 *  APPLICATION LAYER
 * ══════════════════════════════════════════════════════════════════
 * - Takaful contribution = quotePut(spot, floor, market)
 * - Sukuk embedded option = quoteCall(spot, cap, market)
 * - iCDS protection pricing: put on credit-linked note
 * - κ-yield curve construction: option-implied κ across strikes
 */
contract EverlastingOption is Ownable2Step, Pausable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────────────
    //  Constants
    // ─────────────────────────────────────────────────────────────

    /// @dev WAD: 1e18 fixed-point scale used throughout.
    uint256 internal constant WAD = 1e18;

    /// @dev Seconds per year (365 days). Used to annualise κ from oracle.
    uint256 internal constant SECS_PER_YEAR = 365 * 24 * 3600; // 31_536_000

    /// @dev ln(2) in WAD: 0.693147180559945309 * 1e18
    int256  internal constant LN2_WAD = 693_147_180_559_945_309;

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    IOracleAdapter public oracle;

    /**
     * @dev Per-market configuration.
     * @param sigmaSquaredWad  Annual variance σ² in WAD (e.g. 0.64e18 for 80% vol).
     * @param kappaAnnualWad   Admin-set annual κ override in WAD. Ignored when useOracleKappa=true.
     * @param useOracleKappa   If true, derive κ from oracle.getKappaSignal() on each call.
     * @param active           True if this market is configured.
     */
    struct MarketConfig {
        uint256 sigmaSquaredWad;  // σ²  (annual, WAD)
        uint256 kappaAnnualWad;   // κ   (annual, WAD) — admin override
        bool    useOracleKappa;   // use live oracle κ if true
        bool    active;
    }

    mapping(address => MarketConfig) public markets;

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event MarketSet(address indexed asset, uint256 sigmaSquared, uint256 kappa, bool useOracle);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────

    constructor(address initialOwner, address _oracle) Ownable(initialOwner) {
        require(_oracle != address(0), "EO: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    // ─────────────────────────────────────────────────────────────
    //  Admin
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Configure a market for everlasting option pricing.
     * @param asset           The asset address (also market identifier).
     * @param sigmaSquaredWad Annualised variance σ² in WAD. E.g. (0.80)^2 * 1e18 = 0.64e18.
     * @param kappaAnnualWad  Annualised κ override in WAD. E.g. 0.083e18 for 8.3%/year.
     * @param useOracleKappa  True to derive κ from oracle.getKappaSignal() (annualised internally).
     */
    function setMarket(
        address asset,
        uint256 sigmaSquaredWad,
        uint256 kappaAnnualWad,
        bool    useOracleKappa
    ) external onlyOwner {
        require(asset           != address(0), "EO: zero asset");
        require(sigmaSquaredWad  > 0,          "EO: zero sigma");
        require(useOracleKappa || kappaAnnualWad > 0, "EO: zero kappa");

        markets[asset] = MarketConfig({
            sigmaSquaredWad: sigmaSquaredWad,
            kappaAnnualWad:  kappaAnnualWad,
            useOracleKappa:  useOracleKappa,
            active:          true
        });
        emit MarketSet(asset, sigmaSquaredWad, kappaAnnualWad, useOracleKappa);
    }

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "EO: zero oracle");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IOracleAdapter(newOracle);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────────────
    //  Public pricing functions
    // ─────────────────────────────────────────────────────────────

    /**
     * @notice Price of an everlasting put option.
     *         Economically: takaful contribution for floor protection at K on asset X.
     *         Islamic interpretation: fair mutual premium for protection against X < K,
     *         arriving at a Poisson random time with intensity κ. No riba (ι=0).
     *
     * @param asset The market asset (must be configured via setMarket).
     * @param xWad  Current spot price x in WAD (1e18 = $1.00).
     * @param kWad  Strike (floor) K in WAD.
     * @return putPriceWad  Π_put(x, K) in WAD.
     */
    function quotePut(address asset, uint256 xWad, uint256 kWad)
        external
        view
        whenNotPaused
        returns (uint256 putPriceWad)
    {
        require(xWad > 0 && kWad > 0, "EO: zero price");
        (int256 betaNeg, , uint256 denom) = _exponents(asset);
        putPriceWad = _quotePut(xWad, kWad, betaNeg, denom);
    }

    /**
     * @notice Price of an everlasting call option.
     *         Economically: fair price for participation in X > K upside,
     *         collected at a Poisson random time. No riba (ι=0).
     *
     * @param asset The market asset.
     * @param xWad  Current spot price in WAD.
     * @param kWad  Strike (cap) K in WAD.
     * @return callPriceWad Π_call(x, K) in WAD.
     */
    function quoteCall(address asset, uint256 xWad, uint256 kWad)
        external
        view
        whenNotPaused
        returns (uint256 callPriceWad)
    {
        require(xWad > 0 && kWad > 0, "EO: zero price");
        (, int256 betaPos, uint256 denom) = _exponents(asset);
        callPriceWad = _quoteCall(xWad, kWad, betaPos, denom);
    }

    /**
     * @notice Quote both put and call at the current oracle spot price.
     *
     * @param asset The market asset.
     * @param kWad  Strike in WAD.
     * @return putPriceWad  Everlasting put price.
     * @return callPriceWad Everlasting call price.
     * @return spotWad      Current spot (index) price used.
     * @return kappaWad     Annual κ used for pricing.
     * @return betaNegWad   β₋ exponent (negative root) in WAD.
     * @return betaPosWad   β₊ exponent (positive root) in WAD.
     */
    function quoteAtSpot(address asset, uint256 kWad)
        external
        view
        whenNotPaused
        returns (
            uint256 putPriceWad,
            uint256 callPriceWad,
            uint256 spotWad,
            uint256 kappaWad,
            int256  betaNegWad,
            int256  betaPosWad
        )
    {
        require(kWad > 0, "EO: zero strike");
        spotWad   = oracle.getIndexPrice(asset);
        kappaWad  = _getKappaAnnual(asset);
        MarketConfig storage cfg = markets[asset];
        require(cfg.active, "EO: market inactive");

        uint256 denom;
        (betaNegWad, betaPosWad, denom) = _exponents(asset);
        putPriceWad  = _quotePut(spotWad,  kWad, betaNegWad, denom);
        callPriceWad = _quoteCall(spotWad, kWad, betaPosWad, denom);
    }

    /**
     * @notice Returns the current β exponents for a market.
     *         Useful for off-chain display and calibration.
     *
     * @return betaNegWad β₋ < 0 in WAD.
     * @return betaPosWad β₊ > 1 in WAD.
     * @return denomWad   β₊ − β₋ = 2√(¼ + 2κ/σ²) in WAD.
     */
    function getExponents(address asset)
        external
        view
        whenNotPaused
        returns (int256 betaNegWad, int256 betaPosWad, uint256 denomWad)
    {
        return _exponents(asset);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal pricing
    // ─────────────────────────────────────────────────────────────

    /**
     * @dev Everlasting put: Π_put = [K^{1−β₋} / (β₊−β₋)] · x^{β₋}
     *
     *      In log-space to avoid overflow:
     *        ln(Π) = (1−β₋)·ln(K) + β₋·ln(x) − ln(β₊−β₋)
     *        Π = exp(ln(Π))
     *
     *      β₋ < 0, so x^{β₋} decreases as x increases (put is cheaper
     *      when the asset is far above the floor). ✓
     */
    function _quotePut(
        uint256 xWad,
        uint256 kWad,
        int256  betaNegWad,
        uint256 denomWad
    ) internal pure returns (uint256) {
        // ln(K) and ln(x) in WAD
        int256 lnK = _lnWad(kWad);
        int256 lnX = _lnWad(xWad);

        // (1 − β₋)·ln(K) + β₋·ln(x)
        // betaNegWad < 0  so  (WAD − betaNegWad) > WAD
        int256 oneMinusBeta = int256(WAD) - betaNegWad; // > 0
        int256 exponent =
            (oneMinusBeta * lnK) / int256(WAD) +
            (betaNegWad   * lnX) / int256(WAD) -
            _lnWad(denomWad);

        if (exponent < -88 * int256(WAD)) return 0; // underflow → effectively zero
        return _expWad(exponent);
    }

    /**
     * @dev Everlasting call: Π_call = [K^{1−β₊} / (β₊−β₋)] · x^{β₊}
     *
     *      In log-space:
     *        ln(Π) = (1−β₊)·ln(K) + β₊·ln(x) − ln(β₊−β₋)
     *
     *      β₊ > 1, so (1−β₊) < 0, meaning large K penalises the coefficient. ✓
     *      β₊ > 1, so x^{β₊} grows faster than x (convex in x). ✓
     */
    function _quoteCall(
        uint256 xWad,
        uint256 kWad,
        int256  betaPosWad,
        uint256 denomWad
    ) internal pure returns (uint256) {
        int256 lnK = _lnWad(kWad);
        int256 lnX = _lnWad(xWad);

        int256 oneMinusBeta = int256(WAD) - betaPosWad; // < 0
        int256 exponent =
            (oneMinusBeta * lnK) / int256(WAD) +
            (betaPosWad   * lnX) / int256(WAD) -
            _lnWad(denomWad);

        if (exponent < -88 * int256(WAD)) return 0;
        return _expWad(exponent);
    }

    // ─────────────────────────────────────────────────────────────
    //  Exponent computation
    // ─────────────────────────────────────────────────────────────

    /**
     * @dev Compute β₋, β₊, and the denominator (β₊ − β₋) for a market.
     *
     *   D    = ¼ + 2κ/σ²     (in WAD)
     *   sqrtD = √D            (in WAD)
     *   β₋   = ½ − sqrtD     (negative, WAD)
     *   β₊   = ½ + sqrtD     (> 1,    WAD)
     *   denom = β₊ − β₋ = 2·sqrtD
     */
    function _exponents(address asset)
        internal
        view
        returns (int256 betaNeg, int256 betaPos, uint256 denom)
    {
        MarketConfig storage cfg = markets[asset];
        require(cfg.active, "EO: market inactive");

        uint256 kappaWad = _getKappaAnnual(asset);
        uint256 sigma2   = cfg.sigmaSquaredWad;

        // D = 1/4 + 2κ/σ²  (WAD arithmetic)
        // 2κ/σ²: multiply κ by 2 first to avoid precision loss
        uint256 twoKappa = 2 * kappaWad;
        uint256 discrim  = WAD / 4 + (twoKappa * WAD) / sigma2;  // WAD

        // sqrtD in WAD: Math.sqrt operates on raw uint256
        // We want sqrt(discrim * WAD) to keep WAD precision.
        uint256 sqrtD = Math.sqrt(discrim * WAD);                 // WAD

        betaNeg = int256(WAD / 2) - int256(sqrtD);  // < 0
        betaPos = int256(WAD / 2) + int256(sqrtD);  // > 1
        denom   = 2 * sqrtD;                         // β₊ − β₋, WAD
    }

    /**
     * @dev Return the annualised κ for a market.
     *      If useOracleKappa: annualise the per-second oracle value.
     *      Otherwise: return admin-set kappaAnnualWad.
     */
    function _getKappaAnnual(address asset) internal view returns (uint256) {
        MarketConfig storage cfg = markets[asset];
        if (!cfg.useOracleKappa) return cfg.kappaAnnualWad;

        // Oracle returns κ in 1e18/second.
        // Positive kappa = basis converging (healthy).
        (int256 kappaPerSec, , ) = oracle.getKappaSignal(asset);
        if (kappaPerSec <= 0) return cfg.kappaAnnualWad; // fallback to admin value

        // Annualise: multiply by seconds per year.
        uint256 annual = uint256(kappaPerSec) * SECS_PER_YEAR;
        // Sanity: cap at 100%/year to prevent extreme exponents.
        return annual > WAD ? WAD : annual;
    }

    // ─────────────────────────────────────────────────────────────
    //  Fixed-point math — lnWad and expWad
    // ─────────────────────────────────────────────────────────────
    //
    //  All values are in WAD (1e18 = 1.0).
    //
    //  Adapted from Solmate FixedPointMathLib (transmissions11, MIT License)
    //  https://github.com/transmissions11/solmate
    //  and PRBMath (Paul Razvan Berg, MIT License).
    //
    // ─────────────────────────────────────────────────────────────

    /**
     * @dev Natural logarithm of x (WAD in, WAD out).
     *      x = 1e18 → result = 0
     *      x = 2e18 → result ≈ 0.693147e18
     *      x must be > 0.
     *
     *      Algorithm:
     *        ln(x) = log₂(x) · ln(2)
     *        log₂(x) = n + log₂(x / 2ⁿ)  where n = ⌊log₂(x)⌋
     *        log₂(y) for y ∈ [1, 2) via 8-iteration binary expansion.
     */
    function _lnWad(uint256 x) internal pure returns (int256 result) {
        require(x > 0, "EO: ln(0)");
        unchecked {
            // ── Integer part: n = ⌊log₂(x)⌋ ──────────────────────
            // OZ-style bit counting.
            uint256 n = 0;
            uint256 xc = x;
            if (xc >= 1 << 128) { xc >>= 128; n += 128; }
            if (xc >= 1 << 64)  { xc >>= 64;  n += 64;  }
            if (xc >= 1 << 32)  { xc >>= 32;  n += 32;  }
            if (xc >= 1 << 16)  { xc >>= 16;  n += 16;  }
            if (xc >= 1 << 8)   { xc >>= 8;   n += 8;   }
            if (xc >= 1 << 4)   { xc >>= 4;   n += 4;   }
            if (xc >= 1 << 2)   { xc >>= 2;   n += 2;   }
            if (xc >= 1 << 1)   {              n += 1;   }
            // n = floor(log2(x)) — this is also the bit-length - 1.

            // ── Fractional part of log₂ ───────────────────────────
            // Normalise x to [2^127, 2^128) to compute fractional log₂.
            // We use 128-bit fixed point for the fractional computation.
            uint256 y;
            if (n >= 127) {
                y = x >> (n - 127);
            } else {
                y = x << (127 - n);
            }
            // y is now in [2^127, 2^128), representing a value in [1, 2).
            // Compute log₂(y / 2^127) via 60 squaring iterations.
            // 60 iterations gives ~60-bit resolution (error < WAD >> 60 ~ 1),
            // sufficient for 18-decimal WAD option pricing.
            uint256 frac = 0;
            for (uint256 i = 0; i < 60; i++) {
                y = (y * y) >> 127;   // y² / 2^127, stays ~128-bit via uint256
                if (y >= (1 << 128)) {
                    y >>= 1;
                    // Each iteration corresponds to 1/(2^(i+1)) of the fractional log₂.
                    frac += (WAD >> (i + 1));
                }
            }
            // log₂(x) = n + frac  (where frac is accumulated fraction in WAD)
            // Adjust n to be relative to 1e18 scale:
            // We want log₂(x/1e18) = log₂(x) − log₂(1e18)
            // log₂(1e18) = 18 * log₂(10) ≈ 59.7941... → as integer part: 59
            // We keep the signed result.
            int256 log2Wad = (int256(n) - 59) * int256(WAD) + int256(frac)
                             - 794_705_707_972_521_572; // fractional bits of log₂(1e18) in WAD
            // log2Wad is now log₂(x / 1e18) in WAD.

            // ── Convert to natural log: ln(x) = log₂(x) * ln(2) ──
            result = (log2Wad * LN2_WAD) / int256(WAD);
        }
    }

    /**
     * @dev e^x where x is a signed WAD. Returns a uint256 WAD.
     *      Domain: x ∈ (-88e18, +88e18). Returns 0 for x ≤ −88e18.
     *
     *      Algorithm (range reduction + Taylor series):
     *        e^x = 2^(x / ln2) = 2^k · e^(x − k·ln2)
     *        where k = round(x / ln2).
     *        e^r for r ∈ (−0.5·ln2, 0.5·ln2) via 8th-order Taylor.
     */
    function _expWad(int256 x) internal pure returns (uint256) {
        unchecked {
            if (x <= -88 * int256(WAD)) return 0;
            if (x >=  88 * int256(WAD)) revert("EO: exp overflow");

            // ── Range reduction ────────────────────────────────────
            // k = round(x / ln2) so that r = x − k·ln2 ∈ (−0.5·ln2, 0.5·ln2)
            // We compute k in integer form first.
            // LN2_WAD = 693_147_180_559_945_309
            int256 k = (x + LN2_WAD / 2) / LN2_WAD;   // rounded integer
            int256 r = x - k * LN2_WAD;                 // r in (−0.347e18, 0.347e18)

            // ── Taylor series for e^r ──────────────────────────────
            // e^r = 1 + r + r²/2! + r³/3! + ... + r⁸/8!
            // Computed using Horner's method in WAD arithmetic.
            // Coefficients (denominators of factorials), all in WAD:
            // 1/8! = 1/40320, 1/7! = 1/5040, etc.
            // We accumulate from the inside out.
            int256 rWAD = r;                       // r in WAD
            // t = r (will be multiplied by r each step and divided by factorial)
            // Use Horner: e^r ≈ 1 + r*(1 + r/2*(1 + r/3*(... )))
            // Equivalently: sum = 1 + r + r²/2 + r³/6 + r⁴/24 + r⁵/120 + r⁶/720 + r⁷/5040 + r⁸/40320
            int256 res = int256(WAD);                                 // start at 1
            int256 term = rWAD;                                       // r^1/1!
            res += term;
            term = (term * rWAD) / (2 * int256(WAD));                // r^2/2!
            res += term;
            term = (term * rWAD) / (3 * int256(WAD));                // r^3/3!
            res += term;
            term = (term * rWAD) / (4 * int256(WAD));                // r^4/4!
            res += term;
            term = (term * rWAD) / (5 * int256(WAD));                // r^5/5!
            res += term;
            term = (term * rWAD) / (6 * int256(WAD));                // r^6/6!
            res += term;
            term = (term * rWAD) / (7 * int256(WAD));                // r^7/7!
            res += term;
            term = (term * rWAD) / (8 * int256(WAD));                // r^8/8!
            res += term;

            // ── Reconstruct: e^x = e^r · 2^k ─────────────────────
            if (res <= 0) return 0;
            uint256 er = uint256(res);   // e^r in WAD

            if (k >= 0) {
                uint256 uk = uint256(k);
                // Check for overflow: if uk >= 256, shift would be out of range.
                if (uk >= 255) revert("EO: exp overflow");
                return (er << uk);       // e^r * 2^k (WAD-correct since 2^k shifts)
            } else {
                uint256 uk = uint256(-k);
                if (uk >= 255) return 0; // underflow
                return (er >> uk);       // e^r / 2^k
            }
        }
    }
}
