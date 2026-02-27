# BARAKA PROTOCOL — BUILD CHECKLIST
**Last Updated:** February 27, 2026 (Session 11)
**Status Legend:** `[ ]` = Not started · `[~]` = In progress · `[x]` = Complete · `[-]` = Deferred to v2

---

## QUICK REFERENCE — WHERE WE ARE

| Phase | Status | URL / Notes |
|---|---|---|
| Smart Contracts (9) | ✅ Complete | 8 core + BRKXToken, all deployed + verified Arbitrum Sepolia |
| Tests | ✅ 93/93 | +15 KappaSignal unit tests (premium/regime/kappa/fuzz), 1000 runs each |
| Slither | ✅ Clean | HIGH 0, MEDIUM 0 |
| Testnet Deploy | ✅ Live | All 9 contracts on chain 421614 |
| BRKX Token + Fee System | ✅ Live | PositionManager v2 + BRKXToken deployed + verified |
| Frontend | ✅ Live | https://baraka.arcusquantfund.com |
| Subgraph | ✅ Live | https://thegraph.com/studio/subgraph/arcus |
| CI Pipeline | ✅ Active | .github/workflows/ci.yml (4 jobs) |
| Custom Domain | ✅ Live | baraka.arcusquantfund.com (HTTP/2 + SSL) |
| arcusquantfund.com /dapp | ✅ Updated | 9 contracts, 3 papers, IES simulation, BRKX, GitHub link |
| Automated E2E (fork) | ✅ 6/6 | `bash e2e.sh` — 20s, zero gas |
| Paper 1 (ι=0 Shariah Perpetuals) | ✅ Complete | `papers/paper1/` — 16pp, 6 figures, PDF compiled |
| Paper 2 (Credit Equivalence) | ✅ Complete | `papers/paper2/` — 11pp incl. Section 8 simulation validation |
| Paper 3 (IES Framework) | ✅ Complete | `papers/paper3/` — 8pp cadCAD+RL+GT+MD |
| Integrated IES Simulation | ✅ Complete | 5 ep × 720 steps · 0/5 insolvency · MD converged |
| GitHub Public Repo | ✅ Live | https://github.com/Arcus-Quant-Fund/BarakaDapp |
| κ-signal oracle (OracleAdapter) | ✅ Complete | getPremium + getKappaSignal + KappaAlert event + 15 tests |
| BRKX E2E smoke script | ✅ Complete | `script/BRKXSmoke.s.sol` — 6 on-chain assertions, tier3 verified |
| **Next session starts here →** | ⏳ | Pinata JWT + fatwa IPFS upload → GovernanceModule.setFatwaURI() |

---

## PHASE 0 — ENVIRONMENT & KEYS

### API Keys (all collected)
- [x] Alchemy Arbitrum Sepolia RPC — `https://arb-sepolia.g.alchemy.com/v2/<ALCHEMY_KEY>`
- [x] Alchemy Arbitrum Mainnet RPC — `https://arb-mainnet.g.alchemy.com/v2/<ALCHEMY_KEY>`
- [x] Arbiscan API key — `<ARBISCAN_KEY>` (Etherscan V2, covers chain 421614 + 42161)
- [x] Alchemy ETH Mainnet + Infura fallback + Ankr archive
- [x] CoinGecko, Tenderly, Binance, Uniswap API keys — in `BarakaDapp/.env`
- [x] The Graph API key — `83984585a228ad2b12fc7325458dd5e7` (query key)
- [x] The Graph deploy key — `<GRAPH_DEPLOY_KEY>` (Studio slug: arcus)
- [x] Deployer wallet — `0x12A21D0D172265A520aF286F856B5aF628e66D46` (testnet only)
- [ ] Pinata JWT — needed for fatwa IPFS upload (get at pinata.cloud)
- [ ] Testnet ETH top-up if needed (faucet: faucet.triangleplatform.com/arbitrum/sepolia)

### Tooling (all installed)
- [x] Foundry 1.5.1-stable (`forge`, `cast`, `anvil`) — `~/.foundry/bin/`
- [x] Node.js (npm works) — confirmed via subgraph + frontend builds
- [x] Slither — `/opt/anaconda3/bin/slither` — run with `export PATH="$HOME/.foundry/bin:$PATH"`
- [x] graph-cli — installed in `subgraph/node_modules`

### Files (all exist)
- [x] `BarakaDapp/.env` — all keys, NEVER commit
- [x] `BarakaDapp/frontend/.env.local` — `NEXT_PUBLIC_SUBGRAPH_URL` set
- [x] `BarakaDapp/contracts/deployments/421614.json` — all 8 deployed addresses
- [x] `.gitignore` — covers `.env`, `out/`, `cache/`, `broadcast/`, `.env.local`

---

## PHASE 1 — SMART CONTRACTS

### All 8 Contracts (written, compiling, deployed, verified)
- [x] `FundingEngine.sol` — F = (mark−index)/index, ι=0, ±75bps circuit breaker
- [x] `ShariahGuard.sol` — MAX_LEVERAGE=5 constant, asset whitelist, scholar multisig
- [x] `OracleAdapter.sol` — dual Chainlink 60/40, staleness 5min, circuit breaker 20%, `snapshotPrice()` keeper
- [x] `PositionManager.sol` — isolated margin, bytes32 positionId, CEI pattern, ShariahGuard gate
- [x] `CollateralVault.sol` — USDC/PAXG/XAUT, 24h cooldown, no rehypothecation
- [x] `LiquidationEngine.sol` — 2% maintenance margin, 1% penalty (50/50 split)
- [x] `InsuranceFund.sol` — no yield, surplus distribution, Takaful seed note
- [x] `GovernanceModule.sol` — dual-track DAO + Shariah multisig, 48h timelock

### Interfaces (6 written, 1 deferred)
- [x] `IFundingEngine.sol`, `IShariahGuard.sol`, `IOracleAdapter.sol`
- [x] `ICollateralVault.sol`, `ILiquidationEngine.sol`, `IInsuranceFund.sol`
- [-] `IPositionManager.sol` — deferred, no external consumer in MVP

### Deployed Addresses — Arbitrum Sepolia (chainId 421614)
| Contract | Address | Notes |
|---|---|---|
| OracleAdapter | `0xB8d9778288B96ee5a9d873F222923C0671fc38D4` | v1, unchanged |
| ShariahGuard | `0x26d4db76a95DBf945ac14127a23Cd4861DA42e69` | v1, unchanged |
| FundingEngine | `0x459BE882BC8736e92AA4589D1b143e775b114b38` | v1, unchanged |
| InsuranceFund | `0x7B440af63D5fa5592E53310ce914A21513C1a716` | v1, unchanged |
| CollateralVault | `0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E` | v1, unchanged |
| LiquidationEngine | `0x456eBE7BbCb099E75986307E4105A652c108b608` | v1, unchanged |
| PositionManager | `0x787E15807f32f84aC3D929CB136216897b788070` | **v2 — BRKX fee system** |
| GovernanceModule | `0x8c987818dffcD00c000Fe161BFbbD414B0529341` | v1, unchanged |
| BRKXToken | `0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32` | **NEW — 100M BRKX** |
| PositionManager v1 (legacy) | `0x53E3063FE2194c2DAe30C36420A01A8573B150bC` | deauthorized |

### Testing
- [x] Unit tests — `FundingEngine.t.sol` (14/14) + `ShariahGuard.t.sol` (16/16)
- [x] Integration tests — `BarakaIntegration.t.sol` (30/30)
  - [x] Full lifecycle: deposit → open → settle → close → withdraw
  - [x] Liquidation flow: funding erodes collateral → liquidate → split
  - [x] Shariah gate: unapproved asset, leverage > 5, emergency pause
  - [x] Emergency controls: Shariah pause, PM pause, FundingEngine pause
  - [x] Collateral vault cooldown: enforce + bypass on protocol pause
  - [x] Total loss scenario: short, price +50%
  - [x] PnL calculation: unrealised, negative, zero after close
  - [x] Fuzz: leverage > 5 always reverts (1000 runs)
  - [x] Fuzz: valid positions always open (1000 runs)
- [x] Slither: **HIGH 0, MEDIUM 0** — Feb 26 2026
  - [x] HIGH fixed: `OracleAdapter.lastValidPrice` never written → added `snapshotPrice()` keeper
  - [x] MEDIUM fixed: divide-before-multiply, 2× incorrect-equality, reentrancy CEI restructure, 3× uninitialized-local, unused-return
- [ ] Unit tests for OracleAdapter, CollateralVault, LiquidationEngine, InsuranceFund, GovernanceModule *(Phase 2 priority before mainnet)*
- [ ] `forge coverage` >= 90% *(Phase 2 priority)*
- [ ] Invariant test: ι=0 never violated *(Phase 2)*
- [ ] Invariant test: leverage > 5 never possible *(Phase 2)*
- [ ] Integration test: oracle failover (Chainlink staleness, circuit breaker) *(Phase 2)*

### Simulations — 22/22 checks pass
- [x] cadCAD Monte Carlo — 0% insolvency across 5 runs × 200 steps
- [x] RL trader (Gymnasium + PPO/SB3 framework)
- [x] Game theory — ι=0 Nash equilibrium, net_transfer ≈ 0
- [x] Mechanism design — scipy differential_evolution, params in Pareto-optimal region
- [x] Stress tests — flash_crash, funding_spiral, oracle_attack, gradual_bear, insurance_stress (all solvent)

---

## PHASE 2 — FRONTEND

### Stack
- [x] Next.js 16.1.6, TypeScript, Tailwind, App Router
- [x] wagmi@2.19.5 (PINNED — RainbowKit 2.x requires wagmi ^2.9.0; v3 breaks it)
- [x] viem, @rainbow-me/rainbowkit@2.2.10
- [x] lightweight-charts@5.1.0 — use `chart.addSeries(CandlestickSeries, opts)` NOT `addCandlestickSeries`
- [x] @tanstack/react-query

### Pages (5/5 routes, all static prerendered)
- [x] `/` — Homepage (hero, live stats, formula callout, features)
- [x] `/trade` — Trading interface (chart, FundingRateDisplay, OrderPanel, DepositPanel, PositionTable, ShariahPanel)
- [x] `/markets` — Market overview (BTC-PERP live, ETH/PAXG pending approval)
- [x] `/transparency` — Shariah proof (live on-chain formula, math, all 8 contracts with Arbiscan links)

### Components (all built + correct)
- [x] `Navbar.tsx` — sticky, RainbowKit connect button, active route
- [x] `FundingRateDisplay.tsx` — live from FundingEngine (poll 15s)
- [x] `OrderPanel.tsx` — long/short, collateral input, leverage slider max 5×, `openPosition(asset, collateralToken, collateral, leverage, isLong)`
- [x] `PriceChart.tsx` — lightweight-charts v5 candlestick, CoinGecko 7-day OHLCV
- [x] `ShariahPanel.tsx` — live ι=0 proof vs CEX, computed F vs on-chain F
- [x] `DepositPanel.tsx` — ERC20 approve → deposit 2-step, withdraw tab
- [x] `PositionTable.tsx` — bytes32 positionId, close button, unrealised PnL

### Hooks (all corrected to match deployed contracts)
- [x] `useFundingRate.ts` — `getFundingRate(BTC_ASSET_ADDRESS)`, scale: `/ 1e18`
- [x] `useOraclePrices.ts` — `getMarkPrice(asset, twapWindow)`, `getIndexPrice(asset)`, scale: `/ 1e18`
- [x] `useInsuranceFund.ts` — `fundBalance(USDC_ADDRESS)`, not `balance()`
- [x] `usePositions.ts` — **dual mode**: subgraph GraphQL (when `NEXT_PUBLIC_SUBGRAPH_URL` set) → fallback getLogs+multicall
- [x] `useCollateralBalance.ts` — `balance(user, token)` + `freeBalance(user, token)`
- [x] `useDeposit.ts` / `useWithdraw.ts` — vault approve → deposit, withdraw

### Key ABI Facts (CRITICAL — do not change)
- `openPosition` args: `(address asset, address collateralToken, uint256 collateral, uint256 leverage, bool isLong)` → returns `bytes32`
- `getPosition` / `closePosition` use `bytes32` (NOT `uint256`)
- All prices: `1e18` scale (OracleAdapter normalises Chainlink 8-dec to 18-dec)
- Funding rate: `int256` in `1e18` scale (MAX_FUNDING_RATE = 75e14 = 0.75%)
- USDC: 6 decimals for collateral/size amounts
- `BTC_ASSET_ADDRESS` = WBTC address (used as market key)
- `TWAP_WINDOW` = `1800n` (30 minutes)

### Deployment
- [x] **Live URL:** https://baraka.arcusquantfund.com (custom domain, HTTP/2 + SSL)
- [x] Vercel project: `shehzadahmed-xxs-projects/frontend`
- [x] Vercel token: `<VERCEL_TOKEN>`
- [x] Deploy cmd: `npx vercel deploy --prod --token <token> --scope shehzadahmed-xxs-projects -e NEXT_PUBLIC_SUBGRAPH_URL="<url>"`
- [x] `NEXT_PUBLIC_SUBGRAPH_URL` set in Vercel env vars (subgraph GraphQL mode active)
- [x] `frontend/.env.local` — local dev env (not committed)

---

## PHASE 3 — SUBGRAPH & DEVOPS

### The Graph Subgraph
- [x] `subgraph/schema.graphql` — 9 entities: Position, Trade, FundingSettlement, FundingRateSnapshot, DepositEvent, WithdrawEvent, LiquidationEvent, MarketStats, Protocol
- [x] `subgraph/subgraph.yaml` — 4 data sources (PositionManager, FundingEngine, CollateralVault, LiquidationEngine), network: arbitrum-sepolia
- [x] `subgraph/abis/` — 4 minimal event-only ABIs
- [x] `subgraph/src/position-manager.ts` — handlePositionOpened, handlePositionClosed, handleFundingSettled
- [x] `subgraph/src/funding-engine.ts` — handleFundingRateUpdated
- [x] `subgraph/src/collateral-vault.ts` — handleDeposited, handleWithdrawn
- [x] `subgraph/src/liquidation-engine.ts` — handleLiquidated
- [x] `graph codegen` — clean, zero errors
- [x] `graph build` — 4 WASM modules compiled, zero errors
- [x] **Deployed to Graph Studio** — https://thegraph.com/studio/subgraph/arcus (slug: arcus, v0.0.1)
- [x] **Query endpoint live** — `https://api.studio.thegraph.com/query/1742812/arcus/v0.0.1`
- [x] Redeploy cmd: `cd subgraph && npx graph auth <GRAPH_DEPLOY_KEY> && npx graph deploy arcus --version-label vX.X.X`

### Custom Domain
- [x] `baraka.arcusquantfund.com` → Baraka Vercel project (frontend)
- [x] DNS A record: `baraka` → `76.76.21.21` (set Feb 26 2026)
- [x] SSL certificate issued by Vercel — HTTP/2 200 confirmed
- [x] arcusquantfund.com `/dapp` page — "Launch App ↗" buttons pointing to baraka.arcusquantfund.com
- [x] arcusquantfund.com Navbar — "Launch App ↗" button (desktop + mobile)

### CI / DevOps
- [x] `.github/workflows/ci.yml` — 4 jobs:
  - `contracts`: forge build + forge test (60/60) on every PR
  - `slither`: fails if any HIGH or MEDIUM introduced (`--fail-high --fail-medium`)
  - `frontend`: `npm ci && npm run build` (5/5 routes)
  - `subgraph`: `npm run codegen && npm run build` (4 WASM modules)
- [ ] Vercel auto-deploy — connect GitHub repo to Vercel project (push main = deploy)
- [ ] Discord webhook monitoring

---

## PHASE 2.5 — BRKX TOKEN + FEE SYSTEM

### Contracts (deployed + verified Feb 27 2026)
- [x] `src/token/BRKXToken.sol` — ERC20+ERC20Votes+ERC20Permit+Ownable2Step, 100M fixed supply
- [x] `src/interfaces/IPositionManager.sol` — minimal interface for setBrkxToken/setTreasury
- [x] `src/core/CollateralVault.sol` — added `chargeFromFree()` for fee deduction from free balance
- [x] `src/interfaces/ICollateralVault.sol` — added `chargeFromFree` signature
- [x] `src/core/PositionManager.sol` — v2: 7-arg constructor, `_collectFee()`, `setBrkxToken()`, `setTreasury()`
- [x] `script/UpgradeAndDeployBRKX.s.sol` — upgrade PM + deploy BRKX + rewire all dependencies
- [x] BRKXToken verified on Arbiscan: `0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32`
- [x] PositionManager v2 verified on Arbiscan: `0x787E15807f32f84aC3D929CB136216897b788070`

### Tests (78/78 passing)
- [x] `test/unit/BRKXToken.t.sol` — 10/10 (supply, transfer, approve, burn, ERC20Votes, ERC20Permit, Ownable2Step, fuzz)
- [x] `test/unit/PositionManagerFee.t.sol` — 8/8 (all 4 tiers, disabled mode, InsuranceFund split, treasury split, event)
- [x] `test/integration/BarakaIntegration.t.sol` — 30/30 (updated for 7-arg PM constructor)

### Fee tier table (hold-based, no lock-up)
| BRKX held | Fee rate | Saving |
|---|---|---|
| < 1,000 | 5.0 bps | — |
| ≥ 1,000 | 4.0 bps | −20% |
| ≥ 10,000 | 3.5 bps | −30% |
| ≥ 50,000 | 2.5 bps | −50% |

Revenue split: 50% → InsuranceFund / 50% → Treasury

### Pending
- [ ] E2E test on live Sepolia — open position, confirm `FeeCollected` event fires at correct bps
- [ ] Distribute BRKX to test wallets for fee tier testing (from deployer wallet holding all 100M)
- [ ] Frontend: add BRKX balance display + fee tier indicator to OrderPanel

---

## PHASE 4 — TESTNET LAUNCH

- [x] All 8 contracts deployed + verified — Arbitrum Sepolia (Feb 25 2026)
- [x] PositionManager v2 + BRKXToken deployed + verified (Feb 27 2026)
- [x] Frontend live — https://baraka.arcusquantfund.com (Feb 26 2026)
- [x] Subgraph live — indexing all events (Feb 26 2026)
- [x] **Automated E2E test** — `bash e2e.sh` — forks Arbitrum Sepolia, 6/6 pass in ~20s, zero gas
  - `contracts/test/e2e/E2EForkTest.t.sol` — lifecycle, funding flow, liquidation, Shariah guard, cooldown
  - MockFeed swapped in for live Chainlink to control prices + timestamps
  - Auto-unpauses all contracts if left paused on testnet
- [ ] **Pinata JWT** — get at pinata.cloud → upload `fatwa_placeholder.pdf` → store IPFS hash
- [ ] Discord server (#announcements #trading #shariah-questions #dev)
- [ ] Twitter / X account @BarakaProtocol
- [ ] Testnet public announcement (Discord + Twitter)
- [ ] Shariah scholar outreach — AAOIFI contacts, Dr. Bhuyan's academic network
- [ ] Bug bounty scope document

---

## PHASE 6 — RESEARCH PAPERS

### Paper 1 — Interest Parameter in Perpetual Futures (Shariah + Empirical)
- [x] Written — `latest.tex`
- [x] Authors: Ahmed, Bhuyan, Islam
- [ ] Submit to Islamic Economic Studies (IRTI/IsDB) or JKAU: Islamic Economics
- [ ] Preprint on SSRN

### Paper 2 — Random Stopping Time ≡ Credit Event (Riba-Free Credit Pricing)
- [x] Conceived — see PLAN.md §PAPER ROADMAP
- [x] Written — `paper2_credit.tex` (Feb 27 2026)
- [ ] Submit to Journal of Banking & Finance or Mathematical Finance
- [ ] Preprint on SSRN / arXiv (q-fin.GN)
- [ ] Share with AAOIFI for fatwa process input

### Paper 3 — κ-Rate as Islamic Monetary Alternative (planned)
- [ ] Draft outline
- [ ] Target: Journal of Economic Theory / Review of Financial Studies

### Paper 4 — Empirical Baraka Protocol (post-mainnet)
- [ ] After live trading data exists on mainnet

---

## PHASE 5 — PRE-MAINNET (future)

### Additional Tests (before mainnet)
- [ ] Unit tests for OracleAdapter, CollateralVault, LiquidationEngine, InsuranceFund, GovernanceModule
- [ ] `forge coverage` >= 90%
- [ ] Invariant tests: ι=0 never violated, leverage never > 5
- [ ] Integration test: oracle failover (staleness, circuit breaker trigger)

### Security
- [ ] External audit (Certik / OpenZeppelin / Trail of Bits)
- [ ] Audit findings remediated + re-tested

### Shariah Compliance
- [ ] Pinata JWT — get at pinata.cloud → upload fatwa document → store IPFS hash on-chain
- [ ] Fatwa obtained from AAOIFI-certified scholars
- [ ] Fatwa IPFS hash stored in ShariahGuard.fatwaIPFS mapping

### Infrastructure
- [ ] Mainnet deployer wallet (separate from testnet)
- [ ] GRT tokens for subgraph publication on The Graph Network (decentralized)
- [ ] Mainnet Chainlink feed addresses confirmed

---

## LEGAL & COMPLIANCE

- [ ] Dubai LLC formation (Dr. Bhuyan handling per MOU)
- [ ] US LLC formation (Dr. Bhuyan handling per MOU)
- [ ] Shariah board consultant identified + contracted
- [ ] Fatwa process initiated for funding formula + leverage + asset list

---

## KEY COMMANDS (copy-paste reference)

```bash
# Run automated E2E fork test (6 scenarios, ~20s, zero gas)
bash /Users/shehzad/Desktop/BarakaDapp/e2e.sh

# Run all unit + integration tests
cd /Users/shehzad/Desktop/BarakaDapp/contracts
export PATH="$HOME/.foundry/bin:$PATH"
forge test -vvv

# Run Slither
/opt/anaconda3/bin/slither . --exclude-dependencies --fail-high --fail-medium

# Deploy frontend to Vercel
cd /Users/shehzad/Desktop/BarakaDapp/frontend
npx vercel deploy --prod \
  --token <VERCEL_TOKEN> \
  --scope shehzadahmed-xxs-projects \
  -e NEXT_PUBLIC_SUBGRAPH_URL="https://api.studio.thegraph.com/query/1742812/arcus/v0.0.1"

# Deploy Arcus website to Vercel
cd /Users/shehzad/Desktop/ArcusQuantFund/website
npx vercel deploy --prod \
  --token <VERCEL_TOKEN> \
  --scope shehzadahmed-xxs-projects

# Redeploy subgraph (after changes)
cd /Users/shehzad/Desktop/BarakaDapp/subgraph
npx graph auth <GRAPH_DEPLOY_KEY>
npm run codegen && npm run build
npx graph deploy arcus --version-label v0.0.2
```

---

*Checklist Version 2.1 — February 26, 2026 — Updated after Session 9 (automated E2E)*
