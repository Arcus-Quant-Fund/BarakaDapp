import Link from 'next/link'
import MarketsClient from './MarketsClient'

export const metadata = {
  title: 'Markets | Baraka Protocol',
}

export default function MarketsPage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '24px 16px' }}>
      <div className="max-w-5xl mx-auto">
        <div style={{ marginBottom: '24px' }}>
          <h1 style={{ fontSize: '1.4rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '6px' }}>
            Markets
          </h1>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)' }}>
            All markets are Shariah-compliant. Assets require board approval. ι = 0 on all pairs.
          </p>
        </div>
        <MarketsClient />
      </div>
    </main>
  )
}
