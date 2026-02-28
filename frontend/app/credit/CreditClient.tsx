'use client'

import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import {
  useProtectionList,
  useProtections,
  useCreditWrite,
  CDS_STATUS,
} from '@/hooks/useCreditData'
import { PRODUCT_CONTRACTS, ICDS_ABI, USDC_ADDRESS, BTC_ASSET_ADDRESS, ERC20_ABI } from '@/lib/contracts'

const WAD = 1e18
const PANEL = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border)',
  borderRadius: '12px',
  padding: '20px',
} as const

const STATUS_COLORS: Record<string, string> = {
  Open:      'var(--gold)',
  Active:    'var(--green-lite)',
  Triggered: '#e76f51',
  Settled:   'var(--text-muted)',
  Expired:   'var(--text-muted)',
}

function fmtUSDC(raw: bigint) {
  return (Number(raw) / 1e6).toLocaleString(undefined, { maximumFractionDigits: 2 })
}

function fmtPct(wad: bigint) {
  return ((Number(wad) / WAD) * 100).toFixed(1) + '%'
}

function fmtDate(epoch: bigint) {
  return new Date(Number(epoch) * 1000).toLocaleDateString()
}

function nextPremiumDue(lastPremiumAt: bigint): string {
  const next = lastPremiumAt + BigInt(90 * 24 * 3600) // 90 days
  const now = BigInt(Math.floor(Date.now() / 1000))
  if (next <= now) return 'Due now'
  const daysLeft = Number(next - now) / (24 * 3600)
  return `In ${Math.ceil(daysLeft)} days`
}

export default function CreditClient() {
  const { address } = useAccount()
  const { ids, isLoadingIds } = useProtectionList()
  const { protections, isLoading: protLoading } = useProtections(ids)
  const {
    openProtection, acceptProtection, payPremium, settle, expire,
    isOpenPending, isAcceptPending, isPremiumPending, isSettlePending, isExpirePending,
    isOpenConfirming, isAcceptConfirming,
    openSuccess,
  } = useCreditWrite()

  // Open Protection form
  const [notionalInput, setNotionalInput]   = useState('')
  const [recoveryInput, setRecoveryInput]   = useState('40')
  const [tenorInput, setTenorInput]         = useState('365')
  const [approveStep, setApproveStep]       = useState<'idle' | 'approving' | 'opening'>('idle')

  const { writeContract: writeApprove, data: approveTx, isPending: isApprovePending } = useWriteContract()
  const { isLoading: isApproveConfirming, isSuccess: approveSuccess } =
    useWaitForTransactionReceipt({ hash: approveTx })

  // Watch for approval and then open
  const handleOpen = () => {
    if (!address || !notionalInput || !PRODUCT_CONTRACTS.iCDS) return
    const notional = BigInt(Math.round(parseFloat(notionalInput) * 1e6))
    setApproveStep('approving')
    writeApprove({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [PRODUCT_CONTRACTS.iCDS, notional],
    })
  }

  // After approve success, call openProtection
  // (Using a ref or state to track pending open)
  const [pendingOpen, setPendingOpen] = useState(false)
  if (approveSuccess && approveStep === 'approving' && !pendingOpen) {
    setPendingOpen(true)
    setApproveStep('opening')
    const notional       = BigInt(Math.round(parseFloat(notionalInput) * 1e6))
    const recoveryRateWad = BigInt(Math.round(parseFloat(recoveryInput) * 1e16))
    const tenorDays       = BigInt(parseInt(tenorInput))
    openProtection(BTC_ASSET_ADDRESS, USDC_ADDRESS, notional, recoveryRateWad, tenorDays)
  }

  if (openSuccess && pendingOpen) {
    setPendingOpen(false)
    setApproveStep('idle')
    setNotionalInput('')
  }

  const isBusy = isApprovePending || isApproveConfirming || isOpenPending || isOpenConfirming

  const myProtections = address
    ? protections.filter(p => p.seller.toLowerCase() === address.toLowerCase() || p.buyer.toLowerCase() === address.toLowerCase())
    : []

  if (!PRODUCT_CONTRACTS.iCDS) {
    return (
      <div style={{ ...PANEL, textAlign: 'center', color: 'var(--text-muted)' }}>
        <p style={{ marginBottom: '8px' }}>Contracts deploying to testnet...</p>
        <p style={{ fontSize: '12px' }}>Check back shortly.</p>
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>

      {/* All Protections */}
      <div style={PANEL}>
        <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
          All Protections
        </h2>
        {isLoadingIds || protLoading ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Loading...</p>
        ) : protections.length === 0 ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            No protections opened yet. Be the first seller.
          </p>
        ) : (
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '12px' }}>
              <thead>
                <tr style={{ borderBottom: '1px solid var(--border)', color: 'var(--text-muted)', textAlign: 'left' }}>
                  {['ID', 'Notional', 'Recovery', 'Floor', 'Tenor End', 'Current Premium', 'Status'].map(h => (
                    <th key={h} style={{ padding: '6px 8px', fontWeight: 500 }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {protections.map(p => (
                  <tr key={p.id} style={{ borderBottom: '1px solid var(--border)', color: 'var(--text-main)' }}>
                    <td style={{ padding: '8px' }}>#{p.id}</td>
                    <td style={{ padding: '8px' }}>{fmtUSDC(p.notional)} USDC</td>
                    <td style={{ padding: '8px' }}>{fmtPct(p.recoveryRateWad)}</td>
                    <td style={{ padding: '8px' }}>${(Number(p.recoveryFloorWad) / WAD).toLocaleString(undefined, { maximumFractionDigits: 0 })}</td>
                    <td style={{ padding: '8px' }}>{fmtDate(p.tenorEnd)}</td>
                    <td style={{ padding: '8px', color: 'var(--gold)' }}>{fmtUSDC(p.currentPremium)} USDC</td>
                    <td style={{ padding: '8px' }}>
                      <span style={{ color: STATUS_COLORS[p.statusLabel] ?? 'var(--text-muted)', fontWeight: 600 }}>
                        {p.statusLabel}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Open Protection (Seller) */}
      <div style={PANEL}>
        <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '4px' }}>
          Open Protection (Seller)
        </h2>
        <p style={{ fontSize: '12px', color: 'var(--text-muted)', marginBottom: '16px' }}>
          Deposit full notional as collateral. Earn quarterly premiums from the buyer.
        </p>
        {!address ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Connect wallet to open protection.</p>
        ) : (
          <div style={{ display: 'flex', gap: '12px', flexWrap: 'wrap', alignItems: 'flex-end' }}>
            <div>
              <label style={{ fontSize: '12px', color: 'var(--text-muted)', display: 'block', marginBottom: '4px' }}>
                Notional (USDC)
              </label>
              <input
                type="number"
                min="0"
                value={notionalInput}
                onChange={e => setNotionalInput(e.target.value)}
                placeholder="1000.00"
                style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '8px',
                  padding: '8px 12px',
                  color: 'var(--text-main)',
                  fontSize: '13px',
                  width: '140px',
                }}
              />
            </div>
            <div>
              <label style={{ fontSize: '12px', color: 'var(--text-muted)', display: 'block', marginBottom: '4px' }}>
                Recovery % (0–99)
              </label>
              <input
                type="number"
                min="1"
                max="99"
                value={recoveryInput}
                onChange={e => setRecoveryInput(e.target.value)}
                style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '8px',
                  padding: '8px 12px',
                  color: 'var(--text-main)',
                  fontSize: '13px',
                  width: '90px',
                }}
              />
            </div>
            <div>
              <label style={{ fontSize: '12px', color: 'var(--text-muted)', display: 'block', marginBottom: '4px' }}>
                Tenor (days)
              </label>
              <input
                type="number"
                min="1"
                max="3650"
                value={tenorInput}
                onChange={e => setTenorInput(e.target.value)}
                style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '8px',
                  padding: '8px 12px',
                  color: 'var(--text-main)',
                  fontSize: '13px',
                  width: '100px',
                }}
              />
            </div>
            <button
              onClick={handleOpen}
              disabled={isBusy || !notionalInput}
              style={{
                background: isBusy ? 'var(--border)' : '#e76f51',
                color: '#fff',
                border: 'none',
                borderRadius: '8px',
                padding: '8px 20px',
                fontSize: '13px',
                fontWeight: 600,
                cursor: isBusy ? 'not-allowed' : 'pointer',
              }}
            >
              {isApprovePending || isApproveConfirming ? 'Approving...'
                : isOpenPending || isOpenConfirming ? 'Opening...'
                : 'Open Protection'}
            </button>
          </div>
        )}
      </div>

      {/* My Protections */}
      {address && myProtections.length > 0 && (
        <div style={PANEL}>
          <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
            My Protections
          </h2>
          <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
            {myProtections.map(p => {
              const isSeller = p.seller.toLowerCase() === address.toLowerCase()
              const isBuyer  = p.buyer.toLowerCase() === address.toLowerCase()
              const now = BigInt(Math.floor(Date.now() / 1000))
              const isExpired = now >= p.tenorEnd
              const premiumDue = p.status === 1 && isBuyer
                ? now >= p.lastPremiumAt + BigInt(90 * 24 * 3600)
                : false

              return (
                <div key={p.id} style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '8px',
                  padding: '14px',
                }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: '10px' }}>
                    <div>
                      <div style={{ fontSize: '13px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '4px' }}>
                        Protection #{p.id}
                        <span style={{ marginLeft: '8px', color: STATUS_COLORS[p.statusLabel], fontSize: '12px' }}>
                          {p.statusLabel}
                        </span>
                        <span style={{ marginLeft: '8px', color: 'var(--text-muted)', fontSize: '12px' }}>
                          {isSeller ? '(Seller)' : '(Buyer)'}
                        </span>
                      </div>
                      <div style={{ fontSize: '12px', color: 'var(--text-muted)' }}>
                        Notional: {fmtUSDC(p.notional)} USDC | Recovery: {fmtPct(p.recoveryRateWad)} | Tenor ends: {fmtDate(p.tenorEnd)}
                      </div>
                      <div style={{ fontSize: '12px', color: 'var(--text-muted)', marginTop: '2px' }}>
                        Premiums collected: {fmtUSDC(p.premiumsCollected)} USDC
                        {p.status === 1 && ' | Next: ' + nextPremiumDue(p.lastPremiumAt)}
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
                      {/* Buyer: accept if open */}
                      {isBuyer && p.status === 0 && (
                        <button
                          onClick={() => acceptProtection(BigInt(p.id))}
                          disabled={isAcceptPending || isAcceptConfirming}
                          style={{ background: 'var(--green-deep)', color: 'var(--green-lite)', border: 'none', borderRadius: '6px', padding: '6px 14px', fontSize: '12px', cursor: 'pointer' }}
                        >
                          Accept
                        </button>
                      )}
                      {/* Buyer: pay premium if due */}
                      {isBuyer && premiumDue && (
                        <button
                          onClick={() => payPremium(BigInt(p.id))}
                          disabled={isPremiumPending}
                          style={{ background: 'var(--gold)', color: '#0a0f0d', border: 'none', borderRadius: '6px', padding: '6px 14px', fontSize: '12px', fontWeight: 600, cursor: 'pointer' }}
                        >
                          Pay Premium
                        </button>
                      )}
                      {/* Buyer: settle after credit event */}
                      {isBuyer && p.status === 2 && (
                        <button
                          onClick={() => settle(BigInt(p.id))}
                          disabled={isSettlePending}
                          style={{ background: '#e76f51', color: '#fff', border: 'none', borderRadius: '6px', padding: '6px 14px', fontSize: '12px', fontWeight: 600, cursor: 'pointer' }}
                        >
                          Settle
                        </button>
                      )}
                      {/* Seller: expire after tenor */}
                      {isSeller && (p.status === 0 || p.status === 1) && isExpired && (
                        <button
                          onClick={() => expire(BigInt(p.id))}
                          disabled={isExpirePending}
                          style={{ background: 'var(--border)', color: 'var(--text-muted)', border: 'none', borderRadius: '6px', padding: '6px 14px', fontSize: '12px', cursor: 'pointer' }}
                        >
                          Expire & Reclaim
                        </button>
                      )}
                    </div>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      )}

      {/* Shariah Note */}
      <div style={{ ...PANEL, background: '#162019', borderColor: 'var(--green-deep)' }}>
        <h3 style={{ fontSize: '12px', fontWeight: 600, color: 'var(--green-lite)', marginBottom: '8px' }}>
          Shariah Compliance — Paper 2 Framework
        </h3>
        <div style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.6 }}>
          <strong style={{ color: 'var(--text-main)' }}>Maysir eliminated</strong>: Seller deposits full notional collateral — no naked bet.
          <br />
          <strong style={{ color: 'var(--text-main)' }}>Gharar eliminated</strong>: Credit event = on-chain oracle condition (spot ≤ floor), not committee-defined.
          <br />
          <strong style={{ color: 'var(--text-main)' }}>Riba eliminated</strong>: Premium = Π_put(spot, recoveryFloor) × notional / WAD at ι=0. Dynamic, not fixed rate.
        </div>
      </div>

    </div>
  )
}
