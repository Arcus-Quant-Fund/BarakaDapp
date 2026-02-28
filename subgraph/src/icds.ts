import { BigInt, Bytes } from '@graphprotocol/graph-ts'
import {
  ProtectionOpened as ProtectionOpenedEvent,
  ProtectionAccepted as ProtectionAcceptedEvent,
  Settled as SettledEvent,
} from '../generated/iCDS/iCDS'
import { ProtectionEvent } from '../generated/schema'

export function handleProtectionOpened(event: ProtectionOpenedEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new ProtectionEvent(id)

  entity.protectionId = event.params.id
  entity.eventType = 'Opened'
  entity.seller = event.params.seller
  entity.buyer = null
  entity.notional = event.params.notional
  entity.payout = null
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}

export function handleProtectionAccepted(event: ProtectionAcceptedEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new ProtectionEvent(id)

  entity.protectionId = event.params.id
  entity.eventType = 'Accepted'
  entity.seller = null
  entity.buyer = event.params.buyer
  entity.notional = null
  entity.payout = null
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}

export function handleSettled(event: SettledEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new ProtectionEvent(id)

  entity.protectionId = event.params.id
  entity.eventType = 'Settled'
  entity.seller = null
  entity.buyer = event.params.buyer
  entity.notional = null
  entity.payout = event.params.payout
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}
