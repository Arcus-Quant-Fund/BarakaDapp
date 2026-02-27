import FundingRateDisplay from '@/components/FundingRateDisplay'
import OrderPanel from '@/components/OrderPanel'
import PriceChart from '@/components/PriceChart'
import ShariahPanel from '@/components/ShariahPanel'
import DepositPanel from '@/components/DepositPanel'
import PositionTable from '@/components/PositionTable'

export const metadata = {
  title: 'Trade BTC-PERP | Baraka Protocol',
}

export default function TradePage() {
  return (
    <main style={{ minHeight: 'calc(100vh - 56px)', padding: '16px' }}>
      <div className="max-w-7xl mx-auto" style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>

        {/* Top bar */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '12px', flexWrap: 'wrap' }}>
          <span style={{ fontSize: '1.1rem', fontWeight: 700, color: 'var(--text-main)' }}>
            BTC-PERP
          </span>
          <span
            style={{
              fontSize: '11px',
              color: 'var(--text-muted)',
              background: 'var(--bg-card)',
              padding: '2px 8px',
              borderRadius: '4px',
              border: '1px solid var(--border)',
            }}
          >
            Perpetual · USDC margin · Arb Sepolia
          </span>
        </div>

        {/* Funding rate bar */}
        <FundingRateDisplay />

        {/* Main layout: chart + right panel */}
        <div className="trade-grid" style={{ display: 'grid', gridTemplateColumns: '1fr 320px', gap: '12px', alignItems: 'start' }}>

          {/* Left: chart + shariah proof + position table */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            <PriceChart />
            <PositionTable />
            <ShariahPanel />
          </div>

          {/* Right: order panel + deposit panel */}
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            <OrderPanel />
            <DepositPanel />
          </div>
        </div>
      </div>
    </main>
  )
}
