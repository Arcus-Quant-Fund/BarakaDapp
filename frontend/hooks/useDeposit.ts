'use client'

import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseUnits } from 'viem'
import { CONTRACTS, COLLATERAL_VAULT_ABI, USDC_ADDRESS } from '@/lib/contracts'

// Minimal ERC20 ABI — only approve
const ERC20_ABI = [
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
] as const

export function useDeposit() {
  const {
    writeContract: approveWrite,
    data: approveTx,
    isPending: isApprovePending,
  } = useWriteContract()

  const {
    writeContract: depositWrite,
    data: depositTx,
    isPending: isDepositPending,
  } = useWriteContract()

  const { isLoading: isApproveConfirming, isSuccess: approveSuccess } =
    useWaitForTransactionReceipt({ hash: approveTx })

  const { isLoading: isDepositConfirming, isSuccess: depositSuccess } =
    useWaitForTransactionReceipt({ hash: depositTx })

  function approve(amountUSDC: string) {
    const amount = parseUnits(amountUSDC, 6)
    approveWrite({
      address: USDC_ADDRESS,
      abi: ERC20_ABI,
      functionName: 'approve',
      args: [CONTRACTS.CollateralVault, amount],
    })
  }

  function deposit(amountUSDC: string) {
    const amount = parseUnits(amountUSDC, 6)
    depositWrite({
      address: CONTRACTS.CollateralVault,
      abi: COLLATERAL_VAULT_ABI,
      functionName: 'deposit',
      args: [USDC_ADDRESS, amount],
    })
  }

  return {
    approve,
    deposit,
    approveTx,
    depositTx,
    isApprovePending,
    isApproveConfirming,
    approveSuccess,
    isDepositPending,
    isDepositConfirming,
    depositSuccess,
    isBusy: isApprovePending || isApproveConfirming || isDepositPending || isDepositConfirming,
  }
}

export function useWithdraw() {
  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: txHash })

  function withdraw(amountUSDC: string) {
    const amount = parseUnits(amountUSDC, 6)
    writeContract({
      address: CONTRACTS.CollateralVault,
      abi: COLLATERAL_VAULT_ABI,
      functionName: 'withdraw',
      args: [USDC_ADDRESS, amount],
    })
  }

  return { withdraw, txHash, isPending, isConfirming, isSuccess, isBusy: isPending || isConfirming }
}
