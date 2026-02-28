'use client'

import Link from 'next/link'
import { useAccount } from 'wagmi'
import { useBrkxTier } from '@/hooks/useBrkxTier'
import { usePositions } from '@/hooks/usePositions'
import { useOraclePrices } from '@/hooks/useOraclePrices'
import { useSukukCount, useSukukList, useUserSukukPositions } from '@/hooks/useSukukData'
import { useTakafulPoolData, useMemberData, BTC_POOL_ID } from '@/hooks/useTakafulData'
import { useProtectionList, useProtections } from '@/hooks/useCreditData'
import { PRODUCT_CONTRACTS } from '@/lib/contracts'

const WAD = 1e18
const PANEL = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border)',
  borderRadius: '12px',
  padding: '20px',
} as const

function fmtUSDC(raw: bigint) {
  return (Number(raw) / 1e6).toLocaleString(undefined, { maximumFractionDigits: 2 })
}

function StatCard({ label, value, sub, color }: { label: string; value: string; sub?: string; color?: string }) {
  return (
    <div style={PANEL}>
      <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '6px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
        {label}
      </div>
      <div style={{ fontSize: '1.4rem', fontWeight: 700, color: color ?? 'var(--text-main)' }}>
        {value}
      </div>
      {sub && <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '4px' }}>{sub}</div>}
    </div>
  )
}

function SectionHeader({ title, link, linkLabel }: { title: string; link: string; linkLabel: string }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '14px' }}>
      <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', margin: 0 }}>{title}</h2>
      <Link href={link} style={{ fontSize: '12px', color: 'var(--green-lite)', textDecoration: 'none' }}>
        {linkLabel} →
      </Link>
    </div>
  )
}

export default function DashboardClient() {
  const { address } = useAccount()
  const tier = useBrkxTier()
  const { positions } = usePositions()
  const { markDisplay, indexDisplay } = useOraclePrices()

  // Sukuk
  const { count } = useSukukCount()
  const { sukuks } = useSukukList(count)
  const { positions: sukukPositions } = useUserSukukPositions(sukuks.map(s => s.id), address)

  // Takaful
  const { pool } = useTakafulPoolData(BTC_POOL_ID)
  const { member } = useMemberData(BTC_POOL_ID, address)

  // Credit
  const { ids } = useProtectionList()
  const { protections } = useProtections(ids)
  const myProtections = address
    ? protections.filter(p =>
        p.seller.toLowerCase() === address.toLowerCase() ||
        p.buyer.toLowerCase() === address.toLowerCase()
      )
    : []
  const activeProtections = myProtections.filter(p => p.status === 1) // Active

  if (!address) {
    return (
      <div style={{ ...PANEL, textAlign: 'center', padding: '40px 20px' }}>
        <p style={{ color: 'var(--text-muted)', fontSize: '14px', marginBottom: '8px' }}>
          Connect your wallet to view your portfolio.
        </p>
        <p style={{ fontSize: '12px', color: 'var(--text-muted)' }}>
          Your positions across all Baraka Protocol layers will appear here.
        </p>
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '24px' }}>

      {/* Top stats */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: '16px' }}>
        <StatCard
          label="BRKX Fee Tier"
          value={tier.tierName}
          sub={`${tier.feeLabel} per trade`}
          color={tier.tierIndex === 0 ? 'var(--gold)' : tier.tierIndex === 1 ? 'var(--green-lite)' : 'var(--text-main)'}
        />
        <StatCard
          label="Open Positions"
          value={String(positions.length)}
          sub={`BTC Mark: ${markDisplay}`}
        />
        <StatCard
          label="Sukuk Subscriptions"
          value={String(sukukPositions.length)}
          sub={PRODUCT_CONTRACTS.PerpetualSukuk ? 'Layer 2 active' : 'Deploying...'}
        />
        <StatCard
          label="Takaful Coverage"
          value={member && member.totalCoverage > 0n ? fmtUSDC(member.totalCoverage) + ' USDC' : '—'}
          sub={PRODUCT_CONTRACTS.TakafulPool ? 'BTC floor pool' : 'Deploying...'}
        />
        <StatCard
          label="Credit Protections"
          value={String(activeProtections.length)}
          sub="Active iCDS"
          color={activeProtections.length > 0 ? 'var(--green-lite)' : 'var(--text-muted)'}
        />
      </div>

      {/* Perpetual Positions */}
      <div style={PANEL}>
        <SectionHeader title="Perpetual Positions" link="/trade" linkLabel="Open Trade" />
        {positions.length === 0 ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            No open positions. <Link href="/trade" style={{ color: 'var(--green-lite)' }}>Open a trade</Link>.
          </p>
        ) : (
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '12px' }}>
              <thead>
                <tr style={{ borderBottom: '1px solid var(--border)', color: 'var(--text-muted)', textAlign: 'left' }}>
                  {['Side', 'Size', 'Entry', 'Current', 'PnL'].map(h => (
                    <th key={h} style={{ padding: '6px 8px', fontWeight: 500 }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {positions.map(pos => (
                  <tr key={pos.positionId} style={{ borderBottom: '1px solid var(--border)', color: 'var(--text-main)' }}>
                    <td style={{ padding: '8px', color: pos.isLong ? 'var(--green-lite)' : '#e76f51', fontWeight: 600 }}>
                      {pos.isLong ? 'LONG' : 'SHORT'}
                    </td>
                    <td style={{ padding: '8px' }}>{(Number(pos.size) / 1e6).toFixed(2)}</td>
                    <td style={{ padding: '8px' }}>${(Number(pos.entryPrice) / WAD).toLocaleString()}</td>
                    <td style={{ padding: '8px' }}>{markDisplay}</td>
                    <td style={{ padding: '8px', color: pos.unrealisedPnl >= 0n ? 'var(--green-lite)' : '#e76f51' }}>
                      {pos.unrealisedPnl >= 0n ? '+' : ''}{(Number(pos.unrealisedPnl) / 1e6).toFixed(2)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* BRKX Tier */}
      <div style={PANEL}>
        <SectionHeader title="BRKX Fee Tier" link="/trade" linkLabel="Trade" />
        <div style={{ display: 'flex', gap: '20px', flexWrap: 'wrap', alignItems: 'center' }}>
          <div>
            <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Current Tier</div>
            <div style={{
              display: 'inline-block',
              background: 'rgba(212,175,55,0.15)',
              color: 'var(--gold)',
              borderRadius: '6px',
              padding: '4px 14px',
              fontSize: '14px',
              fontWeight: 700,
            }}>
              {tier.tierName}
            </div>
          </div>
          <div>
            <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Fee Rate</div>
            <div style={{ fontSize: '1.2rem', fontWeight: 700, color: 'var(--text-main)' }}>{tier.feeLabel}</div>
          </div>
          <div>
            <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>BRKX Held</div>
            <div style={{ fontSize: '1rem', color: 'var(--text-main)' }}>{tier.balanceDisplay}</div>
          </div>
          {tier.nextTierBrkx !== null && tier.nextTierBrkx > 0n && (
            <div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Next Tier Requires</div>
              <div style={{ fontSize: '12px', color: 'var(--green-lite)' }}>
                {(Number(tier.nextTierBrkx) / WAD).toLocaleString()} BRKX
              </div>
            </div>
          )}
        </div>
      </div>

      {/* Sukuk Summary */}
      <div style={PANEL}>
        <SectionHeader title="Sukuk Subscriptions" link="/sukuk" linkLabel="View Sukuks" />
        {!PRODUCT_CONTRACTS.PerpetualSukuk ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Deploying...</p>
        ) : sukukPositions.length === 0 ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            No sukuk subscriptions. <Link href="/sukuk" style={{ color: 'var(--green-lite)' }}>Browse sukuks</Link>.
          </p>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            {sukukPositions.map(pos => (
              <div key={pos.id} style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 14px',
                background: 'var(--bg-card)',
                border: '1px solid var(--border)',
                borderRadius: '8px',
                fontSize: '13px',
                color: 'var(--text-main)',
              }}>
                <span>Sukuk #{pos.id}</span>
                <span>{fmtUSDC(pos.amount)} USDC subscribed</span>
                <span style={{ color: 'var(--green-lite)' }}>+{fmtUSDC(pos.accrued)} accrued</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Takaful Summary */}
      <div style={PANEL}>
        <SectionHeader title="Takaful Coverage" link="/takaful" linkLabel="View Pool" />
        {!PRODUCT_CONTRACTS.TakafulPool ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Deploying...</p>
        ) : !member || member.totalCoverage === 0n ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            Not a member. <Link href="/takaful" style={{ color: 'var(--green-lite)' }}>Contribute tabarru</Link>.
          </p>
        ) : (
          <div style={{ display: 'flex', gap: '24px', flexWrap: 'wrap' }}>
            <div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>My Coverage</div>
              <div style={{ fontSize: '1.1rem', fontWeight: 600, color: 'var(--text-main)' }}>
                {fmtUSDC(member.totalCoverage)} USDC
              </div>
            </div>
            <div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Tabarru Donated</div>
              <div style={{ fontSize: '1.1rem', fontWeight: 600, color: 'var(--gold)' }}>
                {fmtUSDC(member.totalTabarru)} USDC
              </div>
            </div>
            {pool && (
              <div>
                <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Pool Balance</div>
                <div style={{ fontSize: '1.1rem', fontWeight: 600, color: 'var(--green-lite)' }}>
                  {fmtUSDC(pool.balance)} USDC
                </div>
              </div>
            )}
          </div>
        )}
      </div>

      {/* Credit Protections Summary */}
      <div style={PANEL}>
        <SectionHeader title="Credit Protections (iCDS)" link="/credit" linkLabel="Manage" />
        {!PRODUCT_CONTRACTS.iCDS ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Deploying...</p>
        ) : myProtections.length === 0 ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            No protections. <Link href="/credit" style={{ color: 'var(--green-lite)' }}>Open or buy protection</Link>.
          </p>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
            {myProtections.slice(0, 5).map(p => (
              <div key={p.id} style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 14px',
                background: 'var(--bg-card)',
                border: '1px solid var(--border)',
                borderRadius: '8px',
                fontSize: '12px',
                color: 'var(--text-main)',
                flexWrap: 'wrap',
                gap: '8px',
              }}>
                <span>Protection #{p.id}</span>
                <span>{fmtUSDC(p.notional)} USDC notional</span>
                <span>
                  {p.seller.toLowerCase() === address.toLowerCase() ? 'Seller' : 'Buyer'}
                </span>
                <span style={{ color: p.statusLabel === 'Active' ? 'var(--green-lite)' : p.statusLabel === 'Triggered' ? '#e76f51' : 'var(--text-muted)', fontWeight: 600 }}>
                  {p.statusLabel}
                </span>
              </div>
            ))}
          </div>
        )}
      </div>

    </div>
  )
}
