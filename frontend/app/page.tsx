import Link from 'next/link'

const STATS = [
  { label: 'Interest Parameter (ι)', value: '0', sub: 'Proven — Ackerer et al. (2024)' },
  { label: 'Max Leverage', value: '5×', sub: 'Hard-coded in ShariahGuard.sol' },
  { label: 'Smart Contracts', value: '12', sub: 'All verified on Arbiscan ✓' },
  { label: 'Tests Passing', value: '177/177', sub: 'Unit + fuzz (1 000 runs each)' },
]

// 4-layer product stack
const PRODUCTS = [
  {
    layer: 'Layer 4',
    color: '#e76f51',
    title: 'iCDS — Islamic Credit Default Swaps',
    badge: 'Testnet',
    description:
      'First Shariah-compliant CDS instrument. Protection seller deposits full notional (no naked positions). Premium = Π_put(spot, recovery floor) × notional — dynamic, market-implied, not a fixed riba rate. Credit event = on-chain oracle breach (verifiable, no committee ambiguity).',
    bullets: ['Dynamic put-priced premium (Prop. 6)', 'Quarterly settlement cycle', 'LGD = notional × (1 − recovery rate)', 'Keeper-triggered oracle breach'],
    contract: 'iCDS.sol',
  },
  {
    layer: 'Layer 3',
    color: '#2a9d8f',
    title: 'TakafulPool — Mutual Islamic Insurance',
    badge: 'Testnet',
    description:
      'On-chain takaful (mutual guarantee) pool priced with the everlasting put. Tabarru (contribution) = Π_put(spot, floor) × coverage / WAD. 10% wakala fee to the operator (AAOIFI Std. 26). Keeper triggers claims when oracle price breaches the floor.',
    bullets: ['Actuarially fair tabarru via Ackerer Prop. 6', '10% wakala — AAOIFI Std. 26 compliant', 'Keeper-controlled claim trigger', 'Surplus distribution to charity'],
    contract: 'TakafulPool.sol',
  },
  {
    layer: 'Layer 2',
    color: '#e9c46a',
    title: 'PerpetualSukuk — Islamic Capital Markets',
    badge: 'Testnet',
    description:
      'Shariah-compliant sukuk with an embedded everlasting call option. Issuer deposits par value as collateral. Investors subscribe at par and receive periodic profit (ijarah-style). At maturity: principal + Π_call(spot, par) × subscribed / WAD call upside. No riba — ι = 0 throughout.',
    bullets: ['Embedded everlasting call (Prop. 6)', 'Periodic profit — ijarah structure', 'Principal guaranteed by issuer collateral', 'AAOIFI Std. 17 compliant'],
    contract: 'PerpetualSukuk.sol',
  },
  {
    layer: 'Layer 1',
    color: '#52b788',
    title: 'Perpetual Futures DEX',
    badge: 'Live Testnet',
    description:
      'World\'s first mathematically-proven halal perpetual futures exchange. Funding formula F = (Mark − Index) / Index with ι = 0 — no interest floor, no riba. Max 5× leverage enforced immutably. Isolated margin only. All collateral non-rehypothecated.',
    bullets: ['ι = 0 from Theorem 3, Ackerer (2024)', 'Max 5× leverage — immutable ShariahGuard', 'USDC, PAXG, XAUT collateral', 'Full Shariah board governance'],
    contract: 'PositionManager.sol',
  },
]

const FOUNDATION = [
  {
    icon: '∅',
    title: 'EverlastingOption (Layer 1.5)',
    body: 'The mathematical engine powering all 4 layers. Implements Ackerer Proposition 6 at ι = 0: Π(x,K) = [K^{1−β} / denom] · x^β. Prices tabarru, sukuk upside, and CDS premium without any interest rate.',
  },
  {
    icon: 'κ',
    title: 'κ-Signal Oracle',
    body: 'Real-time convergence intensity signal from the OracleAdapter. Replaces the interest rate r as a monetary primitive. Riba-free, market-implied, on-chain observable. Foundation for all credit pricing across Layer 2/3/4.',
  },
  {
    icon: '🪙',
    title: 'BRKX — Governance Token',
    body: '100M fixed supply ERC20+Votes+Permit token. Hold-based fee discounts: from 5 bps down to 2.5 bps (50% saving). Governance votes weight by BRKX balance. No lock-up — holding is sufficient.',
  },
  {
    icon: '⚖',
    title: 'Shariah Guard',
    body: 'On-chain enforcement of Islamic finance rules. MAX_LEVERAGE = 5 is an immutable constant — cannot be changed by any admin. Asset whitelist requires dual approval: DAO + Shariah board multisig.',
  },
]

export default function HomePage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)' }}>

      {/* ── Hero ──────────────────────────────────────────── */}
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
              display: 'inline-flex', alignItems: 'center', gap: '8px',
              background: 'rgba(27,67,50,0.4)', border: '1px solid var(--green-deep)',
              borderRadius: '999px', padding: '4px 14px', marginBottom: '24px',
              fontSize: '12px', color: 'var(--green-lite)',
            }}
          >
            <span
              style={{ width: '6px', height: '6px', borderRadius: '50%', background: 'var(--green-lite)', display: 'inline-block' }}
              className="animate-pulse"
            />
            Testnet Live — Arbitrum Sepolia
          </div>

          <h1
            style={{ fontSize: 'clamp(2rem, 5vw, 3.5rem)', fontWeight: 700, lineHeight: 1.1, color: 'var(--text-main)', marginBottom: '20px' }}
          >
            The World&apos;s First<br />
            <span style={{ color: 'var(--gold)' }}>Islamic Financial Protocol</span>
          </h1>

          <p
            style={{ fontSize: '1.05rem', color: 'var(--text-muted)', maxWidth: '600px', margin: '0 auto 12px', lineHeight: 1.6 }}
          >
            Four Shariah-compliant financial products on one protocol — perpetual futures, sukuk,
            takaful insurance, and credit default swaps — all powered by a single mathematical
            engine with <strong style={{ color: 'var(--green-lite)' }}>ι = 0</strong>.
          </p>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '36px' }}>
            No riba. No gharar. No maysir. Proven from Ackerer, Hugonnier &amp; Jermann (2024).
          </p>

          <div className="flex gap-4 justify-center flex-wrap">
            <Link
              href="/trade"
              style={{
                background: 'var(--green-deep)', color: 'var(--text-main)',
                padding: '12px 28px', borderRadius: '8px', fontWeight: 600,
                fontSize: '14px', textDecoration: 'none', border: '1px solid var(--green-mid)',
              }}
            >
              Open Trade
            </Link>
            <Link
              href="/transparency"
              style={{
                background: 'transparent', color: 'var(--gold)',
                padding: '12px 28px', borderRadius: '8px', fontWeight: 600,
                fontSize: '14px', textDecoration: 'none', border: '1px solid rgba(212,175,55,0.3)',
              }}
            >
              Shariah Proof
            </Link>
          </div>
        </div>
      </section>

      {/* ── Stats ─────────────────────────────────────────── */}
      <section style={{ borderBottom: '1px solid var(--border)' }} className="px-4 py-10">
        <div className="max-w-5xl mx-auto grid grid-cols-2 md:grid-cols-4 gap-6">
          {STATS.map(({ label, value, sub }) => (
            <div key={label} className="text-center">
              <div style={{ fontSize: 'clamp(1.6rem, 4vw, 2.4rem)', fontWeight: 700, color: 'var(--gold)' }}>
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

      {/* ── Product Stack ─────────────────────────────────── */}
      <section className="px-4 py-16">
        <div className="max-w-5xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--text-muted)', letterSpacing: '0.12em', textAlign: 'center', marginBottom: '8px' }}>
            PROTOCOL SUITE
          </p>
          <h2
            style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', textAlign: 'center', marginBottom: '8px' }}
          >
            Four Products. One Framework.
          </h2>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', textAlign: 'center', marginBottom: '48px', maxWidth: '520px', margin: '0 auto 48px' }}>
            Every product uses the same ι = 0 everlasting option formula — no interest rate anywhere in the stack.
          </p>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
            {PRODUCTS.map(({ layer, color, title, badge, description, bullets, contract }) => (
              <div
                key={layer}
                style={{
                  background: 'var(--bg-card)',
                  border: `1px solid var(--border)`,
                  borderLeft: `3px solid ${color}`,
                  borderRadius: '12px',
                  padding: '24px 28px',
                }}
              >
                <div className="flex items-start gap-4 flex-wrap">
                  {/* Layer label */}
                  <div style={{ minWidth: '80px' }}>
                    <div style={{ fontSize: '11px', color: color, fontWeight: 700, letterSpacing: '0.08em', marginBottom: '4px' }}>
                      {layer}
                    </div>
                    <div
                      style={{
                        display: 'inline-block', fontSize: '10px', fontWeight: 600,
                        color: color, border: `1px solid ${color}`,
                        borderRadius: '4px', padding: '1px 6px', opacity: 0.8,
                      }}
                    >
                      {badge}
                    </div>
                  </div>
                  {/* Content */}
                  <div style={{ flex: 1, minWidth: '260px' }}>
                    <h3 style={{ fontSize: '1rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px' }}>
                      {title}
                    </h3>
                    <p style={{ fontSize: '13px', color: 'var(--text-muted)', lineHeight: 1.6, marginBottom: '12px' }}>
                      {description}
                    </p>
                    <div className="flex flex-wrap gap-2">
                      {bullets.map(b => (
                        <span
                          key={b}
                          style={{
                            fontSize: '11px', color: 'var(--text-muted)',
                            background: 'var(--bg-panel)', border: '1px solid var(--border)',
                            borderRadius: '4px', padding: '2px 8px',
                          }}
                        >
                          {b}
                        </span>
                      ))}
                    </div>
                  </div>
                  {/* Contract badge */}
                  <div
                    style={{
                      fontSize: '11px', fontFamily: 'var(--font-geist-mono)',
                      color: 'var(--text-muted)', background: 'var(--bg-panel)',
                      border: '1px solid var(--border)', borderRadius: '6px',
                      padding: '4px 10px', alignSelf: 'flex-start', whiteSpace: 'nowrap',
                    }}
                  >
                    {contract}
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Formula callout ───────────────────────────────── */}
      <section
        style={{ background: 'var(--bg-panel)', borderTop: '1px solid var(--border)', borderBottom: '1px solid var(--border)' }}
        className="px-4 py-12"
      >
        <div className="max-w-2xl mx-auto text-center">
          <p style={{ fontSize: '12px', color: 'var(--text-muted)', letterSpacing: '0.1em', marginBottom: '16px' }}>
            EVERLASTING OPTION PRICING (ι = 0) — ACKERER, HUGONNIER &amp; JERMANN (2024), PROP. 6
          </p>
          <div
            style={{
              fontFamily: 'var(--font-geist-mono)', fontSize: 'clamp(0.9rem, 2.5vw, 1.2rem)',
              color: 'var(--text-main)', background: 'var(--bg-card)',
              border: '1px solid var(--border)', borderRadius: '10px',
              padding: '20px 28px', display: 'inline-block',
            }}
          >
            <div style={{ marginBottom: '8px' }}>
              F = <span style={{ color: 'var(--green-lite)' }}>(Mark − Index)</span> / Index
            </div>
            <div style={{ color: 'var(--text-muted)', fontSize: '0.85em' }}>
              Π(x,K) = [K<sup>1−β</sup> / denom] · x<sup>β</sup>
              <span style={{ marginLeft: '12px', color: 'var(--gold)' }}>ι = 0</span>
            </div>
          </div>
          <p style={{ fontSize: '12px', color: 'var(--text-muted)', marginTop: '16px' }}>
            One formula — zero interest — powers perpetual futures, sukuk, takaful, and credit protection.
          </p>
        </div>
      </section>

      {/* ── Foundation Layer ──────────────────────────────── */}
      <section className="px-4 py-16" style={{ borderBottom: '1px solid var(--border)' }}>
        <div className="max-w-5xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--text-muted)', letterSpacing: '0.12em', textAlign: 'center', marginBottom: '8px' }}>
            PROTOCOL INFRASTRUCTURE
          </p>
          <h2
            style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', textAlign: 'center', marginBottom: '40px' }}
          >
            The Foundation (Layer 1 + 1.5)
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {FOUNDATION.map(({ icon, title, body }) => (
              <div
                key={title}
                style={{ background: 'var(--bg-card)', border: '1px solid var(--border)', borderRadius: '12px', padding: '24px' }}
              >
                <div style={{ fontSize: '1.4rem', marginBottom: '12px' }}>{icon}</div>
                <h3 style={{ fontSize: '0.95rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px' }}>
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

      {/* ── Shariah compliance table ──────────────────────── */}
      <section className="px-4 py-16" style={{ background: 'var(--bg-panel)', borderBottom: '1px solid var(--border)' }}>
        <div className="max-w-3xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--text-muted)', letterSpacing: '0.12em', textAlign: 'center', marginBottom: '8px' }}>
            SHARIAH COMPLIANCE
          </p>
          <h2
            style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', textAlign: 'center', marginBottom: '32px' }}
          >
            Every Prohibition Addressed
          </h2>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '1px', border: '1px solid var(--border)', borderRadius: '12px', overflow: 'hidden' }}>
            {[
              { prohibition: 'Riba (interest)', arabic: 'ربا', solution: 'ι = 0 hardcoded — no interest term anywhere in the stack', status: '✓' },
              { prohibition: 'Gharar (uncertainty)', arabic: 'غرر', solution: 'Credit events = verifiable on-chain oracle breaches. No committees.', status: '✓' },
              { prohibition: 'Maysir (gambling)', arabic: 'ميسر', solution: 'Max 5× leverage is immutable. Sellers post full notional (no naked CDS).', status: '✓' },
              { prohibition: 'Qabdh (possession)', arabic: 'قبض', solution: 'USDC, PAXG, XAUT — real-asset collateral. No rehypothecation.', status: '✓' },
            ].map(({ prohibition, arabic, solution, status }) => (
              <div
                key={prohibition}
                style={{
                  display: 'grid', gridTemplateColumns: '180px 1fr 32px',
                  gap: '16px', alignItems: 'center',
                  padding: '14px 20px', background: 'var(--bg-card)',
                  borderBottom: '1px solid var(--border)',
                }}
              >
                <div>
                  <div style={{ fontSize: '13px', fontWeight: 600, color: 'var(--text-main)' }}>{prohibition}</div>
                  <div style={{ fontSize: '13px', color: 'var(--text-muted)', fontFamily: 'serif' }}>{arabic}</div>
                </div>
                <div style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.5 }}>{solution}</div>
                <div style={{ fontSize: '16px', color: 'var(--green-lite)', textAlign: 'right' }}>{status}</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── CTA ───────────────────────────────────────────── */}
      <section className="px-4 py-16 text-center">
        <div className="max-w-2xl mx-auto">
          <h2 style={{ fontSize: '1.4rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '12px' }}>
            Start Trading — Halal, Proven, On-Chain
          </h2>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '28px', lineHeight: 1.6 }}>
            Baraka Protocol is live on Arbitrum Sepolia testnet. Connect your wallet and
            open your first Shariah-compliant perpetual position.
          </p>
          <div className="flex gap-4 justify-center flex-wrap">
            <Link
              href="/trade"
              style={{
                background: 'var(--green-deep)', color: 'var(--text-main)',
                padding: '12px 28px', borderRadius: '8px', fontWeight: 600,
                fontSize: '14px', textDecoration: 'none', border: '1px solid var(--green-mid)',
              }}
            >
              Open Trade
            </Link>
            <Link
              href="/transparency"
              style={{
                background: 'transparent', color: 'var(--gold)',
                padding: '12px 28px', borderRadius: '8px', fontWeight: 600,
                fontSize: '14px', textDecoration: 'none', border: '1px solid rgba(212,175,55,0.3)',
              }}
            >
              Read the Proof
            </Link>
            <a
              href="https://github.com/Arcus-Quant-Fund/BarakaDapp"
              target="_blank"
              rel="noopener noreferrer"
              style={{
                background: 'transparent', color: 'var(--text-muted)',
                padding: '12px 28px', borderRadius: '8px', fontWeight: 600,
                fontSize: '14px', textDecoration: 'none', border: '1px solid var(--border)',
              }}
            >
              GitHub ↗
            </a>
          </div>
        </div>
      </section>

      {/* ── Footer ────────────────────────────────────────── */}
      <footer style={{ borderTop: '1px solid var(--border)' }} className="px-4 py-8 text-center">
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
