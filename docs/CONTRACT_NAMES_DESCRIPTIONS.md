# Contract Names & One-Sentence Descriptions

## Proposed Renames (3 contracts)

| Current Name | Proposed Name | One-Sentence Description |
|--------------|---------------|--------------------------|
| `EscrowAdminContract` | `EscrowGovernanceTimelock` | Time-delayed governance controller for modifying escrow parameters (fees, modules) across all escrow contracts with 7-day activation delays. |
| `ModuleManagementContract` | `ModuleSnapshotRegistry` | Immutable registry that captures and freezes module configurations at escrow creation time to ensure consistent module references throughout the escrow lifecycle. |
| `DefaultYieldModule` | `DefaultYieldGenerationModule` | No-op yield generation module that keeps funds in the vault without generating external yield (baseline implementation). |

---

## All Contract Names with Descriptions

### Infrastructure - Singletons (Deploy Once, Shared by All)

#### Ops Contracts (5)
| Name | Type | Description |
|------|------|-------------|
| `CreateOps` | Ops | Operational logic library for escrow creation including validation, fee calculation, and module snapshot coordination. |
| `YieldOps` | Ops | Operational logic library for yield deposit, withdrawal, distribution, and emergency unwind across all yield modules. |
| `DisputeOps` | Ops | Operational logic library for initiating disputes, posting appeal bonds, and coordinating with resolution modules. |
| `SettlementOps` | Ops | Operational logic library for resolving disputes through resolver decisions and managing settlement outcomes. |
| `GuardianOps` | Ops | Operational logic library for guardian-controlled emergency actions including pause, unpause, and emergency yield unwinding. |

#### Management Contracts (3)
| Name | Type | Description |
|------|------|-------------|
| `EscrowGovernanceTimelock` (was EscrowAdminContract) | Timelock | Time-delayed governance controller for modifying escrow parameters (fees, modules) across all escrow contracts with 7-day activation delays. |
| `ModuleSnapshotRegistry` (was ModuleManagementContract) | Registry | Immutable registry that captures and freezes module configurations at escrow creation time to ensure consistent module references throughout the escrow lifecycle. |
| `BondCollector` | Registry | Registry for tracking appeal bond deposits, releases, and slashing during dispute escalation across all escrow contracts. |

#### View Contracts (1)
| Name | Type | Description |
|------|------|-------------|
| `EscrowView` (was EscrowViewContract) | View | Read-only view aggregator providing gas-efficient query functions for escrow state, balances, and configuration across all escrow implementations. |

---

### Escrow - Multi-Instance (Deploy Per Type)

| Name | Type | Description |
|------|------|-------------|
| `BaseEscrow` | Abstract | Abstract base contract defining the core escrow lifecycle (create, fund, dispute, resolve, release) inherited by all escrow implementations. |
| `EscrowVault` | Implementation | Vault-based escrow implementation for token-agnostic peer-to-peer escrows with pluggable yield generation, dispute resolution, and fee management. |
| `EscrowableERC20` | Implementation | ERC20 token contract with integrated escrow functionality enabling direct on-token escrows with built-in yield and dispute handling. |

---

### Modules - Singletons with Multi-Escrow Support

#### Yield Generation Modules
| Name | Type | Description |
|------|------|-------------|
| `AaveYieldGenerationModule` | Module | Yield generation module that deposits escrow funds into Aave V3 lending pools with multi-escrow multi-token aggregation and per-escrow position tracking. |
| `DefaultYieldGenerationModule` (was DefaultYieldModule) | Module | No-op yield generation module that keeps funds in the vault without generating external yield (baseline implementation). |

#### Yield Distribution Modules
| Name | Type | Description |
|------|------|-------------|
| `DefaultYieldDistributionModule` | Module | Yield distribution module that allocates generated yield between protocol fees, seller allocation, and buyer allocation per escrow-specific settings. |
| `TestYieldDistributionModule` | Module (Test) | Test implementation of yield distribution module for validating custom distribution logic in development and testing environments. |

#### Resolution Modules
| Name | Type | Description |
|------|------|-------------|
| `DefaultResolutionModule` | Module | Single-resolver dispute resolution module with time-bounded escalation phases, resolver decisions, and automatic timeout handling. |
| `DefaultReleaseStrategy` | Module | Release strategy module defining standard escrow release conditions (buyer/seller approval, dispute outcomes, timeout thresholds). |

---

## Naming Convention Summary

### Pattern: `[Domain][Purpose][Type]`

**Domains**: Escrow, Module, Bond, Yield, Dispute, Settlement, Guardian  
**Purposes**: Governance, Snapshot, Tracking, Distribution, Generation, Resolution  
**Types**: Ops, Registry, Timelock, Module, View, Implementation

### Type Suffix Meanings

| Suffix | Purpose | Mutability | Singleton? |
|--------|---------|------------|------------|
| **Ops** | Operational logic library | Code immutable | ✅ Yes |
| **Registry** | State tracking/recording | State mutable | ✅ Yes |
| **Timelock** | Governance with delays | Governance-controlled | ✅ Yes |
| **Module** | Pluggable component | Configurable | ✅ Yes (registered) |
| **View** | Read-only queries | Stateless | ✅ Yes |
| **Implementation** | Concrete escrow type | Instance state | ❌ No (multi) |

---

## Quick Reference

### Singletons (Deploy Once - 12 contracts)

**Infrastructure:**
- 5 Ops: CreateOps, YieldOps, DisputeOps, SettlementOps, GuardianOps
- 3 Management: EscrowGovernanceTimelock, ModuleSnapshotRegistry, BondCollector
- 1 View: EscrowView

**Modules:**
- 2 Yield Gen: AaveYieldGenerationModule, DefaultYieldGenerationModule
- 1 Yield Dist: DefaultYieldDistributionModule
- 2 Resolution: DefaultResolutionModule, DefaultReleaseStrategy

### Multi-Instance (Deploy Per Type - 3 contracts)

**Escrow:**
- 1 Abstract: BaseEscrow
- 2 Implementations: EscrowVault, EscrowableERC20

---

## Benefits Summary

### For Auditors
✅ Name immediately tells role (Ops, Registry, Timelock, Module, View)  
✅ "Governance" + "Timelock" = time-delayed governance (not direct admin)  
✅ "Snapshot" + "Registry" = immutable capture (not active management)  
✅ Consistent patterns across all contracts  

### For Developers
✅ Easy to find contracts by purpose (search "Registry", "Ops", etc.)  
✅ Clear separation of singletons vs multi-instance  
✅ Consistent naming for similar contracts  
✅ Future contracts follow established patterns  

