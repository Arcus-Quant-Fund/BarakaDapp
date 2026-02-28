# BARAKA PROTOCOL — BUILD CHECKLIST
**Last Updated:** February 27, 2026 (Session 12)
**Status Legend:** `[ ]` = Not started · `[~]` = In progress · `[x]` = Complete · `[-]` = Deferred to v2

---

## QUICK REFERENCE — WHERE WE ARE

| Phase | Status | URL / Notes |
|---|---|---|
| Smart Contracts (12) | ✅ Complete | 8 core + BRKXToken + EverlastingOption + TakafulPool + PerpetualSukuk + iCDS |
| Tests | ✅ 177/177 | +84 new: EverlastingOption (33) + TakafulPool (16) + PerpetualSukuk (16) + iCDS (19) |
| Slither | ✅ Clean | HIGH 0, MEDIUM 0 |
| Testnet Deploy | ✅ Live | All 9 contracts on chain 421614 |
| BRKX Token + Fee System | ✅ Live | PM v3 + CollateralVault v2 + OracleAdapter v2 + LiqEngine v2 redeployed |
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
| On-chain Redeploy + Smoke | ✅ Complete | `script/RedeployAndSmoke.s.sol` — 4 contracts redeployed, smoke test broadcast verified |
| Frontend BRKX tier + fee display | ✅ Live | `useBrkxTier` + `useKappaSignal` hooks; OrderPanel fee row + tier badge deployed Feb 28 |
| Paper 3 stochastic κ appendix | ✅ Complete | CIR-κ SDE, Feller lemma, κ-bond theorem, κ-yield curve — 11pp clean PDF |
| EverlastingOption.sol | ✅ Complete | Ackerer Prop 6 at ι=0; inline lnWad+expWad; 33/33 tests pass (unit+fuzz) |
| TakafulPool.sol (Layer 3) | ✅ Complete | Mutual takaful insurance; wakala 10%; put-priced tabarru; 16/16 tests |
| PerpetualSukuk.sol (Layer 2) | ✅ Complete | Islamic capital market instrument; par+embedded call at maturity; 16/16 tests |
| iCDS.sol (Layer 4) | ✅ Complete | Islamic Credit Default Swap; quarterly put-priced premium; LGD settlement; 19/19 tests + 1k fuzz |
| IEverlastingOption.sol interface | ✅ Complete | quotePut/quoteCall/quoteAtSpot/getExponents — used by all Layer 2/3/4 |
| Product Stack Deploy (L1.5/L2/L3/L4) | ✅ Live | EverlastingOption + TakafulPool + PerpetualSukuk + iCDS on Arbitrum Sepolia |
| Frontend Product Pages | ✅ Live | /sukuk /takaful /credit /dashboard — baraka.arcusquantfund.com |
| Pinata JWT | ✅ Obtained | `bb023190f5171bdf5884` — stored in BarakaDapp/.env |
| **Next session starts here →** | ⏳ | Upload fatwa_placeholder.pdf to Pinata → GovernanceModule.setFatwaURI(cid) |

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
- [x] Pinata JWT — `bb023190f5171bdf5884` (API Key) — stored in `BarakaDapp/.env` — Feb 28 2026
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
| OracleAdapter | `0x86C475d9943ABC61870C6F19A7e743B134e1b563` | **v2 — kappa signal, redeployed Feb 27** |
| ShariahGuard | `0x26d4db76a95DBf945ac14127a23Cd4861DA42e69` | v1, unchanged |
| FundingEngine | `0x459BE882BC8736e92AA4589D1b143e775b114b38` | v1, setOracle() updated to v2 |
| InsuranceFund | `0x7B440af63D5fa5592E53310ce914A21513C1a716` | v1, unchanged |
| CollateralVault | `0x0e9e32e4e061Db57eE5d3309A986423A5ad3227E` | **v2 — chargeFromFree(), redeployed Feb 27** |
| LiquidationEngine | `0x17D9399C7e17690bE23544E379907eC1AB6b7E07` | **v2 — immutable vault updated, redeployed Feb 27** |
| PositionManager | `0x035E38fd8b34486530A4Cd60cE9D840e1a0A124a` | **v3 — all deps updated, redeployed Feb 27** |
| GovernanceModule | `0x8c987818dffcD00c000Fe161BFbbD414B0529341` | v1, unchanged |
| BRKXToken | `0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32` | 100M BRKX, unchanged |
| EverlastingOption | `0x977419b75182777c157E2192d4Ec2dC87413E006` | **NEW — Layer 1.5, deployed Feb 28** |
| TakafulPool | `0xD53d34cC599CfadB5D1f77516E7Eb326a08bb0E4` | **NEW — Layer 3, deployed Feb 28** |
| PerpetualSukuk | `0xd209f7B587c8301D5E4eC1691264deC1a560e48D` | **NEW — Layer 2, deployed Feb 28** |
| iCDS | `0xc4E8907619C8C02AF90D146B710306aB042c16c5` | **NEW — Layer 4, deployed Feb 28** |
| PositionManager v1 (legacy) | `0x53E3063FE2194c2DAe30C36420A01A8573B150bC` | deauthorized |
| PositionManager v2 (legacy) | `0x787E15807f32f84aC3D929CB136216897b788070` | deauthorized (no chargeFromFree in vault) |
| CollateralVault v1 (legacy) | `0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E` | deauthorized |
| LiquidationEngine v1 (legacy) | `0x456eBE7BbCb099E75986307E4105A652c108b608` | deauthorized |
| OracleAdapter v1 (legacy) | `0xB8d9778288B96ee5a9d873F222923C0671fc38D4` | deauthorized |

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
- [x] `useBrkxTier.ts` — `BRKXToken.balanceOf(address)` → tier index 0–3 → feeBps/feeLabel/nextTierBrkx (Feb 28)
- [x] `useKappaSignal.ts` — `OracleAdapter.getKappaSignal(BTC_ASSET_ADDRESS)` → kappa/premium/regime/regimeLabel/regimeColor (Feb 28) · wagmi v2 tuple fix applied

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

### Tests (93/93 passing)
- [x] `test/unit/BRKXToken.t.sol` — 10/10 (supply, transfer, approve, burn, ERC20Votes, ERC20Permit, Ownable2Step, fuzz)
- [x] `test/unit/PositionManagerFee.t.sol` — 8/8 (all 4 tiers, disabled mode, InsuranceFund split, treasury split, event)
- [x] `test/unit/KappaSignal.t.sol` — 15/15 (premium sign, regime 0-3, fuzz 1000 runs)
- [x] `test/unit/EverlastingOption.t.sol` — 33/33 (math harness 11 + pricing 22, with 4 fuzz props, 1000 runs each)
- [x] `test/unit/TakafulPool.t.sol` — 16/16 (pool lifecycle + claim + surplus + wakala fuzz 1000 runs)
- [x] `test/unit/PerpetualSukuk.t.sol` — 16/16 (issuance + subscription + profit + redemption + call sensitivity)
- [x] `test/unit/iCDS.t.sol` — 19/19 (open + accept + premium + credit event + settlement + expiry + LGD fuzz 1000 runs)
- [x] `test/integration/BarakaIntegration.t.sol` — 30/30 (updated for 7-arg PM constructor)

### Fee tier table (hold-based, no lock-up)
| BRKX held | Fee rate | Saving |
|---|---|---|
| < 1,000 | 5.0 bps | — |
| ≥ 1,000 | 4.0 bps | −20% |
| ≥ 10,000 | 3.5 bps | −30% |
| ≥ 50,000 | 2.5 bps | −50% |

Revenue split: 50% → InsuranceFund / 50% → Treasury

### On-chain Smoke Test (completed Feb 27 2026)
- [x] `script/RedeployAndSmoke.s.sol` — redeploys 4 stale contracts + runs 12-step smoke test
- [x] BRKX tier3 fee verified on-chain: 375,000 / 375,000 tUSDC-wei (IF / treasury) per leg ✓
- [x] κ-signal verified on-chain: `getKappaSignal()` returns regime=0 (NORMAL) ✓
- [x] `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` — Arbitrum Sepolia broadcast confirmed

### Frontend BRKX + κ Display (completed Feb 28 2026)
- [x] `hooks/useBrkxTier.ts` — reads BRKX `balanceOf`, resolves tier (0–3), returns `tierName/feeBps/feeLabel/feePct/balanceDisplay/nextTierBrkx` (refetch 30s)
- [x] `hooks/useKappaSignal.ts` — reads `OracleAdapter.getKappaSignal()` as tuple `[bigint,bigint,number]`, returns `kappa/premium/regime/regimeLabel/regimeColor` (refetch 30s)
  - Fixed wagmi v2 TypeScript error: named `.regime` / `.kappa` not on tuple → destructure with `const [rawKappa, rawPremium, rawRegime] = data`
- [x] `OrderPanel.tsx` — added `estFee = size × feeBps / 100_000` calculation; "Trading fee" row (gold, ~$X.XXXX); "BRKX tier" badge (green=Tier3, gold=others); BRKX balance indicator strip below action button (shows next-tier upgrade path)
- [x] `frontend/lib/contracts.ts` — `getKappaSignal` ABI entry added; all 4 redeployed contract addresses updated to v2/v3

### Pending
- [ ] Distribute BRKX to test wallets for fee tier testing (from deployer wallet holding all 100M)

---

## PHASE 4 — TESTNET LAUNCH

- [x] All 8 contracts deployed + verified — Arbitrum Sepolia (Feb 25 2026)
- [x] PositionManager v2 + BRKXToken deployed + verified (Feb 27 2026)
- [x] OracleAdapter v2 + CollateralVault v2 + LiquidationEngine v2 + PositionManager v3 redeployed (Feb 27 2026)
- [x] On-chain smoke test broadcast verified — BRKX fee split + κ-signal (Feb 27 2026)
- [x] Frontend live — https://baraka.arcusquantfund.com (Feb 26 2026)
- [x] Subgraph live — indexing all events (Feb 26 2026)
- [x] **Automated E2E test** — `bash e2e.sh` — forks Arbitrum Sepolia, 6/6 pass in ~20s, zero gas
  - `contracts/test/e2e/E2EForkTest.t.sol` — lifecycle, funding flow, liquidation, Shariah guard, cooldown
  - MockFeed swapped in for live Chainlink to control prices + timestamps
  - Auto-unpauses all contracts if left paused on testnet
- [x] **Pinata JWT** — obtained Feb 28 2026 (Key: `bb023190f5171bdf5884`, stored in `.env`)
- [ ] **Upload fatwa_placeholder.pdf** → get IPFS CID → call `GovernanceModule.setFatwaURI(cid)`
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
- [x] Written — `papers/paper2/paper2_credit_equivalence.tex` (Feb 27 2026)
- [x] Literature review integrated: Brémaud (1981), Protter (2005), Elliott et al. (2000), Jeanblanc & Rutkowski (2000), Schönbucher (2003), Billah (2007), Htay & Salman (2012), Khan & Ahmed (2001), SeekersGuidance (2025), Jobst (2007)
- [ ] Submit to Journal of Banking & Finance or Mathematical Finance
- [ ] Preprint on SSRN / arXiv (q-fin.GN)
- [ ] Share with AAOIFI for fatwa process input

### Paper 3 — The κ-Rate: Riba-Free Monetary Alternative (written + appendix)
- [x] Written — `papers/paper3/paper3_kappa_rate.tex` (Feb 28 2026) — **11 pages** (compiled clean)
- [x] Literature review: Fisher (1930), Böhm-Bawerk (1890), Wicksell (1898), Keynes (1936), Chapra (1985), Khan & Mirakhor (1987), Iqbal & Mirakhor (2011), CIR (1985), Vasicek (1977), Nelson-Siegel (1987), El-Gamal (2006), Zarqa (1983), Khan & Abdallah (2017), Mirakhor & Askari (2010)
- [x] Core thesis: κ is Wicksell's natural rate minus riba — first rigorous riba-free monetary alternative
- [x] κ-yield curve: κ(T) = 1/T, Islamic analog of the CIR term structure
- [x] Applications: credit instruments, takaful, monetary policy signalling, sovereign sukuk benchmark
- [x] **Appendix A: Stochastic κ Dynamics** — CIR-κ SDE `dκ_t = α(κ̄−κ_t)dt + σ_κ√κ_t dW_t^Q`; Feller condition lemma (κ>0 a.s.); closed-form κ-bond pricing theorem (Riccati ODE proof); stochastic κ-yield curve proposition (short/long-rate limits, normal/inverted/flat shapes); calibration equation; CIR correspondence table
  - Fix applied: `\DeclareMathOperator*{\argmin}` added to preamble (calibration eq. missing this)
  - PDF recompiled: **zero errors, all cross-refs resolved, 11 pages**
- [x] NOTE: simulation (cadCAD/RL/GT/MD) = data tool, cited as data note in Paper 3 (not a standalone paper)
- [ ] Submit to Journal of Economic Theory / Review of Financial Studies
- [ ] Preprint on SSRN / arXiv (q-fin.EC, q-fin.MF)

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
- [x] Pinata JWT obtained — Feb 28 2026 (Key `bb023190f5171bdf5884`, stored in `.env`)
- [ ] Upload `fatwa_placeholder.pdf` to Pinata → call `GovernanceModule.setFatwaURI(cid)` on Sepolia
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

*Checklist Version 2.6 — February 28, 2026 — Updated after Session 15 (Product stack deployed on-chain + /sukuk /takaful /credit /dashboard pages live + Pinata JWT obtained)*
