# Deployment Topology Reference

This document clarifies which contracts are singletons (deployed once per chain), system contracts (typically one, but may vary by design), pluggable modules (deployed many times), and test-only contracts. This guide helps developers, auditors, and operators understand the deployment architecture.

## Overview

The system has a clear separation of concerns:

1. **Core Escrow System**: The main protocol infrastructure for managing escrows and disputes
2. **Governance Layer**: Token, voting, and timelock contracts for protocol governance
3. **Pluggable Modules**: Swappable implementations for yield, resolution, and release strategies
4. **Integration Modules**: Optional integrations (Aave, Kleros, evidence handling)
5. **Administrative Contracts**: Configuration management and operational helpers
6. **Subsystems**: Optional decentralized resolution with staking/slashing/incentives

---

## System Singletons (1 per Chain)

These contracts are deployed exactly once per chain and serve as the system's core infrastructure.

### Core System
| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **EscrowVault** | `core/EscrowVault.sol` | Main escrow contract | Holds all escrowed funds, manages disputes and releases, integrates all modules |
| **ModuleManagementContract** | `core/ModuleManagementContract.sol` | Module governance | Configures which modules are active, uses slow-lane (7-day) activation |
| **EscrowViewContract** | `core/EscrowViewContract.sol` | Read-only querying | Provides safe view functions for escrow state; safe to call from UI/indexers |
| **ModuleRegistry** | `registry/ModuleRegistry.sol` | Module catalog | Registry of available yield/resolution/release modules |
| **BondCollector** | `core/BondCollector.sol` | Bond management | Collects and manages dispute bonds |

### Governance
| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **SewToken** | `token/SewToken.sol` | Governance token | ERC20Votes token; standard OpenZeppelin governor token |
| **GovGovernor** | `governance/GovGovernor.sol` | DAO voting | OpenZeppelin Governor contract; votes with SewToken |
| **TimelockController** | `governance/TimelockController.sol` (OpenZeppelin) | Execution delay | 2-day timelock before governance actions execute |
| **SlowLaneQueueActivate** | `governance/SlowLaneQueueActivate.sol` | Config delays | Base class providing 7-day delay for high-risk changes (used by EscrowAdminContract, ModuleManagementContract) |

### Administration
| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **EscrowAdminContract** | `admin/EscrowAdminContract.sol` | Config management | Centralized slow-lane admin for escrow fee, yield fee, timeout settings; can be authorized by EscrowVault |

### Integration: Kleros (Optional)
| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **KlerosArbitrableProxy** | `arbitration/KlerosArbitrableProxy.sol` | Kleros arbitration bridge | Integration with Kleros protocol; can be registered with EscrowVault as a resolution module |

---

## System Contracts (Typically 1, Configurable)

These contracts provide operational services. Most systems deploy one instance, but by design can have multiples for different configurations or phased rollouts.

### Operations Layer
| Contract | Location | Purpose | Quantity | Notes |
|----------|----------|---------|----------|-------|
| **YieldOps** | `YieldOps.sol` | Yield operations | 1+ | Handles yield distribution and claim logic; can theoretically have multiple instances for different yield protocols |
| **DisputeOps** | `DisputeOps.sol` | Dispute operations | 1+ | Handles dispute initialization and state transitions |
| **SettlementOps** | `SettlementOps.sol` | Settlement operations | 1+ | Handles release and settlement logic |
| **CreateOps** | `CreateOps.sol` | Escrow creation | 1+ | Handles escrow setup and validation |
| **GuardianOps** | `ops/GuardianOps.sol` | Guardian operations | 1+ | Handles emergency pause/unpause (if guardian role is used) |

### Subsystem Singletons (If Decentralized Resolution Subsystem is Active)

If you deploy the decentralized resolution module subsystem:

| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **DecentralizedResolutionModule** | `decentralized-resolution-module/DecentralizedResolutionModule.sol` | Resolver arbitration | Main resolution module for decentralized dispute resolution |
| **InsurancePoolVault** | `decentralized-resolution-module/InsurancePoolVault.sol` | Slashing pool | Holds slashed resolver collateral |
| **ResolverStakingModuleV1** | `decentralized-resolution-module/ResolverStakingModuleV1.sol` | Staking | Manages resolver stake deposits |
| **ResolverSlashingModuleV1** | `decentralized-resolution-module/ResolverSlashingModuleV1.sol` | Slashing | Penalizes misbehaving resolvers |
| **ResolverIncentiveModuleV1** | `decentralized-resolution-module/ResolverIncentiveModuleV1.sol` | Incentives | Rewards resolver participation |
| **PaymentCalculationLibraryV1** | `decentralized-resolution-module/PaymentCalculationLibraryV1.sol` | Payment logic | Calculates resolver rewards (deployed as contract for governance upgrades) |
| **ResolutionAnalytics** | `decentralized-resolution-module/ResolutionAnalytics.sol` | Analytics | Tracks resolver stats and metrics |

---

## Pluggable Modules (Many Instances)

These are swappable implementations registered in `ModuleRegistry`. Each deployment can activate multiple instances, choosing which to use for each escrow.

### Yield Modules
| Contract | Location | Purpose | Instantiation |
|----------|----------|---------|----------------|
| **DefaultYieldModule** | `modules/DefaultYieldModule.sol` | No-op yield | Typically 1 instance; escrow defaults here |
| **AaveYieldGenerationModule** | `modules/AaveYieldGenerationModule.sol` | Aave V3 lending | **Singleton**: 1 instance manages multiple vaults (see [Multi-Vault Architecture](MULTI_VAULT_ARCHITECTURE.md)) |
| **Custom Yield Modules** | — | User-defined | Any contract implementing `IYieldGenerationModule` can be registered |

**Usage**: Each escrow chooses which yield module to use (or none). **Important**: AaveYieldGenerationModule uses a singleton pattern where one instance manages yield for multiple EscrowVault and EscrowableERC20 contracts. See [MULTI_VAULT_ARCHITECTURE.md](MULTI_VAULT_ARCHITECTURE.md) for details on multi-vault management, governance, and cap enforcement.

### Yield Distribution Modules
| Contract | Location | Purpose | Instantiation |
|----------|----------|---------|----------------|
| **DefaultYieldDistributionModule** | `modules/DefaultYieldDistributionModule.sol` | No-op distribution | Typically 1 instance; escrow defaults here |
| **TestYieldDistributionModule** | `modules/TestYieldDistributionModule.sol` | Test/debug only | See "Test Contracts" section |

### Release Strategies
| Contract | Location | Purpose | Instantiation |
|----------|----------|---------|----------------|
| **DefaultReleaseStrategy** | `modules/DefaultReleaseStrategy.sol` | Time-based release | Typically 1 instance; defines default unlock schedule |

### Resolution Modules
| Contract | Location | Purpose | Instantiation |
|----------|----------|---------|----------------|
| **DecentralizedResolutionModule** | `decentralized-resolution-module/DecentralizedResolutionModule.sol` | Decentralized dispute resolution | 0 or 1 (optional subsystem) |
| **KlerosArbitrableProxy** | `arbitration/KlerosArbitrableProxy.sol` | Kleros arbitration | 0 or 1 (optional integration) |
| **Custom Resolution Modules** | — | User-defined | Any contract implementing `IResolutionModule` can be registered |

**Usage**: Each escrow selects one active resolution module. Can be changed via slow-lane governance.

### Evidence Modules
| Contract | Location | Purpose | Instantiation |
|----------|----------|---------|----------------|
| **EvidenceModuleV1** | `evidence-module/EvidenceModuleV1.sol` | Evidence management | 0 or 1 (optional) |

---

## Integration Contracts (Optional)

These are specialized integrations with external protocols. They follow the pluggable module pattern but are grouped here because they require external protocol setup.

### Aave V3 Integration
| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **AaveYieldGenerationModule** | `modules/AaveYieldGenerationModule.sol` | Lend escrow on Aave V3 | Deposits escrowed tokens into Aave lending pools |
| **AaveV3Interfaces** | `interfaces/aave/AaveV3Interfaces.sol` | External interface | Re-exports Aave's IPool, IAddressesProvider, etc. |
| **AaveYieldLibrary** | `libraries/AaveYieldLibrary.sol` | Helper library | Utility for Aave interactions |
| **AaveYieldHandlingLibrary** | `libraries/AaveYieldHandlingLibrary.sol` | Yield handling | Logic for Aave-specific yield processing |

**Usage**: Optional. Deploy and register `AaveYieldGenerationModule` if using Aave as a yield source.

### Kleros Integration
| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **KlerosArbitrableProxy** | `arbitration/KlerosArbitrableProxy.sol` | Kleros integration | Bridges disputes to Kleros arbitration |

**Usage**: Optional. Deploy if using Kleros as an external arbitrator.

---

## ERC20 with Escrow (Factory Pattern)

The system supports creating ERC20 tokens that integrate escrow functionality natively.

| Contract | Location | Purpose | Notes |
|----------|----------|---------|-------|
| **EscrowableERC20** | `core/EscrowableERC20.sol` | ERC20 + escrow | Token with built-in escrow; can be deployed as instances |
| **EscrowableERC20Factory** | `core/EscrowableERC20.sol` | Factory | Helper to deploy EscrowableERC20 instances |

**Usage**: Optional. Use if you want tokens with native escrow functionality.

---

## Test & Mock Contracts

These are development and testing utilities. **Do not deploy to mainnet or testnet.**

### Mocks
| Contract | Location | Purpose |
|----------|----------|---------|
| **ERC20Mock** | `mocks/ERC20Mock.sol` | Standard ERC20 for testing |
| **MockAavePool** | `mocks/MockAavePool.sol` | Simulates Aave lending pool |
| **MockAavePoolReverting** | `mocks/MockAavePoolReverting.sol` | Aave mock that reverts (error testing) |
| **FeeOnTransferERC20Mock** | `mocks/FeeOnTransferERC20Mock.sol` | ERC20 with transfer fees |
| **MockFeeOnTransfer** | `mocks/MockFeeOnTransfer.sol` | Transfer fee simulator |
| **MockNonStandardERC20** | `mocks/MockNonStandardERC20.sol` | Non-compliant ERC20 (testing robustness) |
| **MockRebasingToken** | `mocks/MockRebasingToken.sol` | Token with rebase mechanics |
| **MockRevertingERC20** | `mocks/MockRevertingERC20.sol` | ERC20 that reverts transfers |
| **SafeMock** | `mocks/SafeMock.sol` | Utility for testing Safe integrations |
| **MockKlerosArbitrator** | `arbitration/mocks/MockKlerosArbitrator.sol` | Simulates Kleros arbitrator |

### Test-Only Modules
| Contract | Location | Purpose |
|----------|----------|---------|
| **TestYieldDistributionModule** | `modules/TestYieldDistributionModule.sol` | Debug yield distribution; for testing only |
| **TestnetForwardingResolver** | `mocks/TestnetForwardingResolver.sol` | Testnet resolver for development |

### Decentralized Resolution Subsystem: No-Op Variants
| Contract | Location | Purpose |
|----------|----------|---------|
| **StakingModuleNoOp** | `decentralized-resolution-module/StakingModuleNoOp.sol` | Staking disabled (for testing) |
| **SlashingModuleNoOp** | `decentralized-resolution-module/SlashingModuleNoOp.sol` | Slashing disabled (for testing) |

---

## Library & Support Contracts

These provide internal functionality but are not deployed independently. They are referenced by other contracts.

| Category | Examples | Notes |
|----------|----------|-------|
| **Shared Libraries** | `BalanceUpdateLibrary`, `FeeWithdrawalLibrary`, `TokenRecoveryLibrary`, `DisputeInitializationLibrary`, `DisputeEscalationLibrary`, `ResolverActionLibrary`, etc. | Linked into core/module contracts; not standalone |
| **Module Utilities** | `ModuleGetterLibrary`, `ModuleGetterConsolidationLibrary`, `ModuleProposalLibrary` | Support ModuleManagementContract; not standalone |
| **Decentralized Resolution Support** | `BondValuationLibrary`, `EscalationCostLibrary`, `DecentralizedResolverStructs` | Support DecentralizedResolutionModule; not standalone |
| **Type Definitions** | `types/EscrowTypes.sol`, `types/YieldPresets.sol` | Shared types and constants |

---

## Interface Definitions

Interfaces define contracts' public surfaces and are used for polymorphism (modules, integrations).

| Category | Location | Purpose |
|----------|----------|---------|
| **Core Interfaces** | `interfaces/IModuleRegistry.sol`, `interfaces/IResolver.sol` | System touchpoints |
| **Module Interfaces** | `interfaces/IYieldGenerationModule.sol`, `interfaces/IYieldDistributionModule.sol`, `interfaces/IReleaseStrategy.sol`, `interfaces/IEvidenceModule.sol` | Module contract specs |
| **External Integration** | `interfaces/aave/AaveV3Interfaces.sol`, `arbitration/IArbitrator.sol`, `arbitration/IArbitrable.sol` | External protocol boundaries |
| **Yield Utilities** | `interfaces/IYieldHandlingLibrary.sol` | Yield processing contracts |
| **Decentralized Resolution** | `decentralized-resolution-module/IIncentiveModule.sol`, `IStakingModule.sol`, `ISlashingModule.sol`, `IPaymentCalculationLibrary.sol` | Subsystem interfaces |
| **Shared/Internal** | `shared/interfaces/IResolutionModule.sol`, `IFraudProofModule.sol` | Internal multi-contract interfaces |

---

## Deployment Order (Reference)

The hardhat-deploy scripts define a recommended deployment sequence:

1. **Implementation contracts** (00_impl.ts)
2. **Safe proxy setup** (10_safe.ts) — if using Gnosis Safe
3. **Proxy deployment** (11_proxy.ts)
4. **Module management** (14_module_management.ts)
5. **Ops layer** (15_yield_dispute_ops.ts) — YieldOps, DisputeOps, SettlementOps, CreateOps, BondCollector
6. **Escrow admin** (16_escrow_admin_contract.ts)
7. **Governance token** (20_gov_token.ts) — SewToken
8. **Timelock** (30_timelock.ts)
9. **Release strategy** (32_release_strategy.ts)
10. **Governor** (40_governor.ts)
11. **Timelock wiring** (50_timelock_wiring.ts)
12. **Protocol governance setup** (60_protocol_governance.ts)
13. **Core escrow** (70_core_escrow.ts) — EscrowVault, EscrowViewContract, module wiring

This order ensures dependencies are met (e.g., ModuleManagementContract is ready before EscrowVault).

---

## Summary Table

| Category | Quantity | Examples |
|----------|----------|----------|
| **Singletons (1 per chain)** | ~11 | EscrowVault, GovGovernor, SewToken, TimelockController, ModuleRegistry, etc. |
| **System Contracts (1+)** | ~5 | YieldOps, DisputeOps, SettlementOps, CreateOps, GuardianOps |
| **Pluggable Modules (0+)** | Variable | Yield modules, resolution modules, release strategies |
| **Optional Subsystems (0-1)** | 2 | Decentralized resolution subsystem, Evidence module subsystem |
| **Test/Mock Contracts** | ~12 | Mocks and test-only modules; never deploy to production |
| **Libraries & Interfaces** | ~40+ | Internal utilities; not deployed directly |

---

## Key Principles

1. **Singletons are anchors**: EscrowVault and ModuleManagementContract are the system's core. Everything else connects to them.

2. **Pluggable modules are swappable**: Implementations can be added, upgraded, or replaced via governance without redeploying the core system.

3. **Ops layer is operational**: Separate contracts for yield, disputes, settlement, and creation keep concerns clean and allow independent testing.

4. **Subsystems are optional**: The decentralized resolution module and evidence module are self-contained and can be omitted or upgraded independently.

5. **Governance is two-tiered**: 
   - 2-day TimelockController for standard governance (via SewToken votes)
   - 7-day slow-lane for high-risk changes (module swaps, fee updates)

6. **Mocks are development-only**: Never commit mock contracts to production deployments.

---

## Adding New Contracts

When adding a new contract, ask:

- **Is it a singleton?** (deployed once, coordinates the system) → add to "System Singletons"
- **Is it a pluggable module?** (implements an interface, registered in ModuleRegistry) → add to "Pluggable Modules"
- **Is it an integration?** (bridges to an external protocol) → add to "Integration Contracts"
- **Is it a test utility?** → add to "Test & Mock Contracts"
- **Is it a helper?** (library or internal interface) → add to "Library & Support Contracts"

Update this document when new contracts are added to production deployments.

