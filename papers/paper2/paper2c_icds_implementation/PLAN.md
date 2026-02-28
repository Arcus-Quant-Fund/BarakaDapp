# Paper 2C — Plan

## Title
**"An Islamic Credit Default Swap on Smart Contract Infrastructure: Design, Legal Analysis, and Initial Liquidity"**

## One-Line Summary
We take the iCDS pricing formula `s* = κ(1−δ)` from Paper 2, build a complete on-chain implementation on Arbitrum (the Baraka Protocol iCDS contract), analyse its legal form under VARA/MAS/BNM/AAOIFI frameworks, and design a liquidity bootstrapping mechanism using BRKX token incentives.

---

## The Core Question
Paper 2 proves the fair iCDS spread is `s* = κ(1−δ)`. Paper 2C asks: **can this be deployed as a working financial product that is simultaneously (a) Shariah-compliant, (b) legally operable in at least one jurisdiction, and (c) liquid enough to be economically meaningful?**

This bridges academic finance, Islamic jurisprudence, blockchain engineering, and regulatory law — in one paper.

---

## Research Questions

1. Is the iCDS contract structure (wa'd-based, put-option-priced premium, LGD settlement) recognised as Shariah-compliant by AAOIFI Standard 1 (Derivatives) and ISDA/IIFM Tahawwut documentation?
2. How does the `s* = κ(1−δ)` formula compare to conventional CDS spreads on the same reference entities — is it cheaper, more expensive, or equivalent?
3. Can the `iCDS.sol` smart contract (deployed on Arbitrum Sepolia) correctly execute the full lifecycle: open → accept → settle, with on-chain LGD calculation and put-option-priced premiums?
4. Under which regulatory frameworks (VARA Dubai, MAS Singapore, BNM Malaysia, CFTC US, FCA UK) is an on-chain iCDS legally operable?
5. What liquidity depth is needed for the iCDS market to achieve price discovery? How can BRKX token incentives bootstrap this liquidity?
6. What are the systemic risk properties of the iCDS market — does it provide genuine credit risk transfer, or does it concentrate risk (as happened with conventional CDS pre-2008)?

---

## Methodology

### Part I — Financial Analysis

**Section A: Pricing Comparison Study**
- Collect conventional CDS spreads for 20+ reference entities: GCC sovereign (Saudi Arabia, UAE, Qatar), GCC corporate (Saudi Aramco, ADNOC, DP World), Islamic bank reference entities (Al Rajhi, Dubai Islamic, Maybank Islamic)
- Compute `s* = κ(1−δ)` for each using κ̂ from Paper 2A and δ from Moody's recovery tables
- Compare to observed CDS spreads: test H₀: `s*_iCDS = s_CDS`
- If `s*_iCDS < s_CDS`: iCDS is cheaper than conventional CDS (because riba is excluded) — powerful result
- If `s*_iCDS ≈ s_CDS`: mathematical equivalence proven in practice — validates theory
- If `s*_iCDS > s_CDS`: premium is misspecified; investigate whether δ assumptions are wrong

**Section B: Welfare Analysis**
- For a sukuk buyer holding $10M of Saudi Aramco 5yr sukuk, compare:
  - Unhedged position
  - Hedged with conventional CDS (riba problem: includes interest in spread)
  - Hedged with iCDS at `s* = κ(1−δ)`
- Compute expected utility under each strategy (CRRA preferences)
- Show that iCDS achieves full hedging efficiency of conventional CDS with zero riba

### Part II — Smart Contract Implementation

**Section C: Contract Architecture**
- Full technical description of `iCDS.sol` (already deployed):
  - Protection struct: {notional, seller, buyer, asset, referenceEntity, κ, δ, premium, openTime, settled, payout}
  - `openProtection()`: seller posts notional collateral, sets κ and δ, premium = `κ(1−δ)·notional`
  - `acceptProtection()`: buyer pays upfront premium (or streaming, design decision)
  - `settleProtection()`: oracle confirms credit event → pays `(1−δ)·notional` to buyer
  - Oracle integration: Chainlink CCIP or custom CreditEventOracle for default confirmation
- UML sequence diagram of full lifecycle
- Gas cost analysis: open/accept/settle gas costs on Arbitrum vs. Ethereum mainnet

**Section D: Credit Event Oracle Problem**
The hardest engineering problem: how does the smart contract know a credit event (default) occurred?
- **Option A**: Chainlink node operators vote on credit event (decentralised, lag)
- **Option B**: Reference to ISDA credit event determinations committee (centralised, authoritative)
- **Option C**: Hybrid — ISDA committee decision triggers Chainlink oracle update
- **Option D**: zkProof of SWIFT MT103 payment failure (technically possible, not yet live)
- Analyse each option for Shariah compliance (taghrir — gharar from event uncertainty must be minimised)

**Section E: On-Chain Testing**
- Deploy to Arbitrum Sepolia (already done: `0xc4E8907619C8C02AF90D146B710306aB042c16c5`)
- Run full lifecycle tests: open → accept → simulate credit event → settle
- Verify `s*` computed correctly for sample parameters
- Gas benchmark: full lifecycle cost in USD

### Part III — Legal Analysis

**Section F: AAOIFI Shariah Standard No. 1 — Derivatives**
- Map iCDS structure to AAOIFI Standard 1 requirements
- Key questions:
  - Is the wa'd (promise) structure valid? (bilateral wa'd = permissible if non-binding on one side)
  - Is the premium a halal consideration for risk transfer?
  - Is the reference entity's default a real risk or simulated gambling?
  - Does the put-option-based premium create excessive gharar?
- Expected finding: iCDS is Shariah-compliant because (1) underlying risk is real, (2) ι=0 removes riba, (3) LGD is pre-specified (reduces gharar), (4) wa'd documentation available

**Section G: Jurisdictional Analysis**

| Jurisdiction | Regulator | Key Framework | iCDS Status |
|---|---|---|---|
| Dubai/UAE | VARA + DFSA | VARA Virtual Asset Rulebook 2023 | Likely permissible as virtual asset derivative |
| Malaysia | BNM + SC | Islamic Financial Services Act 2013 | Green light if AAOIFI-compliant |
| Singapore | MAS | Capital Markets Services Act | Digital token + OTC derivative rules apply |
| UK | FCA | CMAR / UK MAR | OTC derivative — requires EMIR reporting |
| US | CFTC | Commodity Exchange Act / Dodd-Frank | Likely a swap — requires SEF or bilateral registration |
| Bahrain | CBB | CBB Rulebook | Gulf-friendly jurisdiction for pilot |

For each jurisdiction: identify the specific licensing requirement, minimum capital, reporting obligations, and pathway to regulatory approval.

**Section H: ISDA/IIFM Documentation**
- Can the ISDA/IIFM Tahawwut Master Agreement (2010) cover an iCDS?
- Draft a term sheet: reference entity, reference obligation, credit events, settlement, governing law
- Key difference from standard CDS: premium formula replaces market-quoted spread with `κ(1−δ)`
- Who has legal standing to declare a credit event on-chain? (Governance question)

### Part IV — Liquidity Bootstrapping

**Section I: Market Structure Design**
- Double-auction order book vs. AMM (Automated Market Maker) for iCDS
- Recommendation: AMM for small notionals, order book for large
- Risk parameters: minimum notional, maximum leverage, position limits
- Collateral requirements: `collateral ≥ notional × (1−δ) + 3σ buffer`

**Section J: BRKX Token Incentive Mechanism**
- **Protection sellers** (risk-takers): earn BRKX rewards proportional to risk taken and time open
- **Protection buyers** (hedgers): reduced BRKX fee on premiums paid
- **Market makers**: BRKX rewards for providing two-sided quotes
- Reward schedule: emission rate tapering over 4 years (modelled in Paper 3 simulation)
- Game-theoretic analysis: does BRKX incentive produce a Nash equilibrium with positive liquidity?

**Section K: Initial Liquidity Numbers**
- How much capital is needed for the iCDS market to be economically meaningful?
  - Minimum viable: $1M notional outstanding (enough for price discovery)
  - Useful scale: $50M notional (comparable to small conventional CDS market)
  - Target: $500M by year 3 (comparable to medium CDS market)
- Baraka Protocol TVL targets implied by these liquidity milestones

---

## Expected Contributions

1. **First deployed Islamic CDS on a public blockchain** — Baraka Protocol `iCDS.sol` is already live on Arbitrum Sepolia
2. **First complete legal analysis of an on-chain iCDS** — 5 jurisdictions, AAOIFI compliance, ISDA documentation
3. **Pricing formula validation** — `s* = κ(1−δ)` tested against real CDS data (20+ reference entities)
4. **Credit event oracle design** — solves the hardest practical problem in on-chain credit derivatives
5. **Liquidity bootstrapping design** — BRKX incentive mechanism with game-theoretic foundation
6. **Bridge paper** — connects academic Islamic finance, regulatory law, and DeFi engineering in one place

---

## Paper Structure (Target: 40–45 pages — this is the most ambitious of the three)

```
1. Introduction (3pp)
   1.1 Credit Default Swaps and the Riba Problem
   1.2 Why Smart Contracts Enable Islamic CDS
   1.3 Contribution and Organisation

2. Background (5pp)
   2.1 Conventional CDS: Market, Pricing, 2008 Lessons
   2.2 The κ-Rate Framework (Paper 2 recap)
   2.3 iCDS Formula: s* = κ(1−δ)
   2.4 Existing Literature: No Prior Islamic CDS

3. Financial Analysis (8pp)
   3.1 Data: CDS Spreads for 20+ Reference Entities
   3.2 κ Estimation and iCDS Spread Computation
   3.3 Comparison: iCDS vs. CDS Spreads
   3.4 Welfare Analysis: Hedging Efficiency

4. Smart Contract Implementation (8pp)
   4.1 iCDS.sol Architecture
   4.2 Full Lifecycle: Open → Accept → Settle
   4.3 Credit Event Oracle: Design Options
   4.4 On-Chain Testing: Arbitrum Sepolia Results
   4.5 Gas Cost Analysis

5. Legal Analysis (10pp)
   5.1 AAOIFI Shariah Compliance Assessment
   5.2 Jurisdictional Analysis: 5 Markets
   5.3 ISDA/IIFM Documentation Framework
   5.4 Regulatory Pathway: Dubai as Pilot Jurisdiction

6. Liquidity Bootstrapping (6pp)
   6.1 Market Structure Design
   6.2 BRKX Incentive Mechanism
   6.3 Game-Theoretic Analysis
   6.4 Liquidity Milestones

7. Systemic Risk Analysis (3pp)
   7.1 Does iCDS Concentrate or Disperse Risk?
   7.2 Circuit Breakers and Position Limits
   7.3 Comparison to 2008 CDS Lessons

8. Conclusion (2pp)

References
Appendix A: iCDS.sol Source Code (full)
Appendix B: Draft iCDS Term Sheet
Appendix C: Jurisdictional Comparison Table (detailed)
Appendix D: BRKX Emission Schedule
```

---

## Data Requirements

| Source | What | Access |
|---|---|---|
| Bloomberg / Refinitiv | CDS spreads for 20+ GCC/Islamic entities | Dr. Bhuyan university access |
| Moody's / S&P | Recovery rate tables by sector | Free summary reports |
| ISDA IIFM | Tahawwut Master Agreement documentation | Free download |
| AAOIFI | Standard No. 1 (Derivatives) text | Paid membership or university library |
| VARA Dubai | Virtual Asset Rulebook 2023 | Free (public) |
| BNM Malaysia | IFSA 2013 + guidelines | Free (public) |
| MAS Singapore | CMS Act guidelines | Free (public) |
| Arbiscan | On-chain tx data from deployed iCDS.sol | Free |

---

## Target Journals

1. **Journal of Financial Regulation** (Oxford) — perfect fit for legal + financial analysis
2. **Capital Markets Law Journal** — if legal section is strongest
3. **Journal of Corporate Finance** — if financial analysis dominates
4. **Review of Financial Studies** — reach journal (very technical implementation required)
5. **Journal of Financial Stability** — if systemic risk section is strongest
6. **ISRA International Journal of Islamic Finance** — guaranteed acceptance, good for fatwa/legal citations

**Also relevant for**: Law review submission at Harvard Islamic Law / UCLA Islamic Finance Law

**Target JEL codes:** G12, G13, G18, K22, Z12

---

## Timeline

| Phase | Task | Duration |
|---|---|---|
| Financial analysis | CDS data pull, κ estimation, spread comparison | 3 weeks |
| Legal research | AAOIFI, 5 jurisdictions, ISDA docs | 4 weeks |
| Smart contract | Extend iCDS.sol, oracle design, gas tests | 2 weeks |
| Liquidity design | BRKX mechanism, game theory model | 2 weeks |
| Writing | Draft paper (longest paper of the three) | 5 weeks |
| Review | Internal → SSRN preprint | 2 weeks |
| **Total** | | **~18 weeks** |

---

## Connection to Baraka Protocol

This is the most directly connected paper to the protocol:
- `iCDS.sol` is already deployed at `0xc4E8907619C8C02AF90D146B710306aB042c16c5` (Arbitrum Sepolia)
- Paper 2C provides:
  - The academic citation justifying the `s* = κ(1−δ)` pricing formula in the contract
  - The legal analysis needed for regulatory approval to operate the iCDS product
  - The BRKX incentive design for liquidity bootstrapping
  - The credit event oracle architecture (currently the biggest missing piece for mainnet)
- This paper is the **go-to-market document** for the iCDS product

Once this paper is published, Baraka Protocol can approach VARA Dubai with:
> "Here is our academic paper. Here is our deployed contract. Here is the legal analysis showing compliance. We want to operate this product under VARA's virtual asset rulebook."

---

## Sequencing Note

Paper 2A should be completed first — it provides the empirical κ̂ values used in Section 3 of Paper 2C (the pricing comparison study). Paper 2B can be written in parallel with 2C. The natural sequence is:

```
Paper 2 (done) → Paper 2A (empirical κ) → Paper 2C (iCDS implementation, uses 2A data)
                                        ↘ Paper 2B (takaful, parallel)
```

---

*Plan created: March 2026*
*Author: Shehzad Ahmed (Baraka Protocol / Arcus Quant Fund)*
*Depends on: Paper 2 (theory), Paper 2A (empirical κ values), iCDS.sol (deployed contract)*
*Key external input: Legal review from VARA/BNM/MAS consultation + AAOIFI Shariah scholar sign-off*
