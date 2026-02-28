# Paper 2B — Plan

## Title
**"Actuarial Properties of the κ-Rate Under Stochastic Hazard: CIR Applications to Agricultural Takaful in South Asia"**

## One-Line Summary
We test the stochastic-κ CIR takaful pricing formula from Paper 2 against real agricultural loss data from Bangladesh, Pakistan, and Indonesia — estimating κ from actuarial tables and verifying that the closed-form premium `π = κ_mort · B` holds in practice.

---

## The Core Question
Paper 2 derives the continuous takaful premium formula `π = κ · B` (premium = intensity × benefit) and extends it to stochastic κ via the CIR model.
**Paper 2B asks: does this formula price agricultural takaful correctly against observed loss data?**

Agricultural takaful is the fastest-growing Shariah-compliant insurance market in South/Southeast Asia, yet premiums are still priced using conventional actuarial tables — often incorporating implicit riba through the discount rate. We provide the first fully riba-free actuarial formula and test it.

---

## Research Questions

1. Can κ (hazard intensity) be reliably estimated from agricultural loss tables (drought, flood, crop failure) using MLE or GMM?
2. Does the closed-form CIR premium formula `π = κ̄ · B · A(T) · e^{−B(T)κ₀}` match observed takaful premiums in Bangladesh, Pakistan, and Indonesia?
3. Is the stochastic-κ formula better calibrated than the constant-κ formula `π = κ · B`? (Test via AIC/BIC)
4. What is the empirical κ̄ (long-run mean hazard) and ν (volatility) for South Asian agricultural risk?
5. Does κ exhibit mean reversion? (i.e., is the CIR assumption justified, or is κ non-stationary?)
6. Does the κ-formula under/over-price relative to conventional actuarial premiums? If so, by how much — and is the difference attributable to the removed interest loading?

---

## Methodology

### Step 1 — Data Collection

**Agricultural loss data (κ estimation):**
- Bangladesh: Bangladesh Meteorological Department (BMD) — annual drought frequency + crop loss statistics, 1980–2024
- Pakistan: Pakistan Bureau of Statistics — flood loss data, Indus Basin records
- Indonesia: BNPB (National Disaster Management Agency) — annual disaster loss reports
- India (comparison): IMD drought monitoring data

**Takaful premium data (model validation):**
- Bangladesh: SadharanBima and Green Delta takaful products
- Pakistan: Pak-Qatar Family Takaful / Salama Takaful crop products
- Indonesia: Asuransi Ramayana Takaful / ASEI (state crop insurance = takaful-like)
- Malaysia (benchmark): MSIG Takaful / Etiqa — most sophisticated market, best data

**Conventional insurance comparison:**
- World Bank IBRD/IDA parametric insurance products (ACRE Africa, ARC)
- Swiss Re Agri data (public annuals)

### Step 2 — Estimating κ from Actuarial Tables

For a Poisson loss process, the MLE estimator for κ from annual loss counts `{n₁, n₂, ..., n_T}` is:
```
κ̂ = (1/T) · Σ nₜ
```
For compound events (drought severity index > threshold), use:
```
κ̂ = − log(1 − p̂)
```
where p̂ is the empirical annual loss probability.

For stochastic κ (CIR), estimate {α, κ̄, ν} via:
- **Method 1**: Euler-Maruyama GMM (match first two moments of κ)
- **Method 2**: MCMC (Bayesian CIR, prior: κ̄ ~ LogNormal(0,1))
- **Method 3**: Quasi-MLE on discretized Ornstein-Uhlenbeck

### Step 3 — Premium Formula Validation

**Constant κ formula (Paper 2, baseline):**
```
π_const = κ̂ · B
```

**Stochastic κ formula (Paper 2, Section 7.3):**
```
π_CIR = B · κ₀ · A(T) · exp(−B_CIR(T) · κ₀)
```
where A(T), B_CIR(T) are the CIR Laplace transform coefficients.

**Comparison metric**: mean absolute percentage error (MAPE) between formula output and observed premium `π_obs`:
```
MAPE = |π_formula − π_obs| / π_obs × 100%
```

**Benchmark**: conventional Bühlmann-Straub credibility premium (standard actuarial formula).

### Step 4 — Interest Loading Decomposition

Decompose observed conventional insurance premium into:
```
π_conv = π_pure_risk + π_interest_loading + π_profit_margin
```
Show that `π_interest_loading > 0` in conventional products (riba identification), and that the κ-formula's `π = κ · B` naturally excludes this component.

This gives us the **explicit dollar value of riba in conventional agricultural insurance** — a powerful result for Shariah compliance advocacy.

### Step 5 — Robustness Checks

- Vary benefit amount B: {$1k, $5k, $10k, $50k} per hectare
- Vary κ estimation window: {5yr, 10yr, 20yr, full sample}
- Compare κ across climate zones within each country (test geographic variation)
- Stress test: simulate κ doubling (climate change scenario) and re-price

---

## Expected Contributions

1. **First empirical test of κ-rate takaful pricing** — theoretical formula validated against real data
2. **Riba decomposition in agricultural insurance** — quantifies the interest loading removed by κ-framework
3. **Stochastic κ for climate risk** — CIR model captures increasing hazard frequency (climate change = rising κ̄)
4. **Country-level κ calibration** — actuarial tables for BD, PK, ID usable by practitioners
5. **Policy contribution** — shows microfinance + takaful bundling for smallholder farmers
6. **Dr. Bhuyan connection** — Bangladesh angle, South Asian data, development finance journals

---

## Paper Structure (Target: 30–35 pages, empirical finance/actuarial)

```
1. Introduction (3pp)
   1.1 Agricultural Risk and the Riba Problem
   1.2 The κ-Rate: A Riba-Free Intensity
   1.3 Contribution and Organisation

2. Theoretical Framework (5pp)
   2.1 Recap: κ-Rate Takaful Pricing from Paper 2
   2.2 The Constant-κ Formula: π = κB
   2.3 Stochastic κ: The CIR Extension
   2.4 CIR Closed Form: A(T) and B(T) Derivation
   2.5 Shariah Compliance: Why κ ≠ Riba

3. Data (5pp)
   3.1 Agricultural Loss Data: Bangladesh, Pakistan, Indonesia
   3.2 Takaful Premium Observations
   3.3 Conventional Insurance Benchmark
   3.4 Descriptive Statistics

4. Estimation (6pp)
   4.1 MLE Estimation of Constant κ
   4.2 GMM / MCMC for CIR Parameters
   4.3 Identification and Robustness

5. Results (10pp)
   5.1 Estimated κ Values by Country and Crop
   5.2 Constant κ Formula vs. Observed Premiums
   5.3 CIR Extension: Better Fit?
   5.4 Interest Decomposition: Riba in Conventional Premiums
   5.5 Climate Change Scenario: κ Under Stress
   5.6 Country Comparison

6. Discussion (3pp)
   6.1 Practical Implementation for Takaful Operators
   6.2 Integration with Baraka Protocol (TakafulPool.sol)
   6.3 Limitations: Data Quality, Recovery Rate Assumptions

7. Conclusion (2pp)

References
Appendix A: CIR Laplace Transform Derivation
Appendix B: Country-Level Loss Data Tables
Appendix C: MCMC Diagnostic Plots
```

---

## Data Requirements

| Source | What | Access |
|---|---|---|
| Bangladesh Meteorological Dept (BMD) | Annual drought/flood frequency, 1980–2024 | Free (public) |
| Pakistan Bureau of Statistics | Agricultural loss statistics | Free (public) |
| BNPB Indonesia | Annual disaster loss reports | Free (public) |
| SadharanBima / Green Delta BD | Takaful product premium schedules | Request directly |
| Pak-Qatar / Salama Takaful PK | Crop takaful premium rates | Request directly |
| ASEI / Etiqa Indonesia | Parametric product pricing | Public documents |
| Swiss Re Agricultural Reports | Global crop loss benchmarks | Free annual PDFs |
| World Bank IBRD parametric insurance | Comparative conventional benchmark | Free |

**Key advantage:** Dr. Bhuyan was born in Bangladesh, has research connections in Dhaka, and has published on South Asian economics. Access to Bangladesh data and local takaful operators is achievable through his network.

---

## Target Journals

1. **Journal of Risk and Insurance** (top actuarial journal)
2. **Insurance: Mathematics and Economics** (top mathematical actuarial)
3. **Geneva Risk and Insurance Review** — good for Shariah/takaful
4. **Journal of Development Economics** — if development/poverty angle is prominent
5. **World Development** — very high impact, if framing is financial inclusion
6. **Journal of Islamic Accounting and Business Research** — safe landing

**Target JEL/subject codes:** G22, Q14 (agricultural economics), O16 (finance/development), Z12

---

## Timeline

| Phase | Task | Duration |
|---|---|---|
| Data | Collect loss tables, takaful premiums | 3 weeks |
| Theory | Complete CIR A(T)/B(T) derivations | 1 week |
| Code | Python: MLE + GMM + MCMC + premium formula | 3 weeks |
| Analysis | Empirical results, tables, plots | 2 weeks |
| Writing | Draft paper | 4 weeks |
| Review | Internal → SSRN preprint | 2 weeks |
| **Total** | | **~15 weeks** |

---

## Connection to Baraka Protocol

This paper directly validates `TakafulPool.sol`, which uses:
```solidity
tabarru = quotePut(coverage, ...) * coverage / WAD;
```
The `quotePut` call uses the everlasting option formula — a close cousin to the `π = κB` formula proven here. If Paper 2B validates this empirically, it provides academic backing for the TakafulPool contract's pricing mechanism.

Future: a live κ oracle for agricultural risk could feed directly into `TakafulPool.sol`, making real-world crop takaful on-chain.

---

*Plan created: March 2026*
*Author: Shehzad Ahmed (Baraka Protocol / Arcus Quant Fund)*
*Depends on: Paper 2 (paper2_credit_equivalence.tex) — specifically Section 6 (takaful) and Section 7.3 (stochastic κ)*
*Key collaborator: Dr. Rafiq Bhuyan (South Asian data access, development finance expertise)*
