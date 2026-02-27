'use client'

import Link from 'next/link'
import { useOraclePrices } from '@/hooks/useOraclePrices'
import { useFundingRate } from '@/hooks/useFundingRate'
import { useInsuranceFund } from '@/hooks/useInsuranceFund'

const MARKETS = [
  {
    id: 'BTC-PERP',
    name: 'Bitcoin',
    symbol: 'BTC',
    maxLeverage: 5,
    approved: true,
    live: true,
  },
  {
    id: 'ETH-PERP',
    name: 'Ethereum',
    symbol: 'ETH',
    maxLeverage: 5,
    approved: false,
    live: false,
    note: 'Pending Shariah approval',
  },
  {
    id: 'PAXG-PERP',
    name: 'PAX Gold',
    symbol: 'PAXG',
    maxLeverage: 3,
    approved: false,
    live: false,
    note: 'Coming — gold-backed',
  },
]

export default function MarketsClient() {
  const { markDisplay, mark, premium } = useOraclePrices()
  const { rateDisplay, isLong } = useFundingRate()
  const { display: insuranceDisplay } = useInsuranceFund()

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>
      {/* Insurance fund banner */}
      <div
        style={{
          background: 'var(--bg-panel)',
          border: '1px solid var(--border)',
          borderRadius: '10px',
          padding: '14px 20px',
          display: 'flex',
          gap: '32px',
          flexWrap: 'wrap',
        }}
      >
        <div>
          <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>INSURANCE FUND</div>
          <div style={{ fontFamily: 'var(--font-geist-mono)', fontSize: '1rem', fontWeight: 700, color: 'var(--gold)' }}>
            {insuranceDisplay}
          </div>
        </div>
        <div>
          <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>INTEREST PARAMETER (ι)</div>
          <div style={{ fontFamily: 'var(--font-geist-mono)', fontSize: '1rem', fontWeight: 700, color: 'var(--green-lite)' }}>
            0.0000 — No riba
          </div>
        </div>
        <div>
          <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>NETWORK</div>
          <div style={{ fontSize: '13px', color: 'var(--text-main)' }}>
            Arbitrum Sepolia (Testnet)
          </div>
        </div>
      </div>

      {/* Market table */}
      <div
        style={{
          background: 'var(--bg-panel)',
          border: '1px solid var(--border)',
          borderRadius: '12px',
          overflow: 'hidden',
        }}
      >
        {/* Header */}
        <div
          style={{
            display: 'grid',
            gridTemplateColumns: '2fr 1.5fr 1.2fr 1.2fr 1fr 1fr',
            padding: '10px 20px',
            borderBottom: '1px solid var(--border)',
            fontSize: '10px',
            color: 'var(--text-muted)',
            letterSpacing: '0.05em',
          }}
        >
          <span>MARKET</span>
          <span>MARK PRICE</span>
          <span>FUNDING / 1H</span>
          <span>PREMIUM</span>
          <span>MAX LEV.</span>
          <span>STATUS</span>
        </div>

        {/* Rows */}
        {MARKETS.map((m, i) => (
          <div
            key={m.id}
            style={{
              display: 'grid',
              gridTemplateColumns: '2fr 1.5fr 1.2fr 1.2fr 1fr 1fr',
              padding: '16px 20px',
              borderBottom: i < MARKETS.length - 1 ? '1px solid var(--border)' : 'none',
              alignItems: 'center',
              opacity: m.live ? 1 : 0.5,
            }}
          >
            {/* Market name */}
            <div>
              <div style={{ fontWeight: 700, fontSize: '14px', color: 'var(--text-main)' }}>
                {m.id}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)' }}>{m.name}</div>
            </div>

            {/* Mark price (live for BTC, placeholder for others) */}
            <div
              style={{
                fontFamily: 'var(--font-geist-mono)',
                fontWeight: 700,
                color: 'var(--text-main)',
              }}
            >
              {m.live ? markDisplay : '—'}
            </div>

            {/* Funding */}
            <div
              style={{
                fontFamily: 'var(--font-geist-mono)',
                color: m.live
                  ? isLong
                    ? 'var(--red-lite)'
                    : 'var(--green-lite)'
                  : 'var(--text-muted)',
              }}
            >
              {m.live ? rateDisplay : '—'}
            </div>

            {/* Premium */}
            <div
              style={{
                fontFamily: 'var(--font-geist-mono)',
                color: m.live
                  ? premium !== null && premium >= 0
                    ? 'var(--green-lite)'
                    : 'var(--red-lite)'
                  : 'var(--text-muted)',
              }}
            >
              {m.live && premium !== null
                ? `${premium >= 0 ? '+' : ''}${premium.toFixed(4)}%`
                : '—'}
            </div>

            {/* Max leverage */}
            <div style={{ color: 'var(--text-main)', fontFamily: 'var(--font-geist-mono)' }}>
              {m.maxLeverage}×
            </div>

            {/* Status */}
            <div>
              {m.live ? (
                <Link
                  href="/trade"
                  style={{
                    background: 'var(--green-deep)',
                    color: 'var(--green-lite)',
                    padding: '4px 12px',
                    borderRadius: '6px',
                    fontSize: '11px',
                    fontWeight: 700,
                    textDecoration: 'none',
                    border: '1px solid var(--green-mid)',
                    display: 'inline-block',
                  }}
                >
                  Trade ↗
                </Link>
              ) : (
                <span
                  style={{
                    fontSize: '11px',
                    color: 'var(--text-muted)',
                    background: 'var(--bg-card)',
                    padding: '4px 10px',
                    borderRadius: '6px',
                    border: '1px solid var(--border)',
                  }}
                >
                  {m.note ?? 'Soon'}
                </span>
              )}
            </div>
          </div>
        ))}
      </div>

      {/* Shariah board note */}
      <div
        style={{
          background: 'rgba(212,175,55,0.06)',
          border: '1px solid rgba(212,175,55,0.2)',
          borderRadius: '10px',
          padding: '14px 18px',
          fontSize: '12px',
          color: 'var(--text-muted)',
          lineHeight: 1.6,
        }}
      >
        <strong style={{ color: 'var(--gold)' }}>Shariah board approval:</strong> Each market asset requires a fatwa from the Baraka Shariah board
        stored on IPFS and enforced by ShariahGuard.sol. Currently only BTC-PERP is approved for testnet.
        ETH and gold markets pending board review.
      </div>
    </div>
  )
}
