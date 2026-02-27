// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/PositionManager.sol";
import "../../src/core/CollateralVault.sol";
import "../../src/core/LiquidationEngine.sol";
import "../../src/core/FundingEngine.sol";
import "../../src/shariah/ShariahGuard.sol";
import "../../src/oracle/OracleAdapter.sol";
import "../mocks/MockERC20.sol";

/**
 * @dev Minimal Chainlink AggregatorV3 mock.
 *      Deployed fresh on the fork so we never depend on live testnet feed staleness.
 *      `setPrice` always refreshes `updatedAt` to the current block.timestamp,
 *      keeping OracleAdapter's 5-minute staleness window satisfied after every vm.warp.
 */
contract MockFeed {
    int256  internal _price;
    uint256 internal _ts;

    constructor(int256 startPrice) {
        _price = startPrice;
        _ts    = block.timestamp;
    }

    function setPrice(int256 p) external {
        _price = p;
        _ts    = block.timestamp;
    }

    function latestRoundData()
        external view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _price, _ts, _ts, 1);
    }

    function decimals() external pure returns (uint8) { return 8; }
}

/**
 * @title E2EForkTest
 * @notice Automated end-to-end test that runs against the LIVE deployed contracts
 *         on Arbitrum Sepolia via a local Anvil fork — no real transactions sent.
 *
 * Three scenarios:
 *   1. Full lifecycle   — deposit → open → settle (F=0, mark==index) → close → withdraw
 *   2. Funding flow     — mark 0.6% above index → long pays, short receives over 3 intervals
 *   3. Liquidation      — thin margin (5× lev) + max-rate funding → liquidate
 *
 * Run with one command:
 *   bash /Users/shehzad/Desktop/BarakaDapp/e2e.sh
 *
 * Or directly:
 *   cd /Users/shehzad/Desktop/BarakaDapp/contracts
 *   export PATH="$HOME/.foundry/bin:$PATH"
 *   forge test --match-path "test/e2e/E2EForkTest.t.sol" \
 *     --fork-url https://arb-sepolia.g.alchemy.com/v2/GLeaFAgyC1y-tbGFosfaG \
 *     -vvv
 */
contract E2EForkTest is Test {

    // ── Deployed contracts (Arbitrum Sepolia 421614) ──────────────────────────
    PositionManager   pm        = PositionManager  (0x53E3063FE2194c2DAe30C36420A01A8573B150bC);
    CollateralVault   vault     = CollateralVault  (0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E);
    LiquidationEngine liqEngine = LiquidationEngine(0x456eBE7BbCb099E75986307E4105A652c108b608);
    FundingEngine     engine    = FundingEngine    (0x459BE882BC8736e92AA4589D1b143e775b114b38);
    ShariahGuard      guard     = ShariahGuard     (0x26d4db76a95DBf945ac14127a23Cd4861DA42e69);
    OracleAdapter     oracle    = OracleAdapter    (0xB8d9778288B96ee5a9d873F222923C0671fc38D4);

    // ── Constants ─────────────────────────────────────────────────────────────
    // DEPLOYER == Shariah board on testnet (same address, testnet only)
    address constant DEPLOYER   = 0x12A21D0D172265A520aF286F856B5aF628e66D46;
    // BTC market ID set in Deploy.s.sol — already Shariah-approved in ShariahGuard
    address constant BTC_MARKET = address(0x00B1C);
    // Testnet IPFS fatwa hash (must match what was used in deployment)
    string  constant FATWA      = "QmPlaceholderFatwaHashReplaceBeforeMainnet";

    // ── Test actors ───────────────────────────────────────────────────────────
    address immutable TRADER     = makeAddr("e2e-trader");
    address immutable LIQUIDATOR = makeAddr("e2e-liquidator");

    // ── Deployed fresh per setUp ───────────────────────────────────────────────
    MockFeed  mockFeed;
    MockERC20 usdc;

    // ─────────────────────────────────────────────────────────────────────────
    // setUp — runs before every test function
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        // 1. Deploy a mock Chainlink feed starting at BTC = $95,000 (8 decimals)
        mockFeed = new MockFeed(95_000e8);

        // 2. Swap the live OracleAdapter config to use our mock feed.
        //    This eliminates any staleness risk from real Chainlink testnet feeds.
        vm.prank(DEPLOYER);
        oracle.setOracle(BTC_MARKET, address(mockFeed), address(mockFeed));

        // 3. Unpause the OracleAdapter if it was left paused on testnet.
        //    Also unpause FundingEngine and PositionManager for the same reason.
        {
            (, bytes memory data) = address(oracle).staticcall(abi.encodeWithSignature("paused()"));
            if (abi.decode(data, (bool))) {
                vm.prank(DEPLOYER);
                oracle.unpause();
            }
        }
        {
            (, bytes memory data) = address(engine).staticcall(abi.encodeWithSignature("paused()"));
            if (abi.decode(data, (bool))) {
                vm.prank(DEPLOYER);
                engine.unpause();
            }
        }
        {
            (, bytes memory data) = address(pm).staticcall(abi.encodeWithSignature("paused()"));
            if (abi.decode(data, (bool))) {
                vm.prank(DEPLOYER);
                pm.unpause();
            }
        }
        {
            (, bytes memory data) = address(vault).staticcall(abi.encodeWithSignature("paused()"));
            if (abi.decode(data, (bool))) {
                vm.prank(DEPLOYER);
                vault.unpause();
            }
        }
        {
            (, bytes memory data) = address(liqEngine).staticcall(abi.encodeWithSignature("paused()"));
            if (abi.decode(data, (bool))) {
                vm.prank(DEPLOYER);
                liqEngine.unpause();
            }
        }
        // lastValidPrice[BTC_MARKET] = 0 after setOracle above, so circuit breaker is inactive.
        // No need to call snapshotPrice — the first getIndexPrice call will work freely.

        // 4. Deploy a fresh MockERC20 as test collateral (6 decimals, like USDC).
        usdc = new MockERC20("Test USDC", "TUSDC", 6);

        // 5. Shariah-approve our test token (DEPLOYER == Shariah board on testnet).
        vm.prank(DEPLOYER);
        guard.approveAsset(address(usdc), FATWA);

        // 6. Fund actors with test tokens + ETH for gas.
        usdc.mint(TRADER,     10_000e6);
        usdc.mint(LIQUIDATOR,  5_000e6);
        vm.deal(TRADER,     1 ether);
        vm.deal(LIQUIDATOR, 1 ether);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helper: advance time and refresh oracle to avoid staleness
    // ─────────────────────────────────────────────────────────────────────────

    function _warpAndRefresh(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        mockFeed.setPrice(95_000e8); // updatedAt = new block.timestamp — within 5-min threshold
    }

    // Push two mark-price TWAP observations at the current timestamp (1 min apart).
    // Two observations are the minimum required by OracleAdapter.TWAP_MIN_OBSERVATIONS.
    function _pushMarkObs(uint256 price) internal {
        oracle.recordMarkPrice(BTC_MARKET, price);
        vm.warp(block.timestamp + 1 minutes);
        mockFeed.setPrice(95_000e8);
        oracle.recordMarkPrice(BTC_MARKET, price);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 1: Full lifecycle — deposit → open → settle (F=0) → close → withdraw
    //
    // mark == index throughout → F = 0 → zero funding payments.
    // Trader should receive back exactly their initial collateral.
    // ═════════════════════════════════════════════════════════════════════════

    function test_1_FullLifecycle() public {
        uint256 deposit  = 1_000e6;
        uint256 leverage = 3;

        emit log_string("");
        emit log_string("=== TEST 1: FULL LIFECYCLE ===");
        emit log_string("    mark == index throughout, F = 0, price unchanged");

        // ── STEP 1: Deposit ───────────────────────────────────────────────────
        vm.startPrank(TRADER);
        usdc.approve(address(vault), deposit);
        vault.deposit(address(usdc), deposit);
        vm.stopPrank();

        assertEq(vault.freeBalance(TRADER, address(usdc)), deposit, "Step1: free balance after deposit");
        emit log_named_uint("[1] Deposit OK  - free balance (USDC 6dec)", vault.freeBalance(TRADER, address(usdc)));

        // ── STEP 2: Open 3x long ──────────────────────────────────────────────
        vm.prank(TRADER);
        bytes32 posId = pm.openPosition(BTC_MARKET, address(usdc), deposit, leverage, true);

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertTrue(pos.open,                              "Step2: position open");
        assertEq(pos.size,     deposit * leverage,        "Step2: notional = collateral x leverage");
        assertEq(pos.collateral, deposit,                 "Step2: collateral recorded");
        assertTrue(pos.isLong,                            "Step2: is long");
        assertEq(vault.freeBalance(TRADER, address(usdc)), 0, "Step2: collateral locked");

        emit log_named_uint("[2] Open OK     - size (notional)", pos.size);
        emit log_named_uint("                  entry price     ", pos.entryPrice);

        // ── STEP 3: Warp 3 hours + settle funding (mark==index → F=0) ─────────
        _warpAndRefresh(3 hours);

        vm.prank(TRADER);
        pm.settleFunding(posId);

        assertEq(pm.getPosition(posId).collateral, deposit, "Step3: collateral unchanged when F=0");
        assertEq(pm.getUnrealizedPnl(posId), 0,             "Step3: PnL=0 price unchanged");
        emit log_named_uint("[3] Settle OK   - collateral unchanged", pm.getPosition(posId).collateral);

        // ── STEP 4: Warp past 24h withdrawal cooldown, close position ──────────
        _warpAndRefresh(22 hours); // total time elapsed: 25h

        vm.prank(TRADER);
        pm.closePosition(posId);

        assertFalse(pm.getPosition(posId).open,             "Step4: position closed");
        assertEq(vault.freeBalance(TRADER, address(usdc)), deposit, "Step4: full collateral returned");
        emit log_named_uint("[4] Close OK    - free balance returned", vault.freeBalance(TRADER, address(usdc)));

        // ── STEP 5: Withdraw ──────────────────────────────────────────────────
        vm.prank(TRADER);
        vault.withdraw(address(usdc), deposit);

        // Trader started with 10_000e6, deposited 1_000e6, withdrew 1_000e6 → back to 10_000e6
        assertEq(usdc.balanceOf(TRADER), 10_000e6, "Step5: wallet balance restored");
        emit log_named_uint("[5] Withdraw OK - wallet balance", usdc.balanceOf(TRADER));
        emit log_string("=== PASS ===");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 2: Funding flow — mark 0.6% above index → long pays, short receives
    //
    // Rate = (95,570 − 95,000) / 95,000 = 6e15 (0.6%, below 75bps cap)
    // Over 3 intervals:
    //   Long  (3× lev, size=3000e6): pays  6e15 × 3 × 3000e6 / 1e18 = 54e6
    //   Short (2× lev, size=2000e6): rcvs  6e15 × 3 × 2000e6 / 1e18 = 36e6
    // ═════════════════════════════════════════════════════════════════════════

    function test_2_FundingFlow() public {
        address SHORT_TRADER = makeAddr("short-trader");
        usdc.mint(SHORT_TRADER, 10_000e6);
        vm.deal(SHORT_TRADER, 1 ether);

        uint256 collateral = 1_000e6;

        emit log_string("");
        emit log_string("=== TEST 2: FUNDING FLOW ===");
        emit log_string("    mark 0.6% above index over 3 intervals");

        // Deposit both traders
        vm.startPrank(TRADER);
        usdc.approve(address(vault), collateral);
        vault.deposit(address(usdc), collateral);
        vm.stopPrank();

        vm.startPrank(SHORT_TRADER);
        usdc.approve(address(vault), collateral);
        vault.deposit(address(usdc), collateral);
        vm.stopPrank();

        // Open long and short
        vm.prank(TRADER);
        bytes32 longId = pm.openPosition(BTC_MARKET, address(usdc), collateral, 3, true);  // size = 3000e6

        vm.prank(SHORT_TRADER);
        bytes32 shortId = pm.openPosition(BTC_MARKET, address(usdc), collateral, 2, false); // size = 2000e6

        emit log_named_uint("[2] Long opened  - size", pm.getPosition(longId).size);
        emit log_named_uint("    Short opened - size", pm.getPosition(shortId).size);

        // Warp 3 hours (3 complete funding intervals)
        // Then push fresh mark observations inside the 30-min TWAP window.
        // mark = $95,570 = 0.6% above index $95,000
        vm.warp(block.timestamp + 3 hours);
        mockFeed.setPrice(95_000e8); // refresh feed (index stays $95k)
        uint256 markPremium = 95_000e18 * 1006 / 1000; // $95,570 in 1e18
        _pushMarkObs(markPremium);  // 2 fresh TWAP observations, 1 min apart

        // Settle funding for both positions
        vm.prank(TRADER);
        pm.settleFunding(longId);

        vm.prank(SHORT_TRADER);
        pm.settleFunding(shortId);

        uint256 longCollateral  = pm.getPosition(longId).collateral;
        uint256 shortCollateral = pm.getPosition(shortId).collateral;

        // Long must have paid funding → collateral decreased
        assertLt(longCollateral,  collateral, "Long must have paid funding");
        // Short must have received funding → collateral increased
        assertGt(shortCollateral, collateral, "Short must have received funding");

        emit log_named_uint("[2] Long collateral  (started 1000e6)", longCollateral);
        emit log_named_uint("    Short collateral (started 1000e6)", shortCollateral);
        emit log_named_uint("    Long paid        (delta)         ", collateral - longCollateral);
        emit log_named_uint("    Short received   (delta)         ", shortCollateral - collateral);
        emit log_string("=== PASS ===");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 3: Liquidation — thin margin + 25 intervals of max-rate funding
    //
    // Setup:
    //   collateral = 200 USDC, leverage = 5×, size = 1000 USDC notional
    //   mark 100% above index → rate capped at MAX_RATE = 75e14 (75bps/hr)
    //
    // After 25 intervals:
    //   funding paid = 75e14 × 25 × 1000e6 / 1e18 = 187.5e6
    //   remaining    = 200e6 - 187.5e6 = 12.5e6
    //   maintenance  = 1000e6 × 2% = 20e6
    //   12.5e6 < 20e6 → liquidatable
    //
    // Liquidation:
    //   penalty       = 1000e6 × 1% = 10e6
    //   liquidator    = 50% of 10e6 = 5e6
    //   insurance     = 50% of 10e6 = 5e6
    //   trader gets   = 12.5e6 - 10e6 = 2.5e6
    // ═════════════════════════════════════════════════════════════════════════

    function test_3_Liquidation() public {
        uint256 collateral = 200e6;

        emit log_string("");
        emit log_string("=== TEST 3: LIQUIDATION FLOW ===");
        emit log_string("    5x long, mark 100% above index, 25 intervals max-rate funding");

        // Deposit + open thin 5× long
        vm.startPrank(TRADER);
        usdc.approve(address(vault), collateral);
        vault.deposit(address(usdc), collateral);
        bytes32 posId = pm.openPosition(BTC_MARKET, address(usdc), collateral, 5, true); // size=1000e6
        vm.stopPrank();

        emit log_named_uint("[3] Position opened - size",       pm.getPosition(posId).size);
        emit log_named_uint("                       collateral", pm.getPosition(posId).collateral);

        // Push mark 100% above index ($190,000) → funding rate will hit MAX_RATE
        uint256 highMark = 95_000e18 * 2; // $190,000
        _pushMarkObs(highMark);            // 2 observations, 1 min apart

        // Advance 25 hours (25 complete funding intervals) + roll 1 block (required by 1-block delay)
        vm.warp(block.timestamp + 25 hours);
        vm.roll(block.number + 1);
        mockFeed.setPrice(95_000e8);       // keep index fresh

        // Push fresh mark inside the current 30-min TWAP window so high funding persists
        _pushMarkObs(highMark);

        // Settle funding — erodes collateral from 200e6 to ~12.5e6
        vm.prank(TRADER);
        pm.settleFunding(posId);

        uint256 collateralLeft = pm.getPosition(posId).collateral;
        emit log_named_uint("[3] Collateral after funding", collateralLeft);
        // Should be <= 200e6 - 187.5e6 = 12.5e6
        assertLt(collateralLeft, 20e6, "Collateral should be below maintenance margin (20e6)");

        // Confirm liquidatable
        assertTrue(liqEngine.isLiquidatable(posId), "Position should be liquidatable");
        emit log_string("    isLiquidatable = true");

        // Record balances before liquidation
        uint256 liquidatorBefore = vault.freeBalance(LIQUIDATOR, address(usdc));
        uint256 traderBefore     = vault.freeBalance(TRADER,     address(usdc));

        // Liquidate
        vm.prank(LIQUIDATOR);
        liqEngine.liquidate(posId);

        // Snapshot must be cleared
        (address snapTrader,,,,,,) = liqEngine.snapshots(posId);
        assertEq(snapTrader, address(0), "Snapshot cleared after liquidation");

        // Liquidator received 5 USDC (50% of 1% of 1000e6 notional)
        uint256 liquidatorGain = vault.freeBalance(LIQUIDATOR, address(usdc)) - liquidatorBefore;
        assertEq(liquidatorGain, 5e6, "Liquidator share = 5 USDC");

        // Trader received remaining (~2.5 USDC)
        uint256 traderGain = vault.freeBalance(TRADER, address(usdc)) - traderBefore;
        assertGt(traderGain, 0, "Trader receives remaining collateral");

        emit log_named_uint("[3] Liquidator gain (vault free balance)", liquidatorGain);
        emit log_named_uint("    Trader remaining returned            ", traderGain);
        emit log_string("=== PASS ===");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 4: Shariah guard — leverage above 5× always rejected
    // ═════════════════════════════════════════════════════════════════════════

    function test_4_ShariahGuardBlocks6xLeverage() public {
        emit log_string("");
        emit log_string("=== TEST 4: SHARIAH GUARD - BLOCKS 6x LEVERAGE ===");

        vm.startPrank(TRADER);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(address(usdc), 1_000e6);

        vm.expectRevert("PM: leverage out of range");
        pm.openPosition(BTC_MARKET, address(usdc), 1_000e6, 6, true);
        vm.stopPrank();

        emit log_string("[4] PASS - 6x leverage correctly rejected");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 5: Exactly 5× leverage is allowed
    // ═════════════════════════════════════════════════════════════════════════

    function test_5_ExactlyFiveXAllowed() public {
        emit log_string("");
        emit log_string("=== TEST 5: SHARIAH GUARD - EXACTLY 5x ALLOWED ===");

        vm.startPrank(TRADER);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(address(usdc), 1_000e6);
        bytes32 posId = pm.openPosition(BTC_MARKET, address(usdc), 1_000e6, 5, true);
        vm.stopPrank();

        PositionManager.Position memory pos = pm.getPosition(posId);
        assertTrue(pos.open,             "5x position open");
        assertEq(pos.size, 5_000e6,      "notional = 5x collateral");

        emit log_named_uint("[5] PASS - 5x position opened with size", pos.size);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // TEST 6: Withdrawal blocked within 24h cooldown
    // ═════════════════════════════════════════════════════════════════════════

    function test_6_WithdrawalCooldown() public {
        emit log_string("");
        emit log_string("=== TEST 6: WITHDRAWAL COOLDOWN ===");

        vm.startPrank(TRADER);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(address(usdc), 1_000e6);

        // Immediate withdrawal blocked
        vm.expectRevert("CollateralVault: withdrawal cooldown active");
        vault.withdraw(address(usdc), 1_000e6);
        vm.stopPrank();

        emit log_string("[6a] Immediate withdrawal correctly blocked");

        // After 24h + 1s it works
        _warpAndRefresh(24 hours + 1);

        vm.prank(TRADER);
        vault.withdraw(address(usdc), 1_000e6);

        assertEq(usdc.balanceOf(TRADER), 10_000e6, "Wallet restored after cooldown");
        emit log_string("[6b] Withdrawal after 24h succeeded");
        emit log_string("=== PASS ===");
    }
}
