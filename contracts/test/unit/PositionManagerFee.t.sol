// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import "../../src/core/PositionManager.sol";
import "../../src/core/CollateralVault.sol";
import "../../src/core/FundingEngine.sol";
import "../../src/core/LiquidationEngine.sol";
import "../../src/insurance/InsuranceFund.sol";
import "../../src/shariah/ShariahGuard.sol";
import "../../src/token/BRKXToken.sol";
import "../mocks/MockOracle.sol";
import "../mocks/MockERC20.sol";

/**
 * @title PositionManagerFeeTest
 * @notice 8 unit tests for the BRKX hold-based fee discount system.
 *
 * Setup:
 *   Full protocol stack deployed fresh per test.
 *   BRKX token configured on PositionManager (fees enabled).
 *   Trader deposits collateral + fee buffer so openPosition can charge from free balance.
 *
 * Fee formula: feeAmount = notional * feeBps / 100_000
 *   where feeBps ∈ {50, 40, 35, 25} depending on BRKX balance.
 *
 * Tests:
 *   1. Zero BRKX held → 5 bps fee charged.
 *   2. Hold 1,000 BRKX → 4 bps fee charged.
 *   3. Hold 10,000 BRKX → 3.5 bps fee charged.
 *   4. Hold 50,000 BRKX → 2.5 bps fee charged.
 *   5. Fee disabled when brkxToken == address(0).
 *   6. InsuranceFund receives 50% of fee.
 *   7. Treasury receives 50% of fee.
 *   8. FeeCollected event emitted with correct args.
 */
contract PositionManagerFeeTest is Test {

    // ── System contracts ─────────────────────────────────────────────────────

    ShariahGuard      public guard;
    FundingEngine     public engine;
    InsuranceFund     public insurance;
    CollateralVault   public vault;
    LiquidationEngine public liqEngine;
    PositionManager   public pm;
    MockOracle        public oracle;
    BRKXToken         public brkx;

    // ── Actors ───────────────────────────────────────────────────────────────

    address public owner        = address(0xABCD);
    address public shariahBoard = address(0xBEEF);
    address public treasury     = address(0xFEED);
    address public trader       = address(0xCAFE);

    // ── Test assets ──────────────────────────────────────────────────────────

    MockERC20 public usdc;
    address   public wbtc = address(0x00B1C);

    // ── Constants ────────────────────────────────────────────────────────────

    string  constant FATWA     = "ipfs://QmFatwaTest";
    uint256 constant BTC_PRICE = 50_000e18;

    // Collateral used in each test
    uint256 constant COLLATERAL = 1_000e6; // 1,000 USDC (6 decimals)
    uint256 constant LEVERAGE   = 3;
    uint256 constant NOTIONAL   = COLLATERAL * LEVERAGE; // 3,000e6

    // Fee amounts at each tier (notional = 3,000e6)
    //   fee = 3_000e6 * feeBps / 100_000
    uint256 constant FEE_5BPS  = 3_000e6 * 50 / 100_000; // 1.5e6 = 1_500_000
    uint256 constant FEE_4BPS  = 3_000e6 * 40 / 100_000; // 1.2e6 = 1_200_000
    uint256 constant FEE_35BPS = 3_000e6 * 35 / 100_000; // 1.05e6 = 1_050_000
    uint256 constant FEE_25BPS = 3_000e6 * 25 / 100_000; // 0.75e6 =   750_000

    // ─────────────────────────────────────────────────────────────────────────
    // setUp — deploy full protocol + configure BRKX fees
    // ─────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.startPrank(owner);

        // Deploy infrastructure
        usdc      = new MockERC20("USD Coin", "USDC", 6);
        oracle    = new MockOracle();
        guard     = new ShariahGuard(shariahBoard);
        engine    = new FundingEngine(owner, address(oracle));
        insurance = new InsuranceFund(owner);
        vault     = new CollateralVault(owner, address(guard));
        liqEngine = new LiquidationEngine(owner, address(insurance), address(vault));
        pm        = new PositionManager(
            owner,
            address(guard),
            address(engine),
            address(oracle),
            address(vault),
            address(liqEngine),
            address(insurance)
        );

        // Deploy BRKX token (100M to owner as treasury for tests)
        brkx = new BRKXToken(owner);

        // Wire authorisations
        vault.setAuthorised(address(pm),        true);
        vault.setAuthorised(address(liqEngine), true);
        liqEngine.setPositionManager(address(pm));

        // Authorise PM to call InsuranceFund (needed for fee split to IF)
        insurance.setAuthorised(address(pm), true);

        // Configure fees on PositionManager
        pm.setBrkxToken(address(brkx));
        pm.setTreasury(treasury);

        vm.stopPrank();

        // Shariah board approves assets
        vm.startPrank(shariahBoard);
        guard.approveAsset(address(usdc), FATWA);
        guard.approveAsset(wbtc,          FATWA);
        vm.stopPrank();

        // Seed oracle
        oracle.setIndexPrice(wbtc, BTC_PRICE);
        oracle.setMarkPrice(wbtc,  BTC_PRICE);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Mint USDC to trader, deposit COLLATERAL + extra buffer into vault.
     *      The buffer covers the opening fee so chargeFromFree doesn't revert.
     */
    function _depositWithBuffer(uint256 feeBuffer) internal {
        uint256 total = COLLATERAL + feeBuffer;
        usdc.mint(trader, total);
        vm.startPrank(trader);
        usdc.approve(address(vault), total);
        vault.deposit(address(usdc), total);
        vm.stopPrank();
    }

    /**
     * @dev Give trader `brkxAmount` BRKX tokens (from owner's 100M supply).
     */
    function _giveBrkx(uint256 brkxAmount) internal {
        vm.prank(owner);
        brkx.transfer(trader, brkxAmount);
    }

    /**
     * @dev Open a 3x long position as trader, return positionId.
     */
    function _openLong() internal returns (bytes32 positionId) {
        vm.prank(trader);
        positionId = pm.openPosition(wbtc, address(usdc), COLLATERAL, LEVERAGE, true);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 1: Zero BRKX held → 5 bps fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_1_ZeroBrkx_FiveBasepointsFee() public {
        // Trader holds 0 BRKX → 5 bps tier
        _depositWithBuffer(FEE_5BPS);

        uint256 freeBeforeOpen = vault.freeBalance(trader, address(usdc));
        // freeBeforeOpen = COLLATERAL + FEE_5BPS

        _openLong();

        // After open: collateral locked, fee charged from free balance
        // Expected: freeBalance = freeBeforeOpen - COLLATERAL - FEE_5BPS = 0
        assertEq(
            vault.freeBalance(trader, address(usdc)),
            freeBeforeOpen - COLLATERAL - FEE_5BPS,
            "5 bps fee deducted from free balance on open"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 2: Hold 1,000 BRKX → 4 bps fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_2_Hold1000Brkx_FourBasepointsFee() public {
        _giveBrkx(1_000e18);
        _depositWithBuffer(FEE_4BPS);

        uint256 freeBefore = vault.freeBalance(trader, address(usdc));

        _openLong();

        assertEq(
            vault.freeBalance(trader, address(usdc)),
            freeBefore - COLLATERAL - FEE_4BPS,
            "4 bps fee deducted (1,000 BRKX tier)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 3: Hold 10,000 BRKX → 3.5 bps fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_3_Hold10kBrkx_ThreePointFiveBasepointsFee() public {
        _giveBrkx(10_000e18);
        _depositWithBuffer(FEE_35BPS);

        uint256 freeBefore = vault.freeBalance(trader, address(usdc));

        _openLong();

        assertEq(
            vault.freeBalance(trader, address(usdc)),
            freeBefore - COLLATERAL - FEE_35BPS,
            "3.5 bps fee deducted (10,000 BRKX tier)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 4: Hold 50,000 BRKX → 2.5 bps fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_4_Hold50kBrkx_TwoPointFiveBasepointsFee() public {
        _giveBrkx(50_000e18);
        _depositWithBuffer(FEE_25BPS);

        uint256 freeBefore = vault.freeBalance(trader, address(usdc));

        _openLong();

        assertEq(
            vault.freeBalance(trader, address(usdc)),
            freeBefore - COLLATERAL - FEE_25BPS,
            "2.5 bps fee deducted (50,000 BRKX tier)"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 5: Fee disabled when brkxToken == address(0)
    // ═════════════════════════════════════════════════════════════════════════

    function test_5_FeesDisabledWhenBrkxNotSet() public {
        // Disable fees by setting brkxToken to zero address
        vm.prank(owner);
        pm.setBrkxToken(address(0));

        // Deposit exactly COLLATERAL (no fee buffer needed)
        usdc.mint(trader, COLLATERAL);
        vm.startPrank(trader);
        usdc.approve(address(vault), COLLATERAL);
        vault.deposit(address(usdc), COLLATERAL);
        vm.stopPrank();

        _openLong();

        // Only collateral locked, no fee taken
        assertEq(
            vault.freeBalance(trader, address(usdc)),
            0,
            "no fee when brkxToken == address(0)"
        );
        // Full collateral locked
        assertEq(
            vault.lockedBalance(trader, address(usdc)),
            COLLATERAL,
            "full collateral locked"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 6: InsuranceFund receives 50% of fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_6_InsuranceFundReceivesHalfOfFee() public {
        // No BRKX → 5 bps fee. FEE_5BPS = 1_500_000
        _depositWithBuffer(FEE_5BPS);

        uint256 ifBalanceBefore = insurance.fundBalance(address(usdc));

        _openLong();

        uint256 ifBalanceAfter = insurance.fundBalance(address(usdc));
        uint256 half = FEE_5BPS / 2; // 750_000

        assertEq(
            ifBalanceAfter - ifBalanceBefore,
            half,
            "InsuranceFund received 50% of fee"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 7: Treasury receives 50% of fee
    // ═════════════════════════════════════════════════════════════════════════

    function test_7_TreasuryReceivesHalfOfFee() public {
        // No BRKX → 5 bps fee. FEE_5BPS = 1_500_000
        _depositWithBuffer(FEE_5BPS);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _openLong();

        uint256 treasuryAfter = usdc.balanceOf(treasury);
        uint256 rem = FEE_5BPS - FEE_5BPS / 2; // 750_000 (or 750_001 if odd, but 1_500_000 is even)

        assertEq(
            treasuryAfter - treasuryBefore,
            rem,
            "treasury received 50% of fee"
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Test 8: FeeCollected event emitted with correct args
    // ═════════════════════════════════════════════════════════════════════════

    function test_8_FeeCollectedEventEmitted() public {
        // No BRKX → 5 bps (feeBps = 50 in ×10 scale)
        _depositWithBuffer(FEE_5BPS);

        // Expect FeeCollected(trader, usdc, FEE_5BPS, 50)
        vm.expectEmit(true, true, false, true);
        emit PositionManager.FeeCollected(trader, address(usdc), FEE_5BPS, 50);

        _openLong();
    }
}
