'use client'

import { useState } from 'react'
import { useAccount } from 'wagmi'
import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useDeposit, useWithdraw } from '@/hooks/useDeposit'
import { useCollateralBalance } from '@/hooks/useCollateralBalance'
import { ARBISCAN_BASE } from '@/lib/contracts'

type Tab = 'deposit' | 'withdraw'

export default function DepositPanel() {
  const { isConnected } = useAccount()
  const [tab, setTab] = useState<Tab>('deposit')
  const [amount, setAmount] = useState('')
  const [step, setStep] = useState<'idle' | 'approving' | 'depositing' | 'done'>('idle')

  const { display: balanceDisplay, usd: balanceUsd, refetch } = useCollateralBalance()
  const {
    approve, deposit,
    approveTx, depositTx,
    isApprovePending, isApproveConfirming, approveSuccess,
    isDepositPending, isDepositConfirming, depositSuccess,
    isBusy: isDepositBusy,
  } = useDeposit()
  const { withdraw, txHash: withdrawTx, isPending: isWithdrawPending, isConfirming: isWithdrawConfirming, isSuccess: withdrawSuccess, isBusy: isWithdrawBusy } = useWithdraw()

  const amountNum = parseFloat(amount) || 0

  function handleApprove() {
    if (!amountNum) return
    setStep('approving')
    approve(amount)
  }

  function handleDeposit() {
    if (!amountNum) return
    setStep('depositing')
    deposit(amount)
    if (depositSuccess) { refetch(); setStep('done') }
  }

  function handleWithdraw() {
    if (!amountNum) return
    withdraw(amount)
    if (withdrawSuccess) refetch()
  }

  const txHash = tab === 'deposit' ? depositTx ?? approveTx : withdrawTx

  return (
    <div
      style={{
        background: 'var(--bg-panel)',
        border: '1px solid var(--border)',
        borderRadius: '12px',
        overflow: 'hidden',
      }}
    >
      {/* Tab selector */}
      <div style={{ display: 'flex', borderBottom: '1px solid var(--border)' }}>
        {(['deposit', 'withdraw'] as Tab[]).map((t) => (
          <button
            key={t}
            onClick={() => { setTab(t); setAmount(''); setStep('idle') }}
            style={{
              flex: 1,
              padding: '10px',
              fontWeight: 600,
              fontSize: '12px',
              border: 'none',
              cursor: 'pointer',
              textTransform: 'capitalize',
              background: tab === t ? 'rgba(82,183,136,0.1)' : 'var(--bg-card)',
              color: tab === t ? 'var(--green-lite)' : 'var(--text-muted)',
              borderBottom: tab === t ? '2px solid var(--green-lite)' : '2px solid transparent',
            }}
          >
            {t}
          </button>
        ))}
      </div>

      <div style={{ padding: '16px' }}>
        {/* Vault balance */}
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            background: 'var(--bg-card)',
            border: '1px solid var(--border)',
            borderRadius: '8px',
            padding: '10px 14px',
            marginBottom: '14px',
          }}
        >
          <span style={{ fontSize: '11px', color: 'var(--text-muted)' }}>Vault Balance</span>
          <span style={{ fontFamily: 'var(--font-geist-mono)', fontWeight: 700, color: 'var(--gold)', fontSize: '14px' }}>
            {isConnected ? balanceDisplay : '—'}
          </span>
        </div>

        {/* Amount input */}
        <div style={{ marginBottom: '14px' }}>
          <label style={{ fontSize: '11px', color: 'var(--text-muted)', display: 'block', marginBottom: '6px' }}>
            AMOUNT (USDC)
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
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
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

        {tab === 'withdraw' && (
          <p style={{ fontSize: '11px', color: 'var(--text-muted)', marginBottom: '12px', lineHeight: 1.5 }}>
            ⏱ 24-hour cooldown enforced on-chain by CollateralVault.sol (Shariah: no instant exit during positions).
          </p>
        )}

        {/* Actions */}
        {!isConnected ? (
          <div style={{ display: 'flex', justifyContent: 'center' }}>
            <ConnectButton label="Connect Wallet" />
          </div>
        ) : tab === 'deposit' ? (
          <div style={{ display: 'flex', gap: '8px' }}>
            {/* Step 1: Approve */}
            <button
              onClick={handleApprove}
              disabled={!amountNum || isDepositBusy || approveSuccess}
              style={{
                flex: 1,
                padding: '11px',
                fontWeight: 700,
                fontSize: '12px',
                border: '1px solid var(--border)',
                borderRadius: '8px',
                cursor: !amountNum || isDepositBusy || approveSuccess ? 'not-allowed' : 'pointer',
                background: approveSuccess ? 'rgba(82,183,136,0.15)' : 'var(--bg-card)',
                color: approveSuccess ? 'var(--green-lite)' : 'var(--text-muted)',
              }}
            >
              {isApprovePending || isApproveConfirming ? '...' : approveSuccess ? '1. Approved ✓' : '1. Approve'}
            </button>

            {/* Step 2: Deposit */}
            <button
              onClick={handleDeposit}
              disabled={!amountNum || !approveSuccess || isDepositBusy || depositSuccess}
              style={{
                flex: 1,
                padding: '11px',
                fontWeight: 700,
                fontSize: '12px',
                border: 'none',
                borderRadius: '8px',
                cursor: !amountNum || !approveSuccess || isDepositBusy || depositSuccess ? 'not-allowed' : 'pointer',
                background:
                  depositSuccess ? 'rgba(82,183,136,0.2)' :
                  !approveSuccess ? 'var(--bg-card)' :
                  'var(--green-mid)',
                color:
                  depositSuccess ? 'var(--green-lite)' :
                  !approveSuccess ? 'var(--text-muted)' :
                  'white',
              }}
            >
              {isDepositPending || isDepositConfirming ? 'Depositing...' : depositSuccess ? '2. Done ✓' : '2. Deposit'}
            </button>
          </div>
        ) : (
          <button
            onClick={handleWithdraw}
            disabled={!amountNum || isWithdrawBusy || !balanceUsd || (balanceUsd ?? 0) < amountNum}
            style={{
              width: '100%',
              padding: '11px',
              fontWeight: 700,
              fontSize: '13px',
              border: 'none',
              borderRadius: '8px',
              cursor: !amountNum || isWithdrawBusy ? 'not-allowed' : 'pointer',
              background: withdrawSuccess ? 'rgba(82,183,136,0.2)' : !amountNum || isWithdrawBusy ? 'var(--bg-card)' : 'var(--green-deep)',
              color: !amountNum || isWithdrawBusy ? 'var(--text-muted)' : 'var(--green-lite)',
            }}
          >
            {isWithdrawPending || isWithdrawConfirming ? 'Withdrawing...' : withdrawSuccess ? 'Withdrawn ✓' : 'Withdraw USDC'}
          </button>
        )}

        {txHash && (
          <div style={{ marginTop: '10px', textAlign: 'center', fontSize: '11px', color: 'var(--green-lite)' }}>
            Tx:{' '}
            <a
              href={`${ARBISCAN_BASE}/tx/${txHash}`}
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: 'var(--green-lite)' }}
            >
              {txHash.slice(0, 10)}...{txHash.slice(-6)} ↗
            </a>
          </div>
        )}

        <p style={{ fontSize: '10px', color: 'var(--text-muted)', marginTop: '10px', textAlign: 'center', lineHeight: 1.5 }}>
          No rehypothecation. Funds stay in the vault contract.
        </p>
      </div>
    </div>
  )
}
