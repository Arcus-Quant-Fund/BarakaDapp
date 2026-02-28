import type { Metadata } from 'next'
import TakafulClient from './TakafulClient'

export const metadata: Metadata = {
  title: 'Takaful | Baraka Protocol',
  description: 'Layer 3 — Mutual Islamic Insurance. Tabarru-based contributions priced via everlasting put at ι=0.',
}

export default function TakafulPage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '24px 16px' }}>
      <div className="max-w-5xl mx-auto">
        <div style={{ marginBottom: '28px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '8px' }}>
            <span style={{
              background: '#2a9d8f22',
              color: '#2a9d8f',
              fontSize: '11px',
              fontWeight: 600,
              padding: '2px 8px',
              borderRadius: '4px',
              letterSpacing: '0.05em',
            }}>
              LAYER 3
            </span>
            <h1 style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', margin: 0 }}>
              Takaful Pool
            </h1>
          </div>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', margin: 0 }}>
            Mutual Islamic insurance — tabarru contributions computed from everlasting put Π_put(spot, floor) at ι=0 (AAOIFI SS-26)
          </p>
        </div>
        <TakafulClient />
      </div>
    </main>
  )
}
