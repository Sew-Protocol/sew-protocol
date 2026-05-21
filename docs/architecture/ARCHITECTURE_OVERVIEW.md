# Architecture Overview

**Last Updated:** 2026-01-16  
**Purpose:** High-level architectural overview of the Sew Protocol escrow system

---

## Introduction

Sew Protocol is a decentralized escrow and dispute-resolution system built on Base (Ethereum L2). It provides trustless, reversible payments for everyday purchases of physical goods through a modular, governance-controlled architecture.

---

## Core Principles

The protocol is built on four fundamental principles:

1. **Trustlessness**: No single party controls funds or can unilaterally modify escrow rules
2. **Immutability**: Escrow rules are snapshotted at creation and cannot be changed
3. **Modularity**: Pluggable modules for resolution, yield, and distribution
4. **Transparency**: All operations are onchain and publicly verifiable

---

## System Architecture

### High-Level Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Sew Protocol                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐      ┌──────────────────┐          │
│  │  Core Escrow     │      │   Governance     │          │
│  │  Contracts       │◄─────┤   System         │          │
│  │  (Immutable)     │      │   (Timelock)     │          │
│  └──────────────────┘      └──────────────────┘          │
│         │                                                    │
│         ├──────────────────────────────────────┐           │
│         │                                      │           │
│  ┌──────▼──────┐  ┌──────────▼──────────┐    │           │
│  │ Resolution  │  │  Yield Generation   │    │           │
│  │  Modules    │  │  Modules             │    │           │
│  │ (Swappable) │  │  (Swappable)        │    │           │
│  └────────────┘  └─────────────────────┘    │           │
│         │                                      │           │
│         └──────────┬──────────────────────────┘           │
│                    │                                        │
│            ┌───────▼────────┐                             │
│            │  Distribution  │                             │
│            │    Modules      │                             │
│            │  (Swappable)    │                             │
│            └─────────────────┘                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Escrow Contracts

The protocol provides three core escrow contract types, all built on an immutable foundation:

### BaseEscrow

**Abstract base contract** providing shared escrow functionality:

- **Multi-token support**: Escrow any ERC20 token
- **State machine**: Manages escrow lifecycle (Pending → Funded → Disputed → Resolved/Cancelled)
- **Dispute resolution**: Integrates with resolution modules
- **Fee management**: Tracks and collects protocol fees
- **Fee immutability**: Protocol fees (yield and appeal bond) snapshotted per-escrow at creation, ensuring fees cannot change during escrow lifetime
- **Module integration**: Pluggable resolution, yield, and distribution modules
- **Snapshot semantics**: Escrow rules, modules, and fees locked at creation, immune to governance changes

**Key Features:**
- Immutable core (no proxies) for maximum security
- Account abstraction compatible (works with smart contract wallets and legacy EOAs)
- Access control via OpenZeppelin AccessControl
- Reentrancy protection
- Pausable (guardian-controlled emergency pause)

### EscrowVault

**Multi-token escrow vault** supporting any ERC20 token:

- **Use Case**: When you need to escrow multiple different tokens in a single contract
- **Features**: 
  - Per-token fee tracking
  - Batch operations
  - Resolution module integration
  - Yield generation support (Aave)
- **Deployment**: Immutable (no proxies)

**Ideal for**: Marketplaces, multi-token use cases, complex escrow scenarios

### EscrowableERC20

**ERC20 token with built-in escrow functionality**:

- **Use Case**: When you want a token that has escrow capabilities built-in
- **Features**: 
  - Standard ERC20 functionality
  - Built-in `createEscrow()` function
  - Automatic fee deduction
  - Single-token escrow (token is both payment and escrow medium)
- **Deployment**: Factory pattern for easy token creation

**Ideal for**: Token-specific escrow use cases, branded payment tokens

---

## Modular Architecture

The protocol uses a **modular architecture** where core functionality is split into swappable modules. This enables:

- **Evolution**: Modules can be upgraded without changing core contracts
- **Flexibility**: Different modules can be swapped in for different use cases
- **Safety**: Module changes are time-delayed and transparent
- **Immutability**: Existing escrows are unaffected by module changes (snapshot semantics)

### Module Types

#### 1. Resolution Modules

Handle dispute resolution and escalation:

- **DefaultResolutionModule**: Simple single-resolver system (initial mainnet deployment)
  - Single trusted resolver per escrow
  - Governance-controlled resolver updates
  - Suitable for initial launch and simple disputes

- **DecentralizedResolutionModule**: Advanced multi-resolver system with escalation — ✅ complete; activated post-IEO via Slow lane governance
  - Multi-resolver registry with round-robin selection
  - Three-level escalation: Standard → Senior → External resolver
  - Category-based dispute routing
  - Resolver incentive system
  - Staged rollout: DR v1 (decisions) → DR v2 (incentives) → DR v3 (capital)

**Module Governance**: All modules are immutable. Module upgrades are performed by deploying a new version and swapping via Slow lane (queue + activate, ~9 days). Both queue and activate operations require Timelock execution (ROLE_TIMELOCK), ensuring all module changes are time-delayed and transparent.

#### 2. Release Strategy Modules

Determine when and how escrow funds can be released:

- **DefaultReleaseStrategy**: Standard release mechanism
  - Time-based releases
  - Conditional releases
  - Dispute-triggered releases

**Change Mechanism**: Slow lane (queue/activate)

#### 3. Yield Generation Modules

Generate yield on escrowed funds:

- **AaveYieldGenerationModule**: Generates yield via Aave integration
  - Optional per-escrow yield generation
  - Protected by exposure caps and pause mechanisms
  - Governance-controlled enable/disable
  - Token-specific caps and registration

**Change Mechanism**: Slow lane (queue/activate)  
**Configuration**: Standard lane (48h) for token registration, caps, etc.  
**Emergency Controls**: Guardian can disable Aave or lower caps (down-only)

#### 4. Yield Distribution Modules

Distribute generated yield to recipients:

- **DefaultYieldDistributionModule**: Configurable yield distribution
  - Percentage-based allocation
  - Multiple recipients support
  - Immutable at escrow creation

**Change Mechanism**: Slow lane (queue/activate)

---

## Governance Architecture

The protocol uses **onchain governance** with time-delayed execution:

### Governance Components

- **GovGovernor**: OpenZeppelin Governor for proposal creation and voting
- **TimelockController**: Time-delayed execution of governance actions
- **SewToken**: Governance token for voting

### Governance Lanes

The protocol uses three governance lanes with different time delays:

1. **Standard Lane** (48 hours)
   - Bounded parameter updates
   - Module configuration changes
   - Low-risk operations

2. **Slow Lane** (~9 days: 48h queue + 7 days + 48h activate)
   - Module swaps
   - High-risk parameter changes
   - Protocol upgrades

3. **Emergency Lane** (0 hours, down-only)
   - Guardian-controlled pause
   - Risk reduction (lower caps, disable features)
   - Cannot increase risk or unpause

### Snapshot Immutability

**Key Guarantee**: Once an escrow is created, its rules (modules, timeouts, resolver) cannot be changed by any actor, including governance. This ensures:

- **Predictability**: Users know exactly what rules apply to their escrow
- **Security**: No retroactive changes to existing escrows
- **Trust**: Governance can only affect new escrows

---

## Security Architecture

### Access Control

The protocol uses OpenZeppelin's AccessControl with the following roles:

- **ROLE_TIMELOCK**: TimelockController (governance execution)
- **ROLE_GUARDIAN**: Emergency controls (pause, risk reduction)

**Note on `DEFAULT_ADMIN_ROLE` (AccessControl):** `DEFAULT_ADMIN_ROLE` exists as the role-administration mechanism in OpenZeppelin AccessControl, but it is **not** part of the protocol’s operational “lane” model. Best practice is:
- Ensure **TimelockController** holds the effective role-admin powers post-deployment (directly or via role admin configuration).
- Ensure the **deployer / EOAs do not retain** `DEFAULT_ADMIN_ROLE` after governance wiring (revoke/renounce as part of the deployment runbook).

### Emergency Controls

- **Pause Mechanism**: Guardian can pause protocol operations
- **Risk Reduction**: Guardian can lower caps, disable features (down-only)
- **No Risk Increase**: Guardian cannot increase risk or unpause (requires governance)

### Immutability Guarantees

- **Core Contracts**: Immutable (no proxies)
- **Escrow Rules**: Snapshotted at creation, cannot be changed
- **Module Upgrades**: Only affect new escrows (snapshot semantics)

---

## Integration Points

### External Protocols

- **Aave**: Yield generation on escrowed funds
- **Kleros**: External dispute resolution (DR v3 escalation level)
- **Account Abstraction**: Compatible with smart contract wallets

### User Interfaces

- **EOAs**: Standard Ethereum accounts
- **Smart Contract Wallets**: Account abstraction compatible
- **dApps**: Standard ERC20 interface for integration

---

## Data Flow

### Escrow Creation Flow

```
User → createEscrow()
  → BaseEscrow.snapshotModules()
  → Store escrow settings (modules, timeouts, resolver)
  → Escrow in Pending state
```

### Dispute Resolution Flow

```
User → raiseDispute()
  → Resolution Module.getResolver()
  → Resolver resolves dispute
  → Resolution Module.executeResolution()
  → Escrow state updated
```

### Yield Generation Flow

```
Escrow funded → Yield Module.depositForYield()
  → Aave deposit
  → Yield accrues
  → Escrow released/refunded → Yield Module.withdrawWithYield()
  → Yield distributed via Distribution Module
```

---

## Key Architectural Decisions

### 1. Immutable Core Contracts

**Decision**: Core escrow contracts are immutable (no proxies)

**Rationale**:
- Maximum security and auditability
- No upgrade attack surface
- Clear security model

**Trade-off**: Module-based evolution instead of contract upgrades

### 2. Snapshot Semantics

**Decision**: Escrow rules are snapshotted at creation

**Rationale**:
- Predictability for users
- No retroactive changes
- Governance can only affect new escrows

**Trade-off**: Cannot update existing escrows (by design)

### 3. Modular Architecture

**Decision**: Pluggable modules for resolution, yield, and distribution

**Rationale**:
- Evolution without core changes
- Flexibility for different use cases
- Clear separation of concerns

**Trade-off**: More complex initial setup, requires module management

### 4. Time-Delayed Governance

**Decision**: All governance changes are time-delayed

**Rationale**:
- Transparency and review period
- Prevents sudden changes
- Allows community response

**Trade-off**: Slower iteration, but safer

---

## See Also

### Architecture Documentation
- **[Escrow Creation and Settings](./ESCROW_CREATION_AND_SETTINGS.md)** - Escrow creation flow and settings
- **[Protocol Fees](./PROTOCOL_FEES.md)** - Protocol fee architecture and governance
- **[Yield Distribution](./YIELD_DISTRIBUTION.md)** - Yield generation and distribution architecture

### Reference Documentation
- **[Module Map](../reference/MODULE_MAP.md)** - Complete module interface → implementation mapping
- **[Module Development Guide](../reference/MODULE_DEVELOPMENT_GUIDE.md)** - Guide for developing new modules
- **[Module Upgrade Strategy](../reference/MODULE_UPGRADE_STRATEGY.md)** - Module upgrade procedures

### Governance Documentation
- **[Governance Process](../governance/GOVERNANCE_PROCESS.md)** - Step-by-step governance workflow
- **[Governance Surface Map](../governance/GOVERNANCE_SURFACE_MAP.md)** - Complete function → role → lane mapping

### Security Documentation
- **[Security Model](../reviews/SECURITY_MODEL.md)** - Security model and threat analysis

### Protocol Documentation
- **[Whitepaper](../WHITEPAPER.md)** - Complete protocol whitepaper

---

## Summary

Sew Protocol's architecture is designed for:

- **Security**: Immutable core, time-delayed governance, emergency controls
- **Flexibility**: Modular design allows evolution without core changes
- **Trustlessness**: No custodians, no single point of failure
- **Transparency**: All operations onchain, publicly verifiable
- **User Protection**: Snapshot immutability ensures predictable rules

The protocol provides a solid foundation for trustless, reversible payments while maintaining the ability to evolve through governance-controlled module upgrades.

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually reviewed against contract directory structure and subsystem decomposition. Component boundaries verified against import graph and role assignments. Updated to reflect DR v3 implementation status. Formal architectural conformance (e.g., layer isolation) not automatically verified — needs follow-up. |
