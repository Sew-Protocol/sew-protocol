import { log, BigInt } from "@graphprotocol/graph-ts"
import {
  EscrowVault,
  EscrowCreated,
  EscrowStateChanged,
  EscrowWithdrawn,
  DisputeOpened,
  DisputeEscalated,
  EscrowResolved,
  ProtocolFeeCollected,
  TimedActionTriggered,
  ClaimableBalanceSet,
  PendingSettlementSet,
  PendingSettlementExecuted,
  DisputeAutoCancelled
} from "../generated/EscrowVault/EscrowVault"
import {
  Escrow,
  EscrowStateChange,
  EscrowWithdrawal,
  Dispute,
  DisputeEscalation,
  Resolution,
  ProtocolFee,
  TimedAction,
  ClaimableBalance,
  PendingSettlement
} from "../generated/schema"

function getEscrowState(state: u8): string {
  if (state === 0) return "NONE"
  if (state === 1) return "PENDING"
  if (state === 2) return "RELEASED"
  if (state === 3) return "REFUNDED"
  if (state === 4) return "DISPUTED"
  if (state === 5) return "RESOLVED"
  return "NONE"
}

export function handleEscrowCreated(event: EscrowCreated): void {
  let escrow = new Escrow(event.params.workflowId.toString())
  escrow.token = event.params.token
  escrow.sender = event.params.from
  escrow.recipient = event.params.to
  escrow.amountAfterFee = event.params.amountAfterFee
  escrow.fee = event.params.fee
  escrow.state = "PENDING"
  escrow.autoReleaseTime = BigInt.fromU64(0)
  escrow.autoCancelTime = BigInt.fromU64(0)
  escrow.createdAt = event.block.timestamp
  escrow.save()
}

export function handleEscrowStateChanged(event: EscrowStateChanged): void {
  let id = event.params.workflowId.toString()
  let escrow = Escrow.load(id)
  if (!escrow) return

  let fromState = getEscrowState(event.params.oldStatus as u8)
  let toState = getEscrowState(event.params.newStatus as u8)

  escrow.state = toState

  if (toState === "RELEASED") {
    escrow.releasedAt = event.block.timestamp
  } else if (toState === "REFUNDED") {
    escrow.refundedAt = event.block.timestamp
  } else if (toState === "DISPUTED") {
    escrow.disputedAt = event.block.timestamp
  } else if (toState === "RESOLVED") {
    escrow.resolvedAt = event.block.timestamp
  }

  escrow.save()

  let stateChange = new EscrowStateChange(
    id + "-" + event.transaction.hash.toHexString()
  )
  stateChange.workflowId = event.params.workflowId
  stateChange.fromState = fromState
  stateChange.toState = toState
  stateChange.transactionHash = event.transaction.hash
  stateChange.timestamp = event.block.timestamp
  stateChange.blockNumber = event.block.number
  stateChange.save()
}

export function handleEscrowWithdrawn(event: EscrowWithdrawn): void {
  let withdrawal = new EscrowWithdrawal(
    event.params.workflowId.toString() + "-" + event.logIndex.toString()
  )
  withdrawal.workflowId = event.params.workflowId
  withdrawal.recipient = event.params.recipient
  withdrawal.token = event.params.token
  withdrawal.amount = event.params.amount
  withdrawal.transactionHash = event.transaction.hash
  withdrawal.timestamp = event.block.timestamp
  withdrawal.blockNumber = event.block.number
  withdrawal.save()
}

export function handleDisputeOpened(event: DisputeOpened): void {
  let id = event.params.workflowId.toString()
  let escrow = Escrow.load(id)
  if (!escrow) return

  escrow.disputeResolver = event.params.disputeResolver
  escrow.save()

  let dispute = new Dispute(id)
  dispute.escrow = id
  dispute.resolver = event.params.disputeResolver
  dispute.raisedBy = event.params.by
  dispute.raisedAt = event.block.timestamp
  dispute.escalated = false
  dispute.save()
}

export function handleDisputeEscalated(event: DisputeEscalated): void {
  let id = event.params.workflowId.toString()
  let dispute = Dispute.load(id)
  if (!dispute) return

  dispute.escalated = true
  dispute.escalationLevel = event.params.toLevel
  dispute.save()

  let escalation = new DisputeEscalation(
    id + "-" + event.transaction.hash.toHexString()
  )
  escalation.dispute = id
  escalation.fromLevel = event.params.fromLevel
  escalation.toLevel = event.params.toLevel
  escalation.newResolver = event.params.newDisputeResolver
  escalation.escalatedBy = event.params.escalatedBy
  escalation.timestamp = event.block.timestamp
  escalation.transactionHash = event.transaction.hash
  escalation.save()
}

export function handleEscrowResolved(event: EscrowResolved): void {
  let id = event.params.workflowId.toString()
  let escrow = Escrow.load(id)
  if (!escrow) return

  let dispute = Dispute.load(id)
  if (dispute) {
    dispute.resolvedAt = event.block.timestamp
    dispute.resolutionHash = event.params.resolutionHash
    dispute.save()
  }

  let resolution = new Resolution(id)
  resolution.escrow = id
  resolution.resolver = event.params.disputeResolver
  resolution.isRelease = true
  resolution.resolutionHash = event.params.resolutionHash
  resolution.timestamp = event.block.timestamp
  resolution.save()
}

export function handleProtocolFeeCollected(event: ProtocolFeeCollected): void {
  let fee = new ProtocolFee(
    event.params.workflowId.toString() + "-" + event.params.kind.toString()
  )
  fee.kind = event.params.kind
  fee.workflowId = event.params.workflowId
  fee.token = event.params.token
  fee.grossAmount = event.params.grossAmount
  fee.feeBps = event.params.feeBps
  fee.feeAmount = event.params.feeAmount
  fee.timestamp = event.block.timestamp
  fee.transactionHash = event.transaction.hash
  fee.save()
}

export function handleTimedActionTriggered(event: TimedActionTriggered): void {
  let action = new TimedAction(
    event.params.workflowId.toString() + "-" + event.logIndex.toString()
  )
  action.workflowId = event.params.workflowId
  action.actionType = event.params.actionType
  action.source = event.params.source
  action.executor = event.params.executor
  action.timestamp = event.block.timestamp
  action.transactionHash = event.transaction.hash
  action.save()
}

export function handleClaimableBalanceSet(event: ClaimableBalanceSet): void {
  let balance = new ClaimableBalance(
    event.params.workflowId.toString() + "-" + event.params.recipient.toHexString() + "-" + event.logIndex.toString()
  )
  balance.workflowId = event.params.workflowId
  balance.recipient = event.params.recipient
  balance.token = event.params.token
  balance.amount = event.params.amount
  balance.timestamp = event.block.timestamp
  balance.transactionHash = event.transaction.hash
  balance.save()
}

export function handlePendingSettlementSet(event: PendingSettlementSet): void {
  let settlement = new PendingSettlement(event.params.workflowId.toString())
  settlement.workflowId = event.params.workflowId
  settlement.isRelease = event.params.isRelease
  settlement.appealDeadline = event.params.appealDeadline
  settlement.timestamp = event.block.timestamp
  settlement.transactionHash = event.transaction.hash
  settlement.save()
}

export function handlePendingSettlementExecuted(event: PendingSettlementExecuted): void {
  // Settlement executed - entity can be deleted or marked as executed
  // For now just log it
}

export function handleDisputeAutoCancelled(event: DisputeAutoCancelled): void {
  // Auto-cancel handled by EscrowStateChanged
}
