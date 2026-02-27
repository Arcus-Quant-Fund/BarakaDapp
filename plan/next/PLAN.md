# BARAKA PROTOCOL — NEXT PHASE PLAN
**Date:** February 2026
**Status:** Pre-build · Foundation established · Ready to execute
**Author:** Shehzad Ahmed (Arcus Quant Fund)

---

## WHAT BARAKA IS

Baraka is the world's first Shariah-compliant perpetual futures protocol, mathematically proven to be riba-free. Built on Arbitrum.

**Mathematical Basis:** Ackerer, Hugonnier & Jermann (2024), *Mathematical Finance*
**Core Principle:** ι = 0 always. The funding rate formula is:
```
F = P = (mark_price - index_price) / index_price
```
No interest term. No interest floor. Proven by Theorem 3 / Proposition 3 of the paper.

**Market Opportunity:**
- 1.8 billion Muslims globally
- $3 trillion Islamic finance industry
- 0 existing halal perpetual futures protocols
- CEX perpetuals (Binance, Bybit) embed ι = 0.010%/8h = 10.95%/year interest

---

## WHERE WE ARE NOW (Feb 2026)

### Done ✅
- Full research foundation (Foundation.rtf, Applicationss.rtf, dooo.rtf, Islamic_DApp_Blueprint.md)
- Mathematical proof documented (ι=0 no-arbitrage via Ackerer framework)
- Website landing page `/dapp` live at arcusquantfund.com/dapp
- Technology stack chosen (Foundry, Arbitrum, Next.js, The Graph)
- Detailed build plan written (BARAKA_CLAUDE_CODE_PLAN.md, BARAKA_FREE_PLAN.md)
- API keys collected for development

### Not Started ❌
- Solidity smart contracts
- Development environment
- Frontend trading interface
- Subgraph indexer
- Any testnet deployment

---

## PHASE 1 — SMART CONTRACTS (TARGET: 2 WEEKS)

### 1.1 Environment Setup (Day 1)
**Goal:** Working Foundry environment, project scaffold, all dependencies installed.

**Tasks:**
- Install Foundry (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- Create `/Users/shehzad/Desktop/BarakaDapp/contracts/` project structure
- Install OZ contracts, forge-std, chainlink interfaces
- Configure `foundry.toml` with Arbitrum Sepolia + Mainnet RPC endpoints
- Create `.env` from template with collected API keys
- Add `.gitignore` (must include `.env`, `broadcast/`, `out/`, `cache/`)

**Expected output:** `forge build` passes, `forge test` runs (no tests yet but framework works)

---

### 1.2 Core Contracts (Days 2–10)

#### Contract 1: FundingEngine.sol
**Path:** `contracts/src/core/FundingEngine.sol`
**Purpose:** The heartbeat of Baraka. Implements ι=0 funding formula.

**Key specs:**
- `getFundingRate(address market) returns (int256)` — formula: `(mark - index) * 1e18 / index`
- `FUNDING_INTERVAL = 1 hours`
- `TWAP_WINDOW = 30 minutes`
- Circuit breaker: clamp to ±75 bps (symmetric, NOT an interest floor)
- OZ Ownable2Step + Pausable + ReentrancyGuard
- NatSpec citing Ackerer et al. (2024) Theorem 3 / Proposition 3
- Event: `FundingRateUpdated(market, rate, markPrice, indexPrice, timestamp)`

**Tests:** `test/unit/FundingEngine.t.sol`
- F=0 when mark=index
- F>0 when mark>index
- F<0 when mark<index
- No interest floor in ANY scenario
- Clamp is symmetric
- Fuzz: `testFuzz_NeverHasInterestFloor(uint256 mark, uint256 index)`

---

#### Contract 2: ShariahGuard.sol
**Path:** `contracts/src/shariah/ShariahGuard.sol`
**Purpose:** On-chain enforcement of Shariah rules. The compliance layer everything must pass through.

**Key specs:**
- `uint256 public constant MAX_LEVERAGE = 5` — immutable, cannot ever change
- `mapping(address => bool) public approvedAssets`
- `mapping(address => string) public fatwaIPFS` — IPFS hash of fatwa PDF per asset
- `address public shariahMultisig` — 3-of-5 multisig, only entity to approve assets
- `approveAsset(token, ipfsHash)` — onlyShariahMultisig
- `revokeAsset(token, reason)` — onlyShariahMultisig
- `validatePosition(asset, leverage)` — reverts if non-compliant

**Tests:** Non-approved asset rejected, leverage > 5 rejected, only multisig can approve

---

#### Contract 3: OracleAdapter.sol
**Path:** `contracts/src/oracle/OracleAdapter.sol`
**Purpose:** Triple-oracle price feed with consensus and failover.

**Key specs:**
- Sources: Chainlink (primary) + Pyth (secondary) — require 2-of-2 within 0.5% tolerance
- Staleness: reject prices older than 5 minutes
- Circuit breaker: reject if >20% from last valid price
- `getIndexPrice(address asset) returns (uint256)`
- `getMarkPrice(address asset, uint256 twapWindow) returns (uint256)`
- Failover logic: if Chainlink fails, use Pyth alone with warning event

**Arbitrum One addresses:**
```
CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9
CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
PYTH_CONTRACT    = 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C
```

---

#### Contract 4: PositionManager.sol
**Path:** `contracts/src/core/PositionManager.sol`
**Purpose:** Core trading logic. Open/close/settle positions.

**Key specs:**
- `openPosition(market, size, leverage, collateralToken, amount)`
- `closePosition(positionId)`
- `settleFunding(market)` — applies hourly funding to all open positions
- Position struct: `{id, trader, market, size, leverage, entryPrice, collateral, openTime, fundingAccrued}`
- Isolated margin only (no cross-margin)
- Calls ShariahGuard before every open
- Unrealized PnL: `(currentPrice - entryPrice) * size`

---

#### Contract 5: CollateralVault.sol
**Path:** `contracts/src/core/CollateralVault.sol`
**Purpose:** Holds user collateral. No rehypothecation.

**Key specs:**
- Approved tokens: USDC, PAXG, XAUT (ShariahGuard must approve each)
- `deposit(token, amount)` / `withdraw(token, amount)` with 24h cooldown
- `lockCollateral(user, amount)` — called by PositionManager on open
- `unlockCollateral(user, amount)` — called on close/liquidation
- NO yield on held funds (avoids riba on reserves)
- Emergency withdraw bypasses cooldown when protocol is paused

**Arbitrum One token addresses:**
```
USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831
PAXG = 0xfEb4DfC8C4Cf7Ed305bb08065D08eC6ee6728429
XAUT = 0xf9b276a1a05934ccD953861E8E59c6Bc428c8cbD
```

---

#### Contract 6: LiquidationEngine.sol
**Path:** `contracts/src/core/LiquidationEngine.sol`
**Purpose:** Liquidates underwater positions. Incentivises liquidators fairly.

**Key specs:**
- Maintenance margin: 2% of position value
- Liquidation penalty: 1% of notional
- Split: 50% to InsuranceFund, 50% to liquidator
- Partial liquidation before full close
- 1-block minimum delay between open and liquidation eligibility
- `isLiquidatable(positionId) returns (bool)`
- `liquidate(positionId)` — callable by anyone

---

#### Contract 7: InsuranceFund.sol
**Path:** `contracts/src/insurance/InsuranceFund.sol`
**Purpose:** Socializes rare shortfall losses. Seed of Layer 3 Takaful.

**Key specs:**
- Receives: 50% of liquidation penalties + future protocol fee allocation
- Covers socialized loss when liquidation insufficient
- NO yield generation on idle capital (avoids riba)
- Surplus distribution if fund > 2x weekly average claims
- NatSpec: "Seed of Layer 3: Takaful Protocol"

---

#### Contract 8: GovernanceModule.sol
**Path:** `contracts/src/shariah/GovernanceModule.sol`
**Purpose:** Dual-track governance — technical DAO cannot override Shariah board.

**Key specs:**
- Track 1: Technical DAO (token vote, 48h timelock)
- Track 2: Shariah Board (3-of-5 multisig, veto power over any change)
- Shariah board can pause markets; DAO cannot undo it without board approval
- 48-hour timelock on all parameter changes

---

### 1.3 Deploy Script (Day 11)
**Path:** `contracts/script/Deploy.s.sol`
**Deploy order:**
1. OracleAdapter
2. ShariahGuard
3. InsuranceFund
4. FundingEngine (needs OracleAdapter)
5. CollateralVault (needs ShariahGuard)
6. LiquidationEngine (needs InsuranceFund)
7. PositionManager (needs all above)
8. GovernanceModule

Post-deploy: approve USDC/PAXG in ShariahGuard, link contracts, save addresses to `deployments/421614.json`

---

### 1.4 Testing (Days 12–14)
- Unit tests: 90%+ branch coverage on each contract
- Integration tests: full lifecycle (deposit → open → settle → close → withdraw)
- Invariant tests: ι=0 is NEVER violated in any state
- Slither static analysis: zero HIGH/MEDIUM issues
- Deploy to Arbitrum Sepolia, verify on Arbiscan

---

## PHASE 2 — FRONTEND (TARGET: 2 WEEKS AFTER PHASE 1)

### Stack
- Next.js 14 (App Router, TypeScript)
- wagmi + viem + RainbowKit (wallet connection)
- lightweight-charts (TradingView-style, free)
- Tailwind CSS
- Color scheme: Deep green `#1B4332` + Gold `#D4AF37` + White

### Pages
1. **`/`** — Homepage: Arabic بَرَكَة, tagline, live κ value, connect wallet
2. **`/trade`** — Trading: price chart, long/short, leverage slider (hard cap 5x), funding rate display
3. **`/transparency`** — Shariah proof: live formula with real numbers, ι=0 highlighted, CEX comparison
4. **`/markets`** — Market overview: BTC-USDC, ETH-USDC, PAXG-USDC with funding rates

### Key Component: ShariahPanel
- Live formula substituted with real prices
- ι = 0.000% in green
- CEX: ι = 0.010%/8h = 10.95%/year in red
- Fatwa status + IPFS link
- κ convergence gauge

---

## PHASE 3 — SUBGRAPH + DEVOPS (1 WEEK)

- The Graph Studio subgraph for all contract events
- GitHub Actions CI (forge test, forge coverage, slither on every PR)
- Vercel auto-deploy on push to main
- Discord webhook monitoring (oracle freshness, insurance fund balance, frontend uptime)

---

## PHASE 4 — TESTNET LAUNCH (TARGET: 6 WEEKS FROM START)

**Checklist before public testnet:**
- All 8 contracts on Arbitrum Sepolia, verified on Arbiscan
- Frontend live on Vercel
- Full end-to-end flow tested manually
- Shariah board review started (reach out to scholars)
- Community channels live (Discord + Twitter @BarakaProtocol)

---

## TECHNOLOGY DECISIONS

| Decision | Choice | Reason |
|---|---|---|
| Chain | Arbitrum One | Low gas, EVM, good ecosystem |
| Smart contracts | Foundry | Best testing framework, fast |
| Frontend | Next.js 14 | Already in use for Arcus website |
| Oracles | Chainlink + Pyth | Most reliable, free on-chain |
| Indexing | The Graph Studio | Free, standard DeFi indexer |
| Hosting | Vercel | Free tier, auto-deploy |
| Auth | Wallet-only (RainbowKit) | No centralized auth needed |

---

## BROADER VISION — LAYERED BUILD ROADMAP

The Baraka Protocol is Layer 1 of a four-layer stack. Each layer is mathematically grounded in the same Ackerer framework. Each layer provides empirical validation for the next.

---

### LAYER 1 — PERPETUAL EXCHANGE (current: Testnet live)

The proof-of-concept. Demonstrates ι=0 achieves no-arbitrage convergence in a live market. Generates data. Provides the empirical foundation for scholar engagement and academic credibility.

**Status:** Deployed on Arbitrum Sepolia. BRKX fee system live. Frontend at baraka.arcusquantfund.com.

---

### LAYER 2 — PERPETUAL SUKUK (CREDIT PROTOCOL)

**Mathematical foundation:** The random time representation of the perpetual futures price is formally isomorphic to the Duffie-Singleton defaultable bond pricing formula. Under the identification κ ↔ λ (hazard rate) and ι = 0 ↔ r = 0 (no interest discount), both yield:

```
V_t = E[X_{θ_t}]
```

where θ_t is an exponentially distributed stopping time with rate κ. This is a mathematically proven, no-arbitrage pricing formula that does not require a positive interest rate.

**What this enables:** A smart contract factory where:
- Real-world asset (RWA) collateral is locked (warehouse, energy asset, gold reserve)
- Perpetual sukuk tokens are minted at price E[X_{θ}] (the Ackerer formula with ι=0)
- The issuer (asset operator) pays continuous premium κ to holders
- At a random redemption event θ (milestone, oracle-triggered), holders receive X_θ (fair market value)
- No riba: pricing is purely expectation-based, no interest discount

**κ calibration:** κ is backed out from the observed premium (f/X ratio). It is endogenous, not set by a central authority. It plays the role of the credit spread — but without interest.

**Build priority:** Post-mainnet. Requires: scholar approval, legal structure, RWA oracle integration.

---

### LAYER 3 — TAKAFUL PROTOCOL (MUTUAL INSURANCE)

**Mathematical foundation:** The everlasting option pricing formula (Ackerer et al. Proposition 6) with ι=0 gives the actuarially fair takaful contribution:

```
Π_takaful(x, K) = C_p × x^{β_p}
```

where β_p is the negative root of (1/2)σ²β(β-1) = κ (at ι=0, r_a=r_b). This is the expected payout of a claim that arrives at a Poisson random time with intensity κ — exactly the actuarial pricing of a perpetual mutual insurance contract.

**What this enables:**
- Agricultural takaful: crops against price floor (K = floor price, X_t = commodity price, κ = historical disaster frequency)
- Life takaful: benefit at death (κ = age-adjusted mortality hazard, X_t = human capital index)
- Property takaful: replacement cost coverage (κ = event frequency, φ(X) = damage function)

All pricing: on-chain, transparent, actuarially fair, riba-free.

**InsuranceFund connection:** The current InsuranceFund contract is explicitly seeded for this — its NatSpec reads "Seed of Layer 3: Takaful Protocol."

**Build priority:** After Layer 2 establishes scholar credibility. Requires: actuarial data feeds, AAOIFI Takaful Standard No. 26 compliance review.

---

### LAYER 4 — ISLAMIC CREDIT DEFAULT SWAPS (iCDS)

**Mathematical foundation:** Same stopping time framework. Protection buyer pays κ × dt continuously; protection seller pays X_τ (recovery value) at default time τ. Fair price = E[X_τ] = no-arbitrage at r=0.

**What this enables:** The first Shariah-compliant credit protection instrument. Muslim institutions can hedge credit risk on sukuk holdings without using riba-based CDS. The $10 trillion global CDS market has zero Islamic alternatives today.

**Build priority:** Last. Requires: Layers 1-3 operating, regulatory clarity on CDS in target jurisdictions, significant institutional counterparty relationships.

---

### THE κ-RATE: AN ISLAMIC MONETARY ALTERNATIVE

The deeper implication of Layers 1-4 is that κ can replace r (the risk-free rate) as the fundamental pricing parameter in a complete Islamic financial system.

- r is set by central banks, represents time preference, is definitionally riba
- κ is endogenous, represents convergence/event intensity, has no riba content
- κ is observable (from perpetuals basis, actuarial tables, credit spreads)
- A "κ-yield curve" (term structure of κ by maturity) is the Islamic analog of the yield curve

This is the deepest contribution: not just halal derivatives, but a mathematically rigorous Islamic alternative to the entire interest rate infrastructure of modern finance.

---

### PAPER ROADMAP

| Paper | Topic | Status | Target |
|---|---|---|---|
| Paper 1 | ι parameter in perpetual futures — Shariah analysis + empirical evidence | Written | Islamic finance journals |
| Paper 2 | Random stopping time ≡ credit event — riba-free credit pricing framework | **Written** `paper2_credit_equivalence.tex` | Mathematical Finance / JBF |
| Paper 3 | κ-Rate: riba-free monetary alternative from perpetual contract theory — full asset pricing theory, κ-yield curve, policy applications | **Written** `paper3_kappa_rate.tex` | Journal of Economic Theory / RFS |
| Paper 4 | Empirical test of Baraka Protocol on mainnet (simulation is data generation tool, not a paper) | After mainnet | Finance / DeFi journals |

---

## SHARIAH COMPLIANCE SUMMARY

| Islamic Prohibition | How Baraka Addresses It |
|---|---|
| Riba (interest) | ι = 0 hardcoded, mathematically proven, on-chain enforced |
| Gharar (uncertainty) | Oracle consensus, transparent κ value, published formula |
| Maysir (gambling) | MAX_LEVERAGE = 5 immutable, no zero-sum speculation |
| Qabdh (delivery) | USDC/PAXG/XAUT as real-asset collateral |

---

*Version 1.0 — February 2026*
*"بَرَكَة — May Allah bless this work"*
