'use client'

import { useReadContracts, useWriteContract, useWaitForTransactionReceipt, usePublicClient } from 'wagmi'
import { useState, useEffect } from 'react'
import { PRODUCT_CONTRACTS, ICDS_ABI } from '@/lib/contracts'

const ADDR = PRODUCT_CONTRACTS.iCDS

// iCDS Status enum (matches Solidity: Open=0, Active=1, Triggered=2, Settled=3, Expired=4)
export const CDS_STATUS = ['Open', 'Active', 'Triggered', 'Settled', 'Expired'] as const
export type CdsStatus = typeof CDS_STATUS[number]

export interface Protection {
  id: number
  seller: string
  buyer: string
  refAsset: string
  token: string
  notional: bigint
  recoveryRateWad: bigint
  recoveryFloorWad: bigint
  tenorEnd: bigint
  lastPremiumAt: bigint
  premiumsCollected: bigint
  status: number
  statusLabel: CdsStatus
}

export function useProtectionList() {
  const client = usePublicClient()
  const [ids, setIds] = useState<number[]>([])
  const [isLoadingIds, setIsLoadingIds] = useState(false)

  useEffect(() => {
    if (!ADDR || !client) return
    setIsLoadingIds(true)

    // Enumerate ProtectionOpened events to find all protection IDs
    client.getLogs({
      address: ADDR,
      event: {
        type: 'event',
        name: 'ProtectionOpened',
        inputs: [
          { name: 'id',       type: 'uint256', indexed: true  },
          { name: 'seller',   type: 'address', indexed: true  },
          { name: 'refAsset', type: 'address', indexed: false },
          { name: 'token',    type: 'address', indexed: false },
          { name: 'notional', type: 'uint256', indexed: false },
          { name: 'tenorEnd', type: 'uint256', indexed: false },
        ],
      },
      fromBlock: 0n,
    }).then(logs => {
      const foundIds = logs
        .map(log => {
          try {
            return Number((log.args as { id?: bigint }).id ?? 0n)
          } catch {
            return -1
          }
        })
        .filter(id => id >= 0)
      setIds([...new Set(foundIds)].sort((a, b) => a - b))
    }).catch(() => {
      // If getLogs fails (e.g. contract not yet deployed), return empty
      setIds([])
    }).finally(() => {
      setIsLoadingIds(false)
    })
  }, [client, ADDR])

  return { ids, isLoadingIds }
}

export function useProtections(ids: number[]) {
  const contracts = ids.map(id => ({
    address: ADDR as `0x${string}`,
    abi: ICDS_ABI,
    functionName: 'protections' as const,
    args: [BigInt(id)] as const,
  }))

  const premiumContracts = ids.map(id => ({
    address: ADDR as `0x${string}`,
    abi: ICDS_ABI,
    functionName: 'computePremium' as const,
    args: [BigInt(id)] as const,
  }))

  const { data, isLoading } = useReadContracts({
    contracts,
    query: { enabled: !!ADDR && ids.length > 0, refetchInterval: 30_000 },
  })
  const { data: premiumData } = useReadContracts({
    contracts: premiumContracts,
    query: { enabled: !!ADDR && ids.length > 0, refetchInterval: 30_000 },
  })

  const protections: (Protection & { currentPremium: bigint })[] = []

  if (data) {
    data.forEach((result, i) => {
      if (result?.status === 'success' && result.result) {
        const r = result.result as readonly [string, string, string, string, bigint, bigint, bigint, bigint, bigint, bigint, number]
        const statusNum = r[10] as number
        protections.push({
          id:                ids[i],
          seller:            r[0],
          buyer:             r[1],
          refAsset:          r[2],
          token:             r[3],
          notional:          r[4],
          recoveryRateWad:   r[5],
          recoveryFloorWad:  r[6],
          tenorEnd:          r[7],
          lastPremiumAt:     r[8],
          premiumsCollected: r[9],
          status:            statusNum,
          statusLabel:       CDS_STATUS[statusNum] ?? 'Open',
          currentPremium:    premiumData?.[i]?.status === 'success'
            ? (premiumData[i].result as bigint)
            : 0n,
        })
      }
    })
  }

  return { protections, isLoading }
}

export function useCreditWrite() {
  const { writeContract: writeOpen,   data: openTx,   isPending: isOpenPending   } = useWriteContract()
  const { writeContract: writeAccept, data: acceptTx, isPending: isAcceptPending } = useWriteContract()
  const { writeContract: writePremium,data: premiumTx,isPending: isPremiumPending } = useWriteContract()
  const { writeContract: writeSettle, data: settleTx, isPending: isSettlePending  } = useWriteContract()
  const { writeContract: writeExpire, data: expireTx, isPending: isExpirePending  } = useWriteContract()

  const { isLoading: isOpenConfirming,   isSuccess: openSuccess   } = useWaitForTransactionReceipt({ hash: openTx })
  const { isLoading: isAcceptConfirming, isSuccess: acceptSuccess } = useWaitForTransactionReceipt({ hash: acceptTx })
  const { isLoading: isPremiumConfirming,isSuccess: premiumSuccess} = useWaitForTransactionReceipt({ hash: premiumTx })
  const { isLoading: isSettleConfirming, isSuccess: settleSuccess } = useWaitForTransactionReceipt({ hash: settleTx })
  const { isLoading: isExpireConfirming, isSuccess: expireSuccess } = useWaitForTransactionReceipt({ hash: expireTx })

  const openProtection = (
    refAsset: `0x${string}`,
    token: `0x${string}`,
    notional: bigint,
    recoveryRateWad: bigint,
    tenorDays: bigint,
  ) => {
    if (!ADDR) return
    writeOpen({
      address: ADDR,
      abi: ICDS_ABI,
      functionName: 'openProtection',
      args: [refAsset, token, notional, recoveryRateWad, tenorDays],
    })
  }

  const acceptProtection = (id: bigint) => {
    if (!ADDR) return
    writeAccept({ address: ADDR, abi: ICDS_ABI, functionName: 'acceptProtection', args: [id] })
  }

  const payPremium = (id: bigint) => {
    if (!ADDR) return
    writePremium({ address: ADDR, abi: ICDS_ABI, functionName: 'payPremium', args: [id] })
  }

  const settle = (id: bigint) => {
    if (!ADDR) return
    writeSettle({ address: ADDR, abi: ICDS_ABI, functionName: 'settle', args: [id] })
  }

  const expire = (id: bigint) => {
    if (!ADDR) return
    writeExpire({ address: ADDR, abi: ICDS_ABI, functionName: 'expire', args: [id] })
  }

  return {
    openProtection, acceptProtection, payPremium, settle, expire,
    openTx, acceptTx, premiumTx, settleTx, expireTx,
    isOpenPending, isAcceptPending, isPremiumPending, isSettlePending, isExpirePending,
    isOpenConfirming, isAcceptConfirming, isPremiumConfirming, isSettleConfirming, isExpireConfirming,
    openSuccess, acceptSuccess, premiumSuccess, settleSuccess, expireSuccess,
  }
}
