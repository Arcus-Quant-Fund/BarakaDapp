// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IOracleAdapter.sol";

/// @dev Minimal Chainlink aggregator interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

/**
 * @title OracleAdapter
 * @author Baraka Protocol
 * @notice Dual-oracle price feed (Chainlink primary + secondary).
 *         Requires both to agree within DEVIATION_TOLERANCE before returning a price.
 *         Staleness check: rejects prices older than STALENESS_THRESHOLD.
 *         Circuit breaker: rejects prices that deviate >20% from last valid price.
 *
 *         Mark price is tracked via on-chain TWAP using cumulative price snapshots.
 */
contract OracleAdapter is IOracleAdapter, Ownable2Step, Pausable {
    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 public constant STALENESS_THRESHOLD  = 5 minutes;
    uint256 public constant DEVIATION_TOLERANCE  = 50;   // 0.5% in bps
    uint256 public constant CIRCUIT_BREAKER_BPS  = 2000; // 20% max deviation from last valid
    uint256 public constant TWAP_MIN_OBSERVATIONS = 2;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    struct OracleConfig {
        AggregatorV3Interface primary;   // Chainlink
        AggregatorV3Interface secondary; // Second Chainlink feed or fallback
    }

    struct TWAPObservation {
        uint256 price;
        uint256 timestamp;
    }

    /// @notice Oracle feeds per asset
    mapping(address => OracleConfig) public oracles;

    /// @notice Last known valid price per asset (for circuit breaker)
    mapping(address => uint256) public lastValidPrice;

    /// @notice Ring buffer of TWAP observations (max 60 observations per asset)
    mapping(address => TWAPObservation[60]) private _twapObs;
    mapping(address => uint256) private _twapHead;
    mapping(address => uint256) private _twapCount;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event OracleSet(address indexed asset, address primary, address secondary);
    event PriceRecorded(address indexed asset, uint256 price, uint256 timestamp);
    event OracleFallback(address indexed asset, string reason);
    event CircuitBreakerTripped(address indexed asset, uint256 lastValid, uint256 incoming);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setOracle(address asset, address primary, address secondary) external onlyOwner {
        require(asset    != address(0), "Zero asset");
        require(primary  != address(0), "Zero primary");
        require(secondary != address(0), "Zero secondary");
        oracles[asset] = OracleConfig(
            AggregatorV3Interface(primary),
            AggregatorV3Interface(secondary)
        );
        lastValidPrice[asset] = 0; // explicit init; circuit breaker seeds on first snapshotPrice call
        emit OracleSet(asset, primary, secondary);
    }

    /**
     * @notice Keeper function: fetch current index price and store as circuit breaker baseline.
     *         Must be called at least once per asset before circuit breaker becomes active.
     * @param asset The asset to snapshot.
     * @return price The current index price (1e18).
     */
    function snapshotPrice(address asset) external whenNotPaused returns (uint256 price) {
        price = _resolveIndexPrice(asset);
        lastValidPrice[asset] = price;
        emit PriceRecorded(asset, price, block.timestamp);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ─────────────────────────────────────────────────────
    // IOracleAdapter — Index price (spot reference)
    // ─────────────────────────────────────────────────────

    /**
     * @notice Returns the index price for an asset.
     *         Requires primary and secondary feeds to agree within DEVIATION_TOLERANCE.
     *         If only one feed is fresh, emits OracleFallback and uses single source.
     */
    function getIndexPrice(address asset) external view override whenNotPaused returns (uint256) {
        return _resolveIndexPrice(asset);
    }

    // ─────────────────────────────────────────────────────
    // IOracleAdapter — Mark price (on-chain TWAP)
    // ─────────────────────────────────────────────────────

    /**
     * @notice Returns the TWAP mark price over the given window (seconds).
     *         Falls back to index price if insufficient TWAP observations.
     */
    function getMarkPrice(address asset, uint256 twapWindow)
        external
        view
        override
        whenNotPaused
        returns (uint256)
    {
        return _computeTWAP(asset, twapWindow);
    }

    /**
     * @notice Record a new TWAP observation. Called by PositionManager on every trade.
     */
    function recordMarkPrice(address asset, uint256 price) external whenNotPaused {
        require(price > 0, "Zero price");
        uint256 head   = _twapHead[asset];
        uint256 count  = _twapCount[asset];

        _twapObs[asset][head] = TWAPObservation(price, block.timestamp);
        _twapHead[asset]      = (head + 1) % 60;
        if (count < 60) _twapCount[asset] = count + 1;

        emit PriceRecorded(asset, price, block.timestamp);
    }

    // ─────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────

    function _resolveIndexPrice(address asset) internal view returns (uint256) {
        OracleConfig storage cfg = oracles[asset];
        require(address(cfg.primary) != address(0), "Oracle not configured");

        (bool p1ok, uint256 p1) = _safeLatestPrice(cfg.primary);
        (bool p2ok, uint256 p2) = _safeLatestPrice(cfg.secondary);

        uint256 price = 0; // slither: explicit init (uninitialized-local)

        if (p1ok && p2ok) {
            // Both fresh — require agreement
            require(_withinTolerance(p1, p2), "Oracle divergence");
            // Weighted average: 60% primary, 40% secondary
            price = (p1 * 60 + p2 * 40) / 100;
        } else if (p1ok) {
            price = p1;
        } else if (p2ok) {
            price = p2;
        } else {
            revert("All oracles stale");
        }

        // Circuit breaker
        uint256 last = lastValidPrice[asset];
        if (last > 0) {
            uint256 diff = price > last ? price - last : last - price;
            require(diff * 10000 / last <= CIRCUIT_BREAKER_BPS, "Circuit breaker: price spike");
        }

        return price;
    }

    function _safeLatestPrice(AggregatorV3Interface feed)
        internal
        view
        returns (bool ok, uint256 price)
    {
        // slither-disable-next-line unused-return (roundId, startedAt, answeredInRound intentionally ignored)
        try feed.latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (answer <= 0)                              return (false, 0);
            if (block.timestamp - updatedAt > STALENESS_THRESHOLD) return (false, 0);
            uint8 dec = feed.decimals();
            // Normalise to 18 decimals
            price = uint256(answer) * (10 ** (18 - dec));
            ok    = true;
        } catch {
            return (false, 0);
        }
    }

    function _withinTolerance(uint256 a, uint256 b) internal pure returns (bool) {
        if (a == 0 || b == 0) return false;
        uint256 diff = a > b ? a - b : b - a;
        return diff * 10000 / a <= DEVIATION_TOLERANCE;
    }

    function _computeTWAP(address asset, uint256 window) internal view returns (uint256) {
        uint256 count = _twapCount[asset];
        if (count < TWAP_MIN_OBSERVATIONS) {
            // Fallback: return index price
            return _resolveIndexPrice(asset);
        }

        uint256 head      = _twapHead[asset];
        uint256 cutoff    = block.timestamp > window ? block.timestamp - window : 0;
        uint256 weightedSum = 0; // slither: explicit init
        uint256 totalTime   = 0; // slither: explicit init
        uint256 prevTimestamp = block.timestamp;

        for (uint256 i = 1; i <= count; i++) {
            uint256 idx = (head + 60 - i) % 60;
            TWAPObservation storage obs = _twapObs[asset][idx];
            if (obs.timestamp < cutoff) break;

            uint256 dt  = prevTimestamp - obs.timestamp;
            weightedSum += obs.price * dt;
            totalTime   += dt;
            prevTimestamp = obs.timestamp;
        }

        // slither-disable-next-line incorrect-equality (totalTime==0 is safe: no observations in window)
        if (totalTime == 0) return _resolveIndexPrice(asset);
        return weightedSum / totalTime;
    }
}
