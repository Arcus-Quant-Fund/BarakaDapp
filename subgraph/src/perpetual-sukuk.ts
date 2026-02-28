import { BigInt } from '@graphprotocol/graph-ts'
import {
  Subscribed as SubscribedEvent,
  ProfitClaimed as ProfitClaimedEvent,
  Redeemed as RedeemedEvent,
} from '../generated/PerpetualSukuk/PerpetualSukuk'
import { SukukSubscription, SukukProfit } from '../generated/schema'

export function handleSubscribed(event: SubscribedEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new SukukSubscription(id)

  entity.sukukId = event.params.id
  entity.investor = event.params.investor
  entity.amount = event.params.amount
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}

export function handleProfitClaimed(event: ProfitClaimedEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new SukukProfit(id)

  entity.sukukId = event.params.id
  entity.investor = event.params.investor
  entity.profit = event.params.profit
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}

export function handleRedeemed(event: RedeemedEvent): void {
  // Redemption = principal return; record as a profit with amount = principal + callUpside
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new SukukProfit(id)

  entity.sukukId = event.params.id
  entity.investor = event.params.investor
  entity.profit = event.params.principal.plus(event.params.callUpside)
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}
