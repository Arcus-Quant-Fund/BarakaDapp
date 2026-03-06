# Security Audit Outreach Emails
**Send to:** Halborn, Code4rena, OpenZeppelin
**Date:** March 4, 2026
**Attach:** `docs/SECURITY_AUDIT_SCOPE.md` + link to GitHub repo

---

## EMAIL 1 — Halborn Security

**To:** hello@halborn.com
**Subject:** Audit Request — Baraka Protocol (Shariah-Compliant Perpetuals DEX, 13 contracts, ~3.8K SLOC)

---

Hi Halborn team,

I'm the founder of Arcus Quant Fund, building Baraka Protocol — the world's first Shariah-compliant perpetual futures DEX on Arbitrum. We have completed testnet deployment of all 13 smart contracts and are targeting mainnet launch within 30 days, subject to a clean security audit.

**What we're building:**
Baraka Protocol applies the Ackerer–Hugonnier–Jermann (2024) perpetual futures framework with the interest parameter hardcoded to ι = 0, eliminating riba (interest) from the funding mechanism. This is supported by 6 SSRN working papers (6322778–6323618). The protocol is live on Arbitrum Sepolia:
- Frontend: https://baraka.arcusquantfund.com
- GitHub: https://github.com/Arcus-Quant-Fund/BarakaDapp (public)

**Scope summary:**
- 13 Solidity contracts, ~3,800 SLOC
- 4 critical: PositionManager, CollateralVault, LiquidationEngine, EverlastingOption
- External deps: OpenZeppelin 5.x, Chainlink, Pyth
- 369 unit/integration/invariant tests, Slither clean (0 HIGH, 0 MEDIUM in CI)
- Full scope document attached

**Why Halborn:**
Your team has audited several DeFi perpetuals protocols (GMX, dYdX derivatives). The math in our EverlastingOption contract (fixed-point lnWad/expWad, put/call pricing) is the kind of nuanced financial logic where your experience is particularly valuable.

**Timeline:** We need the audit completed within 3–4 weeks to hit our mainnet target.

Could you provide a scoping call availability and a preliminary price range? Happy to jump on a call at your convenience.

Best regards,
Shehzad Ahmed
Founder & CEO, Arcus Quant Fund
contact@arcusquantfund.com
https://arcusquantfund.com

---

## EMAIL 2 — Code4rena

**To:** team@code4rena.com (or contest submission form at code4rena.com/how-it-works)
**Subject:** Contest Submission — Baraka Protocol (~3.8K SLOC, Arbitrum, DeFi perpetuals)

---

Hi Code4rena team,

I'd like to submit Baraka Protocol for a Code4rena audit contest. Here are the details:

**Protocol:** Baraka Protocol — Shariah-compliant perpetual futures DEX on Arbitrum
**GitHub:** https://github.com/Arcus-Quant-Fund/BarakaDapp (public)
**SLOC:** ~3,800 (13 contracts)
**Chain:** Arbitrum One (target), currently live on Arbitrum Sepolia

**Key technical areas:**
- Fixed-point math: `EverlastingOption` uses `lnWad`/`expWad` for put/call pricing (515 lines — the most complex contract)
- Oracle security: dual Chainlink/Pyth + TWAP circuit breaker + divergence check
- Liquidation: partial liquidation with penalty cap + conservation invariant
- Funding: ±75 bps circuit breaker, ι=0 enforced by `ShariahGuard`
- Governance: 48-hour timelock, veto mechanism

**Existing security work:**
- Slither: 0 HIGH, 0 MEDIUM (enforced in CI)
- 369 tests: unit + integration + invariant (256×128 depth) + 1000 fuzz runs
- Full scope doc attached

**Ideal contest size:** Medium — $50K–$100K USDC prize pool (open to discuss)
**Timeline:** Need results within 3–4 weeks

Please let me know the earliest available contest slot and submission requirements.

Best regards,
Shehzad Ahmed
Founder & CEO, Arcus Quant Fund
contact@arcusquantfund.com

---

## EMAIL 3 — OpenZeppelin

**To:** security@openzeppelin.com
**Subject:** Audit Request — Baraka Protocol (Arbitrum, OZ 5.x, 13 contracts, perpetuals DEX)

---

Hi OpenZeppelin Security team,

I'm reaching out to request a smart contract security audit for Baraka Protocol, a Shariah-compliant perpetual futures DEX built on Arbitrum. We are heavy users of the OpenZeppelin library (Contracts 5.x: ERC20, Ownable2Step, Votes, Permit, ReentrancyGuard) and trust your team's deep familiarity with these patterns.

**About the protocol:**
Baraka Protocol is the first Islamic Finance-compliant perpetuals DEX. The funding mechanism removes the interest parameter (ι = 0) from the Ackerer–Hugonnier–Jermann framework, making it structurally riba-free. The protocol is live on Arbitrum Sepolia:
- Live frontend: https://baraka.arcusquantfund.com
- GitHub: https://github.com/Arcus-Quant-Fund/BarakaDapp

**Audit scope:**
- 13 contracts, ~3,800 SLOC
- Critical: PositionManager, CollateralVault, LiquidationEngine, EverlastingOption
- Security-sensitive: FundingEngine (circuit breaker), OracleAdapter (Chainlink/Pyth dual-feed + TWAP), GovernanceModule (timelock + veto), TakafulPool, iCDS
- Full scope document attached (includes key risk areas and suggested focus)

**Existing work:**
- Slither static analysis: 0 HIGH, 0 MEDIUM (enforced in GitHub Actions CI)
- 369 automated tests across unit, integration, invariant (9 invariants at 256×128 depth), and fuzz (1000 runs)

**Timeline:** Mainnet launch target is 30 days out — we need the audit completed within that window.

Would you be able to provide a quote and estimated timeline? We are committed to making any identified issues public in the final audit report.

Best regards,
Shehzad Ahmed
Founder & CEO, Arcus Quant Fund
contact@arcusquantfund.com
https://arcusquantfund.com

---

## EMAIL 4 — Sherlock (bonus — competitive with Code4rena)

**To:** Submit via https://app.sherlock.xyz/audits (protocol submission form)
**Subject:** Baraka Protocol Audit — ~3.8K SLOC, Arbitrum Perpetuals DEX

---

Hi Sherlock team,

Submitting Baraka Protocol for a Sherlock audit contest:

**Protocol summary:** Shariah-compliant perpetual futures DEX on Arbitrum. Core innovation: ι = 0 (interest-free funding formula). 13 contracts, ~3,800 SLOC, live on Arbitrum Sepolia.

**GitHub:** https://github.com/Arcus-Quant-Fund/BarakaDapp
**Docs:** Audit scope doc attached; 6 academic papers on SSRN (6322778–6323618)

**Contract breakdown:**
- Core DEX: PositionManager (458), CollateralVault (240), LiquidationEngine (216), FundingEngine (214)
- Pricing: EverlastingOption (515) — fixed-point put/call math, most complex
- Infrastructure: OracleAdapter (381), InsuranceFund (174), ShariahGuard (165), GovernanceModule (249)
- Products: TakafulPool (330), PerpetualSukuk (342), iCDS (392)
- Token: BRKXToken (89)

**Test coverage:** 369 tests, Slither clean, invariant tests at 256×128 depth.

**Prize pool:** Open to Sherlock's recommendation based on scope.
**Timeline:** Need results in 3–4 weeks.

Best,
Shehzad Ahmed | contact@arcusquantfund.com

---

## Sending Priority

| Firm | Send via | Priority | Notes |
|---|---|---|---|
| **Code4rena** | code4rena.com contest form | 1st | Public contest = broadest coverage, fastest turnaround |
| **Sherlock** | app.sherlock.xyz/audits | 2nd | Similar to C4, good for DeFi protocols |
| **Halborn** | hello@halborn.com | 3rd | Best for nuanced math review (paid engagement) |
| **OpenZeppelin** | security@openzeppelin.com | 4th | Premium — good if budget allows; strong OZ familiarity |

**Recommended approach:** Submit to Code4rena + Sherlock simultaneously (public contests, fastest, broadest coverage). Send Halborn email for a private parallel review of the most complex contracts (EverlastingOption math).
