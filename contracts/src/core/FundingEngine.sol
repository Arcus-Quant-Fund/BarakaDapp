// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IFundingEngine.sol";

/**
 * @title FundingEngine
 * @author Baraka Protocol
 * @notice Implements the Shariah-compliant perpetual futures funding formula.
 *
 * ══════════════════════════════════════════════════════
 *  MATHEMATICAL BASIS
 * ══════════════════════════════════════════════════════
 * Ackerer, Hugonnier & Jermann (2024), "Perpetual futures pricing",
 * Mathematical Finance. Theorem 3 / Proposition 3 (continuous-time, ι=0 case).
 *
 * Continuous-time result (stablecoin-margined, r_a = r_b):
 *   f_t = κ / (κ + r_b - r_a) × x_t  →  f_t = x_t  (exact convergence)
 *
 * Our funding rate formula:
 *   F = P = (mark_price - index_price) / index_price
 *
 * ══════════════════════════════════════════════════════
 *  ISLAMIC FINANCE PRINCIPLE — ι = 0
 * ══════════════════════════════════════════════════════
 * The interest parameter ι = 0 by design. This contract contains:
 *   - NO interest term
 *   - NO interest floor
 *   - NO minimum funding rate
 *
 * CEX formula (REJECTED — contains riba):
 *   F = P + clamp(I − P, −0.05%, +0.05%)   where I = 0.01%/8h = 10.95%/year
 *
 * Our formula (IMPLEMENTED — riba-free):
 *   F = P only
 *
 * The circuit-breaker clamp (±75 bps) is a volatility cap, NOT an interest floor.
 * It is symmetric around zero — it can be positive OR negative.
 *
 * ══════════════════════════════════════════════════════
 */
contract FundingEngine is IFundingEngine, Ownable2Step, Pausable, ReentrancyGuard {
    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    /// @notice Funding settlement interval.
    uint256 public constant FUNDING_INTERVAL = 1 hours;

    /// @notice TWAP window for mark price calculation.
    uint256 public constant TWAP_WINDOW = 30 minutes;

    /// @notice Circuit breaker: maximum |funding rate| per interval in 1e18 units (0.75% = 75 bps).
    ///         This is a SYMMETRIC cap — it is NOT an interest floor.
    ///         The rate can be positive, zero, or negative within this range.
    int256 public constant MAX_FUNDING_RATE = 75e14;  // 0.75% in 1e18 scale
    int256 public constant MIN_FUNDING_RATE = -75e14; // −0.75%

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    IOracleAdapter public oracle;

    /// @notice Cumulative funding index per market (grows/shrinks each interval)
    mapping(address => int256) public override cumulativeFundingIndex;

    /// @notice Timestamp of last funding update per market
    mapping(address => uint256) public lastFundingTime;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event FundingRateUpdated(
        address indexed market,
        int256  fundingRate,
        uint256 markPrice,
        uint256 indexPrice,
        uint256 timestamp
    );
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner, address _oracle) Ownable(initialOwner) {
        require(_oracle != address(0), "FundingEngine: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "FundingEngine: zero oracle");
        emit OracleUpdated(address(oracle), newOracle);
        oracle = IOracleAdapter(newOracle);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────
    // IFundingEngine — read
    // ─────────────────────────────────────────────────────

    /**
     * @notice Compute the instantaneous funding rate for a market.
     *
     *   F = (mark_price − index_price) / index_price
     *
     *   - F > 0: longs pay shorts (perpetual trades at premium to spot)
     *   - F < 0: shorts pay longs (perpetual trades at discount to spot)
     *   - F = 0: perfectly anchored (mark = index)
     *
     *   No interest term. No floor. Exactly ι = 0.
     *   Clamped to ±75 bps as a circuit breaker only.
     *
     * @param market The asset address used as market identifier.
     * @return fundingRate Signed rate in 1e18 scale.
     */
    function getFundingRate(address market)
        external
        view
        override
        whenNotPaused
        returns (int256 fundingRate)
    {
        return _computeFundingRate(market);
    }

    // ─────────────────────────────────────────────────────
    // IFundingEngine — write
    // ─────────────────────────────────────────────────────

    /**
     * @notice Update the cumulative funding index for a market.
     *         Called by PositionManager on every position open/close/settle.
     *         Accrues funding for all elapsed intervals since last update.
     *
     * @param market The market to update.
     * @return cumulativeIndex The new cumulative funding index.
     */
    function updateCumulativeFunding(address market)
        external
        override
        nonReentrant
        whenNotPaused
        returns (int256 cumulativeIndex)
    {
        uint256 last    = lastFundingTime[market];
        uint256 elapsed = block.timestamp - last;

        // Initialise on first call
        if (last == 0) {
            lastFundingTime[market] = block.timestamp;
            return cumulativeFundingIndex[market];
        }

        // How many complete intervals have elapsed?
        // slither-disable-next-line divide-before-multiply (intentional: truncate to interval boundary, then multiply back)
        uint256 intervals = elapsed / FUNDING_INTERVAL;
        // slither-disable-next-line incorrect-equality (safe: 0 intervals means no full interval has passed)
        if (intervals == 0) return cumulativeFundingIndex[market];

        int256 rate = _computeFundingRate(market);

        // Accrue: cumulative += rate * intervals
        cumulativeFundingIndex[market] += rate * int256(intervals);
        lastFundingTime[market]        += intervals * FUNDING_INTERVAL; // advance to exact boundary

        uint256 markPrice  = oracle.getMarkPrice(market, TWAP_WINDOW);
        uint256 indexPrice = oracle.getIndexPrice(market);

        emit FundingRateUpdated(market, rate, markPrice, indexPrice, block.timestamp);

        return cumulativeFundingIndex[market];
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /**
     * @dev Core formula: F = (mark − index) / index
     *      Scaled to 1e18. Clamped ±75bps (circuit breaker, NOT interest floor).
     */
    function _computeFundingRate(address market) internal view returns (int256) {
        uint256 markPrice  = oracle.getMarkPrice(market, TWAP_WINDOW);
        uint256 indexPrice = oracle.getIndexPrice(market);

        require(indexPrice > 0, "FundingEngine: zero index price");

        // F = (mark - index) / index  (signed, 1e18 scale)
        int256 premium = (int256(markPrice) - int256(indexPrice)) * 1e18 / int256(indexPrice);

        // Symmetric circuit breaker — clamp to ±75 bps
        // This is NOT a riba floor — the rate can be zero or negative
        return _clamp(premium, MIN_FUNDING_RATE, MAX_FUNDING_RATE);
    }

    function _clamp(int256 val, int256 lo, int256 hi) internal pure returns (int256) {
        if (val < lo) return lo;
        if (val > hi) return hi;
        return val;
    }
}
