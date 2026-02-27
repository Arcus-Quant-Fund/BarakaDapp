import { BigInt } from "@graphprotocol/graph-ts"
import {
  Deposited as DepositedEvent,
  Withdrawn as WithdrawnEvent,
} from "../generated/CollateralVault/CollateralVault"
import { DepositEvent, WithdrawEvent, Protocol } from "../generated/schema"

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

export function handleDeposited(event: DepositedEvent): void {
  let id = event.transaction.hash.concatI32(event.logIndex.toI32())
  let deposit = new DepositEvent(id)
  deposit.user        = event.params.user
  deposit.token       = event.params.token
  deposit.amount      = event.params.amount
  deposit.timestamp   = event.block.timestamp
  deposit.blockNumber = event.block.number
  deposit.txHash      = event.transaction.hash
  deposit.save()

  let protocol = loadOrCreateProtocol()
  protocol.totalDeposited = protocol.totalDeposited.plus(event.params.amount)
  protocol.lastUpdated    = event.block.timestamp
  protocol.save()
}

export function handleWithdrawn(event: WithdrawnEvent): void {
  let id = event.transaction.hash.concatI32(event.logIndex.toI32())
  let withdrawal = new WithdrawEvent(id)
  withdrawal.user        = event.params.user
  withdrawal.token       = event.params.token
  withdrawal.amount      = event.params.amount
  withdrawal.timestamp   = event.block.timestamp
  withdrawal.blockNumber = event.block.number
  withdrawal.txHash      = event.transaction.hash
  withdrawal.save()

  let protocol = loadOrCreateProtocol()
  protocol.totalWithdrawn = protocol.totalWithdrawn.plus(event.params.amount)
  protocol.lastUpdated    = event.block.timestamp
  protocol.save()
}
