// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/settlement/BatchSettlement.sol";
import "../../src/core/Vault.sol";
import "../../src/core/SubaccountManager.sol";
import "../../src/core/MarginEngine.sol";
import "../../src/core/FundingEngine.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracleAdapter.sol";

/**
 * @title BatchSettlementTest
 * @notice Unit tests for BatchSettlement: constructor, access control, single and
 *         multi-item settlement, taker side semantics, empty batch revert, and events.
 */
contract BatchSettlementTest is Test {

    // ─────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────

    uint256 constant WAD = 1e18;
    bytes32 constant BTC_MARKET = keccak256("BTC-USD");
    bytes32 constant ETH_MARKET = keccak256("ETH-USD");

    // ─────────────────────────────────────────────────────
    // Contracts
    // ─────────────────────────────────────────────────────

    BatchSettlement    batchSettlement;
    Vault              vault;
    SubaccountManager  sam;
    MarginEngine       marginEngine;
    FundingEngine      fundingEngine;
    MockERC20          usdc;
    MockOracleAdapter  oracle;

    // ─────────────────────────────────────────────────────
    // Actors
    // ─────────────────────────────────────────────────────

    address owner    = address(0xABCD);
    address alice    = address(0x1111);
    address bob      = address(0x2222);
    address charlie  = address(0x3333);
    address attacker = address(0xDEAD);

    // ─────────────────────────────────────────────────────
    // Subaccounts
    // ─────────────────────────────────────────────────────

    bytes32 aliceSub;
    bytes32 bobSub;
    bytes32 charlieSub;

    // ─────────────────────────────────────────────────────
    // Setup — mirrors E2E stack
    // ─────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        // Deploy infrastructure
        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracleAdapter();
        sam = new SubaccountManager();

        fundingEngine = new FundingEngine(owner, address(oracle));
        vault = new Vault(owner);
        marginEngine = new MarginEngine(
            owner, address(vault), address(sam), address(oracle),
            address(fundingEngine), address(usdc)
        );

        // Deploy BatchSettlement
        batchSettlement = new BatchSettlement(owner, address(marginEngine), address(oracle));

        // Wire permissions
        vault.setApprovedToken(address(usdc), true);
        vault.setAuthorised(address(marginEngine), true);
        marginEngine.setAuthorised(address(batchSettlement), true);
        // Create markets
        marginEngine.createMarket(BTC_MARKET, 0.2e18, 0.05e18, 10_000_000e18, 1_000_000e18);
        marginEngine.createMarket(ETH_MARKET, 0.2e18, 0.05e18, 10_000_000e18, 1_000_000e18);

        // Set oracle prices
        oracle.setIndexPrice(BTC_MARKET, 50_000e18);
        oracle.setMarkPrice(BTC_MARKET, 50_000e18);
        oracle.setIndexPrice(ETH_MARKET, 3_000e18);
        oracle.setMarkPrice(ETH_MARKET, 3_000e18);

        // Authorise this test contract as a caller of batchSettlement
        batchSettlement.setAuthorised(address(this), true);

        fundingEngine.setClampRate(BTC_MARKET, 0.135e18);
        fundingEngine.setClampRate(ETH_MARKET, 0.135e18);

        vm.stopPrank();

        // Create subaccounts
        vm.prank(alice);
        aliceSub = sam.createSubaccount(0);
        vm.prank(bob);
        bobSub = sam.createSubaccount(0);
        vm.prank(charlie);
        charlieSub = sam.createSubaccount(0);

        // Fund subaccounts with collateral
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);

        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(aliceSub, 50_000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(bobSub, 50_000e6);
        vm.stopPrank();

        vm.startPrank(charlie);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(charlieSub, 50_000e6);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════

    function _makeItem(
        bytes32 marketId,
        bytes32 takerSub,
        bytes32 makerSub,
        uint8 takerSide,
        uint256 price,
        uint256 size
    ) internal pure returns (BatchSettlement.SettlementItem memory) {
        return BatchSettlement.SettlementItem({
            marketId: marketId,
            takerSubaccount: takerSub,
            makerSubaccount: makerSub,
            takerSide: takerSide,
            price: price,
            size: size
        });
    }

    function _singleItemBatch(BatchSettlement.SettlementItem memory item)
        internal
        pure
        returns (BatchSettlement.SettlementItem[] memory)
    {
        BatchSettlement.SettlementItem[] memory batch = new BatchSettlement.SettlementItem[](1);
        batch[0] = item;
        return batch;
    }

    // ═══════════════════════════════════════════════════════
    // 1. Constructor sets immutables
    // ═══════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public view {
        assertEq(address(batchSettlement.marginEngine()), address(marginEngine), "marginEngine set");
        assertEq(address(batchSettlement.oracle()), address(oracle), "oracle set");
        assertEq(batchSettlement.owner(), owner, "owner set");
    }

    function test_constructor_revertsZeroMarginEngine() public {
        vm.prank(owner);
        vm.expectRevert("BS: zero ME");
        new BatchSettlement(owner, address(0), address(oracle));
    }

    function test_constructor_revertsZeroOracle() public {
        vm.prank(owner);
        vm.expectRevert("BS: zero oracle");
        new BatchSettlement(owner, address(marginEngine), address(0));
    }

    // ═══════════════════════════════════════════════════════
    // 2. setAuthorised — only owner
    // ═══════════════════════════════════════════════════════

    function test_setAuthorised_ownerCanSet() public {
        address newCaller = address(0x9999);

        vm.prank(owner);
        batchSettlement.setAuthorised(newCaller, true);

        assertTrue(batchSettlement.authorised(newCaller), "authorised granted");

        vm.prank(owner);
        batchSettlement.setAuthorised(newCaller, false);

        assertFalse(batchSettlement.authorised(newCaller), "authorised revoked");
    }

    function test_setAuthorised_nonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        batchSettlement.setAuthorised(attacker, true);
    }

    function test_setAuthorised_zeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert("BS: zero address");
        batchSettlement.setAuthorised(address(0), true);
    }

    // ═══════════════════════════════════════════════════════
    // 3. setFeeEngine — only owner
    // ═══════════════════════════════════════════════════════

    function test_setFeeEngine_ownerCanSet() public {
        address fakeFeeEngine = address(0x7777);

        vm.prank(owner);
        batchSettlement.setFeeEngine(fakeFeeEngine);

        assertEq(address(batchSettlement.feeEngine()), fakeFeeEngine, "feeEngine set");
    }

    function test_setFeeEngine_nonOwnerReverts() public {
        vm.prank(attacker);
        vm.expectRevert();
        batchSettlement.setFeeEngine(address(0x7777));
    }

    // ═══════════════════════════════════════════════════════
    // 4. settleBatch — single item creates positions
    // ═══════════════════════════════════════════════════════

    function test_settleBatch_singleItem_createsPositions() public {
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 1e18)
        );

        batchSettlement.settleBatch(batch);

        IMarginEngine.Position memory alicePos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        IMarginEngine.Position memory bobPos = marginEngine.getPosition(bobSub, BTC_MARKET);

        // Taker (alice) bought: she should be long
        assertEq(alicePos.size, int256(1e18), "Alice long 1 BTC");
        assertEq(alicePos.entryPrice, 50_000e18, "Alice entry price");

        // Maker (bob) is counterparty: he should be short
        assertEq(bobPos.size, -int256(1e18), "Bob short 1 BTC");
        assertEq(bobPos.entryPrice, 50_000e18, "Bob entry price");
    }

    // ═══════════════════════════════════════════════════════
    // 5. settleBatch — multiple items processed atomically
    // ═══════════════════════════════════════════════════════

    function test_settleBatch_multipleItems_batchOf3() public {
        BatchSettlement.SettlementItem[] memory batch = new BatchSettlement.SettlementItem[](3);

        // Fill 1: Alice buys 1 BTC from Bob at $50k
        batch[0] = _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 1e18);
        // Fill 2: Alice buys another 0.5 BTC from Charlie at $51k
        batch[1] = _makeItem(BTC_MARKET, aliceSub, charlieSub, 0, 51_000e18, 0.5e18);
        // Fill 3: Charlie buys 2 ETH from Bob at $3k
        batch[2] = _makeItem(ETH_MARKET, charlieSub, bobSub, 0, 3_000e18, 2e18);

        batchSettlement.settleBatch(batch);

        // Alice: long 1.5 BTC (1 + 0.5)
        IMarginEngine.Position memory aliceBtc = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(aliceBtc.size, int256(1.5e18), "Alice long 1.5 BTC");

        // Bob: short 1 BTC, short 2 ETH
        IMarginEngine.Position memory bobBtc = marginEngine.getPosition(bobSub, BTC_MARKET);
        assertEq(bobBtc.size, -int256(1e18), "Bob short 1 BTC");
        IMarginEngine.Position memory bobEth = marginEngine.getPosition(bobSub, ETH_MARKET);
        assertEq(bobEth.size, -int256(2e18), "Bob short 2 ETH");

        // Charlie: short 0.5 BTC, long 2 ETH
        IMarginEngine.Position memory charlieBtc = marginEngine.getPosition(charlieSub, BTC_MARKET);
        assertEq(charlieBtc.size, -int256(0.5e18), "Charlie short 0.5 BTC");
        IMarginEngine.Position memory charlieEth = marginEngine.getPosition(charlieSub, ETH_MARKET);
        assertEq(charlieEth.size, int256(2e18), "Charlie long 2 ETH");
    }

    // ═══════════════════════════════════════════════════════
    // 6. Taker buy (side=0): taker long, maker short
    // ═══════════════════════════════════════════════════════

    function test_takerBuy_longShortSemantic() public {
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 2e18)
        );

        batchSettlement.settleBatch(batch);

        IMarginEngine.Position memory takerPos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        IMarginEngine.Position memory makerPos = marginEngine.getPosition(bobSub, BTC_MARKET);

        // Taker buy → taker gets +size (long)
        assertGt(takerPos.size, 0, "Taker is long");
        assertEq(takerPos.size, int256(2e18), "Taker long 2 BTC");

        // Maker gets -size (short)
        assertLt(makerPos.size, 0, "Maker is short");
        assertEq(makerPos.size, -int256(2e18), "Maker short 2 BTC");
    }

    // ═══════════════════════════════════════════════════════
    // 7. Taker sell (side=1): taker short, maker long
    // ═══════════════════════════════════════════════════════

    function test_takerSell_shortLongSemantic() public {
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, bobSub, 1, 50_000e18, 3e18)
        );

        batchSettlement.settleBatch(batch);

        IMarginEngine.Position memory takerPos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        IMarginEngine.Position memory makerPos = marginEngine.getPosition(bobSub, BTC_MARKET);

        // Taker sell → taker gets -size (short)
        assertLt(takerPos.size, 0, "Taker is short");
        assertEq(takerPos.size, -int256(3e18), "Taker short 3 BTC");

        // Maker gets +size (long)
        assertGt(makerPos.size, 0, "Maker is long");
        assertEq(makerPos.size, int256(3e18), "Maker long 3 BTC");
    }

    // ═══════════════════════════════════════════════════════
    // 8. Empty batch reverts
    // ═══════════════════════════════════════════════════════

    function test_settleBatch_emptyBatch_reverts() public {
        BatchSettlement.SettlementItem[] memory empty = new BatchSettlement.SettlementItem[](0);

        vm.expectRevert("BS: empty batch");
        batchSettlement.settleBatch(empty);
    }

    // ═══════════════════════════════════════════════════════
    // 9. Unauthorised caller reverts
    // ═══════════════════════════════════════════════════════

    function test_settleBatch_unauthorisedCaller_reverts() public {
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 1e18)
        );

        vm.prank(attacker);
        vm.expectRevert("BS: not authorised");
        batchSettlement.settleBatch(batch);
    }

    // ═══════════════════════════════════════════════════════
    // 10. Event emission: BatchSettled with correct count
    // ═══════════════════════════════════════════════════════

    function test_settleBatch_emitsBatchSettled_singleItem() public {
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 1e18)
        );

        // AUDIT FIX (L0-M-6): batchId now includes _batchNonce (starts at 0)
        bytes32 expectedBatchId = keccak256(
            abi.encodePacked(block.number, block.timestamp, uint256(1), uint256(0))
        );

        vm.expectEmit(true, true, false, true);
        emit BatchSettlement.BatchSettled(1, expectedBatchId);

        batchSettlement.settleBatch(batch);
    }

    function test_settleBatch_emitsBatchSettled_multipleItems() public {
        BatchSettlement.SettlementItem[] memory batch = new BatchSettlement.SettlementItem[](3);
        batch[0] = _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 1e18);
        batch[1] = _makeItem(BTC_MARKET, aliceSub, charlieSub, 0, 51_000e18, 0.5e18);
        batch[2] = _makeItem(ETH_MARKET, charlieSub, bobSub, 0, 3_000e18, 2e18);

        // AUDIT FIX (L0-M-6): batchId includes nonce (1 since single-item batch ran first in different test)
        // In this test, nonce starts at 0 since each test gets fresh state
        bytes32 expectedBatchId = keccak256(
            abi.encodePacked(block.number, block.timestamp, uint256(3), uint256(0))
        );

        vm.expectEmit(true, true, false, true);
        emit BatchSettlement.BatchSettled(3, expectedBatchId);

        batchSettlement.settleBatch(batch);
    }

    // ═══════════════════════════════════════════════════════
    // 11. P16-AC-M4: Cross-account self-trade prevention
    // ═══════════════════════════════════════════════════════

    /// @notice Same-owner subaccounts must not trade against each other (wash trading).
    function test_settleOne_crossAccountSelfTrade_reverts() public {
        // Wire SubaccountManager so the cross-account check is active
        vm.prank(owner);
        batchSettlement.setSubaccountManager(address(sam));

        // Create a second subaccount for Alice (same owner, different index)
        vm.prank(alice);
        bytes32 aliceSub2 = sam.createSubaccount(1);

        // Fund the second subaccount
        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(aliceSub2, 50_000e6);
        vm.stopPrank();

        // Attempt: Alice sub0 buys from Alice sub1 — same owner, should revert
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, aliceSub2, 0, 50_000e18, 1e18)
        );

        // The try/catch in settleBatch swallows the revert but emits SettlementFailed
        vm.expectEmit(true, true, false, false);
        emit BatchSettlement.SettlementFailed(0, BTC_MARKET);
        batchSettlement.settleBatch(batch);

        // Verify no positions were created (settlement was rejected)
        IMarginEngine.Position memory pos1 = marginEngine.getPosition(aliceSub, BTC_MARKET);
        IMarginEngine.Position memory pos2 = marginEngine.getPosition(aliceSub2, BTC_MARKET);
        assertEq(pos1.size, 0, "Alice sub0 should have no position");
        assertEq(pos2.size, 0, "Alice sub1 should have no position");
    }

    /// @notice Cross-account check is skipped when SubaccountManager is not set.
    function test_settleOne_crossAccountSelfTrade_noManagerBypass() public {
        // SubaccountManager NOT set on batchSettlement — check is skipped

        // Create a second subaccount for Alice
        vm.prank(alice);
        bytes32 aliceSub2 = sam.createSubaccount(1);

        // Fund it
        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 50_000e6);
        marginEngine.deposit(aliceSub2, 50_000e6);
        vm.stopPrank();

        // Without SubaccountManager, same-owner trade succeeds (graceful degradation)
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, aliceSub2, 0, 50_000e18, 1e18)
        );

        batchSettlement.settleBatch(batch);

        IMarginEngine.Position memory pos1 = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(pos1.size, int256(1e18), "Trade should succeed without SubaccountManager");
    }

    /// @notice Different owners should settle normally even with SubaccountManager set.
    function test_settleOne_differentOwners_succeedsWithManager() public {
        // Wire SubaccountManager
        vm.prank(owner);
        batchSettlement.setSubaccountManager(address(sam));

        // Alice buys from Bob — different owners, should succeed
        BatchSettlement.SettlementItem[] memory batch = _singleItemBatch(
            _makeItem(BTC_MARKET, aliceSub, bobSub, 0, 50_000e18, 1e18)
        );

        batchSettlement.settleBatch(batch);

        IMarginEngine.Position memory alicePos = marginEngine.getPosition(aliceSub, BTC_MARKET);
        assertEq(alicePos.size, int256(1e18), "Alice should be long 1 BTC");
    }
}
