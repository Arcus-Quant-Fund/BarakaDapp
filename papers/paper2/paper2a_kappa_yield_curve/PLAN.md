# Paper 2A — Plan

## Title
**"The κ-Yield Curve: Empirical Estimation of the Convergence Intensity from Sukuk Panel Data"**

## One-Line Summary
We estimate κ — the riba-free convergence intensity from Ackerer et al. (2024) — directly from observed sukuk spreads, build the first empirical κ-yield curve for GCC and Malaysian markets, and test whether κ-implied spreads outperform SOFR-based models.

---

## The Core Question
Paper 2 proves theoretically that κ can replace the risk-free rate r in credit pricing.
**Paper 2A asks: what are the actual κ values in the real sukuk market, and do they work?**

If κ can be estimated from data, the entire theoretical edifice of Paper 2 becomes empirically verifiable and publishable in finance (not just Islamic finance) journals.

---

## Research Questions

1. Can κ be identified from sukuk yield spread panels using standard intensity estimation methods?
2. Does a κ-yield curve (κ vs. maturity) have the same shape properties as the conventional yield curve (upward-sloping, inverted, humped)?
3. Do κ-implied spreads explain observed sukuk spreads better than SOFR/LIBOR-based models?
4. Are κ estimates stable across countries (GCC vs. Malaysia) and sectors (sovereign vs. corporate)?
5. What is the term structure of κ — i.e., does `κ(T)` follow a predictable functional form (e.g., mean-reverting CIR)?

---

## Methodology

### Step 1 — Data Collection
- **Dataset**: Bloomberg sukuk panel — sovereign and quasi-sovereign sukuk from:
  - Saudi Arabia (SAMA), UAE (Ministry of Finance), Qatar, Bahrain, Kuwait
  - Malaysia (BNM sovereign sukuk), Indonesia (SBSN)
  - Corporate: Saudi Aramco, Emaar, Axiata
- **Period**: 2010–2025 (post-GFC, includes negative European rate era as control)
- **Variables per observation**: Issue date, maturity, coupon rate, yield at issuance, yield spread (over SOFR or equivalent), credit rating (S&P/Moody's), currency, jurisdiction

### Step 2 — κ Extraction from Spread Data
From Paper 2, Theorem 1: the fair sukuk spread is
```
s = κ · (1 − Recovery Rate)
```
So for observed spread `s_obs` and assumed recovery rate `δ`:
```
κ̂ = s_obs / (1 − δ)
```
Use:
- δ = 0.40 (Basel II standard for unsecured corporate)
- δ = 0.60 for sovereign (higher recovery in restructuring)
- Robustness check: δ ∈ {0.20, 0.40, 0.60, 0.80}

### Step 3 — The κ-Yield Curve
For each issuer / country, estimate κ̂(T) across maturities T ∈ {2, 3, 5, 7, 10, 15, 20, 30 years}.
Fit a Nelson-Siegel-Svensson (NSS) functional form to κ̂(T):
```
κ(T) = β₀ + β₁·f₁(T,τ₁) + β₂·f₂(T,τ₁) + β₃·f₂(T,τ₂)
```
This gives the **Islamic yield curve** — directly analogous to the conventional government bond yield curve but riba-free.

### Step 4 — Horse Race: κ-model vs SOFR-model
For each sukuk observation:
- **κ-model**: predicted spread = κ̂ × (1−δ)
- **SOFR-model**: predicted spread = conventional risky bond spread over SOFR
- Compare RMSE, MAE, R², and Diebold-Mariano test for equal predictive accuracy

### Step 5 — Panel Regression
```
s_{i,t} = α + β·κ̂_{i,t} + γ·X_{i,t} + ε_{i,t}
```
where X = {rating dummies, maturity, country FE, sector FE, VIX, oil price}.
H₀: β = 1 (κ is the complete explanation of spread)

### Step 6 — Time Series: κ Dynamics
For a balanced panel of 20+ sukuk with long histories, estimate a VAR/VECM of κ̂_t:
- Does κ mean-revert? Estimate α, κ̄, ν from the CIR model using GMM
- Does κ respond to credit events (rating downgrades, defaults)?
- Cross-country spillovers: does GCC κ Granger-cause Malaysian κ?

---

## Expected Contributions

1. **First empirical κ-yield curve** — directly analogous to the Bloomberg government bond yield curve, but constructed entirely without interest
2. **Validation of Paper 2 theory** — empirical proof that κ-pricing works in real sukuk markets
3. **New tool for Islamic portfolio managers** — κ-duration, κ-convexity for Shariah-compliant fixed income
4. **Cross-market comparison** — shows GCC and SEA sukuk markets are integrated (or not)
5. **Natural experiment** — 2014–2022 negative European rate era as out-of-sample validation: κ > 0 always, even when r < 0

---

## Paper Structure (Target: 25–30 pages)

```
1. Introduction (3pp)
   1.1 The Riba Prohibition and Yield Curve Construction
   1.2 Contribution and Organisation

2. Theoretical Framework (4pp)
   2.1 The κ-Rate from Ackerer et al. and Paper 2
   2.2 From κ to Sukuk Spreads (Theorem 1 recap)
   2.3 The κ Yield Curve: Definition and Properties

3. Data (4pp)
   3.1 Sample Construction
   3.2 Descriptive Statistics
   3.3 Time Series of Spreads by Country/Sector

4. Estimation Methodology (5pp)
   4.1 Point Estimation of κ from Spreads
   4.2 Nelson-Siegel-Svensson Curve Fitting
   4.3 GMM Estimation of CIR Dynamics

5. Results (8pp)
   5.1 κ̂ Estimates: Cross-Section
   5.2 The κ-Yield Curve: Shape and Properties
   5.3 Predictive Accuracy: κ-Model vs. SOFR-Model
   5.4 Panel Regression Results
   5.5 Time Series: CIR Dynamics of κ
   5.6 Robustness: Recovery Rate Sensitivity

6. Discussion (3pp)
   6.1 What κ Tells Us About Islamic Credit Markets
   6.2 Implications for Islamic Fund Management
   6.3 Limitations

7. Conclusion (2pp)

References
Appendix A: Full Data Table (all 100+ sukuk)
Appendix B: Country-Level κ Curves
```

---

## Data Requirements

| Source | What | Cost |
|---|---|---|
| Bloomberg Terminal | Sukuk yield panels (10-yr history) | University access (Dr. Bhuyan / Monarch Business School) |
| IIFM Sukuk Database | Issue terms, structuring details | Free for members |
| Refinitiv Eikon | Corporate sukuk data | Alternative to Bloomberg |
| S&P / Moody's | Credit ratings history | Free via university |
| FRED (St. Louis Fed) | SOFR, OIS rates for benchmarking | Free |

**Key access point:** Dr. Rafiq Bhuyan (Co-Founder) has Bloomberg Terminal access through his university position. This is the data gateway for this paper.

---

## Target Journals

1. **Journal of Financial Economics** (top-5) — if the κ-model outperforms SOFR at high significance
2. **Journal of Finance** — same
3. **Journal of International Money and Finance** — very good for EM / sukuk work
4. **Review of Finance** — strong empirical finance
5. **Pacific-Basin Finance Journal** — high acceptance for Southeast Asia sukuk work
6. **Journal of Islamic Accounting and Business Research** — safe landing if top-5 reject

**Target JEL codes:** G12, G13, G15, F34, Z12

---

## Timeline

| Phase | Task | Duration |
|---|---|---|
| Data | Bloomberg panel pull via Dr. Bhuyan | 2 weeks |
| Code | Python estimation pipeline (κ̂ extraction + NSS + GMM) | 2 weeks |
| Analysis | Run all regressions, produce tables | 1 week |
| Writing | Draft paper from plan | 3 weeks |
| Revision | Internal review → SSRN preprint | 2 weeks |
| **Total** | | **~10 weeks** |

---

## Connection to Baraka Protocol

This paper directly validates the pricing engine used in:
- `PerpetualSukuk.sol` — sukuk pricing
- `iCDS.sol` — iCDS spread `s* = κ(1−δ)`
- Future: a real-time κ oracle would feed into the Baraka Protocol on-chain

The κ-yield curve could eventually replace Chainlink price feeds for sukuk pricing, making Baraka Protocol fully self-contained for Islamic fixed income products.

---

*Plan created: March 2026*
*Author: Shehzad Ahmed (Baraka Protocol / Arcus Quant Fund)*
*Depends on: Paper 2 (paper2_credit_equivalence.tex) — theoretical foundation*
