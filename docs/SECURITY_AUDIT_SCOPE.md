# Baraka Protocol — Security Audit Scope
**Date:** March 4, 2026
**Network:** Arbitrum Sepolia (testnet) → Arbitrum One (mainnet target)
**GitHub:** https://github.com/Arcus-Quant-Fund/BarakaDapp

---

## 1. Project Overview

Baraka Protocol is the world's first Shariah-compliant perpetual futures DEX on Ethereum L2 (Arbitrum). The core financial innovation is `ι = 0` — the interest parameter in the Ackerer–Hugonnier–Jermann (2024) funding formula is hardcoded to zero, eliminating riba (interest) from the funding mechanism. The protocol was developed alongside 6 SSRN working papers.

**Key protocol properties:**
- Funding rate: `F = (mark − index) / index` — symmetric, no interest term
- Circuit breaker: ±75 bps clamp (not an interest floor)
- Collateral: USDC, PAXG, XAUT (no ETH/volatile assets as margin)
- Max leverage: 5× (hardcoded in ShariahGuard)
- Fee currency: BRKX governance token (4 tiers: 5.0% → 2.5% bps)
- Insurance fund: 50% of protocol fees
- Oracle: dual Chainlink/Pyth with TWAP circuit breaker

---

## 2. Smart Contracts in Scope

| Contract | File | SLOC | Priority |
|---|---|---|---|
| PositionManager | `src/core/PositionManager.sol` | 458 | **CRITICAL** |
| CollateralVault | `src/core/CollateralVault.sol` | 240 | **CRITICAL** |
| LiquidationEngine | `src/core/LiquidationEngine.sol` | 216 | **CRITICAL** |
| EverlastingOption | `src/core/EverlastingOption.sol` | 515 | **CRITICAL** |
| FundingEngine | `src/core/FundingEngine.sol` | 214 | HIGH |
| InsuranceFund | `src/insurance/InsuranceFund.sol` | 174 | HIGH |
| OracleAdapter | `src/oracle/OracleAdapter.sol` | 381 | HIGH |
| TakafulPool | `src/takaful/TakafulPool.sol` | 330 | HIGH |
| iCDS | `src/credit/iCDS.sol` | 392 | HIGH |
| PerpetualSukuk | `src/credit/PerpetualSukuk.sol` | 342 | MEDIUM |
| ShariahGuard | `src/shariah/ShariahGuard.sol` | 165 | MEDIUM |
| GovernanceModule | `src/shariah/GovernanceModule.sol` | 249 | MEDIUM |
| BRKXToken | `src/token/BRKXToken.sol` | 89 | LOW |

**Total: 13 contracts, ~3,800 SLOC (excluding interfaces)**

---

## 3. Interfaces (informational only)

- `IEverlastingOption.sol` (41 lines)
- `IOracleAdapter.sol`, `ILiquidationEngine.sol`, `ICollateralVault.sol`, `IShariahGuard.sol`, `IInsuranceFund.sol`, `IPositionManager.sol`

---

## 4. External Dependencies

| Dependency | Version | Usage |
|---|---|---|
| OpenZeppelin Contracts | ^5.0 | ERC20, Ownable2Step, Votes, Permit, ReentrancyGuard |
| Chainlink | latest | Price feeds (primary oracle) |
| Pyth Network | latest | Price feeds (secondary oracle) |
| forge-std | latest | Test framework (out of scope) |

---

## 5. Deployed Testnet Addresses (Arbitrum Sepolia, chain 421614)

| Contract | Address |
|---|---|
| OracleAdapter | `0x86C475d9943ABC61870C6F19A7e743B134e1b563` |
| ShariahGuard | `0x26d4db76a95DBf945ac14127a23Cd4861DA42e69` |
| FundingEngine | `0x459BE882BC8736e92AA4589D1b143e775b114b38` |
| InsuranceFund | `0x7B440af63D5fa5592E53310ce914A21513C1a716` |
| CollateralVault | `0x0e9e32e4e061Db57eE5d3309A986423A5ad3227E` |
| LiquidationEngine | `0x17D9399C7e17690bE23544E379907eC1AB6b7E07` |
| PositionManager | `0x035E38fd8b34486530A4Cd60cE9D840e1a0A124a` |
| GovernanceModule | `0x8c987818dffcD00c000Fe161BFbbD414B0529341` |
| BRKXToken | `0xD3f7E29cAC5b618fAB44Dd8a64C4CC335C154A32` |
| EverlastingOption | `0x977419b75182777c157E2192d4Ec2dC87413E006` |
| TakafulPool | `0xD53d34cC599CfadB5D1f77516E7Eb326a08bb0E4` |
| PerpetualSukuk | `0xd209f7B587c8301D5E4eC1691264deC1a560e48D` |
| iCDS | `0xc4E8907619C8C02AF90D146B710306aB042c16c5` |

All 13 contracts are **verified on Arbiscan**: https://sepolia.arbiscan.io

---

## 6. Existing Security Work

| Item | Status |
|---|---|
| Slither static analysis | 0 HIGH, 0 MEDIUM (CI enforced) |
| Foundry unit tests | 369/369 passing |
| Invariant tests | 9 invariants (ι=0 + max leverage), 256 runs × 128 depth |
| Integration tests | 30/30 (full E2E, fork tests) |
| Fuzz tests | 1000 runs on all core math |
| Automated E2E | `bash e2e.sh` — 6 on-chain assertions pass |

---

## 7. Key Risk Areas (Suggested Focus)

### 7.1 Critical — Financial Logic
- **Funding rate manipulation**: Can `FundingEngine` be forced to accumulate unbounded funding beyond ±75 bps? Can the circuit breaker be bypassed?
- **Liquidation griefing**: Can a liquidator front-run, brick, or selectively avoid unhealthy positions? `LiquidationEngine.liquidate()` re-checks health inline.
- **Collateral accounting**: `CollateralVault` tracks `_lockedBalance` and `_freeBalance` separately. Can locked → free bypass be triggered?
- **Position PnL**: `PositionManager.close()` uses `EverlastingOption.quoteAtSpot()` for PnL. Any precision loss or manipulation in the fixed-point math (`lnWad`, `expWad`)?
- **Fee extraction**: `CollateralVault.chargeFromFree()` sends fees to InsuranceFund + Treasury. Can this be called by non-PositionManager callers?

### 7.2 High — Oracle Security
- `OracleAdapter` uses dual Chainlink/Pyth with ±2% divergence circuit breaker + 15-min TWAP
- **Staleness**: feeds are rejected if `block.timestamp - updatedAt > STALE_THRESHOLD (3600s)`
- **Price manipulation**: Can a flash-loan manipulate the TWAP ring-buffer? Buffer is 8 slots at 5-min intervals.
- **kappa signal**: `getKappaSignal()` emits `KappaAlert` at regime changes. Can this be spammed to DoS the insurance mechanism?

### 7.3 Medium — Governance
- `GovernanceModule`: `TIMELOCK_DELAY = 48 hours`. Can a malicious governance vote change ShariahGuard's `MAX_LEVERAGE` or `shariahMultisig` before the timelock?
- **Veto mechanism**: Does the veto path have the same reentrancy protection as the execute path?

### 7.4 Medium — Islamic Finance Compliance Checks
- `ShariahGuard.checkCompliance()`: Does the on-chain logic correctly enforce the ι=0 constraint at all times? Can it be bypassed by a governance vote?
- `TakafulPool.tabarru` calculation uses `EverlastingOption.quotePut()`. Can the put pricing be manipulated to drain the takaful pool?
- `iCDS` quarterly settlement: Is there a griefing vector where a protection seller can delay or prevent settlement?

---

## 8. Out of Scope

- Frontend / subgraph code
- Oracle infrastructure (Chainlink/Pyth internals)
- Upgradeability (contracts are NOT upgradeable — immutable deploys)
- Gas optimization (not a security concern)

---

## 9. Testing and CI

```bash
# Clone and run full test suite
git clone https://github.com/Arcus-Quant-Fund/BarakaDapp
cd contracts
forge test -vvv  # 369 tests, all pass
forge test --match-path "test/invariant/*" --fuzz-runs 1000  # invariant suite

# Static analysis
slither . --exclude-dependencies --fail-high --fail-medium
```

---

## 10. Contact

**Shehzad Ahmed** — Founder & CEO, Arcus Quant Fund
- Email: contact@arcusquantfund.com
- GitHub: https://github.com/Arcus-Quant-Fund/BarakaDapp
- Website: https://arcusquantfund.com

**Academic context:** Auditors may find the SSRN working papers useful for understanding the `EverlastingOption` and `FundingEngine` math:
- Paper 1 (ι=0 foundation): SSRN 6322778
- Paper 2 (random stopping / credit equivalence): SSRN 6322858

---

## 11. Timeline & Budget

- **Target mainnet launch:** 30 days from audit kickoff
- **Budget:** Open to proposals — please include estimated timeline and price breakdown
- **Preferred format:** Report with severity classification (Critical / High / Medium / Low / Info)
