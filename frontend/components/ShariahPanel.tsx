'use client'

import { useFundingRate } from '@/hooks/useFundingRate'
import { useOraclePrices } from '@/hooks/useOraclePrices'
import { CONTRACTS, ARBISCAN_BASE } from '@/lib/contracts'

export default function ShariahPanel() {
  const { ratePercent, rateDisplay, isLoading } = useFundingRate()
  const { mark, index, premium } = useOraclePrices()

  const computed =
    mark !== null && index !== null && index > 0
      ? (mark - index) / index
      : null

  const matches =
    computed !== null && ratePercent !== null
      ? Math.abs(computed - ratePercent) < 0.0001
      : null

  return (
    <div
      style={{
        background: 'var(--bg-panel)',
        border: '1px solid var(--border)',
        borderRadius: '12px',
        padding: '20px',
      }}
    >
      <div
        style={{
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          marginBottom: '16px',
        }}
      >
        <h3 style={{ margin: 0, fontSize: '13px', fontWeight: 700, color: 'var(--text-main)' }}>
          Shariah Compliance — Live Proof
        </h3>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
            background: 'rgba(27,67,50,0.4)',
            border: '1px solid var(--green-deep)',
            borderRadius: '6px',
            padding: '3px 10px',
            fontSize: '11px',
            color: 'var(--green-lite)',
            fontFamily: 'var(--font-geist-mono)',
          }}
        >
          ι = 0 &nbsp;✓
        </div>
      </div>

      {/* Formula row */}
      <div
        style={{
          background: 'var(--bg-card)',
          border: '1px solid var(--border)',
          borderRadius: '8px',
          padding: '16px',
          fontFamily: 'var(--font-geist-mono)',
          fontSize: '13px',
          marginBottom: '16px',
          lineHeight: 2,
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', flexWrap: 'wrap', gap: '8px' }}>
          <div>
            <span style={{ color: 'var(--text-muted)' }}>F = </span>
            <span style={{ color: 'var(--text-main)' }}>(Mark − Index) / Index</span>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)' }}>ι = </span>
            <span style={{ color: 'var(--green-lite)', fontWeight: 700 }}>0</span>
            <span style={{ color: 'var(--text-muted)', fontSize: '11px', marginLeft: '6px' }}>
              (hardcoded, not a variable)
            </span>
          </div>
        </div>

        <div
          style={{
            borderTop: '1px solid var(--border)',
            marginTop: '10px',
            paddingTop: '10px',
            display: 'flex',
            gap: '24px',
            flexWrap: 'wrap',
          }}
        >
          <div>
            <span style={{ color: 'var(--text-muted)', fontSize: '11px' }}>Mark: </span>
            <span style={{ color: 'var(--text-main)' }}>
              {mark !== null ? `$${mark.toFixed(2)}` : '—'}
            </span>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)', fontSize: '11px' }}>Index: </span>
            <span style={{ color: 'var(--text-main)' }}>
              {index !== null ? `$${index.toFixed(2)}` : '—'}
            </span>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)', fontSize: '11px' }}>Computed F: </span>
            <span style={{ color: 'var(--green-lite)' }}>
              {computed !== null ? `${(computed * 100).toFixed(4)}%` : '—'}
            </span>
          </div>
          <div>
            <span style={{ color: 'var(--text-muted)', fontSize: '11px' }}>On-chain F: </span>
            <span style={{ color: 'var(--green-lite)' }}>
              {isLoading ? '...' : rateDisplay}
            </span>
          </div>
          {matches !== null && (
            <div>
              <span
                style={{
                  padding: '1px 8px',
                  borderRadius: '4px',
                  fontSize: '11px',
                  background: matches ? 'rgba(82,183,136,0.15)' : 'rgba(229,83,83,0.15)',
                  color: matches ? 'var(--green-lite)' : 'var(--red-lite)',
                }}
              >
                {matches ? '✓ Matches' : '⚠ Mismatch'}
              </span>
            </div>
          )}
        </div>
      </div>

      {/* CEX comparison */}
      <div style={{ marginBottom: '16px' }}>
        <p style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '8px' }}>
          vs. Centralised Exchanges (typical):
        </p>
        <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
          {[
            { name: 'Binance', rate: '0.0100%', note: 'has ι > 0 floor' },
            { name: 'Bybit',   rate: '0.0100%', note: 'has ι > 0 floor' },
            { name: 'OKX',     rate: '0.0300%', note: 'has ι > 0 floor' },
            { name: 'Baraka',  rate: rateDisplay, note: 'ι = 0 on-chain', isUs: true },
          ].map(({ name, rate, note, isUs }) => (
            <div
              key={name}
              style={{
                flex: '1',
                minWidth: '120px',
                background: isUs ? 'rgba(27,67,50,0.3)' : 'var(--bg-card)',
                border: `1px solid ${isUs ? 'var(--green-deep)' : 'var(--border)'}`,
                borderRadius: '8px',
                padding: '10px',
                textAlign: 'center',
              }}
            >
              <div style={{ fontSize: '11px', fontWeight: 700, color: isUs ? 'var(--green-lite)' : 'var(--text-main)', marginBottom: '4px' }}>
                {name}
              </div>
              <div style={{ fontFamily: 'var(--font-geist-mono)', fontSize: '12px', color: isUs ? 'var(--green-lite)' : 'var(--red-lite)' }}>
                {rate}
              </div>
              <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginTop: '3px' }}>
                {note}
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Contract links */}
      <div>
        <p style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '8px' }}>
          Verified contracts:
        </p>
        <div style={{ display: 'flex', gap: '6px', flexWrap: 'wrap' }}>
          {(
            [
              ['FundingEngine', CONTRACTS.FundingEngine],
              ['ShariahGuard', CONTRACTS.ShariahGuard],
              ['OracleAdapter', CONTRACTS.OracleAdapter],
            ] as [string, string][]
          ).map(([name, addr]) => (
            <a
              key={name}
              href={`${ARBISCAN_BASE}/address/${addr}`}
              target="_blank"
              rel="noopener noreferrer"
              style={{
                fontSize: '11px',
                color: 'var(--green-lite)',
                background: 'var(--bg-card)',
                border: '1px solid var(--border)',
                borderRadius: '4px',
                padding: '2px 8px',
                textDecoration: 'none',
                fontFamily: 'var(--font-geist-mono)',
              }}
            >
              {name} ↗
            </a>
          ))}
        </div>
      </div>
    </div>
  )
}
