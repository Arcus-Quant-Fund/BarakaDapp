import Link from 'next/link'
import Image from 'next/image'

const STATS = [
  { label: 'Interest Parameter (ι)', value: '0', sub: 'Proven — Ackerer et al. (2025)' },
  { label: 'SSRN Papers', value: '6', sub: 'All published March 2026' },
  { label: 'Smart Contracts', value: '13', sub: 'All verified on Arbiscan' },
  { label: 'Tests Passing', value: '177/177', sub: 'Unit + fuzz (1,000 runs)' },
]

const PRODUCTS = [
  {
    layer: 'Layer 1',
    color: '#52b788',
    title: 'Perpetual Futures DEX',
    badge: 'Live Testnet',
    description:
      'World\'s first mathematically-proven halal perpetual futures exchange. Funding formula with ι = 0 — no interest floor, no riba. Max 5× leverage enforced immutably.',
    bullets: ['ι = 0 from Theorem 3', 'Max 5× leverage — immutable', 'USDC, PAXG, XAUT collateral', 'Isolated margin only'],
    contract: 'PositionManager.sol',
  },
  {
    layer: 'Layer 2',
    color: '#e9c46a',
    title: 'Perpetual Sukuk',
    badge: 'Testnet',
    description:
      'Shariah-compliant sukuk with embedded everlasting call option. Investors subscribe at par, receive periodic ijarah-style profit, plus call upside at maturity.',
    bullets: ['Embedded everlasting call (Prop. 6)', 'Periodic profit — ijarah structure', 'Principal guaranteed by collateral', 'AAOIFI Std. 17 compliant'],
    contract: 'PerpetualSukuk.sol',
  },
  {
    layer: 'Layer 3',
    color: '#2a9d8f',
    title: 'Takaful — Mutual Insurance',
    badge: 'Testnet',
    description:
      'On-chain takaful pool priced with the everlasting put. Tabarru contribution is actuarially fair. 10% wakala fee to operator per AAOIFI Std. 26.',
    bullets: ['Fair tabarru via Ackerer Prop. 6', '10% wakala — AAOIFI compliant', 'Keeper-controlled claims', 'Surplus to charity'],
    contract: 'TakafulPool.sol',
  },
  {
    layer: 'Layer 4',
    color: '#e76f51',
    title: 'iCDS — Islamic Credit Default Swaps',
    badge: 'Testnet',
    description:
      'First Shariah-compliant CDS. Protection seller deposits full notional — no naked positions. Premium is dynamic and market-implied, not a fixed riba rate.',
    bullets: ['Dynamic put-priced premium', 'Full collateral required', 'On-chain oracle breach trigger', 'Quarterly settlement cycle'],
    contract: 'iCDS.sol',
  },
]

const FOUNDATION = [
  {
    icon: '∅',
    color: '#52b788',
    title: 'Everlasting Option Engine',
    body: 'The mathematical core powering all 4 layers. Implements Ackerer Proposition 6 at ι = 0. One formula prices everything — tabarru, sukuk upside, CDS premium — without any interest rate.',
  },
  {
    icon: 'κ',
    color: '#e9c46a',
    title: 'κ-Signal Oracle',
    body: 'Real-time convergence intensity signal replacing the interest rate r. Riba-free, market-implied, on-chain observable. Foundation for all credit pricing across Layers 2–4.',
  },
  {
    icon: '⚖',
    color: '#2a9d8f',
    title: 'Governance Token (BRKX)',
    body: '100M fixed supply. Hold-based fee discounts from 5 bps to 2.5 bps. Governance votes weighted by balance. No lock-up required.',
  },
  {
    icon: '🛡',
    color: '#e76f51',
    title: 'Shariah Guard',
    body: 'On-chain enforcement of Islamic finance rules. MAX_LEVERAGE = 5 is an immutable constant. Asset whitelist requires dual approval: DAO + Shariah board multisig.',
  },
]

const COMPLIANCE = [
  { prohibition: 'Riba (Interest)', arabic: 'ربا', solution: 'ι = 0 hardcoded — no interest term anywhere in the protocol stack' },
  { prohibition: 'Gharar (Uncertainty)', arabic: 'غرر', solution: 'Credit events are verifiable on-chain oracle breaches — no committee ambiguity' },
  { prohibition: 'Maysir (Gambling)', arabic: 'ميسر', solution: 'Max 5× leverage is immutable. CDS sellers must post full notional collateral' },
  { prohibition: 'Qabdh (Possession)', arabic: 'قبض', solution: 'USDC, PAXG, XAUT — real-asset backed collateral. No rehypothecation' },
]

const PAPERS = [
  {
    series: 'Paper 1',
    color: '#52b788',
    title: 'The Interest Parameter in Perpetual Futures',
    result: '40,218 funding intervals — ι=0 is mathematically separable from convergence (t = 59.95, p < 10⁻³⁰⁰)',
    ssrn: '6322778',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6322778',
  },
  {
    series: 'Paper 2',
    color: '#52b788',
    title: 'From Perpetual Contracts to Islamic Credit',
    result: 'Stopping time θ_t ≡ credit event τ at ι=0 — enables riba-free pricing across sukuk, takaful, and credit',
    ssrn: '6322858',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6322858',
  },
  {
    series: 'Paper 2A',
    color: '#e9c46a',
    title: 'The κ-Yield Curve from Sovereign Sukuk Data',
    result: '8,232 observations across 7 GCC & SE Asian markets — κ outperforms SOFR benchmark by 13.4%',
    ssrn: '6322938',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6322938',
  },
  {
    series: 'Paper 2B',
    color: '#e9c46a',
    title: 'κ-Rate Stochastic Hazard: Agricultural Takaful',
    result: 'Model κ̂ = 12.06% matches India PMFBY rate exactly. Riba loading = 7.4% at 8% discount rate',
    ssrn: '6323459',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6323459',
  },
  {
    series: 'Paper 2C',
    color: '#e76f51',
    title: 'Islamic CDS on Smart-Contract Infrastructure',
    result: 'Mean riba premium 109 bps across 1,176 country-periods. Full lifecycle costs $0.14 on Arbitrum',
    ssrn: '6323519',
    href: 'https://papers.ssrn.com/sol3/papers.cfm?abstract_id=6323519',
  },
  {
    series: 'Paper 3',
    color: '#2a9d8f',
    title: 'Integrated Simulation Framework for DeFi',
    result: '0 insolvency events, Nash leverage 2.72×–3.28× (below 5× cap), net transfer ≈ $0 confirming ι=0',
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
          background: 'linear-gradient(180deg, var(--bg-deep) 0%, var(--bg-panel) 100%)',
          borderBottom: '1px solid var(--border)',
          position: 'relative',
          overflow: 'hidden',
        }}
        className="px-4 py-24 text-center"
      >
        {/* Background glow */}
        <div style={{
          position: 'absolute', top: '50%', left: '50%',
          transform: 'translate(-50%, -60%)',
          width: '600px', height: '600px',
          background: 'radial-gradient(circle, rgba(82,183,136,0.06) 0%, transparent 70%)',
          pointerEvents: 'none',
        }} />

        <div className="max-w-3xl mx-auto" style={{ position: 'relative', zIndex: 1 }}>
          <div
            style={{
              display: 'inline-flex', alignItems: 'center', gap: '8px',
              background: 'rgba(27,67,50,0.4)', border: '1px solid var(--green-deep)',
              borderRadius: '999px', padding: '4px 14px', marginBottom: '28px',
              fontSize: '12px', color: 'var(--green-lite)',
            }}
            className="animate-fade-up"
          >
            <span
              style={{ width: '6px', height: '6px', borderRadius: '50%', background: 'var(--green-lite)', display: 'inline-block' }}
              className="animate-pulse"
            />
            Testnet Live — Arbitrum Sepolia
          </div>

          <div className="animate-fade-up animate-delay-1">
            <Image
              src="/baraka-logo.png"
              alt="Baraka"
              width={160}
              height={160}
              style={{ margin: '0 auto 28px', display: 'block' }}
              priority
            />
          </div>

          <h1
            style={{ fontSize: 'clamp(2.2rem, 5vw, 3.8rem)', fontWeight: 800, lineHeight: 1.05, color: 'var(--text-main)', marginBottom: '24px', letterSpacing: '-0.02em' }}
            className="animate-fade-up animate-delay-2"
          >
            The World&apos;s First<br />
            <span className="gradient-text">Islamic Financial Protocol</span>
          </h1>

          <p
            style={{ fontSize: '1.1rem', color: 'var(--text-muted)', maxWidth: '580px', margin: '0 auto 16px', lineHeight: 1.7 }}
            className="animate-fade-up animate-delay-3"
          >
            Four Shariah-compliant financial products on one protocol — perpetual futures, sukuk,
            takaful insurance, and credit default swaps — all powered by a single mathematical
            engine with <strong style={{ color: 'var(--green-lite)' }}>ι = 0</strong>.
          </p>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '40px' }} className="animate-fade-up animate-delay-3">
            No riba. No gharar. No maysir. Proven in Ackerer, Hugonnier &amp; Jermann (2025, <em>Mathematical Finance</em>).
          </p>

          <div className="flex gap-4 justify-center flex-wrap animate-fade-up animate-delay-4">
            <Link
              href="/trade"
              style={{
                background: 'var(--green-deep)', color: 'var(--text-main)',
                padding: '14px 32px', borderRadius: '10px', fontWeight: 600,
                fontSize: '15px', textDecoration: 'none', border: '1px solid var(--green-mid)',
                transition: 'all 0.2s',
              }}
            >
              Open Trade
            </Link>
            <Link
              href="/transparency"
              style={{
                background: 'transparent', color: 'var(--gold)',
                padding: '14px 32px', borderRadius: '10px', fontWeight: 600,
                fontSize: '15px', textDecoration: 'none', border: '1px solid rgba(212,175,55,0.3)',
                transition: 'all 0.2s',
              }}
            >
              Shariah Proof
            </Link>
          </div>
        </div>
      </section>

      {/* ── Stats ─────────────────────────────────────────── */}
      <section style={{ borderBottom: '1px solid var(--border)' }} className="px-4 py-12">
        <div className="max-w-4xl mx-auto grid grid-cols-2 md:grid-cols-4 gap-6">
          {STATS.map(({ label, value, sub }, i) => (
            <div
              key={label}
              className={`text-center animate-fade-up animate-delay-${i + 1}`}
              style={{
                background: 'var(--bg-card)',
                border: '1px solid var(--border)',
                borderRadius: '12px',
                padding: '20px 16px',
              }}
            >
              <div className="stat-value" style={{ fontSize: 'clamp(1.8rem, 4vw, 2.6rem)', fontWeight: 800, color: 'var(--gold)', lineHeight: 1 }}>
                {value}
              </div>
              <div style={{ fontSize: '12px', fontWeight: 600, color: 'var(--text-main)', marginTop: '8px' }}>
                {label}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '4px' }}>
                {sub}
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* ── Product Stack ─────────────────────────────────── */}
      <section className="px-4 py-20">
        <div className="max-w-5xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--green-lite)', letterSpacing: '0.15em', textAlign: 'center', marginBottom: '8px', fontWeight: 600 }}>
            PROTOCOL SUITE
          </p>
          <h2
            style={{ fontSize: '1.8rem', fontWeight: 800, color: 'var(--text-main)', textAlign: 'center', marginBottom: '8px' }}
          >
            Four Products. One Framework.
          </h2>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', textAlign: 'center', marginBottom: '48px', maxWidth: '520px', margin: '0 auto 48px' }}>
            Every product uses the same ι = 0 everlasting option formula — no interest rate anywhere in the stack.
          </p>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
            {PRODUCTS.map(({ layer, color, title, badge, description, bullets, contract }) => (
              <div
                key={layer}
                className="card-hover"
                style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '14px',
                  padding: '0',
                  display: 'flex',
                  overflow: 'hidden',
                }}
              >
                {/* Color bar */}
                <div className="layer-indicator" style={{ background: color }} />

                <div style={{ padding: '24px 28px', flex: 1 }}>
                  <div className="flex items-start gap-4 flex-wrap">
                    <div style={{ minWidth: '80px' }}>
                      <div style={{ fontSize: '11px', color: color, fontWeight: 700, letterSpacing: '0.08em', marginBottom: '6px' }}>
                        {layer}
                      </div>
                      <div
                        style={{
                          display: 'inline-block', fontSize: '10px', fontWeight: 600,
                          color: color, border: `1px solid ${color}`,
                          borderRadius: '4px', padding: '2px 8px', opacity: 0.8,
                        }}
                      >
                        {badge}
                      </div>
                    </div>
                    <div style={{ flex: 1, minWidth: '260px' }}>
                      <h3 style={{ fontSize: '1.05rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px' }}>
                        {title}
                      </h3>
                      <p style={{ fontSize: '13px', color: 'var(--text-muted)', lineHeight: 1.7, marginBottom: '14px' }}>
                        {description}
                      </p>
                      <div className="flex flex-wrap gap-2">
                        {bullets.map(b => (
                          <span
                            key={b}
                            style={{
                              fontSize: '11px', color: 'var(--text-muted)',
                              background: 'var(--bg-panel)', border: '1px solid var(--border)',
                              borderRadius: '6px', padding: '3px 10px',
                            }}
                          >
                            {b}
                          </span>
                        ))}
                      </div>
                    </div>
                    <div
                      style={{
                        fontSize: '11px', fontFamily: 'var(--font-geist-mono)',
                        color: 'var(--text-muted)', background: 'var(--bg-panel)',
                        border: '1px solid var(--border)', borderRadius: '6px',
                        padding: '6px 12px', alignSelf: 'flex-start', whiteSpace: 'nowrap',
                      }}
                    >
                      {contract}
                    </div>
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
        className="px-4 py-16"
      >
        <div className="max-w-2xl mx-auto text-center">
          <p style={{ fontSize: '11px', color: 'var(--green-lite)', letterSpacing: '0.12em', marginBottom: '20px', fontWeight: 600 }}>
            EVERLASTING OPTION PRICING (ι = 0)
          </p>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', marginBottom: '20px' }}>
            Ackerer, Hugonnier &amp; Jermann (2025, <em>Mathematical Finance</em>), Proposition 6
          </p>
          <div
            style={{
              fontFamily: 'var(--font-geist-mono)', fontSize: 'clamp(1rem, 2.5vw, 1.3rem)',
              color: 'var(--text-main)', background: 'var(--bg-card)',
              border: '1px solid var(--border)', borderRadius: '14px',
              padding: '28px 36px', display: 'inline-block',
            }}
          >
            <div style={{ marginBottom: '10px', fontSize: '1.1em' }}>
              F = <span style={{ color: 'var(--green-lite)' }}>(Mark − Index)</span> / Index
            </div>
            <div style={{ color: 'var(--text-muted)', fontSize: '0.85em' }}>
              Π(x,K) = [K<sup>1−β</sup> / denom] · x<sup>β</sup>
              <span style={{ marginLeft: '14px', color: 'var(--gold)', fontWeight: 700 }}>ι = 0</span>
            </div>
          </div>
          <p style={{ fontSize: '13px', color: 'var(--text-muted)', marginTop: '20px', maxWidth: '460px', margin: '20px auto 0' }}>
            One formula — zero interest — powers perpetual futures, sukuk, takaful, and credit protection.
          </p>
        </div>
      </section>

      {/* ── Foundation Layer ──────────────────────────────── */}
      <section className="px-4 py-20" style={{ borderBottom: '1px solid var(--border)' }}>
        <div className="max-w-5xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--green-lite)', letterSpacing: '0.15em', textAlign: 'center', marginBottom: '8px', fontWeight: 600 }}>
            PROTOCOL INFRASTRUCTURE
          </p>
          <h2
            style={{ fontSize: '1.8rem', fontWeight: 800, color: 'var(--text-main)', textAlign: 'center', marginBottom: '48px' }}
          >
            The Foundation
          </h2>
          <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
            {FOUNDATION.map(({ icon, color, title, body }) => (
              <div
                key={title}
                className="card-hover"
                style={{
                  background: 'var(--bg-card)', border: '1px solid var(--border)',
                  borderRadius: '14px', padding: '28px',
                }}
              >
                <div
                  style={{
                    width: '44px', height: '44px', borderRadius: '10px',
                    background: `${color}15`, border: `1px solid ${color}30`,
                    display: 'flex', alignItems: 'center', justifyContent: 'center',
                    fontSize: '1.2rem', marginBottom: '16px',
                  }}
                >
                  {icon}
                </div>
                <h3 style={{ fontSize: '1rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '10px' }}>
                  {title}
                </h3>
                <p style={{ fontSize: '13px', color: 'var(--text-muted)', lineHeight: 1.7, margin: 0 }}>
                  {body}
                </p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Shariah compliance ────────────────────────────── */}
      <section className="px-4 py-20" style={{ background: 'var(--bg-panel)', borderBottom: '1px solid var(--border)' }}>
        <div className="max-w-3xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--green-lite)', letterSpacing: '0.15em', textAlign: 'center', marginBottom: '8px', fontWeight: 600 }}>
            SHARIAH COMPLIANCE
          </p>
          <h2
            style={{ fontSize: '1.8rem', fontWeight: 800, color: 'var(--text-main)', textAlign: 'center', marginBottom: '40px' }}
          >
            Every Prohibition Addressed
          </h2>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            {COMPLIANCE.map(({ prohibition, arabic, solution }) => (
              <div
                key={prohibition}
                className="card-hover"
                style={{
                  display: 'flex', alignItems: 'center', gap: '20px',
                  padding: '18px 24px', background: 'var(--bg-card)',
                  border: '1px solid var(--border)', borderRadius: '12px',
                }}
              >
                <div style={{ minWidth: '140px' }}>
                  <div style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)' }}>{prohibition}</div>
                  <div style={{ fontSize: '16px', color: 'var(--gold)', fontFamily: 'serif', marginTop: '2px' }}>{arabic}</div>
                </div>
                <div style={{ fontSize: '13px', color: 'var(--text-muted)', lineHeight: 1.6, flex: 1 }}>{solution}</div>
                <div style={{ fontSize: '18px', color: 'var(--green-lite)', flexShrink: 0 }}>✓</div>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* ── Research Papers ───────────────────────────────── */}
      <section className="px-4 py-20" style={{ borderBottom: '1px solid var(--border)' }}>
        <div className="max-w-5xl mx-auto">
          <p style={{ fontSize: '11px', color: 'var(--green-lite)', letterSpacing: '0.15em', textAlign: 'center', marginBottom: '8px', fontWeight: 600 }}>
            ACADEMIC RESEARCH
          </p>
          <h2 style={{ fontSize: '1.8rem', fontWeight: 800, color: 'var(--text-main)', textAlign: 'center', marginBottom: '8px' }}>
            6 Papers. All on SSRN.
          </h2>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', textAlign: 'center', maxWidth: '520px', margin: '0 auto 48px' }}>
            Every design decision is grounded in peer-reviewed mathematics — all published and citable.
          </p>

          <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
            {PAPERS.map(({ series, color, title, result, ssrn, href }) => (
              <a
                key={ssrn}
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                className="paper-card"
                style={{
                  display: 'block', textDecoration: 'none',
                  background: 'var(--bg-card)', border: '1px solid var(--border)',
                  borderRadius: '14px', padding: '20px 24px',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '12px' }}>
                  <span style={{
                    fontSize: '10px', color: color, fontWeight: 700,
                    letterSpacing: '0.08em',
                  }}>
                    {series}
                  </span>
                  <span style={{
                    fontSize: '10px', color: 'var(--text-muted)',
                    background: 'var(--bg-panel)', border: '1px solid var(--border)',
                    borderRadius: '4px', padding: '1px 6px', fontFamily: 'var(--font-geist-mono)',
                  }}>
                    SSRN {ssrn}
                  </span>
                  <span style={{ marginLeft: 'auto', fontSize: '12px', color: 'var(--text-muted)' }}>
                    ↗
                  </span>
                </div>
                <h3 style={{ fontSize: '0.9rem', fontWeight: 700, color: 'var(--text-main)', marginBottom: '8px', lineHeight: 1.4 }}>
                  {title}
                </h3>
                <p style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.5, margin: 0 }}>
                  {result}
                </p>
              </a>
            ))}
          </div>
        </div>
      </section>

      {/* ── CTA ───────────────────────────────────────────── */}
      <section className="px-4 py-20 text-center">
        <div className="max-w-2xl mx-auto">
          <h2 style={{ fontSize: '1.6rem', fontWeight: 800, color: 'var(--text-main)', marginBottom: '14px' }}>
            Start Trading — Halal, Proven, On-Chain
          </h2>
          <p style={{ fontSize: '14px', color: 'var(--text-muted)', marginBottom: '32px', lineHeight: 1.7 }}>
            Baraka Protocol is live on Arbitrum Sepolia testnet. Connect your wallet and
            open your first Shariah-compliant perpetual position.
          </p>
          <div className="flex gap-4 justify-center flex-wrap">
            <Link
              href="/trade"
              style={{
                background: 'var(--green-deep)', color: 'var(--text-main)',
                padding: '14px 32px', borderRadius: '10px', fontWeight: 600,
                fontSize: '15px', textDecoration: 'none', border: '1px solid var(--green-mid)',
                transition: 'all 0.2s',
              }}
            >
              Open Trade
            </Link>
            <Link
              href="/transparency"
              style={{
                background: 'transparent', color: 'var(--gold)',
                padding: '14px 32px', borderRadius: '10px', fontWeight: 600,
                fontSize: '15px', textDecoration: 'none', border: '1px solid rgba(212,175,55,0.3)',
                transition: 'all 0.2s',
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
                padding: '14px 32px', borderRadius: '10px', fontWeight: 600,
                fontSize: '15px', textDecoration: 'none', border: '1px solid var(--border)',
                transition: 'all 0.2s',
              }}
            >
              GitHub ↗
            </a>
          </div>
        </div>
      </section>

      {/* ── Footer ────────────────────────────────────────── */}
      <footer style={{ borderTop: '1px solid var(--border)', background: 'var(--bg-panel)' }} className="px-4 py-10">
        <div className="max-w-5xl mx-auto">
          <div className="flex flex-col md:flex-row items-center justify-between gap-6">
            <div className="flex items-center gap-3">
              <Image src="/baraka-logo.png" alt="Baraka" width={28} height={28} />
              <span style={{ color: 'var(--text-main)', fontWeight: 600, fontSize: '14px' }}>Baraka Protocol</span>
              <span style={{ color: 'var(--text-muted)', fontSize: '12px' }}>Testnet</span>
            </div>
            <div className="flex items-center gap-6" style={{ fontSize: '13px' }}>
              <Link href="/transparency" style={{ color: 'var(--text-muted)', textDecoration: 'none' }}>Transparency</Link>
              <a href="https://github.com/Arcus-Quant-Fund/BarakaDapp" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--text-muted)', textDecoration: 'none' }}>GitHub</a>
              <a href="https://arcusquantfund.com" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--text-muted)', textDecoration: 'none' }}>Arcus Quant Fund</a>
              <a href="https://arcusquantfund.com/contact" target="_blank" rel="noopener noreferrer" style={{ color: 'var(--text-muted)', textDecoration: 'none' }}>Contact</a>
            </div>
          </div>
          <div style={{ borderTop: '1px solid var(--border)', marginTop: '20px', paddingTop: '20px' }}>
            <p style={{ fontSize: '11px', color: 'var(--text-muted)', textAlign: 'center' }}>
              Baraka Protocol is in testnet. Not financial or religious advice. Consult your scholar.
              Built by{' '}
              <a href="https://arcusquantfund.com" style={{ color: 'var(--green-lite)', textDecoration: 'none' }}>
                Arcus Quant Fund
              </a>.
            </p>
          </div>
        </div>
      </footer>
    </main>
  )
}
