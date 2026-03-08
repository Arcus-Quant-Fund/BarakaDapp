// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IOrderBook
 * @notice On-chain Central Limit Order Book (CLOB).
 *         One orderbook per market. Price-time priority matching.
 */
interface IOrderBook {

    enum Side { Buy, Sell }
    enum OrderType { Limit, Market }
    enum TimeInForce { GTC, IOC, FOK, PostOnly }

    struct Order {
        bytes32 id;
        bytes32 subaccount;
        Side    side;
        uint256 price;        // limit price (1e18), 0 for market orders
        uint256 size;         // remaining size (1e18)
        uint256 originalSize; // original size at placement
        uint256 timestamp;
        OrderType orderType;
        TimeInForce tif;
        bool    active;
    }

    struct Fill {
        bytes32 makerOrderId;
        bytes32 takerOrderId;
        bytes32 makerSubaccount;
        bytes32 takerSubaccount;
        uint256 price;
        uint256 size;
        Side    takerSide;
    }

    function placeOrder(
        bytes32 subaccount,
        Side side,
        uint256 price,
        uint256 size,
        OrderType orderType,
        TimeInForce tif
    ) external returns (bytes32 orderId, Fill[] memory fills);

    function cancelOrder(bytes32 orderId) external;
    function cancelAllOrders(bytes32 subaccount) external;

    function getOrder(bytes32 orderId) external view returns (Order memory);
    function bestBid() external view returns (uint256 price, uint256 size);
    function bestAsk() external view returns (uint256 price, uint256 size);
    function midPrice() external view returns (uint256);
    function spread() external view returns (uint256);
}
