'use client'

import { useReadContract, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useAccount } from 'wagmi'
import { PRODUCT_CONTRACTS, PERPETUAL_SUKUK_ABI } from '@/lib/contracts'

const ADDR = PRODUCT_CONTRACTS.PerpetualSukuk

export interface SukukInfo {
  id: number
  issuer: string
  asset: string
  token: string
  parValue: bigint
  profitRateWad: bigint
  maturityEpoch: bigint
  issuedAt: bigint
  totalSubscribed: bigint
  redeemed: boolean
}

export interface UserSubscription {
  id: number
  amount: bigint
  lastProfitAt: bigint
  redeemed: boolean
  accrued: bigint
  callRateWad: bigint
  callUpside: bigint
}

export function useSukukCount() {
  const { data, isLoading } = useReadContract({
    address: ADDR || undefined,
    abi: PERPETUAL_SUKUK_ABI,
    functionName: 'nextId',
    query: { enabled: !!ADDR, refetchInterval: 30_000 },
  })
  return { count: data ? Number(data) : 0, isLoading }
}

export function useSukukList(count: number) {
  const contracts = Array.from({ length: count }, (_, i) => ({
    address: ADDR as `0x${string}`,
    abi: PERPETUAL_SUKUK_ABI,
    functionName: 'sukuks' as const,
    args: [BigInt(i)] as const,
  }))

  const { data, isLoading } = useReadContracts({
    contracts,
    query: { enabled: !!ADDR && count > 0, refetchInterval: 30_000 },
  })

  const sukuks: SukukInfo[] = []
  if (data) {
    data.forEach((result, i) => {
      if (result.status === 'success' && result.result) {
        const r = result.result as readonly [string, string, string, bigint, bigint, bigint, bigint, bigint, boolean]
        sukuks.push({
          id: i,
          issuer: r[0],
          asset: r[1],
          token: r[2],
          parValue: r[3],
          profitRateWad: r[4],
          maturityEpoch: r[5],
          issuedAt: r[6],
          totalSubscribed: r[7],
          redeemed: r[8],
        })
      }
    })
  }

  return { sukuks: sukuks.filter(s => !s.redeemed), isLoading }
}

export function useUserSukukPositions(ids: number[], userAddress?: string) {
  const address = userAddress as `0x${string}` | undefined

  // Read subscriptions for each sukuk
  const subContracts = ids.map(id => ({
    address: ADDR as `0x${string}`,
    abi: PERPETUAL_SUKUK_ABI,
    functionName: 'subscriptions' as const,
    args: [BigInt(id), address!] as const,
  }))
  const profitContracts = ids.map(id => ({
    address: ADDR as `0x${string}`,
    abi: PERPETUAL_SUKUK_ABI,
    functionName: 'getAccruedProfit' as const,
    args: [BigInt(id), address!] as const,
  }))
  const callContracts = ids.map(id => ({
    address: ADDR as `0x${string}`,
    abi: PERPETUAL_SUKUK_ABI,
    functionName: 'getEmbeddedCallValue' as const,
    args: [BigInt(id), address!] as const,
  }))

  const { data: subData, isLoading: subLoading } = useReadContracts({
    contracts: subContracts,
    query: { enabled: !!ADDR && !!address && ids.length > 0, refetchInterval: 30_000 },
  })
  const { data: profitData, isLoading: profitLoading } = useReadContracts({
    contracts: profitContracts,
    query: { enabled: !!ADDR && !!address && ids.length > 0, refetchInterval: 30_000 },
  })
  const { data: callData, isLoading: callLoading } = useReadContracts({
    contracts: callContracts,
    query: { enabled: !!ADDR && !!address && ids.length > 0, refetchInterval: 30_000 },
  })

  const positions: UserSubscription[] = []
  if (subData && profitData && callData) {
    ids.forEach((id, i) => {
      const sub = subData[i]
      const profit = profitData[i]
      const call = callData[i]
      if (sub?.status === 'success' && sub.result) {
        const s = sub.result as readonly [bigint, bigint, boolean]
        if (s[0] > 0n && !s[2]) {
          positions.push({
            id,
            amount: s[0],
            lastProfitAt: s[1],
            redeemed: s[2],
            accrued: profit?.status === 'success' ? (profit.result as bigint) : 0n,
            callRateWad: call?.status === 'success' ? (call.result as readonly [bigint, bigint])[0] : 0n,
            callUpside: call?.status === 'success' ? (call.result as readonly [bigint, bigint])[1] : 0n,
          })
        }
      }
    })
  }

  return { positions, isLoading: subLoading || profitLoading || callLoading }
}

export function useSukukWrite() {
  const { writeContract: writeSubscribe, data: subscribeTx, isPending: isSubscribePending } = useWriteContract()
  const { writeContract: writeClaim,     data: claimTx,     isPending: isClaimPending     } = useWriteContract()
  const { writeContract: writeRedeem,    data: redeemTx,    isPending: isRedeemPending    } = useWriteContract()

  const { isLoading: isSubscribeConfirming, isSuccess: subscribeSuccess } =
    useWaitForTransactionReceipt({ hash: subscribeTx })
  const { isLoading: isClaimConfirming, isSuccess: claimSuccess } =
    useWaitForTransactionReceipt({ hash: claimTx })
  const { isLoading: isRedeemConfirming, isSuccess: redeemSuccess } =
    useWaitForTransactionReceipt({ hash: redeemTx })

  const subscribe = (id: bigint, amount: bigint) => {
    if (!ADDR) return
    writeSubscribe({ address: ADDR, abi: PERPETUAL_SUKUK_ABI, functionName: 'subscribe', args: [id, amount] })
  }

  const claimProfit = (id: bigint) => {
    if (!ADDR) return
    writeClaim({ address: ADDR, abi: PERPETUAL_SUKUK_ABI, functionName: 'claimProfit', args: [id] })
  }

  const redeem = (id: bigint) => {
    if (!ADDR) return
    writeRedeem({ address: ADDR, abi: PERPETUAL_SUKUK_ABI, functionName: 'redeem', args: [id] })
  }

  return {
    subscribe, claimProfit, redeem,
    subscribeTx, claimTx, redeemTx,
    isSubscribePending, isClaimPending, isRedeemPending,
    isSubscribeConfirming, isClaimConfirming, isRedeemConfirming,
    subscribeSuccess, claimSuccess, redeemSuccess,
  }
}
