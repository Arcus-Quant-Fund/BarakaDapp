import Link from 'next/link'

const STATS = [
  { label: 'Interest Parameter (ι)', value: '0', sub: 'Proven — Ackerer et al. (2025, Math. Finance)' },
  { label: 'SSRN Papers', value: '6', sub: 'All published March 2026' },
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
    bullets: ['ι = 0 from Theorem 3, Ackerer (2025)', 'Max 5× leverage — immutable ShariahGuard', 'USDC, PAXG, XAUT collateral', 'Full Shariah board governance'],
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
    icon: '⚖',
    title: 'Governance Token',
    body: '100M fixed supply ERC20+Votes+Permit token. Hold-based fee discounts: from 5 bps down to 2.5 bps (50% saving). Governance votes weight by token balance. No lock-up — holding is sufficient.',
  },
  {
    icon: '🛡',
    title: 'Shariah Guard',
    body: 'On-chain enforcement of Islamic finance rules. MAX_LEVERAGE = 5 is an immutable constant — cannot be changed by any admin. Asset whitelist requires dual approval: DAO + Shariah board multisig.',
  },
]

const PAPERS = [
  {
    series: 'Paper 1',
    color: '#52b788',
    title: 'The Interest Parameter in Perpetual Futures: Shariah Analysis and Empirical Evidence',
    result: '40,218 funding intervals across 5 platforms — ι=0 is mathematically separable from no-arbitrage convergence (t = 59.95, p < 10⁻³⁰⁰)',
    ssrn: '6322778',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6322778',
  },
  {
    series: 'Paper 2',
    color: '#52b788',
    title: 'From Perpetual Contracts to Islamic Credit: The Random Stopping Time Equivalence',
    result: 'Formal isomorphism: stopping time θ_t ≡ credit event τ at ι=0. Enables riba-free pricing of sukuk, takaful, and credit protection from one unified framework.',
    ssrn: '6322858',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6322858',
  },
  {
    series: 'Paper 2A',
    color: '#e9c46a',
    title: 'The κ-Yield Curve: Empirical Estimation of the Convergence Intensity from Sovereign Sukuk Data',
    result: '8,232 observations across 7 GCC & SE Asian markets — κ-yield curves upward-sloping, panel RMSE 4.6–28.5 bps; κ outperforms SOFR benchmark by 13.4%',
    ssrn: '6322938',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6322938',
  },
  {
    series: 'Paper 2B',
    color: '#e9c46a',
    title: 'Actuarial Properties of the κ-Rate Under Stochastic Hazard: CIR Applications to Agricultural Takaful',
    result: 'Model κ̂ = 12.06% matches India PMFBY national actuarial rate ≈ 12% exactly. Riba loading quantified at 7.4% of the fair premium at 8% discount rate.',
    ssrn: '6323459',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6323459',
  },
  {
    series: 'Paper 2C',
    color: '#e76f51',
    title: 'An Islamic Credit Default Swap on Smart-Contract Infrastructure: Design, Pricing, and Regulatory Pathway',
    result: 'Mean riba premium 109 bps across 1,176 country-periods. iCDS full lifecycle costs $0.14 on Arbitrum. AHJ formula fits GCC sovereigns within 7.7% MAE.',
    ssrn: '6323519',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6323519',
  },
  {
    series: 'Paper 3',
    color: '#2a9d8f',
    title: 'An Integrated Simulation Framework for DeFi Protocols: cadCAD, RL, Game Theory, and Mechanism Design',
    result: '5 episodes × 720 steps: 0 insolvency events, Nash leverage 2.72×–3.28× (below 5× cap), net transfer ≈ $0 confirming ι=0 riba-freedom empirically.',
    ssrn: '6323618',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6323618',
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
            No riba. No gharar. No maysir. Proven in Ackerer, Hugonnier &amp; Jermann (2025, <em>Mathematical Finance</em>).
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
            EVERLASTING OPTION PRICING (ι = 0) — ACKERER, HUGONNIER &amp; JERMANN (2025), PROP. 6
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

      {/* ── Research Papers ───────────────────────────────── */}
      <section className="px-4 py-16" style={{ borderBottom: '1px solid var(--border)' }}>
        <div className="max-w-5xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--text-muted)', letterSpacing: '0.12em', textAlign: 'center', marginBottom: '8px' }}>
            ACADEMIC RESEARCH
          </p>
          <h2 style={{ fontSize: '1.5rem', fontWeight: 700, color: 'var(--text-main)', textAlign: 'center', marginBottom: '8px' }}>
            6 Papers. All on SSRN.
          </h2>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', textAlign: 'center', maxWidth: '520px', margin: '0 auto 48px' }}>
            Every design decision in the protocol is grounded in peer-reviewed mathematics.
            From the ι = 0 foundation to the iCDS smart contract — all published and citable.
          </p>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            {PAPERS.map(({ series, color, title, result, ssrn, href }) => (
              <a
                key={ssrn}
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                style={{
                  display: 'block', textDecoration: 'none',
                  background: 'var(--bg-card)', border: '1px solid var(--border)',
                  borderLeft: `3px solid ${color}`, borderRadius: '12px',
                  padding: '20px 24px',
                  transition: 'border-color 0.15s',
                }}
              >
                <div className="flex items-start gap-4 flex-wrap">
                  <div style={{ minWidth: '72px' }}>
                    <div style={{ fontSize: '10px', color: color, fontWeight: 700, letterSpacing: '0.08em', marginBottom: '4px' }}>
                      {series}
                    </div>
                    <div style={{
                      fontSize: '10px', color: 'var(--text-muted)',
                      background: 'var(--bg-panel)', border: '1px solid var(--border)',
                      borderRadius: '4px', padding: '1px 6px', fontFamily: 'var(--font-geist-mono)',
                    }}>
                      SSRN {ssrn}
                    </div>
                  </div>
                  <div style={{ flex: 1, minWidth: '260px' }}>
                    <h3 style={{ fontSize: '0.9rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px', lineHeight: 1.4 }}>
                      {title}
                    </h3>
                    <p style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.5, margin: 0 }}>
                      <span style={{ color: color }}>Key result:</span> {result}
                    </p>
                  </div>
                  <div style={{ fontSize: '12px', color: 'var(--text-muted)', alignSelf: 'center', whiteSpace: 'nowrap' }}>
                    Read ↗
                  </div>
                </div>
              </a>
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
