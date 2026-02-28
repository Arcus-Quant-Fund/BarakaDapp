import type { Metadata } from 'next'
import DashboardClient from './DashboardClient'

export const metadata: Metadata = {
  title: 'Dashboard | Baraka Protocol',
  description: 'Portfolio overview — perpetual positions, BRKX fee tier, sukuk exposure, takaful coverage, credit protections.',
}

export default function DashboardPage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '24px 16px' }}>
      <div className="max-w-5xl mx-auto">
        <div style={{ marginBottom: '28px' }}>
          <h1 style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px' }}>
            Portfolio Dashboard
          </h1>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', margin: 0 }}>
            Unified view across all Baraka Protocol layers — perpetuals, sukuk, takaful, and credit default swaps.
          </p>
        </div>
        <DashboardClient />
      </div>
    </main>
  )
}
