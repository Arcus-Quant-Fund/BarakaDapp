// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IOrderBook.sol";
import "../interfaces/IMarginEngine.sol";
import "../interfaces/ISubaccountManager.sol";
import "../interfaces/IShariahRegistry.sol";
import "../interfaces/IFeeEngine.sol";
import "../interfaces/IOracleAdapter.sol";
import "../interfaces/IAutoDeleveraging.sol";

// AUDIT FIX (P3-CROSS-6): Minimal interface for ComplianceOracle. MatchingEngine previously had
// no reference to ComplianceOracle at all, so Shariah compliance was never enforced at fill time.
interface IComplianceOracle {
    function isCompliant(bytes32 marketId) external view returns (bool);
}

/**
 * @title MatchingEngine
 * @author Baraka Protocol v2
 * @notice Orchestrates order placement, matching, and settlement.
 *
 *         Flow:
 *           1. User calls placeOrder() with subaccount, market, side, price, size
 *           2. ShariahRegistry validates the order (asset approval, leverage check)
 *           3. MarginEngine checks initial margin (free collateral >= new IMR)
 *           4. OrderBook matches against resting orders
 *           5. For each fill: MarginEngine.updatePosition() for both maker and taker
 *           6. FeeEngine charges maker/taker fees
 *           7. Remaining size rests on book (GTC) or is cancelled (IOC/FOK)
 *
 *         MEV protection (optional per-market):
 *           Commit-reveal: trader submits hash first, reveals order after N blocks.
 *           Prevents front-running and sandwich attacks.
 */
contract MatchingEngine is Ownable2Step, Pausable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────
    // Dependencies
    // ─────────────────────────────────────────────────────

    ISubaccountManager public immutable subaccountManager;
    IMarginEngine      public immutable marginEngine;
    IShariahRegistry   public immutable shariahRegistry;

    /// @notice marketId → OrderBook contract
    mapping(bytes32 => IOrderBook) public orderBooks;

    /// @notice Fee engine (optional — fees disabled if not set)
    IFeeEngine public feeEngine;

    /// @notice Fee recipients (used when FeeEngine not set)
    address public treasury;
    address public insuranceFund;

    /// @notice Fee rates (WAD scale, e.g. 0.0005e18 = 5 bps)
    uint256 public takerFeeBps = 5e14;  // 5 bps = 0.05%
    int256  public makerFeeBps = -5e13; // -0.5 bps = -0.005% (rebate)

    /// AUDIT FIX (P2-HIGH-6): Oracle adapter for EWMA mark price updates after each fill.
    /// MatchingEngine was not feeding trade prices into the oracle — EWMA was non-functional.
    IOracleAdapter public oracle;

    /// AUDIT FIX (P3-CROSS-6): ComplianceOracle enforces Shariah compliance at fill time.
    /// Previously absent — fills for non-compliant markets were never blocked by the engine.
    IComplianceOracle public complianceOracle;

    /// AUDIT FIX (P7-M-2): ADL participant registry — register traders after successful fills
    /// so ADL has a populated counterparty list when needed.
    IAutoDeleveraging public adl;

    // ─────────────────────────────────────────────────────
    // MEV Protection — Commit-Reveal
    // ─────────────────────────────────────────────────────

    /// @notice Markets with commit-reveal enabled
    mapping(bytes32 => bool) public commitRevealEnabled;

    /// @notice Commit-reveal delay (blocks)
    uint256 public commitRevealDelay = 1;

    /// @notice commitHash → commit block number
    mapping(bytes32 => uint256) public commits;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event OrderBookSet(bytes32 indexed marketId, address orderBook);
    event OrderSubmitted(
        bytes32 indexed marketId,
        bytes32 indexed subaccount,
        bytes32 orderId,
        IOrderBook.Side side,
        uint256 price,
        uint256 size,
        uint256 fillCount
    );
    event CommitSubmitted(bytes32 indexed commitHash, address indexed sender, uint256 blockNumber);
    /// AUDIT FIX (L1-M-8): Event emitted when fee processing fails (trading continues)
    event FeeProcessingFailed(bytes32 indexed marketId, bytes32 indexed takerSubaccount, bytes32 indexed makerSubaccount);
    /// AUDIT FIX (P3-CLOB-6): Emitted when a maker's updatePosition reverts (insolvent maker).
    /// The maker order is cancelled and the taker fill continues uninterrupted.
    event MakerCancelledInsolvent(bytes32 indexed marketId, bytes32 indexed makerOrderId, bytes32 indexed makerSubaccount);
    /// AUDIT FIX (P10-C-1): Emitted when taker reversal fails after insolvent maker — OI invariant broken.
    event TakerReversalFailed(bytes32 indexed marketId, bytes32 indexed takerSubaccount, int256 takerDelta);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(
        address initialOwner,
        address _subaccountManager,
        address _marginEngine,
        address _shariahRegistry
    ) Ownable(initialOwner) {
        require(_subaccountManager != address(0), "MaE: zero SAM");
        require(_marginEngine != address(0), "MaE: zero ME");
        require(_shariahRegistry != address(0), "MaE: zero SR");

        subaccountManager = ISubaccountManager(_subaccountManager);
        marginEngine = IMarginEngine(_marginEngine);
        shariahRegistry = IShariahRegistry(_shariahRegistry);
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setOrderBook(bytes32 marketId, address orderBook) external onlyOwner {
        require(orderBook != address(0), "MaE: zero OB");
        orderBooks[marketId] = IOrderBook(orderBook);
        emit OrderBookSet(marketId, orderBook);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "MaE: zero treasury");
        treasury = _treasury;
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        require(_insuranceFund != address(0), "MaE: zero IF");
        insuranceFund = _insuranceFund;
    }

    function setFeeEngine(address _feeEngine) external onlyOwner {
        feeEngine = IFeeEngine(_feeEngine);
    }

    /// AUDIT FIX (L1-M-4): Cap fee rates — prevent owner setting 100% fees
    function setFees(uint256 _takerBps, int256 _makerBps) external onlyOwner {
        require(_takerBps <= 50e14, "MaE: taker fee > 50 bps");
        require(_makerBps >= -50e14 && _makerBps <= 50e14, "MaE: maker fee out of range");
        takerFeeBps = _takerBps;
        makerFeeBps = _makerBps;
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "MaE: zero oracle");
        oracle = IOracleAdapter(_oracle);
    }

    /// AUDIT FIX (P3-CROSS-6): Setter for ComplianceOracle. When set, every fill execution
    /// checks that the market is Shariah-compliant before settling positions.
    /// AUDIT FIX (P4-A4-8): Allow setting to address(0) to clear the compliance oracle.
    /// ComplianceOracle is optional — _processFill() guards with an address(0) check.
    /// Blocking zero prevents removal of a broken or migrated oracle without a dummy shim.
    function setComplianceOracle(address _complianceOracle) external onlyOwner {
        complianceOracle = IComplianceOracle(_complianceOracle);
    }

    /// AUDIT FIX (P7-M-2): Set ADL contract for participant registration after fills.
    function setADL(address _adl) external onlyOwner {
        adl = IAutoDeleveraging(_adl);
    }

    function setCommitReveal(bytes32 marketId, bool enabled) external onlyOwner {
        commitRevealEnabled[marketId] = enabled;
    }

    /// AUDIT FIX (P10-H-6 + P10-L-2): Enforce min=1 and max=256 on commitRevealDelay.
    /// Min=1: delay=0 allows same-block commit+reveal, defeating MEV protection entirely.
    /// Max=256: reveal window is [commitBlock+delay, commitBlock+delay+256]. If delay>256,
    /// the window opens AFTER the commit has already expired — all commits become permanently
    /// unrevealable, bricking all commit-reveal markets.
    function setCommitRevealDelay(uint256 blocks) external onlyOwner {
        require(blocks >= 1,   "MaE: delay must be >= 1 block");
        require(blocks <= 256, "MaE: delay exceeds commit reveal window");
        commitRevealDelay = blocks;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("MaE: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // Core — place order
    // ─────────────────────────────────────────────────────

    /// @notice Place an order on a market. Validates Shariah compliance and margin.
    function placeOrder(
        bytes32 marketId,
        bytes32 subaccount,
        IOrderBook.Side side,
        uint256 price,
        uint256 size,
        IOrderBook.OrderType orderType,
        IOrderBook.TimeInForce tif
    ) external nonReentrant whenNotPaused returns (bytes32 orderId) {
        // Ownership check
        require(subaccountManager.getOwner(subaccount) == msg.sender, "MaE: not owner");
        /// AUDIT FIX (P7-L-2): Enforce subaccount existence — closed subaccounts cannot trade.
        require(subaccountManager.exists(subaccount), "MaE: subaccount closed");
        require(address(orderBooks[marketId]) != address(0), "MaE: no orderbook");

        // AUDIT FIX (L1-M-3): Block direct placeOrder when commit-reveal is enabled
        require(!commitRevealEnabled[marketId], "MaE: use commit-reveal for this market");

        // Shariah compliance — halt check + asset approval
        require(!shariahRegistry.isProtocolHalted(), "MaE: Shariah halt");
        require(shariahRegistry.isApprovedAsset(marketId), "MaE: asset not approved");
        /// AUDIT FIX (P4-A4-10): Enforce Shariah leverage cap. ShariahRegistry.validateOrder()
        /// was never called, making per-market maxLeverage dead code. Inline the leverage check:
        /// verify the market's IMR >= 1/maxLeverage so effective leverage is Shariah-bounded.
        {
            uint256 maxLev = shariahRegistry.maxLeverage(marketId);
            IMarginEngine.MarketParams memory mktParams = marginEngine.getMarketParams(marketId);
            require(mktParams.initialMarginRate >= 1e18 / maxLev, "MaE: market exceeds Shariah leverage");
        }

        // Pre-trade margin check: ensure subaccount has enough free collateral
        // for the worst case (full fill at limit price)
        /// AUDIT FIX (P15-H-1): Compute required initial margin for this specific order,
        /// not just check freeCol >= 0. Previously, $1 free collateral could place a $1M order.
        /// AUDIT FIX (P15-H-3): Require price > 0 for MEV/slippage protection on market orders.
        /// Market orders with price=0 fill at any price — fully exposed to sandwich attacks.
        require(price > 0, "MaE: price required for slippage protection");
        if (!_isReducingPosition(subaccount, marketId, side, size)) {
            int256 freeCol = marginEngine.getFreeCollateral(subaccount);
            require(freeCol >= 0, "MaE: insufficient margin");
            // P15-H-1: Check that free collateral covers required initial margin for this order
            IMarginEngine.MarketParams memory mktParams = marginEngine.getMarketParams(marketId);
            uint256 requiredMargin = Math.mulDiv(
                Math.mulDiv(size, price, 1e18),
                mktParams.initialMarginRate,
                1e18
            );
            require(freeCol >= int256(requiredMargin), "MaE: insufficient margin for order size");
        }

        // Place on orderbook
        IOrderBook.Fill[] memory fills;
        (orderId, fills) = orderBooks[marketId].placeOrder(
            subaccount, side, price, size, orderType, tif
        );

        // Process fills — update positions and charge fees
        for (uint256 i = 0; i < fills.length; i++) {
            _processFill(marketId, fills[i]);
        }

        emit OrderSubmitted(marketId, subaccount, orderId, side, price, size, fills.length);
    }

    // ─────────────────────────────────────────────────────
    // Core — commit-reveal (MEV protection)
    // ─────────────────────────────────────────────────────

    /// @notice Step 1: Submit order hash. Order details are hidden.
    function commitOrder(bytes32 commitHash) external whenNotPaused {
        require(commits[commitHash] == 0, "MaE: already committed");
        commits[commitHash] = block.number;
        emit CommitSubmitted(commitHash, msg.sender, block.number);
    }

    /// @notice Step 2: Reveal and execute the order after delay.
    function revealOrder(
        bytes32 marketId,
        bytes32 subaccount,
        IOrderBook.Side side,
        uint256 price,
        uint256 size,
        IOrderBook.OrderType orderType,
        IOrderBook.TimeInForce tif,
        bytes32 nonce
    ) external nonReentrant whenNotPaused returns (bytes32 orderId) {
        require(commitRevealEnabled[marketId], "MaE: commit-reveal not enabled");

        // Verify commit
        /// AUDIT FIX (P10-H-5): Include block.chainid and address(this) for domain separation.
        /// Without these, a commit on Ethereum mainnet has the same hash on Arbitrum — an observer
        /// can replay a valid testnet commit on mainnet. This mirrors EIP-712 domain separator.
        bytes32 commitHash = keccak256(abi.encodePacked(
            block.chainid, address(this),
            marketId, subaccount, side, price, size, orderType, tif, nonce, msg.sender
        ));
        uint256 commitBlock = commits[commitHash];
        require(commitBlock > 0, "MaE: no commit found");
        require(block.number >= commitBlock + commitRevealDelay, "MaE: reveal too early");
        require(block.number <= commitBlock + commitRevealDelay + 256, "MaE: commit expired");

        // Clear commit
        delete commits[commitHash];

        // Ownership check
        require(subaccountManager.getOwner(subaccount) == msg.sender, "MaE: not owner");
        /// AUDIT FIX (P7-L-2): Enforce subaccount existence — closed subaccounts cannot trade.
        require(subaccountManager.exists(subaccount), "MaE: subaccount closed");

        // Shariah compliance
        require(!shariahRegistry.isProtocolHalted(), "MaE: Shariah halt");
        require(shariahRegistry.isApprovedAsset(marketId), "MaE: asset not approved");
        /// AUDIT FIX (P4-A4-10): Enforce Shariah leverage cap in commit-reveal path too.
        {
            uint256 maxLev = shariahRegistry.maxLeverage(marketId);
            IMarginEngine.MarketParams memory mktParams = marginEngine.getMarketParams(marketId);
            require(mktParams.initialMarginRate >= 1e18 / maxLev, "MaE: market exceeds Shariah leverage");
        }

        // AUDIT FIX (L1-H-1): Add margin check to revealOrder (was missing — could open
        // unbacked positions via commit-reveal path)
        // AUDIT FIX (P15-H-1 + P15-H-3): Same pre-trade margin checks as placeOrder
        require(price > 0, "MaE: price required for slippage protection");
        if (!_isReducingPosition(subaccount, marketId, side, size)) {
            int256 freeCol = marginEngine.getFreeCollateral(subaccount);
            require(freeCol >= 0, "MaE: insufficient margin");
            IMarginEngine.MarketParams memory mktParams2 = marginEngine.getMarketParams(marketId);
            uint256 requiredMargin = Math.mulDiv(
                Math.mulDiv(size, price, 1e18),
                mktParams2.initialMarginRate,
                1e18
            );
            require(freeCol >= int256(requiredMargin), "MaE: insufficient margin for order size");
        }

        // Place on orderbook
        IOrderBook.Fill[] memory fills;
        (orderId, fills) = orderBooks[marketId].placeOrder(
            subaccount, side, price, size, orderType, tif
        );

        for (uint256 i = 0; i < fills.length; i++) {
            _processFill(marketId, fills[i]);
        }

        emit OrderSubmitted(marketId, subaccount, orderId, side, price, size, fills.length);
    }

    // ─────────────────────────────────────────────────────
    // Core — cancel
    // ─────────────────────────────────────────────────────

    function cancelOrder(bytes32 marketId, bytes32 orderId) external nonReentrant {
        IOrderBook ob = orderBooks[marketId];
        IOrderBook.Order memory order = ob.getOrder(orderId);
        require(subaccountManager.getOwner(order.subaccount) == msg.sender, "MaE: not owner");
        ob.cancelOrder(orderId);
    }

    /// AUDIT FIX (P8-I-1): Proxy for OrderBook.cancelAllOrders(). Without this, users must cancel
    /// each order individually — operationally burdensome during emergencies for market makers
    /// with up to 200 resting orders (the P7-M-1 cap).
    function cancelAllOrders(bytes32 marketId, bytes32 subaccount) external nonReentrant {
        require(subaccountManager.getOwner(subaccount) == msg.sender, "MaE: not owner");
        require(address(orderBooks[marketId]) != address(0), "MaE: no orderbook");
        orderBooks[marketId].cancelAllOrders(subaccount);
    }

    // ─────────────────────────────────────────────────────
    // Internal — fill processing
    // ─────────────────────────────────────────────────────

    function _processFill(bytes32 marketId, IOrderBook.Fill memory fill) internal {
        // AUDIT FIX (P3-CROSS-6): Enforce ComplianceOracle before settling any fill.
        // Previously, MatchingEngine had no reference to ComplianceOracle — fills for
        // non-compliant (e.g. newly-delisted) markets were processed without any check.
        if (address(complianceOracle) != address(0)) {
            require(complianceOracle.isCompliant(marketId), "ME: market not compliant");
        }

        /// AUDIT FIX (P15-M-7): Block self-trade — same subaccount on both sides.
        /// Prevents wash-trading, volume manipulation, and mark price manipulation
        /// when a user's own resting order matches their incoming order.
        require(fill.makerSubaccount != fill.takerSubaccount, "MaE: self-trade");

        /// AUDIT FIX (P9-M-1): Block self-trading (same owner on both sides).
        /// Prevents cross-account opposing position attacks where an attacker opens
        /// long+short via two subaccounts, liquidates the losing side, and profits from
        /// the winning side. Real-world ref: Mango Markets $117M exploit pattern.
        require(
            subaccountManager.getOwner(fill.takerSubaccount) != subaccountManager.getOwner(fill.makerSubaccount),
            "MaE: self-trade not allowed"
        );

        // Determine maker/taker sides
        int256 takerDelta;
        int256 makerDelta;

        if (fill.takerSide == IOrderBook.Side.Buy) {
            takerDelta = int256(fill.size);   // taker is buying (long)
            makerDelta = -int256(fill.size);  // maker was selling (short)
        } else {
            takerDelta = -int256(fill.size);  // taker is selling (short)
            makerDelta = int256(fill.size);   // maker was buying (long)
        }

        // Update taker position first — taker side must always succeed (reverts bubble up to caller).
        marginEngine.updatePosition(fill.takerSubaccount, marketId, takerDelta, fill.price);

        // P3-CLOB-6 FIX: Insolvent maker must not revert taker — cancel and skip.
        // AUDIT FIX (P10-C-1): Track whether fill fully settled via makerSucceeded flag.
        // Oracle update and fee charging must ONLY occur when both sides committed.
        // Previously, oracle.updateMarkPrice() and feeEngine.processTradeFees() were called
        // unconditionally — even when the maker reverted and the taker position was reversed.
        // This caused phantom mark price updates and fee charges for fills that never settled,
        // enabling oracle manipulation and free-fee extraction by griefing the maker side.
        bool makerSucceeded = false;
        try marginEngine.updatePosition(fill.makerSubaccount, marketId, makerDelta, fill.price) {
            makerSucceeded = true;
            /// AUDIT FIX (P7-M-2): Register both taker and maker as market participants
            /// for ADL ranking. Without this, ADL iterates an empty list and cannot cover
            /// shortfalls when InsuranceFund is exhausted.
            if (address(adl) != address(0)) {
                try adl.registerParticipant(marketId, fill.takerSubaccount) {} catch {}
                try adl.registerParticipant(marketId, fill.makerSubaccount) {} catch {}
            }
        } catch {
            /// AUDIT FIX (P4-A4-1): Maker insolvent — reverse the taker's position update first.
            /// Without reversal, the taker holds an open position with no counterparty: open interest
            /// becomes asymmetric, funding settlement diverges, and the system cannot be made whole.
            /// Reversal uses -takerDelta to exactly unwind the position just applied above.
            bool reversed = false;
            try marginEngine.updatePosition(fill.takerSubaccount, marketId, -takerDelta, fill.price) {
                reversed = true;
            } catch {}
            /// AUDIT FIX (P15-C-1): Revert if taker reversal fails — unbacked OI breaks solvency.
            /// Previously (P10-C-1) emitted TakerReversalFailed event and continued, creating
            /// asymmetric open interest. Both sides must commit or neither — atomic settlement
            /// is non-negotiable. If this reverts, the entire fill is rolled back.
            require(reversed, "MaE: atomic fill failure - taker reversal impossible");
            IOrderBook ob = orderBooks[marketId];
            try ob.cancelOrder(fill.makerOrderId) {} catch {}
            emit MakerCancelledInsolvent(marketId, fill.makerOrderId, fill.makerSubaccount);
        }

        // Only update oracle and charge fees when the fill actually settled on both sides.
        // AUDIT FIX (P10-C-1): Gate oracle + fee calls behind makerSucceeded.
        if (makerSucceeded) {
            // Update EWMA mark price in oracle
            /// AUDIT FIX (P2-HIGH-6): Feed each fill price into oracle EWMA. Without this call,
            /// mark price is stuck at the initial value and funding rates are wrong.
            if (address(oracle) != address(0)) {
                try oracle.updateMarkPrice(marketId, fill.price) {} catch {}
            }

            // Charge fees via FeeEngine (if set)
            // AUDIT FIX (L1B-H-3): Use processTradeFees (atomic taker+maker) to avoid phantom balance
            // AUDIT FIX (L1-M-8): Try/catch — fee failure should not brick trading
            if (address(feeEngine) != address(0)) {
                /// AUDIT FIX (P2-HIGH-7): Use Math.mulDiv to prevent overflow on extreme size×price products
                uint256 notional = Math.mulDiv(fill.size, fill.price, 1e18);
                try feeEngine.processTradeFees(fill.takerSubaccount, fill.makerSubaccount, notional) {
                } catch {
                    emit FeeProcessingFailed(marketId, fill.takerSubaccount, fill.makerSubaccount);
                }
            }
        }
    }

    /// AUDIT FIX (P15-H-4): Check both direction AND size — prevents disguising position-opening
    /// orders as reducing trades. Previously, a user with 1 BTC long could place a 100 BTC short
    /// "reducing" order, bypassing initial margin checks for the 99 BTC net short position.
    function _isReducingPosition(
        bytes32 subaccount,
        bytes32 marketId,
        IOrderBook.Side side,
        uint256 orderSize
    ) internal view returns (bool) {
        IMarginEngine.Position memory pos = marginEngine.getPosition(subaccount, marketId);
        if (pos.size == 0) return false;
        // Reducing = opposite direction AND order size <= position size
        if (pos.size > 0 && side == IOrderBook.Side.Sell) return orderSize <= uint256(pos.size);
        if (pos.size < 0 && side == IOrderBook.Side.Buy) return orderSize <= uint256(-pos.size);
        return false;
    }
}
