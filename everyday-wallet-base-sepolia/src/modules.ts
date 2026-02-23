import {
  DefaultReleaseStrategyActivated,
  DefaultReleaseStrategyQueued,
  DefaultResolutionModuleActivated,
  DefaultResolutionModuleQueued,
  DefaultYieldGenerationModuleActivated,
  DefaultYieldGenerationModuleQueued,
  DefaultYieldDistributionModuleActivated,
  DefaultYieldDistributionModuleQueued
} from "../generated/ModuleSnapshotRegistry/ModuleSnapshotRegistry"
import { ModuleChange } from "../generated/schema"

export function handleDefaultReleaseStrategyActivated(event: DefaultReleaseStrategyActivated): void {
  let change = new ModuleChange(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  change.moduleType = 1 // Release
  change.oldModule = event.params.oldModule
  change.newModule = event.params.newModule
  change.timestamp = event.block.timestamp
  change.transactionHash = event.transaction.hash
  change.save()
}

export function handleDefaultReleaseStrategyQueued(event: DefaultReleaseStrategyQueued): void {
  // Queued event - can track if needed
}

export function handleDefaultResolutionModuleActivated(event: DefaultResolutionModuleActivated): void {
  let change = new ModuleChange(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  change.moduleType = 0 // Resolution
  change.oldModule = event.params.oldModule
  change.newModule = event.params.newModule
  change.timestamp = event.block.timestamp
  change.transactionHash = event.transaction.hash
  change.save()
}

export function handleDefaultResolutionModuleQueued(event: DefaultResolutionModuleQueued): void {
  // Queued event - can track if needed
}

export function handleDefaultYieldGenerationModuleActivated(event: DefaultYieldGenerationModuleActivated): void {
  let change = new ModuleChange(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  change.moduleType = 2 // Yield Generation
  change.oldModule = event.params.oldModule
  change.newModule = event.params.newModule
  change.timestamp = event.block.timestamp
  change.transactionHash = event.transaction.hash
  change.save()
}

export function handleDefaultYieldGenerationModuleQueued(event: DefaultYieldGenerationModuleQueued): void {
  // Queued event - can track if needed
}

export function handleDefaultYieldDistributionModuleActivated(event: DefaultYieldDistributionModuleActivated): void {
  let change = new ModuleChange(
    event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  )
  change.moduleType = 3 // Yield Distribution
  change.oldModule = event.params.oldModule
  change.newModule = event.params.newModule
  change.timestamp = event.block.timestamp
  change.transactionHash = event.transaction.hash
  change.save()
}

export function handleDefaultYieldDistributionModuleQueued(event: DefaultYieldDistributionModuleQueued): void {
  // Queued event - can track if needed
}
