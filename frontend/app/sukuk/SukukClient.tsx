'use client'

import { useState, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import {
  useSukukCount,
  useSukukList,
  useUserSukukPositions,
  useSukukWrite,
} from '@/hooks/useSukukData'
import { PRODUCT_CONTRACTS, PERPETUAL_SUKUK_ABI, USDC_ADDRESS, ERC20_ABI } from '@/lib/contracts'

const WAD = 1e18
const PANEL = {
  background: 'var(--bg-panel)',
  border: '1px solid var(--border)',
  borderRadius: '12px',
  padding: '20px',
} as const

function fmtUSDC(raw: bigint) {
  return (Number(raw) / 1e6).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

function fmtDate(epoch: bigint) {
  return new Date(Number(epoch) * 1000).toLocaleDateString()
}

function fmtPct(wad: bigint) {
  return ((Number(wad) / WAD) * 100).toFixed(2) + '%'
}

function StatusBadge({ maturity, redeemed }: { maturity: bigint; redeemed: boolean }) {
  const now = BigInt(Math.floor(Date.now() / 1000))
  if (redeemed) return <span style={{ color: 'var(--text-muted)', fontSize: '11px' }}>Redeemed</span>
  if (now >= maturity) return <span style={{ color: '#e76f51', fontSize: '11px' }}>Matured</span>
  return <span style={{ color: 'var(--green-lite)', fontSize: '11px' }}>Active</span>
}

export default function SukukClient() {
  const { address } = useAccount()
  const { count, isLoading: countLoading } = useSukukCount()
  const { sukuks, isLoading: listLoading } = useSukukList(count)
  const { positions, isLoading: posLoading } = useUserSukukPositions(
    sukuks.map(s => s.id),
    address,
  )
  const { claimProfit, redeem, isClaimPending, isRedeemPending, claimSuccess, redeemSuccess } = useSukukWrite()

  const [subscribeId, setSubscribeId] = useState('')
  const [subscribeAmt, setSubscribeAmt] = useState('')
  const [approveStep, setApproveStep] = useState<'idle' | 'approving' | 'subscribing'>('idle')

  const { writeContract: writeApprove, data: approveTx, isPending: isApprovePending } = useWriteContract()
  const { writeContract: writeSubscribe, data: subscribeTx, isPending: isSubPending } = useWriteContract()
  const { isLoading: isApproveConfirming, isSuccess: approveSuccess } =
    useWaitForTransactionReceipt({ hash: approveTx })
  const { isLoading: isSubConfirming, isSuccess: subSuccess } =
    useWaitForTransactionReceipt({ hash: subscribeTx })

  useEffect(() => {
    if (approveSuccess && approveStep === 'approving') {
      setApproveStep('subscribing')
      const id = BigInt(subscribeId)
      const amt = BigInt(Math.round(parseFloat(subscribeAmt) * 1e6))
      writeSubscribe({
        address: PRODUCT_CONTRACTS.PerpetualSukuk,
        abi: PERPETUAL_SUKUK_ABI,
        functionName: 'subscribe',
        args: [id, amt],
      })
    }
  }, [approveSuccess, approveStep])

  useEffect(() => {
    if (subSuccess) {
      setApproveStep('idle')
      setSubscribeId('')
      setSubscribeAmt('')
    }
  }, [subSuccess])

  const handleSubscribe = () => {
    if (!address || !subscribeId || !subscribeAmt || !PRODUCT_CONTRACTS.PerpetualSukuk) return
    const amt = BigInt(Math.round(parseFloat(subscribeAmt) * 1e6))
    setApproveStep('approving')
    writeApprove({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [PRODUCT_CONTRACTS.PerpetualSukuk, amt],
    })
  }

  const isBusy = isApprovePending || isApproveConfirming || isSubPending || isSubConfirming

  if (!PRODUCT_CONTRACTS.PerpetualSukuk) {
    return (
      <div style={{ ...PANEL, textAlign: 'center', color: 'var(--text-muted)' }}>
        <p style={{ marginBottom: '8px' }}>Contracts deploying to testnet...</p>
        <p style={{ fontSize: '12px' }}>Check back shortly.</p>
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>

      {/* Active Sukuk List */}
      <div style={PANEL}>
        <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
          Active Sukuks
        </h2>
        {countLoading || listLoading ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Loading...</p>
        ) : sukuks.length === 0 ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>
            No active sukuks. Issue the first one on-chain.
          </p>
        ) : (
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: '13px' }}>
              <thead>
                <tr style={{ borderBottom: '1px solid var(--border)', color: 'var(--text-muted)', textAlign: 'left' }}>
                  {['ID', 'Par Value', 'Profit Rate', 'Maturity', 'Subscribed', 'Status'].map(h => (
                    <th key={h} style={{ padding: '6px 8px', fontWeight: 500 }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {sukuks.map(s => (
                  <tr key={s.id} style={{ borderBottom: '1px solid var(--border)', color: 'var(--text-main)' }}>
                    <td style={{ padding: '8px' }}>#{s.id}</td>
                    <td style={{ padding: '8px' }}>{fmtUSDC(s.parValue)} USDC</td>
                    <td style={{ padding: '8px', color: 'var(--green-lite)' }}>{fmtPct(s.profitRateWad)} / yr</td>
                    <td style={{ padding: '8px' }}>{fmtDate(s.maturityEpoch)}</td>
                    <td style={{ padding: '8px' }}>{fmtUSDC(s.totalSubscribed)} / {fmtUSDC(s.parValue)}</td>
                    <td style={{ padding: '8px' }}><StatusBadge maturity={s.maturityEpoch} redeemed={s.redeemed} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Subscribe Panel */}
      <div style={PANEL}>
        <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
          Subscribe to Sukuk
        </h2>
        {!address ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Connect wallet to subscribe.</p>
        ) : (
          <div style={{ display: 'flex', gap: '12px', flexWrap: 'wrap', alignItems: 'flex-end' }}>
            <div>
              <label style={{ fontSize: '12px', color: 'var(--text-muted)', display: 'block', marginBottom: '4px' }}>
                Sukuk ID
              </label>
              <input
                type="number"
                min="0"
                value={subscribeId}
                onChange={e => setSubscribeId(e.target.value)}
                placeholder="0"
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
            <div>
              <label style={{ fontSize: '12px', color: 'var(--text-muted)', display: 'block', marginBottom: '4px' }}>
                Amount (USDC)
              </label>
              <input
                type="number"
                min="0"
                value={subscribeAmt}
                onChange={e => setSubscribeAmt(e.target.value)}
                placeholder="100.00"
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
            <button
              onClick={handleSubscribe}
              disabled={isBusy || !subscribeId || !subscribeAmt}
              style={{
                background: isBusy ? 'var(--border)' : 'var(--green-deep)',
                color: 'var(--green-lite)',
                border: 'none',
                borderRadius: '8px',
                padding: '8px 20px',
                fontSize: '13px',
                fontWeight: 600,
                cursor: isBusy ? 'not-allowed' : 'pointer',
              }}
            >
              {isApprovePending || isApproveConfirming ? 'Approving...'
                : isSubPending || isSubConfirming ? 'Subscribing...'
                : 'Subscribe'}
            </button>
          </div>
        )}
        {subSuccess && (
          <p style={{ color: 'var(--green-lite)', fontSize: '12px', marginTop: '8px' }}>
            Subscribed successfully!
          </p>
        )}
        <p style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '12px' }}>
          Ijarah-style: your USDC is deployed and earns periodic profit at the stated rate. At maturity you receive principal + embedded call upside (ι=0, no riba).
        </p>
      </div>

      {/* My Portfolio */}
      {address && (
        <div style={PANEL}>
          <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
            My Sukuk Portfolio
          </h2>
          {posLoading ? (
            <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Loading positions...</p>
          ) : positions.length === 0 ? (
            <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>No active subscriptions.</p>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
              {positions.map(pos => {
                const now = BigInt(Math.floor(Date.now() / 1000))
                const sukuk = sukuks.find(s => s.id === pos.id)
                const isMatured = sukuk && now >= sukuk.maturityEpoch
                return (
                  <div key={pos.id} style={{
                    background: 'var(--bg-card)',
                    border: '1px solid var(--border)',
                    borderRadius: '8px',
                    padding: '14px',
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    flexWrap: 'wrap',
                    gap: '10px',
                  }}>
                    <div>
                      <div style={{ fontSize: '13px', color: 'var(--text-main)', fontWeight: 600 }}>
                        Sukuk #{pos.id}
                      </div>
                      <div style={{ fontSize: '12px', color: 'var(--text-muted)', marginTop: '2px' }}>
                        Subscribed: {fmtUSDC(pos.amount)} USDC
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: '16px', alignItems: 'center' }}>
                      <div style={{ textAlign: 'right' }}>
                        <div style={{ fontSize: '12px', color: 'var(--text-muted)' }}>Accrued Profit</div>
                        <div style={{ fontSize: '13px', color: 'var(--green-lite)' }}>
                          +{fmtUSDC(pos.accrued)} USDC
                        </div>
                      </div>
                      {!isMatured && pos.accrued > 0n && (
                        <button
                          onClick={() => claimProfit(BigInt(pos.id))}
                          disabled={isClaimPending}
                          style={{
                            background: 'var(--green-deep)',
                            color: 'var(--green-lite)',
                            border: 'none',
                            borderRadius: '6px',
                            padding: '6px 14px',
                            fontSize: '12px',
                            cursor: isClaimPending ? 'not-allowed' : 'pointer',
                          }}
                        >
                          {isClaimPending ? 'Claiming...' : 'Claim Profit'}
                        </button>
                      )}
                      {isMatured && (
                        <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                          <div style={{ fontSize: '12px', color: 'var(--text-muted)' }}>
                            Call upside: +{fmtUSDC(pos.callUpside)} USDC
                          </div>
                          <button
                            onClick={() => redeem(BigInt(pos.id))}
                            disabled={isRedeemPending}
                            style={{
                              background: 'var(--gold)',
                              color: '#0a0f0d',
                              border: 'none',
                              borderRadius: '6px',
                              padding: '6px 14px',
                              fontSize: '12px',
                              fontWeight: 600,
                              cursor: isRedeemPending ? 'not-allowed' : 'pointer',
                            }}
                          >
                            {isRedeemPending ? 'Redeeming...' : 'Redeem'}
                          </button>
                        </div>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      )}

      {/* Shariah Note */}
      <div style={{
        ...PANEL,
        background: '#162019',
        borderColor: 'var(--green-deep)',
      }}>
        <h3 style={{ fontSize: '12px', fontWeight: 600, color: 'var(--green-lite)', marginBottom: '8px' }}>
          Shariah Compliance — AAOIFI Standard 17
        </h3>
        <div style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.6 }}>
          Sukuk represent undivided ownership in a deployed asset pool, NOT interest-bearing debt.
          Profit = ijarah rent (proportional to deployment time and rate).
          Embedded call = mudarabah participation in asset appreciation above par.
          Interest parameter ι=0 throughout — no riba enters the pricing.
        </div>
      </div>

    </div>
  )
}
