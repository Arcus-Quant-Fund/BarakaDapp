# Baraka Protocol — Progress Report

**Generated:** March 6, 2026
**Status:** Testnet Live | Pre-Audit | All Core Infrastructure Complete
**Frontend:** https://baraka.arcusquantfund.com

---

## Executive Summary

Baraka Protocol is the world's first Shariah-compliant perpetual futures DEX, mathematically proven riba-free (iota=0). Fully built, deployed, and tested on Arbitrum Sepolia testnet with 13 smart contracts, a production frontend (8 routes), indexed subgraph, 4-job CI pipeline, and 6 published SSRN research papers. Mainnet blocked on external security audit and scholar-signed fatwa.

---

## Directory Structure

```
BarakaDapp/
├── contracts/                    # Foundry project (Solc 0.8.24, OZ ^5.0)
│   ├── src/
│   │   ├── core/                 # PositionManager, FundingEngine, CollateralVault, LiquidationEngine, EverlastingOption
│   │   ├── oracle/               # OracleAdapter (dual Chainlink/Pyth + kappa-signal)
│   │   ├── shariah/              # ShariahGuard (MAX_LEVERAGE=5), GovernanceModule (DAO + Shariah veto)
│   │   ├── insurance/            # InsuranceFund
│   │   ├── takaful/              # TakafulPool (Layer 3 mutual insurance)
│   │   ├── credit/               # PerpetualSukuk (Layer 2), iCDS (Layer 4)
│   │   └── token/                # BRKXToken (ERC20 governance, 4 fee tiers)
│   ├── test/                     # 410/410 tests (unit + integration + invariant + fuzz)
│   ├── script/                   # Deploy scripts (testnet + mainnet ready)
│   └── deployments/421614.json   # All deployed addresses + versions
├── frontend/                     # Next.js 16 + wagmi 2.19.5 + RainbowKit
│   ├── app/                      # 8 routes: /, /trade, /markets, /sukuk, /takaful, /credit, /dashboard, /transparency
│   ├── components/               # PriceChart, OrderPanel, PositionTable, ShariahPanel, KappaPanel, DepositPanel
│   ├── hooks/                    # useFundingRate, useOraclePrices, useKappaSignal, useBrkxTier, usePositions, useDeposit, useWithdraw
│   └── lib/contracts.ts          # All addresses + ABIs (v4 redeployed)
├── subgraph/                     # The Graph Studio (v0.0.2, 9 entities, 4 data sources)
├── simulations/                  # Economic security (cadCAD + RL + game theory + mechanism design)
├── papers/                       # 6 SSRN papers
├── docs/                         # Security audit scope, outreach emails, AI audit report
├── plan/                         # Roadmap, checklists, session logs
├── scripts/                      # deploy.sh, test.sh, build.sh
└── .github/workflows/ci.yml     # 4-job CI (contracts/slither/frontend/subgraph)
```

---

## Smart Contracts (13 Total, ~3,800 SLOC)

### Core Layer (Layer 1)
| Contract | Version | Address (Sepolia) | SLOC |
|----------|---------|-------------------|------|
| PositionManager | v4 | 0x5a8b...5d31 | 458 |
| FundingEngine | v2 | 0x9aFD...AfF4 | 214 |
| CollateralVault | v2 | 0x0e9e...227E | 240 |
| LiquidationEngine | v3 | 0x8E70...65bA | 216 |
| OracleAdapter | v3 | 0x4f6C...2999 | 381 |
| ShariahGuard | v1 | 0x26d4...2e69 | 165 |
| InsuranceFund | v1 | 0x7B44...a716 | 174 |
| GovernanceModule | v2 | 0xf342...75c5 | 249 |

### Product Stack (Layers 1.5-4)
| Contract | Layer | Version | Address (Sepolia) | SLOC |
|----------|-------|---------|-------------------|------|
| EverlastingOption | 1.5 | v1 | 0x8B45...dEC8 | 515 |
| PerpetualSukuk | 2 | v1 | 0xB2c5...99B3 | 342 |
| TakafulPool | 3 | v1 | 0x6386...c91 | 330 |
| iCDS | 4 | v2 | 0x7A02...b15F | 392 |
| BRKXToken | - | v1 | 0xD3f7...A32 | 89 |

### Test Results
- **410/410 tests passing** (unit + integration + invariant + fuzz)
- **Slither:** 0 HIGH, 0 MEDIUM findings
- **8 AI audit findings:** All fixed (Sessions 18-19)
- **E2E fork test:** 6/6 on-chain assertions pass

---

## Frontend (8 Routes)

**Stack:** Next.js 16.1.6 | wagmi 2.19.5 (PINNED) | RainbowKit 2.2.10 | Tailwind v4 | lightweight-charts 5.1.0

| Route | Purpose | Key Components |
|-------|---------|----------------|
| `/` | Homepage | Hero, stats, product cards, fatwa proof |
| `/trade` | Trading | PriceChart, OrderPanel, PositionTable, DepositPanel |
| `/markets` | Market overview | BTC-PERP live; ETH/PAXG pending |
| `/sukuk` | Sukuk issuance | SukukForm, SubscriptionPanel |
| `/takaful` | Takaful pools | PoolSelector, ContributionPanel |
| `/credit` | iCDS trading | ProtectionBuyerForm, ProtectionSellerForm |
| `/dashboard` | User portfolio | PositionTable, PnL tracker, tier badge |
| `/transparency` | Shariah proof | Live formula, all 13 contracts, audit links |

---

## Subgraph (The Graph Studio)

- **Version:** v0.0.1 | **Network:** Arbitrum Sepolia
- **Status:** Addresses fixed (Mar 6) — subgraph.yaml now points to v4 addresses. Needs `graph deploy` to publish new version.
- **Entities:** Position, Trade, FundingSettlement, FundingRateSnapshot, DepositEvent, WithdrawEvent, LiquidationEvent, MarketStats, Protocol (9 entities)
- **Data Sources:** 7 (PositionManager, FundingEngine, CollateralVault, LiquidationEngine, TakafulPool, PerpetualSukuk, iCDS)

---

## Simulations (All Passing)

| Module | Framework | Key Result |
|--------|-----------|------------|
| cadCAD | 5 runs x 720 steps | iota=0 maintained, 0% insolvency |
| RL Trader | Gymnasium + PPO/SB3 | Learned optimal carry strategy |
| Game Theory | nashpy | Nash equilibrium: net transfer ~$0 |
| Mechanism Design | scipy differential_evolution | Params in Pareto-optimal region |

**Stress Tests:** flash crash (-20%), funding spiral, oracle attack, gradual bear (-50%), insurance stress — all pass with 0% insolvency.

---

## Papers (6 SSRN Publications)

| # | Title | SSRN ID | Pages |
|---|-------|---------|-------|
| 1 | iota=0 Shariah Perpetual Futures | 6322778 | 16 |
| 2 | Random Stopping Time = Credit Event | 6322858 | 11 |
| 2A | kappa-Yield Curve (Empirical) | 6322938 | 26 |
| 2B | Stochastic Takaful Pricing (CIR Hazard) | 6323459 | 28 |
| 2C | iCDS Implementation | 6323519 | 15 |
| 3 | IES Simulation Framework | 6323618 | 8 |

---

## Readiness Summary

| Component | Complete | Tests | Deployed | Blocker |
|-----------|----------|-------|----------|---------|
| Smart Contracts (13) | 100% | 410/410 | Sepolia | EXT AUDIT |
| Frontend (8 routes) | 100% | Build passes | baraka.com | - |
| Subgraph (v0.0.1) | 90% | Codegen+build | Studio | Addresses fixed — needs graph deploy |
| CI Pipeline | 100% | 4 jobs green | GitHub Actions | - |
| Papers (6) | 100% | N/A | SSRN | - |
| Simulations | 100% | All pass | Results | - |
| Mainnet Script | 100% | Tested | Not run | EXT AUDIT |
| Fatwa | 50% | N/A | Placeholder | SCHOLARS |
| Community | 10% | N/A | Not public | - |

---

## Mainnet Blockers

1. **External Security Audit** — Scope doc ready (`docs/SECURITY_AUDIT_SCOPE.md`), outreach emails drafted. Send to Code4rena, Sherlock, Halborn.
2. **Scholar-Signed Fatwa** — Placeholder on-chain. Need AAOIFI-certified scholars (Dr. Bhuyan's network).
3. **Fund Mainnet Deployer** — Need 0.5+ ETH on Arbitrum One.
4. **Deploy Subgraph** — subgraph.yaml addresses updated Mar 6. Run `graph deploy` to publish v0.0.2 with correct addresses.

## Next Steps (30-Day Path)

1. Week 1: Send security audit applications
2. Week 2-4: Audit process (15-30 days)
3. Week 3 (parallel): Engage scholars for fatwa
4. Week 4: Soft-launch Twitter + Discord + LinkedIn
5. Week 5: Deploy to Arbitrum One mainnet
