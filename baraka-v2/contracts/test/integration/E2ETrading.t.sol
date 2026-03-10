// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Vault.sol";
import "../../src/core/SubaccountManager.sol";
import "../../src/core/MarginEngine.sol";
import "../../src/core/FundingEngine.sol";
import "../../src/orderbook/OrderBook.sol";
import "../../src/orderbook/MatchingEngine.sol";
import "../../src/shariah/ShariahRegistry.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracleAdapter.sol";

/**
 * @title E2ETrading
 * @notice End-to-end integration test: deploy full v2 stack, trade via orderbook.
 */
contract E2ETrading is Test {

    Vault              vault;
    SubaccountManager  sam;
    MarginEngine       marginEngine;
    FundingEngine      fundingEngine;
    OrderBook          orderBook;
    MatchingEngine     matchingEngine;
    ShariahRegistry    shariahRegistry;
    MockERC20          usdc;
    MockOracleAdapter  oracle;

    address owner = address(0xABCD);
    address alice = address(0x1111);
    address bob   = address(0x2222);

    bytes32 constant BTC_MARKET = keccak256("BTC-USD");

    bytes32 aliceSub;
    bytes32 bobSub;

    uint256 constant WAD = 1e18;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracleAdapter();
        sam = new SubaccountManager();

        fundingEngine = new FundingEngine(owner, address(oracle));
        vault = new Vault(owner);
        marginEngine = new MarginEngine(
            owner, address(vault), address(sam), address(oracle),
            address(fundingEngine), address(usdc)
        );

        shariahRegistry = new ShariahRegistry(owner);
        shariahRegistry.setMarginEngine(address(marginEngine));
        shariahRegistry.setOracle(address(oracle));
        shariahRegistry.approveAsset(BTC_MARKET, true);
        shariahRegistry.approveCollateral(address(usdc), true);
        shariahRegistry.setMaxLeverage(BTC_MARKET, 5);

        orderBook = new OrderBook(owner, BTC_MARKET);

        matchingEngine = new MatchingEngine(
            owner, address(sam), address(marginEngine), address(shariahRegistry)
        );

        vault.setApprovedToken(address(usdc), true);
        vault.setAuthorised(address(marginEngine), true);
        marginEngine.setAuthorised(address(matchingEngine), true);
        marginEngine.createMarket(BTC_MARKET, 0.2e18, 0.05e18, 10_000_000e18, 1_000_000e18);
        orderBook.setAuthorised(address(matchingEngine), true);
        matchingEngine.setOrderBook(BTC_MARKET, address(orderBook));
        matchingEngine.setTreasury(owner);
        matchingEngine.setInsuranceFund(owner);
        fundingEngine.setClampRate(BTC_MARKET, 0.135e18);

        oracle.setIndexPrice(BTC_MARKET, 50_000e18);
        oracle.setMarkPrice(BTC_MARKET, 50_000e18);

        vm.stopPrank();

        vm.prank(alice);
        aliceSub = sam.createSubaccount(0);
        vm.prank(bob);
        bobSub = sam.createSubaccount(0);

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(aliceSub, 50_000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(bobSub, 50_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // Helper — place order and return orderId
    // ═══════════════════════════════════════════════════════

    function _place(
        address trader,
        bytes32 sub,
        IOrderBook.Side side,
        uint256 price,
        uint256 size,
        IOrderBook.OrderType ot,
        IOrderBook.TimeInForce tif
    ) internal returns (bytes32) {
        vm.prank(trader);
        return matchingEngine.placeOrder(BTC_MARKET, sub, side, price, size, ot, tif);
    }

    // ═══════════════════════════════════════════════════════
    // Tests
    // ═══════════════════════════════════════════════════════

    function test_fullTradeLifecycle() public {
        // Alice places a limit buy at $50k (rests on book — no asks)
        bytes32 aliceOrderId = _place(
            alice, aliceSub, IOrderBook.Side.Buy,
            50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC
        );

        IOrderBook.Order memory aliceOrder = orderBook.getOrder(aliceOrderId);
        assertTrue(aliceOrder.active, "Alice order active");
        assertEq(aliceOrder.size, 1e18, "Alice order size");

        // Bob places limit sell at $50k → matches against Alice's buy
        _place(
            bob, bobSub, IOrderBook.Side.Sell,
            50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC
        );

        // Alice should have a long position
        IMarginEngine.Position memory alicePos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(alicePos.size, 1e18, "Alice long 1 BTC");
        assertEq(alicePos.entryPrice, 50_000e18, "Alice entry $50k");

        // Bob should have a short position
        IMarginEngine.Position memory bobPos = marginEngine.getPosition(bobSub, BTC_MARKET);
        assertEq(bobPos.size, -1e18, "Bob short 1 BTC");
        assertEq(bobPos.entryPrice, 50_000e18, "Bob entry $50k");
    }

    function test_priceMove_equityChanges() public {
        // Open positions (Alice long, Bob short at $50k)
        _place(alice, aliceSub, IOrderBook.Side.Buy, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);
        _place(bob, bobSub, IOrderBook.Side.Sell, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        // Price moves to $55,000
        oracle.setIndexPrice(BTC_MARKET, 55_000e18);

        int256 aliceEquity = marginEngine.getEquity(aliceSub);
        int256 bobEquity = marginEngine.getEquity(bobSub);

        // Alice profits, Bob loses — equity diverges
        assertGt(aliceEquity, 0, "Alice equity positive");
        assertGt(aliceEquity, bobEquity, "Alice > Bob");
    }

    function test_subaccountCreation() public {
        vm.prank(alice);
        bytes32 aliceSub2 = sam.createSubaccount(1);

        assertEq(sam.getOwner(aliceSub2), alice);
        assertTrue(sam.exists(aliceSub2));
        assertEq(sam.subaccountCount(alice), 2);
    }

    function test_depositWithdraw() public {
        assertEq(vault.balance(aliceSub, address(usdc)), 50_000e6);

        vm.prank(alice);
        marginEngine.withdraw(aliceSub, 10_000e6);

        assertEq(vault.balance(aliceSub, address(usdc)), 40_000e6);
        assertEq(usdc.balanceOf(alice), 60_000e6);
    }

    function test_shariahHalt_blocksTrading() public {
        vm.prank(owner);
        shariahRegistry.setHalt(true);

        vm.prank(alice);
        vm.expectRevert("MaE: Shariah halt");
        matchingEngine.placeOrder(
            BTC_MARKET, aliceSub, IOrderBook.Side.Buy,
            50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC
        );
    }

    function test_unapprovedAsset_reverts() public {
        bytes32 BAD_MARKET = keccak256("SHIB-USD");

        // Set up an orderbook for BAD_MARKET so the "no orderbook" check passes first
        vm.startPrank(owner);
        OrderBook badOB = new OrderBook(owner, BAD_MARKET);
        badOB.setAuthorised(address(matchingEngine), true);
        matchingEngine.setOrderBook(BAD_MARKET, address(badOB));
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert("MaE: asset not approved");
        matchingEngine.placeOrder(
            BAD_MARKET, aliceSub, IOrderBook.Side.Buy,
            1e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC
        );
    }

    function test_orderBook_bestBidAsk() public {
        _place(alice, aliceSub, IOrderBook.Side.Buy, 49_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);
        _place(bob, bobSub, IOrderBook.Side.Sell, 51_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        (uint256 bidPrice, uint256 bidSize) = orderBook.bestBid();
        (uint256 askPrice, uint256 askSize) = orderBook.bestAsk();

        assertEq(bidPrice, 49_000e18, "Best bid");
        assertEq(bidSize, 1e18, "Bid size");
        assertEq(askPrice, 51_000e18, "Best ask");
        assertEq(askSize, 1e18, "Ask size");
        assertEq(orderBook.spread(), 2_000e18, "Spread = $2k");
        assertEq(orderBook.midPrice(), 50_000e18, "Mid = $50k");
    }

    function test_selfTradePrevention() public {
        // Alice buy at $50k rests
        _place(alice, aliceSub, IOrderBook.Side.Buy, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        // Alice sell at $50k — STP cancels the resting buy, sell rests
        _place(alice, aliceSub, IOrderBook.Side.Sell, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        // No position opened (STP cancelled the buy before matching)
        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(pos.size, 0, "No self-trade position");
    }

    function test_postOnly_revertOnCross() public {
        _place(alice, aliceSub, IOrderBook.Side.Buy, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        vm.prank(bob);
        vm.expectRevert("OB: PostOnly order would cross");
        matchingEngine.placeOrder(
            BTC_MARKET, bobSub, IOrderBook.Side.Sell,
            50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.PostOnly
        );
    }

    function test_IOC_noResting() public {
        // IOC buy with no asks → no fill, no resting order
        _place(alice, aliceSub, IOrderBook.Side.Buy, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.IOC);

        (uint256 bidPrice,) = orderBook.bestBid();
        assertEq(bidPrice, 0, "No resting bid after IOC");
    }

    function test_cancelOrder() public {
        bytes32 orderId = _place(alice, aliceSub, IOrderBook.Side.Buy, 49_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        IOrderBook.Order memory order = orderBook.getOrder(orderId);
        assertTrue(order.active);

        vm.prank(alice);
        matchingEngine.cancelOrder(BTC_MARKET, orderId);

        order = orderBook.getOrder(orderId);
        assertFalse(order.active, "Cancelled");

        (uint256 bidPrice,) = orderBook.bestBid();
        assertEq(bidPrice, 0, "Book empty after cancel");
    }

    function test_partialFill() public {
        // Alice buys 2 BTC at $50k
        _place(alice, aliceSub, IOrderBook.Side.Buy, 50_000e18, 2e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        // Bob sells 1 BTC at $50k → partial fill
        _place(bob, bobSub, IOrderBook.Side.Sell, 50_000e18, 1e18, IOrderBook.OrderType.Limit, IOrderBook.TimeInForce.GTC);

        // Alice should have 1 BTC position (filled), 1 BTC resting
        IMarginEngine.Position memory alicePos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(alicePos.size, 1e18, "Alice 1 BTC filled");

        // Book should still have 1 BTC resting bid
        (uint256 bidPrice, uint256 bidSize) = orderBook.bestBid();
        assertEq(bidPrice, 50_000e18, "Resting bid price");
        assertEq(bidSize, 1e18, "1 BTC still resting");
    }
}
