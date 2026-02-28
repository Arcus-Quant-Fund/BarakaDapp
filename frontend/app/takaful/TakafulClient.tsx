'use client'

import { useState, useEffect } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import {
  useTakafulPoolData,
  useMemberData,
  useTabarruPreview,
  useTakafulWrite,
  BTC_POOL_ID,
} from '@/hooks/useTakafulData'
import { PRODUCT_CONTRACTS, TAKAFUL_POOL_ABI, USDC_ADDRESS, ERC20_ABI } from '@/lib/contracts'

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

function fmtUSD(wad: bigint) {
  return '$' + (Number(wad) / WAD).toLocaleString(undefined, { maximumFractionDigits: 0 })
}

function fmtPct(wad: bigint) {
  return ((Number(wad) / WAD) * 100).toFixed(4) + '%'
}

export default function TakafulClient() {
  const { address } = useAccount()
  const { pool, isLoading: poolLoading } = useTakafulPoolData(BTC_POOL_ID)
  const { member } = useMemberData(BTC_POOL_ID, address)

  const [coverageInput, setCoverageInput] = useState('')
  const coverageAmt = coverageInput ? BigInt(Math.round(parseFloat(coverageInput) * 1e6)) : 0n
  const { tabarruGross, spotWad, putRateWad } = useTabarruPreview(BTC_POOL_ID, coverageAmt)

  const [approveStep, setApproveStep] = useState<'idle' | 'approving' | 'contributing'>('idle')
  const { contribute, isPending: isContributing, isConfirming: isContribConfirming, isSuccess: contribSuccess } = useTakafulWrite()

  const { writeContract: writeApprove, data: approveTx, isPending: isApprovePending } = useWriteContract()
  const { isLoading: isApproveConfirming, isSuccess: approveSuccess } =
    useWaitForTransactionReceipt({ hash: approveTx })

  useEffect(() => {
    if (approveSuccess && approveStep === 'approving') {
      setApproveStep('contributing')
      contribute(BTC_POOL_ID, coverageAmt)
    }
  }, [approveSuccess, approveStep])

  useEffect(() => {
    if (contribSuccess) {
      setApproveStep('idle')
      setCoverageInput('')
    }
  }, [contribSuccess])

  const handleContribute = () => {
    if (!address || coverageAmt === 0n || !PRODUCT_CONTRACTS.TakafulPool) return
    setApproveStep('approving')
    writeApprove({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [PRODUCT_CONTRACTS.TakafulPool, tabarruGross],
    })
  }

  const isBusy = isApprovePending || isApproveConfirming || isContributing || isContribConfirming
  const isFloorBreached = pool && pool.spotWad > 0n && pool.spotWad < pool.floorWad
  const isDeployed = !!PRODUCT_CONTRACTS.TakafulPool

  if (!isDeployed) {
    return (
      <div style={{ ...PANEL, textAlign: 'center', color: 'var(--text-muted)' }}>
        <p style={{ marginBottom: '8px' }}>Contracts deploying to testnet...</p>
        <p style={{ fontSize: '12px' }}>Check back shortly.</p>
      </div>
    )
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '20px' }}>

      {/* Pool Status Card */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '16px' }}>
        {poolLoading ? (
          <div style={{ ...PANEL, color: 'var(--text-muted)', fontSize: '13px' }}>Loading pool data...</div>
        ) : !pool ? (
          <div style={{ ...PANEL, color: 'var(--text-muted)', fontSize: '13px' }}>Pool not found.</div>
        ) : (
          <>
            <div style={PANEL}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '6px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                Pool Balance
              </div>
              <div style={{ fontSize: '1.4rem', fontWeight: 700, color: 'var(--text-main)' }}>
                {fmtUSDC(pool.balance)} <span style={{ fontSize: '14px', color: 'var(--text-muted)' }}>USDC</span>
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '4px' }}>
                Claims paid: {fmtUSDC(pool.totalClaimsPaid)} USDC
              </div>
            </div>

            <div style={PANEL}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '6px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                BTC Spot vs Floor
              </div>
              <div style={{ fontSize: '1.4rem', fontWeight: 700, color: isFloorBreached ? '#e76f51' : 'var(--green-lite)' }}>
                {fmtUSD(pool.spotWad)}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '4px' }}>
                Floor: {fmtUSD(pool.floorWad)} {isFloorBreached && (
                  <span style={{ color: '#e76f51', fontWeight: 600 }}>— BREACHED</span>
                )}
              </div>
            </div>

            <div style={PANEL}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '6px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                Put Rate (tabarruRate)
              </div>
              <div style={{ fontSize: '1.4rem', fontWeight: 700, color: 'var(--gold)' }}>
                {putRateWad > 0n ? fmtPct(putRateWad) : '—'}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '4px' }}>
                Π_put(spot, floor) — ι=0
              </div>
            </div>

            <div style={PANEL}>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '6px', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
                Pool Status
              </div>
              <div style={{
                display: 'inline-block',
                background: pool.active ? 'rgba(82,183,136,0.15)' : 'rgba(231,111,81,0.15)',
                color: pool.active ? 'var(--green-lite)' : '#e76f51',
                borderRadius: '6px',
                padding: '4px 12px',
                fontSize: '14px',
                fontWeight: 600,
              }}>
                {pool.active ? 'Active' : 'Inactive'}
              </div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginTop: '8px' }}>
                BTC floor protection pool
              </div>
            </div>
          </>
        )}
      </div>

      {/* Contribute Panel */}
      <div style={PANEL}>
        <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
          Contribute Tabarru
        </h2>
        {!address ? (
          <p style={{ color: 'var(--text-muted)', fontSize: '13px' }}>Connect wallet to contribute.</p>
        ) : (
          <div style={{ display: 'flex', gap: '16px', flexWrap: 'wrap', alignItems: 'flex-start' }}>
            <div style={{ flex: 1, minWidth: '200px' }}>
              <label style={{ fontSize: '12px', color: 'var(--text-muted)', display: 'block', marginBottom: '4px' }}>
                Coverage Amount (USDC)
              </label>
              <input
                type="number"
                min="0"
                value={coverageInput}
                onChange={e => setCoverageInput(e.target.value)}
                placeholder="1000.00"
                style={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '8px',
                  padding: '8px 12px',
                  color: 'var(--text-main)',
                  fontSize: '13px',
                  width: '100%',
                }}
              />
              {tabarruGross > 0n && (
                <div style={{ marginTop: '8px', padding: '10px', background: 'var(--bg-card)', borderRadius: '8px', fontSize: '12px' }}>
                  <div style={{ color: 'var(--text-muted)' }}>Required tabarru (incl. 10% wakala):</div>
                  <div style={{ color: 'var(--gold)', fontWeight: 600, fontSize: '14px', marginTop: '2px' }}>
                    {fmtUSDC(tabarruGross)} USDC
                  </div>
                  <div style={{ color: 'var(--text-muted)', marginTop: '4px', fontSize: '11px' }}>
                    tabarruRate = {fmtPct(putRateWad)} of coverage
                  </div>
                </div>
              )}
            </div>
            <div style={{ paddingTop: '20px' }}>
              <button
                onClick={handleContribute}
                disabled={isBusy || coverageAmt === 0n || tabarruGross === 0n}
                style={{
                  background: isBusy ? 'var(--border)' : '#2a9d8f',
                  color: '#fff',
                  border: 'none',
                  borderRadius: '8px',
                  padding: '10px 24px',
                  fontSize: '13px',
                  fontWeight: 600,
                  cursor: isBusy ? 'not-allowed' : 'pointer',
                }}
              >
                {isApprovePending || isApproveConfirming ? 'Approving...'
                  : isContributing || isContribConfirming ? 'Contributing...'
                  : 'Contribute'}
              </button>
            </div>
          </div>
        )}
        {contribSuccess && (
          <p style={{ color: 'var(--green-lite)', fontSize: '12px', marginTop: '8px' }}>
            Tabarru contributed successfully!
          </p>
        )}
      </div>

      {/* My Membership */}
      {address && member && (member.totalCoverage > 0n || member.totalTabarru > 0n) && (
        <div style={PANEL}>
          <h2 style={{ fontSize: '14px', fontWeight: 600, color: 'var(--text-main)', marginBottom: '16px' }}>
            My Membership
          </h2>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
            <div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Total Coverage</div>
              <div style={{ fontSize: '1.2rem', fontWeight: 700, color: 'var(--text-main)' }}>
                {fmtUSDC(member.totalCoverage)} USDC
              </div>
            </div>
            <div>
              <div style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '4px' }}>Total Tabarru Donated</div>
              <div style={{ fontSize: '1.2rem', fontWeight: 700, color: 'var(--text-main)' }}>
                {fmtUSDC(member.totalTabarru)} USDC
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Shariah Note */}
      <div style={{ ...PANEL, background: '#162019', borderColor: 'var(--green-deep)' }}>
        <h3 style={{ fontSize: '12px', fontWeight: 600, color: 'var(--green-lite)', marginBottom: '8px' }}>
          Shariah Compliance — AAOIFI Standard 26
        </h3>
        <div style={{ fontSize: '12px', color: 'var(--text-muted)', lineHeight: 1.6 }}>
          Contributions are <strong style={{ color: 'var(--text-main)' }}>tabarru</strong> (charitable donation), NOT insurance premiums.
          The 10% wakala fee is the operator&apos;s ju&apos;alah (service contract fee).
          No guaranteed return. Surplus (above 2× claims reserve) is distributed to charity.
          Put pricing at ι=0 eliminates any riba element from the premium formula.
        </div>
      </div>

    </div>
  )
}
