// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/shariah/ShariahGuard.sol";

/**
 * @title UpdateFatwa
 * @notice Updates the on-chain fatwa IPFS hash for approved assets in ShariahGuard.
 *
 * Run AFTER uploading the fatwa document with scripts/upload_fatwa.sh.
 * The script reads FATWA_CID from the environment (or from ../.fatwa_cid).
 *
 * Usage:
 *   # Option A — env var:
 *   FATWA_CID=QmABC... forge script contracts/script/UpdateFatwa.s.sol \
 *     --rpc-url arbitrum_sepolia --broadcast -vvv
 *
 *   # Option B — run upload_fatwa.sh first (writes .fatwa_cid), then:
 *   forge script contracts/script/UpdateFatwa.s.sol \
 *     --rpc-url arbitrum_sepolia --broadcast -vvv
 *
 * Note: Must be signed by DEPLOYER_PRIVATE_KEY (shariahMultisig on testnet).
 */
contract UpdateFatwa is Script {

    // ── Live addresses (Arbitrum Sepolia 421614) ──────────────────────────────
    address constant SHARIAH_GUARD = 0x26d4db76a95DBf945ac14127a23Cd4861DA42e69;
    address constant BTC_MARKET    = address(0x00B1C);

    // USDC and PAXG addresses for mainnet — add here when ready
    // address constant USDC  = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8; // Arb One
    // address constant PAXG  = 0xfEb4DfC8C4Cf7Ed305bb08065D08eC6ee6728429; // Arb One

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // ── Resolve CID ───────────────────────────────────────────────────────
        // Priority: FATWA_CID env var → ../.fatwa_cid file
        string memory cid;
        try vm.envString("FATWA_CID") returns (string memory envCid) {
            cid = envCid;
        } catch {
            // Read from .fatwa_cid written by upload_fatwa.sh
            string memory cidPath = string.concat(vm.projectRoot(), "/../.fatwa_cid");
            try vm.readFile(cidPath) returns (string memory fileCid) {
                // Trim any trailing newline
                bytes memory raw = bytes(fileCid);
                uint256 len = raw.length;
                while (len > 0 && (raw[len - 1] == 0x0A || raw[len - 1] == 0x0D)) {
                    len--;
                }
                bytes memory trimmed = new bytes(len);
                for (uint256 i = 0; i < len; i++) trimmed[i] = raw[i];
                cid = string(trimmed);
            } catch {
                revert("UpdateFatwa: set FATWA_CID env var or run upload_fatwa.sh first");
            }
        }

        require(bytes(cid).length > 0, "UpdateFatwa: empty CID");
        console.log("Fatwa CID:", cid);

        ShariahGuard guard = ShariahGuard(SHARIAH_GUARD);

        vm.startBroadcast(deployerPk);

        // ── Update BTC_MARKET fatwa hash ──────────────────────────────────────
        // approveAsset() acts as both initial approval and update — it overwrites
        // fatwaIPFS[token] and re-emits AssetApproved event.
        guard.approveAsset(BTC_MARKET, cid);
        console.log("BTC_MARKET fatwa updated:");
        console.log("  ShariahGuard :", SHARIAH_GUARD);
        console.log("  Asset        : BTC_MARKET (0x00B1C)");
        console.log("  IPFS hash    :", cid);
        console.log("  Gateway      : https://gateway.pinata.cloud/ipfs/", cid);

        vm.stopBroadcast();

        console.log("");
        console.log("Done. Verify on Arbiscan:");
        console.log("  https://sepolia.arbiscan.io/address/", SHARIAH_GUARD, "#readContract");
        console.log("  -> fatwaIPFS(0x0000000000000000000000000000000000000b1c)");
    }
}
