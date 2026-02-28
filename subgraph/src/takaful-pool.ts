import { Bytes, BigInt } from '@graphprotocol/graph-ts'
import {
  ContributionMade as ContributionMadeEvent,
  ClaimPaid as ClaimPaidEvent,
} from '../generated/TakafulPool/TakafulPool'
import { ContributionEvent, ClaimEvent } from '../generated/schema'

export function handleContributionMade(event: ContributionMadeEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new ContributionEvent(id)

  entity.poolId = event.params.poolId as Bytes
  entity.member = event.params.member
  entity.coverage = event.params.coverage
  entity.tabarru = event.params.tabarru
  entity.wakala = event.params.wakala
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}

export function handleClaimPaid(event: ClaimPaidEvent): void {
  const id = event.transaction.hash.concatI32(event.logIndex.toI32())
  const entity = new ClaimEvent(id)

  entity.poolId = event.params.poolId as Bytes
  entity.beneficiary = event.params.beneficiary
  entity.amount = event.params.amount
  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.txHash = event.transaction.hash

  entity.save()
}
