'use client'

import { useFundingRate } from '@/hooks/useFundingRate'
import { useOraclePrices } from '@/hooks/useOraclePrices'
import { useInsuranceFund } from '@/hooks/useInsuranceFund'
import { CONTRACTS, PRODUCT_CONTRACTS, ARBISCAN_BASE } from '@/lib/contracts'

const CONTRACT_LIST = [
  { name: 'FundingEngine',     addr: CONTRACTS.FundingEngine,     desc: '[L1] F = (Mark − Index) / Index, ι hardcoded to 0' },
  { name: 'ShariahGuard',      addr: CONTRACTS.ShariahGuard,      desc: '[L1] Validates leverage ≤ 5×, asset approval, fatwa IPFS registry' },
  { name: 'OracleAdapter',     addr: CONTRACTS.OracleAdapter,     desc: '[L1] Dual Chainlink feeds (60/40), κ-signal, staleness + circuit breaker' },
  { name: 'CollateralVault',   addr: CONTRACTS.CollateralVault,   desc: '[L1] USDC/PAXG/XAUT custody, no rehypothecation, 24h cooldown' },
  { name: 'PositionManager',   addr: CONTRACTS.PositionManager,   desc: '[L1] Open/close positions, BRKX fee tiers, ShariahGuard on every open' },
  { name: 'LiquidationEngine', addr: CONTRACTS.LiquidationEngine, desc: '[L1] 2% maintenance margin, 1% penalty (50/50 fund/liquidator)' },
  { name: 'InsuranceFund',     addr: CONTRACTS.InsuranceFund,     desc: '[L1] No yield on idle capital — seed for Takaful layer' },
  { name: 'GovernanceModule',  addr: CONTRACTS.GovernanceModule,  desc: '[L1] 48h timelock, Shariah board veto, dual-track governance' },
  { name: 'BRKXToken',         addr: CONTRACTS.BRKXToken,         desc: '[L1] 100 M fixed supply, hold-based fee tiers (5.0 → 2.5 bps)' },
  { name: 'EverlastingOption', addr: PRODUCT_CONTRACTS.EverlastingOption, desc: '[L2] κ-rate pricing engine — everlasting put/call at ι=0 (Ackerer 2024 Prop. 6)' },
  { name: 'TakafulPool',       addr: PRODUCT_CONTRACTS.TakafulPool,       desc: '[L3] Tabarru mutual insurance — BTC/USDC pool, wakala 10% operator fee' },
  { name: 'PerpetualSukuk',    addr: PRODUCT_CONTRACTS.PerpetualSukuk,    desc: '[L3] Ijarah + embedded mudarabah call — fixed profit + upside sharing' },
  { name: 'iCDS',              addr: PRODUCT_CONTRACTS.iCDS,              desc: '[L4] Islamic Credit Default Swap — ta\'awun protection, no speculation' },
] as const

const PRINCIPLES = [
  {
    id: '01',
    title: 'No Riba (ι = 0)',
    status: 'ENFORCED',
    color: 'var(--green-lite)',
    body: 'The funding rate formula F = (Mark − Index) / Index contains no interest floor or riba component. The parameter ι is hardcoded to zero in FundingEngine.sol and cannot be changed — it is a constant, not a variable. This is proven by Ackerer, Hugonnier & Jermann (2024), Theorem 3 / Proposition 3: when r_a ≈ r_b (both parties use the same stablecoin), the no-arbitrage condition uniquely determines ι = 0.',
  },
  {
    id: '02',
    title: 'No Maysir (Excessive Speculation)',
    status: 'ENFORCED',
    color: 'var(--green-lite)',
    body: 'Maximum leverage is hardcoded as MAX_LEVERAGE = 5 in ShariahGuard.sol (a constant, not a settable parameter). Every position open call passes through validatePosition() which reverts if leverage > 5. Utility-focused framing: the protocol is designed for hedging, not pure speculation.',
  },
  {
    id: '03',
    title: 'No Gharar (Uncertainty / Hidden Risk)',
    status: 'ENFORCED',
    color: 'var(--green-lite)',
    body: 'All 9 contracts are verified on Arbiscan — source code is public. No proxy contracts, no upgradeable contracts (OZ upgradeable deliberately NOT installed). No admin backdoors. The only governance is a 48-hour timelock with Shariah board veto. All fees, liquidation parameters, and funding mechanics are visible on-chain.',
  },
  {
    id: '04',
    title: 'Takaful Insurance Fund',
    status: 'PARTIAL',
    color: 'var(--gold)',
    body: 'An on-chain insurance fund holds collateral to cover bad debt from insolvent positions. 50% of all liquidation penalties flow to this fund. No yield is generated on idle capital (no staking or lending of insurance funds). This is the seed of a full Takaful structure planned for Layer 3.',
  },
  {
    id: '05',
    title: 'Halal Asset Approval',
    status: 'ENFORCED',
    color: 'var(--green-lite)',
    body: 'ShariahGuard.sol requires each collateral asset to be approved by the Shariah board multisig. The approval stores an IPFS hash pointing to the fatwa document on Pinata. Testnet USDC is approved — fatwa CID QmVztQvWd5QkD5euhiUb2ycwr2SHL928Y2AC9rnWCMn7c2 is recorded in ShariahGuard.fatwaIPFS[USDC]. PAXG and XAUT pending formal board review for mainnet.',
  },
  {
    id: '06',
    title: 'Everlasting Options — κ-Rate Pricing (Layer 2)',
    status: 'DEPLOYED',
    color: 'var(--green-lite)',
    body: 'EverlastingOption.sol implements the actuarially fair takaful pricing formula from Ackerer, Hugonnier & Jermann (2024) Proposition 6 at ι = 0: Π(x, K) = [K^{1−β} / (β₊ − β₋)] · x^β, where β = ½ ± √(¼ + 2κ/σ²). The κ-rate (convergence intensity) replaces the interest rate r entirely — no riba in the formula. 177/177 tests pass including fuzz (1 000 runs). Deployed to Arbitrum Sepolia (2026-02-28). This is the pricing engine for Layer 2 Perpetual Sukuk and Layer 3 Takaful.',
  },
]

export default function TransparencyClient() {
  const { ratePercent, rateDisplay, isLoading: rateLoading } = useFundingRate()
  const { mark, index, markDisplay, indexDisplay } = useOraclePrices()
  const { display: insuranceDisplay } = useInsuranceFund()

  const computed =
    mark !== null && index !== null && index > 0
      ? (mark - index) / index
      : null

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>

      {/* Live proof card */}
      <div
        style={{
          background: 'var(--bg-panel)',
          border: '1px solid var(--green-deep)',
          borderRadius: '12px',
          padding: '24px',
        }}
      >
        <h2 style={{ fontSize: '14px', fontWeight: 700, color: 'var(--text-main)', marginBottom: '18px' }}>
          Live On-Chain Verification
        </h2>

        <div
          style={{
            fontFamily: 'var(--font-geist-mono)',
            background: 'var(--bg-card)',
            border: '1px solid var(--border)',
            borderRadius: '8px',
            padding: '18px',
            fontSize: '13px',
            lineHeight: 2.2,
          }}
        >
          {[
            ['Mark Price (OracleAdapter)', markDisplay, 'var(--text-main)'],
            ['Index Price (OracleAdapter)', indexDisplay, 'var(--text-main)'],
            ['F computed = (Mark−Index)/Index', computed !== null ? `${(computed * 100).toFixed(6)}%` : '—', 'var(--green-lite)'],
            ['F on-chain (FundingEngine.getFundingRate)', rateLoading ? 'loading...' : rateDisplay, 'var(--green-lite)'],
            ['ι (interest parameter)', '0  ← hardcoded constant', 'var(--green-lite)'],
            ['Insurance Fund', insuranceDisplay, 'var(--gold)'],
          ].map(([label, value, color]) => (
            <div
              key={label as string}
              style={{ display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: '8px', borderBottom: '1px solid rgba(30,51,39,0.5)', paddingBottom: '4px' }}
            >
              <span style={{ color: 'var(--text-muted)', fontSize: '12px' }}>{label as string}</span>
              <span style={{ color: color as string, fontWeight: 600 }}>{value as string}</span>
            </div>
          ))}
        </div>

        <p style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '12px' }}>
          Values refresh every 10–15 seconds from Arbitrum Sepolia (chainId 421614).
        </p>
      </div>

      {/* Principles */}
      <div>
        <h2 style={{ fontSize: '14px', fontWeight: 700, color: 'var(--text-main)', marginBottom: '14px' }}>
          Islamic Finance Principles
        </h2>
        <div style={{ display: 'flex', flexDirection: 'column', gap: '10px' }}>
          {PRINCIPLES.map(({ id, title, status, color, body }) => (
            <details
              key={id}
              style={{
                background: 'var(--bg-panel)',
                border: '1px solid var(--border)',
                borderRadius: '10px',
                overflow: 'hidden',
              }}
            >
              <summary
                style={{
                  padding: '14px 18px',
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '12px',
                  listStyle: 'none',
                  userSelect: 'none',
                }}
              >
                <span style={{ fontSize: '11px', fontFamily: 'var(--font-geist-mono)', color: 'var(--text-muted)' }}>
                  {id}
                </span>
                <span style={{ fontWeight: 700, color: 'var(--text-main)', flex: 1 }}>
                  {title}
                </span>
                <span
                  style={{
                    fontSize: '10px',
                    padding: '2px 8px',
                    borderRadius: '4px',
                    background: `${color}20`,
                    color,
                    fontWeight: 700,
                    letterSpacing: '0.05em',
                  }}
                >
                  {status}
                </span>
              </summary>
              <div
                style={{
                  padding: '0 18px 18px',
                  fontSize: '13px',
                  color: 'var(--text-muted)',
                  lineHeight: 1.7,
                  borderTop: '1px solid var(--border)',
                  paddingTop: '14px',
                }}
              >
                {body}
              </div>
            </details>
          ))}
        </div>
      </div>

      {/* Mathematical proof */}
      <div
        style={{
          background: 'var(--bg-panel)',
          border: '1px solid var(--border)',
          borderRadius: '12px',
          padding: '24px',
        }}
      >
        <h2 style={{ fontSize: '14px', fontWeight: 700, color: 'var(--text-main)', marginBottom: '16px' }}>
          Mathematical Proof (Ackerer et al. 2024)
        </h2>

        <div
          style={{
            fontFamily: 'var(--font-geist-mono)',
            fontSize: '12px',
            lineHeight: 1.8,
            color: 'var(--text-muted)',
            background: 'var(--bg-card)',
            border: '1px solid var(--border)',
            borderRadius: '8px',
            padding: '16px',
            marginBottom: '14px',
          }}
        >
          <div style={{ color: 'var(--text-main)', marginBottom: '8px' }}>Grand Valuation Equation (Ackerer Theorem 3):</div>
          <div style={{ color: 'var(--green-lite)' }}>
            F = (r_a − r_b − ι) × x + (Mark − Index) / Index
          </div>
          <div style={{ marginTop: '12px' }}>
            <span style={{ color: 'var(--text-main)' }}>For stablecoin-margined perps (USDC):</span><br />
            <span style={{ color: 'var(--gold)' }}>r_a ≈ r_b</span>{' '}
            <span style={{ color: 'var(--text-muted)' }}>(both legs use USDC, same borrowing cost)</span><br />
            <span style={{ color: 'var(--gold)' }}>∴ r_a − r_b = 0</span><br />
            <span style={{ color: 'var(--gold)' }}>∴ F = −ι × x + (Mark − Index) / Index</span><br />
            <span style={{ color: 'var(--text-muted)' }}>No-arbitrage + Proposition 3 uniquely determines </span>
            <span style={{ color: 'var(--green-lite)' }}>ι = 0</span>
          </div>
          <div style={{ marginTop: '12px', color: 'var(--green-lite)', fontWeight: 700 }}>
            ∴ F = (Mark − Index) / Index  [no riba term]
          </div>
        </div>

        <p style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.6 }}>
          Reference: Ackerer, D., Hugonnier, J., & Jermann, U. (2024).{' '}
          <em>Perpetual Futures Pricing</em>. Mathematical Finance 34(4), 1277–1308.
          The BarakaDapp implementation follows Theorem 3 / Proposition 3 precisely — see
          NatSpec comments in FundingEngine.sol. The κ-rate monetary framework and
          everlasting option pricing (Proposition 6) are developed in Ahmed, Bhuyan &amp; Islam
          (2026), Papers 2 &amp; 3 — available at{' '}
          <a href="https://github.com/Arcus-Quant-Fund/BarakaDapp" style={{ color: 'var(--green-lite)', textDecoration: 'none' }}>
            github.com/Arcus-Quant-Fund/BarakaDapp
          </a>.
        </p>
      </div>

      {/* All contracts */}
      <div
        style={{
          background: 'var(--bg-panel)',
          border: '1px solid var(--border)',
          borderRadius: '12px',
          overflow: 'hidden',
        }}
      >
        <div style={{ padding: '16px 20px', borderBottom: '1px solid var(--border)' }}>
          <h2 style={{ fontSize: '14px', fontWeight: 700, color: 'var(--text-main)', margin: 0 }}>
            Verified Contracts — Arbitrum Sepolia (13 deployed)
          </h2>
        </div>
        {CONTRACT_LIST.map(({ name, addr, desc }, i) => (
          <div
            key={name}
            style={{
              padding: '14px 20px',
              borderBottom: i < CONTRACT_LIST.length - 1 ? '1px solid var(--border)' : 'none',
              display: 'flex',
              gap: '16px',
              alignItems: 'flex-start',
              flexWrap: 'wrap',
            }}
          >
            <div style={{ flex: 1, minWidth: '200px' }}>
              <div style={{ fontWeight: 700, fontSize: '13px', color: 'var(--text-main)', marginBottom: '3px' }}>
                {name}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>{desc}</div>
            </div>
            <a
              href={`${ARBISCAN_BASE}/address/${addr}`}
              target="_blank"
              rel="noopener noreferrer"
              style={{
                fontFamily: 'var(--font-geist-mono)',
                fontSize: '11px',
                color: 'var(--green-lite)',
                textDecoration: 'none',
                whiteSpace: 'nowrap',
              }}
            >
              {addr.slice(0, 6)}…{addr.slice(-4)} ↗
            </a>
          </div>
        ))}
      </div>
    </div>
  )
}
