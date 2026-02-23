import { newMockEvent } from "matchstick-as"
import { ethereum, BigInt, Address, Bytes } from "@graphprotocol/graph-ts"
import {
  AppealBondProtocolFeeBpsUpdated,
  ClaimableBalanceSet,
  DisputeAutoCancelled,
  DisputeEscalated,
  DisputeOpened,
  EscrowCreated,
  EscrowResolved,
  EscrowSettingsUpdated,
  EscrowStateChanged,
  EscrowTransferAutoResult,
  EscrowWithdrawn,
  FeesWithdrawn,
  IncidentPauseTriggered,
  OperationFailure,
  PendingSettlementCancelled,
  PendingSettlementExecuted,
  PendingSettlementSet,
  ProtocolFeeCollected,
  ResolutionModuleActivated,
  RoleAdminChanged,
  RoleGranted,
  RoleRevoked,
  SystemResumed,
  TimedActionTriggered,
  TimeoutConfigUpdated,
  YieldProtocolFeeBpsUpdated
} from "../generated/EscrowVault/EscrowVault"

export function createAppealBondProtocolFeeBpsUpdatedEvent(
  oldFeeBps: BigInt,
  newFeeBps: BigInt
): AppealBondProtocolFeeBpsUpdated {
  let appealBondProtocolFeeBpsUpdatedEvent =
    changetype<AppealBondProtocolFeeBpsUpdated>(newMockEvent())

  appealBondProtocolFeeBpsUpdatedEvent.parameters = new Array()

  appealBondProtocolFeeBpsUpdatedEvent.parameters.push(
    new ethereum.EventParam(
      "oldFeeBps",
      ethereum.Value.fromUnsignedBigInt(oldFeeBps)
    )
  )
  appealBondProtocolFeeBpsUpdatedEvent.parameters.push(
    new ethereum.EventParam(
      "newFeeBps",
      ethereum.Value.fromUnsignedBigInt(newFeeBps)
    )
  )

  return appealBondProtocolFeeBpsUpdatedEvent
}

export function createClaimableBalanceSetEvent(
  workflowId: BigInt,
  recipient: Address,
  token: Address,
  amount: BigInt
): ClaimableBalanceSet {
  let claimableBalanceSetEvent = changetype<ClaimableBalanceSet>(newMockEvent())

  claimableBalanceSetEvent.parameters = new Array()

  claimableBalanceSetEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  claimableBalanceSetEvent.parameters.push(
    new ethereum.EventParam("recipient", ethereum.Value.fromAddress(recipient))
  )
  claimableBalanceSetEvent.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(token))
  )
  claimableBalanceSetEvent.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  )

  return claimableBalanceSetEvent
}

export function createDisputeAutoCancelledEvent(
  workflowId: BigInt,
  from: Address,
  amount: BigInt,
  reasonCode: i32
): DisputeAutoCancelled {
  let disputeAutoCancelledEvent =
    changetype<DisputeAutoCancelled>(newMockEvent())

  disputeAutoCancelledEvent.parameters = new Array()

  disputeAutoCancelledEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  disputeAutoCancelledEvent.parameters.push(
    new ethereum.EventParam("from", ethereum.Value.fromAddress(from))
  )
  disputeAutoCancelledEvent.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  )
  disputeAutoCancelledEvent.parameters.push(
    new ethereum.EventParam(
      "reasonCode",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(reasonCode))
    )
  )

  return disputeAutoCancelledEvent
}

export function createDisputeEscalatedEvent(
  workflowId: BigInt,
  fromLevel: i32,
  toLevel: i32,
  newDisputeResolver: Address,
  escalatedBy: Address
): DisputeEscalated {
  let disputeEscalatedEvent = changetype<DisputeEscalated>(newMockEvent())

  disputeEscalatedEvent.parameters = new Array()

  disputeEscalatedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  disputeEscalatedEvent.parameters.push(
    new ethereum.EventParam(
      "fromLevel",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(fromLevel))
    )
  )
  disputeEscalatedEvent.parameters.push(
    new ethereum.EventParam(
      "toLevel",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(toLevel))
    )
  )
  disputeEscalatedEvent.parameters.push(
    new ethereum.EventParam(
      "newDisputeResolver",
      ethereum.Value.fromAddress(newDisputeResolver)
    )
  )
  disputeEscalatedEvent.parameters.push(
    new ethereum.EventParam(
      "escalatedBy",
      ethereum.Value.fromAddress(escalatedBy)
    )
  )

  return disputeEscalatedEvent
}

export function createDisputeOpenedEvent(
  workflowId: BigInt,
  by: Address,
  disputeResolver: Address
): DisputeOpened {
  let disputeOpenedEvent = changetype<DisputeOpened>(newMockEvent())

  disputeOpenedEvent.parameters = new Array()

  disputeOpenedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  disputeOpenedEvent.parameters.push(
    new ethereum.EventParam("by", ethereum.Value.fromAddress(by))
  )
  disputeOpenedEvent.parameters.push(
    new ethereum.EventParam(
      "disputeResolver",
      ethereum.Value.fromAddress(disputeResolver)
    )
  )

  return disputeOpenedEvent
}

export function createEscrowCreatedEvent(
  workflowId: BigInt,
  token: Address,
  from: Address,
  to: Address,
  amount: BigInt,
  amountAfterFee: BigInt,
  fee: BigInt
): EscrowCreated {
  let escrowCreatedEvent = changetype<EscrowCreated>(newMockEvent())

  escrowCreatedEvent.parameters = new Array()

  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(token))
  )
  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam("from", ethereum.Value.fromAddress(from))
  )
  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam("to", ethereum.Value.fromAddress(to))
  )
  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  )
  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam(
      "amountAfterFee",
      ethereum.Value.fromUnsignedBigInt(amountAfterFee)
    )
  )
  escrowCreatedEvent.parameters.push(
    new ethereum.EventParam("fee", ethereum.Value.fromUnsignedBigInt(fee))
  )

  return escrowCreatedEvent
}

export function createEscrowResolvedEvent(
  workflowId: BigInt,
  disputeResolver: Address,
  resolutionHash: Bytes
): EscrowResolved {
  let escrowResolvedEvent = changetype<EscrowResolved>(newMockEvent())

  escrowResolvedEvent.parameters = new Array()

  escrowResolvedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  escrowResolvedEvent.parameters.push(
    new ethereum.EventParam(
      "disputeResolver",
      ethereum.Value.fromAddress(disputeResolver)
    )
  )
  escrowResolvedEvent.parameters.push(
    new ethereum.EventParam(
      "resolutionHash",
      ethereum.Value.fromFixedBytes(resolutionHash)
    )
  )

  return escrowResolvedEvent
}

export function createEscrowSettingsUpdatedEvent(
  workflowId: BigInt,
  settings: ethereum.Tuple
): EscrowSettingsUpdated {
  let escrowSettingsUpdatedEvent =
    changetype<EscrowSettingsUpdated>(newMockEvent())

  escrowSettingsUpdatedEvent.parameters = new Array()

  escrowSettingsUpdatedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  escrowSettingsUpdatedEvent.parameters.push(
    new ethereum.EventParam("settings", ethereum.Value.fromTuple(settings))
  )

  return escrowSettingsUpdatedEvent
}

export function createEscrowStateChangedEvent(
  workflowId: BigInt,
  oldStatus: i32,
  newStatus: i32
): EscrowStateChanged {
  let escrowStateChangedEvent = changetype<EscrowStateChanged>(newMockEvent())

  escrowStateChangedEvent.parameters = new Array()

  escrowStateChangedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  escrowStateChangedEvent.parameters.push(
    new ethereum.EventParam(
      "oldStatus",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(oldStatus))
    )
  )
  escrowStateChangedEvent.parameters.push(
    new ethereum.EventParam(
      "newStatus",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(newStatus))
    )
  )

  return escrowStateChangedEvent
}

export function createEscrowTransferAutoResultEvent(
  workflowId: BigInt,
  recipient: Address,
  token: Address,
  amount: BigInt,
  success: boolean,
  reasonCode: i32
): EscrowTransferAutoResult {
  let escrowTransferAutoResultEvent =
    changetype<EscrowTransferAutoResult>(newMockEvent())

  escrowTransferAutoResultEvent.parameters = new Array()

  escrowTransferAutoResultEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  escrowTransferAutoResultEvent.parameters.push(
    new ethereum.EventParam("recipient", ethereum.Value.fromAddress(recipient))
  )
  escrowTransferAutoResultEvent.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(token))
  )
  escrowTransferAutoResultEvent.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  )
  escrowTransferAutoResultEvent.parameters.push(
    new ethereum.EventParam("success", ethereum.Value.fromBoolean(success))
  )
  escrowTransferAutoResultEvent.parameters.push(
    new ethereum.EventParam(
      "reasonCode",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(reasonCode))
    )
  )

  return escrowTransferAutoResultEvent
}

export function createEscrowWithdrawnEvent(
  workflowId: BigInt,
  recipient: Address,
  token: Address,
  amount: BigInt
): EscrowWithdrawn {
  let escrowWithdrawnEvent = changetype<EscrowWithdrawn>(newMockEvent())

  escrowWithdrawnEvent.parameters = new Array()

  escrowWithdrawnEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  escrowWithdrawnEvent.parameters.push(
    new ethereum.EventParam("recipient", ethereum.Value.fromAddress(recipient))
  )
  escrowWithdrawnEvent.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(token))
  )
  escrowWithdrawnEvent.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  )

  return escrowWithdrawnEvent
}

export function createFeesWithdrawnEvent(
  token: Address,
  amount: BigInt
): FeesWithdrawn {
  let feesWithdrawnEvent = changetype<FeesWithdrawn>(newMockEvent())

  feesWithdrawnEvent.parameters = new Array()

  feesWithdrawnEvent.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(token))
  )
  feesWithdrawnEvent.parameters.push(
    new ethereum.EventParam("amount", ethereum.Value.fromUnsignedBigInt(amount))
  )

  return feesWithdrawnEvent
}

export function createIncidentPauseTriggeredEvent(
  reason: string,
  timestamp: BigInt,
  pauseCycleCount: BigInt
): IncidentPauseTriggered {
  let incidentPauseTriggeredEvent =
    changetype<IncidentPauseTriggered>(newMockEvent())

  incidentPauseTriggeredEvent.parameters = new Array()

  incidentPauseTriggeredEvent.parameters.push(
    new ethereum.EventParam("reason", ethereum.Value.fromString(reason))
  )
  incidentPauseTriggeredEvent.parameters.push(
    new ethereum.EventParam(
      "timestamp",
      ethereum.Value.fromUnsignedBigInt(timestamp)
    )
  )
  incidentPauseTriggeredEvent.parameters.push(
    new ethereum.EventParam(
      "pauseCycleCount",
      ethereum.Value.fromUnsignedBigInt(pauseCycleCount)
    )
  )

  return incidentPauseTriggeredEvent
}

export function createOperationFailureEvent(
  op: i32,
  workflowId: BigInt,
  target: Address,
  selector: Bytes,
  reasonCode: i32
): OperationFailure {
  let operationFailureEvent = changetype<OperationFailure>(newMockEvent())

  operationFailureEvent.parameters = new Array()

  operationFailureEvent.parameters.push(
    new ethereum.EventParam(
      "op",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(op))
    )
  )
  operationFailureEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  operationFailureEvent.parameters.push(
    new ethereum.EventParam("target", ethereum.Value.fromAddress(target))
  )
  operationFailureEvent.parameters.push(
    new ethereum.EventParam("selector", ethereum.Value.fromFixedBytes(selector))
  )
  operationFailureEvent.parameters.push(
    new ethereum.EventParam(
      "reasonCode",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(reasonCode))
    )
  )

  return operationFailureEvent
}

export function createPendingSettlementCancelledEvent(
  workflowId: BigInt
): PendingSettlementCancelled {
  let pendingSettlementCancelledEvent =
    changetype<PendingSettlementCancelled>(newMockEvent())

  pendingSettlementCancelledEvent.parameters = new Array()

  pendingSettlementCancelledEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )

  return pendingSettlementCancelledEvent
}

export function createPendingSettlementExecutedEvent(
  workflowId: BigInt,
  isRelease: boolean
): PendingSettlementExecuted {
  let pendingSettlementExecutedEvent =
    changetype<PendingSettlementExecuted>(newMockEvent())

  pendingSettlementExecutedEvent.parameters = new Array()

  pendingSettlementExecutedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  pendingSettlementExecutedEvent.parameters.push(
    new ethereum.EventParam("isRelease", ethereum.Value.fromBoolean(isRelease))
  )

  return pendingSettlementExecutedEvent
}

export function createPendingSettlementSetEvent(
  workflowId: BigInt,
  isRelease: boolean,
  appealDeadline: BigInt
): PendingSettlementSet {
  let pendingSettlementSetEvent =
    changetype<PendingSettlementSet>(newMockEvent())

  pendingSettlementSetEvent.parameters = new Array()

  pendingSettlementSetEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  pendingSettlementSetEvent.parameters.push(
    new ethereum.EventParam("isRelease", ethereum.Value.fromBoolean(isRelease))
  )
  pendingSettlementSetEvent.parameters.push(
    new ethereum.EventParam(
      "appealDeadline",
      ethereum.Value.fromUnsignedBigInt(appealDeadline)
    )
  )

  return pendingSettlementSetEvent
}

export function createProtocolFeeCollectedEvent(
  kind: i32,
  workflowId: BigInt,
  token: Address,
  grossAmount: BigInt,
  feeBps: BigInt,
  feeAmount: BigInt
): ProtocolFeeCollected {
  let protocolFeeCollectedEvent =
    changetype<ProtocolFeeCollected>(newMockEvent())

  protocolFeeCollectedEvent.parameters = new Array()

  protocolFeeCollectedEvent.parameters.push(
    new ethereum.EventParam(
      "kind",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(kind))
    )
  )
  protocolFeeCollectedEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  protocolFeeCollectedEvent.parameters.push(
    new ethereum.EventParam("token", ethereum.Value.fromAddress(token))
  )
  protocolFeeCollectedEvent.parameters.push(
    new ethereum.EventParam(
      "grossAmount",
      ethereum.Value.fromUnsignedBigInt(grossAmount)
    )
  )
  protocolFeeCollectedEvent.parameters.push(
    new ethereum.EventParam("feeBps", ethereum.Value.fromUnsignedBigInt(feeBps))
  )
  protocolFeeCollectedEvent.parameters.push(
    new ethereum.EventParam(
      "feeAmount",
      ethereum.Value.fromUnsignedBigInt(feeAmount)
    )
  )

  return protocolFeeCollectedEvent
}

export function createResolutionModuleActivatedEvent(
  oldModule: Address,
  newModule: Address
): ResolutionModuleActivated {
  let resolutionModuleActivatedEvent =
    changetype<ResolutionModuleActivated>(newMockEvent())

  resolutionModuleActivatedEvent.parameters = new Array()

  resolutionModuleActivatedEvent.parameters.push(
    new ethereum.EventParam("oldModule", ethereum.Value.fromAddress(oldModule))
  )
  resolutionModuleActivatedEvent.parameters.push(
    new ethereum.EventParam("newModule", ethereum.Value.fromAddress(newModule))
  )

  return resolutionModuleActivatedEvent
}

export function createRoleAdminChangedEvent(
  role: Bytes,
  previousAdminRole: Bytes,
  newAdminRole: Bytes
): RoleAdminChanged {
  let roleAdminChangedEvent = changetype<RoleAdminChanged>(newMockEvent())

  roleAdminChangedEvent.parameters = new Array()

  roleAdminChangedEvent.parameters.push(
    new ethereum.EventParam("role", ethereum.Value.fromFixedBytes(role))
  )
  roleAdminChangedEvent.parameters.push(
    new ethereum.EventParam(
      "previousAdminRole",
      ethereum.Value.fromFixedBytes(previousAdminRole)
    )
  )
  roleAdminChangedEvent.parameters.push(
    new ethereum.EventParam(
      "newAdminRole",
      ethereum.Value.fromFixedBytes(newAdminRole)
    )
  )

  return roleAdminChangedEvent
}

export function createRoleGrantedEvent(
  role: Bytes,
  account: Address,
  sender: Address
): RoleGranted {
  let roleGrantedEvent = changetype<RoleGranted>(newMockEvent())

  roleGrantedEvent.parameters = new Array()

  roleGrantedEvent.parameters.push(
    new ethereum.EventParam("role", ethereum.Value.fromFixedBytes(role))
  )
  roleGrantedEvent.parameters.push(
    new ethereum.EventParam("account", ethereum.Value.fromAddress(account))
  )
  roleGrantedEvent.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  )

  return roleGrantedEvent
}

export function createRoleRevokedEvent(
  role: Bytes,
  account: Address,
  sender: Address
): RoleRevoked {
  let roleRevokedEvent = changetype<RoleRevoked>(newMockEvent())

  roleRevokedEvent.parameters = new Array()

  roleRevokedEvent.parameters.push(
    new ethereum.EventParam("role", ethereum.Value.fromFixedBytes(role))
  )
  roleRevokedEvent.parameters.push(
    new ethereum.EventParam("account", ethereum.Value.fromAddress(account))
  )
  roleRevokedEvent.parameters.push(
    new ethereum.EventParam("sender", ethereum.Value.fromAddress(sender))
  )

  return roleRevokedEvent
}

export function createSystemResumedEvent(timestamp: BigInt): SystemResumed {
  let systemResumedEvent = changetype<SystemResumed>(newMockEvent())

  systemResumedEvent.parameters = new Array()

  systemResumedEvent.parameters.push(
    new ethereum.EventParam(
      "timestamp",
      ethereum.Value.fromUnsignedBigInt(timestamp)
    )
  )

  return systemResumedEvent
}

export function createTimedActionTriggeredEvent(
  workflowId: BigInt,
  actionType: i32,
  source: i32,
  executor: Address
): TimedActionTriggered {
  let timedActionTriggeredEvent =
    changetype<TimedActionTriggered>(newMockEvent())

  timedActionTriggeredEvent.parameters = new Array()

  timedActionTriggeredEvent.parameters.push(
    new ethereum.EventParam(
      "workflowId",
      ethereum.Value.fromUnsignedBigInt(workflowId)
    )
  )
  timedActionTriggeredEvent.parameters.push(
    new ethereum.EventParam(
      "actionType",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(actionType))
    )
  )
  timedActionTriggeredEvent.parameters.push(
    new ethereum.EventParam(
      "source",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(source))
    )
  )
  timedActionTriggeredEvent.parameters.push(
    new ethereum.EventParam("executor", ethereum.Value.fromAddress(executor))
  )

  return timedActionTriggeredEvent
}

export function createTimeoutConfigUpdatedEvent(
  config: ethereum.Tuple
): TimeoutConfigUpdated {
  let timeoutConfigUpdatedEvent =
    changetype<TimeoutConfigUpdated>(newMockEvent())

  timeoutConfigUpdatedEvent.parameters = new Array()

  timeoutConfigUpdatedEvent.parameters.push(
    new ethereum.EventParam("config", ethereum.Value.fromTuple(config))
  )

  return timeoutConfigUpdatedEvent
}

export function createYieldProtocolFeeBpsUpdatedEvent(
  oldFeeBps: BigInt,
  newFeeBps: BigInt
): YieldProtocolFeeBpsUpdated {
  let yieldProtocolFeeBpsUpdatedEvent =
    changetype<YieldProtocolFeeBpsUpdated>(newMockEvent())

  yieldProtocolFeeBpsUpdatedEvent.parameters = new Array()

  yieldProtocolFeeBpsUpdatedEvent.parameters.push(
    new ethereum.EventParam(
      "oldFeeBps",
      ethereum.Value.fromUnsignedBigInt(oldFeeBps)
    )
  )
  yieldProtocolFeeBpsUpdatedEvent.parameters.push(
    new ethereum.EventParam(
      "newFeeBps",
      ethereum.Value.fromUnsignedBigInt(newFeeBps)
    )
  )

  return yieldProtocolFeeBpsUpdatedEvent
}
