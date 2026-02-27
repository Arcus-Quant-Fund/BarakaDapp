// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/oracle/OracleAdapter.sol";
import "../src/shariah/ShariahGuard.sol";
import "../src/core/FundingEngine.sol";
import "../src/insurance/InsuranceFund.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/LiquidationEngine.sol";
import "../src/core/PositionManager.sol";
import "../src/shariah/GovernanceModule.sol";

/**
 * @title Deploy
 * @notice Deploys all 8 Baraka Protocol contracts to Arbitrum Sepolia in
 *         correct dependency order and wires all post-deploy configuration.
 *
 * Deployment order (each contract depends on those above it):
 *   1. OracleAdapter       — no deps
 *   2. ShariahGuard        — no deps
 *   3. FundingEngine       — needs OracleAdapter
 *   4. InsuranceFund       — no deps
 *   5. CollateralVault     — needs ShariahGuard
 *   6. LiquidationEngine   — needs InsuranceFund + CollateralVault
 *   7. PositionManager     — needs all of the above
 *   8. GovernanceModule    — needs ShariahGuard multisig address
 *
 * Post-deploy wiring:
 *   - OracleAdapter.setOracle(BTC_MARKET, feed1, feed2)
 *   - InsuranceFund.setAuthorised(LiquidationEngine, true)
 *   - CollateralVault.setAuthorised(PositionManager, true)
 *   - CollateralVault.setAuthorised(LiquidationEngine, true)
 *   - LiquidationEngine.setPositionManager(PositionManager)
 *   - ShariahGuard.approveAsset(BTC_MARKET, ipfsHash)
 *
 * Usage:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract Deploy is Script {

    // ─── Deployer & Shariah Board ──────────────────────────────────────────────
    // For testnet: deployer acts as both owner and shariah multisig.
    // For mainnet: SHARIAH_MULTISIG must be a real 3-of-5 multisig (Safe).
    address constant DEPLOYER         = 0x12A21D0D172265A520aF286F856B5aF628e66D46;
    address constant SHARIAH_MULTISIG = 0x12A21D0D172265A520aF286F856B5aF628e66D46; // TESTNET ONLY

    // ─── Chainlink Feed Addresses (Arbitrum Sepolia) ───────────────────────────
    // BTC/USD  — two feeds weighted 60/40 in OracleAdapter
    // These are mock/placeholder feed addresses on Arbitrum Sepolia.
    // Replace with real Chainlink testnet feeds when available.
    // Arbitrum Sepolia Chainlink feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=arbitrum&page=1#arbitrum-sepolia
    address constant CHAINLINK_BTC_USD_PRIMARY   = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69; // BTC/USD Arb Sepolia
    address constant CHAINLINK_BTC_USD_SECONDARY = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69; // same for now (use primary as fallback)

    // ─── Market Identifier ────────────────────────────────────────────────────
    // On testnet we use a deterministic address as the BTC market ID.
    // On mainnet this would be the actual BTC token address or a market registry entry.
    address constant BTC_MARKET = address(0x00B1C);

    // ─── Governance Token ─────────────────────────────────────────────────────
    // address(0) = no governance token in MVP (DAO track disabled at launch)
    address constant GOVERNANCE_TOKEN = address(0);

    // ─── Fatwa IPFS Hash (placeholder) ────────────────────────────────────────
    // Replace with real IPFS hash once fatwa document is uploaded to Pinata.
    string constant FATWA_IPFS_HASH = "QmPlaceholderFatwaHashReplaceBeforeMainnet";

    // ─── Deployed Addresses (populated during run()) ──────────────────────────
    OracleAdapter     public oracle;
    ShariahGuard      public shariahGuard;
    FundingEngine     public fundingEngine;
    InsuranceFund     public insuranceFund;
    CollateralVault   public vault;
    LiquidationEngine public liqEngine;
    PositionManager   public pm;
    GovernanceModule  public governance;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        // ── 1. OracleAdapter ──────────────────────────────────────────────────
        oracle = new OracleAdapter(DEPLOYER);
        console.log("OracleAdapter     :", address(oracle));

        // ── 2. ShariahGuard ───────────────────────────────────────────────────
        shariahGuard = new ShariahGuard(SHARIAH_MULTISIG);
        console.log("ShariahGuard      :", address(shariahGuard));

        // ── 3. FundingEngine ──────────────────────────────────────────────────
        fundingEngine = new FundingEngine(DEPLOYER, address(oracle));
        console.log("FundingEngine     :", address(fundingEngine));

        // ── 4. InsuranceFund ──────────────────────────────────────────────────
        insuranceFund = new InsuranceFund(DEPLOYER);
        console.log("InsuranceFund     :", address(insuranceFund));

        // ── 5. CollateralVault ────────────────────────────────────────────────
        vault = new CollateralVault(DEPLOYER, address(shariahGuard));
        console.log("CollateralVault   :", address(vault));

        // ── 6. LiquidationEngine ──────────────────────────────────────────────
        liqEngine = new LiquidationEngine(
            DEPLOYER,
            address(insuranceFund),
            address(vault)
        );
        console.log("LiquidationEngine :", address(liqEngine));

        // ── 7. PositionManager ────────────────────────────────────────────────
        pm = new PositionManager(
            DEPLOYER,
            address(shariahGuard),
            address(fundingEngine),
            address(oracle),
            address(vault),
            address(liqEngine),
            address(insuranceFund)
        );
        console.log("PositionManager   :", address(pm));

        // ── 8. GovernanceModule ───────────────────────────────────────────────
        governance = new GovernanceModule(SHARIAH_MULTISIG, GOVERNANCE_TOKEN);
        console.log("GovernanceModule  :", address(governance));

        // ─────────────────────────────────────────────────────────────────────
        // POST-DEPLOY WIRING
        // ─────────────────────────────────────────────────────────────────────

        // Wire oracle: register BTC/USD price feeds (60% primary / 40% secondary)
        oracle.setOracle(BTC_MARKET, CHAINLINK_BTC_USD_PRIMARY, CHAINLINK_BTC_USD_SECONDARY);
        console.log("Oracle feeds set for BTC_MARKET");

        // Authorise LiquidationEngine to call InsuranceFund.receiveFromLiquidation
        insuranceFund.setAuthorised(address(liqEngine), true);
        console.log("InsuranceFund: authorised LiquidationEngine");

        // Authorise PositionManager + LiquidationEngine to call CollateralVault
        vault.setAuthorised(address(pm),        true);
        vault.setAuthorised(address(liqEngine), true);
        console.log("CollateralVault: authorised PM + LiquidationEngine");

        // Wire LiquidationEngine → PositionManager (for snapshot checks)
        liqEngine.setPositionManager(address(pm));
        console.log("LiquidationEngine: PositionManager set");

        // Shariah board approves BTC/USD as a tradeable market
        // NOTE: ShariahGuard.approveAsset can only be called by the shariah multisig.
        // On testnet SHARIAH_MULTISIG == DEPLOYER so this works directly.
        // On mainnet this must be a separate multisig transaction.
        shariahGuard.approveAsset(BTC_MARKET, FATWA_IPFS_HASH);
        console.log("ShariahGuard: BTC_MARKET approved with fatwa hash");

        vm.stopBroadcast();

        // ─────────────────────────────────────────────────────────────────────
        // DEPLOYMENT SUMMARY
        // ─────────────────────────────────────────────────────────────────────
        console.log("\n======================================================");
        console.log("BARAKA PROTOCOL - DEPLOYMENT COMPLETE");
        console.log("======================================================");
        console.log("Network          : Arbitrum Sepolia (421614)");
        console.log("Deployer         :", DEPLOYER);
        console.log("------------------------------------------------------");
        console.log("OracleAdapter    :", address(oracle));
        console.log("ShariahGuard     :", address(shariahGuard));
        console.log("FundingEngine    :", address(fundingEngine));
        console.log("InsuranceFund    :", address(insuranceFund));
        console.log("CollateralVault  :", address(vault));
        console.log("LiquidationEngine:", address(liqEngine));
        console.log("PositionManager  :", address(pm));
        console.log("GovernanceModule :", address(governance));
        console.log("======================================================");
        console.log("Save these addresses to deployments/421614.json");
        console.log("======================================================");
    }
}
