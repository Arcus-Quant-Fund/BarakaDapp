# 🌙 BARAKA — ALMOST FREE BUILD PLAN
### *Build the entire protocol for under $50/month*
**Version:** 1.0 — February 2026

---

> Every tool below has a free tier. Total monthly cost: ~$0–$50 depending on usage.
> The only things you genuinely need to pay for are gas fees to deploy contracts.

---

## 💰 TRUE COST BREAKDOWN

| Item | Cost | When |
|---|---|---|
| Arbitrum Sepolia testnet gas | **$0** | Free testnet ETH from faucet |
| Arbitrum One mainnet deploy (8 contracts) | **~$15–30 one-time** | Phase 3 only |
| All accounts below | **$0** | Free tiers |
| Domain name (baraka.finance) | **~$15/year** | Optional |
| **Total to launch testnet** | **$0** | |
| **Total to launch mainnet MVP** | **~$30–50** | |

---

## 🔑 SECTION A — FREE ACCOUNTS TO OPEN

### A.1 — BLOCKCHAIN

#### 1. Alchemy — FREE
- **URL:** https://alchemy.com
- **Free tier:** 300M compute units/month — more than enough for development
- **Sign up** → Create App → Network: Arbitrum Sepolia
- **Keys:**
  ```
  ALCHEMY_ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
  ALCHEMY_ARB_MAINNET_RPC=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
  ```

#### 2. Arbiscan — FREE
- **URL:** https://arbiscan.io → sign up → API Keys
- **Free tier:** 5 API calls/second — fine for verification
- **Key:**
  ```
  ARBISCAN_API_KEY=YOUR_KEY
  ```

#### 3. Public RPCs as backup (no account needed)
```
# Free public RPCs — slower but cost nothing
ARBITRUM_PUBLIC_RPC=https://arb1.arbitrum.io/rpc
ARBITRUM_SEPOLIA_PUBLIC=https://sepolia-rollup.arbitrum.io/rpc
```

---

### A.2 — ORACLES (All FREE — on-chain, no keys needed)

- **Chainlink:** Read-only on-chain. No account. No key. Free forever.
- **Pyth:** On-chain. No account. No key. Free forever.
- **Redstone:** On-chain. No account. No key. Free forever.

```
# Just paste these addresses — no API keys needed
CHAINLINK_BTC_USD=0x6ce185860a4963106506C203335A2910413708e9
CHAINLINK_ETH_USD=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
CHAINLINK_XAU_USD=0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c
PYTH_CONTRACT_ARBITRUM=0xff1a0f4744e8582DF1aE09D5611b887B6a12925C
```

---

### A.3 — CODE & DEPLOYMENT

#### 4. GitHub — FREE
- **URL:** https://github.com
- **Free tier:** Unlimited public repos, 2,000 CI minutes/month
- **Create organisation:** `baraka-protocol`
- **Create repos:** `baraka-contracts`, `baraka-frontend`, `baraka-docs`
- **Key:**
  ```
  GITHUB_TOKEN=ghp_YOUR_TOKEN  # Settings → Developer Settings → Personal Access Tokens
  ```

#### 5. Deployer Wallet — FREE
- **Download MetaMask:** https://metamask.io (free)
- Create a brand new wallet — ONLY for deploying contracts
- Get free testnet ETH: https://www.alchemy.com/faucets/arbitrum-sepolia
- **Key:**
  ```
  DEPLOYER_PRIVATE_KEY=0x  ← export from MetaMask → Account Details → Export Private Key
  DEPLOYER_ADDRESS=0x
  ```

---

### A.4 — FRONTEND HOSTING

#### 6. Vercel — FREE
- **URL:** https://vercel.com
- **Free tier:** Unlimited hobby deployments, custom domain, HTTPS
- Connect your GitHub `baraka-frontend` repo → auto-deploys on every push
- No credit card needed for free tier

---

### A.5 — DATABASE & CACHING

#### 7. Supabase — FREE
- **URL:** https://supabase.com
- **Free tier:** 500MB database, 2GB bandwidth — fine for MVP
- **Keys:**
  ```
  SUPABASE_URL=https://YOUR_PROJECT.supabase.co
  SUPABASE_ANON_KEY=YOUR_KEY
  SUPABASE_SERVICE_KEY=YOUR_KEY
  ```

#### 8. Upstash Redis — FREE
- **URL:** https://upstash.com
- **Free tier:** 10,000 commands/day — enough for MVP
- **Keys:**
  ```
  UPSTASH_REDIS_URL=rediss://YOUR_URL
  UPSTASH_REDIS_TOKEN=YOUR_TOKEN
  ```

---

### A.6 — INDEXING

#### 9. The Graph Studio — FREE
- **URL:** https://thegraph.com/studio
- **Free tier:** Unlimited subgraph deployments in Studio
- Sign up → Create Subgraph → "baraka-protocol"
- **Key:**
  ```
  THE_GRAPH_DEPLOY_KEY=YOUR_KEY
  ```

---

### A.7 — IPFS (For Fatwa Documents)

#### 10. Pinata — FREE
- **URL:** https://app.pinata.cloud
- **Free tier:** 1GB storage, 100GB bandwidth — easily enough for PDF fatwa docs
- **Keys:**
  ```
  PINATA_JWT=YOUR_JWT
  ```

#### Alternative: web3.storage — FREE
- **URL:** https://web3.storage
- **Free tier:** 5GB — completely free
- Even simpler than Pinata

---

### A.8 — MONITORING (Free alternatives)

#### 11. Tenderly — FREE
- **URL:** https://tenderly.co
- **Free tier:** 1 project, transaction simulation, basic alerts
- More than enough for Phase 1
- **Keys:**
  ```
  TENDERLY_ACCESS_KEY=YOUR_KEY
  TENDERLY_PROJECT=baraka-protocol
  TENDERLY_USERNAME=baraka
  ```

#### 12. UptimeRobot — FREE
- **URL:** https://uptimerobot.com
- **Free tier:** 50 monitors, 5-minute checks, email alerts
- Use to monitor frontend + RPC endpoints
- No API key needed for basic use

---

### A.9 — SECURITY TOOLS (All FREE — local install)

#### 13. Slither — FREE (open source)
```bash
pip3 install slither-analyzer
```

#### 14. Echidna — FREE (open source)
```bash
# Install via Docker (free)
docker pull ghcr.io/crytic/echidna/echidna
```

#### 15. Foundry — FREE (open source)
```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

---

### A.10 — COMMUNICATIONS

#### 16. Discord — FREE
- **URL:** https://discord.com
- Create server: "Baraka Protocol"
- Channels: #announcements, #trading, #shariah-questions, #bug-reports, #dev
- Free. No limits.

#### 17. Twitter/X — FREE
- Create: @BarakaProtocol
- Use for: Launch announcements, funding rate updates, scholar endorsements

#### 18. Telegram — FREE
- Create community group + announcement channel
- Islamic finance community is very active on Telegram

---

### A.11 — MASTER FREE .env FILE

```bash
# ============================================================
# BARAKA PROTOCOL — ENVIRONMENT VARIABLES (FREE TIER)
# NEVER commit this file to GitHub
# ============================================================

# BLOCKCHAIN
ALCHEMY_ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
ALCHEMY_ARB_MAINNET_RPC=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY

# DEPLOYER (NEVER SHARE)
DEPLOYER_PRIVATE_KEY=0x
DEPLOYER_ADDRESS=0x

# BLOCK EXPLORER
ARBISCAN_API_KEY=

# ORACLE ADDRESSES (no keys — read on-chain for free)
CHAINLINK_BTC_USD=0x6ce185860a4963106506C203335A2910413708e9
CHAINLINK_ETH_USD=0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
CHAINLINK_XAU_USD=0x1F954Dc24a49708C26E0C1777f16750B5C6d5a2c
PYTH_CONTRACT_ARBITRUM=0xff1a0f4744e8582DF1aE09D5611b887B6a12925C

# MONITORING
TENDERLY_ACCESS_KEY=
TENDERLY_PROJECT=baraka-protocol
TENDERLY_USERNAME=baraka

# INDEXER
THE_GRAPH_DEPLOY_KEY=

# IPFS
PINATA_JWT=

# DATABASE
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_KEY=

# CACHE
UPSTASH_REDIS_URL=
UPSTASH_REDIS_TOKEN=

# CHAIN IDs
CHAIN_ID_MAINNET=42161
CHAIN_ID_TESTNET=421614
```

---

## 🤖 SECTION B — CLAUDE CODE INSTRUCTIONS (FREE STACK)

### SPRINT 0 — Setup (Day 1, Cost: $0)

**Give Claude Code this prompt:**

```
Set up the Baraka Protocol development environment using only free tools.

Run these commands in order:

# 1. Install Foundry (free, open source)
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge --version

# 2. Install Node.js tools
npm install -g pnpm
pnpm --version

# 3. Install Python security tools
pip3 install slither-analyzer

# 4. Create project
mkdir baraka-protocol && cd baraka-protocol
git init

# 5. Create folder structure
mkdir -p contracts/src/core
mkdir -p contracts/src/shariah  
mkdir -p contracts/src/oracle
mkdir -p contracts/src/insurance
mkdir -p contracts/src/interfaces
mkdir -p contracts/test/unit
mkdir -p contracts/test/integration
mkdir -p contracts/test/invariant
mkdir -p contracts/test/mocks
mkdir -p contracts/script
mkdir -p frontend
mkdir -p subgraph
mkdir -p docs

# 6. Create .gitignore FIRST (before any .env files)
echo ".env
.env.local
.env.*.local
out/
cache/
node_modules/
broadcast/
" > .gitignore

# 7. Copy .env template
cp .env.example .env

# 8. Verify everything works
forge --version && node --version && python3 --version
```

---

### SPRINT 1 — Smart Contracts (Days 2–14, Cost: $0)

#### Task 1.1 — Init Foundry Project

```
In /contracts, run:

forge init --no-commit --force

Install free open-source dependencies:
forge install OpenZeppelin/openzeppelin-contracts --no-commit
forge install OpenZeppelin/openzeppelin-contracts-upgradeable --no-commit
forge install foundry-rs/forge-std --no-commit
forge install smartcontractkit/chainlink-brownie-contracts --no-commit

Create foundry.toml:

[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200

[profile.default.fuzz]
runs = 1000

[rpc_endpoints]
arbitrum_sepolia = "${ALCHEMY_ARBITRUM_SEPOLIA_RPC}"
arbitrum_mainnet = "${ALCHEMY_ARB_MAINNET_RPC}"
localhost = "http://127.0.0.1:8545"

[etherscan]
arbitrum_sepolia = { key = "${ARBISCAN_API_KEY}", url = "https://api-sepolia.arbiscan.io/api" }
arbitrum_mainnet = { key = "${ARBISCAN_API_KEY}", url = "https://api.arbiscan.io/api" }
```

#### Task 1.2 — FundingEngine.sol

```
Write /contracts/src/core/FundingEngine.sol

This is the CORE contract. The most important rule:
ι = 0 ALWAYS. No interest parameter. No floor. Ever.

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title FundingEngine
 * @author Baraka Protocol
 * @notice Implements the Shariah-compliant perpetual futures funding formula.
 *
 * MATHEMATICAL BASIS:
 * Ackerer, Hugonnier & Jermann (2024), "Perpetual futures pricing"
 * Mathematical Finance. Theorem 3 / Proposition 3.
 *
 * Formula: F = P = (mark_price - index_price) / index_price
 *
 * KEY ISLAMIC FINANCE PRINCIPLE:
 * The interest parameter ι = 0 by design. This contract contains
 * NO interest term, NO interest floor, and NO minimum funding rate.
 * This satisfies the no-arbitrage proof with ι=0 from Ackerer et al.
 *
 * CEX formula (REJECTED): F = P + clamp(I - P, -0.05%, +0.05%)
 * Our formula (IMPLEMENTED): F = P only
 */

Full implementation requirements:
- getFundingRate(address market) returns (int256) — pure premium formula
- FUNDING_INTERVAL = 1 hours
- TWAP_WINDOW = 30 minutes  
- Clamp: ±75 bps max (symmetric circuit breaker, NOT an interest floor)
- Uses IOracleAdapter for prices
- OpenZeppelin Ownable2Step, Pausable, ReentrancyGuard
- Full NatSpec on every function
- Events: FundingRateUpdated(market, rate, markPrice, indexPrice, timestamp)

Then write /contracts/test/unit/FundingEngine.t.sol with tests:
- test_FundingRateZeroWhenMarkEqualsIndex()
- test_FundingRatePositiveWhenMarkAboveIndex()  
- test_FundingRateNegativeWhenMarkBelowIndex()
- test_NoInterestFloorExists()
- test_ClampIsSymmetric()
- testFuzz_FundingRateNeverHasInterestFloor(uint256 markPrice, uint256 indexPrice)
```

#### Task 1.3 — ShariahGuard.sol

```
Write /contracts/src/shariah/ShariahGuard.sol

/**
 * @title ShariahGuard  
 * @notice On-chain enforcement of Shariah compliance rules.
 * MAX_LEVERAGE is immutable. Only Shariah board multisig can approve assets.
 */

Requirements:
- uint256 public constant MAX_LEVERAGE = 5; // immutable
- mapping(address => bool) public approvedAssets;
- mapping(address => string) public fatwaIPFS; // IPFS hash of scholar fatwa
- address public shariahMultisig;
- approveAsset(address token, string calldata ipfsHash) onlyShariahMultisig
- revokeAsset(address token, string calldata reason) onlyShariahMultisig
- validatePosition(address asset, uint256 leverage) external view
  → revert if asset not approved OR leverage > 5
- emergencyPause(address market, string calldata reason) onlyShariahMultisig

Write tests in /contracts/test/unit/ShariahGuard.t.sol
```

#### Task 1.4 — OracleAdapter.sol

```
Write /contracts/src/oracle/OracleAdapter.sol

Three oracle sources (all free/on-chain):
1. Chainlink AggregatorV3Interface
2. Pyth IPyth
3. Third source: use Chainlink as backup with slight address variation

Requirements:
- getIndexPrice(address asset) returns (uint256)
  → Check all sources, require 2-of-3 within 0.5% tolerance
  → Reject if price older than 5 minutes (staleness check)
  → Return weighted median: CL 50%, Pyth 50% (simplify to 2 sources for MVP)
- getMarkPrice(address asset, uint256 twapWindow) returns (uint256)
  → Simple TWAP from last N trades recorded on-chain
- Circuit breaker: reject if >20% from last valid price

Write mock oracle in /contracts/test/mocks/MockOracle.sol for testing
Write tests in /contracts/test/unit/OracleAdapter.t.sol
```

#### Task 1.5 — Remaining 5 Contracts

```
Write these 5 contracts. Each should be clean, well-documented, and tested.

1. /contracts/src/core/PositionManager.sol
   - openPosition(market, size, leverage, collateralToken, collateralAmount)
   - closePosition(positionId)
   - settleFunding(market) — apply hourly funding to all positions
   - Struct Position: {id, trader, market, size, leverage, entryPrice, collateral, openTime}
   - Check ShariahGuard before every position open

2. /contracts/src/core/CollateralVault.sol  
   - deposit(token, amount) — only approved tokens
   - withdraw(token, amount) — 24h cooldown
   - lockCollateral / unlockCollateral — called by PositionManager
   - NO rehypothecation

3. /contracts/src/core/LiquidationEngine.sol
   - isLiquidatable(positionId) returns bool (when margin < 2%)
   - liquidate(positionId) — 1% penalty, 50% to InsuranceFund, 50% to caller
   - Partial liquidation before full

4. /contracts/src/insurance/InsuranceFund.sol
   - receiveFromLiquidation() — called by LiquidationEngine
   - coverShortfall(amount) — called by PositionManager when liquidation insufficient
   - NO yield on reserves (avoids riba)
   - NatSpec: "This is the seed of Layer 3 Takaful protocol"

5. /contracts/src/shariah/GovernanceModule.sol
   - Two-track: technical DAO (token vote) + Shariah board (multisig)
   - Shariah board cannot be overridden by DAO
   - 48-hour timelock on all changes

Write tests for all 5 in /contracts/test/unit/
```

#### Task 1.6 — Deploy Script

```
Write /contracts/script/Deploy.s.sol

Deploy order:
1. MockOracle (testnet only) or OracleAdapter (mainnet)
2. ShariahGuard(_shariahMultisig)
3. InsuranceFund()
4. FundingEngine(oracleAdapter)
5. CollateralVault(shariahGuard)
6. LiquidationEngine(insuranceFund)
7. PositionManager(fundingEngine, shariahGuard, collateralVault, liquidationEngine)

Post-deploy config:
- Call shariahGuard.approveAsset(USDC_TESTNET, "ipfs://placeholder")
- Call shariahGuard.approveAsset(PAXG_TESTNET, "ipfs://placeholder")
- Log all addresses

Save to /contracts/deployments/{chainId}.json
```

---

### SPRINT 2 — Testing (Days 15–21, Cost: $0)

```
Give Claude Code this:

Run all tests and fix everything until they pass:

# Run unit tests
forge test --match-path "test/unit/*" -vvv

# Run with gas reporting
forge test --gas-report

# Run coverage (want >90%)
forge coverage

# Run static analysis (free)
slither contracts/src/ --print human-summary

# Fix all HIGH and MEDIUM slither findings
# Document LOW findings with justification

# Deploy to free testnet
forge script script/Deploy.s.sol \
  --rpc-url $ALCHEMY_ARBITRUM_SEPOLIA_RPC \
  --broadcast \
  --verify \
  -vvvv

# Verify contracts (free on Arbiscan)
forge verify-contract <FUNDING_ENGINE_ADDRESS> \
  src/core/FundingEngine.sol:FundingEngine \
  --chain arbitrum-sepolia \
  --etherscan-api-key $ARBISCAN_API_KEY
```

---

### SPRINT 3 — Frontend (Days 22–35, Cost: $0)

#### Task 3.1 — Setup

```
In /frontend:

pnpm create next-app@latest . --typescript --tailwind --eslint --app

pnpm add wagmi viem @rainbow-me/rainbowkit @tanstack/react-query
pnpm add recharts lightweight-charts
pnpm add lucide-react
pnpm add @radix-ui/react-dialog @radix-ui/react-tabs @radix-ui/react-slider

# All free packages. No paid libraries.
```

#### Task 3.2 — Pages to Build

```
Build these pages:

1. / — Homepage
   - Baraka branding: crescent + geometric Islamic pattern (CSS only, no paid assets)
   - Arabic: بَرَكَة  in large calligraphy-style CSS font
   - Tagline: "The world's first mathematically-proven halal perpetuals"  
   - Live stats: current κ value, total open interest, 24h volume
   - "How it works" — 3 steps: Connect → Deposit → Trade
   - Scholar endorsement placeholder
   - Connect Wallet button (RainbowKit)

2. /trade — Trading interface
   - Price chart (lightweight-charts — FREE TradingView alternative)
   - Long/Short toggle
   - Size input
   - Leverage slider (hard max 5x — cannot exceed)
   - Funding rate display (live, from contract)
   - Shariah badge: "ι = 0 | No Interest" in green

3. /transparency — The Shariah proof page (KEY DIFFERENTIATOR)
   Display live:
   - Mark price (from oracle)
   - Index price (from oracle)  
   - Funding rate = (mark - index) / index [with real numbers]
   - ι = 0.000% [highlighted green]
   - CEX comparison: Binance ι = 0.010%/8h [red]
   - Link to Ackerer et al. (2024) paper
   - Fatwa IPFS link (when available)

4. /markets — Market list
   - BTC-USDC, ETH-USDC, PAXG-USDC
   - Current funding rate, OI, volume
   - Shariah status badge

All styling: Tailwind only (free). 
Color scheme: Deep green (#1B4332) + Gold (#D4AF37) + White
Islamic geometric pattern: CSS-only SVG background
```

#### Task 3.3 — Contract Hooks

```
Write /frontend/hooks/:

useContractAddresses.ts — returns deployed contract addresses by chainId
useFundingRate.ts — reads from FundingEngine every 60 seconds  
useKappa.ts — calculates κ from basis and funding frequency
usePosition.ts — reads user's open positions
useOpenPosition.ts — mutation to open position
useClosePosition.ts — mutation to close position
useCollateralBalance.ts — reads collateral balance
useDeposit.ts — mutation to deposit
useWithdraw.ts — mutation to withdraw

All use wagmi hooks (free). No paid data providers.
```

---

### SPRINT 4 — Subgraph (Days 36–40, Cost: $0)

```
In /subgraph:

npm install -g @graphprotocol/graph-cli
graph init --studio baraka-protocol --from-contract <FUNDING_ENGINE_ADDRESS> --network arbitrum-sepolia

Write schema.graphql:
- Position (id, trader, market, size, leverage, entryPrice, status, openTimestamp)
- FundingRate (id, market, rate, markPrice, indexPrice, timestamp, kappa)
- Trade (id, trader, market, action, size, price, timestamp)
- Market (id, totalVolume, openInterest, currentFundingRate)

Write mappings for every contract event.

graph codegen && graph build
graph deploy baraka-protocol --studio

Free on The Graph Studio. No cost.
```

---

### SPRINT 5 — CI/CD (Days 41–45, Cost: $0)

#### GitHub Actions — FREE

```
Create /.github/workflows/ci.yml

name: Baraka CI

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest   # FREE on GitHub
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: recursive
      
      - name: Install Foundry
        uses: foundry-rs/foundry-toolchain@v1
      
      - name: Run tests
        run: cd contracts && forge test -vvv
      
      - name: Check coverage
        run: cd contracts && forge coverage
      
      - name: Run Slither
        run: |
          pip install slither-analyzer
          slither contracts/src/ --print human-summary

  frontend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '20'
      - run: cd frontend && pnpm install && pnpm build

2,000 free CI minutes/month on GitHub — more than enough.
```

#### Vercel Auto-Deploy — FREE

```
Connect baraka-frontend GitHub repo to Vercel.
Every push to main auto-deploys.
Free custom domain support.
Free HTTPS.
Zero config needed beyond connecting the repo.
```

#### Simple Monitoring Script — FREE

```
Create /scripts/monitor.js (runs on your local machine or free server)

Every 5 minutes, check:
1. Oracle price freshness (call contract directly via RPC — free)
2. Insurance fund balance (call contract — free)  
3. Frontend up (HTTP ping — free)

Alert via: free Discord webhook
  → Create Discord channel #alerts
  → Settings → Integrations → Webhooks → copy URL
  → Post to webhook when anything is wrong

DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/YOUR_WEBHOOK
```

---

### SPRINT 6 — Testnet Launch (Days 46–60, Cost: $0)

```
Final checklist before testnet goes public:

Contracts (all on free Arbitrum Sepolia):
[ ] All 8 contracts deployed and verified
[ ] Test all core flows manually with your own wallet
[ ] Run full test suite one more time: forge test -vvv

Frontend (free Vercel hosting):
[ ] Deployed to Vercel
[ ] baraka-protocol.vercel.app working
[ ] All 4 pages load
[ ] Wallet connects on Arbitrum Sepolia
[ ] Can deposit test USDC, open position, close position

Community (all free):
[ ] Discord server live with 3 channels minimum
[ ] Twitter @BarakaProtocol created
[ ] Post testnet announcement:
    "Baraka Protocol testnet is live.
     World's first mathematically-proven halal perpetuals.
     ι = 0. Always. By proof.
     Try it: [link]"

[ ] Share in Islamic finance communities:
    - IslamicFinanceGuru community
    - Muslim DeFi Telegram groups  
    - LinkedIn Islamic finance groups
    - Reddit r/IslamicFinance
```

---

## 📋 SECTION C — WHAT TO DO IN ORDER TODAY

If you're starting right now, do this exact sequence:

```
Hour 1 — Open free accounts (do all at once):
  1. alchemy.com — sign up, create Arbitrum app, copy RPC URL
  2. arbiscan.io — sign up, get API key
  3. github.com — create baraka-protocol organisation, create repos
  4. vercel.com — sign up, connect to GitHub
  5. supabase.com — sign up, create project, copy keys
  6. upstash.com — sign up, create Redis, copy keys
  7. thegraph.com/studio — sign up, create subgraph
  8. pinata.cloud — sign up, get JWT
  9. tenderly.co — sign up, get key
  10. discord.com — create Baraka Protocol server

Hour 2 — Set up deployer wallet:
  1. Download MetaMask
  2. Create NEW wallet (not your personal one)
  3. Export private key → save in password manager
  4. Go to https://www.alchemy.com/faucets/arbitrum-sepolia
  5. Get free test ETH sent to your new wallet

Hour 3 — Give Claude Code the Sprint 0 prompt
  → Environment setup
  → Folder structure
  → .gitignore
  → .env template with your real keys pasted in

Then work through Sprints 1–6 day by day.
```

---

## ⚡ SECTION D — QUICK REFERENCE

```bash
# Free local blockchain for testing (no gas cost)
anvil

# Compile
forge build

# Test (free, runs locally)
forge test -vvv

# Deploy to free testnet
forge script script/Deploy.s.sol --rpc-url $ALCHEMY_ARBITRUM_SEPOLIA_RPC --broadcast --verify

# Check your balance on testnet (free)
cast balance $DEPLOYER_ADDRESS --rpc-url $ALCHEMY_ARBITRUM_SEPOLIA_RPC

# Read live funding rate from deployed contract (free)
cast call $FUNDING_ENGINE_ADDRESS "getFundingRate(address)(int256)" $BTC_MARKET --rpc-url $ALCHEMY_ARBITRUM_SEPOLIA_RPC

# Start frontend locally (free)
cd frontend && pnpm dev

# Run slither (free)
slither contracts/src/

# Deploy subgraph (free)
cd subgraph && graph deploy baraka-protocol --studio
```

---

## 🚀 WHEN YOU'RE READY TO PAY (Phase 3 Only)

Only spend money when you're ready to go mainnet:

| Item | Cost | Notes |
|---|---|---|
| Mainnet deploy gas | ~$30 one-time | 8 contracts on Arbitrum |
| Domain: baraka.finance | ~$15/year | Namecheap or Porkbun |
| That's it | | Everything else stays free |

**Upgrade only if you hit limits:**
- Alchemy free tier runs out → upgrade to $49/month Growth plan
- The Graph free tier runs out → pay per query (~$0.0001 each)
- Supabase hits 500MB → upgrade to $25/month Pro

None of these will happen until you have significant traffic. By then you'll have revenue to cover it.

---

*Baraka Protocol — Built for the Ummah, Built on Truth*  
*بَرَكَة — May Allah bless this work*
