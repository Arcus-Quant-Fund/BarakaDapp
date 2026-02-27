import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  FundingRateUpdated as FundingRateUpdatedEvent,
} from "../generated/FundingEngine/FundingEngine"
import { FundingRateSnapshot, MarketStats } from "../generated/schema"

export function handleFundingRateUpdated(event: FundingRateUpdatedEvent): void {
  let market = event.params.market

  // ID = market address + block timestamp (unique per funding interval)
  let snapshotId = market.concatI32(event.block.timestamp.toI32())
  let snapshot = new FundingRateSnapshot(snapshotId)
  snapshot.market      = market
  snapshot.fundingRate = event.params.fundingRate
  snapshot.markPrice   = event.params.markPrice
  snapshot.indexPrice  = event.params.indexPrice
  // premium = markPrice - indexPrice (signed: positive when mark > index)
  snapshot.premium     = event.params.markPrice.minus(event.params.indexPrice)
  snapshot.timestamp   = event.block.timestamp
  snapshot.blockNumber = event.block.number
  snapshot.save()

  // Update market's last known funding rate
  let marketStats = MarketStats.load(market)
  if (marketStats != null) {
    marketStats.lastFundingRate = event.params.fundingRate
    marketStats.lastUpdated     = event.block.timestamp
    marketStats.save()
  }
}
