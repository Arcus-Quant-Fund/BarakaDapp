// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Core
import "../src/core/SubaccountManager.sol";
import "../src/core/Vault.sol";
import "../src/core/MarginEngine.sol";
import "../src/core/FundingEngine.sol";
import "../src/core/FeeEngine.sol";

// Oracle
import "../src/oracle/OracleAdapter.sol";

// Orderbook
import "../src/orderbook/OrderBook.sol";
import "../src/orderbook/MatchingEngine.sol";

// Settlement
import "../src/settlement/BatchSettlement.sol";

// Risk
import "../src/risk/InsuranceFund.sol";
import "../src/risk/LiquidationEngine.sol";
import "../src/risk/AutoDeleveraging.sol";

// Shariah
import "../src/shariah/ShariahRegistry.sol";
import "../src/shariah/ComplianceOracle.sol";

// Governance
import "../src/governance/BRKXToken.sol";
import "../src/governance/GovernanceModule.sol";

// Instruments
import "../src/instruments/EverlastingOption.sol";
import "../src/instruments/PerpetualSukuk.sol";
import "../src/instruments/TakafulPool.sol";
import "../src/instruments/iCDS.sol";

/**
 * @title Deploy
 * @author Baraka Protocol v2
 * @notice Full deployment script for all 20 protocol contracts.
 *
 *         Deployment order respects dependency graph:
 *           Phase 1 — Standalone: SubaccountManager, Vault, OracleAdapter, InsuranceFund,
 *                     ShariahRegistry, ComplianceOracle, BRKXToken
 *           Phase 2 — Core with deps: FundingEngine, MarginEngine, FeeEngine
 *           Phase 3 — Orderbook: OrderBook(s), MatchingEngine
 *           Phase 4 — Settlement: BatchSettlement
 *           Phase 5 — Risk: LiquidationEngine, AutoDeleveraging
 *           Phase 6 — Instruments: EverlastingOption, PerpetualSukuk, TakafulPool, iCDS
 *           Phase 7 — Governance: GovernanceModule
 *           Phase 8 — Wiring: authorisations, market creation, oracle config
 *
 *         Environment variables:
 *           DEPLOYER_PRIVATE_KEY — deployer/owner private key
 *           COLLATERAL_TOKEN    — USDC address (or other 6-decimal ERC20)
 *           CHAINLINK_BTC_FEED  — Chainlink BTC/USD aggregator (optional, zero = mock)
 *           CHAINLINK_ETH_FEED  — Chainlink ETH/USD aggregator (optional, zero = mock)
 *           SHARIAH_BOARD       — Shariah board multisig address
 *           TREASURY            — Treasury wallet address
 *           GUARDIAN            — Vault guardian address
 *
 *         Usage:
 *           forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --verify
 */
contract Deploy is Script {

    // ─────────────────────────────────────────────────────
    // Market IDs
    // ─────────────────────────────────────────────────────

    bytes32 constant BTC_MARKET = keccak256("BTC-USD");
    bytes32 constant ETH_MARKET = keccak256("ETH-USD");

    // ─────────────────────────────────────────────────────
    // Deployed contracts (set during run)
    // ─────────────────────────────────────────────────────

    SubaccountManager  sam;
    Vault              vault;
    OracleAdapter      oracleAdapter;
    FundingEngine      fundingEngine;
    MarginEngine       marginEngine;
    FeeEngine          feeEngine;
    OrderBook          btcOrderBook;
    OrderBook          ethOrderBook;
    MatchingEngine     matchingEngine;
    BatchSettlement    batchSettlement;
    InsuranceFund      insuranceFund;
    LiquidationEngine  liquidationEngine;
    AutoDeleveraging   adl;
    ShariahRegistry    shariahRegistry;
    ComplianceOracle   complianceOracle;
    BRKXToken          brkxToken;
    GovernanceModule   governanceModule;
    EverlastingOption  everlastingOption;
    PerpetualSukuk     perpetualSukuk;
    TakafulPool        takafulPool;
    iCDS               icds;

    function run() external {
        uint256 deployerPK = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);
        address collateralToken = vm.envAddress("COLLATERAL_TOKEN");
        address treasury = vm.envOr("TREASURY", deployer);
        address guardianAddr = vm.envOr("GUARDIAN", address(0));
        address shariahBoard = vm.envOr("SHARIAH_BOARD", deployer);
        address btcFeed = vm.envOr("CHAINLINK_BTC_FEED", address(0));
        address ethFeed = vm.envOr("CHAINLINK_ETH_FEED", address(0));

        vm.startBroadcast(deployerPK);

        // ═════════════════════════════════════════════════
        // Phase 1 — Standalone contracts
        // ═════════════════════════════════════════════════

        sam = new SubaccountManager();
        console.log("SubaccountManager:", address(sam));

        vault = new Vault(deployer);
        console.log("Vault:", address(vault));

        oracleAdapter = new OracleAdapter(deployer);
        console.log("OracleAdapter:", address(oracleAdapter));

        insuranceFund = new InsuranceFund(deployer);
        console.log("InsuranceFund:", address(insuranceFund));

        shariahRegistry = new ShariahRegistry(deployer);
        console.log("ShariahRegistry:", address(shariahRegistry));

        complianceOracle = new ComplianceOracle(deployer);
        console.log("ComplianceOracle:", address(complianceOracle));

        brkxToken = new BRKXToken(treasury);
        console.log("BRKXToken:", address(brkxToken));

        // ═════════════════════════════════════════════════
        // Phase 2 — Core with dependencies
        // ═════════════════════════════════════════════════

        fundingEngine = new FundingEngine(deployer, address(oracleAdapter));
        console.log("FundingEngine:", address(fundingEngine));

        marginEngine = new MarginEngine(
            deployer,
            address(vault),
            address(sam),
            address(oracleAdapter),
            address(fundingEngine),
            collateralToken
        );
        console.log("MarginEngine:", address(marginEngine));

        feeEngine = new FeeEngine(deployer, address(vault), collateralToken, address(sam));
        console.log("FeeEngine:", address(feeEngine));

        // ═════════════════════════════════════════════════
        // Phase 3 — Orderbook
        // ═════════════════════════════════════════════════

        btcOrderBook = new OrderBook(deployer, BTC_MARKET);
        console.log("OrderBook (BTC):", address(btcOrderBook));

        ethOrderBook = new OrderBook(deployer, ETH_MARKET);
        console.log("OrderBook (ETH):", address(ethOrderBook));

        matchingEngine = new MatchingEngine(
            deployer,
            address(sam),
            address(marginEngine),
            address(shariahRegistry)
        );
        console.log("MatchingEngine:", address(matchingEngine));

        // ═════════════════════════════════════════════════
        // Phase 4 — Settlement
        // ═════════════════════════════════════════════════

        batchSettlement = new BatchSettlement(deployer, address(marginEngine), address(oracleAdapter));
        console.log("BatchSettlement:", address(batchSettlement));

        // ═════════════════════════════════════════════════
        // Phase 5 — Risk
        // ═════════════════════════════════════════════════

        liquidationEngine = new LiquidationEngine(
            deployer,
            address(marginEngine),
            address(vault),
            address(oracleAdapter),
            collateralToken,
            address(sam)
        );
        console.log("LiquidationEngine:", address(liquidationEngine));

        adl = new AutoDeleveraging(
            deployer,
            address(marginEngine),
            address(oracleAdapter),
            address(sam)
        );
        console.log("AutoDeleveraging:", address(adl));

        // ═════════════════════════════════════════════════
        // Phase 6 — Instruments
        // ═════════════════════════════════════════════════

        everlastingOption = new EverlastingOption(deployer, address(oracleAdapter));
        console.log("EverlastingOption:", address(everlastingOption));

        perpetualSukuk = new PerpetualSukuk(deployer, address(everlastingOption), address(oracleAdapter));
        console.log("PerpetualSukuk:", address(perpetualSukuk));

        takafulPool = new TakafulPool(deployer, address(everlastingOption), address(oracleAdapter), deployer);
        console.log("TakafulPool:", address(takafulPool));

        icds = new iCDS(deployer, address(everlastingOption), address(oracleAdapter));
        console.log("iCDS:", address(icds));

        // ═════════════════════════════════════════════════
        // Phase 7 — Governance
        // ═════════════════════════════════════════════════

        governanceModule = new GovernanceModule(shariahBoard, address(brkxToken));
        console.log("GovernanceModule:", address(governanceModule));

        // ═════════════════════════════════════════════════
        // Phase 8 — Wiring & authorisations
        // ═════════════════════════════════════════════════

        // --- Vault ---
        vault.setApprovedToken(collateralToken, true);
        vault.setAuthorised(address(marginEngine), true);
        vault.setAuthorised(address(feeEngine), true);
        vault.setAuthorised(address(liquidationEngine), true);
        if (guardianAddr != address(0)) {
            vault.setGuardian(guardianAddr);
        }

        // --- MarginEngine ---
        marginEngine.setAuthorised(address(matchingEngine), true);
        marginEngine.setAuthorised(address(batchSettlement), true);
        marginEngine.setAuthorised(address(liquidationEngine), true);
        marginEngine.setAuthorised(address(adl), true);

        // --- FeeEngine ---
        feeEngine.setAuthorised(address(matchingEngine), true);
        feeEngine.setRecipients(treasury, address(insuranceFund), address(0)); // stakerPool set later
        feeEngine.setBRKXToken(address(brkxToken));

        // --- OrderBooks ---
        btcOrderBook.setAuthorised(address(matchingEngine), true);
        ethOrderBook.setAuthorised(address(matchingEngine), true);

        // --- MatchingEngine ---
        matchingEngine.setOrderBook(BTC_MARKET, address(btcOrderBook));
        matchingEngine.setOrderBook(ETH_MARKET, address(ethOrderBook));
        matchingEngine.setFeeEngine(address(feeEngine));
        matchingEngine.setOracle(address(oracleAdapter));
        matchingEngine.setADL(address(adl));

        // --- BatchSettlement ---
        batchSettlement.setADL(address(adl));
        batchSettlement.setSubaccountManager(address(sam));

        // --- OracleAdapter ---
        oracleAdapter.setAuthorised(address(matchingEngine), true);
        oracleAdapter.setAuthorised(address(batchSettlement), true);
        if (btcFeed != address(0)) {
            oracleAdapter.setMarketOracle(BTC_MARKET, btcFeed, 3600, 8);
        }
        if (ethFeed != address(0)) {
            oracleAdapter.setMarketOracle(ETH_MARKET, ethFeed, 3600, 8);
        }

        // --- FundingEngine ---
        // clampRate = (IMR - MMR) * 0.9 for BTC: (0.10 - 0.05) * 0.9 = 0.045
        fundingEngine.setClampRate(BTC_MARKET, 0.045e18);
        fundingEngine.setClampRate(ETH_MARKET, 0.045e18);

        // --- MarginEngine markets ---
        // BTC: 10% IMR, 5% MMR, 100 BTC max position (~$5M at $50k)
        marginEngine.createMarket(BTC_MARKET, 0.10e18, 0.05e18, 100e18);
        // ETH: 10% IMR, 5% MMR, 1000 ETH max position (~$3M at $3k)
        marginEngine.createMarket(ETH_MARKET, 0.10e18, 0.05e18, 1000e18);

        // --- InsuranceFund ---
        insuranceFund.setAuthorised(address(liquidationEngine), true);

        // --- LiquidationEngine ---
        liquidationEngine.setInsuranceFund(address(insuranceFund));
        liquidationEngine.setADL(address(adl));

        // --- ShariahRegistry ---
        // Transfer board role if a separate multisig is provided
        if (shariahBoard != deployer) {
            shariahRegistry.setShariahBoard(shariahBoard);
            // Note: shariahBoard must call acceptShariahBoard() to complete transfer
        }
        shariahRegistry.setMarginEngine(address(marginEngine));
        shariahRegistry.setOracle(address(oracleAdapter));

        vm.stopBroadcast();

        // ═════════════════════════════════════════════════
        // Summary
        // ═════════════════════════════════════════════════

        console.log("========== BARAKA PROTOCOL v2 - DEPLOYMENT COMPLETE ==========");
        console.log("Deployer / Owner:", deployer);
        console.log("Collateral Token:", collateralToken);
        console.log("Treasury:", treasury);
        console.log("Markets: BTC-USD, ETH-USD");
        console.log("Total contracts: 21 (20 protocol + 1 BRKX token)");
        console.log("================================================================");
    }
}
