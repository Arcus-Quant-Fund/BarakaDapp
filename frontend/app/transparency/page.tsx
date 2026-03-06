import TransparencyClient from './TransparencyClient'

export const metadata = {
  title: 'Shariah Transparency | Baraka Protocol',
  description: 'Live on-chain proof that Baraka funding rate satisfies ι=0 — no riba, no interest floor. Mathematical proof from Ackerer, Hugonnier & Jermann (2025, Mathematical Finance).',
}

export default function TransparencyPage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '24px 16px' }}>
      <div className="max-w-4xl mx-auto">
        <div style={{ marginBottom: '28px', textAlign: 'center' }}>
          <div
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: '8px',
              background: 'rgba(27,67,50,0.4)',
              border: '1px solid var(--green-deep)',
              borderRadius: '999px',
              padding: '4px 14px',
              marginBottom: '16px',
              fontSize: '12px',
              color: 'var(--green-lite)',
              fontFamily: 'var(--font-geist-mono)',
            }}
          >
            ι = 0 — Verified On-Chain
          </div>
          <h1 style={{ fontSize: '1.8rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '10px' }}>
            Shariah Compliance Proof
          </h1>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', maxWidth: '560px', margin: '0 auto', lineHeight: 1.6 }}>
            Every value on this page is read live from our verified smart contracts on Arbitrum Sepolia.
            No trust required — verify it yourself on Arbiscan.
          </p>
        </div>

        <TransparencyClient />
      </div>
    </main>
  )
}
