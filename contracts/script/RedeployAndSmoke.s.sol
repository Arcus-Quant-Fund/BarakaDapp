// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/oracle/OracleAdapter.sol";
import "../src/shariah/ShariahGuard.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/FundingEngine.sol";
import "../src/insurance/InsuranceFund.sol";
import "../src/core/LiquidationEngine.sol";
import "../src/core/PositionManager.sol";
import "../src/shariah/GovernanceModule.sol";
import "../src/token/BRKXToken.sol";
import "../test/mocks/MockERC20.sol";

/**
 * @title RedeployAndSmoke
 * @notice Redeploys the 4 contracts that needed new functions, rewires all
 *         dependencies, then runs the full BRKX fee smoke test on Arbitrum Sepolia.
 *
 * WHY REDEPLOY: Session 11 added chargeFromFree (CollateralVault),
 *   snapshotPrice/getKappaSignal (OracleAdapter). These functions are missing
 *   from the originally deployed contracts. Since vault/oracle are immutable
 *   constructor args in PositionManager and LiquidationEngine, all 4 must be
 *   redeployed together.
 *
 * UNCHANGED (reused from previous deployment):
 *   ShariahGuard, FundingEngine, InsuranceFund, GovernanceModule, BRKXToken
 *   (FundingEngine has setOracle() so it can point to new OracleAdapter)
 *
 * After this script succeeds, update deployments/421614.json with new addresses.
 *
 * Usage:
 *   forge script script/RedeployAndSmoke.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     -vvvv
 */
contract RedeployAndSmoke is Script {

    // ── UNCHANGED contracts (Arbitrum Sepolia 421614) ─────────────────────────
    address constant DEPLOYER         = 0x12A21D0D172265A520aF286F856B5aF628e66D46;
    address constant SHARIAH_GUARD    = 0x26d4db76a95DBf945ac14127a23Cd4861DA42e69;
    address constant FUNDING_ENGINE   = 0x459BE882BC8736e92AA4589D1b143e775b114b38;
    address constant INSURANCE_FUND   = 0x7B440af63D5fa5592E53310ce914A21513C1a716;
    address constant GOVERNANCE       = 0x8c987818dffcD00c000Fe161BFbbD414B0529341;
    address constant BRKX_TOKEN       = 0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32;
    address constant TREASURY         = 0x12A21D0D172265A520aF286F856B5aF628e66D46;

    // ── BTC market + Chainlink feed (unchanged) ───────────────────────────────
    address constant BTC_MARKET       = address(0x00B1C);
    address constant CHAINLINK_BTC    = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;
    string  constant FATWA_HASH       = "QmPlaceholderFatwaHashReplaceBeforeMainnet";

    // ── Smoke test parameters ─────────────────────────────────────────────────
    uint256 constant COLLATERAL = 1_000e6;  // 1,000 tUSDC (6-decimal)
    uint256 constant LEVERAGE   = 3;
    uint256 constant NOTIONAL   = COLLATERAL * LEVERAGE; // 3,000e6
    // Deployer holds 100M BRKX (>=50k) -> tier3 -> 2.5 bps (feeBps=25)
    // feeAmount = 3_000e6 * 25 / 100_000 = 750 (6-dec)
    uint256 constant FEE_BPS    = 25;
    uint256 constant OPEN_FEE   = (NOTIONAL * FEE_BPS) / 100_000; // 750
    uint256 constant CLOSE_FEE  = OPEN_FEE;

    function run() external {
        uint256 pk     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address trader = vm.addr(pk);

        console.log("==========================================");
        console.log("  BARAKA - REDEPLOY CORE + SMOKE TEST");
        console.log("==========================================");
        console.log("Deployer:", trader);

        vm.startBroadcast(pk);

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 1: REDEPLOY THE 4 STALE CONTRACTS
        // ══════════════════════════════════════════════════════════════════════

        // ── 1a. OracleAdapter v2 (adds getKappaSignal, snapshotPrice) ─────────
        OracleAdapter newOracle = new OracleAdapter(DEPLOYER);
        newOracle.setOracle(BTC_MARKET, CHAINLINK_BTC, CHAINLINK_BTC);
        console.log("1a. OracleAdapter v2 :", address(newOracle));

        // ── 1b. CollateralVault v2 (adds chargeFromFree) ──────────────────────
        CollateralVault newVault = new CollateralVault(DEPLOYER, SHARIAH_GUARD);
        console.log("1b. CollateralVault v2:", address(newVault));

        // ── 1c. LiquidationEngine v2 (vault is immutable -> must redeploy) ────
        LiquidationEngine newLiqEngine = new LiquidationEngine(
            DEPLOYER,
            INSURANCE_FUND,
            address(newVault)
        );
        console.log("1c. LiquidationEngine v2:", address(newLiqEngine));

        // ── 1d. PositionManager v3 (oracle+vault+liqEngine all immutable) ─────
        PositionManager newPm = new PositionManager(
            DEPLOYER,
            SHARIAH_GUARD,
            FUNDING_ENGINE,
            address(newOracle),
            address(newVault),
            address(newLiqEngine),
            INSURANCE_FUND
        );
        console.log("1d. PositionManager v3:", address(newPm));

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 2: REWIRE ALL DEPENDENCIES
        // ══════════════════════════════════════════════════════════════════════

        // FundingEngine: update oracle pointer (has setOracle - no redeploy needed)
        FundingEngine(FUNDING_ENGINE).setOracle(address(newOracle));
        console.log("2a. FundingEngine: oracle updated to v2");

        // CollateralVault: authorise new PM + new LiqEngine
        newVault.setAuthorised(address(newPm),        true);
        newVault.setAuthorised(address(newLiqEngine), true);
        console.log("2b. CollateralVault: PM v3 + LiqEngine v2 authorised");

        // InsuranceFund: authorise new PM (old PM revoked implicitly - not a security risk on testnet)
        InsuranceFund(INSURANCE_FUND).setAuthorised(address(newPm), true);
        console.log("2c. InsuranceFund: PM v3 authorised");

        // LiquidationEngine: point to new PM
        newLiqEngine.setPositionManager(address(newPm));
        console.log("2d. LiquidationEngine: PositionManager v3 set");

        // PositionManager: enable BRKX fee system
        newPm.setBrkxToken(BRKX_TOKEN);
        newPm.setTreasury(TREASURY);
        console.log("2e. PositionManager v3: BRKX token + treasury set");

        console.log("------------------------------------------");
        console.log("All contracts deployed and wired. Starting smoke test...");
        console.log("------------------------------------------");

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 3: SMOKE TEST
        // ══════════════════════════════════════════════════════════════════════

        // ── Step 1: Deploy testnet collateral token ────────────────────────
        MockERC20 usdc = new MockERC20("Test USDC", "tUSDC", 6);
        console.log("Step 1: MockERC20 (tUSDC):", address(usdc));

        // ── Step 2: Approve tUSDC in ShariahGuard ─────────────────────────
        ShariahGuard(SHARIAH_GUARD).approveAsset(address(usdc), FATWA_HASH);
        console.log("Step 2: ShariahGuard: tUSDC approved");

        // ── Step 3: Mint tUSDC to trader ───────────────────────────────────
        uint256 mintAmount = COLLATERAL + OPEN_FEE + CLOSE_FEE + 1_000;
        usdc.mint(trader, mintAmount);
        console.log("Step 3: Minted", mintAmount / 1e6, "tUSDC to trader");

        // ── Step 4: Deposit into new vault ────────────────────────────────
        usdc.approve(address(newVault), mintAmount);
        newVault.deposit(address(usdc), mintAmount);
        console.log("Step 4: Deposited into vault");

        // ── Step 5: Snapshot oracle to seed circuit breaker baseline ──────
        uint256 btcPrice = newOracle.snapshotPrice(BTC_MARKET);
        console.log("Step 5: BTC price snapshotted:", btcPrice / 1e18, "USD");

        // ── Step 6: Verify BRKX tier ───────────────────────────────────────
        uint256 brkxBal = BRKXToken(BRKX_TOKEN).balanceOf(trader);
        console.log("Step 6: BRKX balance:", brkxBal / 1e18, "BRKX");
        require(brkxBal >= 50_000e18, "RedeployAndSmoke: need >=50k BRKX for tier3");
        console.log("       -> tier3 confirmed (>=50k BRKX = 2.5 bps)");

        // ── Step 7: Read balances before open ─────────────────────────────
        uint256 ifBefore = usdc.balanceOf(INSURANCE_FUND);
        uint256 trBefore = usdc.balanceOf(TREASURY);
        console.log("Step 7: IF balance before:", ifBefore, "/ treasury:", trBefore);

        // ── Step 8: Open 3x long position ─────────────────────────────────
        console.log("Step 8: Opening 3x long BTC...");
        bytes32 posId = newPm.openPosition(
            BTC_MARKET,
            address(usdc),
            COLLATERAL,
            LEVERAGE,
            true
        );
        console.log("       posId:", uint256(posId));

        // ── Step 9: Verify open fee split ──────────────────────────────────
        uint256 halfFee = OPEN_FEE / 2;
        uint256 remFee  = OPEN_FEE - halfFee;

        uint256 ifAfterOpen = usdc.balanceOf(INSURANCE_FUND);
        uint256 trAfterOpen = usdc.balanceOf(TREASURY);
        console.log("Step 9: IF delta (got/expected):", ifAfterOpen - ifBefore, halfFee);
        console.log("        TR delta (got/expected):", trAfterOpen - trBefore, remFee);
        require(ifAfterOpen - ifBefore == halfFee, "RedeployAndSmoke: IF open fee wrong");
        require(trAfterOpen - trBefore == remFee,  "RedeployAndSmoke: treasury open fee wrong");
        console.log("       -> open fee split VERIFIED (feeBps=25, 2.5 bps, tier3)");

        // ── Step 10: Verify getKappaSignal on new OracleAdapter ───────────
        (int256 kappa, int256 premium, uint8 regime) = newOracle.getKappaSignal(BTC_MARKET);
        console.log("Step 10: kappa   :", kappa);
        console.log("         premium :", premium);
        console.log("         regime  :", regime);
        require(regime <= 3, "RedeployAndSmoke: regime out of range");
        console.log("        -> kappa signal VERIFIED (regime 0-3)");

        // ── Step 11: NOTE — closePosition omitted from broadcast smoke ──────
        // posId = keccak256(msg.sender, asset, token, block.timestamp, block.number).
        // Forge's broadcast pre-simulation runs against live chain state where the
        // position does not yet exist -> closePosition reverts "PM: position not open".
        // Close-fee split uses the identical code path; verified by unit tests 8/8.
        console.log("Step 11: closePosition skipped (block-dependent posId; see unit tests)");
        console.log("         PositionManagerFee.t.sol 8/8 covers close fee split");

        vm.stopBroadcast();

        // ══════════════════════════════════════════════════════════════════════
        // FINAL SUMMARY
        // ══════════════════════════════════════════════════════════════════════
        console.log("\n==========================================");
        console.log("  ALL CHECKS PASSED (open-only E2E)");
        console.log("==========================================");
        console.log("NEW CONTRACT ADDRESSES (update 421614.json):");
        console.log("  OracleAdapter v2  :", address(newOracle));
        console.log("  CollateralVault v2:", address(newVault));
        console.log("  LiquidationEngine v2:", address(newLiqEngine));
        console.log("  PositionManager v3:", address(newPm));
        console.log("------------------------------------------");
        console.log("SMOKE TEST RESULTS:");
        console.log("  feeBps            : 25 (tier3, >=50k BRKX = 2.5 bps)");
        console.log("  open fee charged  :", OPEN_FEE, "tUSDC-wei");
        console.log("  InsuranceFund 50% :", halfFee, "tUSDC-wei (open)");
        console.log("  Treasury 50%      :", remFee, "tUSDC-wei (open)");
        console.log("  kappa regime      :", regime, "(0=NORMAL)");
        console.log("  close fee         : unit-tested (PositionManagerFee.t.sol 8/8)");
        console.log("==========================================");
        console.log("NEXT: Update deployments/421614.json and verify on Arbiscan");
        console.log("==========================================");
    }
}
