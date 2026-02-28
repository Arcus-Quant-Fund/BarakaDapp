'use client'

import { useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { PRODUCT_CONTRACTS, TAKAFUL_POOL_ABI, ORACLE_ADAPTER_ABI, CONTRACTS, BTC_ASSET_ADDRESS } from '@/lib/contracts'

const POOL_ADDR = PRODUCT_CONTRACTS.TakafulPool
// keccak256("BTC-40k-USDC") — precomputed to match Solidity
// keccak256("BTC-40k-USDC") — confirmed via `cast keccak "BTC-40k-USDC"`
export const BTC_POOL_ID = '0xa62553efe090534f3bd23505218dd898105cb8863d630a8e01fae4e40ab72647' as `0x${string}`

export interface PoolData {
  asset: string
  token: string
  floorWad: bigint
  active: boolean
  balance: bigint
  totalClaimsPaid: bigint
  spotWad: bigint
}

export interface MemberData {
  totalCoverage: bigint
  totalTabarru: bigint
}

export function useTakafulPoolData(poolId: `0x${string}`) {
  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      {
        address: POOL_ADDR || undefined,
        abi: TAKAFUL_POOL_ABI,
        functionName: 'pools',
        args: [poolId],
      },
      {
        address: POOL_ADDR || undefined,
        abi: TAKAFUL_POOL_ABI,
        functionName: 'poolBalance',
        args: [poolId],
      },
      {
        address: POOL_ADDR || undefined,
        abi: TAKAFUL_POOL_ABI,
        functionName: 'totalClaimsPaid',
        args: [poolId],
      },
      {
        address: CONTRACTS.OracleAdapter,
        abi: ORACLE_ADAPTER_ABI,
        functionName: 'getIndexPrice',
        args: [BTC_ASSET_ADDRESS],
      },
    ],
    query: { enabled: !!POOL_ADDR, refetchInterval: 15_000 },
  })

  let pool: PoolData | null = null
  if (data) {
    const poolResult    = data[0]
    const balanceResult = data[1]
    const claimsResult  = data[2]
    const spotResult    = data[3]

    if (poolResult?.status === 'success' && poolResult.result) {
      const p = poolResult.result as readonly [string, string, bigint, boolean]
      pool = {
        asset:           p[0],
        token:           p[1],
        floorWad:        p[2],
        active:          p[3],
        balance:         balanceResult?.status === 'success' ? (balanceResult.result as bigint) : 0n,
        totalClaimsPaid: claimsResult?.status  === 'success' ? (claimsResult.result  as bigint) : 0n,
        spotWad:         spotResult?.status     === 'success' ? (spotResult.result     as bigint) : 0n,
      }
    }
  }

  return { pool, isLoading, refetch }
}

export function useMemberData(poolId: `0x${string}`, address?: string) {
  const { data, isLoading } = useReadContracts({
    contracts: [
      {
        address: POOL_ADDR || undefined,
        abi: TAKAFUL_POOL_ABI,
        functionName: 'members',
        args: [poolId, address as `0x${string}`],
      },
    ],
    query: { enabled: !!POOL_ADDR && !!address, refetchInterval: 30_000 },
  })

  let member: MemberData | null = null
  if (data?.[0]?.status === 'success' && data[0].result) {
    const m = data[0].result as readonly [bigint, bigint]
    member = { totalCoverage: m[0], totalTabarru: m[1] }
  }

  return { member, isLoading }
}

export function useTabarruPreview(poolId: `0x${string}`, coverageAmount: bigint) {
  const { data, isLoading } = useReadContracts({
    contracts: [
      {
        address: POOL_ADDR || undefined,
        abi: TAKAFUL_POOL_ABI,
        functionName: 'getRequiredTabarru',
        args: [poolId, coverageAmount],
      },
    ],
    query: { enabled: !!POOL_ADDR && coverageAmount > 0n, refetchInterval: 10_000 },
  })

  if (data?.[0]?.status === 'success' && data[0].result) {
    const r = data[0].result as readonly [bigint, bigint, bigint]
    return {
      tabarruGross: r[0],
      spotWad:      r[1],
      putRateWad:   r[2],
      isLoading,
    }
  }
  return { tabarruGross: 0n, spotWad: 0n, putRateWad: 0n, isLoading }
}

export function useTakafulWrite() {
  const { writeContract, data: tx, isPending } = useWriteContract()
  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({ hash: tx })

  const contribute = (poolId: `0x${string}`, coverageAmount: bigint) => {
    if (!POOL_ADDR) return
    writeContract({
      address: POOL_ADDR,
      abi: TAKAFUL_POOL_ABI,
      functionName: 'contribute',
      args: [poolId, coverageAmount],
    })
  }

  return { contribute, tx, isPending, isConfirming, isSuccess }
}
