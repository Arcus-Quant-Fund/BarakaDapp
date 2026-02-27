'use client'

import { useReadContract } from 'wagmi'
import { CONTRACTS, FUNDING_ENGINE_ABI, BTC_ASSET_ADDRESS } from '@/lib/contracts'

export function useFundingRate() {
  const { data: rate, isLoading, error } = useReadContract({
    address: CONTRACTS.FundingEngine,
    abi: FUNDING_ENGINE_ABI,
    functionName: 'getFundingRate',
    args: [BTC_ASSET_ADDRESS],
    query: { refetchInterval: 15_000 },
  })

  const { data: lastTime } = useReadContract({
    address: CONTRACTS.FundingEngine,
    abi: FUNDING_ENGINE_ABI,
    functionName: 'lastFundingTime',
    args: [BTC_ASSET_ADDRESS],
    query: { refetchInterval: 15_000 },
  })

  // rate is int256 in 1e18 scale. MAX_FUNDING_RATE = 75e14 = 0.75%.
  // ratePercent: 0.0075 means 0.75%
  const rateRaw = rate as bigint | undefined
  const ratePercent =
    rateRaw !== undefined ? Number(rateRaw) / 1e18 : null

  const rateBps = ratePercent !== null ? ratePercent * 10_000 : null // e.g. 75 = 75bps

  const nextFundingIn =
    lastTime !== undefined
      ? Math.max(0, Number(lastTime as bigint) * 1000 + 3_600_000 - Date.now())
      : null

  return {
    ratePercent,  // e.g. 0.0075 = 0.75%
    rateBps,      // e.g. 75 = 75bps
    rateDisplay:  ratePercent !== null ? `${(ratePercent * 100).toFixed(4)}%` : '—',
    nextFundingIn,
    isLong: ratePercent !== null && ratePercent > 0, // longs pay when positive
    isLoading,
    error,
  }
}
