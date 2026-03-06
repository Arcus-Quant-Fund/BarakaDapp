// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/oracle/OracleAdapter.sol";
import "../src/core/FundingEngine.sol";
import "../src/core/LiquidationEngine.sol";
import "../src/core/PositionManager.sol";
import "../src/core/CollateralVault.sol";
import "../src/insurance/InsuranceFund.sol";
import "../src/shariah/GovernanceModule.sol";
import "../src/core/EverlastingOption.sol";
import "../src/takaful/TakafulPool.sol";
import "../src/credit/PerpetualSukuk.sol";
import "../src/credit/iCDS.sol";
import "../src/shariah/ShariahGuard.sol";
import "../src/token/BRKXToken.sol";
import "../test/mocks/MockERC20.sol";

/**
 * @title AuditFixRedeploy
 * @notice Redeploys all contracts that changed during the AI security audit
 *         (Sessions 18-19: C-1/C-2/C-3/C-4 + H-1/H-2/H-5/H-6 fixes).
 *
 * WHAT CHANGED:
 *   C-2: LiquidationEngine — oracle equity check (entryPrice in LiqSnapshot)
 *   C-3: PositionManager — payPnl settlement via InsuranceFund
 *   H-1: FundingEngine — interval cap at 720 (30 days max)
 *   H-2: OracleAdapter — snapshotPrice() is now onlyOwner
 *   H-5: GovernanceModule — QUORUM_BPS = 400 (4% of totalSupply)
 *   H-6: iCDS — lastPremiumAt += PREMIUM_PERIOD (not block.timestamp)
 *
 * CASCADE (contracts using changed addresses as immutable constructor args):
 *   OracleAdapter changed → EverlastingOption, PositionManager, TakafulPool,
 *                            PerpetualSukuk, iCDS all take oracle as immutable
 *   FundingEngine changed → PositionManager takes fundingEngine as immutable
 *   LiquidationEngine changed → PositionManager takes liqEngine as immutable
 *
 * UNCHANGED (reused from previous deployment):
 *   ShariahGuard, InsuranceFund, CollateralVault, BRKXToken
 *
 * Usage:
 *   export DEPLOYER_PRIVATE_KEY=<key>
 *   forge script script/AuditFixRedeploy.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract AuditFixRedeploy is Script {

    // ── Unchanged contracts (Arbitrum Sepolia 421614) ─────────────────────────
    address constant DEPLOYER        = 0x12A21D0D172265A520aF286F856B5aF628e66D46;
    address constant SHARIAH_GUARD   = 0x26d4db76a95DBf945ac14127a23Cd4861DA42e69;
    address constant INSURANCE_FUND  = 0x7B440af63D5fa5592E53310ce914A21513C1a716;
    address constant COLLATERAL_VAULT= 0x0e9e32e4e061Db57eE5d3309A986423A5ad3227E;
    address constant BRKX_TOKEN      = 0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32;
    address constant TREASURY        = 0x12A21D0D172265A520aF286F856B5aF628e66D46;

    // ── Market + feed addresses ──────────────────────────────────────────────
    address constant BTC_MARKET      = address(0x00B1C);            // core PM market key
    address constant BTC_ASSET       = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f; // product stack key
    address constant CHAINLINK_BTC   = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69; // BTC/USD Arb Sepolia
    address constant USDC            = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d; // Aave testnet USDC

    // ── EverlastingOption / TakafulPool market params ────────────────────────
    uint256 constant SIGMA2          = 64e16;    // σ² = 0.64 (80% annual vol)
    uint256 constant KAPPA           = 83e15;    // κ = 8.3%/year (IES calibration)
    uint256 constant FLOOR_WAD       = 40_000e18; // TakafulPool BTC floor = $40k

    // ── Fatwa hash (testnet placeholder) ────────────────────────────────────
    string constant FATWA_HASH       = "QmPlaceholderFatwaHashReplaceBeforeMainnet";

    // ── Smoke test parameters ────────────────────────────────────────────────
    uint256 constant COLLATERAL      = 1_000e6;   // 1,000 tUSDC (6-decimal)
    uint256 constant LEVERAGE        = 3;
    uint256 constant NOTIONAL        = COLLATERAL * LEVERAGE;
    uint256 constant FEE_BPS         = 25;        // tier3 (>=50k BRKX = 2.5 bps)
    uint256 constant OPEN_FEE        = (NOTIONAL * FEE_BPS) / 100_000; // 750

    function run() external {
        uint256 pk      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address trader  = vm.addr(pk);

        console.log("==========================================================");
        console.log("  BARAKA PROTOCOL - AUDIT FIX REDEPLOY (Sessions 18-19)");
        console.log("==========================================================");
        console.log("Deployer:", trader);

        vm.startBroadcast(pk);

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 1 — CORE INFRASTRUCTURE
        // ══════════════════════════════════════════════════════════════════════

        // 1a. OracleAdapter v3 (H-2: snapshotPrice is now onlyOwner)
        OracleAdapter newOracle = new OracleAdapter(DEPLOYER);
        // Configure Chainlink feed for both market keys
        newOracle.setOracle(BTC_MARKET, CHAINLINK_BTC, CHAINLINK_BTC);
        newOracle.setOracle(BTC_ASSET,  CHAINLINK_BTC, CHAINLINK_BTC);
        console.log("1a. OracleAdapter v3  :", address(newOracle));

        // 1b. FundingEngine v2 (H-1: intervals capped at 720)
        FundingEngine newFunding = new FundingEngine(DEPLOYER, address(newOracle));
        console.log("1b. FundingEngine v2  :", address(newFunding));

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 2 — STANDALONE CONTRACTS
        // ══════════════════════════════════════════════════════════════════════

        // 2a. GovernanceModule v2 (H-5: QUORUM_BPS = 400, 4% of totalSupply)
        GovernanceModule newGov = new GovernanceModule(DEPLOYER, address(0));
        console.log("2a. GovernanceModule v2 :", address(newGov));

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 3 — CORE CONTRACTS (depend on oracle + FundingEngine)
        // ══════════════════════════════════════════════════════════════════════

        // 3a. LiquidationEngine v3 (C-2: oracle equity check, entryPrice in snapshot)
        //     Vault is unchanged (CollateralVault at COLLATERAL_VAULT)
        LiquidationEngine newLiqEngine = new LiquidationEngine(
            DEPLOYER,
            INSURANCE_FUND,
            COLLATERAL_VAULT
        );
        // Wire oracle for real-time equity check (C-2 fix)
        newLiqEngine.setOracle(address(newOracle));
        console.log("3a. LiquidationEngine v3:", address(newLiqEngine));

        // 3b. PositionManager v4 (C-3: payPnl, + oracle v3 + FundingEngine v2 + LiqEngine v3)
        PositionManager newPm = new PositionManager(
            DEPLOYER,
            SHARIAH_GUARD,
            address(newFunding),
            address(newOracle),
            COLLATERAL_VAULT,
            address(newLiqEngine),
            INSURANCE_FUND
        );
        newPm.setBrkxToken(BRKX_TOKEN);
        newPm.setTreasury(TREASURY);
        console.log("3b. PositionManager v4 :", address(newPm));

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 4 — PRODUCT STACK (depend on oracle + EverlastingOption)
        // ══════════════════════════════════════════════════════════════════════

        // 4a. EverlastingOption v2 (oracle changed)
        EverlastingOption newEvOption = new EverlastingOption(DEPLOYER, address(newOracle));
        newEvOption.setMarket(BTC_ASSET, SIGMA2, KAPPA, false);
        console.log("4a. EverlastingOption v2:", address(newEvOption));

        // 4b. TakafulPool v2 (oracle changed)
        TakafulPool newTakaful = new TakafulPool(
            DEPLOYER,
            address(newEvOption),
            address(newOracle),
            DEPLOYER   // operator = deployer (testnet)
        );
        newTakaful.setKeeper(DEPLOYER, true);
        bytes32 poolId = keccak256("BTC-40k-USDC");
        newTakaful.createPool(poolId, BTC_ASSET, USDC, FLOOR_WAD);
        console.log("4b. TakafulPool v2     :", address(newTakaful));

        // 4c. PerpetualSukuk v2 (oracle changed)
        PerpetualSukuk newSukuk = new PerpetualSukuk(
            DEPLOYER,
            address(newEvOption),
            address(newOracle)
        );
        console.log("4c. PerpetualSukuk v2  :", address(newSukuk));

        // 4d. iCDS v2 (H-6: lastPremiumAt += PREMIUM_PERIOD; oracle changed)
        iCDS newCds = new iCDS(
            DEPLOYER,
            address(newEvOption),
            address(newOracle)
        );
        newCds.setKeeper(DEPLOYER, true);
        console.log("4d. iCDS v2            :", address(newCds));

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 5 — REWIRE EXISTING CONTRACTS
        // ══════════════════════════════════════════════════════════════════════

        // CollateralVault: authorise new PM v4 + new LiqEngine v3
        CollateralVault vault = CollateralVault(COLLATERAL_VAULT);
        vault.setAuthorised(address(newPm),        true);
        vault.setAuthorised(address(newLiqEngine), true);
        console.log("5a. CollateralVault: PM v4 + LiqEngine v3 authorised");

        // InsuranceFund: authorise new PM v4
        InsuranceFund(INSURANCE_FUND).setAuthorised(address(newPm), true);
        console.log("5b. InsuranceFund: PM v4 authorised");

        // LiquidationEngine v3: point to new PM v4
        newLiqEngine.setPositionManager(address(newPm));
        console.log("5c. LiquidationEngine v3: PM v4 set");

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 6 — SMOKE TEST (open position, verify fee split, check kappa)
        // ══════════════════════════════════════════════════════════════════════

        // Step 1: Deploy testnet collateral token
        MockERC20 usdc = new MockERC20("Test USDC", "tUSDC", 6);
        console.log("Smoke 1: MockERC20 (tUSDC):", address(usdc));

        // Step 2: Approve tUSDC in ShariahGuard
        ShariahGuard(SHARIAH_GUARD).approveAsset(address(usdc), FATWA_HASH);
        console.log("Smoke 2: ShariahGuard: tUSDC approved");

        // Step 3: Mint tUSDC to trader (collateral + fees)
        uint256 mintAmount = COLLATERAL + OPEN_FEE + 1_000;
        usdc.mint(trader, mintAmount);
        console.log("Smoke 3: Minted", mintAmount / 1e6, "tUSDC to trader");

        // Step 4: Deposit into vault
        usdc.approve(address(vault), mintAmount);
        vault.deposit(address(usdc), mintAmount);
        console.log("Smoke 4: Deposited into CollateralVault");

        // Step 5: Snapshot oracle (now onlyOwner — deployer is owner, passes)
        uint256 btcPrice = newOracle.snapshotPrice(BTC_MARKET);
        console.log("Smoke 5: BTC price snapshotted:", btcPrice / 1e18, "USD");

        // Step 6: Verify BRKX tier
        require(
            BRKXToken(BRKX_TOKEN).balanceOf(trader) >= 50_000e18,
            "AuditFixRedeploy: need >=50k BRKX for tier3"
        );
        console.log("Smoke 6: tier3 confirmed (>=50k BRKX = 2.5 bps)");

        // Step 7: Read balances before open
        uint256 ifBefore = usdc.balanceOf(INSURANCE_FUND);
        uint256 trBefore = usdc.balanceOf(TREASURY);

        // Step 8: Open 3x long position
        bytes32 posId = newPm.openPosition(BTC_MARKET, address(usdc), COLLATERAL, LEVERAGE, true);
        console.log("Smoke 8: Position opened, posId:", uint256(posId));

        // Step 9: Verify open fee split (50% IF / 50% Treasury)
        uint256 halfFee = OPEN_FEE / 2;
        uint256 remFee  = OPEN_FEE - halfFee;
        require(usdc.balanceOf(INSURANCE_FUND) - ifBefore == halfFee, "fee split IF wrong");
        require(usdc.balanceOf(TREASURY)        - trBefore == remFee,  "fee split TR wrong");
        console.log("Smoke 9: fee split VERIFIED (feeBps=25, 2.5 bps, tier3)");

        // Step 10: Verify kappa signal
        (, , uint8 regime) = newOracle.getKappaSignal(BTC_MARKET);
        require(regime <= 3, "kappa regime out of range");
        console.log("Smoke 10: kappa regime:", regime, "(0=NORMAL)");

        vm.stopBroadcast();

        // ══════════════════════════════════════════════════════════════════════
        // FINAL SUMMARY — update deployments/421614.json with these
        // ══════════════════════════════════════════════════════════════════════
        console.log("\n==========================================================");
        console.log("  ALL CHECKS PASSED - AUDIT FIX REDEPLOY COMPLETE");
        console.log("==========================================================");
        console.log("Core contracts:");
        console.log("  OracleAdapter v3    :", address(newOracle));
        console.log("  FundingEngine v2    :", address(newFunding));
        console.log("  LiquidationEngine v3:", address(newLiqEngine));
        console.log("  PositionManager v4  :", address(newPm));
        console.log("  GovernanceModule v2 :", address(newGov));
        console.log("Unchanged:");
        console.log("  ShariahGuard        :", SHARIAH_GUARD);
        console.log("  InsuranceFund       :", INSURANCE_FUND);
        console.log("  CollateralVault     :", COLLATERAL_VAULT);
        console.log("  BRKXToken           :", BRKX_TOKEN);
        console.log("Product stack:");
        console.log("  EverlastingOption v2:", address(newEvOption));
        console.log("  TakafulPool v2      :", address(newTakaful));
        console.log("  PerpetualSukuk v2   :", address(newSukuk));
        console.log("  iCDS v2             :", address(newCds));
        console.log("----------------------------------------------------------");
        console.log("Smoke test:");
        console.log("  BTC price           :", btcPrice / 1e18, "USD");
        console.log("  open fee (tier3)    :", OPEN_FEE, "tUSDC-wei (feeBps=25)");
        console.log("  IF received         :", halfFee, "tUSDC-wei");
        console.log("  Treasury received   :", remFee, "tUSDC-wei");
        console.log("  kappa regime        :", regime);
        console.log("----------------------------------------------------------");
        console.log("NEXT: Update deployments/421614.json, verify on Arbiscan");
        console.log("==========================================================");
    }
}
