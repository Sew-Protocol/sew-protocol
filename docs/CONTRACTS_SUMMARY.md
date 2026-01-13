# Contracts Summary

**Date**: 2025-01-XX  
**Purpose**: Succinct overview of all contracts and their roles

---

## Core Escrow Contracts

### BaseEscrow.sol
**Purpose**: Abstract base contract providing core escrow functionality  
**Key Features**:
- Multi-token escrow support (ERC20)
- Dispute resolution system
- Escalation support
- Fee management
- Integration with resolution modules, yield generation, and yield distribution modules

**Inherited By**: `EscrowVault`, `EscrowableERC20`

---

### EscrowVault.sol
**Purpose**: Multi-token escrow vault for holding multiple token types  
**Key Features**:
- Supports any ERC20 token
- Per-token fee tracking
- Batch operations
- Resolution module integration
- Yield generation support (Aave)

**Use Case**: When you need to escrow multiple different tokens in a single contract

---

### EscrowableERC20.sol
**Purpose**: ERC20 token with built-in escrow functionality  
**Key Features**:
- Standard ERC20 token
- Built-in `createEscrow()` function (primary function name)
- Automatic fee deduction
- Single-token escrow (token is both payment and escrow medium)
- Factory pattern for deployment

**Use Case**: When you want a token that has escrow capabilities built-in

---

## Resolution Modules

### DefaultResolutionModule.sol
**Purpose**: Simple, single-resolver resolution module  
**Key Features**:
- Single resolver assignment
- No escalation support
- Minimal configuration
- Governance-controlled resolver updates

**Use Case**: Simple disputes that don't need escalation or multiple resolvers

---

### DecentralizedResolutionModule.sol
**Purpose**: Advanced decentralized resolution with multiple resolvers and escalation  
**Status**: In separate package (`contracts/decentralized-resolution-module/`), **not included in initial mainnet release**. When ready, will be deployed and swapped in via Slow lane governance (queue + activate, ~9 days).  
**Key Features**:
- Resolver registry (standard and senior resolvers)
- Round-robin resolver selection (fair distribution)
- Three-level escalation (standard → senior → external)
- Dynamic resolution table (category-based assignment)
- Integration with ResolverIncentiveModule

**Use Case**: Complex disputes requiring multiple resolvers, escalation paths, and fair workload distribution

**Note**: This module is developed and tested in isolation before mainnet integration. When ready, it will use the same governance pattern as other modules: deploy new version and swap via Slow lane (~9 days).

---

## Payment & Incentive System

### ResolverIncentiveModule.sol
**Purpose**: Tracks and distributes payments to dispute resolvers  
**Key Features**:
- Resolver involvement tracking
- Fee aggregation (escrow fees + escalation fees)
- Payment calculation using pluggable libraries
- Automatic payment distribution (ERC20)
- Governance-controlled configuration (Slow lane, ~9 days)
- Configurable resolver share percentage and weights

**Use Case**: Incentivizing resolvers by paying them a share of collected fees

**Note**: When ready, this module will use the same governance pattern as other modules: deploy new version and swap via Slow lane (~9 days).

---

### PaymentCalculationLibraryV1.sol
**Purpose**: Payment calculation library (Version 1)  
**Key Features**:
- Weighted distribution by escalation level
- Pure functions (no state)
- Extensible input/output design
- Version detection support

**Calculation Method**: Weighted by level (level 0 = 1x, level 1 = 1.5x, level 2 = 2x)

**Use Case**: Calculates how much each resolver should be paid based on their involvement level

---

### IPaymentCalculationLibrary.sol
**Purpose**: Interface for payment calculation libraries  
**Key Features**:
- Standard interface for library implementations
- Extensible input/output structures
- Version detection
- Validation function

**Use Case**: Allows governance to upgrade payment calculation logic without changing core contracts

---

## Yield Generation Modules

### AaveYieldGenerationModule.sol
**Purpose**: Generates yield on escrowed funds using Aave  
**Key Features**:
- Deposits tokens to Aave lending pool
- Tracks yield per escrow
- Proportional yield calculation
- Withdrawal with yield

**Use Case**: Earn interest on escrowed funds while they're locked

---

### AaveYieldModule.sol
**Purpose**: Wrapper for Aave integration  
**Key Features**:
- Aave pool interaction
- Token supply/withdrawal
- Yield calculation

**Use Case**: Low-level Aave integration

---

## Yield Distribution Modules

### DefaultYieldDistributionModule.sol
**Purpose**: Distributes yield to configured recipients  
**Key Features**:
- Configurable yield distribution
- Percentage-based allocation
- Multiple recipients support

**Use Case**: Share yield between parties (e.g., sender and recipient)

---

## Governance

### SlowLaneQueueActivate.sol
**Purpose**: Abstract contract for slow lane governance (7-day delay)  
**Key Features**:
- Queue/activate pattern
- 7-day delay enforcement
- Address and uint256 parameter support

**Use Case**: High-risk parameter changes requiring community review

---

### GovGovernor.sol
**Purpose**: Governance governor for DAO proposals  
**Key Features**:
- Proposal creation and execution
- Voting mechanism
- Timelock integration

**Use Case**: DAO governance for protocol upgrades

---

## Libraries

### ResolverLogicLibrary.sol
**Purpose**: Helper functions for resolver operations  
**Key Features**:
- Payout validation
- Yield calculation
- Array manipulation

**Use Case**: Reusable logic for resolution operations

---

### EscrowEncodingLibrary.sol
**Purpose**: Encoding/decoding escrow data  
**Key Features**:
- Escrow data encoding
- Data structure serialization

**Use Case**: Encoding escrow information for module communication

---

### SettingsValidationLibrary.sol
**Purpose**: Validation functions for escrow settings  
**Key Features**:
- Settings validation
- Parameter bounds checking

**Use Case**: Ensure escrow settings are valid before creation

---

### YieldDistributionLibrary.sol
**Purpose**: Yield distribution calculations  
**Key Features**:
- Distribution calculations
- Percentage validation

**Use Case**: Calculate yield distribution amounts

---

## Interfaces

### IResolutionModule.sol
**Purpose**: Standard interface for resolution modules  
**Key Features**:
- Resolver assignment
- Authorization checking
- Escalation support

**Use Case**: Pluggable resolution system

---

### IYieldGenerationModule.sol
**Purpose**: Interface for yield generation  
**Key Features**:
- Deposit/withdraw functions
- Yield calculation

**Use Case**: Pluggable yield generation

---

### IYieldDistributionModule.sol
**Purpose**: Interface for yield distribution  
**Key Features**:
- Distribution configuration
- Yield allocation

**Use Case**: Pluggable yield distribution

---

### IResolver.sol
**Purpose**: Interface for resolver contracts  
**Key Features**:
- Dispute callbacks
- Resolution functions

**Use Case**: Custom resolver implementations

---

## Mocks & Test Utilities

### ERC20Mock.sol
**Purpose**: Mock ERC20 token for testing  
**Key Features**:
- Standard ERC20 implementation
- Mint/burn functions

**Use Case**: Testing escrow functionality

---

### MockAavePool.sol
**Purpose**: Mock Aave pool for testing  
**Key Features**:
- Simulates Aave interactions

**Use Case**: Testing yield generation without mainnet Aave

---

## Architecture Overview

```
┌─────────────────────────────────────────┐
│   Escrow Contracts                      │
│   - EscrowVault (multi-token)           │
│   - EscrowableERC20 (single-token)      │
│   (inherit from BaseEscrow)            │
└──────────────┬──────────────────────────┘
               │
               ├─> Resolution Modules
               │   - DefaultResolutionModule (simple)
               │   - DecentralizedResolutionModule (advanced)
               │
               ├─> Yield Generation
               │   - AaveYieldGenerationModule
               │
               ├─> Yield Distribution
               │   - DefaultYieldDistributionModule
               │
               └─> Resolver Incentives
                   - ResolverIncentiveModule
                       └─> PaymentCalculationLibraryV1
```

---

## Key Design Patterns

1. **Modular Architecture**: Pluggable modules for resolution, yield generation, and distribution
2. **Unified Module Governance**: All modules use Slow lane swap pattern (immutable modules, ~9 days)
3. **Functional/Hybrid Approach**: Pure functions for calculations, imperative for state
4. **Round-Robin Selection**: Fair distribution of resolver workload (DecentralizedResolutionModule)
5. **Immutable Modules**: All modules are immutable - upgrades via deploy new version + swap

---

## Contract Relationships

- **BaseEscrow** → Core functionality for all escrow types
- **EscrowVault/EscrowableERC20** → Specific escrow implementations
- **Resolution Modules** → Pluggable dispute resolution
- **ResolverIncentiveModule** → Tracks and pays resolvers
- **PaymentCalculationLibraryV1** → Calculates payment amounts
- **Yield Modules** → Optional yield generation and distribution

---

*This summary provides a high-level overview. For detailed implementation, see individual contract files and documentation.*



