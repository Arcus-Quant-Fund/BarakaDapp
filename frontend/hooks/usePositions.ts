'use client'

import { useState, useEffect } from 'react'
import { useAccount, usePublicClient } from 'wagmi'
import { parseAbiItem } from 'viem'
import { CONTRACTS, POSITION_MANAGER_ABI } from '@/lib/contracts'
import { useOraclePrices } from './useOraclePrices'

export interface Position {
  positionId:      `0x${string}` // bytes32
  trader:          string
  asset:           string
  collateralToken: string
  isLong:          boolean
  collateral:      number   // USDC (6 dec → USD float)
  size:            number   // USDC notional (USD float)
  entryPrice:      number   // USD (1e18 → USD float)
  leverage:        number
  unrealisedPnl:   number   // USD
  pnlPercent:      number   // %
}

// ──────────────────────────────────────────────────────────────────────────────
// Subgraph GraphQL query — used when NEXT_PUBLIC_SUBGRAPH_URL is set
// ──────────────────────────────────────────────────────────────────────────────

const SUBGRAPH_URL = process.env.NEXT_PUBLIC_SUBGRAPH_URL ?? ''

const POSITIONS_QUERY = `
  query OpenPositions($trader: Bytes!) {
    positions(
      where: { trader: $trader, isOpen: true }
      orderBy: openTimestamp
      orderDirection: desc
      first: 100
    ) {
      id
      trader
      asset
      collateralToken
      isLong
      size
      collateral
      entryPrice
      openTimestamp
    }
  }
`

interface SubgraphPosition {
  id:              string
  trader:          string
  asset:           string
  collateralToken: string
  isLong:          boolean
  size:            string   // BigInt as string from GraphQL
  collateral:      string
  entryPrice:      string
  openTimestamp:   string
}

async function fetchPositionsFromSubgraph(trader: string): Promise<SubgraphPosition[]> {
  const res = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      query: POSITIONS_QUERY,
      variables: { trader: trader.toLowerCase() },
    }),
  })
  const json = await res.json()
  return (json?.data?.positions ?? []) as SubgraphPosition[]
}

// ──────────────────────────────────────────────────────────────────────────────
// Fallback: on-chain getLogs + multicall (used before subgraph is deployed)
// ──────────────────────────────────────────────────────────────────────────────

const POSITION_OPENED_EVENT = parseAbiItem(
  'event PositionOpened(bytes32 indexed positionId, address indexed trader, address indexed asset, address collateralToken, uint256 size, uint256 collateral, uint256 entryPrice, bool isLong)'
)

interface PositionTuple {
  trader:             string
  asset:              string
  collateralToken:    string
  size:               bigint
  collateral:         bigint
  entryPrice:         bigint
  fundingIndexAtOpen: bigint
  openBlock:          bigint
  openTimestamp:      bigint
  isLong:             boolean
  open:               boolean
}

// ──────────────────────────────────────────────────────────────────────────────
// Shared builder: raw numbers → Position interface
// ──────────────────────────────────────────────────────────────────────────────

function buildPosition(
  positionId: `0x${string}`,
  trader: string,
  asset: string,
  collateralToken: string,
  isLong: boolean,
  rawSize: bigint,
  rawCollateral: bigint,
  rawEntryPrice: bigint,
  currentMark: number,
): Position {
  const collateral = Number(rawCollateral) / 1e6
  const size       = Number(rawSize)       / 1e6
  const entryPrice = Number(rawEntryPrice) / 1e18
  const leverage   = collateral > 0 ? size / collateral : 0

  const priceDelta    = entryPrice > 0 ? (currentMark - entryPrice) / entryPrice : 0
  const unrealisedPnl = isLong ? size * priceDelta : -size * priceDelta
  const pnlPercent    = collateral > 0 ? (unrealisedPnl / collateral) * 100 : 0

  return {
    positionId, trader, asset, collateralToken, isLong,
    collateral, size, entryPrice, leverage, unrealisedPnl, pnlPercent,
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Hook
// ──────────────────────────────────────────────────────────────────────────────

export function usePositions() {
  const { address } = useAccount()
  const publicClient = usePublicClient()
  const { mark } = useOraclePrices()

  const [positions, setPositions] = useState<Position[]>([])
  const [isLoading, setIsLoading] = useState(false)
  const [source, setSource] = useState<'subgraph' | 'rpc'>('rpc')

  useEffect(() => {
    if (!address) return

    async function refresh() {
      setIsLoading(true)
      const currentMark = mark ?? 0

      try {
        // ── Path A: subgraph ─────────────────────────────────────────────────
        if (SUBGRAPH_URL) {
          const raw = await fetchPositionsFromSubgraph(address!)
          setSource('subgraph')
          setPositions(
            raw.map((p) =>
              buildPosition(
                p.id as `0x${string}`,
                p.trader,
                p.asset,
                p.collateralToken,
                p.isLong,
                BigInt(p.size),
                BigInt(p.collateral),
                BigInt(p.entryPrice),
                currentMark,
              )
            )
          )
          return
        }

        // ── Path B: on-chain getLogs + multicall fallback ────────────────────
        if (!publicClient) return
        setSource('rpc')

        const logs = await publicClient.getLogs({
          address: CONTRACTS.PositionManager as `0x${string}`,
          event: POSITION_OPENED_EVENT,
          args: { trader: address },
          fromBlock: 0n,
        })

        const seen = new Set<string>()
        const positionIds: `0x${string}`[] = []
        for (const log of logs) {
          const id = log.args.positionId as `0x${string}`
          if (!seen.has(id)) { seen.add(id); positionIds.push(id) }
        }

        if (positionIds.length === 0) { setPositions([]); return }

        const results = await publicClient.multicall({
          contracts: positionIds.map((id) => ({
            address: CONTRACTS.PositionManager as `0x${string}`,
            abi: POSITION_MANAGER_ABI,
            functionName: 'getPosition' as const,
            args: [id] as const,
          })),
        })

        const parsed: Position[] = []
        results.forEach((r, i) => {
          if (r.status !== 'success' || !r.result) return
          const pos = r.result as unknown as PositionTuple
          if (!pos.open) return
          parsed.push(buildPosition(
            positionIds[i],
            pos.trader, pos.asset, pos.collateralToken, pos.isLong,
            pos.size, pos.collateral, pos.entryPrice,
            currentMark,
          ))
        })
        setPositions(parsed)

      } catch (e) {
        console.error('usePositions:', e)
      } finally {
        setIsLoading(false)
      }
    }

    refresh()
    const timer = setInterval(refresh, 30_000)
    return () => clearInterval(timer)
  }, [address, publicClient, mark])

  return { positions, isLoading, source }
}
