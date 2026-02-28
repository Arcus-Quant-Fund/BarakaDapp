// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../src/shariah/ShariahGuard.sol";

/**
 * @title SetFatwaURI
 * @notice Records the Shariah fatwa IPFS hash on-chain for approved collateral tokens.
 *
 * Prerequisites:
 *   - DEPLOYER_PRIVATE_KEY set in environment (deployer == shariahMultisig on testnet).
 *   - FATWA_CID set in environment (e.g. "QmVztQvWd5QkD5euhiUb2ycwr2SHL928Y2AC9rnWCMn7c2").
 *
 * Usage:
 *   FATWA_CID="QmXyz..." forge script script/SetFatwaURI.s.sol \
 *     --rpc-url arbitrum_sepolia \
 *     --broadcast \
 *     -vvvv
 */
contract SetFatwaURI is Script {

    // ── ShariahGuard on Arbitrum Sepolia (421614) ─────────────────────────────
    ShariahGuard constant sg = ShariahGuard(0x26d4db76a95DBf945ac14127a23Cd4861DA42e69);

    // ── Arbitrum Sepolia testnet USDC (Aave faucet token) ────────────────────
    address constant USDC_SEPOLIA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory cid  = vm.envString("FATWA_CID");

        vm.startBroadcast(deployerPk);

        // Register fatwa IPFS hash for USDC collateral
        sg.approveAsset(USDC_SEPOLIA, cid);
        console.log("ShariahGuard.approveAsset() called:");
        console.log("  token   :", USDC_SEPOLIA);
        console.log("  ipfsHash:", cid);

        vm.stopBroadcast();

        console.log("\n======================================================");
        console.log("BARAKA PROTOCOL - FATWA IPFS REGISTERED");
        console.log("======================================================");
        console.log("ShariahGuard :", address(sg));
        console.log("Token (USDC) :", USDC_SEPOLIA);
        console.log("Fatwa CID    :", cid);
        console.log("Gateway      :");
        console.log("  https://gateway.pinata.cloud/ipfs/", cid);
        console.log("Verify on-chain:");
        console.log("  cast call", address(sg),
            "\"fatwaIPFS(address)(string)\"", USDC_SEPOLIA,
            "--rpc-url arbitrum_sepolia");
        console.log("======================================================");
    }
}
