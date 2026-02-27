'use client'

import { useAccount, useReadContract } from 'wagmi'
import { CONTRACTS, COLLATERAL_VAULT_ABI, USDC_ADDRESS } from '@/lib/contracts'

export function useCollateralBalance() {
  const { address } = useAccount()

  const { data: totalData, isLoading, refetch } = useReadContract({
    address: CONTRACTS.CollateralVault,
    abi: COLLATERAL_VAULT_ABI,
    functionName: 'balance',
    args: address ? [address, USDC_ADDRESS] : undefined,
    query: {
      enabled: !!address,
      refetchInterval: 15_000,
    },
  })

  const { data: freeData } = useReadContract({
    address: CONTRACTS.CollateralVault,
    abi: COLLATERAL_VAULT_ABI,
    functionName: 'freeBalance',
    args: address ? [address, USDC_ADDRESS] : undefined,
    query: {
      enabled: !!address,
      refetchInterval: 15_000,
    },
  })

  // USDC has 6 decimals
  const total = totalData !== undefined ? Number(totalData as bigint) / 1e6 : null
  const free  = freeData  !== undefined ? Number(freeData  as bigint) / 1e6 : null

  const fmt = (v: number | null) =>
    v !== null
      ? `$${v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
      : '—'

  return {
    total,        // total vault balance (free + locked)
    free,         // withdrawable (not locked in positions)
    usd: total,   // alias for backward compat
    display: fmt(total),
    freeDisplay: fmt(free),
    isLoading,
    refetch,
  }
}
