# 🌙 BARAKA — CLAUDE CODE EXECUTION PLAN
### *Step-by-Step Build Instructions for Claude Code*
**Company:** Baraka Financial Protocol  
**Product:** TayyibFi — Shariah-Compliant Perpetual Finance  
**Date:** February 2026  

---

> **How to use this document:** Hand this directly to Claude Code. Each section is a self-contained task with exact commands, file paths, and expected outputs. Work through them in strict order. Never skip a step.

---

## 🔑 SECTION A — ACCOUNTS & API KEYS TO OPEN FIRST

*Complete ALL of these before starting Claude Code. You need every key ready.*

---

### A.1 — BLOCKCHAIN INFRASTRUCTURE

#### 1. Alchemy (Primary RPC Provider)
- **URL:** https://alchemy.com
- **Plan:** Growth ($49/month) — needed for Arbitrum mainnet + testnet
- **Create:**
  - App 1: "Baraka-Arbitrum-Mainnet" → network: Arbitrum One
  - App 2: "Baraka-Arbitrum-Sepolia" → network: Arbitrum Sepolia (testnet)
  - App 3: "Baraka-Ethereum-Mainnet" → network: Ethereum (for oracle feeds)
- **Keys needed:**
  ```
  ALCHEMY_ARBITRUM_MAINNET_RPC=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
  ALCHEMY_ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
  ALCHEMY_ETH_MAINNET_RPC=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
  ```

#### 2. Infura (Backup RPC Provider)
- **URL:** https://infura.io
- **Plan:** Free tier is fine for backup
- **Keys needed:**
  ```
  INFURA_ARBITRUM_RPC=https://arbitrum-mainnet.infura.io/v3/YOUR_KEY
  ```

#### 3. Etherscan / Arbiscan (Contract Verification)
- **URL:** https://arbiscan.io → sign up → API Keys
- **Keys needed:**
  ```
  ARBISCAN_API_KEY=YOUR_KEY
  ETHERSCAN_API_KEY=YOUR_KEY
  ```

---

### A.2 — ORACLE PROVIDERS

#### 4. Chainlink (Primary Oracle)
- **URL:** https://data.chain.link
- **No API key needed** — Chainlink is read-only on-chain
- **Action:** Note the contract addresses for Arbitrum One:
  ```
  CHAINLINK_BTC_USD=0x6ce185860a4963106506C203335A2910413708e9
  CHAINLINK_ETH_USD=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
  CHAINLINK_XAU_USD=0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c
  ```

#### 5. Pyth Network (Secondary Oracle)
- **URL:** https://pyth.network/developers
- **No API key** — on-chain
- **Action:** Note Pyth price feed IDs:
  ```
  PYTH_CONTRACT_ARBITRUM=0xff1a0f4744e8582DF1aE09D5611b887B6a12925C
  PYTH_BTC_FEED_ID=0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
  PYTH_ETH_FEED_ID=0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
  PYTH_XAU_FEED_ID=0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2
  ```

#### 6. Redstone Oracle (Tertiary Oracle)
- **URL:** https://app.redstone.finance
- **No API key** — on-chain
- **Action:** Note Redstone contract on Arbitrum:
  ```
  REDSTONE_CONTRACT_ARBITRUM=0x7C1DAAE7BB0688C9bfE3A918A4224041c7177256
  ```

---

### A.3 — DEVELOPMENT & DEPLOYMENT

#### 7. GitHub (Code Repository)
- **URL:** https://github.com
- **Action:** Create organisation: `baraka-protocol`
- **Repos to create:**
  - `baraka-contracts` (Solidity smart contracts)
  - `baraka-frontend` (Next.js frontend)
  - `baraka-subgraph` (The Graph indexer)
  - `baraka-docs` (Documentation)
  - `baraka-scripts` (Deployment + admin scripts)
- **Keys needed:**
  ```
  GITHUB_TOKEN=ghp_YOUR_PERSONAL_ACCESS_TOKEN
  ```

#### 8. Foundry (Smart Contract Framework)
- **No account needed** — local install
- **Claude Code will install this**

#### 9. Hardhat (Optional Backup)
- **No account needed** — npm package

#### 10. Deployer Wallet
- **Action:** Create a NEW MetaMask wallet ONLY for deployment
- **NEVER use your personal wallet**
- **Fund with:** 0.5 ETH on Arbitrum Sepolia (from faucet) + 0.1 ETH on Arbitrum One (mainnet)
- **Keys needed:**
  ```
  DEPLOYER_PRIVATE_KEY=0xYOUR_DEPLOYER_WALLET_PRIVATE_KEY
  DEPLOYER_ADDRESS=0xYOUR_DEPLOYER_WALLET_ADDRESS
  ```
- **Faucet for testnet ETH:** https://www.alchemy.com/faucets/arbitrum-sepolia

---

### A.4 — SECURITY & AUDITING TOOLS

#### 11. Slither (Static Analysis)
- **No account** — pip install
- **Claude Code will install**

#### 12. Tenderly (Transaction Simulation & Monitoring)
- **URL:** https://tenderly.co
- **Plan:** Free tier (Dev plan sufficient for Phase 1)
- **Keys needed:**
  ```
  TENDERLY_ACCESS_KEY=YOUR_KEY
  TENDERLY_PROJECT=baraka-protocol
  TENDERLY_USERNAME=baraka
  ```

#### 13. OpenZeppelin Defender (Admin & Automation)
- **URL:** https://defender.openzeppelin.com
- **Plan:** Free tier for start
- **Use for:** Multisig management, timelock, automated monitoring
- **Keys needed:**
  ```
  OZ_DEFENDER_API_KEY=YOUR_KEY
  OZ_DEFENDER_SECRET=YOUR_SECRET
  ```

---

### A.5 — INDEXING & DATA

#### 14. The Graph (Subgraph Indexer)
- **URL:** https://thegraph.com/studio
- **Plan:** Free (pay per query in production)
- **Action:** Create subgraph: "baraka-protocol"
- **Keys needed:**
  ```
  THE_GRAPH_DEPLOY_KEY=YOUR_KEY
  THE_GRAPH_STUDIO_URL=https://api.studio.thegraph.com/query/YOUR_ID/baraka-protocol/v0.0.1
  ```

#### 15. Pinata (IPFS — for Fatwa Documents)
- **URL:** https://app.pinata.cloud
- **Plan:** Free tier (1GB storage)
- **Use for:** Storing Shariah fatwa PDFs permanently on IPFS
- **Keys needed:**
  ```
  PINATA_API_KEY=YOUR_KEY
  PINATA_SECRET_KEY=YOUR_SECRET
  PINATA_JWT=YOUR_JWT_TOKEN
  ```

---

### A.6 — FRONTEND & INFRASTRUCTURE

#### 16. Vercel (Frontend Hosting)
- **URL:** https://vercel.com
- **Plan:** Pro ($20/month) — needed for team features
- **Connect to:** GitHub `baraka-frontend` repo
- **Keys needed:**
  ```
  VERCEL_TOKEN=YOUR_TOKEN
  VERCEL_ORG_ID=YOUR_ORG_ID
  VERCEL_PROJECT_ID=YOUR_PROJECT_ID
  ```

#### 17. Supabase (Database — for off-chain analytics)
- **URL:** https://supabase.com
- **Plan:** Free tier to start
- **Keys needed:**
  ```
  SUPABASE_URL=https://YOUR_PROJECT.supabase.co
  SUPABASE_ANON_KEY=YOUR_ANON_KEY
  SUPABASE_SERVICE_KEY=YOUR_SERVICE_KEY
  ```

#### 18. Upstash Redis (Real-time caching)
- **URL:** https://upstash.com
- **Plan:** Free tier (10,000 commands/day)
- **Keys needed:**
  ```
  UPSTASH_REDIS_URL=rediss://YOUR_URL
  UPSTASH_REDIS_TOKEN=YOUR_TOKEN
  ```

---

### A.7 — COMPLIANCE & MONITORING

#### 19. Chainalysis (AML Screening)
- **URL:** https://www.chainalysis.com/chainalysis-kyt/
- **Plan:** Contact sales — get startup pricing
- **Keys needed:**
  ```
  CHAINALYSIS_API_KEY=YOUR_KEY
  ```
- **Note:** Can defer this to Phase 3 (mainnet launch). Use free Etherscan labels API initially.

#### 20. PagerDuty (Alerting)
- **URL:** https://pagerduty.com
- **Plan:** Free tier
- **Keys needed:**
  ```
  PAGERDUTY_INTEGRATION_KEY=YOUR_KEY
  ```

#### 21. Dune Analytics (On-Chain Data Dashboards)
- **URL:** https://dune.com
- **Plan:** Free (Plus $35/month when needed)
- **No API key for MVP** — use their UI to build dashboards

---

### A.8 — COMMUNICATIONS & LEGAL

#### 22. Clerk (Authentication for Dashboard)
- **URL:** https://clerk.com
- **Plan:** Free tier (10,000 MAU)
- **Keys needed:**
  ```
  NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_YOUR_KEY
  CLERK_SECRET_KEY=sk_YOUR_KEY
  ```

#### 23. Loops (Email — for user notifications)
- **URL:** https://loops.so
- **Plan:** Free tier
- **Keys needed:**
  ```
  LOOPS_API_KEY=YOUR_KEY
  ```

---

### A.9 — MASTER .env FILE TEMPLATE

*Claude Code will create this file. You fill in the values.*

```bash
# ============================================================
# BARAKA PROTOCOL — ENVIRONMENT VARIABLES
# NEVER commit this file to GitHub
# ============================================================

# --- BLOCKCHAIN ---
ALCHEMY_ARBITRUM_MAINNET_RPC=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
ALCHEMY_ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
ALCHEMY_ETH_MAINNET_RPC=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
INFURA_ARBITRUM_RPC=https://arbitrum-mainnet.infura.io/v3/YOUR_KEY

# --- DEPLOYER WALLET (NEVER share this) ---
DEPLOYER_PRIVATE_KEY=0x
DEPLOYER_ADDRESS=0x

# --- BLOCK EXPLORERS ---
ARBISCAN_API_KEY=
ETHERSCAN_API_KEY=

# --- ORACLES (on-chain addresses — no keys needed) ---
CHAINLINK_BTC_USD=0x6ce185860a4963106506C203335A2910413708e9
CHAINLINK_ETH_USD=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
CHAINLINK_XAU_USD=0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c
PYTH_CONTRACT_ARBITRUM=0xff1a0f4744e8582DF1aE09D5611b887B6a12925C

# --- MONITORING ---
TENDERLY_ACCESS_KEY=
TENDERLY_PROJECT=baraka-protocol
TENDERLY_USERNAME=baraka
OZ_DEFENDER_API_KEY=
OZ_DEFENDER_SECRET=

# --- INDEXER ---
THE_GRAPH_DEPLOY_KEY=
THE_GRAPH_STUDIO_URL=

# --- IPFS ---
PINATA_API_KEY=
PINATA_SECRET_KEY=
PINATA_JWT=

# --- FRONTEND ---
VERCEL_TOKEN=
NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=
CLERK_SECRET_KEY=

# --- DATABASE ---
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_KEY=
UPSTASH_REDIS_URL=
UPSTASH_REDIS_TOKEN=

# --- COMPLIANCE ---
CHAINALYSIS_API_KEY=

# --- ALERTS ---
PAGERDUTY_INTEGRATION_KEY=

# --- EMAIL ---
LOOPS_API_KEY=

# --- NETWORK SETTINGS ---
CHAIN_ID_MAINNET=42161
CHAIN_ID_TESTNET=421614
```

---

## 🤖 SECTION B — CLAUDE CODE STEP-BY-STEP EXECUTION PLAN

*These are the exact instructions to give Claude Code, in order.*

---

### SPRINT 0 — ENVIRONMENT SETUP (Day 1)

**Give Claude Code this exact prompt:**

```
You are building the Baraka Protocol — a Shariah-compliant DeFi platform.
First task: set up the complete development environment.

Step 1: Check system prerequisites
- Run: node --version (need >= 18)
- Run: git --version
- Run: python3 --version

Step 2: Install Foundry
- Run: curl -L https://foundry.paradigm.xyz | bash
- Run: foundryup
- Verify: forge --version, cast --version, anvil --version

Step 3: Install global tools
- Run: npm install -g pnpm
- Run: pip3 install slither-analyzer
- Run: pip3 install eth-brownie

Step 4: Create project structure
mkdir baraka-protocol
cd baraka-protocol
git init
Create the folder structure below exactly.
```

**Folder structure to create:**
```
baraka-protocol/
├── contracts/                  # Solidity smart contracts
│   ├── src/
│   │   ├── core/
│   │   │   ├── FundingEngine.sol
│   │   │   ├── PositionManager.sol
│   │   │   ├── CollateralVault.sol
│   │   │   └── LiquidationEngine.sol
│   │   ├── shariah/
│   │   │   ├── ShariahGuard.sol
│   │   │   └── GovernanceModule.sol
│   │   ├── oracle/
│   │   │   └── OracleAdapter.sol
│   │   ├── insurance/
│   │   │   └── InsuranceFund.sol
│   │   └── interfaces/
│   │       ├── IFundingEngine.sol
│   │       ├── IShariahGuard.sol
│   │       └── IOracleAdapter.sol
│   ├── test/
│   │   ├── unit/
│   │   ├── integration/
│   │   └── invariant/
│   ├── script/
│   │   ├── Deploy.s.sol
│   │   └── Configure.s.sol
│   ├── lib/                    # Git submodules
│   ├── foundry.toml
│   └── .env
├── frontend/                   # Next.js app
│   ├── app/
│   ├── components/
│   ├── hooks/
│   ├── lib/
│   └── public/
├── subgraph/                   # The Graph indexer
│   ├── src/
│   ├── schema.graphql
│   └── subgraph.yaml
├── scripts/                    # Utility scripts
│   ├── verify.sh
│   └── monitor.sh
├── docs/                       # Documentation
│   ├── WHITEPAPER.md
│   ├── SHARIAH_PROOF.md
│   └── API.md
├── .env.example
├── .gitignore
└── README.md
```

---

### SPRINT 1 — SMART CONTRACTS (Days 2–14)

#### Task 1.1 — Foundry Project Initialisation

```
In the /contracts directory, run these exact commands:

forge init --no-commit
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
forge install foundry-rs/forge-std
forge install smartcontractkit/chainlink-brownie-contracts

Update foundry.toml with:
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
ffi = true
via_ir = true

[profile.default.fuzz]
runs = 10000

[rpc_endpoints]
arbitrum_sepolia = "${ALCHEMY_ARBITRUM_SEPOLIA_RPC}"
arbitrum_mainnet = "${ALCHEMY_ARBITRUM_MAINNET_RPC}"

[etherscan]
arbitrum_sepolia = { key = "${ARBISCAN_API_KEY}", url = "https://api-sepolia.arbiscan.io/api" }
arbitrum_mainnet = { key = "${ARBISCAN_API_KEY}", url = "https://api.arbiscan.io/api" }
```

#### Task 1.2 — Write FundingEngine.sol

**Give Claude Code this prompt:**

```
Write FundingEngine.sol in /contracts/src/core/FundingEngine.sol

Requirements:
1. Implements ι=0 perpetual futures funding formula: F = P = (mark - index) / index
2. NO interest parameter. NO interest floor. NO minimum rate.
3. Funding interval: 1 hour
4. TWAP window: 30 minutes for mark price
5. Circuit breaker clamp: ±75 basis points per interval (symmetric — not a floor)
6. Uses IOracleAdapter interface
7. Natspec comments must cite: Ackerer, Hugonnier & Jermann (2024), Mathematical Finance, Theorem 3 / Proposition 3
8. Events: FundingRateUpdated(market, rate, markPrice, indexPrice, timestamp)
9. OpenZeppelin Ownable2Step for admin
10. OpenZeppelin Pausable for emergency stops
11. ReentrancyGuard on all state-changing functions

Key function: getFundingRate(address market) returns (int256)
Formula: fundingRate = (markPrice - indexPrice) * 1e18 / indexPrice

Include full NatSpec documentation explaining the Islamic finance rationale.
After writing the contract, write comprehensive Foundry tests in /contracts/test/unit/FundingEngine.t.sol covering:
- F=0 when mark=index
- F>0 when mark>index
- F<0 when mark<index  
- No interest floor in any scenario
- Circuit breaker clamp tests
- Fuzz tests on funding rate calculation
```

#### Task 1.3 — Write ShariahGuard.sol

```
Write ShariahGuard.sol in /contracts/src/shariah/ShariahGuard.sol

Requirements:
1. MAX_LEVERAGE = 5 (immutable constant — cannot ever be changed)
2. approvedAssets mapping (address => bool)
3. shariahFatwaIPFS mapping (address => string) — stores IPFS hash of fatwa document
4. shariahMultisig address — 3-of-5 multisig, only entity that can approve assets
5. approveAsset(token, ipfsHash) — only shariahMultisig
6. revokeAsset(token, reason) — only shariahMultisig
7. validatePosition(asset, leverage, collateralToken) — reverts if non-compliant
8. emergencyPause(market, reason) — only shariahMultisig
9. Events: AssetApproved(token, fatwaIPFSHash), AssetRevoked(token, reason), MarketPaused(market, reason)

Write tests in /contracts/test/unit/ShariahGuard.t.sol covering:
- Non-approved asset cannot be traded
- Leverage > 5 reverts
- Only multisig can approve assets
- Fatwa IPFS hash is stored correctly
- Emergency pause works
```

#### Task 1.4 — Write OracleAdapter.sol

```
Write OracleAdapter.sol in /contracts/src/oracle/OracleAdapter.sol

Requirements:
1. Three oracle sources: Chainlink, Pyth, Redstone
2. Weights: Chainlink 40%, Pyth 40%, Redstone 20%
3. Require 2-of-3 agreement within 0.5% tolerance before returning price
4. Staleness check: reject prices older than 5 minutes
5. Circuit breaker: reject prices >20% from last valid price
6. Failover: if primary fails, use 2-of-2 from remaining
7. getIndexPrice(address asset) returns (uint256)
8. getMarkPrice(address asset, uint256 twapWindow) returns (uint256) — on-chain TWAP
9. Events: OraclePriceUpdated, OracleDeviation(source, expected, actual), OracleFallback

Use Chainlink AggregatorV3Interface
Use Pyth IPyth interface
Implement TWAP using cumulative price tracking

Write mock oracles for testing in /contracts/test/mocks/
Write tests covering oracle divergence, staleness, failover scenarios
```

#### Task 1.5 — Write PositionManager.sol

```
Write PositionManager.sol in /contracts/src/core/PositionManager.sol

Requirements:
1. openPosition(market, size, leverage, collateral) — checks ShariahGuard before execution
2. closePosition(positionId) 
3. liquidatePosition(positionId) — calls LiquidationEngine
4. settleFunding(market) — applies FundingEngine rate to all positions in market
5. Position struct: {id, trader, market, size, leverage, entryPrice, collateral, fundingAccrued, openTimestamp}
6. Isolated margin system (not cross-margin)
7. Calculate unrealized PnL: (currentPrice - entryPrice) * size
8. Maximum open interest per market (risk parameter)
9. Events: PositionOpened, PositionClosed, FundingSettled, LiquidationTriggered

Integrate with: ShariahGuard, FundingEngine, OracleAdapter, CollateralVault, LiquidationEngine
```

#### Task 1.6 — Write CollateralVault.sol

```
Write CollateralVault.sol in /contracts/src/core/CollateralVault.sol

Requirements:
1. Accept USDC, PAXG, XAUT as collateral (others rejected by ShariahGuard check)
2. deposit(token, amount) — check ShariahGuard approval
3. withdraw(token, amount) — 24-hour cooldown
4. getBalance(user, token) returns (uint256)
5. lockCollateral(user, amount) — called by PositionManager when opening position
6. unlockCollateral(user, amount) — called when closing/liquidating
7. NO rehypothecation of collateral (funds cannot be lent out)
8. Emergency withdrawal: bypasses cooldown if protocol is paused
9. Events: Deposited, Withdrawn, CollateralLocked, CollateralUnlocked

Token addresses (Arbitrum One):
USDC: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
PAXG: 0xfEb4DfC8C4Cf7Ed305bb08065D08eC6ee6728429
XAUT: 0xf9b276a1a05934ccD953861E8E59c6Bc428c8cbD
```

#### Task 1.7 — Write LiquidationEngine.sol

```
Write LiquidationEngine.sol in /contracts/src/core/LiquidationEngine.sol

Requirements:
1. Maintenance margin threshold: 2% of position value
2. Liquidation penalty: 1% of position notional
3. Penalty split: 50% to InsuranceFund, 50% to liquidator
4. Partial liquidation first (reduce to safe leverage before full close)
5. Price impact protection: cannot liquidate at >5% slippage from mark price
6. isLiquidatable(positionId) returns (bool)
7. liquidate(positionId) — callable by anyone when position is underwater
8. Block delay: 1-block minimum between position open and liquidation eligibility
9. Events: Liquidated(positionId, liquidator, penalty, timestamp)
```

#### Task 1.8 — Write InsuranceFund.sol

```
Write InsuranceFund.sol in /contracts/src/insurance/InsuranceFund.sol

Requirements:
1. Receives: 50% of liquidation penalties + 10% of protocol trading fees
2. Covers socialized losses when liquidations are insufficient
3. NO yield generation on idle capital (avoids riba on reserves)
4. Surplus distribution: if fund > 2x average weekly claims, return excess pro-rata to users
5. Governance: Shariah board must approve any policy change
6. coverShortfall(amount) — called by PositionManager when liquidation insufficient
7. This is the SEED of Layer 3 Takaful — document this in NatSpec
8. Events: FundReceived, ShortfallCovered, SurplusDistributed
```

#### Task 1.9 — Write Interfaces

```
Write all interfaces in /contracts/src/interfaces/:

IFundingEngine.sol — interface for FundingEngine
IShariahGuard.sol — interface for ShariahGuard  
IOracleAdapter.sol — interface for OracleAdapter
IPositionManager.sol — interface for PositionManager
ICollateralVault.sol — interface for CollateralVault
ILiquidationEngine.sol — interface for LiquidationEngine
IInsuranceFund.sol — interface for InsuranceFund
```

#### Task 1.10 — Write Deployment Script

```
Write Deploy.s.sol in /contracts/script/Deploy.s.sol

Deploy order (dependencies must deploy first):
1. OracleAdapter (no dependencies)
2. ShariahGuard (no dependencies)
3. InsuranceFund (no dependencies)
4. FundingEngine (needs OracleAdapter)
5. CollateralVault (needs ShariahGuard)
6. LiquidationEngine (needs InsuranceFund)
7. PositionManager (needs all above)

After deployment:
- Set PositionManager address in FundingEngine
- Set PositionManager address in CollateralVault
- Set PositionManager address in LiquidationEngine
- Approve initial assets in ShariahGuard: USDC, PAXG, XAUT
- Transfer ownership to deployer multisig

Print all deployed addresses to console.
Save addresses to /contracts/deployments/arbitrum-sepolia.json
```

---

### SPRINT 2 — TESTING (Days 15–21)

#### Task 2.1 — Unit Tests

```
Run all unit tests and achieve 95%+ branch coverage:
forge test --match-path "test/unit/*" -vvv

Fix any failing tests. 
Run coverage: forge coverage
Output coverage report to /contracts/coverage/
```

#### Task 2.2 — Integration Tests

```
Write integration tests in /contracts/test/integration/

Test scenarios:
1. Full lifecycle: deposit → open position → funding settlement → close position → withdraw
2. Liquidation flow: open position → price drops → margin call → liquidation → insurance fund
3. Oracle failure: primary oracle goes down → system falls back to secondary
4. Shariah guard: attempt to trade non-approved asset → revert
5. Leverage cap: attempt 10x leverage → revert
6. Funding rate: verify F=0 when mark=index, F positive/negative in both directions

Run: forge test --match-path "test/integration/*" -vvv
```

#### Task 2.3 — Invariant Tests

```
Write invariant tests in /contracts/test/invariant/

Invariants to test:
1. Total collateral locked = sum of all open position collateral requirements (always)
2. Insurance fund balance >= 0 (never goes negative)
3. No position can have leverage > MAX_LEVERAGE (5)
4. FundingEngine never returns an interest floor (verify ι=0 in all states)
5. Only approved assets can have open positions

Run: forge test --match-path "test/invariant/*" -vvv --fuzz-seed 42
```

#### Task 2.4 — Static Analysis

```
Run Slither on all contracts:
slither contracts/src/ --checklist --markdown-root https://github.com/baraka-protocol/baraka-contracts > /docs/slither-report.md

Fix all HIGH and MEDIUM severity issues.
Document and accept LOW severity with justification.
```

#### Task 2.5 — Deploy to Testnet

```
Deploy to Arbitrum Sepolia:
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --verify -vvvv

Verify all contracts on Arbiscan:
forge verify-contract <address> src/core/FundingEngine.sol:FundingEngine --chain arbitrum-sepolia

Save deployment addresses to /contracts/deployments/arbitrum-sepolia.json
```

---

### SPRINT 3 — FRONTEND (Days 22–35)

#### Task 3.1 — Next.js Project Setup

```
In /frontend directory:

npx create-next-app@latest . --typescript --tailwind --eslint --app --src-dir --import-alias "@/*"

Install dependencies:
pnpm add wagmi viem @rainbow-me/rainbowkit
pnpm add @tanstack/react-query
pnpm add recharts
pnpm add @clerk/nextjs
pnpm add framer-motion
pnpm add lucide-react
pnpm add @radix-ui/react-dialog @radix-ui/react-dropdown-menu @radix-ui/react-tabs
pnpm add lightweight-charts   # TradingView chart library

Configure wagmi with Arbitrum Sepolia + Mainnet
Configure RainbowKit with custom Baraka theme (green/gold Islamic aesthetic)
```

#### Task 3.2 — Core Pages

```
Build these pages in /frontend/app/:

1. / (Homepage) — landing page with:
   - Baraka branding (crescent moon + geometric Islamic pattern)
   - "World's first mathematically-proven halal perpetuals" headline
   - Live κ value display
   - Link to fatwa (IPFS)
   - Connect wallet button

2. /trade — main trading interface:
   - TradingView chart (price + funding rate overlay)
   - Order panel (market/limit, long/short, leverage slider capped at 5x)
   - Position panel (open positions, PnL, funding accrued)
   - Funding rate history chart
   - Shariah compliance indicator (green badge with fatwa link)

3. /dashboard — portfolio overview:
   - Total collateral
   - Open positions
   - PnL history
   - Funding payments history

4. /transparency — Shariah proof page:
   - Live formula display: F = P = (mark - index) / index
   - Live κ value with explanation
   - CEX vs Baraka comparison (show structural riba = 10.95%/year vs Baraka = 0%)
   - Fatwa document (embedded PDF from IPFS)
   - Link to Ackerer et al. (2024) paper

5. /markets — market overview:
   - All available markets
   - Current funding rates
   - 24h volume, open interest
   - Shariah status badge for each market
```

#### Task 3.3 — Smart Contract Hooks

```
Write custom React hooks in /frontend/hooks/:

useFundingRate(market) — reads live funding rate from FundingEngine
usePosition(positionId) — reads position data
useCollateralBalance(token) — reads user collateral balance
useKappa(market) — reads and displays κ value
useOpenPosition() — mutation hook for opening positions
useClosePosition() — mutation hook for closing positions
useDeposit() — mutation hook for depositing collateral
useWithdraw() — mutation hook for withdrawing collateral

All hooks use wagmi's useReadContract / useWriteContract
All hooks include loading, error, and success states
```

#### Task 3.4 — Shariah Transparency Component

```
Build ShariahPanel component in /frontend/components/ShariahPanel.tsx

This is a key differentiator. It should display:
1. Live formula: F = (mark - index) / index  [with real numbers substituted in]
2. Interest component: ι = 0.000% (hardcoded, highlighted in green)
3. CEX comparison: Binance ι = 0.010%/8h = 10.95%/year [red]
4. Fatwa status: "Certified by [Scholar Names]" with link to IPFS document
5. κ meter: real-time convergence strength gauge
6. Mathematical proof: expandable section showing Ackerer theorem citation

Style: Islamic geometric patterns, green and gold color scheme, Arabic calligraphy header "بَرَكَة"
```

---

### SPRINT 4 — THE GRAPH SUBGRAPH (Days 36–40)

#### Task 4.1 — Subgraph Setup

```
In /subgraph directory:

npm install -g @graphprotocol/graph-cli
graph init --studio baraka-protocol

Write schema.graphql defining:
- Position entity (id, trader, market, size, leverage, entryPrice, collateral, status)
- FundingRate entity (id, market, rate, markPrice, indexPrice, timestamp)
- Trade entity (id, trader, market, type, size, price, timestamp)
- KappaValue entity (id, market, kappa, basis, timestamp)
- Market entity (id, token, totalOpenInterest, totalVolume, approvedAt)

Write mappings in /subgraph/src/ for each event:
- handleFundingRateUpdated
- handlePositionOpened
- handlePositionClosed
- handleFundingSettled
- handleLiquidated
- handleAssetApproved

Deploy to The Graph Studio:
graph deploy baraka-protocol
```

---

### SPRINT 5 — DEVOPS & MONITORING (Days 41–45)

#### Task 5.1 — GitHub Actions CI/CD

```
Create /.github/workflows/ci.yml:

On every pull request to main:
1. Run: forge test (all tests must pass)
2. Run: forge coverage (must be >= 95%)
3. Run: slither contracts/src/ (no new HIGH/MEDIUM issues)
4. Run: forge build (no compiler warnings)
5. Run: pnpm lint (no ESLint errors in frontend)
6. Run: pnpm type-check (no TypeScript errors)

On merge to main:
1. Deploy frontend to Vercel preview
2. If tag v*.*.* — deploy contracts to Arbitrum Sepolia

On tag v*.*.*-mainnet:
1. Require manual approval
2. Deploy contracts to Arbitrum One
3. Verify on Arbiscan
4. Post deployment summary to GitHub
```

#### Task 5.2 — Monitoring Setup

```
Create /scripts/monitor.sh:

Monitor every 5 minutes:
1. Check oracle prices (Chainlink, Pyth) — alert if divergence > 0.5%
2. Check funding rate — alert if |rate| > 0.05% per hour (unusual)
3. Check InsuranceFund balance — alert if < $10,000
4. Check all contract pause status
5. Check κ value — alert if κ < 0.1 (weak convergence)

Send alerts to PagerDuty on any breach.
Log all values to Supabase for historical tracking.

Set up Tenderly alert:
- Alert if any contract function reverts unexpectedly
- Alert if admin function called from non-multisig address
- Alert if TVL changes > 20% in 1 hour
```

#### Task 5.3 — Documentation

```
Write /docs/WHITEPAPER.md covering:
1. Introduction: The Islamic finance gap in DeFi
2. Mathematical foundation: Ackerer et al. (2024) theorems (full derivations)
3. The ι=0 insight: why no interest is needed for convergence
4. Shariah compliance: Riba, Gharar, Maysir, Qabdh analysis
5. Protocol architecture: all contracts explained
6. The κ-Engine: real-time convergence monitoring
7. Governance: two-track system
8. Roadmap: Layers 1-4
9. References: all academic citations

Write /docs/SHARIAH_PROOF.md:
1. Formal mathematical proof that ι=0 satisfies no-arbitrage
2. Comparison with CEX interest structure
3. Response to common scholar objections
4. Links to empirical dYdX data (365-day dataset)

Write /docs/API.md covering all contract ABIs and function signatures
```

---

### SPRINT 6 — TESTNET LAUNCH (Days 46–60)

#### Task 6.1 — Testnet Deployment Checklist

```
Run through this checklist before testnet launch:

Contracts:
[ ] All 8 contracts deployed to Arbitrum Sepolia
[ ] All contracts verified on Arbiscan
[ ] Initial assets approved in ShariahGuard (USDC test token, test PAXG)
[ ] Oracle adapter connected to testnet price feeds
[ ] Deployment addresses saved to /contracts/deployments/arbitrum-sepolia.json

Frontend:
[ ] Frontend deployed to Vercel (preview URL)
[ ] Connects to Arbitrum Sepolia
[ ] All pages functional
[ ] Wallet connection working
[ ] Position open/close flow working end-to-end

Monitoring:
[ ] Monitoring script running
[ ] Tenderly alerts configured
[ ] Subgraph indexed and queryable

Testing:
[ ] Do a manual end-to-end test: connect wallet → deposit USDC → open BTC-USDC position → wait for funding → close position → withdraw
[ ] Test liquidation flow: open position, manually manipulate test oracle below liquidation price, verify liquidation
```

#### Task 6.2 — Bug Bounty Preparation

```
Write /docs/SECURITY.md covering:
1. Scope: which contracts are in scope
2. Out of scope: frontend, documentation
3. Reward tiers: Critical ($50K), High ($20K), Medium ($5K), Low ($1K)
4. Reporting: security@baraka.finance
5. Rules: no DoS testing on mainnet

Set up Immunefi bug bounty programme (do this before mainnet).
```

---

## 📋 SECTION C — CLAUDE CODE DAILY WORKFLOW

*How to work with Claude Code each day.*

### How to Start Each Day

```
1. Pull latest code:
   cd baraka-protocol && git pull

2. Run tests (ensure nothing broke overnight):
   cd contracts && forge test

3. Check CI status on GitHub

4. Open today's sprint task from this document

5. Give Claude Code the specific task prompt from the relevant sprint
```

### How to Give Claude Code a Task

Always structure your prompt like this:

```
Context: We are building Baraka Protocol — a Shariah-compliant perpetual 
futures DApp on Arbitrum. Mathematical basis: Ackerer, Hugonnier & Jermann 
(2024). Key constraint: ι=0 ALWAYS (no interest parameter anywhere).

File to create: [exact file path]

Requirements:
[paste the requirements from the relevant task above]

After writing the code:
1. Run the tests
2. Fix any failures
3. Run forge coverage
4. Show me the output
```

### When Claude Code Finishes a Task

```
1. Review the code yourself
2. Run: forge test -vvv (review output)
3. Run: git add . && git commit -m "feat: [task description]"
4. Move to next task
```

---

## 🗓️ SECTION D — TIMELINE SUMMARY

| Sprint | Task | Days | Deliverable |
|---|---|---|---|
| 0 | Environment Setup | 1 | Working Foundry + Node.js environment |
| 1 | Smart Contracts | 2–14 | 8 contracts written + tested |
| 2 | Testing | 15–21 | 95%+ coverage + Slither clean + Sepolia deploy |
| 3 | Frontend | 22–35 | Working trading UI on testnet |
| 4 | Subgraph | 36–40 | Live indexer on The Graph |
| 5 | DevOps | 41–45 | CI/CD + monitoring + docs |
| 6 | Testnet Launch | 46–60 | Public testnet with 1,000 beta users |
| — | Phase 2 | 60–90 | Shariah board review, external audit |
| — | Phase 3 | 90–120 | Mainnet launch 🚀 |

---

## ⚡ SECTION E — QUICK REFERENCE COMMANDS

```bash
# Start local blockchain
anvil --chain-id 31337 --block-time 2

# Compile contracts
forge build

# Run all tests
forge test -vvv

# Run specific test
forge test --match-test testFundingRateIsZeroWhenMarkEqualsIndex -vvvv

# Run coverage
forge coverage --report lcov

# Deploy to testnet
forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --verify

# Verify contract
forge verify-contract <addr> src/core/FundingEngine.sol:FundingEngine --chain arbitrum-sepolia

# Run slither
slither contracts/src/

# Start frontend dev server
cd frontend && pnpm dev

# Deploy subgraph
cd subgraph && graph deploy baraka-protocol

# Check deployer balance
cast balance $DEPLOYER_ADDRESS --rpc-url $ALCHEMY_ARBITRUM_SEPOLIA_RPC

# Read funding rate from deployed contract
cast call $FUNDING_ENGINE_ADDRESS "getFundingRate(address)" $BTC_MARKET_ADDRESS --rpc-url $ALCHEMY_ARBITRUM_SEPOLIA_RPC
```

---

## 🔐 SECTION F — SECURITY RULES FOR CLAUDE CODE

*Claude Code must follow these rules without exception.*

```
1. NEVER hardcode private keys in any file
2. ALWAYS use environment variables for sensitive values
3. ALWAYS add the private key file to .gitignore BEFORE creating it
4. NEVER commit .env files
5. ALWAYS use OpenZeppelin's audited contracts (not custom implementations) for:
   - Access control (Ownable2Step, AccessControl)
   - Reentrancy protection (ReentrancyGuard)
   - Pausable
   - SafeERC20 for token transfers
6. ALWAYS check that MAX_LEVERAGE = 5 cannot be modified without Shariah board multisig
7. ALWAYS verify that ι=0 is enforced — no interest floor can be added
8. ALWAYS emit events for every state change
9. ALWAYS use SafeERC20 for ERC20 transfers
10. NEVER use tx.origin for authentication
11. ALWAYS use block.timestamp with care (can be manipulated by miners slightly)
12. For oracle prices — ALWAYS check for staleness and zero values
```

---

*Plan Version 1.0 — February 2026*  
*Company: Baraka Financial Protocol*  
*"May your work be blessed" — بَرَكَة*
