# Dispute Resolution Staged Implementation TODOs

**Date**: 2025-01-XX  
**Status**: In Progress  
**Based on**: `DR_STAGING_PLAN.md`  
**Goal**: Atomic, testable TODOs for each phase of decentralised dispute resolution rollout

---

## Overview

This document translates the staged rollout plan (`DR_STAGING_PLAN.md`) into concrete, atomic, testable code-level tasks. Each TODO is:

- **Atomic**: Represents a single, complete change
- **Testable**: Can be validated with a specific test
- **Phase-aligned**: Tagged with target phase (IEO, DR v1, DR v2, DR v3)

---

## IEO + Central Resolver (Pre-DR)

**Target**: 1 March  
**Status**: ✅ Excluded from IEO (DR module not in initial release)

### TODOs: N/A

- Decentralised dispute resolution module is explicitly excluded from IEO release
- DefaultResolutionModule remains active for IEO
- Focus is on shipping core escrow functionality and funding DR testing

---

## DR v1 — Decentralise Decisions

**Goal**: Multiple resolvers, random allocation, escalations, Kleros backstop — but **no resolver capital at risk**

### v1.1: Workload Routing Controls (Performance-Based Assignment)

#### v1.1.1: Add Assignment Weight Configuration

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol`
- **Task**: Add `assignmentWeight` field to `ResolverStats` struct (uint256, basis points 0-10000)
- **Test**: Verify struct allows weight 0-10000, defaults to 10000 for new resolvers
- **Dependencies**: None

#### v1.1.2: Implement Workload-to-Zero Mechanism

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add function `setResolverAssignmentWeight(address resolver, uint256 weight)` (onlyRole(ROLE_TIMELOCK))
- **Task**: Modify `selectResolverWithQuality` to respect assignment weight (weight=0 → exclude from selection)
- **Test**: Verify resolver with weight=0 receives no assignments
- **Test**: Verify resolver with weight=5000 receives half the expected workload vs weight=10000
- **Dependencies**: v1.1.1

#### v1.1.3: Update Performance Signal Tracking

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Ensure `recordResolution()` updates quality score based on: SLA compliance, escalations, reversals
- **Task**: Add helper function `calculateAssignmentWeight(address resolver) → uint256` that maps quality score to weight
- **Test**: Verify weight decreases when quality score drops below thresholds
- **Dependencies**: v1.1.2

#### v1.1.4: Add Workload Routing Events

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add event `ResolverAssignmentWeightUpdated(address indexed resolver, uint256 oldWeight, uint256 newWeight)`
- **Test**: Verify event emitted on weight changes
- **Dependencies**: v1.1.2

### v1.2: Ensure No Resolver Capital at Risk

#### v1.2.1: Verify No Staking Interface in v1

- **File**: Review all resolution module contracts
- **Task**: Confirm no `stake()`, `slash()`, or resolver bond functions exist
- **Task**: Document that v1 explicitly avoids resolver staking/slashing
- **Test**: Verify compilation fails if staking functions are accidentally added
- **Dependencies**: None

#### v1.2.2: Document v1 Constraints in Code

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add NatSpec comment at contract level: "DR v1: No resolver capital at risk. Workload routing is primary incentive lever."
- **Dependencies**: None

### v1.3: Phase Gate Validation (Exit Criteria)

#### v1.3.1: Add Phase Gate Monitoring Functions

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add view function `getV1PhaseGateMetrics() → (uint256 escalationRate, uint256 avgResponseTime, uint256 activeResolvers)`
- **Test**: Verify metrics reflect real system state
- **Dependencies**: Existing stats tracking

---

## DR v2 — Decentralise Incentives (User Bonds, Not Resolver Bonds)

**Goal**: Add escalation/appeal bonds and increasing cost curves to prevent griefing, **without** resolver staking

### v2.1: Appeal Bond Infrastructure

#### v2.1.1: Add Appeal Bond Struct

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol`
- **Task**: Add struct `AppealBond { address depositor; uint256 amount; address token; uint256 depositedAt; bool refunded; }`
- **Task**: Add mapping `mapping(uint256 => mapping(uint8 => AppealBond)) public appealBonds;` (workflowId → escalationLevel → bond)
- **Test**: Verify struct fields are correctly stored/retrieved
- **Dependencies**: None

#### v2.1.2: Extend IResolutionModule Interface for Bonds

- **File**: `contracts/shared/interfaces/IResolutionModule.sol`
- **Task**: Add function `getRequiredAppealBond(uint256 workflowId, uint8 currentLevel, bytes calldata escrowData) → (uint256 amount, address token)`
- **Task**: Update `canEscalate()` return to include bond requirement (extend return struct or add separate view function)
- **Test**: Verify interface compiles and existing implementations are backward compatible
- **Dependencies**: v2.1.1

#### v2.1.3: Implement Bond Collection in BaseEscrow

- **File**: `contracts/core/BaseEscrow.sol` or `contracts/DisputeOps.sol`
- **Task**: Modify escalation flow to require bond deposit before escalation
- **Task**: Add function `_collectAppealBond(uint256 workflowId, uint8 level, uint256 amount, address token)`
- **Test**: Verify escalation fails if bond not paid
- **Test**: Verify bond is correctly tracked per escalation level
- **Dependencies**: v2.1.2

#### v2.1.4: Implement Bond Redistribution Logic

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add function `distributeAppealBond(uint256 workflowId, uint8 level, bool appealSucceeded)`
- **Task**: Logic: If appeal fails (decision upheld) → bond goes to previous resolver(s) or treasury
- **Task**: Logic: If appeal succeeds (reversed) → bond returned to escalator (or partially returned)
- **Test**: Verify bond distribution on successful appeal
- **Test**: Verify bond distribution on failed appeal
- **Dependencies**: v2.1.3

### v2.2: Escalation Cost Curve (Quadratic Default)

#### v2.2.1: Add Cost Curve Configuration

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolverStructs.sol`
- **Task**: Add enum `CostCurveType { LINEAR, QUADRATIC, GEOMETRIC }`
- **Task**: Add struct `EscalationCostConfig { CostCurveType curveType; uint256 baseCost; uint256 stepSize; uint256 multiplier; }`
- **Task**: Add mapping `mapping(uint8 => EscalationCostConfig) public escalationCostConfig;` (level → config)
- **Test**: Verify config struct stores all parameters correctly
- **Dependencies**: None

#### v2.2.2: Implement Cost Curve Calculation Library

- **File**: `contracts/decentralized-resolution-module/EscalationCostLibrary.sol` (new file)
- **Task**: Add pure function `calculateEscalationCost(uint8 level, EscalationCostConfig memory config) → uint256`
- **Task**: Implement quadratic: `cost(k) = baseCost + stepSize * k^2` (where k = escalation count)
- **Task**: Implement linear: `cost(k) = baseCost + stepSize * k`
- **Task**: Implement geometric: `cost(k) = baseCost * multiplier^k` (optional, for future use)
- **Test**: Verify quadratic cost for k=0,1,2,3 matches expected values
- **Test**: Verify costs increase appropriately with level
- **Dependencies**: v2.2.1

#### v2.2.3: Integrate Cost Curve into Escalation Flow

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Modify `canEscalate()` to use cost curve library to calculate required fee
- **Task**: Track escalation count per dispute: `mapping(uint256 => uint8) public disputeEscalationCount;`
- **Test**: Verify first escalation costs baseCost, second costs more (quadratic), third costs even more
- **Dependencies**: v2.2.2

#### v2.2.4: Add Cost Curve Governance

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add function `queueEscalationCostConfig(uint8 level, EscalationCostConfig memory config)` (onlyRole(ROLE_TIMELOCK))
- **Task**: Add function `activateEscalationCostConfig(uint8 level)` (onlyRole(ROLE_TIMELOCK), slow lane)
- **Test**: Verify config changes require slow lane activation
- **Dependencies**: v2.2.3

### v2.3: Ensure No Resolver Bonds in v2

#### v2.3.1: Verify No Resolver Staking in v2

- **File**: Review all v2 changes
- **Task**: Confirm appeal bonds are user-side only (escalator deposits bond, not resolver)
- **Task**: Document that v2 explicitly avoids resolver staking
- **Test**: Verify no resolver bond functions exist
- **Dependencies**: None

### v2.4: Phase Gate Validation

#### v2.4.1: Add v2 Phase Gate Monitoring

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add view function `getV2PhaseGateMetrics() → (uint256 appealSpamRate, uint256 bondRetentionRate, uint256 avgAppealCost)`
- **Test**: Verify metrics help assess if appeal spam is suppressed
- **Dependencies**: v2.1.4, v2.2.3

---

## DR v3 — Decentralise Capital (Resolver Bonds, Slashing)

**Goal**: Add resolver staking, slashing, senior backing, fraud lane — **only after v1/v2 are proven stable**

### v3.1: Interface Placeholders (Do Not Implement)

#### v3.1.1: Create IStakingModule Interface

- **File**: `contracts/shared/interfaces/IStakingModule.sol` (new file)
- **Task**: Define interface with functions: `stake(address resolver, uint256 amount, address token)`, `unstake(address resolver, uint256 amount)`, `getStake(address resolver, address token) → uint256`
- **Task**: Add NatSpec: "⚠️ DR v3 placeholder - Not implemented in v1/v2. Guarded behind module swap."
- **Test**: Verify interface compiles (no implementation needed)
- **Dependencies**: None

#### v3.1.2: Create ISlashingModule Interface

- **File**: `contracts/shared/interfaces/ISlashingModule.sol` (new file)
- **Task**: Define interface with functions: `slash(address resolver, uint256 amount, address token, string reason)`, `getSlashableAmount(address resolver, address token) → uint256`
- **Task**: Add NatSpec: "⚠️ DR v3 placeholder - Not implemented in v1/v2. Slashing must be objective and contract-executed."
- **Test**: Verify interface compiles (no implementation needed)
- **Dependencies**: None

#### v3.1.3: Create IFraudProofModule Interface

- **File**: `contracts/shared/interfaces/IFraudProofModule.sol` (new file)
- **Task**: Define interface with functions: `submitFraudProof(uint256 workflowId, bytes calldata proof)`, `verifyFraudProof(uint256 workflowId) → bool`
- **Task**: Add NatSpec: "⚠️ DR v3 placeholder - Not implemented in v1/v2. Fraud lane for investigation + execution."
- **Test**: Verify interface compiles (no implementation needed)
- **Dependencies**: None

#### v3.1.4: Add v3 Interface Guards

- **File**: `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
- **Task**: Add commented placeholder: `// IStakingModule public stakingModule; // DR v3 - guarded behind module swap`
- **Task**: Add NatSpec at contract level: "DR v3 interfaces (IStakingModule, ISlashingModule, IFraudProofModule) are placeholders. Not implemented until v1/v2 phase gates are met."
- **Test**: Verify code compiles with commented placeholders
- **Dependencies**: v3.1.1, v3.1.2, v3.1.3

### v3.2: Implementation TODOs (Future - Not in Current Scope)

#### v3.2.1: Resolver Bond Implementation

- **Status**: ⏸️ Deferred until v1/v2 phase gates met
- **Note**: Will require module swap to v3-compatible resolution module

#### v3.2.2: Slashing Implementation

- **Status**: ⏸️ Deferred until v1/v2 phase gates met
- **Note**: Must be objective and contract-executed (timeouts, provable non-response)

#### v3.2.3: Senior Backing Implementation

- **Status**: ⏸️ Deferred until v1/v2 phase gates met
- **Note**: Delegation/underwriting system for resolver bonds

#### v3.2.4: Fraud Lane Implementation

- **Status**: ⏸️ Deferred until v1/v2 phase gates met
- **Note**: Investigation + execution path for fraud proofs

---

## Testing Strategy

### Unit Tests

- Each TODO should have corresponding unit test
- Tests should be atomic (one test per TODO where possible)
- Use forge-std for fast, deterministic tests

### Integration Tests

- Test phase transitions (v1 → v2 → v3 readiness checks)
- Test governance flows (slow lane config changes)
- Test escalation flows with bonds and cost curves

### Phase Gate Tests

- Verify v1 metrics are collectable before v2 deployment
- Verify v2 metrics are collectable before v3 deployment
- Verify phase gates prevent premature upgrades

---

## Implementation Notes

### Constraints

- **Do NOT implement resolver slashing in this change** (v3 only)
- **Do NOT implement resolver bonds in this change** (v3 only)
- **Prefer minimal changes** that reduce time-to-IEO
- **v1/v2 changes should be small and low-risk** if implemented

### Architecture Alignment

- All changes must align with modular architecture (module swaps via governance)
- Changes must respect slow lane governance for critical parameters
- Changes must be backward compatible where possible (v1 → v2 upgrades)

### Documentation Requirements

- Each phase change must be documented in code (NatSpec)
- Interface placeholders must clearly indicate v3 status
- Phase gates must be documented in governance docs

---

## Phase Dependencies

```
IEO (Central Resolver)
  ↓
DR v1 (Decentralise Decisions)
  ├─→ Workload routing (v1.1)
  ├─→ No resolver capital at risk (v1.2)
  └─→ Phase gate metrics (v1.3)
       ↓
DR v2 (Decentralise Incentives - User Bonds)
  ├─→ Appeal bonds (v2.1)
  ├─→ Cost curves (v2.2)
  ├─→ No resolver bonds (v2.3)
  └─→ Phase gate metrics (v2.4)
       ↓
DR v3 (Decentralise Capital - Resolver Bonds)
  ├─→ Interface placeholders (v3.1) ← Current scope
  └─→ Implementation (v3.2) ← Future scope
```

---

## Status Tracking

- **IEO**: ✅ Excluded from release
- **DR v1**: ✅ **COMPLETE** - All TODOs implemented and tested
- **DR v2**: ✅ **COMPLETE** - All TODOs implemented, bond custody enforced, integration complete
- **DR v3**: ⚠️ **PARTIALLY COMPLETE** - Interfaces complete, staking complete, slashing mostly complete, fraud lane deferred
