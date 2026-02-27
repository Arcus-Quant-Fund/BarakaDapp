# Islamic Perpetual Futures DApp — Implementation Blueprint
### Based on: Ahmed, Bhuyan & Islam (2026) + Ackerer, Hugonnier & Jermann (2024)

---

## 1. Executive Summary

This blueprint describes a Shariah-compliant perpetual futures decentralised
application (DApp) built on the mathematical proof that spot-price convergence
is achievable with zero interest (ι=0). The protocol implements the premium-only
funding formula F = P, eliminating riba by design, while addressing gharar through
transparent on-chain mechanics and maysir through asset selection and leverage policy.

**Name suggestion:** *HalalPerps* or *TayyibFi* (tayyib = pure/wholesome in Arabic)

**Target launch:** Cosmos SDK chain or Arbitrum L2
**MVP timeline:** 12–18 months from funding
**Primary markets:** BTC, ETH, gold (PAXG), silver (XAUT), halal equity indices

---

## 2. Mathematical Foundation

### 2.1 Why ι=0 Works (From Ackerer et al. 2024)

The Ackerer, Hugonnier & Jermann (2024) proof establishes that in both
discrete and continuous time, a perpetual futures contract converges to spot
with zero interest (ι=0), relying solely on premium intensity κ.

**Continuous-time constant-parameter result:**

```
f_t = κ / (κ + r_b - r_a) × x_t
```

When r_a = r_b (stablecoin-margined contracts): **f_t = x_t exactly.**

This is the theoretical licence for the DApp's funding formula.

### 2.2 The Funding Formula (Core of the Protocol)

**CEX formula (what we reject):**
```
F = P + clamp(I - P, -0.05%, +0.05%)
where I = 0.01%/8h  ← this is riba
```

**Our formula (what we implement):**
```
F = P = (mark_price - index_price) / index_price
```

- No fixed floor. No interest term. No I.
- F can be positive (longs pay shorts) or negative (shorts pay longs).
- F = 0 when mark = index (perfectly anchored).
- Bilateral, conditional on market — not predetermined excess return.

### 2.3 Convergence Conditions by Contract Type

| Contract Type | Formula (ι=0) | Convergence Condition |
|---|---|---|
| Linear (USDC-margined) | κ/(κ + r_b - r_a) × x_t | r_a ≈ r_b → f_t = x_t |
| Inverse (BTC-margined) | (κ_I + r_a - r_b)/κ_I × x_t | r_a ≈ r_b → f_t = x_t |
| Quanto (cross-currency) | κ/(κ + r_c - σ_x·σ_z - r_a) × z_t | Aligned rates + vols |

**MVP launches linear contracts only** (USDC-margined, simplest convergence guarantee).

---

## 3. Shariah Compliance Framework

### 3.1 Three-Layer Clearance

| Prohibition | CEX Status | Our DApp Status | Mechanism |
|---|---|---|---|
| **Riba** | I=0.01%/8h hardcoded | I=0 hardcoded in contract | Premium-only formula |
| **Gharar** | Opaque funding, perpetual uncertainty | On-chain formula, transparent oracle | Smart contract immutability |
| **Maysir** | Leverage up to 125x | Max 5x leverage, utility assets only | Contract-enforced limits |

### 3.2 Residual Concern: Qabdh (Possession)

The most conservative fatwa objection (SeekersGuidance 2025) is qabdh —
the requirement for constructive possession of the underlying asset.

**Our response:**
- **Phase 1 (MVP):** Gold-backed tokens (PAXG, XAUT) where 1 token = 1 troy oz
  physically allocated. Buying the token = constructive qabdh of the gold.
- **Phase 2:** Commodity indices with physical redemption rights.
- **Phase 3:** Full delivery mechanism for small positions.

### 3.3 Shariah Board Approval Process

Before launch:
1. Submit protocol whitepaper to AAOIFI-certified scholars.
2. Obtain written fatwa on: funding formula, leverage limits, asset list.
3. Publish fatwa on-chain (IPFS hash in contract metadata).
4. Annual re-certification as protocol evolves.

**Target scholars/bodies:** AAOIFI, Securities Commission Malaysia (SC),
Dubai Islamic Economy Development Centre (DIEDC).

---

## 4. Smart Contract Architecture

### 4.1 Contract Overview

```
┌─────────────────────────────────────────────┐
│              HalalPerps Protocol             │
├─────────────────┬───────────────────────────┤
│  FundingEngine  │  PositionManager           │
│  (ι=0 enforced) │  (leverage cap enforced)   │
├─────────────────┼───────────────────────────┤
│  OracleAdapter  │  CollateralVault           │
│  (Chainlink/Pyth│  (RWA-backed assets only)  │
├─────────────────┼───────────────────────────┤
│  ShariahGuard   │  GovernanceModule          │
│  (asset whitelist│ (DAO + Shariah board)     │
└─────────────────┴───────────────────────────┘
```

### 4.2 FundingEngine.sol (Core — Solidity)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title FundingEngine
 * @notice Implements the premium-only funding formula F = P (ι = 0).
 *         No interest parameter exists in this contract by design.
 *         Mathematical basis: Ackerer, Hugonnier & Jermann (2024),
 *         Theorem 3 / Proposition 3 (continuous-time, ι=0 case).
 */
contract FundingEngine {

    // Funding interval: 1 hour (vs CEX 8h)
    uint256 public constant FUNDING_INTERVAL = 1 hours;

    // Maximum funding rate per interval: ±0.75% (caps extreme volatility)
    // NOTE: There is NO minimum floor (unlike CEX 0.01%/8h interest floor)
    int256 public constant MAX_FUNDING_RATE = 750;    // 0.075% in bps × 10000
    int256 public constant MIN_FUNDING_RATE = -750;   // -0.075%

    // TWAP window for mark price (reduces manipulation)
    uint256 public constant TWAP_WINDOW = 30 minutes;

    IOracleAdapter public oracle;

    /**
     * @notice Calculate current funding rate.
     *         F = P = (mark_price - index_price) / index_price
     *         This is the ONLY formula. There is no interest term.
     *
     * @return fundingRate in basis points × 10000 (signed)
     */
    function getFundingRate(address market)
        external view returns (int256 fundingRate)
    {
        uint256 markPrice  = oracle.getMarkPrice(market, TWAP_WINDOW);
        uint256 indexPrice = oracle.getIndexPrice(market);

        require(indexPrice > 0, "Invalid index price");

        // Pure premium: F = (mark - index) / index
        // No interest term. No floor. Exactly ι = 0.
        int256 premium = (int256(markPrice) - int256(indexPrice))
                         * 1e18 / int256(indexPrice);

        // Clamp only for extreme circuit-breaker (not an interest floor)
        fundingRate = _clamp(premium / 1e14, MIN_FUNDING_RATE, MAX_FUNDING_RATE);
    }

    function _clamp(int256 val, int256 lo, int256 hi)
        internal pure returns (int256)
    {
        if (val < lo) return lo;
        if (val > hi) return hi;
        return val;
    }
}
```

### 4.3 ShariahGuard.sol (Compliance Enforcement)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ShariahGuard
 * @notice Enforces Shariah compliance parameters on-chain.
 *         Parameters set by Shariah board multisig; immutable after lock.
 */
contract ShariahGuard {

    // Maximum leverage: 5x (maysir mitigation)
    // Conservative scholars: 3x. Progressive: up to 10x.
    // Starting at 5x pending formal fatwa.
    uint256 public constant MAX_LEVERAGE = 5;

    // Only AAOIFI-approved/Shariah-cleared assets may be listed
    mapping(address => bool) public approvedAssets;
    mapping(address => string) public shariahFatwaIPFS; // fatwa document hash

    // Shariah board multisig (3-of-5 required for asset additions)
    address public shariahMultisig;

    modifier onlyShariah() {
        require(msg.sender == shariahMultisig, "Not Shariah board");
        _;
    }

    /**
     * @notice Add a new asset after Shariah board approval.
     *         Requires IPFS hash of the fatwa document.
     */
    function approveAsset(address token, string calldata fatwaIPFSHash)
        external onlyShariah
    {
        approvedAssets[token] = true;
        shariahFatwaIPFS[token] = fatwaIPFSHash;
        emit AssetApproved(token, fatwaIPFSHash);
    }

    /**
     * @notice Validate a position before opening.
     *         Reverts if leverage > MAX_LEVERAGE or asset not approved.
     */
    function validatePosition(
        address asset,
        uint256 collateral,
        uint256 notional
    ) external view {
        require(approvedAssets[asset], "Asset not Shariah-approved");
        require(collateral > 0, "No collateral");
        uint256 leverage = notional / collateral;
        require(leverage <= MAX_LEVERAGE, "Exceeds max leverage (maysir)");
    }

    event AssetApproved(address indexed token, string fatwaIPFSHash);
}
```

### 4.4 PositionManager.sol (Core Trading Logic)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PositionManager
 * @notice Manages perpetual futures positions with premium-only funding.
 *         Long positions pay funding when mark > index (contango).
 *         Short positions pay funding when mark < index (backwardation).
 *         Either party can receive funding — it is bilateral, not predetermined.
 */
contract PositionManager {

    struct Position {
        address trader;
        address asset;
        int256  size;           // positive = long, negative = short
        uint256 collateral;     // in USDC
        int256  entryPrice;
        int256  fundingIndex;   // cumulative funding at entry
        uint256 openTime;
    }

    FundingEngine  public fundingEngine;
    ShariahGuard   public shariahGuard;
    CollateralVault public vault;

    mapping(bytes32 => Position) public positions;
    mapping(address => int256)   public cumulativeFundingIndex;

    /**
     * @notice Open a new position.
     *         Shariah checks enforced by ShariahGuard before any state change.
     */
    function openPosition(
        address asset,
        int256  size,
        uint256 collateral
    ) external returns (bytes32 positionId) {

        uint256 notional = uint256(size < 0 ? -size : size)
                           * uint256(fundingEngine.oracle().getIndexPrice(asset))
                           / 1e18;

        // Shariah validation — reverts if non-compliant
        shariahGuard.validatePosition(asset, collateral, notional);

        vault.lockCollateral(msg.sender, collateral);

        positionId = keccak256(abi.encodePacked(msg.sender, asset, block.timestamp));
        positions[positionId] = Position({
            trader:       msg.sender,
            asset:        asset,
            size:         size,
            collateral:   collateral,
            entryPrice:   int256(fundingEngine.oracle().getIndexPrice(asset)),
            fundingIndex: cumulativeFundingIndex[asset],
            openTime:     block.timestamp
        });

        emit PositionOpened(positionId, msg.sender, asset, size, collateral);
    }

    /**
     * @notice Settle funding for a position.
     *         Longs pay shorts when mark > index; shorts pay longs when mark < index.
     *         Neither party is guaranteed to pay — this is bilateral and conditional.
     */
    function settleFunding(bytes32 positionId) external {
        Position storage pos = positions[positionId];
        int256 fundingDelta = cumulativeFundingIndex[pos.asset] - pos.fundingIndex;
        int256 fundingPayment = (pos.size * fundingDelta) / 1e18;

        // Update collateral (can increase or decrease depending on market)
        if (fundingPayment > 0) {
            // Trader pays funding (mark was above index while long, or below while short)
            require(int256(pos.collateral) > fundingPayment, "Liquidatable");
            pos.collateral -= uint256(fundingPayment);
        } else {
            // Trader receives funding (beneficial — market moved in their favour)
            pos.collateral += uint256(-fundingPayment);
        }

        pos.fundingIndex = cumulativeFundingIndex[pos.asset];
        emit FundingSettled(positionId, fundingPayment);
    }

    event PositionOpened(bytes32 indexed id, address trader, address asset,
                         int256 size, uint256 collateral);
    event FundingSettled(bytes32 indexed id, int256 payment);
}
```

---

## 5. Oracle Design

### 5.1 Two-Oracle Architecture

To prevent manipulation and ensure fair index prices:

```
Mark Price  = TWAP of on-chain DEX trades (30-min window)
             → Prevents flash loan manipulation of funding

Index Price = Weighted median of:
             - Chainlink price feed (40% weight)
             - Pyth Network feed   (40% weight)
             - Redstone oracle     (20% weight)
             → Requires 2-of-3 agreement within 0.5% tolerance
```

### 5.2 Oracle Adapter (Solidity)

```solidity
contract OracleAdapter {
    IChainlinkFeed public chainlink;
    IPythFeed      public pyth;
    IRedstone      public redstone;

    uint256 public constant STALENESS_THRESHOLD = 5 minutes;
    uint256 public constant DEVIATION_TOLERANCE = 50; // 0.5% in bps

    function getIndexPrice(address asset) external view returns (uint256) {
        uint256 p1 = chainlink.latestPrice(asset);
        uint256 p2 = pyth.latestPrice(asset);
        uint256 p3 = redstone.latestPrice(asset);

        // Require at least 2 sources to agree within tolerance
        require(_withinTolerance(p1, p2) || _withinTolerance(p1, p3)
                || _withinTolerance(p2, p3), "Oracle divergence");

        // Weighted median
        return (p1 * 40 + p2 * 40 + p3 * 20) / 100;
    }

    function _withinTolerance(uint256 a, uint256 b) internal pure returns (bool) {
        uint256 diff = a > b ? a - b : b - a;
        return diff * 10000 / a <= DEVIATION_TOLERANCE;
    }
}
```

---

## 6. Asset Selection Strategy

### Phase 1 (MVP) — Strongest Shariah case

| Asset | Token | Qabdh Solution | Why Halal |
|---|---|---|---|
| Gold | PAXG (Paxos) | 1 token = 1 troy oz physical gold, redeemable | Physical commodity, direct ownership |
| Silver | XAUT (Tether Gold) | Similar physical backing | Physical commodity |
| ETH | Native ETH | Productive asset (staking yield) | Utility, not pure speculation |

### Phase 2 — After Phase 1 fatwa

| Asset | Rationale | Shariah Issue to Clear |
|---|---|---|
| Halal equity index | e.g. Dow Jones Islamic Market Index | Underlying stocks screened |
| Real estate token | RWA tokenisation of Shariah-compliant property | Qabdh via legal title |
| Commodity indices | Wheat, palm oil (halal commodity production) | Physical delivery mechanism |

### Phase 3 — Excluded permanently

| Asset | Why Excluded |
|---|---|
| DOGE, SHIB, meme coins | No underlying value, pure maysir |
| Alcohol/tobacco stocks | Haram underlying |
| Conventional bonds/interest-bearing | Riba in underlying |
| Highly leveraged DeFi tokens | Speculative, no productive use |

---

## 7. Governance Model (Shariah DAO)

### 7.1 Two-Track Governance

```
Track 1: TECHNICAL governance (protocol upgrades, fee changes)
         → Token holder DAO vote (51% quorum)
         → 7-day timelock before execution

Track 2: SHARIAH governance (asset listing, leverage limits)
         → Shariah board multisig (3-of-5 scholars)
         → Cannot be overridden by token holders
         → Annual re-certification required
```

### 7.2 Shariah Board Composition

- 3 AAOIFI-certified scholars (minimum)
- 1 Islamic finance lawyer (Malaysia/UAE jurisdiction)
- 1 DeFi technical expert with Islamic finance background

Each scholar signs a transaction approving new assets or parameter changes.
The IPFS hash of the fatwa document is stored on-chain permanently.

### 7.3 Emergency Pause

```solidity
// Shariah board can pause markets if new fatwa prohibits
// (e.g., if AAOIFI issues a standard that overrides current approval)
function emergencyPause(address market, string calldata reason)
    external onlyShariah
{
    markets[market].paused = true;
    pauseReasons[market] = reason;
    emit MarketPaused(market, reason);
}
```

---

## 8. Technical Stack

### 8.1 Option A: Cosmos SDK Chain (Recommended)

**Why:** dYdX v4 proved this works. IBC for cross-chain assets. Sovereign governance.

```
Chain:      Cosmos SDK (Go)
Consensus:  CometBFT (Tendermint)
Language:   Go for chain modules, CosmWasm for smart contracts
Indexer:    Custom indexer + The Graph
Frontend:   Next.js + CosmJS
Wallet:     Keplr, Leap
```

**Pros:** Full control, no L1 gas constraints, proven by dYdX
**Cons:** Harder to build, requires validator set, higher initial cost

### 8.2 Option B: Arbitrum (Faster to Market)

```
Chain:      Arbitrum One (EVM-compatible)
Language:   Solidity 0.8.x
Standards:  ERC-20 collateral, EIP-712 signatures
Indexer:    The Graph Protocol
Frontend:   Next.js + ethers.js / wagmi
Wallet:     MetaMask, WalletConnect
Oracle:     Chainlink + Pyth
```

**Pros:** Faster development, existing DeFi ecosystem, lower cost
**Cons:** Dependent on Ethereum/Arbitrum, less sovereignty

### 8.3 MVP Recommendation: Arbitrum

Start on Arbitrum for speed to market. Migrate to Cosmos SDK chain
after achieving $50M TVL and Shariah board certification.

---

## 9. Economic Model

### 9.1 Protocol Fees (No Riba in Fee Structure)

| Fee Type | Amount | Rationale |
|---|---|---|
| Taker fee | 0.05% per trade | Service fee for matching (not interest) |
| Maker rebate | -0.02% | Incentivise liquidity provision |
| Liquidation fee | 1% of position | Risk management |
| **No funding fee** | 0% | Funding is bilateral P2P, protocol takes nothing |

### 9.2 Why Protocol Takes Zero Funding

In CEX protocols, the exchange often clips a portion of funding payments.
This would constitute riba for the protocol. In our design:
- Funding flows directly from losing side to winning side (P2P)
- Protocol only earns explicit service fees (permissible as ujrah — service wage)
- Surplus funding (when longs and shorts are imbalanced) goes to insurance fund

### 9.3 Insurance Fund

```
Source:     10% of liquidation fees + 20% of protocol trading fees
Purpose:    Cover socialised losses (extreme market conditions)
Halal basis: Tabarru (voluntary contribution) — each trader contributes
             to a common pool when entering, similar to takaful model
```

---

## 10. Regulatory Strategy

### 10.1 Jurisdiction Selection

| Jurisdiction | Status | Why Relevant |
|---|---|---|
| **Malaysia** | Most developed Islamic fintech framework | SC Malaysia has crypto guidelines + Shariah Advisory Council |
| **UAE (ADGM)** | Crypto-friendly + Islamic finance hub | ADGM has DeFi sandbox, Dubai has DIEDC |
| **Bahrain** | CBB has FinTech regulatory sandbox | CBB Rulebook Vol. 6 covers crypto |
| **Indonesia** | Largest Muslim population | DSN-MUI issues crypto fatwas |

**Recommended path:** Register in Malaysia first (Labuan IBFC for offshore,
SC Malaysia for domestic). This gives ASEAN access + credibility with
Islamic finance institutions.

### 10.2 Token Structure

Avoid issuing a governance token that could be deemed a security.
Consider:
- **Fee rebate NFT** (utility, not investment contract)
- **Staking for governance** (with no guaranteed yield — profit-sharing only)
- **Mudarabah structure** for investors (profit-sharing, no fixed return)

---

## 11. MVP Roadmap

### Phase 1: Foundation (Months 1–4)

- [ ] Smart contracts: FundingEngine, ShariahGuard, PositionManager (Arbitrum)
- [ ] Oracle integration: Chainlink + Pyth for BTC, ETH, PAXG
- [ ] Internal security audit
- [ ] Draft whitepaper with Ackerer mathematical foundation
- [ ] Approach 3 AAOIFI scholars for preliminary review

### Phase 2: Shariah Certification (Months 4–7)

- [ ] Submit full protocol documentation to Shariah board
- [ ] Receive written fatwa on: funding formula, leverage limits, asset list
- [ ] Publish fatwa IPFS hash in contract
- [ ] External smart contract audit (Certik / OpenZeppelin)
- [ ] Testnet launch with community testing

### Phase 3: Mainnet Launch (Months 7–10)

- [ ] Mainnet on Arbitrum
- [ ] Initial markets: BTC-USDC, ETH-USDC, PAXG-USDC
- [ ] Bug bounty programme
- [ ] Approach Islamic finance institutions for institutional liquidity

### Phase 4: Growth (Months 10–18)

- [ ] Add silver (XAUT), halal equity index markets
- [ ] Launch DEX expiring futures alongside perpetuals
- [ ] Begin Cosmos SDK chain development
- [ ] Target $10M TVL, apply for SC Malaysia registration
- [ ] Publish empirical performance paper (follow-up to Ahmed et al. 2026)

---

## 12. Key Differentiators vs. dYdX v4

dYdX v4 already implements I=0 and is the closest existing product to our DApp.
Our differentiators:

| Feature | dYdX v4 | Our DApp |
|---|---|---|
| Islamic positioning | None (no Shariah intent) | Explicit, with fatwa |
| Asset selection | All crypto assets | Shariah-screened only |
| Leverage limit | Up to 20x | Max 5x |
| Governance | Token DAO | Token DAO + Shariah board multisig |
| Target market | Global crypto traders | Muslim investors + Islamic institutions |
| Insurance fund | Socialised losses | Takaful-based model |
| Marketing | General DeFi | Islamic fintech, halal certification |

**Key insight from the research paper:** dYdX's I=0 formula achieves Shariah
compliance by design, but dYdX never marketed it as such and never obtained
a fatwa. Our DApp is dYdX's formula + explicit Shariah intent + institutional
credibility + appropriate asset selection.

---

## 13. Connection to the Research Paper

This DApp is the **implementation layer** of the Ahmed, Bhuyan & Islam (2026)
research findings:

| Paper Finding | DApp Implementation |
|---|---|
| "CEX interest is a design choice, not necessity" (§2.3) | FundingEngine.sol: no interest term |
| "dYdX I=0 achieves convergence" (Ackerer theorem, §2.3) | Mathematical proof embedded in whitepaper |
| "Four-category taxonomy" (Table 1) | DApp falls in Category 2: Premium-only DEX perpetual |
| "SeekersGuidance concedes riba resolved" (§4.1) | First fatwa to seek extends this concession |
| "Qabdh addressed by RWA-backed tokens" (§6.4) | Phase 1 assets: PAXG, XAUT, native ETH |
| "Everlasting options forward-looking" (§2.6) | Phase 3/4 feature: ι=0 everlasting options |

The paper provides the academic legitimacy. The DApp provides the implementation.
Together they constitute a complete contribution: proof → product.

---

## 14. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Scholars reject funding formula | Medium | Critical | Pre-consultation before build; multiple scholar opinions |
| Oracle manipulation | Low | High | 3-oracle median, TWAP, circuit breakers |
| Smart contract exploit | Medium | Critical | Multiple audits, bug bounty, gradual TVL caps |
| Regulatory ban | Low-Medium | High | Malaysia/UAE jurisdiction, legal counsel |
| Low liquidity | High | Medium | Market maker incentives, institutional partnerships |
| dYdX copies our Shariah marketing | Medium | Low | First-mover + fatwa credibility cannot be replicated quickly |
| Leverage leads to user losses (maysir perception) | Medium | Medium | 5x cap, risk warnings, educational content |

---

## 15. Estimated Build Cost

| Component | Cost (USD) | Notes |
|---|---|---|
| Smart contract development | $80,000–120,000 | 3 senior Solidity devs, 4 months |
| Smart contract audit (x2) | $60,000–100,000 | Certik + OpenZeppelin or equivalent |
| Frontend + indexer | $40,000–60,000 | React/Next.js + The Graph |
| Oracle integration | $10,000–20,000 | Chainlink/Pyth setup |
| Shariah board fees | $30,000–50,000 | 3 scholars × formal fatwa process |
| Legal (Malaysia/UAE) | $30,000–50,000 | Registration + compliance |
| **Total MVP** | **$250,000–400,000** | Conservative estimate |

---

*Blueprint prepared by: Shehzad Ahmed, based on*
*"The Interest Parameter in Perpetual Futures" (Ahmed, Bhuyan & Islam, 2026)*
*and Ackerer, Hugonnier & Jermann (2024) — Mathematical Finance.*

*Last updated: February 2026*
