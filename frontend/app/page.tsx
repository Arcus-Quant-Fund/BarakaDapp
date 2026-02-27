import Link from 'next/link'

const STATS = [
  { label: 'Interest Parameter (ι)', value: '0', sub: 'Proven from Ackerer et al. (2024)' },
  { label: 'Max Leverage', value: '5×', sub: 'Hard-coded in ShariahGuard.sol' },
  { label: 'Contracts on Arbiscan', value: '8', sub: 'All verified ✓' },
  { label: 'Simulation Checks', value: '22/22', sub: 'cadCAD + stress tests passed' },
]

const FEATURES = [
  {
    icon: '∅',
    title: 'Zero Interest (ι = 0)',
    body: 'The Baraka funding rate is F = (Mark − Index) / Index with no interest floor or riba component — proven from Ackerer, Hugonnier & Jermann (2024).',
  },
  {
    icon: '⚖',
    title: 'Shariah Guard',
    body: 'Every position is validated on-chain before execution. Max 5× leverage. Assets require Shariah board approval stored on IPFS.',
  },
  {
    icon: '🔍',
    title: 'Full Transparency',
    body: 'All 8 contracts are verified on Arbiscan. No proxies, no admin backdoors, no upgradeable contracts — Shariah principle of no hidden changes.',
  },
  {
    icon: '🛡',
    title: 'Insurance Fund (Takaful seed)',
    body: 'A dedicated on-chain insurance fund absorbs bad debt. 50% of liquidation penalties go to the fund — no yield generated on idle capital.',
  },
]

export default function HomePage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)' }}>
      {/* Hero */}
      <section
        style={{
          background: 'linear-gradient(135deg, var(--bg-deep) 0%, var(--bg-panel) 100%)',
          borderBottom: '1px solid var(--border)',
        }}
        className="px-4 py-20 text-center"
      >
        <div className="max-w-3xl mx-auto">
          <div
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: '8px',
              background: 'rgba(27,67,50,0.4)',
              border: '1px solid var(--green-deep)',
              borderRadius: '999px',
              padding: '4px 14px',
              marginBottom: '24px',
              fontSize: '12px',
              color: 'var(--green-lite)',
            }}
          >
            <span
              style={{
                width: '6px',
                height: '6px',
                borderRadius: '50%',
                background: 'var(--green-lite)',
                display: 'inline-block',
              }}
              className="animate-pulse"
            />
            Testnet Live — Arbitrum Sepolia
          </div>

          <h1
            style={{
              fontSize: 'clamp(2rem, 5vw, 3.5rem)',
              fontWeight: 700,
              lineHeight: 1.1,
              color: 'var(--text-main)',
              marginBottom: '20px',
            }}
          >
            Shariah-Compliant<br />
            <span style={{ color: 'var(--gold)' }}>Perpetual Futures</span>
          </h1>

          <p
            style={{
              fontSize: '1.05rem',
              color: 'var(--text-muted)',
              maxWidth: '580px',
              margin: '0 auto 36px',
              lineHeight: 1.6,
            }}
          >
            Trade Bitcoin perpetuals with zero interest parameter (ι = 0),
            mathematically proven on-chain. No riba. No hidden fees.
            Full Islamic finance compliance.
          </p>

          <div className="flex gap-4 justify-center flex-wrap">
            <Link
              href="/trade"
              style={{
                background: 'var(--green-deep)',
                color: 'var(--text-main)',
                padding: '12px 28px',
                borderRadius: '8px',
                fontWeight: 600,
                fontSize: '14px',
                textDecoration: 'none',
                border: '1px solid var(--green-mid)',
              }}
            >
              Open Trade
            </Link>
            <Link
              href="/transparency"
              style={{
                background: 'transparent',
                color: 'var(--gold)',
                padding: '12px 28px',
                borderRadius: '8px',
                fontWeight: 600,
                fontSize: '14px',
                textDecoration: 'none',
                border: '1px solid rgba(212,175,55,0.3)',
              }}
            >
              View Shariah Proof
            </Link>
          </div>
        </div>
      </section>

      {/* Stats */}
      <section
        style={{ borderBottom: '1px solid var(--border)' }}
        className="px-4 py-10"
      >
        <div className="max-w-5xl mx-auto grid grid-cols-2 md:grid-cols-4 gap-6">
          {STATS.map(({ label, value, sub }) => (
            <div key={label} className="text-center">
              <div
                style={{ fontSize: 'clamp(1.8rem, 4vw, 2.5rem)', fontWeight: 700, color: 'var(--gold)' }}
              >
                {value}
              </div>
              <div style={{ fontSize: '13px', fontWeight: 600, color: 'var(--text-main)', marginTop: '4px' }}>
                {label}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '2px' }}>
                {sub}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Features */}
      <section className="px-4 py-16">
        <div className="max-w-5xl mx-auto">
          <h2
            style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', textAlign: 'center', marginBottom: '40px' }}
          >
            Why Baraka?
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {FEATURES.map(({ icon, title, body }) => (
              <div
                key={title}
                style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '12px',
                  padding: '24px',
                }}
              >
                <div style={{ fontSize: '1.5rem', marginBottom: '12px' }}>{icon}</div>
                <h3 style={{ fontSize: '1rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px' }}>
                  {title}
                </h3>
                <p style={{ fontSize: '13px', color: 'var(--text-muted)', lineHeight: 1.6, margin: 0 }}>
                  {body}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Formula callout */}
      <section
        style={{
          background: 'var(--bg-panel)',
          borderTop: '1px solid var(--border)',
          borderBottom: '1px solid var(--border)',
        }}
        className="px-4 py-12"
      >
        <div className="max-w-2xl mx-auto text-center">
          <p style={{ fontSize: '12px', color: 'var(--text-muted)', letterSpacing: '0.1em', marginBottom: '16px' }}>
            FUNDING RATE FORMULA (ι = 0)
          </p>
          <div
            style={{
              fontFamily: 'var(--font-geist-mono)',
              fontSize: 'clamp(1rem, 3vw, 1.4rem)',
              color: 'var(--text-main)',
              background: 'var(--bg-card)',
              border: '1px solid var(--border)',
              borderRadius: '10px',
              padding: '20px 28px',
              display: 'inline-block',
            }}
          >
            F = <span style={{ color: 'var(--green-lite)' }}>(Mark − Index)</span> / Index
          </div>
          <p style={{ fontSize: '12px', color: 'var(--text-muted)', marginTop: '16px' }}>
            No interest floor. No riba component. Proven from Theorem 3, Ackerer, Hugonnier & Jermann (2024).
          </p>
        </div>
      </section>

      {/* Footer */}
      <footer className="px-4 py-8 text-center">
        <p style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
          Baraka Protocol is in testnet. Not financial or religious advice. Consult your scholar.
          Built by{' '}
          <a href="https://arcusquantfund.com" style={{ color: 'var(--green-lite)', textDecoration: 'none' }}>
            Arcus Quant Fund
          </a>.
        </p>
      </footer>
    </main>
  )
}
