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
import "../src/token/BRKXToken.sol";

/// @dev Minimal interface for staleness pre-flight check
interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256 updatedAt, uint80);
    function decimals() external view returns (uint8);
}

/**
 * @title DeployMainnet
 * @author Baraka Protocol
 * @notice Full production deployment for Arbitrum One (chainId 42161).
 *
 * Prerequisites (set in shell before running):
 *   export DEPLOYER_PRIVATE_KEY=<hex>
 *   export SHARIAH_MULTISIG=<safe-address>   # 3-of-5 Safe — must differ from deployer
 *   export TREASURY=<treasury-address>        # Fee revenue destination
 *   export FATWA_CID=<ipfs-hash>             # Pinned fatwa PDF on Pinata
 *
 * Usage:
 *   forge script script/DeployMainnet.s.sol \
 *     --rpc-url arbitrum_one \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ARBISCAN_API_KEY \
 *     -vvvv
 *
 * After success:
 *   1. Copy printed addresses to deployments/42161.json
 *   2. Have Shariah board call ShariahGuard.approveAsset() for each collateral + market
 *   3. Frontend: update CONTRACTS object in frontend/lib/contracts.ts
 *
 * ── Deployment Order ──────────────────────────────────────────────────────────
 *   1. OracleAdapter       — no deps
 *   2. ShariahGuard        — owner = SHARIAH_MULTISIG (Shariah board Safe)
 *   3. FundingEngine       — needs OracleAdapter
 *   4. InsuranceFund       — no deps
 *   5. CollateralVault     — needs ShariahGuard
 *   6. LiquidationEngine   — needs InsuranceFund + CollateralVault
 *   7. PositionManager     — needs all above; set BRKX token + treasury
 *   8. GovernanceModule    — owner = SHARIAH_MULTISIG
 *   9. BRKXToken           — fixed 100M supply → deployer
 *
 * ── Post-deploy Wiring ────────────────────────────────────────────────────────
 *   - OracleAdapter.setOracle(BTC_MARKET,  BTC_USD_PRIMARY, BTC_USD_SECONDARY)
 *   - OracleAdapter.setOracle(ETH_MARKET,  ETH_USD_PRIMARY, ETH_USD_SECONDARY)
 *   - OracleAdapter.snapshotPrice(BTC_MARKET)  — seeds circuit breaker
 *   - OracleAdapter.snapshotPrice(ETH_MARKET)
 *   - InsuranceFund.setAuthorised(LiquidationEngine, true)
 *   - InsuranceFund.setAuthorised(PositionManager,   true)
 *   - CollateralVault.setAuthorised(PositionManager, true)
 *   - CollateralVault.setAuthorised(LiquidationEngine, true)
 *   - LiquidationEngine.setPositionManager(PositionManager)
 *   - PositionManager.setBrkxToken(BRKXToken)
 *   - PositionManager.setTreasury(TREASURY)
 *
 * ── Shariah Board Transactions (separate — cannot be done by deployer) ───────
 *   ShariahGuard.approveAsset(USDC_MAINNET, FATWA_CID)
 *   ShariahGuard.approveAsset(PAXG_MAINNET, FATWA_CID)
 *   ShariahGuard.approveAsset(XAUT_MAINNET, FATWA_CID)
 *   ShariahGuard.approveAsset(BTC_MARKET,   FATWA_CID)
 *   ShariahGuard.approveAsset(ETH_MARKET,   FATWA_CID)
 */
contract DeployMainnet is Script {

    // ── Chainlink Feeds — Arbitrum One ─────────────────────────────────────────
    // Verify before deployment: https://docs.chain.link/data-feeds/price-feeds/addresses?network=arbitrum
    address constant BTC_USD_PRIMARY   = 0x6ce185860a4963106506C203335A2910413708e9; // BTC/USD  Arbitrum One
    address constant BTC_USD_SECONDARY = 0x6ce185860a4963106506C203335A2910413708e9; // same for MVP (single-source fallback)
    address constant ETH_USD_PRIMARY   = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // ETH/USD  Arbitrum One
    address constant ETH_USD_SECONDARY = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // same for MVP

    // ── Market IDs (wrapped asset addresses used as identifiers) ──────────────
    address constant BTC_MARKET = 0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f; // WBTC on Arbitrum One
    address constant ETH_MARKET = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH on Arbitrum One

    // ── Approved Collateral Tokens — Arbitrum One ──────────────────────────────
    // ShariahGuard must approve these (via Shariah multisig after deployment)
    address constant USDC_MAINNET = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // Native USDC
    address constant PAXG_MAINNET = 0xfEb4DfC8C4Cf7Ed305bb08065D08eC6ee6728429; // PAX Gold
    address constant XAUT_MAINNET = 0xf9b276A1A05934ccD953861E8E59c6Bc428c8cbD; // Tether Gold

    // ── Governance ─────────────────────────────────────────────────────────────
    // address(0) = no DAO governance token at launch (Track 2 only: Shariah board)
    address constant GOVERNANCE_TOKEN = address(0);

    // ── Staleness guard ────────────────────────────────────────────────────────
    uint256 constant MAX_FEED_AGE = 5 minutes;

    // ── Min deployer ETH balance for gas ──────────────────────────────────────
    uint256 constant MIN_ETH_BALANCE = 0.1 ether;

    // ─────────────────────────────────────────────────────────────────────────
    // Main entry point
    // ─────────────────────────────────────────────────────────────────────────

    function run() external {
        // ── Read env ──────────────────────────────────────────────────────────
        uint256 deployerPk      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer        = vm.addr(deployerPk);
        address shariahMultisig = vm.envAddress("SHARIAH_MULTISIG");
        address treasury        = vm.envAddress("TREASURY");
        string memory fatwaCid  = vm.envString("FATWA_CID");

        // ── Pre-flight checks (no broadcast) ──────────────────────────────────
        _preflight(deployer, shariahMultisig, fatwaCid);

        console.log("========================================================");
        console.log("  BARAKA PROTOCOL - ARBITRUM ONE MAINNET DEPLOYMENT");
        console.log("========================================================");
        console.log("Deployer         :", deployer);
        console.log("Shariah Multisig :", shariahMultisig);
        console.log("Treasury         :", treasury);
        console.log("Fatwa CID        :", fatwaCid);
        console.log("--------------------------------------------------------");

        vm.startBroadcast(deployerPk);

        // ═════════════════════════════════════════════════════════════════════
        // PHASE 1 — DEPLOY CONTRACTS
        // ═════════════════════════════════════════════════════════════════════

        // 1. OracleAdapter — owned by deployer (admin key controls setOracle)
        OracleAdapter oracle = new OracleAdapter(deployer);
        console.log("1. OracleAdapter     :", address(oracle));

        // 2. ShariahGuard — owned by SHARIAH_MULTISIG (deployer has NO control)
        ShariahGuard shariahGuard = new ShariahGuard(shariahMultisig);
        console.log("2. ShariahGuard      :", address(shariahGuard));

        // 3. FundingEngine
        FundingEngine fundingEngine = new FundingEngine(deployer, address(oracle));
        console.log("3. FundingEngine     :", address(fundingEngine));

        // 4. InsuranceFund
        InsuranceFund insuranceFund = new InsuranceFund(deployer);
        console.log("4. InsuranceFund     :", address(insuranceFund));

        // 5. CollateralVault — ShariahGuard reference is immutable
        CollateralVault vault = new CollateralVault(deployer, address(shariahGuard));
        console.log("5. CollateralVault   :", address(vault));

        // 6. LiquidationEngine
        LiquidationEngine liqEngine = new LiquidationEngine(
            deployer,
            address(insuranceFund),
            address(vault)
        );
        console.log("6. LiquidationEngine :", address(liqEngine));

        // 7. PositionManager
        PositionManager pm = new PositionManager(
            deployer,
            address(shariahGuard),
            address(fundingEngine),
            address(oracle),
            address(vault),
            address(liqEngine),
            address(insuranceFund)
        );
        console.log("7. PositionManager   :", address(pm));

        // 8. GovernanceModule — owned by SHARIAH_MULTISIG
        GovernanceModule governance = new GovernanceModule(shariahMultisig, GOVERNANCE_TOKEN);
        console.log("8. GovernanceModule  :", address(governance));

        // 9. BRKXToken — fixed 100M supply minted to deployer
        BRKXToken brkx = new BRKXToken(deployer);
        console.log("9. BRKXToken         :", address(brkx));

        // ═════════════════════════════════════════════════════════════════════
        // PHASE 2 — REGISTER ORACLE FEEDS
        // ═════════════════════════════════════════════════════════════════════

        oracle.setOracle(BTC_MARKET, BTC_USD_PRIMARY, BTC_USD_SECONDARY);
        console.log("Oracle: BTC/USD feeds set");

        oracle.setOracle(ETH_MARKET, ETH_USD_PRIMARY, ETH_USD_SECONDARY);
        console.log("Oracle: ETH/USD feeds set");

        // Seed circuit breaker baselines (must be called once before trading opens)
        uint256 btcPrice = oracle.snapshotPrice(BTC_MARKET);
        uint256 ethPrice = oracle.snapshotPrice(ETH_MARKET);
        console.log("Oracle: BTC snapshot =", btcPrice / 1e18, "USD");
        console.log("Oracle: ETH snapshot =", ethPrice / 1e18, "USD");

        // ═════════════════════════════════════════════════════════════════════
        // PHASE 3 — WIRE AUTHORIZATIONS & DEPENDENCIES
        // ═════════════════════════════════════════════════════════════════════

        // InsuranceFund: accept calls from LiquidationEngine + PositionManager
        insuranceFund.setAuthorised(address(liqEngine), true);
        insuranceFund.setAuthorised(address(pm),        true);
        console.log("InsuranceFund: authorised LiqEngine + PM");

        // CollateralVault: accept calls from PositionManager + LiquidationEngine
        vault.setAuthorised(address(pm),        true);
        vault.setAuthorised(address(liqEngine), true);
        console.log("CollateralVault: authorised PM + LiqEngine");

        // LiquidationEngine: must know the PM address to verify snapshot updates
        liqEngine.setPositionManager(address(pm));
        console.log("LiquidationEngine: PositionManager set");

        // PositionManager: BRKX fee system
        pm.setBrkxToken(address(brkx));
        pm.setTreasury(treasury);
        console.log("PositionManager: BRKX token + treasury set");

        vm.stopBroadcast();

        // ═════════════════════════════════════════════════════════════════════
        // PHASE 4 — POST-DEPLOY ASSERTIONS (read-only, no broadcast)
        // ═════════════════════════════════════════════════════════════════════

        _verify(
            address(oracle),
            address(shariahGuard),
            address(fundingEngine),
            address(insuranceFund),
            address(vault),
            address(liqEngine),
            address(pm),
            address(governance),
            address(brkx),
            treasury
        );

        // ═════════════════════════════════════════════════════════════════════
        // DEPLOYMENT SUMMARY
        // ═════════════════════════════════════════════════════════════════════

        console.log("\n========================================================");
        console.log("  BARAKA PROTOCOL - MAINNET DEPLOYMENT COMPLETE");
        console.log("========================================================");
        console.log("Network          : Arbitrum One (42161)");
        console.log("Deployer         :", deployer);
        console.log("Shariah Multisig :", shariahMultisig);
        console.log("Treasury         :", treasury);
        console.log("--------------------------------------------------------");
        console.log("Contract Addresses:");
        console.log("  OracleAdapter    :", address(oracle));
        console.log("  ShariahGuard     :", address(shariahGuard));
        console.log("  FundingEngine    :", address(fundingEngine));
        console.log("  InsuranceFund    :", address(insuranceFund));
        console.log("  CollateralVault  :", address(vault));
        console.log("  LiquidationEngine:", address(liqEngine));
        console.log("  PositionManager  :", address(pm));
        console.log("  GovernanceModule :", address(governance));
        console.log("  BRKXToken        :", address(brkx));
        console.log("--------------------------------------------------------");
        console.log("Markets:");
        console.log("  BTC_MARKET  :", BTC_MARKET);
        console.log("  ETH_MARKET  :", ETH_MARKET);
        console.log("--------------------------------------------------------");
        console.log("Chainlink Feeds (Arbitrum One):");
        console.log("  BTC/USD :", BTC_USD_PRIMARY);
        console.log("  ETH/USD :", ETH_USD_PRIMARY);
        console.log("========================================================");
        console.log("NEXT STEPS:");
        console.log("  1. Copy addresses above to deployments/42161.json");
        console.log("  2. Shariah board (Safe) must call ShariahGuard.approveAsset() for:");
        console.log("       USDC   :", USDC_MAINNET);
        console.log("       PAXG   :", PAXG_MAINNET);
        console.log("       XAUT   :", XAUT_MAINNET);
        console.log("       BTC_MKT:", BTC_MARKET);
        console.log("       ETH_MKT:", ETH_MARKET);
        console.log("       FATWA  :", fatwaCid);
        console.log("  3. Run SetFatwaURI.s.sol to register fatwa on-chain");
        console.log("  4. Update frontend/lib/contracts.ts with new addresses");
        console.log("  5. Distribute BRKX to team wallets for fee tier testing");
        console.log("========================================================");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pre-flight checks
    // ─────────────────────────────────────────────────────────────────────────

    function _preflight(
        address deployer,
        address shariahMultisig,
        string memory fatwaCid
    ) internal view {
        console.log("\n[PRE-FLIGHT CHECKS]");

        // 1. Deployer must have ETH for gas
        require(
            deployer.balance >= MIN_ETH_BALANCE,
            "DeployMainnet: deployer ETH balance too low (need >= 0.1 ETH)"
        );
        console.log("  [OK] Deployer ETH balance:", deployer.balance / 1e15, "mETH");

        // 2. Shariah multisig must differ from deployer (mainnet safety invariant)
        require(
            shariahMultisig != deployer,
            "DeployMainnet: SHARIAH_MULTISIG must differ from deployer on mainnet"
        );
        require(
            shariahMultisig != address(0),
            "DeployMainnet: SHARIAH_MULTISIG cannot be zero"
        );
        console.log("  [OK] Shariah multisig is separate from deployer");

        // 3. Treasury must be non-zero
        require(
            vm.envAddress("TREASURY") != address(0),
            "DeployMainnet: TREASURY cannot be zero"
        );
        console.log("  [OK] Treasury address set");

        // 4. Fatwa CID must be provided (non-empty)
        require(
            bytes(fatwaCid).length >= 46,
            "DeployMainnet: FATWA_CID looks invalid (expected >= 46 chars for IPFS CID)"
        );
        console.log("  [OK] Fatwa CID provided");

        // 5. BTC/USD feed freshness
        _checkFeedFresh(BTC_USD_PRIMARY, "BTC/USD");

        // 6. ETH/USD feed freshness
        _checkFeedFresh(ETH_USD_PRIMARY, "ETH/USD");

        console.log("  [OK] All pre-flight checks passed");
        console.log("");
    }

    function _checkFeedFresh(address feedAddr, string memory name) internal view {
        (, int256 answer, , uint256 updatedAt,) =
            IChainlinkFeed(feedAddr).latestRoundData();

        require(answer > 0, string(abi.encodePacked(
            "DeployMainnet: ", name, " feed has non-positive answer"
        )));
        require(
            block.timestamp - updatedAt <= MAX_FEED_AGE,
            string(abi.encodePacked(
                "DeployMainnet: ", name, " feed is stale (>5 min)"
            ))
        );

        uint256 priceUsd = uint256(answer) * 1e18 / (10 ** IChainlinkFeed(feedAddr).decimals());
        console.log(string(abi.encodePacked(
            "  [OK] ", name, " feed fresh, price = "
        )), priceUsd / 1e18, "USD");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Post-deploy assertions
    // ─────────────────────────────────────────────────────────────────────────

    function _verify(
        address oracleAddr,
        address shariahGuardAddr,
        address fundingEngineAddr,
        address insuranceFundAddr,
        address vaultAddr,
        address liqEngineAddr,
        address pmAddr,
        address governanceAddr,
        address brkxAddr,
        address treasury
    ) internal view {
        console.log("\n[POST-DEPLOY ASSERTIONS]");

        // All addresses must be non-zero
        require(oracleAddr       != address(0), "oracle zero");
        require(shariahGuardAddr != address(0), "shariahGuard zero");
        require(fundingEngineAddr!= address(0), "fundingEngine zero");
        require(insuranceFundAddr!= address(0), "insuranceFund zero");
        require(vaultAddr        != address(0), "vault zero");
        require(liqEngineAddr    != address(0), "liqEngine zero");
        require(pmAddr           != address(0), "pm zero");
        require(governanceAddr   != address(0), "governance zero");
        require(brkxAddr         != address(0), "brkx zero");
        console.log("  [OK] All contract addresses non-zero");

        // Oracle: circuit breaker baselines seeded
        require(
            OracleAdapter(oracleAddr).lastValidPrice(BTC_MARKET) > 0,
            "DeployMainnet: BTC circuit breaker not seeded"
        );
        require(
            OracleAdapter(oracleAddr).lastValidPrice(ETH_MARKET) > 0,
            "DeployMainnet: ETH circuit breaker not seeded"
        );
        console.log("  [OK] Oracle circuit breaker baselines seeded");

        // CollateralVault: correct authorizations
        require(
            CollateralVault(vaultAddr).authorised(pmAddr),
            "DeployMainnet: PM not authorised in vault"
        );
        require(
            CollateralVault(vaultAddr).authorised(liqEngineAddr),
            "DeployMainnet: LiqEngine not authorised in vault"
        );
        console.log("  [OK] CollateralVault authorizations correct");

        // LiquidationEngine: PM wired
        require(
            LiquidationEngine(liqEngineAddr).positionManager() == pmAddr,
            "DeployMainnet: LiqEngine.positionManager mismatch"
        );
        console.log("  [OK] LiquidationEngine.positionManager set correctly");

        // InsuranceFund: authorized callers
        require(
            InsuranceFund(insuranceFundAddr).authorised(liqEngineAddr),
            "DeployMainnet: LiqEngine not authorised in InsuranceFund"
        );
        require(
            InsuranceFund(insuranceFundAddr).authorised(pmAddr),
            "DeployMainnet: PM not authorised in InsuranceFund"
        );
        console.log("  [OK] InsuranceFund authorizations correct");

        // PositionManager: BRKX + treasury set
        require(
            address(PositionManager(pmAddr).brkxToken()) == brkxAddr,
            "DeployMainnet: PM.brkxToken mismatch"
        );
        require(
            PositionManager(pmAddr).treasury() == treasury,
            "DeployMainnet: PM.treasury mismatch"
        );
        console.log("  [OK] PositionManager BRKX + treasury configured");

        // BRKXToken: full 100M supply with deployer
        uint256 totalSupply = BRKXToken(brkxAddr).totalSupply();
        require(totalSupply == 100_000_000e18, "DeployMainnet: BRKX supply != 100M");
        console.log("  [OK] BRKXToken: 100M supply verified");

        console.log("  [OK] All post-deploy assertions passed");
    }
}
