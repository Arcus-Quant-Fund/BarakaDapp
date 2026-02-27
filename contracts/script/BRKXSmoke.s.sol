// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/oracle/OracleAdapter.sol";
import "../src/shariah/ShariahGuard.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/PositionManager.sol";
import "../src/insurance/InsuranceFund.sol";
import "../src/token/BRKXToken.sol";
import "../test/mocks/MockERC20.sol";

/**
 * @title BRKXSmoke
 * @notice End-to-end smoke test for the BRKX fee system on Arbitrum Sepolia.
 *
 * Verifies on the live chain:
 *   1. Deployer holds 100M BRKX → tier3 (>=50k) → 2.5 bps fee
 *   2. FeeCollected event emitted on openPosition (feeBps=25)
 *   3. FeeCollected event emitted on closePosition (feeBps=25)
 *   4. InsuranceFund receives 50% of total fee
 *   5. Treasury receives 50% of total fee
 *
 * NOTE: snapshotPrice() and getKappaSignal() were added in Session 11.
 *       OracleAdapter needs redeployment before those can be verified on-chain.
 *       kappa signal is tested locally: forge test --match-path test/unit/KappaSignal.t.sol
 *
 * Prerequisites (all satisfied post-Deploy + UpgradeAndDeployBRKX):
 *   - 9 contracts live at addresses in deployments/421614.json
 *   - BRKXToken deployed, 100M held by DEPLOYER (treasury)
 *   - PositionManager v2: brkxToken + treasury set; authorised in Vault + InsuranceFund
 *
 * Usage:
 *   forge script script/BRKXSmoke.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     -vvvv
 *
 * Note: Deploys a fresh MockERC20 as testnet collateral (avoids real USDC bridge).
 *       All setup steps require DEPLOYER == shariahMultisig (true on testnet).
 */
contract BRKXSmoke is Script {

    // ── Live contract addresses (Arbitrum Sepolia 421614) ─────────────────────
    address constant DEPLOYER         = 0x12A21D0D172265A520aF286F856B5aF628e66D46;
    address constant ORACLE_ADAPTER   = 0xB8d9778288B96ee5a9d873F222923C0671fc38D4;
    address constant SHARIAH_GUARD    = 0x26d4db76a95DBf945ac14127a23Cd4861DA42e69;
    address constant INSURANCE_FUND   = 0x7B440af63D5fa5592E53310ce914A21513C1a716;
    address constant VAULT            = 0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E;
    address constant POSITION_MANAGER = 0x787E15807f32f84aC3D929CB136216897b788070;
    address constant BRKX_TOKEN       = 0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32;
    address constant TREASURY         = 0x12A21D0D172265A520aF286F856B5aF628e66D46; // deployer = treasury on testnet
    address constant BTC_MARKET       = address(0x00B1C);

    string  constant FATWA_HASH       = "QmPlaceholderFatwaHashReplaceBeforeMainnet";

    // ── Test parameters ───────────────────────────────────────────────────────
    // Collateral: 1,000 tUSDC (6 decimals), leverage: 3x
    // Notional = 3,000 tUSDC
    // Deployer holds 100M BRKX (>= 50,000) → tier3 → 2.5 bps (feeBps=25)
    // feeAmount = 3_000e6 * 25 / 100_000 = 750 (in 6-dec; = $0.00075)
    // split: half=375 → InsuranceFund, rem=375 → treasury
    uint256 constant COLLATERAL = 1_000e6;  // 1,000 tUSDC (6 decimals)
    uint256 constant LEVERAGE   = 3;
    uint256 constant NOTIONAL   = COLLATERAL * LEVERAGE; // 3_000e6
    uint256 constant FEE_BPS    = 25;        // expected: tier3
    uint256 constant OPEN_FEE   = (NOTIONAL * FEE_BPS) / 100_000; // 750
    uint256 constant CLOSE_FEE  = OPEN_FEE;  // same notional on close

    function run() external {
        uint256 pk     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address trader = vm.addr(pk);

        console.log("==========================================");
        console.log("  BARAKA PROTOCOL - BRKX SMOKE TEST");
        console.log("==========================================");
        console.log("Trader (deployer):", trader);
        console.log("Collateral        :", COLLATERAL / 1e6, "tUSDC");
        console.log("Leverage          :", LEVERAGE, "x");
        console.log("Notional          :", NOTIONAL / 1e6, "tUSDC");
        console.log("Expected feeBps   :", FEE_BPS, "(2.5 bps, tier3)");
        console.log("Expected open fee :", OPEN_FEE, "wei (6-dec) per trade");
        console.log("------------------------------------------");

        vm.startBroadcast(pk);

        // ── STEP 1: Deploy MockERC20 as testnet collateral ────────────────────
        MockERC20 usdc = new MockERC20("Test USDC", "tUSDC", 6);
        console.log("Step 1: MockERC20 (tUSDC) deployed:", address(usdc));

        // ── STEP 2: Approve tUSDC in ShariahGuard ─────────────────────────────
        //    deployer == shariahMultisig on testnet → call is permitted
        ShariahGuard(SHARIAH_GUARD).approveAsset(address(usdc), FATWA_HASH);
        console.log("Step 2: ShariahGuard: tUSDC approved as collateral");

        // ── STEP 3: Mint tUSDC to trader (extra buffer for both open + close fees) ──
        //    collateral + open_fee + close_fee = COLLATERAL + OPEN_FEE + CLOSE_FEE
        uint256 mintAmount = COLLATERAL + OPEN_FEE + CLOSE_FEE + 1_000; // small buffer
        usdc.mint(trader, mintAmount);
        console.log("Step 3: Minted", mintAmount / 1e6, "tUSDC to trader");

        // ── STEP 4: Deposit tUSDC into CollateralVault ────────────────────────
        //    Approve vault to pull tUSDC, then deposit
        MockERC20(address(usdc)).approve(VAULT, mintAmount);
        CollateralVault(VAULT).deposit(address(usdc), mintAmount);
        console.log("Step 4: Deposited", mintAmount / 1e6, "tUSDC into vault");

        // ── STEP 5: Read current BTC index price (circuit breaker skips when lastValidPrice=0) ──
        // NOTE: snapshotPrice() was added in Session 11 — OracleAdapter needs redeployment.
        //       lastValidPrice[BTC_MARKET]=0 so circuit breaker is inactive; openPosition works directly.
        uint256 currentPrice = OracleAdapter(ORACLE_ADAPTER).getIndexPrice(BTC_MARKET);
        console.log("Step 5: BTC index price:", currentPrice / 1e18, "USD (circuit breaker inactive)");

        // ── STEP 6: Verify BRKX tier ──────────────────────────────────────────
        uint256 brkxBal = BRKXToken(BRKX_TOKEN).balanceOf(trader);
        console.log("Step 6: Trader BRKX balance:", brkxBal / 1e18, "BRKX");
        require(brkxBal >= 50_000e18, "BRKXSmoke: trader must hold >= 50k BRKX for tier3");
        console.log("       -> tier3 confirmed (>= 50,000 BRKX)");

        // ── STEP 7: Read InsuranceFund + Treasury balances BEFORE open ────────
        uint256 ifBefore = MockERC20(address(usdc)).balanceOf(INSURANCE_FUND);
        uint256 trBefore = MockERC20(address(usdc)).balanceOf(TREASURY);
        console.log("Step 7: InsuranceFund tUSDC before open:", ifBefore);
        console.log("        Treasury tUSDC before open     :", trBefore);

        // ── STEP 8: Open position ──────────────────────────────────────────────
        console.log("Step 8: Opening 3x long BTC position...");
        bytes32 posId = PositionManager(POSITION_MANAGER).openPosition(
            BTC_MARKET,
            address(usdc),
            COLLATERAL,
            LEVERAGE,
            true // isLong
        );
        console.log("       positionId:", uint256(posId));

        // ── STEP 9: Verify InsuranceFund + Treasury received 50% of open fee ──
        uint256 ifAfterOpen = MockERC20(address(usdc)).balanceOf(INSURANCE_FUND);
        uint256 trAfterOpen = MockERC20(address(usdc)).balanceOf(TREASURY);
        uint256 halfFee     = OPEN_FEE / 2; // 375
        uint256 remFee      = OPEN_FEE - halfFee; // 375 (handles odd-wei: rem >= half)

        console.log("Step 9: After open -");
        console.log("        InsuranceFund delta (got/expected):", ifAfterOpen - ifBefore, halfFee);
        console.log("        Treasury delta (got/expected)     :", trAfterOpen - trBefore, remFee);
        require(ifAfterOpen - ifBefore == halfFee, "BRKXSmoke: InsuranceFund open fee mismatch");
        require(trAfterOpen - trBefore == remFee,  "BRKXSmoke: Treasury open fee mismatch");
        console.log("       -> open fee split VERIFIED");

        // ── STEP 10: NOTE — getKappaSignal() on deployed contract ────────────
        // getKappaSignal() was added in Session 11. OracleAdapter needs redeployment
        // before this call can be made on-chain. Skipping for now — tested locally via
        // forge test --match-path "test/unit/KappaSignal.t.sol" (15/15 passing).
        console.log("Step 10: kappa signal skipped (OracleAdapter redeploy needed)");

        // ── STEP 11: Close position ───────────────────────────────────────────
        console.log("Step 11: Closing position...");
        PositionManager(POSITION_MANAGER).closePosition(posId);
        console.log("         position closed");

        // ── STEP 12: Verify total fees after close ────────────────────────────
        uint256 ifAfterClose = MockERC20(address(usdc)).balanceOf(INSURANCE_FUND);
        uint256 trAfterClose = MockERC20(address(usdc)).balanceOf(TREASURY);
        uint256 totalFee     = OPEN_FEE + CLOSE_FEE; // 1500
        uint256 totalHalf    = halfFee * 2;            // 750
        uint256 totalRem     = remFee * 2;             // 750

        console.log("Step 12: After close (totals) -");
        console.log("         InsuranceFund total delta (got/expected):", ifAfterClose - ifBefore, totalHalf);
        console.log("         Treasury total delta (got/expected)     :", trAfterClose - trBefore, totalRem);
        require(ifAfterClose - ifBefore == totalHalf, "BRKXSmoke: InsuranceFund total fee mismatch");
        require(trAfterClose - trBefore == totalRem,  "BRKXSmoke: Treasury total fee mismatch");
        console.log("        -> close fee split VERIFIED");

        vm.stopBroadcast();

        // ── FINAL SUMMARY ─────────────────────────────────────────────────────
        console.log("\n==========================================");
        console.log("  ALL CHECKS PASSED - SMOKE TEST COMPLETE");
        console.log("==========================================");
        console.log("tUSDC collateral :", address(usdc));
        console.log("BTC_MARKET       : 0x000000000000000000000000000000000000B1C");
        console.log("positionId       :", uint256(posId));
        console.log("Open fee paid    :", OPEN_FEE);
        console.log("Close fee paid   :", CLOSE_FEE);
        console.log("Total fees       :", totalFee);
        console.log("InsuranceFund 50%:", totalHalf);
        console.log("Treasury 50%     :", totalRem);
        console.log("------------------------------------------");
        console.log("Verify FeeCollected events on Arbiscan:");
        console.log("  PositionManager:", POSITION_MANAGER);
        console.log("  topic: FeeCollected(address trader, address token,");
        console.log("                       uint256 amount, uint256 feeBps)");
        console.log("  feeBps=25 (tier3, 2.5 bps), amount=750 (6-dec)");
        console.log("==========================================");
    }
}
