// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/core/EverlastingOption.sol";
import "../src/takaful/TakafulPool.sol";
import "../src/credit/PerpetualSukuk.sol";
import "../src/credit/iCDS.sol";

/**
 * @title DeployProductStack
 * @notice Deploys the Baraka Protocol Layer 2/3/4 product stack:
 *         EverlastingOption (pricing engine) + TakafulPool + PerpetualSukuk + iCDS.
 *
 * Prerequisites:
 *   - Core 8 contracts already deployed (Deploy.s.sol).
 *   - BRKXToken already deployed (DeployBRKX.s.sol).
 *   - DEPLOYER_PRIVATE_KEY set in environment.
 *
 * Deployment order (by dependency):
 *   1. EverlastingOption  — depends only on OracleAdapter (already live)
 *   2. TakafulPool        — depends on EverlastingOption + OracleAdapter
 *   3. PerpetualSukuk     — depends on EverlastingOption + OracleAdapter
 *   4. iCDS               — depends on EverlastingOption + OracleAdapter
 *
 * Post-deploy:
 *   - setMarket() called on EverlastingOption for BTC_ASSET
 *   - First TakafulPool (BTC-40k-USDC) created with $40k floor
 *   - Deployer set as keeper for TakafulPool + iCDS (testnet)
 *
 * Usage:
 *   forge script script/DeployProductStack.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     --verify \
 *     -vvvv
 */
contract DeployProductStack is Script {

    // ── Deployer (testnet: also operator + keeper) ────────────────────────────
    address constant DEPLOYER  = 0x12A21D0D172265A520aF286F856B5aF628e66D46;

    // ── Existing deployed contracts (Arbitrum Sepolia 421614) ────────────────
    address constant ORACLE    = 0x86C475d9943ABC61870C6F19A7e743B134e1b563; // OracleAdapter v2

    // ── Market parameters ─────────────────────────────────────────────────────
    // BTC market key — WBTC address used consistently throughout protocol
    address constant BTC_ASSET = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f;

    // Arbitrum Sepolia USDC (payment token for first Takaful pool)
    address constant USDC      = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    // ── EverlastingOption market config ───────────────────────────────────────
    // σ² = (80% annual vol)² = 0.64 in WAD
    uint256 constant SIGMA2    = 64e16;   // 0.64 * 1e18

    // κ = 8.3%/year — empirical from integrated simulation (5 episodes, 720 steps)
    // useOracleKappa = false on testnet (oracle kappa signal not yet calibrated)
    uint256 constant KAPPA     = 83e15;   // 0.083 * 1e18

    // ── TakafulPool first pool config ─────────────────────────────────────────
    // Floor: $40k — BTC protection below this level triggers tabarru pricing
    uint256 constant FLOOR_WAD = 40_000e18;

    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPk);

        // ── 1. Deploy EverlastingOption (Layer 1.5 pricing engine) ────────────
        EverlastingOption evOption = new EverlastingOption(DEPLOYER, ORACLE);
        // Configure BTC market: σ²=0.64, κ=8.3%/year, admin κ (not oracle)
        evOption.setMarket(BTC_ASSET, SIGMA2, KAPPA, false);
        console.log("EverlastingOption :", address(evOption));
        console.log("  BTC market set: sigma2=0.64, kappa=0.083, useOracleKappa=false");

        // ── 2. Deploy TakafulPool (Layer 3 — mutual Islamic insurance) ────────
        // operator = deployer on testnet (receives 10% wakala fee)
        TakafulPool takaful = new TakafulPool(
            DEPLOYER,            // owner
            address(evOption),   // everlasting option pricer
            ORACLE,              // oracle
            DEPLOYER             // operator (wakala agent, testnet = deployer)
        );
        takaful.setKeeper(DEPLOYER, true);

        // Create first Takaful pool: BTC protection with $40k floor, USDC token
        bytes32 poolId = keccak256("BTC-40k-USDC");
        takaful.createPool(poolId, BTC_ASSET, USDC, FLOOR_WAD);
        console.log("TakafulPool       :", address(takaful));
        console.log("  Pool BTC-40k-USDC created, floor=40000, keeper=DEPLOYER");

        // ── 3. Deploy PerpetualSukuk (Layer 2 — Islamic capital markets) ──────
        PerpetualSukuk sukuk = new PerpetualSukuk(
            DEPLOYER,           // owner
            address(evOption),  // everlasting option pricer
            ORACLE              // oracle
        );
        console.log("PerpetualSukuk    :", address(sukuk));

        // ── 4. Deploy iCDS (Layer 4 — Islamic Credit Default Swap) ───────────
        iCDS cds = new iCDS(
            DEPLOYER,           // owner
            address(evOption),  // everlasting option pricer
            ORACLE              // oracle
        );
        cds.setKeeper(DEPLOYER, true);
        console.log("iCDS              :", address(cds));
        console.log("  Keeper set: DEPLOYER");

        vm.stopBroadcast();

        // ─────────────────────────────────────────────────────────────────────
        // DEPLOYMENT SUMMARY
        // ─────────────────────────────────────────────────────────────────────
        console.log("\n======================================================");
        console.log("BARAKA PROTOCOL - PRODUCT STACK DEPLOYED");
        console.log("======================================================");
        console.log("Network          : Arbitrum Sepolia (421614)");
        console.log("Deployer         :", DEPLOYER);
        console.log("------------------------------------------------------");
        console.log("[L1.5] EverlastingOption :", address(evOption));
        console.log("       sigma2=0.64, kappa=0.083, BTC market active");
        console.log("[L2]   PerpetualSukuk    :", address(sukuk));
        console.log("       Ijarah-style sukuk with embedded everlasting call");
        console.log("[L3]   TakafulPool       :", address(takaful));
        console.log("       Pool: BTC-40k-USDC | floor=$40k | keeper=DEPLOYER");
        console.log("[L4]   iCDS              :", address(cds));
        console.log("       Quarterly put-priced premiums | keeper=DEPLOYER");
        console.log("------------------------------------------------------");
        console.log("NEXT STEPS:");
        console.log("  1. Update contracts/deployments/421614.json with above addresses");
        console.log("  2. Update frontend/lib/contracts.ts with addresses + ABIs");
        console.log("  3. Verify EverlastingOption.markets(BTC_ASSET).active == true");
        console.log("  4. Verify TakafulPool.pools(keccak256('BTC-40k-USDC')).active == true");
        console.log("  5. npm run build && vercel deploy --prod");
        console.log("======================================================");
    }
}
