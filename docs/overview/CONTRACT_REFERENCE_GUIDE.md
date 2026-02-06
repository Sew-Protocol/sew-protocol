# Contract Reference Guide (Post-Refactor)

**Updated**: February 2026  
**Branch**: feat/combined-reorganization  
**Status**: Reflects all naming improvements for audit clarity

---

## Table of Contents

1. [Infrastructure Contracts (Singletons)](#infrastructure-contracts-singletons)
2. [Escrow Implementations (Multi-Instance)](#escrow-implementations-multi-instance)
3. [Module Contracts](#module-contracts)
4. [Operational Libraries (Ops)](#operational-libraries-ops)
5. [Governance Contracts](#governance-contracts)
6. [Shared Libraries](#shared-libraries)
7. [Quick Reference Tables](#quick-reference-tables)

---

## Infrastructure Contracts (Singletons)

**Pattern**: Deployed ONCE, shared by all escrow instances via registration

### EscrowGovernanceTimelock
- **Location**: `contracts/admin/EscrowGovernanceTimelock.sol`
- **Previously**: EscrowAdminContract
- **Type**: ✅ Singleton
- **Description**: Time-delayed governance contract for escrow configuration changes. Enforces 7-day minimum delay for parameter updates via queue/activate pattern.
- **Key Functions**: Queue/activate escrow fee, resolution module, yield settings per escrow
- **Registrations**: Target escrow contracts must grant ROLE_ADMIN_CONTRACT

### ModuleSnapshotRegistry
- **Location**: `contracts/core/ModuleSnapshotRegistry.sol`
- **Previously**: ModuleManagementContract
- **Type**: ✅ Singleton
- **Description**: Registry for module snapshots frozen at escrow creation time. Stores immutable module configurations per escrow contract.
- **Key Functions**: Register escrow, snapshot modules at creation, provide fallback defaults
- **Registrations**: New escrow contracts register on deployment

### BondCollector
- **Location**: `contracts/core/BondCollector.sol`
- **Type**: ✅ Singleton
- **Description**: External contract for collecting escalation bonds (ETH or ERC20) with protocol fee deduction. Handles custody and incentive module recording.
- **Key Functions**: Collect ETH/ERC20 appeal bonds, deduct protocol fees, record to incentive module
- **Registrations**: Escrow contracts must grant ROLE_ESCROW_CONTRACT

### EscrowViewContract
- **Location**: `contracts/core/EscrowViewContract.sol`
- **Type**: ✅ Singleton
- **Description**: Read-only view functions for escrow state queries. Extracted from BaseEscrow to reduce contract size.
- **Key Functions**: Batch queries, computed views, aggregated state reads
- **Registrations**: No registration required (read-only)

---

## Escrow Implementations (Multi-Instance)

**Pattern**: Deployed MULTIPLE times, one per escrow type or configuration

### BaseEscrow (Abstract)
- **Location**: `contracts/core/BaseEscrow.sol`
- **Type**: ⚠️ Abstract (not deployed directly)
- **Description**: Base implementation for all escrow contracts. Provides core lifecycle, disputes, settlements, yield, and module management.
- **Inherited By**: EscrowVault, EscrowableERC20
- **Key Features**: Pausable, role-based access, module swapping, Aave yield integration

### EscrowVault
- **Location**: `contracts/core/EscrowVault.sol`
- **Type**: 🔄 Multi-Instance
- **Description**: Vault-style escrow where funds held in contract. Supports deposits, withdrawals, disputes, and Aave yield generation.
- **Use Case**: Traditional escrow (buyer deposits funds, seller fulfills, funds release)
- **Instances**: Deployed per configuration (e.g., different fee structures, modules)

### EscrowableERC20
- **Location**: `contracts/core/EscrowableERC20.sol`
- **Type**: 🔄 Multi-Instance
- **Description**: ERC20 token with built-in escrow capabilities. Token balances can be locked in escrow workflows.
- **Use Case**: Tokenized escrows, conditional token releases
- **Instances**: Deployed per token (e.g., wrapped assets, stablecoins with escrow)

---

## Module Contracts

**Pattern**: Most are singletons (deployed once, shared). DR modules are modular/swappable.

### Yield Generation Modules

#### AaveYieldGenerationModule
- **Location**: `contracts/modules/AaveYieldGenerationModule.sol`
- **Type**: ✅ Singleton
- **Description**: Yield generation module integrating Aave V3 protocol. Deposits escrow funds to Aave, tracks scaled balances, handles emergency unwinding.
- **Supports**: Multi-token, multi-vault, dust/deficit tracking, pause controls

#### DefaultYieldGenerationModule
- **Location**: `contracts/modules/DefaultYieldGenerationModule.sol`
- **Previously**: DefaultYieldModule
- **Type**: ✅ Singleton
- **Description**: No-op yield module (no actual yield generation). Serves as fallback for escrows that don't generate yield.
- **Use Case**: Escrows without yield, testing, or emergency fallback

### Yield Distribution Modules

#### DefaultYieldDistributionModule
- **Location**: `contracts/modules/DefaultYieldDistributionModule.sol`
- **Type**: ✅ Singleton
- **Description**: Default yield distribution logic. Implements IYieldDistributionModule interface.
- **Strategy**: [Implementation-specific, check contract for details]

### Resolution Modules

#### DefaultResolutionModule
- **Location**: `contracts/modules/DefaultResolutionModule.sol`
- **Type**: ✅ Singleton
- **Description**: Basic resolution module for dispute handling without decentralized resolution.
- **Use Case**: Simple disputes, admin-based resolution

#### DefaultReleaseStrategy
- **Location**: `contracts/modules/DefaultReleaseStrategy.sol`
- **Type**: ✅ Singleton
- **Description**: Default release strategy (buyer-initiated release).
- **Behavior**: Matches current EscrowableERC20 behavior

### Decentralized Resolution Module (DR1/DR2/DR3)

**Location**: `contracts/modules/decentralized-resolution-module/`  
**Status**: Post-launch, optional (can be separate package)

#### DecentralizedResolutionModule
- **Type**: ✅ Singleton
- **Description**: Main DR module orchestrating decentralized dispute resolution.
- **Versions**: Supports DR v1 (workload routing), DR v2 (appeal bonds), DR v3 (staking - future)

#### ResolverIncentiveModuleV1
- **Type**: ✅ Singleton
- **Description**: DR v1 incentive module with performance-based workload routing (no appeal bonds).

#### ResolverIncentiveModuleV2
- **Type**: ✅ Singleton
- **Description**: DR v2 incentive module with appeal bonds and escalation cost curves.

#### Additional DR Contracts
- ResolverStakingModuleV1 (DR v3 - future)
- ResolverSlashingModuleV1 (DR v3 - future)
- PaymentCalculationLibraryV1
- BondValuationLibrary
- EscalationCostLibrary
- InsurancePoolVault
- ResolutionAnalytics

---

## Operational Libraries (Ops)

**Location**: `contracts/ops/`  
**Pattern**: Stateless libraries deployed once, called by escrow contracts

### CreateOps
- **Type**: ✅ Singleton (Library)
- **Description**: External contract for escrow creation validation and computation. Handles settings validation, encoding, and initialization.
- **Extracted**: Reduces BaseEscrow contract size

### YieldOps
- **Type**: ✅ Singleton (Library)
- **Description**: External contract for yield withdrawal and distribution operations.
- **Handles**: Yield module calls, distribution logic, withdrawal orchestration

### DisputeOps
- **Type**: ✅ Singleton (Library)
- **Description**: External contract for dispute escalation orchestration.
- **Handles**: Appeal bond collection, round management, incentive module integration

### SettlementOps
- **Type**: ✅ Singleton (Library)
- **Description**: External contract for settlement execution operations.
- **Handles**: Final settlement logic, fund distribution

### GuardianOps
- **Type**: ✅ Singleton (Library)
- **Description**: Emergency operations contract for guardian-controlled Aave position unwinding.
- **Safety**: Only callable by ROLE_GUARDIAN, read-only settlement view

---

## Governance Contracts

### SlowLaneQueueActivate (Base Contract)
- **Location**: `contracts/governance/SlowLaneQueueActivate.sol`
- **Type**: ✅ Base Contract (inherited)
- **Description**: Abstract base providing queue/activate pattern with configurable delays.
- **Used By**: EscrowGovernanceTimelock, ModuleSnapshotRegistry, AaveYieldGenerationModule

### TimelockController Integration
- **Location**: External (OpenZeppelin)
- **Description**: Protocol-level timelock controller (7-day delay for governance actions).
- **Grants**: ROLE_TIMELOCK to EscrowGovernanceTimelock

---

## Shared Libraries

**Location**: `contracts/libraries/`  
**Pattern**: Pure libraries (no state, no deployment needed in most cases)

### Core Libraries
- **SettingsValidationLibrary**: Validates escrow configuration parameters
- **EscrowEncodingLibrary**: Encoding/decoding for escrow data structures
- **ResolverLogicLibrary**: Resolver selection and logic
- **RecoveryLibrary**: Emergency recovery operations
- **ModuleProposalLibrary**: Module swap proposals
- **ResolverActionLibrary**: Resolver action processing
- **StateManagementLibrary**: Escrow state transitions

### Dispute Libraries
- **DisputeInitializationLibrary**: Dispute setup and initialization
- **DisputeManagementLibrary**: Dispute state management
- **DisputeRaiseLibrary**: Dispute raising logic
- **DisputeEscalationLibrary**: Appeal and escalation handling

### Yield Libraries
- **YieldPresetLibrary**: Yield preset configuration
- **AaveYieldHandlingLibrary**: Aave-specific yield operations
- **BalanceUpdateLibrary**: Balance tracking and updates
- **FeeWithdrawalLibrary**: Fee calculation and withdrawal

### Module Libraries
- **ModuleSnapshotLibrary**: Module snapshot creation/retrieval
- **ModuleGetterLibrary**: Optimized module address retrieval
- **BondHandlingLibrary**: Bond processing and fee calculation

### Resolution Libraries
- **ResolutionTableLibrary**: Resolution table management (DR module)

---

## Quick Reference Tables

### Table 1: Deployment Pattern Summary

| Category | Pattern | Count | Examples |
|----------|---------|-------|----------|
| Infrastructure | ✅ Singleton | 4 | EscrowGovernanceTimelock, ModuleSnapshotRegistry, BondCollector, EscrowViewContract |
| Escrow Implementations | 🔄 Multi-Instance | 2 | EscrowVault, EscrowableERC20 |
| Yield Modules | ✅ Singleton | 3 | AaveYieldGenerationModule, DefaultYieldGenerationModule, DefaultYieldDistributionModule |
| Resolution Modules | ✅ Singleton | 2+ | DefaultResolutionModule, DefaultReleaseStrategy, DR modules |
| Ops Libraries | ✅ Singleton | 5 | CreateOps, YieldOps, DisputeOps, SettlementOps, GuardianOps |
| Pure Libraries | No deployment | 20+ | Various libraries in `contracts/libraries/` |

### Table 2: Contract Renames (for Reference)

| Old Name | New Name | Rationale |
|----------|----------|-----------|
| EscrowAdminContract | EscrowGovernanceTimelock | Clarifies time-delayed governance (not direct admin) |
| ModuleManagementContract | ModuleSnapshotRegistry | Emphasizes immutable snapshots (not active management) |
| DefaultYieldModule | DefaultYieldGenerationModule | Consistency with AaveYieldGenerationModule naming |

### Table 3: Registration Requirements

| Contract | Registers With | Role Granted | Purpose |
|----------|----------------|--------------|---------|
| EscrowVault | ModuleSnapshotRegistry | ROLE_ESCROW_CONTRACT | Module snapshot access |
| EscrowVault | BondCollector | ROLE_ESCROW_CONTRACT | Bond collection delegation |
| EscrowVault | EscrowGovernanceTimelock | Register as target | Governance parameter updates |
| EscrowVault | AaveYieldGenerationModule | ROLE_ESCROW_CONTRACT | Yield deposit/withdrawal |
| BondCollector | Get from escrow | ROLE_ESCROW_CONTRACT (on escrow) | Call escrow functions |
| EscrowGovernanceTimelock | Get from escrow | ROLE_ADMIN_CONTRACT (on escrow) | Update escrow parameters |

### Table 4: Interface Locations

| Interface | Location | Used By |
|-----------|----------|---------|
| IIncentiveModule | `shared/interfaces/` | Core escrows, DR modules |
| IResolutionModule | `shared/interfaces/` | Escrows, resolution modules |
| IYieldGenerationModule | `interfaces/` | Escrows, yield modules |
| IYieldDistributionModule | `interfaces/` | Escrows, distribution modules |
| IReleaseStrategy | `interfaces/` | Escrows, release modules |

---

## Architectural Notes

### Singleton vs Multi-Instance Pattern

**Why Singletons?**
- Infrastructure contracts shared across all escrows
- Reduces deployment costs (deploy once, use many times)
- Centralized governance and module management
- Consistent behavior across all escrow instances

**Why Multi-Instance?**
- Escrow contracts hold user funds (isolated risk)
- Different configurations per deployment (fees, modules, rules)
- Allows experimentation without affecting existing escrows

### Module Swapping

All escrow contracts support module swapping via:
1. **Proposal**: Escrow proposes new module
2. **Queue**: EscrowGovernanceTimelock queues change
3. **Wait**: 7-day minimum delay
4. **Activate**: Governance activates, module swaps

This enables:
- Upgrading yield strategies (e.g., Compound → Aave)
- Switching resolution systems (Default → Decentralized)
- Emergency fallbacks (Aave → Default if Aave paused)

### Package Separation (Post-Refactor)

After IIncentiveModule extraction:
- **Core Package**: Infrastructure, escrows, basic modules
- **DR Package**: Decentralized resolution module (can be separate npm package)
- **Interface**: `IIncentiveModule` in core, implementations in DR package

This enables:
- DR module development in separate repo
- Optional DR installation (not required at launch)
- Clear architectural boundaries

---

## For Auditors

### Key Focus Areas by Category

**Infrastructure (High Risk)**
1. EscrowGovernanceTimelock - Time delays correctly enforced?
2. ModuleSnapshotRegistry - Snapshots truly immutable?
3. BondCollector - Protocol fees calculated correctly?

**Escrow Implementations (Critical)**
1. BaseEscrow - State machine transitions sound?
2. EscrowVault - Fund custody secure?
3. EscrowableERC20 - Token accounting correct?

**Yield Modules (Medium-High Risk)**
1. AaveYieldGenerationModule - Aave integration secure?
2. Dust/deficit tracking - Rounding handled correctly?
3. Emergency unwind - Funds recovered properly?

**Resolution Modules (Launch: Low Risk)**
- DefaultResolutionModule - Simple, admin-based
- DR Module - Post-launch, out of scope initially

### Naming Clarity Improvements

The recent refactor focused on:
1. **Governance** terms for time-delayed changes (not "admin")
2. **Registry** terms for immutable snapshots (not "management")
3. **Generation** suffix for clarity (yield generation vs distribution)
4. **Organization** - All Ops in one directory, interfaces separated

These changes make auditor navigation and comprehension easier.

---

## Document Version

**Last Updated**: February 4, 2026  
**Reflects**: All Phase 1-6 refactoring (feat/combined-reorganization branch)  
**Status**: Ready for audit  

**Changes from Previous Version**:
- ✅ Updated 3 contract names (EscrowGovernanceTimelock, ModuleSnapshotRegistry, DefaultYieldGenerationModule)
- ✅ Added IIncentiveModule location (moved to shared/interfaces/)
- ✅ Added Ops consolidation (all in contracts/ops/)
- ✅ Added singleton/multi-instance indicators
- ✅ Added registration requirements table
