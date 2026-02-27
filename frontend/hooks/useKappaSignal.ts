'use client'

import { useReadContract } from 'wagmi'
import { CONTRACTS, ORACLE_ADAPTER_ABI, BTC_ASSET_ADDRESS } from '@/lib/contracts'

const REGIME_LABELS = ['NORMAL', 'ELEVATED', 'HIGH', 'CRITICAL'] as const
const REGIME_COLORS = ['#52b788', '#f4a261', '#e76f51', '#e63946'] as const

export type KappaSignal = {
  kappa:        number   // convergence intensity (1e18-normalised)
  premium:      number   // (mark - index) / index (1e18-normalised)
  regime:       number   // 0-3
  regimeLabel:  string   // 'NORMAL' | 'ELEVATED' | 'HIGH' | 'CRITICAL'
  regimeColor:  string   // hex colour for UI badge
  isLoading:    boolean
}

export function useKappaSignal(): KappaSignal {
  const { data, isLoading } = useReadContract({
    address: CONTRACTS.OracleAdapter,
    abi:     ORACLE_ADAPTER_ABI,
    functionName: 'getKappaSignal',
    args:    [BTC_ASSET_ADDRESS],
    query:   { refetchInterval: 30_000 },
  })

  if (!data) {
    return { kappa: 0, premium: 0, regime: 0, regimeLabel: 'NORMAL', regimeColor: REGIME_COLORS[0], isLoading }
  }

  // wagmi v2 returns tuple: [kappa, premium, regime] at indices 0/1/2
  const [rawKappa, rawPremium, rawRegime] = data as [bigint, bigint, number]
  const regimeNum = Number(rawRegime)
  return {
    kappa:       Number(rawKappa)   / 1e18,
    premium:     Number(rawPremium) / 1e18,
    regime:      regimeNum,
    regimeLabel: REGIME_LABELS[regimeNum] ?? 'NORMAL',
    regimeColor: REGIME_COLORS[regimeNum] ?? REGIME_COLORS[0],
    isLoading,
  }
}
