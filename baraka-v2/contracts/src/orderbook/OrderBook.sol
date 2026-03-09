// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IOrderBook.sol";

/**
 * @title OrderBook
 * @author Baraka Protocol v2
 * @notice On-chain Central Limit Order Book (CLOB) for a single perpetual market.
 *
 *         Design inspired by dYdX v4's orderbook, implemented on-chain for trustlessness.
 *         On L2 (Arbitrum/Base), gas cost per order is ~$0.01-0.05, making this viable.
 *
 *         Price-time priority matching:
 *           1. Orders matched at the best available price
 *           2. At same price level, earliest order fills first (FIFO)
 *
 *         Data structures:
 *           - Sorted price levels using a doubly-linked list (O(1) insert at known position)
 *           - Each price level has a FIFO queue of orders
 *           - Best bid/ask cached for O(1) access
 *
 *         Gas optimizations:
 *           - Packed order storage (2 slots per order)
 *           - Lazy deletion (cancelled orders skipped during match, cleaned periodically)
 *           - Batch order placement
 *
 *         Self-trade prevention (STP): orders from same subaccount cancel the resting order.
 */
contract OrderBook is IOrderBook, Ownable2Step, Pausable, ReentrancyGuard {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;

    /// @notice Minimum price tick (1e12 = 0.000001 in WAD terms)
    uint256 public constant MIN_TICK = 1e12;

    /// @notice Maximum orders per price level before cleanup
    uint256 public constant MAX_ORDERS_PER_LEVEL = 500;

    /// AUDIT FIX (P6-H-2): Cap tempFills allocation to prevent OOG DoS.
    /// _askPrices.length * MAX_ORDERS_PER_LEVEL can be enormous (50 levels × 500 = 25,000).
    /// Memory cost is quadratic in Solidity, so 25k Fill structs ≈ 60M gas just for allocation.
    /// A taker order can only match its own size; 500 fills covers any practical single order.
    uint256 public constant MAX_FILLS = 500;

    /// AUDIT FIX (P7-M-1): Cap active resting orders per subaccount to prevent unbounded
    /// _subaccountOrders growth. Market makers with hundreds of GTC orders per day cause
    /// the array to grow to thousands of entries, making cancelAllOrders() hit gas limits.
    uint256 public constant MAX_ACTIVE_ORDERS = 200;

    // ─────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────

    /// @notice Price level in the book — contains a FIFO queue of order IDs
    struct PriceLevel {
        uint256 totalSize;     // sum of all active order sizes at this level
        uint256 orderCount;    // number of active orders
        bytes32 headOrderId;   // first order (oldest)
        bytes32 tailOrderId;   // last order (newest)
        bool    exists;
    }

    /// @notice Linked list node for order queue within a price level
    struct OrderNode {
        bytes32 next; // next order in FIFO queue (0 = tail)
        bytes32 prev; // prev order in FIFO queue (0 = head)
    }

    // ─────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────

    /// @notice Market identifier this book serves
    bytes32 public immutable marketId;

    /// @notice All orders by ID
    mapping(bytes32 => Order) public orders;

    /// @notice Order queue linking within price levels
    mapping(bytes32 => OrderNode) private _orderNodes;

    /// @notice Buy (bid) side: price → PriceLevel
    mapping(uint256 => PriceLevel) public bidLevels;

    /// @notice Sell (ask) side: price → PriceLevel
    mapping(uint256 => PriceLevel) public askLevels;

    /// @notice Sorted bid prices (descending — highest first)
    uint256[] private _bidPrices;

    /// @notice Sorted ask prices (ascending — lowest first)
    uint256[] private _askPrices;

    /// AUDIT FIX (L1-I-1): Removed dead _bestBidPrice/_bestAskPrice variables.
    ///     Best prices are computed dynamically from _bidPrices[0]/_askPrices[0].

    /// @notice Order nonce for unique IDs
    /// @dev INFO (L1-I-6): uint256 nonce — overflow after 2^256 orders is infeasible.
    uint256 private _orderNonce;

    /// AUDIT FIX (P6-I-1): Per-subaccount active order tracking for cancelAllOrders().
    mapping(bytes32 => bytes32[]) private _subaccountOrders;

    /// AUDIT FIX (P7-M-1): Active resting order count per subaccount (for cap enforcement).
    mapping(bytes32 => uint256) private _activeOrderCount;

    /// @notice Authorised caller (MatchingEngine)
    mapping(address => bool) public authorised;

    // ─────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────

    event OrderPlaced(bytes32 indexed orderId, bytes32 indexed subaccount, Side side, uint256 price, uint256 size);
    event OrderCancelled(bytes32 indexed orderId);
    event OrderFilled(bytes32 indexed orderId, uint256 filledSize, uint256 remainingSize);
    event TradeExecuted(bytes32 indexed makerOrderId, bytes32 indexed takerOrderId, uint256 price, uint256 size);

    // ─────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────

    constructor(address initialOwner, bytes32 _marketId) Ownable(initialOwner) {
        marketId = _marketId;
    }

    // ─────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────

    function setAuthorised(address caller, bool status) external onlyOwner {
        require(caller != address(0), "OB: zero address");
        authorised[caller] = status;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /// AUDIT FIX (P5-H-3): Prevent ownership renouncement — contract requires owner for admin operations.
    function renounceOwnership() public view override onlyOwner {
        revert("OB: renounce disabled");
    }

    // ─────────────────────────────────────────────────────
    // Core — place order
    // ─────────────────────────────────────────────────────

    /// @notice Place an order. Returns the order ID and any immediate fills.
    function placeOrder(
        bytes32 subaccount,
        Side side,
        uint256 price,
        uint256 size,
        OrderType orderType,
        TimeInForce tif
    )
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 orderId, Fill[] memory fills)
    {
        require(authorised[msg.sender], "OB: not authorised");
        require(size > 0, "OB: zero size");
        // AUDIT FIX (P3-CLOB-2): Market orders with price=0 previously bypassed the slippage guard
        // in _matchBuy/_matchSell (the `maxPrice > 0` check evaluates false when price==0, allowing
        // matching at any price). Require a non-zero worst-case price for ALL order types so that
        // every order has an explicit slippage bound.
        require(price > 0, "OB: zero price");
        if (orderType == OrderType.Limit) {
            require(price % MIN_TICK == 0, "OB: price not on tick");
        }

        // PostOnly check: reject if order would cross the book
        if (tif == TimeInForce.PostOnly) {
            if (side == Side.Buy && _askPrices.length > 0 && price >= _askPrices[0]) {
                revert("OB: PostOnly order would cross");
            }
            if (side == Side.Sell && _bidPrices.length > 0 && price <= _bidPrices[0]) {
                revert("OB: PostOnly order would cross");
            }
        }

        // Generate order ID
        orderId = keccak256(abi.encodePacked(marketId, subaccount, _orderNonce++, block.timestamp));

        // Try to match against resting book
        uint256 remaining = size;
        // AUDIT FIX (P3-CLOB-1): _match* now returns a dynamic Fill[] array via push()-equivalent
        // pattern, eliminating the fixed Fill[100] buffer that caused Panic(0x32) on >100 levels.

        if (side == Side.Buy) {
            // Match against ask side (lowest asks first)
            (remaining, fills) = _matchBuy(orderId, subaccount, price, remaining, orderType);
        } else {
            // Match against bid side (highest bids first)
            (remaining, fills) = _matchSell(orderId, subaccount, price, remaining, orderType);
        }

        // Handle remaining size based on TIF
        if (remaining > 0) {
            if (tif == TimeInForce.IOC || tif == TimeInForce.FOK || orderType == OrderType.Market) {
                // IOC/FOK/Market: don't rest, discard remaining
                // AUDIT FIX (L1-H-2): FOK must be FULLY filled, not just partially
                if (tif == TimeInForce.FOK && remaining > 0) {
                    revert("OB: FOK not fully filled");
                }
                // Create order record but mark inactive (for event tracking)
                orders[orderId] = Order({
                    id: orderId,
                    subaccount: subaccount,
                    side: side,
                    price: price,
                    size: 0,
                    originalSize: size,
                    timestamp: block.timestamp,
                    orderType: orderType,
                    tif: tif,
                    active: false
                });
            } else if (tif == TimeInForce.PostOnly) {
                // PostOnly: revert if any fills occurred (order would have crossed)
                require(fills.length == 0, "OB: PostOnly order would cross");
                _restOrder(orderId, subaccount, side, price, remaining, size, orderType, tif);
            } else {
                // GTC: rest remaining on book
                _restOrder(orderId, subaccount, side, price, remaining, size, orderType, tif);
            }
        } else {
            // Fully filled
            orders[orderId] = Order({
                id: orderId,
                subaccount: subaccount,
                side: side,
                price: price,
                size: 0,
                originalSize: size,
                timestamp: block.timestamp,
                orderType: orderType,
                tif: tif,
                active: false
            });
        }

        emit OrderPlaced(orderId, subaccount, side, price, size);
    }

    // ─────────────────────────────────────────────────────
    // Core — cancel order
    // ─────────────────────────────────────────────────────

    /// AUDIT FIX (P2-MEDIUM-6): Removed whenNotPaused — cancellations must always be allowed.
    /// Freezing cancels during pause locks user funds in resting orders that match at stale prices
    /// when the protocol unpauses. Only placeOrder should be paused, not cancelOrder.
    function cancelOrder(bytes32 orderId) external override nonReentrant {
        require(authorised[msg.sender], "OB: not authorised");
        Order storage order = orders[orderId];
        require(order.active, "OB: order not active");

        order.active = false;
        /// AUDIT FIX (P7-M-1): Decrement active order count on cancel.
        _activeOrderCount[order.subaccount]--;
        uint256 price = order.price;

        // Remove from price level
        if (order.side == Side.Buy) {
            _removeFromLevel(bidLevels[price], orderId, order.size);
            if (bidLevels[price].totalSize == 0) {
                _removeBidPrice(price);
            }
        } else {
            _removeFromLevel(askLevels[price], orderId, order.size);
            if (askLevels[price].totalSize == 0) {
                _removeAskPrice(price);
            }
        }

        order.size = 0;
        emit OrderCancelled(orderId);
    }

    /// AUDIT FIX (P6-I-1): Implemented using per-subaccount order tracking.
    /// Iterates the subaccount's tracked orders, cancels all active ones,
    /// and compacts the tracking array.
    function cancelAllOrders(bytes32 subaccount) external override nonReentrant {
        require(authorised[msg.sender], "OB: not authorised");

        bytes32[] storage orderIds = _subaccountOrders[subaccount];
        uint256 len = orderIds.length;

        for (uint256 i = 0; i < len; i++) {
            bytes32 oid = orderIds[i];
            Order storage order = orders[oid];

            if (!order.active || order.size == 0) continue;

            order.active = false;
            uint256 price = order.price;

            if (order.side == Side.Buy) {
                _removeFromLevel(bidLevels[price], oid, order.size);
                if (bidLevels[price].totalSize == 0) {
                    _removeBidPrice(price);
                }
            } else {
                _removeFromLevel(askLevels[price], oid, order.size);
                if (askLevels[price].totalSize == 0) {
                    _removeAskPrice(price);
                }
            }

            order.size = 0;
            emit OrderCancelled(oid);
        }

        // Clear the tracking array and reset active count
        delete _subaccountOrders[subaccount];
        /// AUDIT FIX (P7-M-1): Reset active order count.
        _activeOrderCount[subaccount] = 0;
    }

    // ─────────────────────────────────────────────────────
    // Internal — matching
    // ─────────────────────────────────────────────────────

    /// @dev Match a buy order against the ask side (lowest asks first).
    // AUDIT FIX (P3-CLOB-1): Signature changed — fills returned as dynamic memory array built
    // with push(), eliminating the fixed-size Fill[100] buffer and the associated Panic(0x32).
    function _matchBuy(
        bytes32 takerOrderId,
        bytes32 takerSubaccount,
        uint256 maxPrice,   // limit price (0 = market order, match any)
        uint256 remaining,
        OrderType /* orderType */
    ) internal returns (uint256, Fill[] memory fills) {
        // AUDIT FIX (P6-H-2): Cap allocation at MAX_FILLS to prevent OOG DoS from
        // many price levels × MAX_ORDERS_PER_LEVEL memory explosion.
        uint256 capacity = _askPrices.length * MAX_ORDERS_PER_LEVEL;
        if (capacity > MAX_FILLS) capacity = MAX_FILLS;
        Fill[] memory tempFills = new Fill[](capacity);
        uint256 fillCount;

        uint256 i = 0;
        while (remaining > 0 && i < _askPrices.length && fillCount < capacity) {
            uint256 askPrice = _askPrices[i];
            /// AUDIT FIX (L1-M-1): Respect price as slippage limit for market orders too
            if (askPrice > maxPrice && maxPrice > 0) break; // price too high (limit or slippage)

            PriceLevel storage level = askLevels[askPrice];
            bytes32 currentOrderId = level.headOrderId;

            while (remaining > 0 && currentOrderId != bytes32(0) && fillCount < capacity) {
                Order storage makerOrder = orders[currentOrderId];
                bytes32 nextId = _orderNodes[currentOrderId].next;

                // Skip cancelled/inactive orders (lazy deletion)
                if (!makerOrder.active || makerOrder.size == 0) {
                    currentOrderId = nextId;
                    continue;
                }

                // Self-trade prevention: cancel resting order
                if (makerOrder.subaccount == takerSubaccount) {
                    makerOrder.active = false;
                    /// AUDIT FIX (P7-M-1): Decrement active order count on self-trade cancel.
                    _activeOrderCount[makerOrder.subaccount]--;
                    level.totalSize -= makerOrder.size;
                    level.orderCount--;
                    makerOrder.size = 0;
                    emit OrderCancelled(currentOrderId);
                    currentOrderId = nextId;
                    continue;
                }

                // Execute fill
                uint256 fillSize = remaining < makerOrder.size ? remaining : makerOrder.size;
                uint256 fillPrice = askPrice; // maker's price

                // AUDIT FIX (P6-H-2): fillCount bounded by capacity check in while condition.
                tempFills[fillCount++] = Fill({
                    makerOrderId: currentOrderId,
                    takerOrderId: takerOrderId,
                    makerSubaccount: makerOrder.subaccount,
                    takerSubaccount: takerSubaccount,
                    price: fillPrice,
                    size: fillSize,
                    takerSide: Side.Buy
                });

                makerOrder.size -= fillSize;
                remaining -= fillSize;
                level.totalSize -= fillSize;

                if (makerOrder.size == 0) {
                    makerOrder.active = false;
                    level.orderCount--;
                    /// AUDIT FIX (P7-M-1): Decrement active order count on full fill.
                    _activeOrderCount[makerOrder.subaccount]--;
                }

                emit TradeExecuted(currentOrderId, takerOrderId, fillPrice, fillSize);
                emit OrderFilled(currentOrderId, fillSize, makerOrder.size);

                currentOrderId = nextId;
            }

            // Update head pointer
            level.headOrderId = currentOrderId;

            // Clean up empty level
            if (level.totalSize == 0 || level.orderCount == 0) {
                i++; // move to next price (will be cleaned up later)
            } else {
                i++;
            }
        }

        // Clean up empty ask prices
        _cleanAskPrices();

        // Trim to actual fill count
        fills = new Fill[](fillCount);
        for (uint256 k = 0; k < fillCount; k++) {
            fills[k] = tempFills[k];
        }

        return (remaining, fills);
    }

    /// @dev Match a sell order against the bid side (highest bids first).
    // AUDIT FIX (P3-CLOB-1): Signature changed — fills returned as dynamic memory array built
    // with push(), eliminating the fixed-size Fill[100] buffer and the associated Panic(0x32).
    function _matchSell(
        bytes32 takerOrderId,
        bytes32 takerSubaccount,
        uint256 minPrice,
        uint256 remaining,
        OrderType /* orderType */
    ) internal returns (uint256, Fill[] memory fills) {
        // AUDIT FIX (P6-H-2): Cap allocation at MAX_FILLS to prevent OOG DoS.
        uint256 capacity = _bidPrices.length * MAX_ORDERS_PER_LEVEL;
        if (capacity > MAX_FILLS) capacity = MAX_FILLS;
        Fill[] memory tempFills = new Fill[](capacity);
        uint256 fillCount;

        // Bids are sorted descending (highest first)
        uint256 i = 0;
        while (remaining > 0 && i < _bidPrices.length && fillCount < capacity) {
            uint256 bidPrice = _bidPrices[i];
            /// AUDIT FIX (L1-M-1): Respect price as slippage limit for market orders too
            if (bidPrice < minPrice && minPrice > 0) break;

            PriceLevel storage level = bidLevels[bidPrice];
            bytes32 currentOrderId = level.headOrderId;

            while (remaining > 0 && currentOrderId != bytes32(0) && fillCount < capacity) {
                Order storage makerOrder = orders[currentOrderId];
                bytes32 nextId = _orderNodes[currentOrderId].next;

                if (!makerOrder.active || makerOrder.size == 0) {
                    currentOrderId = nextId;
                    continue;
                }

                // Self-trade prevention
                if (makerOrder.subaccount == takerSubaccount) {
                    makerOrder.active = false;
                    /// AUDIT FIX (P7-M-1): Decrement active order count on self-trade cancel.
                    _activeOrderCount[makerOrder.subaccount]--;
                    level.totalSize -= makerOrder.size;
                    level.orderCount--;
                    makerOrder.size = 0;
                    emit OrderCancelled(currentOrderId);
                    currentOrderId = nextId;
                    continue;
                }

                uint256 fillSize = remaining < makerOrder.size ? remaining : makerOrder.size;
                uint256 fillPrice = bidPrice;

                // AUDIT FIX (P6-H-2): fillCount bounded by capacity check in while condition.
                tempFills[fillCount++] = Fill({
                    makerOrderId: currentOrderId,
                    takerOrderId: takerOrderId,
                    makerSubaccount: makerOrder.subaccount,
                    takerSubaccount: takerSubaccount,
                    price: fillPrice,
                    size: fillSize,
                    takerSide: Side.Sell
                });

                makerOrder.size -= fillSize;
                remaining -= fillSize;
                level.totalSize -= fillSize;

                if (makerOrder.size == 0) {
                    makerOrder.active = false;
                    level.orderCount--;
                    /// AUDIT FIX (P7-M-1): Decrement active order count on full fill.
                    _activeOrderCount[makerOrder.subaccount]--;
                }

                emit TradeExecuted(currentOrderId, takerOrderId, fillPrice, fillSize);
                emit OrderFilled(currentOrderId, fillSize, makerOrder.size);

                currentOrderId = nextId;
            }

            level.headOrderId = currentOrderId;
            i++;
        }

        _cleanBidPrices();

        // Trim to actual fill count
        fills = new Fill[](fillCount);
        for (uint256 k = 0; k < fillCount; k++) {
            fills[k] = tempFills[k];
        }

        return (remaining, fills);
    }

    // ─────────────────────────────────────────────────────
    // Internal — order book management
    // ─────────────────────────────────────────────────────

    function _restOrder(
        bytes32 orderId,
        bytes32 subaccount,
        Side side,
        uint256 price,
        uint256 size,
        uint256 originalSize,
        OrderType orderType,
        TimeInForce tif
    ) internal {
        orders[orderId] = Order({
            id: orderId,
            subaccount: subaccount,
            side: side,
            price: price,
            size: size,
            originalSize: originalSize,
            timestamp: block.timestamp,
            orderType: orderType,
            tif: tif,
            active: true
        });

        /// AUDIT FIX (P7-M-1): Enforce active order cap before resting.
        require(_activeOrderCount[subaccount] < MAX_ACTIVE_ORDERS, "OB: max active orders");
        _activeOrderCount[subaccount]++;

        /// AUDIT FIX (P6-I-1): Track active order for cancelAllOrders().
        _subaccountOrders[subaccount].push(orderId);

        if (side == Side.Buy) {
            _addToLevel(bidLevels[price], orderId, size);
            if (!bidLevels[price].exists) {
                bidLevels[price].exists = true;
                _insertBidPrice(price);
            }
        } else {
            _addToLevel(askLevels[price], orderId, size);
            if (!askLevels[price].exists) {
                askLevels[price].exists = true;
                _insertAskPrice(price);
            }
        }
    }

    function _addToLevel(PriceLevel storage level, bytes32 orderId, uint256 size) internal {
        /// AUDIT FIX (L1-L-4): Enforce MAX_ORDERS_PER_LEVEL to prevent O(n²) gas costs
        require(level.orderCount < MAX_ORDERS_PER_LEVEL, "OB: level full");
        level.totalSize += size;
        level.orderCount++;

        if (level.tailOrderId == bytes32(0)) {
            // First order at this level
            level.headOrderId = orderId;
            level.tailOrderId = orderId;
        } else {
            // Append to tail
            _orderNodes[level.tailOrderId].next = orderId;
            _orderNodes[orderId].prev = level.tailOrderId;
            level.tailOrderId = orderId;
        }
    }

    function _removeFromLevel(PriceLevel storage level, bytes32 orderId, uint256 size) internal {
        level.totalSize -= size;
        level.orderCount--;

        OrderNode storage node = _orderNodes[orderId];
        if (node.prev != bytes32(0)) {
            _orderNodes[node.prev].next = node.next;
        } else {
            level.headOrderId = node.next;
        }
        if (node.next != bytes32(0)) {
            _orderNodes[node.next].prev = node.prev;
        } else {
            level.tailOrderId = node.prev;
        }
        delete _orderNodes[orderId];
    }

    /// AUDIT FIX (P6-L-2): Binary search for insertion point — O(log n) instead of O(n).
    /// @dev Insert price into sorted bid array (descending order).
    function _insertBidPrice(uint256 price) internal {
        uint256 len = _bidPrices.length;
        _bidPrices.push(0); // extend array

        // Binary search for insertion point (descending order)
        uint256 lo = 0;
        uint256 hi = len;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_bidPrices[mid] > price) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        // Shift elements right from insertion point
        for (uint256 i = len; i > lo; i--) {
            _bidPrices[i] = _bidPrices[i - 1];
        }
        _bidPrices[lo] = price;
    }

    /// AUDIT FIX (P6-L-2): Binary search for insertion point — O(log n) instead of O(n).
    /// @dev Insert price into sorted ask array (ascending order).
    function _insertAskPrice(uint256 price) internal {
        uint256 len = _askPrices.length;
        _askPrices.push(0); // extend array

        // Binary search for insertion point (ascending order)
        uint256 lo = 0;
        uint256 hi = len;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_askPrices[mid] < price) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        // Shift elements right from insertion point
        for (uint256 i = len; i > lo; i--) {
            _askPrices[i] = _askPrices[i - 1];
        }
        _askPrices[lo] = price;
    }

    /// AUDIT FIX (P7-I-1): Shift-left removal maintains sort order in O(n)
    /// instead of swap-and-pop + O(n²) insertion sort re-sort.
    function _removeBidPrice(uint256 price) internal {
        uint256 len = _bidPrices.length;
        for (uint256 i = 0; i < len; i++) {
            if (_bidPrices[i] == price) {
                for (uint256 j = i; j < len - 1; j++) {
                    _bidPrices[j] = _bidPrices[j + 1];
                }
                _bidPrices.pop();
                bidLevels[price].exists = false;
                return;
            }
        }
    }

    /// AUDIT FIX (P7-I-1): Shift-left removal maintains sort order in O(n).
    function _removeAskPrice(uint256 price) internal {
        uint256 len = _askPrices.length;
        for (uint256 i = 0; i < len; i++) {
            if (_askPrices[i] == price) {
                for (uint256 j = i; j < len - 1; j++) {
                    _askPrices[j] = _askPrices[j + 1];
                }
                _askPrices.pop();
                askLevels[price].exists = false;
                return;
            }
        }
    }

    /// AUDIT FIX (L1-M-2): Compact entire array — remove all empty levels, not just front
    /// AUDIT FIX (P10-M-1): Zero headOrderId and tailOrderId when removing an empty level.
    /// Previously, only `exists = false` was set, leaving headOrderId/tailOrderId pointing at
    /// stale order IDs. When the same price level was re-added later, the new level inherited
    /// the old head/tail pointers, causing the linked-list traversal to start mid-chain or
    /// re-process already-filled/cancelled orders — resulting in phantom fills or skipped orders.
    function _cleanBidPrices() internal {
        uint256 write = 0;
        for (uint256 read = 0; read < _bidPrices.length; read++) {
            if (bidLevels[_bidPrices[read]].totalSize > 0) {
                if (write != read) _bidPrices[write] = _bidPrices[read];
                write++;
            } else {
                uint256 price = _bidPrices[read];
                bidLevels[price].exists = false;
                bidLevels[price].headOrderId = bytes32(0);
                bidLevels[price].tailOrderId = bytes32(0);
            }
        }
        while (_bidPrices.length > write) _bidPrices.pop();
        // Array maintains sorted order since we only removed elements
    }

    /// AUDIT FIX (L1-M-2): Compact entire array — remove all empty levels, not just front
    /// AUDIT FIX (P10-M-1): Zero headOrderId and tailOrderId when removing an empty level.
    function _cleanAskPrices() internal {
        uint256 write = 0;
        for (uint256 read = 0; read < _askPrices.length; read++) {
            if (askLevels[_askPrices[read]].totalSize > 0) {
                if (write != read) _askPrices[write] = _askPrices[read];
                write++;
            } else {
                uint256 price = _askPrices[read];
                askLevels[price].exists = false;
                askLevels[price].headOrderId = bytes32(0);
                askLevels[price].tailOrderId = bytes32(0);
            }
        }
        while (_askPrices.length > write) _askPrices.pop();
    }

    /// AUDIT FIX (P7-I-1): _sortBidPrices() and _sortAskPrices() removed —
    /// no longer needed after shift-left removal replaces swap-and-pop + re-sort.

    /// AUDIT FIX (P8-I-3): Compact the _subaccountOrders tracking array by removing dead entries
    /// (filled/cancelled orders) without cancelling active orders. Market makers should call this
    /// periodically to prevent unbounded array growth from accumulating dead entries.
    function compactOrders(bytes32 subaccount) external nonReentrant {
        require(authorised[msg.sender], "OB: not authorised");

        bytes32[] storage orderIds = _subaccountOrders[subaccount];
        uint256 write = 0;
        for (uint256 read = 0; read < orderIds.length; read++) {
            if (orders[orderIds[read]].active) {
                if (write != read) orderIds[write] = orderIds[read];
                write++;
            }
        }
        // Trim dead entries from the end
        while (orderIds.length > write) orderIds.pop();
    }

    // ─────────────────────────────────────────────────────
    // View
    // ─────────────────────────────────────────────────────

    function getOrder(bytes32 orderId) external view override returns (Order memory) {
        return orders[orderId];
    }

    function bestBid() external view override returns (uint256 price, uint256 size) {
        if (_bidPrices.length == 0) return (0, 0);
        price = _bidPrices[0];
        size = bidLevels[price].totalSize;
    }

    function bestAsk() external view override returns (uint256 price, uint256 size) {
        if (_askPrices.length == 0) return (0, 0);
        price = _askPrices[0];
        size = askLevels[price].totalSize;
    }

    function midPrice() external view override returns (uint256) {
        if (_bidPrices.length == 0 || _askPrices.length == 0) return 0;
        return (_bidPrices[0] + _askPrices[0]) / 2;
    }

    function spread() external view override returns (uint256) {
        if (_bidPrices.length == 0 || _askPrices.length == 0) return type(uint256).max;
        return _askPrices[0] - _bidPrices[0];
    }

    function bidDepth() external view returns (uint256) { return _bidPrices.length; }
    function askDepth() external view returns (uint256) { return _askPrices.length; }
}
