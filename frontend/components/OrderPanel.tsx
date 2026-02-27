'use client'

import { useState } from 'react'
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { parseUnits } from 'viem'
import { CONTRACTS, POSITION_MANAGER_ABI, BTC_ASSET_ADDRESS, USDC_ADDRESS } from '@/lib/contracts'
import { useOraclePrices } from '@/hooks/useOraclePrices'
import { useFundingRate } from '@/hooks/useFundingRate'

const MAX_LEVERAGE = 5

export default function OrderPanel() {
  const { isConnected } = useAccount()
  const [side, setSide]           = useState<'long' | 'short'>('long')
  const [collateral, setCollateral] = useState('')
  const [leverage, setLeverage]   = useState(1)

  const { mark } = useOraclePrices()
  const { rateDisplay, isLong } = useFundingRate()

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash: txHash,
  })

  const collateralNum = parseFloat(collateral) || 0
  const size = collateralNum * leverage
  const estLiqPrice =
    mark && collateralNum > 0
      ? side === 'long'
        ? mark * (1 - 1 / leverage + 0.02) // 2% maintenance margin
        : mark * (1 + 1 / leverage - 0.02)
      : null

  function handleOpen() {
    if (!collateralNum || collateralNum <= 0) return
    const collateralBigInt = parseUnits(collateral, 6) // USDC 6 decimals
    writeContract({
      address: CONTRACTS.PositionManager,
      abi: POSITION_MANAGER_ABI,
      functionName: 'openPosition',
      // (asset, collateralToken, collateral, leverage, isLong) — must match contract exactly
      args: [BTC_ASSET_ADDRESS, USDC_ADDRESS, collateralBigInt, BigInt(leverage), side === 'long'],
    })
  }

  return (
    <div
      style={{
        background: 'var(--bg-panel)',
        border: '1px solid var(--border)',
        borderRadius: '12px',
        overflow: 'hidden',
        minWidth: '300px',
      }}
    >
      {/* Side selector */}
      <div style={{ display: 'flex' }}>
        {(['long', 'short'] as const).map((s) => (
          <button
            key={s}
            onClick={() => setSide(s)}
            style={{
              flex: 1,
              padding: '12px',
              fontWeight: 700,
              fontSize: '13px',
              border: 'none',
              cursor: 'pointer',
              textTransform: 'uppercase',
              letterSpacing: '0.05em',
              transition: 'all 0.15s',
              background:
                side === s
                  ? s === 'long'
                    ? 'rgba(82,183,136,0.2)'
                    : 'rgba(229,83,83,0.2)'
                  : 'var(--bg-card)',
              color:
                side === s
                  ? s === 'long'
                    ? 'var(--green-lite)'
                    : 'var(--red-lite)'
                  : 'var(--text-muted)',
              borderBottom:
                side === s
                  ? `2px solid ${s === 'long' ? 'var(--green-lite)' : 'var(--red-lite)'}`
                  : '2px solid transparent',
            }}
          >
            {s === 'long' ? '▲ Long' : '▼ Short'}
          </button>
        ))}
      </div>

      <div style={{ padding: '18px' }}>
        {/* Collateral input */}
        <div style={{ marginBottom: '16px' }}>
          <label style={{ fontSize: '11px', color: 'var(--text-muted)', display: 'block', marginBottom: '6px' }}>
            COLLATERAL (USDC)
          </label>
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              background: 'var(--bg-card)',
              border: '1px solid var(--border)',
              borderRadius: '8px',
              padding: '10px 12px',
            }}
          >
            <input
              type="number"
              min="0"
              step="1"
              placeholder="0.00"
              value={collateral}
              onChange={(e) => setCollateral(e.target.value)}
              style={{
                flex: 1,
                background: 'transparent',
                border: 'none',
                outline: 'none',
                color: 'var(--text-main)',
                fontSize: '1rem',
                fontFamily: 'var(--font-geist-mono)',
              }}
            />
            <span style={{ color: 'var(--text-muted)', fontSize: '12px' }}>USDC</span>
          </div>
        </div>

        {/* Leverage slider */}
        <div style={{ marginBottom: '20px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '6px' }}>
            <label style={{ fontSize: '11px', color: 'var(--text-muted)' }}>
              LEVERAGE
            </label>
            <span
              style={{
                fontSize: '13px',
                fontWeight: 700,
                fontFamily: 'var(--font-geist-mono)',
                color: leverage === MAX_LEVERAGE ? 'var(--gold)' : 'var(--text-main)',
              }}
            >
              {leverage}×{leverage === MAX_LEVERAGE ? ' (max)' : ''}
            </span>
          </div>
          <input
            type="range"
            min={1}
            max={MAX_LEVERAGE}
            step={1}
            value={leverage}
            onChange={(e) => setLeverage(Number(e.target.value))}
            style={{
              width: '100%',
              accentColor: 'var(--green-mid)',
              cursor: 'pointer',
            }}
          />
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: '4px' }}>
            {[1, 2, 3, 4, 5].map((v) => (
              <button
                key={v}
                onClick={() => setLeverage(v)}
                style={{
                  background: leverage === v ? 'var(--green-deep)' : 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  color: leverage === v ? 'var(--green-lite)' : 'var(--text-muted)',
                  borderRadius: '4px',
                  padding: '2px 8px',
                  fontSize: '11px',
                  cursor: 'pointer',
                }}
              >
                {v}×
              </button>
            ))}
          </div>
        </div>

        {/* Order summary */}
        {collateralNum > 0 && (
          <div
            style={{
              background: 'var(--bg-card)',
              border: '1px solid var(--border)',
              borderRadius: '8px',
              padding: '12px',
              marginBottom: '16px',
              fontSize: '12px',
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '6px' }}>
              <span style={{ color: 'var(--text-muted)' }}>Position size</span>
              <span style={{ color: 'var(--text-main)', fontFamily: 'var(--font-geist-mono)' }}>
                ${size.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} USDC
              </span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '6px' }}>
              <span style={{ color: 'var(--text-muted)' }}>Est. liq. price</span>
              <span style={{ color: 'var(--red)', fontFamily: 'var(--font-geist-mono)' }}>
                {estLiqPrice
                  ? `$${estLiqPrice.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
                  : '—'}
              </span>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}>
              <span style={{ color: 'var(--text-muted)' }}>Funding rate (1h)</span>
              <span
                style={{
                  fontFamily: 'var(--font-geist-mono)',
                  color: side === 'long' && isLong ? 'var(--red-lite)' : 'var(--green-lite)',
                }}
              >
                {rateDisplay}
              </span>
            </div>
          </div>
        )}

        {/* Action button */}
        {!isConnected ? (
          <div style={{ display: 'flex', justifyContent: 'center' }}>
            <ConnectButton label="Connect to Trade" />
          </div>
        ) : (
          <button
            onClick={handleOpen}
            disabled={!collateralNum || isPending || isConfirming}
            style={{
              width: '100%',
              padding: '13px',
              fontWeight: 700,
              fontSize: '14px',
              border: 'none',
              borderRadius: '8px',
              cursor: !collateralNum || isPending || isConfirming ? 'not-allowed' : 'pointer',
              background:
                !collateralNum || isPending || isConfirming
                  ? 'var(--bg-card)'
                  : side === 'long'
                  ? 'var(--green-mid)'
                  : 'var(--red)',
              color:
                !collateralNum || isPending || isConfirming
                  ? 'var(--text-muted)'
                  : 'white',
              transition: 'all 0.15s',
            }}
          >
            {isPending
              ? 'Confirm in wallet...'
              : isConfirming
              ? 'Confirming on-chain...'
              : isSuccess
              ? 'Position opened!'
              : `${side === 'long' ? '▲ Open Long' : '▼ Open Short'} ${leverage}×`}
          </button>
        )}

        {isSuccess && txHash && (
          <div style={{ marginTop: '10px', textAlign: 'center', fontSize: '11px', color: 'var(--green-lite)' }}>
            Tx:{' '}
            <a
              href={`https://sepolia.arbiscan.io/tx/${txHash}`}
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: 'var(--green-lite)' }}
            >
              {txHash.slice(0, 10)}...
            </a>
          </div>
        )}

        {/* Shariah notice */}
        <p style={{ fontSize: '10px', color: 'var(--text-muted)', textAlign: 'center', marginTop: '12px', lineHeight: 1.5 }}>
          Max leverage is 5× — enforced on-chain by ShariahGuard.sol
        </p>
      </div>
    </div>
  )
}
