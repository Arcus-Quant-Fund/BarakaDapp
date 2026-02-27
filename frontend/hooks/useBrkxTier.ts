'use client'

import { useAccount, useReadContract } from 'wagmi'
import { CONTRACTS, BRKX_TOKEN_ABI, BRKX_TIERS } from '@/lib/contracts'

export type BrkxTierInfo = {
  tierIndex:    number         // 0=Tier3(best) … 3=Standard(no BRKX)
  tierName:     string         // 'Tier 3' | 'Tier 2' | 'Tier 1' | 'Standard'
  feeBps:       number         // 25 | 35 | 40 | 50
  feeLabel:     string         // '2.5 bps' | '3.5 bps' | '4.0 bps' | '5.0 bps'
  feePct:       string         // '0.025%' | '0.035%' | '0.040%' | '0.050%'
  balance:      bigint
  balanceDisplay: string       // '100,000 BRKX'
  nextTierBrkx: bigint | null  // BRKX needed to reach next tier (null if already best)
  isLoading:    boolean
}

const TIER_NAMES = ['Tier 3', 'Tier 2', 'Tier 1', 'Standard'] as const
const FEE_PCT    = ['0.025%', '0.035%', '0.040%', '0.050%'] as const

export function useBrkxTier(): BrkxTierInfo {
  const { address } = useAccount()

  const { data: balance, isLoading } = useReadContract({
    address: CONTRACTS.BRKXToken,
    abi:     BRKX_TOKEN_ABI,
    functionName: 'balanceOf',
    args:    address ? [address] : undefined,
    query:   { enabled: !!address, refetchInterval: 30_000 },
  })

  const bal = balance ?? 0n

  // BRKX_TIERS sorted highest threshold first; find first tier user qualifies for
  let tierIndex = BRKX_TIERS.length - 1
  for (let i = 0; i < BRKX_TIERS.length; i++) {
    if (bal >= BRKX_TIERS[i].minBrkx) { tierIndex = i; break }
  }

  const tier = BRKX_TIERS[tierIndex]
  const nextTierBrkx = tierIndex > 0 ? BRKX_TIERS[tierIndex - 1].minBrkx - bal : null

  const balanceDisplay = address
    ? `${(Number(bal) / 1e18).toLocaleString('en-US', { maximumFractionDigits: 0 })} BRKX`
    : '— BRKX'

  return {
    tierIndex,
    tierName:  TIER_NAMES[tierIndex],
    feeBps:    tier.feeBps,
    feeLabel:  tier.label,
    feePct:    FEE_PCT[tierIndex],
    balance:   bal,
    balanceDisplay,
    nextTierBrkx,
    isLoading,
  }
}
