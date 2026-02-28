import type { Metadata } from 'next'
import CreditClient from './CreditClient'

export const metadata: Metadata = {
  title: 'Credit | Baraka Protocol',
  description: 'Layer 4 — Islamic Credit Default Swaps. Put-priced dynamic premiums at ι=0. No riba.',
}

export default function CreditPage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '24px 16px' }}>
      <div className="max-w-5xl mx-auto">
        <div style={{ marginBottom: '28px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '8px' }}>
            <span style={{
              background: '#e76f5122',
              color: '#e76f51',
              fontSize: '11px',
              fontWeight: 600,
              padding: '2px 8px',
              borderRadius: '4px',
              letterSpacing: '0.05em',
            }}>
              LAYER 4
            </span>
            <h1 style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', margin: 0 }}>
              iCDS — Islamic Credit Default Swaps
            </h1>
          </div>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', margin: 0 }}>
            Riba-free credit protection — quarterly premium = Π_put(spot, recoveryFloor) × notional / WAD at ι=0 (Paper 2)
          </p>
        </div>
        <CreditClient />
      </div>
    </main>
  )
}
