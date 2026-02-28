import type { Metadata } from 'next'
import SukukClient from './SukukClient'

export const metadata: Metadata = {
  title: 'Sukuk | Baraka Protocol',
  description: 'Layer 2 — Perpetual Sukuk with embedded everlasting call option. Ijarah-style profit distribution at ι=0.',
}

export default function SukukPage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '24px 16px' }}>
      <div className="max-w-5xl mx-auto">
        <div style={{ marginBottom: '28px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '8px' }}>
            <span style={{
              background: '#e9c46a22',
              color: '#e9c46a',
              fontSize: '11px',
              fontWeight: 600,
              padding: '2px 8px',
              borderRadius: '4px',
              letterSpacing: '0.05em',
            }}>
              LAYER 2
            </span>
            <h1 style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', margin: 0 }}>
              Perpetual Sukuk
            </h1>
          </div>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', margin: 0 }}>
            Islamic capital market instrument — ijarah-style profit distribution + embedded everlasting call option at ι=0 (AAOIFI SS-17)
          </p>
        </div>
        <SukukClient />
      </div>
    </main>
  )
}
