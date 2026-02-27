# BARAKA PROTOCOL — SHARIAH COMPLIANCE STATEMENT
## Fatwa Placeholder Document (v0.1 — Testnet)

> **STATUS:** This is a placeholder document for testnet deployment.
> A formal fatwa signed by AAOIFI-certified scholars will replace this
> document before mainnet launch. The IPFS hash of that signed PDF will be
> recorded on-chain in `ShariahGuard.fatwaIPFS[token]`.

---

## 1. PROTOCOL OVERVIEW

**Baraka Protocol** is a decentralised perpetual futures exchange deployed on
Arbitrum One. It is designed from first principles to comply with Islamic
finance principles as codified in AAOIFI (Accounting and Auditing Organisation
for Islamic Financial Institutions) standards.

- **Primary market (testnet):** BTC/USD perpetual
- **Collateral:** USDC (testnet), with PAXG / XAUT gold-backed tokens planned
  for mainnet as Shariah-preferred collateral
- **Maximum leverage:** 5x (hardcoded immutable constant in `ShariahGuard.sol`)
- **Smart contract network:** Arbitrum Sepolia (testnet), Arbitrum One (mainnet)

---

## 2. ISLAMIC FINANCE PRINCIPLES ADDRESSED

### 2.1 Riba (Interest) — ELIMINATED

The funding rate formula contains **no interest component**:

```
F = (mark_price - index_price) / index_price
```

The interest parameter `iota` (ι) is hardcoded to **zero** in `FundingEngine.sol`.

**Mathematical basis:** Ackerer, Hugonnier & Jermann (2024), *"Perpetual Futures
Pricing,"* Theorem 3 / Proposition 3. Under ι=0, the net transfer across all
market participants equals zero in expectation. No value is extracted from the
system as interest — funding payments are purely redistributive between long and
short participants based on price divergence.

**Research paper:** Ahmed, Bhuyan & Islam (2026), *"Zero-Interest Perpetual
Futures: A Shariah-Compliant Derivatives Framework,"* provides the full proof
that ι=0 eliminates riba while preserving price-discovery efficiency.

### 2.2 Maysir (Gambling) — MITIGATED

Leverage is capped at 5x by an **immutable constant** (`MAX_LEVERAGE = 5`) in
`ShariahGuard.sol`. This constant cannot be changed by any admin, multisig, or
governance vote — it is compiled into the contract bytecode permanently.

A symmetric circuit breaker (±75 basis points) clamps the funding rate. This is
**not** an interest floor; it prevents funding rate spirals that could cause
undercollateralisation and force involuntary losses.

### 2.3 Gharar (Excessive Uncertainty) — MITIGATED

- All prices sourced from dual Chainlink oracle feeds (60/40 weighted TWAP).
- 5-minute staleness threshold; stale prices revert all position actions.
- Only AAOIFI-reviewed assets may be used as collateral (`ShariahGuard.approveAsset`).
- Every approved collateral asset maps on-chain to its fatwa IPFS hash.

### 2.4 Qimar (Zero-Sum Gambling) — NOT APPLICABLE

Perpetual futures used for hedging and price discovery are permitted under
scholarly consensus as `bay al-salam`-adjacent instruments when the underlying
asset (BTC, gold) is permissible and no interest is charged. The net-zero
funding transfers further confirm no systemic wealth extraction.

---

## 3. CONTRACT ADDRESSES (Arbitrum Sepolia Testnet — 421614)

| Contract           | Address |
|--------------------|---------|
| OracleAdapter      | 0xB8d9778288B96ee5a9d873F222923C0671fc38D4 |
| ShariahGuard       | 0x26d4db76a95DBf945ac14127a23Cd4861DA42e69 |
| FundingEngine      | 0x459BE882BC8736e92AA4589D1b143e775b114b38 |
| InsuranceFund      | 0x7B440af63D5fa5592E53310ce914A21513C1a716 |
| CollateralVault    | 0x5530e4670523cFd1A60dEFbB123f51ae6cae0c5E |
| LiquidationEngine  | 0x456eBE7BbCb099E75986307E4105A652c108b608 |
| PositionManager    | 0x53E3063FE2194c2DAe30C36420A01A8573B150bC |
| GovernanceModule   | 0x8c987818dffcD00c000Fe161BFbbD414B0529341 |

All contracts are verified on Arbiscan:
https://sepolia.arbiscan.io/address/0x26d4db76a95DBf945ac14127a23Cd4861DA42e69

---

## 4. SHARIAH BOARD (PENDING — MAINNET)

The mainnet Shariah board will be a 3-of-5 multisig (`shariahMultisig` in
`ShariahGuard.sol`) composed of AAOIFI-certified Islamic finance scholars. Their
identities, affiliations, and signed fatwa documents will be published on-chain
and on the Baraka Protocol transparency page before mainnet launch.

**Target scholars:**
- AAOIFI-certified scholar (to be identified via Dr. Rafiq Bhuyan's network)
- IUB / University of Dhaka Islamic economics faculty
- Dubai Islamic economy network contact

---

## 5. AUDIT STATUS

| Item                  | Status       | Detail |
|-----------------------|--------------|--------|
| Unit tests (Forge)    | 60/60 pass   | FundingEngine + ShariahGuard, 1000 fuzz runs |
| Integration tests     | 30/30 pass   | Full lifecycle, liquidation, Shariah gate |
| E2E fork tests        | 6/6 pass     | Arbitrum Sepolia fork, 20s automated |
| Slither static analysis | Clean      | HIGH 0, MEDIUM 0 (Feb 2026) |
| External audit        | Pending      | Certik / OpenZeppelin pre-mainnet |
| Formal scholar review | Pending      | AAOIFI outreach — Month 2 |

---

## 6. RESEARCH REFERENCES

1. Ackerer, D., Hugonnier, J., & Jermann, U. (2024). *Perpetual Futures Pricing.*
   Swiss Finance Institute Research Paper.

2. Ahmed, S., Bhuyan, R., & Islam, M. (2026). *Zero-Interest Perpetual Futures:
   A Shariah-Compliant Derivatives Framework.* Working paper.

3. AAOIFI Shariah Standard No. 21 — Financial Papers (Bonds and Notes).

4. AAOIFI Shariah Standard No. 42 — Financial Rights and How They Are Exercised.

---

## 7. DISCLAIMER

This document is a placeholder for testnet purposes only. It does not constitute
a legal fatwa. The protocol will not launch on mainnet without a formal written
fatwa from at least one AAOIFI-certified Shariah scholar. The IPFS hash of the
signed fatwa PDF will permanently replace this document's hash in
`ShariahGuard.fatwaIPFS`.

---

*Prepared by: Shehzad Ahmed, Founder — Baraka Protocol / Arcus Quant Fund*
*Date: February 2026*
*Contact: contact@arcusquantfund.com*
