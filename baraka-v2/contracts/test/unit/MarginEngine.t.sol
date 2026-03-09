// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/MarginEngine.sol";
import "../../src/core/Vault.sol";
import "../../src/core/SubaccountManager.sol";
import "../../src/core/FundingEngine.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockOracleAdapter.sol";

/**
 * @title MarginEngineTest
 * @notice Unit tests for MarginEngine: market creation, deposits, withdrawals,
 *         position updates (open/increase/reduce/flip/close), margin checks,
 *         funding settlement, equity computation, and access control.
 */
contract MarginEngineTest is Test {

    uint256 constant WAD = 1e18;
    bytes32 constant BTC = keccak256("BTC-USD");
    bytes32 constant ETH = keccak256("ETH-USD");

    MarginEngine      marginEngine;
    Vault             vault;
    SubaccountManager sam;
    FundingEngine     fundingEngine;
    MockERC20         usdc;
    MockOracleAdapter oracle;

    address owner    = address(0xABCD);
    address alice    = address(0x1111);
    address bob      = address(0x2222);
    address matcher  = address(0x6666);

    bytes32 aliceSub;
    bytes32 bobSub;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracleAdapter();
        sam = new SubaccountManager();
        fundingEngine = new FundingEngine(owner, address(oracle));
        vault = new Vault(owner);

        marginEngine = new MarginEngine(
            owner,
            address(vault),
            address(sam),
            address(oracle),
            address(fundingEngine),
            address(usdc)
        );

        // Wire permissions
        vault.setApprovedToken(address(usdc), true);
        vault.setAuthorised(address(marginEngine), true);
        marginEngine.setAuthorised(matcher, true);

        // Create BTC market: 10% IMR, 5% MMR, 10M max
        marginEngine.createMarket(BTC, 0.10e18, 0.05e18, 10_000_000e18, 1_000_000e18);

        // Set oracle prices
        oracle.setIndexPrice(BTC, 50_000e18);
        oracle.setMarkPrice(BTC, 50_000e18);

        // Set clamp rate for funding
        fundingEngine.setClampRate(BTC, 0.045e18);

        vm.stopPrank();

        // Create subaccounts
        vm.prank(alice);
        aliceSub = sam.createSubaccount(0);
        vm.prank(bob);
        bobSub = sam.createSubaccount(0);

        // Fund alice with 10,000 USDC
        _deposit(alice, aliceSub, 10_000e6);
    }

    function _deposit(address user, bytes32 sub, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(marginEngine), amount);
        marginEngine.deposit(sub, amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════
    // 1. Constructor
    // ═══════════════════════════════════════════════════════

    function test_constructor_setsImmutables() public view {
        assertEq(address(marginEngine.vault()), address(vault));
        assertEq(address(marginEngine.subaccountManager()), address(sam));
        assertEq(address(marginEngine.oracle()), address(oracle));
        assertEq(address(marginEngine.fundingEngine()), address(fundingEngine));
        assertEq(marginEngine.collateralToken(), address(usdc));
        assertEq(marginEngine.collateralScale(), 1e12);
    }

    function test_constructor_revert_zeroVault() public {
        vm.prank(owner);
        vm.expectRevert("ME: zero vault");
        new MarginEngine(owner, address(0), address(sam), address(oracle), address(fundingEngine), address(usdc));
    }

    // ═══════════════════════════════════════════════════════
    // 2. Market creation
    // ═══════════════════════════════════════════════════════

    function test_createMarket_basic() public {
        vm.prank(owner);
        marginEngine.createMarket(ETH, 0.20e18, 0.05e18, 5_000_000e18, 1_000_000e18);

        IMarginEngine.MarketParams memory p = marginEngine.getMarketParams(ETH);
        assertEq(p.initialMarginRate, 0.20e18);
        assertEq(p.maintenanceMarginRate, 0.05e18);
        assertEq(p.maxPositionSize, 5_000_000e18);
        assertTrue(p.active);
    }

    function test_createMarket_revert_alreadyExists() public {
        vm.prank(owner);
        vm.expectRevert("ME: market exists");
        marginEngine.createMarket(BTC, 0.20e18, 0.05e18, 1e18, 1_000_000e18);
    }

    function test_createMarket_revert_imrLeMmr() public {
        vm.prank(owner);
        vm.expectRevert("ME: IMR <= MMR");
        marginEngine.createMarket(ETH, 0.05e18, 0.05e18, 1e18, 1_000_000e18);
    }

    function test_createMarket_revert_zeroMmr() public {
        vm.prank(owner);
        vm.expectRevert("ME: zero MMR");
        marginEngine.createMarket(ETH, 0.10e18, 0, 1e18, 1_000_000e18);
    }

    function test_createMarket_revert_imrOver100() public {
        vm.prank(owner);
        vm.expectRevert("ME: IMR > 100%");
        marginEngine.createMarket(ETH, WAD + 1, 0.50e18, 1e18, 1_000_000e18);
    }

    function test_createMarket_revert_zeroMaxSize() public {
        vm.prank(owner);
        vm.expectRevert("ME: zero max size");
        marginEngine.createMarket(ETH, 0.10e18, 0.05e18, 0, 1_000_000e18);
    }

    function test_createMarket_revert_nonOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        marginEngine.createMarket(ETH, 0.10e18, 0.05e18, 1e18, 1_000_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 3. Market update
    // ═══════════════════════════════════════════════════════

    function test_updateMarket_basic() public {
        vm.prank(owner);
        marginEngine.updateMarket(BTC, 0.15e18, 0.08e18);

        IMarginEngine.MarketParams memory p = marginEngine.getMarketParams(BTC);
        assertEq(p.initialMarginRate, 0.15e18);
        assertEq(p.maintenanceMarginRate, 0.08e18);
    }

    function test_updateMarket_revert_notActive() public {
        vm.prank(owner);
        vm.expectRevert("ME: market not active");
        marginEngine.updateMarket(ETH, 0.10e18, 0.05e18);
    }

    // ═══════════════════════════════════════════════════════
    // 4. Deposit
    // ═══════════════════════════════════════════════════════

    function test_deposit_basic() public view {
        // Alice deposited 10,000 USDC in setUp
        assertEq(vault.balance(aliceSub, address(usdc)), 10_000e6);
    }

    function test_deposit_revert_notOwner() public {
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(marginEngine), 1000e6);
        vm.expectRevert("ME: not owner");
        marginEngine.deposit(aliceSub, 1000e6);
        vm.stopPrank();
    }

    function test_deposit_revert_closedSubaccount() public {
        vm.prank(alice);
        sam.closeSubaccount(0);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 100e6);
        vm.expectRevert("ME: subaccount closed");
        marginEngine.deposit(aliceSub, 100e6);
        vm.stopPrank();
    }

    function test_deposit_revert_zeroAmount() public {
        vm.prank(alice);
        vm.expectRevert("ME: zero amount");
        marginEngine.deposit(aliceSub, 0);
    }

    // ═══════════════════════════════════════════════════════
    // 5. Withdraw
    // ═══════════════════════════════════════════════════════

    function test_withdraw_basic() public {
        vm.prank(alice);
        marginEngine.withdraw(aliceSub, 5_000e6);

        assertEq(vault.balance(aliceSub, address(usdc)), 5_000e6);
        assertEq(usdc.balanceOf(alice), 5_000e6);
    }

    function test_withdraw_revert_notOwner() public {
        vm.prank(bob);
        vm.expectRevert("ME: not owner");
        marginEngine.withdraw(aliceSub, 100e6);
    }

    function test_withdraw_revert_insufficientFreeCollateral() public {
        // Open a position that uses margin, then try to withdraw everything
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // 1 BTC at 50k = 50k notional, 10% IMR = 5000 USDC required in WAD terms
        // Collateral = 10000 USDC, free = 10000 - 5000 = 5000 USDC
        vm.prank(alice);
        vm.expectRevert("ME: insufficient free collateral");
        marginEngine.withdraw(aliceSub, 6_000e6); // More than free collateral
    }

    // ═══════════════════════════════════════════════════════
    // 6. Position updates — open
    // ═══════════════════════════════════════════════════════

    function test_updatePosition_openLong() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, 1e18);
        assertEq(pos.entryPrice, 50_000e18);
    }

    function test_updatePosition_openShort() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, -1e18, 50_000e18);

        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, -1e18);
        assertEq(pos.entryPrice, 50_000e18);
    }

    function test_updatePosition_revert_notAuthorised() public {
        vm.prank(alice);
        vm.expectRevert("ME: not authorised");
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);
    }

    function test_updatePosition_revert_zeroDelta() public {
        vm.prank(matcher);
        vm.expectRevert("ME: zero delta");
        marginEngine.updatePosition(aliceSub, BTC, 0, 50_000e18);
    }

    function test_updatePosition_revert_inactiveMarket() public {
        vm.prank(matcher);
        vm.expectRevert("ME: market not active");
        marginEngine.updatePosition(aliceSub, ETH, 1e18, 3000e18);
    }

    function test_updatePosition_revert_exceedsMaxPosition() public {
        // Max position = 10M notional. 1 BTC at 50k = 50k. 201 BTC = 10.05M → exceeds
        _deposit(alice, aliceSub, 2_000_000e6);
        vm.prank(matcher);
        vm.expectRevert("ME: exceeds max position");
        marginEngine.updatePosition(aliceSub, BTC, 201e18, 50_000e18);
    }

    function test_updatePosition_revert_insufficientMargin() public {
        // 10000 USDC collateral. At 10% IMR, max notional = 100k = 2 BTC
        // Try to open 3 BTC = 150k notional, needs 15k margin
        vm.prank(matcher);
        vm.expectRevert("ME: insufficient margin");
        marginEngine.updatePosition(aliceSub, BTC, 3e18, 50_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 7. Position updates — increase (weighted avg entry)
    // ═══════════════════════════════════════════════════════

    function test_updatePosition_increaseLong() public {
        vm.startPrank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 0.5e18, 50_000e18);
        marginEngine.updatePosition(aliceSub, BTC, 0.5e18, 52_000e18);
        vm.stopPrank();

        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, 1e18);
        // Weighted avg: (0.5*50000 + 0.5*52000) / 1.0 = 51000
        assertEq(pos.entryPrice, 51_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 8. Position updates — reduce (realize PnL)
    // ═══════════════════════════════════════════════════════

    function test_updatePosition_partialCloseLong_profit() public {
        // P15-C-2: PnL credits require backing tokens — simulate counterparty collateral
        usdc.mint(address(vault), 10_000e6);

        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // Price goes up to 52k, close 0.5 BTC
        oracle.setIndexPrice(BTC, 52_000e18);
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, -0.5e18, 52_000e18);

        // PnL = (52000 - 50000) * 0.5 = 1000 USDC
        // 10000 + 1000 = 11000, but in token terms: 10000e6 + 1000e6 = 11000e6
        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, 0.5e18);
        assertEq(vault.balance(aliceSub, address(usdc)), 11_000e6);
    }

    function test_updatePosition_fullClose() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, -1e18, 50_000e18);

        // Position fully closed
        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, 0);
        assertEq(pos.entryPrice, 0);
    }

    function test_updatePosition_partialCloseShort_profit() public {
        // P15-C-2: PnL credits require backing tokens — simulate counterparty collateral
        usdc.mint(address(vault), 10_000e6);

        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, -1e18, 50_000e18);

        // Price drops to 48k → short profits
        oracle.setIndexPrice(BTC, 48_000e18);
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 0.5e18, 48_000e18);

        // PnL = (50000 - 48000) * 0.5 = 1000
        assertEq(vault.balance(aliceSub, address(usdc)), 11_000e6);
    }

    // ═══════════════════════════════════════════════════════
    // 9. Position updates — flip
    // ═══════════════════════════════════════════════════════

    function test_updatePosition_flipLongToShort() public {
        // P15-C-2: PnL credits require backing tokens — simulate counterparty collateral
        usdc.mint(address(vault), 10_000e6);

        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 0.5e18, 50_000e18);

        // Flip: sell 1 BTC → close 0.5 long + open 0.5 short
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, -1e18, 51_000e18);

        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, -0.5e18);
        assertEq(pos.entryPrice, 51_000e18);
        // Closed PnL: (51000-50000)*0.5 = 500
        assertEq(vault.balance(aliceSub, address(usdc)), 10_500e6);
    }

    // ═══════════════════════════════════════════════════════
    // 10. Max 20 markets per subaccount
    // ═══════════════════════════════════════════════════════

    function test_updatePosition_revert_max20Markets() public {
        _deposit(alice, aliceSub, 10_000_000e6);

        // Create and open 20 markets
        for (uint8 i = 0; i < 20; i++) {
            bytes32 mkt = keccak256(abi.encode("MKT", i));
            vm.prank(owner);
            marginEngine.createMarket(mkt, 0.10e18, 0.05e18, 100_000_000e18, 1_000_000e18);
            oracle.setIndexPrice(mkt, 100e18);
            oracle.setMarkPrice(mkt, 100e18);
            vm.prank(owner);
            fundingEngine.setClampRate(mkt, 0.045e18);
            vm.prank(matcher);
            marginEngine.updatePosition(aliceSub, mkt, 0.01e18, 100e18);
        }

        // 21st market should fail
        bytes32 mkt21 = keccak256(abi.encode("MKT", uint8(20)));
        vm.prank(owner);
        marginEngine.createMarket(mkt21, 0.10e18, 0.05e18, 100_000_000e18, 1_000_000e18);
        oracle.setIndexPrice(mkt21, 100e18);

        vm.prank(matcher);
        vm.expectRevert("ME: max 20 markets per subaccount");
        marginEngine.updatePosition(aliceSub, mkt21, 0.01e18, 100e18);
    }

    // ═══════════════════════════════════════════════════════
    // 11. Equity computation
    // ═══════════════════════════════════════════════════════

    function test_getEquity_noPositions() public view {
        // 10000 USDC = 10000e18 in WAD
        assertEq(marginEngine.getEquity(aliceSub), 10_000e18);
    }

    function test_getEquity_withUnrealizedProfit() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // Price goes to 52k → unrealized PnL = +2000
        oracle.setIndexPrice(BTC, 52_000e18);
        assertEq(marginEngine.getEquity(aliceSub), 12_000e18);
    }

    function test_getEquity_withUnrealizedLoss() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // Price drops to 48k → unrealized PnL = -2000
        oracle.setIndexPrice(BTC, 48_000e18);
        assertEq(marginEngine.getEquity(aliceSub), 8_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 12. Margin requirements
    // ═══════════════════════════════════════════════════════

    function test_getInitialMarginReq() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // 1 BTC * 50000 * 10% = 5000e18
        assertEq(marginEngine.getInitialMarginReq(aliceSub), 5_000e18);
    }

    function test_getMaintenanceMarginReq() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // 1 BTC * 50000 * 5% = 2500e18
        assertEq(marginEngine.getMaintenanceMarginReq(aliceSub), 2_500e18);
    }

    function test_getFreeCollateral() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // 10000 - 5000 = 5000
        assertEq(marginEngine.getFreeCollateral(aliceSub), 5_000e18);
    }

    // ═══════════════════════════════════════════════════════
    // 13. Liquidatable
    // ═══════════════════════════════════════════════════════

    function test_isLiquidatable_false() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        assertFalse(marginEngine.isLiquidatable(aliceSub));
    }

    function test_isLiquidatable_true_afterLoss() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);

        // Price drops to 42500 → equity = 10000 - 7500 = 2500
        // MMR = 1 * 42500 * 5% = 2125
        // equity(2500) > mmr(2125) → not liquidatable
        oracle.setIndexPrice(BTC, 42_500e18);
        assertFalse(marginEngine.isLiquidatable(aliceSub));

        // Price drops to 42000 → equity = 10000 - 8000 = 2000
        // MMR = 1 * 42000 * 5% = 2100
        // equity(2000) < mmr(2100) → liquidatable
        oracle.setIndexPrice(BTC, 42_000e18);
        assertTrue(marginEngine.isLiquidatable(aliceSub));
    }

    // ═══════════════════════════════════════════════════════
    // 14. Transfer between subaccounts
    // ═══════════════════════════════════════════════════════

    function test_transferBetweenSubaccounts() public {
        vm.prank(alice);
        bytes32 aliceSub2 = sam.createSubaccount(1);

        vm.prank(alice);
        marginEngine.transferBetweenSubaccounts(aliceSub, aliceSub2, 3_000e6);

        assertEq(vault.balance(aliceSub, address(usdc)), 7_000e6);
        assertEq(vault.balance(aliceSub2, address(usdc)), 3_000e6);
    }

    function test_transferBetweenSubaccounts_revert_notOwner() public {
        vm.prank(bob);
        vm.expectRevert("ME: not owner of source");
        marginEngine.transferBetweenSubaccounts(aliceSub, bobSub, 100e6);
    }

    // ═══════════════════════════════════════════════════════
    // 15. Pause
    // ═══════════════════════════════════════════════════════

    function test_pause_blocksDeposit() public {
        vm.prank(owner);
        marginEngine.pause();

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(marginEngine), 100e6);
        vm.expectRevert();
        marginEngine.deposit(aliceSub, 100e6);
        vm.stopPrank();
    }

    function test_pause_blocksWithdraw() public {
        vm.prank(owner);
        marginEngine.pause();

        vm.prank(alice);
        vm.expectRevert();
        marginEngine.withdraw(aliceSub, 100e6);
    }

    function test_pause_doesNotBlockUpdatePosition() public {
        vm.prank(owner);
        marginEngine.pause();

        // updatePosition must work during pause (liquidation path)
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 0.1e18, 50_000e18);

        IMarginEngine.Position memory pos = marginEngine.getPosition(aliceSub, BTC);
        assertEq(pos.size, 0.1e18);
    }

    // ═══════════════════════════════════════════════════════
    // 16. Renounce ownership
    // ═══════════════════════════════════════════════════════

    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert("ME: renounce disabled");
        marginEngine.renounceOwnership();
    }

    // ═══════════════════════════════════════════════════════
    // 17. Position cleanup on full close
    // ═══════════════════════════════════════════════════════

    function test_fullClose_removesMarketFromSubaccount() public {
        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 1e18, 50_000e18);
        assertEq(marginEngine.getSubaccountMarkets(aliceSub).length, 1);

        vm.prank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, -1e18, 50_000e18);
        assertEq(marginEngine.getSubaccountMarkets(aliceSub).length, 0);
    }

    // ═══════════════════════════════════════════════════════
    // 18. getSubaccountMarkets
    // ═══════════════════════════════════════════════════════

    function test_getSubaccountMarkets_empty() public view {
        assertEq(marginEngine.getSubaccountMarkets(aliceSub).length, 0);
    }

    function test_getSubaccountMarkets_multipleMarkets() public {
        vm.prank(owner);
        marginEngine.createMarket(ETH, 0.10e18, 0.05e18, 10_000_000e18, 1_000_000e18);
        oracle.setIndexPrice(ETH, 3000e18);
        oracle.setMarkPrice(ETH, 3000e18);
        vm.prank(owner);
        fundingEngine.setClampRate(ETH, 0.045e18);

        vm.startPrank(matcher);
        marginEngine.updatePosition(aliceSub, BTC, 0.1e18, 50_000e18);
        marginEngine.updatePosition(aliceSub, ETH, 1e18, 3_000e18);
        vm.stopPrank();

        assertEq(marginEngine.getSubaccountMarkets(aliceSub).length, 2);
    }
}
