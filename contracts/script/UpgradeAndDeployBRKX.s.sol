// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/core/PositionManager.sol";
import "../src/core/CollateralVault.sol";
import "../src/core/LiquidationEngine.sol";
import "../src/insurance/InsuranceFund.sol";
import "../src/token/BRKXToken.sol";
import "../src/shariah/GovernanceModule.sol";

/**
 * @title UpgradeAndDeployBRKX
 * @notice Redeploys PositionManager with the new 7-arg constructor
 *         (added _insuranceFund, setBrkxToken, setTreasury, chargeFromFree),
 *         re-wires all dependencies, then deploys BRKXToken and enables fees.
 *
 * Existing contracts that are NOT redeployed (same addresses):
 *   OracleAdapter, ShariahGuard, FundingEngine, InsuranceFund,
 *   CollateralVault, LiquidationEngine, GovernanceModule
 *
 * Steps:
 *   1. Deploy new PositionManager (7 args).
 *   2. Revoke old PM from vault + insurance authorisations.
 *   3. Authorise new PM in CollateralVault + InsuranceFund.
 *   4. Re-point LiquidationEngine to new PM.
 *   5. Deploy BRKXToken (100M to deployer/treasury).
 *   6. Wire BRKX: pm.setBrkxToken + pm.setTreasury.
 *   7. Wire governance: governance.setGovernanceToken(brkx).
 *
 * Usage:
 *   forge script script/UpgradeAndDeployBRKX.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract UpgradeAndDeployBRKX is Script {

    // ── Deployer ──────────────────────────────────────────────────────────────
    address constant DEPLOYER         = 0x12A21D0D172265A520aF286F856B5aF628e66D46;
    address constant SHARIAH_MULTISIG = 0x12A21D0D172265A520aF286F856B5aF628e66D46;

    // ── Existing deployed contracts (all unchanged) ───────────────────────────
    address constant OLD_PM           = 0x53E3063FE2194c2DAe30C36420A01A8573B150bC;
    address constant SHARIAH_GUARD    = 0x26d4db76a95DBf945ac14127a23Cd4861DA42e69;
    address constant FUNDING_ENGINE   = 0x459BE882BC8736e92AA4589D1b143e775b114b38;
    address constant ORACLE_ADAPTER   = 0xB8d9778288B96ee5a9d873F222923C0671fc38D4;
    address constant VAULT_ADDR       = 0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E;
    address constant LIQ_ENGINE       = 0x456eBE7BbCb099E75986307E4105A652c108b608;
    address constant INSURANCE_FUND   = 0x7B440af63D5fa5592E53310ce914A21513C1a716;
    address constant GOVERNANCE       = 0x8c987818dffcD00c000Fe161BFbbD414B0529341;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        // ── 1. Deploy new PositionManager ─────────────────────────────────────
        PositionManager newPm = new PositionManager(
            DEPLOYER,
            SHARIAH_GUARD,
            FUNDING_ENGINE,
            ORACLE_ADAPTER,
            VAULT_ADDR,
            LIQ_ENGINE,
            INSURANCE_FUND
        );
        console.log("New PositionManager:", address(newPm));

        // ── 2. Revoke old PositionManager from vault (clean up) ───────────────
        CollateralVault vault = CollateralVault(VAULT_ADDR);
        vault.setAuthorised(OLD_PM, false);
        console.log("CollateralVault: old PM deauthorised");

        // ── 3. Authorise new PM in CollateralVault ────────────────────────────
        vault.setAuthorised(address(newPm), true);
        console.log("CollateralVault: new PM authorised");

        // ── 4. Authorise new PM in InsuranceFund (needed for fee split) ───────
        InsuranceFund insurance = InsuranceFund(INSURANCE_FUND);
        insurance.setAuthorised(address(newPm), true);
        console.log("InsuranceFund: new PM authorised");

        // ── 5. Re-point LiquidationEngine to new PositionManager ─────────────
        LiquidationEngine liqEngine = LiquidationEngine(LIQ_ENGINE);
        liqEngine.setPositionManager(address(newPm));
        console.log("LiquidationEngine: PositionManager updated to new PM");

        // ── 6. Deploy BRKXToken ───────────────────────────────────────────────
        BRKXToken brkx = new BRKXToken(DEPLOYER);
        console.log("BRKXToken         :", address(brkx));

        // ── 7. Enable trading fees on new PositionManager ─────────────────────
        newPm.setBrkxToken(address(brkx));
        console.log("PositionManager: brkxToken set ->", address(brkx));

        newPm.setTreasury(DEPLOYER);
        console.log("PositionManager: treasury set  ->", DEPLOYER);

        // ── 8. Wire BRKX to GovernanceModule ─────────────────────────────────
        GovernanceModule(GOVERNANCE).setGovernanceToken(address(brkx));
        console.log("GovernanceModule: governanceToken set ->", address(brkx));

        vm.stopBroadcast();

        // ── DEPLOYMENT SUMMARY ────────────────────────────────────────────────
        console.log("\n======================================================");
        console.log("BARAKA PROTOCOL - PM + BRKX UPGRADE COMPLETE");
        console.log("======================================================");
        console.log("Network           : Arbitrum Sepolia (421614)");
        console.log("Deployer/Treasury :", DEPLOYER);
        console.log("------------------------------------------------------");
        console.log("New PositionManager:", address(newPm));
        console.log("BRKXToken          :", address(brkx));
        console.log("Max Supply         : 100,000,000 BRKX");
        console.log("------------------------------------------------------");
        console.log("UNCHANGED contracts:");
        console.log("  OracleAdapter   :", ORACLE_ADAPTER);
        console.log("  ShariahGuard    :", SHARIAH_GUARD);
        console.log("  FundingEngine   :", FUNDING_ENGINE);
        console.log("  InsuranceFund   :", INSURANCE_FUND);
        console.log("  CollateralVault :", VAULT_ADDR);
        console.log("  LiquidationEngine:", LIQ_ENGINE);
        console.log("  GovernanceModule:", GOVERNANCE);
        console.log("------------------------------------------------------");
        console.log("Fee tiers (hold-based, no lock-up):");
        console.log("  < 1,000  BRKX  ->  5.0 bps per open/close");
        console.log("  >= 1,000 BRKX  ->  4.0 bps  (-20%)");
        console.log("  >= 10,000 BRKX ->  3.5 bps  (-30%)");
        console.log("  >= 50,000 BRKX ->  2.5 bps  (-50%)");
        console.log("  Revenue: 50% InsuranceFund / 50% Treasury");
        console.log("======================================================");
        console.log("NEXT STEPS:");
        console.log("  1. Update deployments/421614.json with new PM + BRKX addresses");
        console.log("  2. Update frontend env with new PositionManager address");
        console.log("  3. Verify on Arbiscan: pm.brkxToken() returns BRKX address");
        console.log("  4. Distribute BRKX to test wallets for tier testing");
        console.log("======================================================");
    }
}
