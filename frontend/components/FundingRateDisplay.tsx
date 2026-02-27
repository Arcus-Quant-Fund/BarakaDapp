'use client'

import { useFundingRate } from '@/hooks/useFundingRate'
import { useOraclePrices } from '@/hooks/useOraclePrices'

function msToHMS(ms: number) {
  const s = Math.floor(ms / 1000)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  return `${h}h ${m.toString().padStart(2, '0')}m ${sec.toString().padStart(2, '0')}s`
}

export default function FundingRateDisplay() {
  const { rateDisplay, nextFundingIn, isLong, isLoading } = useFundingRate()
  const { markDisplay, indexDisplay, premium } = useOraclePrices()

  return (
    <div
      style={{
        background: 'var(--bg-panel)',
        border: '1px solid var(--border)',
        borderRadius: '10px',
        padding: '14px 18px',
        display: 'flex',
        gap: '28px',
        flexWrap: 'wrap',
        alignItems: 'center',
      }}
    >
      {/* Mark price */}
      <div>
        <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>
          MARK PRICE
        </div>
        <div style={{ fontSize: '1.1rem', fontWeight: 700, color: 'var(--text-main)', fontFamily: 'var(--font-geist-mono)' }}>
          {markDisplay}
        </div>
      </div>

      <div style={{ width: '1px', height: '30px', background: 'var(--border)' }} />

      {/* Index price */}
      <div>
        <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>
          INDEX PRICE
        </div>
        <div style={{ fontSize: '1rem', fontWeight: 600, color: 'var(--text-muted)', fontFamily: 'var(--font-geist-mono)' }}>
          {indexDisplay}
        </div>
      </div>

      <div style={{ width: '1px', height: '30px', background: 'var(--border)' }} />

      {/* Premium */}
      <div>
        <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>
          PREMIUM
        </div>
        <div
          style={{
            fontSize: '1rem',
            fontWeight: 600,
            fontFamily: 'var(--font-geist-mono)',
            color: premium === null ? 'var(--text-muted)' : premium >= 0 ? 'var(--green-lite)' : 'var(--red-lite)',
          }}
        >
          {premium === null ? '—' : `${premium >= 0 ? '+' : ''}${premium.toFixed(4)}%`}
        </div>
      </div>

      <div style={{ width: '1px', height: '30px', background: 'var(--border)' }} />

      {/* Funding rate */}
      <div>
        <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>
          FUNDING / 1H
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
          <div
            style={{
              fontSize: '1rem',
              fontWeight: 700,
              fontFamily: 'var(--font-geist-mono)',
              color: isLoading ? 'var(--text-muted)' : isLong ? 'var(--red-lite)' : 'var(--green-lite)',
            }}
          >
            {isLoading ? '...' : rateDisplay}
          </div>
          {!isLoading && (
            <span
              style={{
                fontSize: '10px',
                padding: '1px 6px',
                borderRadius: '4px',
                background: isLong ? 'rgba(229,83,83,0.15)' : 'rgba(82,183,136,0.15)',
                color: isLong ? 'var(--red-lite)' : 'var(--green-lite)',
              }}
            >
              {isLong ? 'Longs pay' : 'Shorts pay'}
            </span>
          )}
        </div>
      </div>

      <div style={{ width: '1px', height: '30px', background: 'var(--border)' }} />

      {/* Next funding */}
      <div>
        <div style={{ fontSize: '10px', color: 'var(--text-muted)', marginBottom: '3px' }}>
          NEXT FUNDING
        </div>
        <div style={{ fontSize: '0.9rem', fontFamily: 'var(--font-geist-mono)', color: 'var(--text-muted)' }}>
          {nextFundingIn === null ? '—' : msToHMS(nextFundingIn)}
        </div>
      </div>

      {/* ι=0 badge */}
      <div style={{ marginLeft: 'auto' }}>
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '6px',
            background: 'rgba(27,67,50,0.3)',
            border: '1px solid var(--green-deep)',
            borderRadius: '6px',
            padding: '4px 10px',
            fontSize: '12px',
            color: 'var(--green-lite)',
            fontFamily: 'var(--font-geist-mono)',
          }}
        >
          <span style={{ color: 'var(--green-lite)' }}>ι = 0</span>
          <span style={{ color: 'var(--text-muted)', fontSize: '10px' }}>No riba</span>
        </div>
      </div>
    </div>
  )
}
