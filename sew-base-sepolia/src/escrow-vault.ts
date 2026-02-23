import {
  AppealBondProtocolFeeBpsUpdated as AppealBondProtocolFeeBpsUpdatedEvent,
  ClaimableBalanceSet as ClaimableBalanceSetEvent,
  DisputeAutoCancelled as DisputeAutoCancelledEvent,
  DisputeEscalated as DisputeEscalatedEvent,
  DisputeOpened as DisputeOpenedEvent,
  EscrowCreated as EscrowCreatedEvent,
  EscrowResolved as EscrowResolvedEvent,
  EscrowSettingsUpdated as EscrowSettingsUpdatedEvent,
  EscrowStateChanged as EscrowStateChangedEvent,
  EscrowTransferAutoResult as EscrowTransferAutoResultEvent,
  EscrowWithdrawn as EscrowWithdrawnEvent,
  FeesWithdrawn as FeesWithdrawnEvent,
  IncidentPauseTriggered as IncidentPauseTriggeredEvent,
  OperationFailure as OperationFailureEvent,
  PendingSettlementCancelled as PendingSettlementCancelledEvent,
  PendingSettlementExecuted as PendingSettlementExecutedEvent,
  PendingSettlementSet as PendingSettlementSetEvent,
  ProtocolFeeCollected as ProtocolFeeCollectedEvent,
  ResolutionModuleActivated as ResolutionModuleActivatedEvent,
  RoleAdminChanged as RoleAdminChangedEvent,
  RoleGranted as RoleGrantedEvent,
  RoleRevoked as RoleRevokedEvent,
  SystemResumed as SystemResumedEvent,
  TimedActionTriggered as TimedActionTriggeredEvent,
  TimeoutConfigUpdated as TimeoutConfigUpdatedEvent,
  YieldProtocolFeeBpsUpdated as YieldProtocolFeeBpsUpdatedEvent
} from "../generated/EscrowVault/EscrowVault"
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
} from "../generated/schema"

export function handleAppealBondProtocolFeeBpsUpdated(
  event: AppealBondProtocolFeeBpsUpdatedEvent
): void {
  let entity = new AppealBondProtocolFeeBpsUpdated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.oldFeeBps = event.params.oldFeeBps
  entity.newFeeBps = event.params.newFeeBps

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleClaimableBalanceSet(
  event: ClaimableBalanceSetEvent
): void {
  let entity = new ClaimableBalanceSet(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.recipient = event.params.recipient
  entity.token = event.params.token
  entity.amount = event.params.amount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleDisputeAutoCancelled(
  event: DisputeAutoCancelledEvent
): void {
  let entity = new DisputeAutoCancelled(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.from = event.params.from
  entity.amount = event.params.amount
  entity.reasonCode = event.params.reasonCode

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleDisputeEscalated(event: DisputeEscalatedEvent): void {
  let entity = new DisputeEscalated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.fromLevel = event.params.fromLevel
  entity.toLevel = event.params.toLevel
  entity.newDisputeResolver = event.params.newDisputeResolver
  entity.escalatedBy = event.params.escalatedBy

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleDisputeOpened(event: DisputeOpenedEvent): void {
  let entity = new DisputeOpened(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.by = event.params.by
  entity.disputeResolver = event.params.disputeResolver

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleEscrowCreated(event: EscrowCreatedEvent): void {
  let entity = new EscrowCreated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.token = event.params.token
  entity.from = event.params.from
  entity.to = event.params.to
  entity.amount = event.params.amount
  entity.amountAfterFee = event.params.amountAfterFee
  entity.fee = event.params.fee

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleEscrowResolved(event: EscrowResolvedEvent): void {
  let entity = new EscrowResolved(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.disputeResolver = event.params.disputeResolver
  entity.resolutionHash = event.params.resolutionHash

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleEscrowSettingsUpdated(
  event: EscrowSettingsUpdatedEvent
): void {
  let entity = new EscrowSettingsUpdated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.settings_customResolver = event.params.settings.customResolver
  entity.settings_releaseAddress = event.params.settings.releaseAddress
  entity.settings_yieldPreset = event.params.settings.yieldPreset
  entity.settings_autoReleaseTime = event.params.settings.autoReleaseTime
  entity.settings_autoCancelTime = event.params.settings.autoCancelTime

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleEscrowStateChanged(event: EscrowStateChangedEvent): void {
  let entity = new EscrowStateChanged(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.oldStatus = event.params.oldStatus
  entity.newStatus = event.params.newStatus

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleEscrowTransferAutoResult(
  event: EscrowTransferAutoResultEvent
): void {
  let entity = new EscrowTransferAutoResult(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.recipient = event.params.recipient
  entity.token = event.params.token
  entity.amount = event.params.amount
  entity.success = event.params.success
  entity.reasonCode = event.params.reasonCode

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleEscrowWithdrawn(event: EscrowWithdrawnEvent): void {
  let entity = new EscrowWithdrawn(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.recipient = event.params.recipient
  entity.token = event.params.token
  entity.amount = event.params.amount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleFeesWithdrawn(event: FeesWithdrawnEvent): void {
  let entity = new FeesWithdrawn(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.token = event.params.token
  entity.amount = event.params.amount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleIncidentPauseTriggered(
  event: IncidentPauseTriggeredEvent
): void {
  let entity = new IncidentPauseTriggered(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.reason = event.params.reason
  entity.timestamp = event.params.timestamp
  entity.pauseCycleCount = event.params.pauseCycleCount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleOperationFailure(event: OperationFailureEvent): void {
  let entity = new OperationFailure(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.op = event.params.op
  entity.workflowId = event.params.workflowId
  entity.target = event.params.target
  entity.selector = event.params.selector
  entity.reasonCode = event.params.reasonCode

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handlePendingSettlementCancelled(
  event: PendingSettlementCancelledEvent
): void {
  let entity = new PendingSettlementCancelled(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handlePendingSettlementExecuted(
  event: PendingSettlementExecutedEvent
): void {
  let entity = new PendingSettlementExecuted(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.isRelease = event.params.isRelease

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handlePendingSettlementSet(
  event: PendingSettlementSetEvent
): void {
  let entity = new PendingSettlementSet(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.isRelease = event.params.isRelease
  entity.appealDeadline = event.params.appealDeadline

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleProtocolFeeCollected(
  event: ProtocolFeeCollectedEvent
): void {
  let entity = new ProtocolFeeCollected(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.kind = event.params.kind
  entity.workflowId = event.params.workflowId
  entity.token = event.params.token
  entity.grossAmount = event.params.grossAmount
  entity.feeBps = event.params.feeBps
  entity.feeAmount = event.params.feeAmount

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleResolutionModuleActivated(
  event: ResolutionModuleActivatedEvent
): void {
  let entity = new ResolutionModuleActivated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.oldModule = event.params.oldModule
  entity.newModule = event.params.newModule

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleRoleAdminChanged(event: RoleAdminChangedEvent): void {
  let entity = new RoleAdminChanged(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.role = event.params.role
  entity.previousAdminRole = event.params.previousAdminRole
  entity.newAdminRole = event.params.newAdminRole

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleRoleGranted(event: RoleGrantedEvent): void {
  let entity = new RoleGranted(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.role = event.params.role
  entity.account = event.params.account
  entity.sender = event.params.sender

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleRoleRevoked(event: RoleRevokedEvent): void {
  let entity = new RoleRevoked(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.role = event.params.role
  entity.account = event.params.account
  entity.sender = event.params.sender

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleSystemResumed(event: SystemResumedEvent): void {
  let entity = new SystemResumed(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.timestamp = event.params.timestamp

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleTimedActionTriggered(
  event: TimedActionTriggeredEvent
): void {
  let entity = new TimedActionTriggered(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.workflowId = event.params.workflowId
  entity.actionType = event.params.actionType
  entity.source = event.params.source
  entity.executor = event.params.executor

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleTimeoutConfigUpdated(
  event: TimeoutConfigUpdatedEvent
): void {
  let entity = new TimeoutConfigUpdated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.config_defaultAutoReleaseDelay =
    event.params.config.defaultAutoReleaseDelay
  entity.config_defaultAutoCancelDelay =
    event.params.config.defaultAutoCancelDelay
  entity.config_maxDisputeDuration = event.params.config.maxDisputeDuration
  entity.config_appealWindowDuration = event.params.config.appealWindowDuration

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleYieldProtocolFeeBpsUpdated(
  event: YieldProtocolFeeBpsUpdatedEvent
): void {
  let entity = new YieldProtocolFeeBpsUpdated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.oldFeeBps = event.params.oldFeeBps
  entity.newFeeBps = event.params.newFeeBps

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}
