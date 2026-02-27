import { BigInt } from "@graphprotocol/graph-ts"
import {
  Liquidated as LiquidatedEvent,
} from "../generated/LiquidationEngine/LiquidationEngine"
import {
  LiquidationEvent,
  Trade,
  Position,
  MarketStats,
  Protocol,
} from "../generated/schema"

function loadOrCreateProtocol(): Protocol {
  let protocol = Protocol.load("baraka")
  if (protocol == null) {
    protocol = new Protocol("baraka")
    protocol.totalDeposited    = BigInt.zero()
    protocol.totalWithdrawn    = BigInt.zero()
    protocol.totalPositions    = BigInt.zero()
    protocol.openPositions     = BigInt.zero()
    protocol.totalTrades       = BigInt.zero()
    protocol.totalLiquidations = BigInt.zero()
    protocol.totalVolume       = BigInt.zero()
    protocol.lastUpdated       = BigInt.zero()
  }
  return protocol!
}

export function handleLiquidated(event: LiquidatedEvent): void {
  let posId = event.params.positionId

  // ── 1. Create immutable LiquidationEvent record ──────────────────
  let liqId = event.transaction.hash.concatI32(event.logIndex.toI32())
  let liqEvent = new LiquidationEvent(liqId)
  liqEvent.position       = posId
  liqEvent.liquidator     = event.params.liquidator
  liqEvent.trader         = event.params.trader
  liqEvent.penalty        = event.params.penalty
  liqEvent.liquidatorShare = event.params.liquidatorShare
  liqEvent.insuranceShare = event.params.insuranceShare
  liqEvent.timestamp      = event.block.timestamp
  liqEvent.blockNumber    = event.block.number
  liqEvent.txHash         = event.transaction.hash
  liqEvent.save()

  // ── 2. Create immutable Trade record (action = "LIQUIDATE") ──────
  let tradeId = event.transaction.hash.concatI32(event.logIndex.toI32() + 1)
  let trade = new Trade(tradeId)
  trade.position    = posId
  trade.trader      = event.params.trader
  trade.action      = "LIQUIDATE"
  trade.realizedPnl = null
  trade.timestamp   = event.block.timestamp
  trade.blockNumber = event.block.number
  trade.txHash      = event.transaction.hash

  // Fill asset/size/price from existing Position if available
  let position = Position.load(posId)
  if (position != null) {
    trade.asset  = position.asset
    trade.size   = position.size
    trade.price  = position.entryPrice   // best available price at liquidation
  } else {
    // Orphan liquidation — fill with zero placeholders so the record is valid
    trade.asset  = event.params.liquidator   // placeholder bytes (shouldn't happen)
    trade.size   = BigInt.zero()
    trade.price  = BigInt.zero()
  }
  trade.save()

  // ── 3. Update Position entity ─────────────────────────────────────
  if (position != null) {
    position.isOpen         = false
    position.isLiquidated   = true
    position.closeTimestamp = event.block.timestamp
    // exitPrice and realizedPnl are unknown from this event; leave as-is (null)
    position.save()

    // ── 4. Update MarketStats ─────────────────────────────────────
    let market = MarketStats.load(position.asset)
    if (market != null) {
      if (position.isLong) {
        market.totalLongs = market.totalLongs.minus(position.size)
        if (market.totalLongs.lt(BigInt.zero())) market.totalLongs = BigInt.zero()
      } else {
        market.totalShorts = market.totalShorts.minus(position.size)
        if (market.totalShorts.lt(BigInt.zero())) market.totalShorts = BigInt.zero()
      }
      market.openInterest      = market.totalLongs.plus(market.totalShorts)
      market.totalLiquidations = market.totalLiquidations.plus(BigInt.fromI32(1))
      market.lastUpdated       = event.block.timestamp
      market.save()
    }
  }

  // ── 5. Update Protocol singleton ─────────────────────────────────
  let protocol = loadOrCreateProtocol()
  protocol.openPositions     = protocol.openPositions.minus(BigInt.fromI32(1))
  if (protocol.openPositions.lt(BigInt.zero())) protocol.openPositions = BigInt.zero()
  protocol.totalLiquidations = protocol.totalLiquidations.plus(BigInt.fromI32(1))
  protocol.lastUpdated       = event.block.timestamp
  protocol.save()
}
