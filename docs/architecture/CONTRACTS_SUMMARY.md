# Contracts Summary

Succinct overview of the major contracts and their roles.

**Last Updated**: 2026-01

---

## Core Escrow Contracts

### `BaseEscrow.sol`

**Purpose**: Abstract base contract providing core escrow functionality  
**Key Features**:

- Multi-token escrow support (ERC20)
- Dispute resolution system
- Escalation support
- Fee management
- Integration with resolution modules, yield generation, and yield distribution modules

**Inherited by**: `EscrowVault`, `EscrowableERC20`

---

### `EscrowVault.sol`

**Purpose**: Multi-token escrow vault for holding multiple token types  
**Key Features**:

- Supports any ERC20 token
- Per-token fee tracking
- Batch operations
- Resolution module integration
- Yield generation support (Aave)

**Use case**: When you need to escrow multiple different tokens in a single contract

---

### `EscrowableERC20.sol`

**Purpose**: ERC20 token with built-in escrow functionality  
**Key Features**:

- Standard ERC20 token
- Built-in `createEscrow()` function (primary function name)
- Automatic fee deduction
- Single-token escrow (token is both payment and escrow medium)
- Factory pattern for deployment

**Use case**: When you want a token that has escrow capabilities built-in

---

## Resolution Modules

### `DefaultResolutionModule.sol`

**Purpose**: Simple, single-resolver resolution module  
**Key Features**:

- Single resolver assignment
- No escalation support
- Minimal configuration
- Governance-controlled resolver updates

**Use case**: Simple disputes that don't need escalation or multiple resolvers

---

### `DecentralizedResolutionModule.sol`

**Purpose**: Advanced decentralized resolution with multiple resolvers and escalation  
**Status**: ✅ Complete and production-ready. Lives in separate package (`contracts/decentralized-resolution-module/`). Deployed post-IEO via Slow lane governance (queue + activate, ~9 days). DR v3 (staking + slashing) is now fully implemented.  
**Key Features**:

- Resolver registry (standard and senior resolvers)
- Round-robin resolver selection (fair distribution)
- Three-level escalation (standard → senior → external)
- Dynamic resolution table (category-based assignment)
- Integration with ResolverIncentiveModule

**Use case**: Complex disputes requiring multiple resolvers, escalation paths, and fair workload distribution

---

## Payment & Incentive System

### `ResolverIncentiveModule*.sol`

**Purpose**: Tracks and distributes payments to dispute resolvers  
**Key Features**:

- Resolver involvement tracking
- Fee aggregation (escrow fees + escalation fees)
- Payment calculation using pluggable libraries
- Automatic payment distribution (ERC20)
- Governance-controlled configuration (Slow lane, ~9 days)
- Configurable resolver share percentage and weights

**Use case**: Incentivizing resolvers by paying them a share of collected fees

---

### `PaymentCalculationLibraryV1.sol`

**Purpose**: Payment calculation library (Version 1)  
**Key Features**:

- Weighted distribution by escalation level
- Pure functions (no state)
- Extensible input/output design
- Version detection support

**Use case**: Calculates how much each resolver should be paid based on their involvement level

---

## Yield Modules

### `AaveYieldGenerationModule*.sol`

**Purpose**: Generates yield on escrowed funds using Aave  
**Key Features**:

- Deposits tokens to Aave lending pool
- Tracks yield per escrow
- Proportional yield calculation
- Withdrawal with yield

**Use case**: Earn interest on escrowed funds while they're locked

---

### `DefaultYieldDistributionModule.sol`

**Purpose**: Distributes yield deterministically by preset  
**Key Features**:

- Yield distribution derived from `YieldPreset`
- Simple preset-based distribution (e.g., `OFF`, `TO_SENDER`)

**Use case**: Share yield between parties (e.g., sender and recipient) without per-escrow distributions

---

## Governance

### `GovGovernor.sol`

**Purpose**: Governance governor for DAO proposals  
**Key Features**:

- Proposal creation and execution
- Voting mechanism
- Timelock integration
- Quorum definition (see `docs/governance/`)

**Use case**: DAO governance for protocol upgrades

---

## Architecture Overview (high-level)

```
┌─────────────────────────────────────────┐
│   Escrow Contracts                      │
│   - EscrowVault (multi-token)           │
│   - EscrowableERC20 (single-token)      │
│   (inherit from BaseEscrow)             │
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
                   - ResolverIncentiveModule*
                       └─> PaymentCalculationLibraryV1
```


---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Generated from contract source enumeration and manually reviewed for accuracy. Contract descriptions verified against NatSpec and function signatures. Reflects contract set at `sew-protocol @ 62fce3a`. Will require update if new contracts are added. |
