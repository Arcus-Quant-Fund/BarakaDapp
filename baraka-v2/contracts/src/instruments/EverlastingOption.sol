// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IEverlastingOption.sol";

/**
 * @title EverlastingOption
 * @author Baraka Protocol v2
 * @notice On-chain pricing for everlasting (perpetual) options using the
 *         Ackerer, Hugonnier & Jermann (2024) framework at iota = 0.
 *
 *         Ported from v1 with key change: uses bytes32 marketId instead of address asset.
 *         All math and security fixes preserved from v1 audit rounds.
 *
 *         At iota = 0:
 *           beta_neg = 1/2 - sqrt(1/4 + 2*kappa/sigma^2)
 *           beta_pos = 1/2 + sqrt(1/4 + 2*kappa/sigma^2)
 *           put(x, K) = [K^(1-beta_neg) / (beta_pos - beta_neg)] * x^beta_neg
 *           call(x, K) = [K^(1-beta_pos) / (beta_pos - beta_neg)] * x^beta_pos
 */
contract EverlastingOption is IEverlastingOption, Ownable2Step, Pausable, ReentrancyGuard {

    uint256 internal constant WAD = 1e18;
    uint256 internal constant SECS_PER_YEAR = 365 * 24 * 3600;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    IOracleAdapter public oracle;

    // A2-M3 fix: 2-step oracle update with 48h timelock
    uint256 public constant ORACLE_TIMELOCK = 48 hours;
    address public pendingOracle;
    uint256 public oraclePendingAfter;

    struct MarketConfig {
        uint256 sigmaSquaredWad;  // annual variance in WAD
        uint256 kappaAnnualWad;   // annual kappa override in WAD
        /// @dev INFO (L4-I-1): useOracleKappa is dead code — kept for storage layout compatibility.
        ///      Will be removed in next major version with storage migration.
        bool    useOracleKappa;
        bool    active;
    }

    mapping(bytes32 => MarketConfig) public markets;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event MarketSet(bytes32 indexed marketId, uint256 sigmaSquared, uint256 kappa, bool useOracle);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event OracleUpdateInitiated(address indexed pendingOracle, uint256 applicableAfter);
    event OracleUpdateCancelled(address indexed cancelledOracle);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner, address _oracle) Ownable(initialOwner) {
        require(_oracle != address(0), "EO: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setMarket(
        bytes32 marketId,
        uint256 sigmaSquaredWad,
        uint256 kappaAnnualWad,
        bool    useOracleKappa
    ) external onlyOwner {
        require(sigmaSquaredWad >= 1e14, "EO: sigma too small");
        require(sigmaSquaredWad <= 100e18, "EO: sigma too large");
        require(useOracleKappa || kappaAnnualWad > 0, "EO: zero kappa");
        require(useOracleKappa || kappaAnnualWad <= WAD, "EO: kappa > 100%/yr");

        markets[marketId] = MarketConfig({
            sigmaSquaredWad: sigmaSquaredWad,
            kappaAnnualWad:  kappaAnnualWad,
            useOracleKappa:  useOracleKappa,
            active:          true
        });
        emit MarketSet(marketId, sigmaSquaredWad, kappaAnnualWad, useOracleKappa);
    }

    function initiateOracleUpdate(address newOracle) external onlyOwner {
        require(newOracle != address(0), "EO: zero oracle");
        require(newOracle != address(oracle), "EO: same oracle");
        pendingOracle = newOracle;
        oraclePendingAfter = block.timestamp + ORACLE_TIMELOCK;
        emit OracleUpdateInitiated(newOracle, oraclePendingAfter);
    }

    /// AUDIT FIX (EO-M-2): Only owner can apply oracle update after timelock
    function applyOracleUpdate() external onlyOwner {
        require(pendingOracle != address(0), "EO: no pending oracle");
        require(block.timestamp >= oraclePendingAfter, "EO: timelock not elapsed");
        address old = address(oracle);
        oracle = IOracleAdapter(pendingOracle);
        pendingOracle = address(0);
        oraclePendingAfter = 0;
        emit OracleUpdated(old, address(oracle));
    }

    function cancelOracleUpdate() external onlyOwner {
        require(pendingOracle != address(0), "EO: no pending oracle");
        address cancelled = pendingOracle;
        pendingOracle = address(0);
        oraclePendingAfter = 0;
        emit OracleUpdateCancelled(cancelled);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("EO: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // Public pricing
    // ─────────────────────────────────────────────────────

    function quotePut(bytes32 marketId, uint256 xWad, uint256 kWad)
        external view override whenNotPaused returns (uint256)
    {
        require(xWad > 0 && kWad > 0, "EO: zero price");
        require(xWad <= 1e36 && kWad <= 1e36, "EO: price out of range");
        (int256 betaNeg, , uint256 denom) = _exponents(marketId);
        return _quotePut(xWad, kWad, betaNeg, denom);
    }

    function quoteCall(bytes32 marketId, uint256 xWad, uint256 kWad)
        external view override whenNotPaused returns (uint256)
    {
        require(xWad > 0 && kWad > 0, "EO: zero price");
        require(xWad <= 1e36 && kWad <= 1e36, "EO: price out of range");
        (, int256 betaPos, uint256 denom) = _exponents(marketId);
        return _quoteCall(xWad, kWad, betaPos, denom);
    }

    function quoteAtSpot(bytes32 marketId, uint256 kWad)
        external view override whenNotPaused
        returns (uint256 putPriceWad, uint256 callPriceWad, uint256 spotWad,
                 uint256 kappaWad, int256 betaNegWad, int256 betaPosWad)
    {
        require(kWad > 0 && kWad <= 1e36, "EO: strike out of range");
        spotWad = oracle.getIndexPrice(marketId);
        require(spotWad > 0 && spotWad <= 1e36, "EO: spot out of range");
        kappaWad = _getKappaAnnual(marketId);

        uint256 denom;
        (betaNegWad, betaPosWad, denom) = _exponents(marketId);
        putPriceWad  = _quotePut(spotWad, kWad, betaNegWad, denom);
        callPriceWad = _quoteCall(spotWad, kWad, betaPosWad, denom);
    }

    function getExponents(bytes32 marketId)
        external view override whenNotPaused
        returns (int256 betaNegWad, int256 betaPosWad, uint256 denomWad)
    {
        return _exponents(marketId);
    }

    // ─────────────────────────────────────────────────────
    // Internal pricing
    // ─────────────────────────────────────────────────────

    function _quotePut(uint256 xWad, uint256 kWad, int256 betaNegWad, uint256 denomWad)
        internal pure returns (uint256)
    {
        int256 lnK = _lnWad(kWad);
        int256 lnX = _lnWad(xWad);
        int256 oneMinusBeta = int256(WAD) - betaNegWad;
        int256 exponent = (oneMinusBeta * lnK) / int256(WAD) +
                          (betaNegWad * lnX) / int256(WAD) -
                          _lnWad(denomWad);
        if (exponent < -88 * int256(WAD)) return 0;
        /// AUDIT FIX (P3-INST-11): Guard against expWad overflow with extreme market parameters.
        /// expWad(x) overflows for x > ~135e18 (e^135 ≈ 2^195, approaching uint256 ceiling).
        /// At extreme sigma or kappa values, beta exponents can produce large positive log sums.
        /// Revert rather than overflow silently, preventing permanent DoS on affected markets.
        require(exponent <= 135 * int256(WAD), "EO: exponent overflow");
        return _expWad(exponent);
    }

    function _quoteCall(uint256 xWad, uint256 kWad, int256 betaPosWad, uint256 denomWad)
        internal pure returns (uint256)
    {
        int256 lnK = _lnWad(kWad);
        int256 lnX = _lnWad(xWad);
        int256 oneMinusBeta = int256(WAD) - betaPosWad;
        int256 exponent = (oneMinusBeta * lnK) / int256(WAD) +
                          (betaPosWad * lnX) / int256(WAD) -
                          _lnWad(denomWad);
        if (exponent < -88 * int256(WAD)) return 0;
        /// AUDIT FIX (P3-INST-11): Guard against expWad overflow with extreme market parameters.
        /// expWad(x) overflows for x > ~135e18 (e^135 ≈ 2^195, approaching uint256 ceiling).
        /// At extreme sigma or kappa values, beta exponents can produce large positive log sums.
        /// Revert rather than overflow silently, preventing permanent DoS on affected markets.
        require(exponent <= 135 * int256(WAD), "EO: exponent overflow");
        return _expWad(exponent);
    }

    function _exponents(bytes32 marketId)
        internal view returns (int256 betaNeg, int256 betaPos, uint256 denom)
    {
        MarketConfig storage cfg = markets[marketId];
        require(cfg.active, "EO: market inactive");

        uint256 kappaWad = _getKappaAnnual(marketId);
        uint256 sigma2 = cfg.sigmaSquaredWad;

        uint256 twoKappa = 2 * kappaWad;
        uint256 discrim = WAD / 4 + (twoKappa * WAD) / sigma2;
        /// AUDIT FIX (EO-M-3): Guard against precision loss at extreme parameters
        require(discrim >= WAD / 4, "EO: discriminant underflow");
        uint256 sqrtD = Math.sqrt(discrim * WAD);
        require(sqrtD > 0, "EO: sqrt precision loss");

        betaNeg = int256(WAD / 2) - int256(sqrtD);
        betaPos = int256(WAD / 2) + int256(sqrtD);
        denom = 2 * sqrtD;
    }

    function _getKappaAnnual(bytes32 marketId) internal view returns (uint256) {
        MarketConfig storage cfg = markets[marketId];
        return cfg.kappaAnnualWad;
    }

    /// AUDIT FIX (L4-L-1): Defensive guard — ln(0) is undefined, would revert opaquely
    function _lnWad(uint256 x) internal pure returns (int256) {
        require(x > 0, "EO: ln(0) undefined");
        return FixedPointMathLib.lnWad(int256(x));
    }

    function _expWad(int256 x) internal pure returns (uint256) {
        if (x <= -42139678854452767551) return 0;
        return uint256(FixedPointMathLib.expWad(x));
    }
}
