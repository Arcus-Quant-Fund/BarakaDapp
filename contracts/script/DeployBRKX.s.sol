// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/token/BRKXToken.sol";
import "../src/core/PositionManager.sol";
import "../src/shariah/GovernanceModule.sol";

/**
 * @title DeployBRKX
 * @notice Deploys the BRKX token and wires it into the existing Baraka Protocol.
 *
 * Prerequisites:
 *   - All 8 core contracts already deployed (see Deploy.s.sol + deployments/421614.json).
 *   - DEPLOYER_PRIVATE_KEY set in environment.
 *
 * Steps:
 *   1. Deploy BRKXToken (100M minted to DEPLOYER / treasury).
 *   2. Enable fee collection: pm.setBrkxToken(brkxToken).
 *   3. Set treasury:          pm.setTreasury(DEPLOYER).
 *   4. Wire DAO voting:       governance.setGovernanceToken(brkxToken).
 *
 * Usage:
 *   forge script script/DeployBRKX.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployBRKX is Script {

    // ── Deployer (testnet: also Shariah board + treasury) ─────────────────────
    address constant DEPLOYER = 0x12A21D0D172265A520aF286F856B5aF628e66D46;

    // ── Existing deployed contracts (Arbitrum Sepolia 421614) ────────────────
    PositionManager  constant pm         = PositionManager (0x53E3063FE2194c2DAe30C36420A01A8573B150bC);
    GovernanceModule constant governance = GovernanceModule(0x8c987818dffcD00c000Fe161BFbbD414B0529341);

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        // ── 1. Deploy BRKXToken — 100M minted to deployer as treasury ─────────
        BRKXToken brkx = new BRKXToken(DEPLOYER);
        console.log("BRKXToken         :", address(brkx));
        console.log("BRKX total supply :", brkx.totalSupply());

        // ── 2. Enable trading fees in PositionManager ─────────────────────────
        pm.setBrkxToken(address(brkx));
        console.log("PositionManager   : brkxToken set ->", address(brkx));

        // ── 3. Set treasury (deployer for testnet; replace with multisig on mainnet) ──
        pm.setTreasury(DEPLOYER);
        console.log("PositionManager   : treasury set  ->", DEPLOYER);

        // ── 4. Wire BRKX to GovernanceModule DAO voting ───────────────────────
        // GovernanceModule.setGovernanceToken is onlyShariahMultisig.
        // On testnet DEPLOYER == shariahMultisig, so this works directly.
        // On mainnet this must be a separate multisig transaction.
        governance.setGovernanceToken(address(brkx));
        console.log("GovernanceModule  : governanceToken set ->", address(brkx));

        vm.stopBroadcast();

        // ─────────────────────────────────────────────────────────────────────
        // DEPLOYMENT SUMMARY
        // ─────────────────────────────────────────────────────────────────────
        console.log("\n======================================================");
        console.log("BARAKA PROTOCOL - BRKX TOKEN DEPLOYED");
        console.log("======================================================");
        console.log("Network          : Arbitrum Sepolia (421614)");
        console.log("Deployer/Treasury:", DEPLOYER);
        console.log("------------------------------------------------------");
        console.log("BRKXToken        :", address(brkx));
        console.log("Max Supply       : 100,000,000 BRKX");
        console.log("------------------------------------------------------");
        console.log("Fee tiers (hold-based, no lock-up):");
        console.log("  < 1,000  BRKX held  ->  5.0 bps per open/close");
        console.log("  >= 1,000 BRKX held  ->  4.0 bps  (-20%)");
        console.log("  >= 10,000 BRKX held ->  3.5 bps  (-30%)");
        console.log("  >= 50,000 BRKX held ->  2.5 bps  (-50%)");
        console.log("Revenue: 50% InsuranceFund / 50% Treasury");
        console.log("======================================================");
        console.log("NEXT STEPS:");
        console.log("  1. Verify on Arbiscan: BRKX.totalSupply() == 100_000_000e18");
        console.log("  2. Verify: pm.brkxToken() == BRKXToken address above");
        console.log("  3. Transfer some BRKX to wallets for fee tier testing");
        console.log("  4. Open position and confirm FeeCollected event emitted");
        console.log("  5. Add BRKX address to deployments/421614.json");
        console.log("======================================================");
    }
}
