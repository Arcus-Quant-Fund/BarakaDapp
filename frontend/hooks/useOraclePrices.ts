'use client'

import { useReadContracts } from 'wagmi'
import { CONTRACTS, ORACLE_ADAPTER_ABI, BTC_ASSET_ADDRESS, TWAP_WINDOW } from '@/lib/contracts'

export function useOraclePrices() {
  const { data, isLoading } = useReadContracts({
    contracts: [
      {
        address: CONTRACTS.OracleAdapter,
        abi: ORACLE_ADAPTER_ABI,
        functionName: 'getMarkPrice',
        args: [BTC_ASSET_ADDRESS, TWAP_WINDOW],
      },
      {
        address: CONTRACTS.OracleAdapter,
        abi: ORACLE_ADAPTER_ABI,
        functionName: 'getIndexPrice',
        args: [BTC_ASSET_ADDRESS],
      },
    ],
    query: { refetchInterval: 10_000 },
  })

  // OracleAdapter normalises Chainlink (8 dec) to 1e18.
  // $95,000 → 95000 * 1e18 → divide by 1e18 to get USD float.
  const markRaw  = data?.[0]?.result as bigint | undefined
  const indexRaw = data?.[1]?.result as bigint | undefined

  const mark  = markRaw  !== undefined ? Number(markRaw)  / 1e18 : null
  const index = indexRaw !== undefined ? Number(indexRaw) / 1e18 : null

  const premium = mark !== null && index !== null && index > 0
    ? ((mark - index) / index) * 100
    : null

  const fmt = (v: number | null) =>
    v !== null
      ? `$${v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`
      : '—'

  return {
    mark,
    index,
    premium,      // % above/below index
    markDisplay:  fmt(mark),
    indexDisplay: fmt(index),
    isLoading,
  }
}
