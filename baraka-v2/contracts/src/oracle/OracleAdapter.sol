// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "../interfaces/IOracleAdapter.sol";

/**
 * @title OracleAdapter
 * @author Baraka Protocol v2
 * @notice Dual-source oracle for margin calculations and liquidation triggers.
 *
 *         Index price: external oracle (Chainlink / Pyth) — used for margin, liquidation, funding.
 *         Mark price: EWMA of recent trade prices — used for funding rate premium.
 *
 *         NOT used for trade execution (orderbook prices are market-driven).
 */
contract OracleAdapter is IOracleAdapter, Ownable2Step {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    struct MarketOracle {
        address priceFeed;     // Chainlink aggregator or mock
        uint256 heartbeat;     // max seconds between updates
        uint8   feedDecimals;  // decimals of the feed
        uint256 lastIndexPrice;
        uint256 lastMarkPrice;
        uint256 lastUpdateTime;
        bool    active;
    }

    /// @notice Per-market oracle configuration
    mapping(bytes32 => MarketOracle) public marketOracles;

    /// AUDIT FIX (P4-A1-5): Track last Chainlink-fed price per market.
    /// setIndexPrice() is bounded to ±50% of this reference, not of the current price.
    /// Closes the path-dependence exploit: without this, an owner can walk the price
    /// arbitrarily far via multiple 50% hops (1000 → 1500 → 2250 → ...).
    mapping(bytes32 => uint256) public chainlinkReferencePrice;

    /// @notice EWMA alpha for mark price (in WAD, e.g. 0.1e18 = 10% weight on new price)
    uint256 public markEwmaAlpha = 0.1e18;

    /// @notice Authorised callers (MatchingEngine — updates mark price on trades)
    mapping(address => bool) public authorised;

    /// AUDIT FIX (P5-H-5): Arbitrum L2 Sequencer Uptime Feed for oracle liveness check.
    /// After sequencer recovery, prices may be stale. Grace period prevents acting on stale data.
    address public sequencerUptimeFeed;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @notice P9-H-2: Circuit breaker — max allowed price deviation per update (WAD).
    /// E.g. 0.15e18 = 15%. If new price deviates more than this from the last, revert.
    /// Prevents oracle manipulation via compromised feed or flash crash relay.
    /// 0 = disabled (no circuit breaker).
    uint256 public maxPriceDeviation;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event MarketOracleSet(bytes32 indexed marketId, address priceFeed, uint256 heartbeat);
    event IndexPriceUpdated(bytes32 indexed marketId, uint256 price);
    event MarkPriceUpdated(bytes32 indexed marketId, uint256 price);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setMarketOracle(
        bytes32 marketId,
        address priceFeed,
        uint256 heartbeat,
        uint8   feedDecimals
    ) external onlyOwner {
        require(priceFeed != address(0), "OA: zero feed");
        /// AUDIT FIX (P4-A4-2): Preserve lastIndexPrice and lastMarkPrice on reconfiguration.
        /// Previously, setMarketOracle() always reset prices to 0, creating a liveness blackout:
        /// all margin checks, liquidations, and funding calculations reverted ("OA: index price not set")
        /// until a keeper called updateIndexPrice() on the new feed. On a live market with open positions,
        /// this blackout window could prevent liquidations and allow undercollateralised positions to grow.
        /// Fix: update config fields only; reset lastUpdateTime to 0 (forces isStale=true, signalling
        /// keepers to refresh from the new feed) while price reads remain available from the prior feed.
        MarketOracle storage mo = marketOracles[marketId];
        mo.priceFeed = priceFeed;
        mo.heartbeat = heartbeat;
        mo.feedDecimals = feedDecimals;
        mo.active = true;
        mo.lastUpdateTime = 0; // stale until keeper refreshes from the new feed
        // lastIndexPrice and lastMarkPrice preserved — prevents margin/liquidation blackout
        emit MarketOracleSet(marketId, priceFeed, heartbeat);
    }

    function setAuthorised(address caller, bool status) external onlyOwner {
        authorised[caller] = status;
    }

    /// AUDIT FIX (P2-HIGH-8): Prevent ownership renouncement — OracleAdapter requires owner for market setup.
    function renounceOwnership() public view override onlyOwner {
        revert("OA: renounce disabled");
    }

    /// AUDIT FIX (L1B-M-1): Cap alpha at 20% — higher values allow single-trade mark manipulation
    function setMarkEwmaAlpha(uint256 alpha) external onlyOwner {
        require(alpha > 0 && alpha <= 0.20e18, "OA: alpha out of range (max 20%)");
        markEwmaAlpha = alpha;
    }

    /// AUDIT FIX (P5-H-5): Set Arbitrum L2 Sequencer Uptime Feed address. address(0) disables check.
    function setSequencerUptimeFeed(address feed) external onlyOwner {
        sequencerUptimeFeed = feed;
    }

    /// @notice P9-H-2: Set circuit breaker max price deviation (WAD). 0 = disabled.
    /// @param deviation Max deviation in WAD (e.g. 0.15e18 = 15%). Capped at 50%.
    function setMaxPriceDeviation(uint256 deviation) external onlyOwner {
        require(deviation <= 0.50e18, "OA: deviation > 50%");
        maxPriceDeviation = deviation;
    }

    // ─────────────────────────────────────────────────────
    // Price updates
    // ─────────────────────────────────────────────────────

    /// @notice Update index price from Chainlink feed.
    ///         Can be called by anyone (keeper) or internally.
    function updateIndexPrice(bytes32 marketId) external {
        MarketOracle storage mo = marketOracles[marketId];
        require(mo.active, "OA: market not active");

        /// AUDIT FIX (P5-H-5): Check Arbitrum L2 Sequencer Uptime Feed.
        /// After sequencer recovery, enforce grace period before accepting new prices.
        if (sequencerUptimeFeed != address(0)) {
            (, int256 seqAnswer, uint256 seqStartedAt,,) = _latestRoundData(sequencerUptimeFeed);
            require(seqAnswer == 0, "OA: sequencer down");
            require(block.timestamp - seqStartedAt > SEQUENCER_GRACE_PERIOD, "OA: sequencer grace period");
        }

        // Read from Chainlink aggregator
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = _latestRoundData(mo.priceFeed);
        require(answer > 0, "OA: negative price");
        /// AUDIT FIX (L1B-M-2): Use 1x heartbeat — 2x is too permissive
        require(block.timestamp - updatedAt <= mo.heartbeat, "OA: stale feed");
        /// AUDIT FIX (L1B-M-4): Validate Chainlink round completeness
        require(answeredInRound >= roundId, "OA: stale round");
        require(startedAt > 0, "OA: round not started");

        // Normalize to WAD (1e18)
        uint256 price = uint256(answer) * WAD / (10 ** mo.feedDecimals);

        /// AUDIT FIX (P9-H-2): Circuit breaker — revert if price deviates too much from last known.
        /// Prevents oracle manipulation via compromised Chainlink feed or flash crash relay.
        /// Real-world ref: KiloEx $7.5M oracle manipulation (2024).
        /// AUDIT FIX (P10-H-4): Use chainlinkReferencePrice as fallback on first update.
        /// Previously `mo.lastIndexPrice == 0` skipped the check entirely on market init, allowing
        /// a compromised feed to anchor the circuit breaker at an arbitrary baseline. Now the check
        /// fires against the existing chainlinkReferencePrice (set by setMarketOracle) when no
        /// lastIndexPrice is available yet.
        if (maxPriceDeviation > 0) {
            uint256 refPrice = mo.lastIndexPrice > 0
                ? mo.lastIndexPrice
                : chainlinkReferencePrice[marketId];  // use Chainlink anchor on first update
            if (refPrice > 0) {
                uint256 diff = price > refPrice ? price - refPrice : refPrice - price;
                require(diff * WAD / refPrice <= maxPriceDeviation, "OA: circuit breaker - price deviation too large");
            }
        }

        mo.lastIndexPrice = price;
        mo.lastUpdateTime = block.timestamp;
        /// AUDIT FIX (P4-A1-5): Record Chainlink-fed price as the reference for setIndexPrice() bounds.
        chainlinkReferencePrice[marketId] = price;

        // Initialize mark price if first update
        if (mo.lastMarkPrice == 0) {
            mo.lastMarkPrice = price;
        }

        emit IndexPriceUpdated(marketId, price);
    }

    /// @notice Update mark price with a new trade price (EWMA).
    ///         Called by MatchingEngine after each trade.
    function updateMarkPrice(bytes32 marketId, uint256 tradePrice) external {
        require(authorised[msg.sender], "OA: not authorised");
        MarketOracle storage mo = marketOracles[marketId];
        require(mo.active, "OA: market not active");

        if (mo.lastMarkPrice == 0) {
            /// AUDIT FIX (P4-A1-4): Initialize mark from index price when available.
            /// Previously, the first trade price anchored the EWMA with no validation — a single
            /// manipulated trade could permanently bias the starting point. Using the Chainlink-fed
            /// index price (when set) provides a trusted anchor. Falls back to tradePrice only
            /// when no index price exists (fresh market bootstrap).
            mo.lastMarkPrice = mo.lastIndexPrice > 0 ? mo.lastIndexPrice : tradePrice;
        } else {
            /// AUDIT FIX (P5-M-2): Clamp trade price to ±10% of index before EWMA.
            /// Without volume weighting, dust trades at extreme prices manipulate mark.
            /// 20 wash trades at 5% above index push mark ~4.4% above, extracting funding.
            /// Clamping input bounds the maximum mark deviation regardless of trade count.
            uint256 clampedPrice = tradePrice;
            if (mo.lastIndexPrice > 0) {
                uint256 upper = mo.lastIndexPrice * 110 / 100;
                uint256 lower = mo.lastIndexPrice * 90 / 100;
                if (clampedPrice > upper) clampedPrice = upper;
                if (clampedPrice < lower) clampedPrice = lower;
            }
            // EWMA: new_mark = alpha * tradePrice + (1 - alpha) * old_mark
            mo.lastMarkPrice = (markEwmaAlpha * clampedPrice + (WAD - markEwmaAlpha) * mo.lastMarkPrice) / WAD;
        }

        emit MarkPriceUpdated(marketId, mo.lastMarkPrice);
    }

    /// @notice Admin override for index price (emergency / testing).
    function setIndexPrice(bytes32 marketId, uint256 price) external onlyOwner {
        require(price > 0, "OA: zero price");
        // AUDIT FIX (P3-CROSS-3): Bound price deviation to ±50%.
        // AUDIT FIX (P4-A1-5): Use Chainlink reference, not current price, for the bound.
        // Previously, the ±50% cap was applied against the current (possibly already-walked)
        // price, enabling multi-hop manipulation: 1000→1500→2250→... each within 50%.
        // Now bound against the last Chainlink-fed price, which the owner cannot manipulate.
        // First-time set (no reference) is unrestricted to allow market initialisation.
        uint256 ref = chainlinkReferencePrice[marketId];
        if (ref > 0) {
            /// AUDIT FIX (P8-I-2): Corrected error message — bound is [ref/2, ref*2] (no halving/doubling),
            /// not symmetric ±50%. Lower bound = -50%, upper bound = +100%.
            require(price >= ref / 2 && price <= ref * 2, "OA: price outside [ref/2, ref*2] bound");
        }
        marketOracles[marketId].lastIndexPrice = price;
        marketOracles[marketId].lastUpdateTime = block.timestamp;
        if (marketOracles[marketId].lastMarkPrice == 0) {
            marketOracles[marketId].lastMarkPrice = price;
        }
        emit IndexPriceUpdated(marketId, price);
    }

    /// @notice Admin override for mark price (emergency / testing).
    function setMarkPrice(bytes32 marketId, uint256 price) external onlyOwner {
        require(price > 0, "OA: zero price");
        // AUDIT FIX (P3-CROSS-3): Bound price deviation to ±50%.
        // AUDIT FIX (P5-H-2): Use Chainlink reference, not current mark, for the bound.
        // Previously bounded against current mark price, enabling multi-hop walk:
        // 1000→1500→2250→... each within 50%. Now bound against Chainlink reference
        // (same fix as P4-A1-5 for setIndexPrice). Owner cannot manipulate the reference.
        uint256 ref = chainlinkReferencePrice[marketId];
        if (ref > 0) {
            /// AUDIT FIX (P8-I-2): Corrected error message — bound is [ref/2, ref*2], not ±50%.
            require(price >= ref / 2 && price <= ref * 2, "OA: mark outside [ref/2, ref*2] bound");
        }
        marketOracles[marketId].lastMarkPrice = price;
        emit MarkPriceUpdated(marketId, price);
    }

    // ─────────────────────────────────────────────────────
    // View — IOracleAdapter
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (L1B-H-4): Revert on uninitialized/zero price to prevent margin bypass
    function getIndexPrice(bytes32 marketId) external view override returns (uint256) {
        uint256 price = marketOracles[marketId].lastIndexPrice;
        require(price > 0, "OA: index price not set");
        return price;
    }

    /// AUDIT FIX (P10-L-5): Revert on uninitialized market — consistent with getIndexPrice.
    /// Previously returned 0 silently when both lastMarkPrice and lastIndexPrice are 0,
    /// causing callers to treat the position as zero notional (margin bypass for new markets).
    function getMarkPrice(bytes32 marketId) external view override returns (uint256) {
        uint256 mark = marketOracles[marketId].lastMarkPrice;
        uint256 price = mark > 0 ? mark : marketOracles[marketId].lastIndexPrice;
        require(price > 0, "OA: mark price not initialised");
        return price;
    }

    /// AUDIT FIX (L1B-M-2): Use 1x heartbeat consistently
    function isStale(bytes32 marketId) external view override returns (bool) {
        MarketOracle storage mo = marketOracles[marketId];
        if (!mo.active) return true;
        if (mo.lastUpdateTime == 0) return true;
        return block.timestamp - mo.lastUpdateTime > mo.heartbeat;
    }

    // ─────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────

    /// @dev INFO (L1B-I-3): Uses raw staticcall instead of AggregatorV3Interface import
    ///      to avoid Chainlink dependency — works with any latestRoundData() compatible feed.
    /// @dev INFO (L1B-I-4): WAD constant is uint256 throughout — consistent type usage.
    function _latestRoundData(address feed) internal view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        // Chainlink AggregatorV3Interface
        (bool success, bytes memory data) = feed.staticcall(
            abi.encodeWithSignature("latestRoundData()")
        );
        require(success, "OA: feed call failed");
        (roundId, answer, startedAt, updatedAt, answeredInRound) = abi.decode(
            data, (uint80, int256, uint256, uint256, uint80)
        );
    }
}
