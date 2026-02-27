'use client'

import { useReadContract } from 'wagmi'
import { CONTRACTS, INSURANCE_FUND_ABI, USDC_ADDRESS } from '@/lib/contracts'

export function useInsuranceFund() {
  const { data, isLoading } = useReadContract({
    address: CONTRACTS.InsuranceFund,
    abi: INSURANCE_FUND_ABI,
    functionName: 'fundBalance',
    args: [USDC_ADDRESS],
    query: { refetchInterval: 30_000 },
  })

  // USDC 6 decimals
  const raw = data as bigint | undefined
  const usd = raw !== undefined ? Number(raw) / 1e6 : null

  return {
    usd,
    display: usd !== null
      ? `$${usd.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 })}`
      : '—',
    isLoading,
  }
}
