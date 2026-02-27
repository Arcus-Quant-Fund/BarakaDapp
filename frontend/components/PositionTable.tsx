'use client'

import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { usePositions } from '@/hooks/usePositions'
import { CONTRACTS, POSITION_MANAGER_ABI, ARBISCAN_BASE } from '@/lib/contracts'
import { useState } from 'react'

export default function PositionTable() {
  const { positions, isLoading } = usePositions()
  const [closingId, setClosingId] = useState<`0x${string}` | null>(null)

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash })

  function handleClose(positionId: `0x${string}`) {
    setClosingId(positionId)
    writeContract({
      address: CONTRACTS.PositionManager,
      abi: POSITION_MANAGER_ABI,
      functionName: 'closePosition',
      args: [positionId], // bytes32 — passed directly as hex string
    })
  }

  return (
    <div
      style={{
        background: 'var(--bg-panel)',
        border: '1px solid var(--border)',
        borderRadius: '12px',
        overflow: 'hidden',
      }}
    >
      {/* Header */}
      <div style={{ padding: '12px 16px', borderBottom: '1px solid var(--border)', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <span style={{ fontSize: '13px', fontWeight: 700, color: 'var(--text-main)' }}>
          Open Positions
        </span>
        <span style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
          {isLoading ? 'Loading...' : `${positions.length} position${positions.length !== 1 ? 's' : ''}`}
        </span>
      </div>

      {positions.length === 0 ? (
        <div style={{ padding: '28px', textAlign: 'center', color: 'var(--text-muted)', fontSize: '13px' }}>
          {isLoading ? 'Scanning positions...' : 'No open positions'}
        </div>
      ) : (
        <>
          {/* Column headers */}
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '80px 70px 1fr 1fr 1fr 1fr 90px',
              padding: '8px 16px',
              borderBottom: '1px solid var(--border)',
              fontSize: '10px',
              color: 'var(--text-muted)',
              letterSpacing: '0.04em',
            }}
          >
            <span>MARKET</span>
            <span>SIDE</span>
            <span>SIZE</span>
            <span>COLLATERAL</span>
            <span>ENTRY</span>
            <span>PNL</span>
            <span style={{ textAlign: 'right' }}>ACTION</span>
          </div>

          {/* Rows */}
          {positions.map((pos) => {
            const isClosing = closingId === pos.positionId && (isPending || isConfirming)
            const isClosed  = closingId === pos.positionId && isSuccess
            const pnlColor  = pos.unrealisedPnl >= 0 ? 'var(--green-lite)' : 'var(--red-lite)'

            return (
              <div
                key={pos.positionId}
                style={{
                  display: 'grid',
                  gridTemplateColumns: '80px 70px 1fr 1fr 1fr 1fr 90px',
                  padding: '12px 16px',
                  borderBottom: '1px solid var(--border)',
                  alignItems: 'center',
                  fontSize: '12px',
                  opacity: isClosed ? 0.4 : 1,
                  transition: 'opacity 0.3s',
                }}
              >
                <span style={{ fontWeight: 700, color: 'var(--text-main)' }}>BTC-PERP</span>

                <span
                  style={{
                    fontWeight: 700,
                    color: pos.isLong ? 'var(--green-lite)' : 'var(--red-lite)',
                  }}
                >
                  {pos.isLong ? '▲ Long' : '▼ Short'} {pos.leverage.toFixed(1)}×
                </span>

                <span style={{ fontFamily: 'var(--font-geist-mono)', color: 'var(--text-main)' }}>
                  ${pos.size.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                </span>

                <span style={{ fontFamily: 'var(--font-geist-mono)', color: 'var(--text-muted)' }}>
                  ${pos.collateral.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                </span>

                <span style={{ fontFamily: 'var(--font-geist-mono)', color: 'var(--text-muted)' }}>
                  ${pos.entryPrice.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                </span>

                <div>
                  <div style={{ fontFamily: 'var(--font-geist-mono)', fontWeight: 700, color: pnlColor }}>
                    {pos.unrealisedPnl >= 0 ? '+' : ''}
                    ${pos.unrealisedPnl.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                  </div>
                  <div style={{ fontSize: '10px', color: pnlColor }}>
                    {pos.pnlPercent >= 0 ? '+' : ''}{pos.pnlPercent.toFixed(2)}%
                  </div>
                </div>

                <div style={{ textAlign: 'right' }}>
                  {isClosed ? (
                    <span style={{ fontSize: '11px', color: 'var(--green-lite)' }}>Closed ✓</span>
                  ) : (
                    <button
                      onClick={() => handleClose(pos.positionId)}
                      disabled={isClosing}
                      style={{
                        padding: '5px 12px',
                        fontSize: '11px',
                        fontWeight: 700,
                        border: '1px solid var(--border)',
                        borderRadius: '6px',
                        cursor: isClosing ? 'not-allowed' : 'pointer',
                        background: isClosing ? 'var(--bg-card)' : 'rgba(229,83,83,0.12)',
                        color: isClosing ? 'var(--text-muted)' : 'var(--red-lite)',
                      }}
                    >
                      {isClosing ? '...' : 'Close'}
                    </button>
                  )}
                  {txHash && closingId === pos.positionId && (
                    <a
                      href={`${ARBISCAN_BASE}/tx/${txHash}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      style={{ display: 'block', fontSize: '10px', color: 'var(--text-muted)', marginTop: '3px' }}
                    >
                      {txHash.slice(0, 8)}... ↗
                    </a>
                  )}
                </div>
              </div>
            )
          })}
        </>
      )}
    </div>
  )
}
