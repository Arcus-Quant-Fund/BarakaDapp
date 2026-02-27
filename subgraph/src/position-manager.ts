import { BigInt, Bytes, crypto, ByteArray } from "@graphprotocol/graph-ts"
import {
  PositionOpened as PositionOpenedEvent,
  PositionClosed as PositionClosedEvent,
  FundingSettled as FundingSettledEvent,
} from "../generated/PositionManager/PositionManager"
import {
  Position,
  Trade,
  FundingSettlement,
  MarketStats,
  Protocol,
} from "../generated/schema"

// ─────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────

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

function loadOrCreateMarket(asset: Bytes, timestamp: BigInt): MarketStats {
  let market = MarketStats.load(asset)
  if (market == null) {
    market = new MarketStats(asset)
    market.totalLongs        = BigInt.zero()
    market.totalShorts       = BigInt.zero()
    market.openInterest      = BigInt.zero()
    market.totalVolume       = BigInt.zero()
    market.totalTrades       = BigInt.zero()
    market.totalLiquidations = BigInt.zero()
    market.lastFundingRate   = BigInt.zero()
    market.lastUpdated       = timestamp
  }
  return market!
}

// ─────────────────────────────────────────────────────────
// PositionOpened
// ─────────────────────────────────────────────────────────

export function handlePositionOpened(event: PositionOpenedEvent): void {
  let posId = event.params.positionId

  // Create Position entity
  let position = new Position(posId)
  position.trader          = event.params.trader
  position.asset           = event.params.asset
  position.collateralToken = event.params.collateralToken
  position.isLong          = event.params.isLong
  position.size            = event.params.size
  position.collateral      = event.params.collateral
  position.entryPrice      = event.params.entryPrice
  position.openBlock       = event.block.number
  position.openTimestamp   = event.block.timestamp
  position.closeTimestamp  = null
  position.exitPrice       = null
  position.realizedPnl     = null
  position.totalFundingPaid = BigInt.zero()
  position.isOpen          = true
  position.isLiquidated    = false
  position.save()

  // Create immutable Trade record
  let tradeId = event.transaction.hash.concatI32(event.logIndex.toI32())
  let trade = new Trade(tradeId)
  trade.position    = posId
  trade.trader      = event.params.trader
  trade.asset       = event.params.asset
  trade.action      = "OPEN"
  trade.size        = event.params.size
  trade.price       = event.params.entryPrice
  trade.realizedPnl = null
  trade.timestamp   = event.block.timestamp
  trade.blockNumber = event.block.number
  trade.txHash      = event.transaction.hash
  trade.save()

  // Update MarketStats
  let market = loadOrCreateMarket(event.params.asset, event.block.timestamp)
  if (event.params.isLong) {
    market.totalLongs = market.totalLongs.plus(event.params.size)
  } else {
    market.totalShorts = market.totalShorts.plus(event.params.size)
  }
  market.openInterest = market.totalLongs.plus(market.totalShorts)
  market.totalVolume  = market.totalVolume.plus(event.params.size)
  market.totalTrades  = market.totalTrades.plus(BigInt.fromI32(1))
  market.lastUpdated  = event.block.timestamp
  market.save()

  // Update Protocol
  let protocol = loadOrCreateProtocol()
  protocol.totalPositions = protocol.totalPositions.plus(BigInt.fromI32(1))
  protocol.openPositions  = protocol.openPositions.plus(BigInt.fromI32(1))
  protocol.totalTrades    = protocol.totalTrades.plus(BigInt.fromI32(1))
  protocol.totalVolume    = protocol.totalVolume.plus(event.params.size)
  protocol.lastUpdated    = event.block.timestamp
  protocol.save()
}

// ─────────────────────────────────────────────────────────
// PositionClosed
// ─────────────────────────────────────────────────────────

export function handlePositionClosed(event: PositionClosedEvent): void {
  let posId = event.params.positionId

  let position = Position.load(posId)
  if (position == null) return // orphan event — ignore

  // Update position
  position.isOpen         = false
  position.closeTimestamp = event.block.timestamp
  position.exitPrice      = event.params.exitPrice
  position.realizedPnl    = event.params.realizedPnl
  position.save()

  // Create immutable Trade record
  let tradeId = event.transaction.hash.concatI32(event.logIndex.toI32())
  let trade = new Trade(tradeId)
  trade.position    = posId
  trade.trader      = event.params.trader
  trade.asset       = position.asset
  trade.action      = "CLOSE"
  trade.size        = position.size
  trade.price       = event.params.exitPrice
  trade.realizedPnl = event.params.realizedPnl
  trade.timestamp   = event.block.timestamp
  trade.blockNumber = event.block.number
  trade.txHash      = event.transaction.hash
  trade.save()

  // Update MarketStats
  let market = MarketStats.load(position.asset)
  if (market != null) {
    if (position.isLong) {
      market.totalLongs = market.totalLongs.minus(position.size)
      if (market.totalLongs.lt(BigInt.zero())) market.totalLongs = BigInt.zero()
    } else {
      market.totalShorts = market.totalShorts.minus(position.size)
      if (market.totalShorts.lt(BigInt.zero())) market.totalShorts = BigInt.zero()
    }
    market.openInterest = market.totalLongs.plus(market.totalShorts)
    market.lastUpdated  = event.block.timestamp
    market.save()
  }

  // Update Protocol
  let protocol = loadOrCreateProtocol()
  protocol.openPositions = protocol.openPositions.minus(BigInt.fromI32(1))
  if (protocol.openPositions.lt(BigInt.zero())) protocol.openPositions = BigInt.zero()
  protocol.totalTrades = protocol.totalTrades.plus(BigInt.fromI32(1))
  protocol.lastUpdated = event.block.timestamp
  protocol.save()
}

// ─────────────────────────────────────────────────────────
// FundingSettled
// ─────────────────────────────────────────────────────────

export function handleFundingSettled(event: FundingSettledEvent): void {
  let posId = event.params.positionId

  let position = Position.load(posId)
  if (position == null) return

  // Update collateral on Position
  position.collateral       = event.params.newCollateral
  position.totalFundingPaid = position.totalFundingPaid.plus(event.params.fundingPayment)
  position.save()

  // Create immutable FundingSettlement record
  let settlementId = posId.concatI32(event.logIndex.toI32()).concat(event.transaction.hash)
  let settlement = new FundingSettlement(settlementId)
  settlement.position       = posId
  settlement.fundingPayment = event.params.fundingPayment
  settlement.newCollateral  = event.params.newCollateral
  settlement.timestamp      = event.block.timestamp
  settlement.blockNumber    = event.block.number
  settlement.txHash         = event.transaction.hash
  settlement.save()
}
