# Contract Naming Review: Auditor Clarity

**Goal**: Each contract name should immediately convey:
1. What it does
2. Whether it's mutable/immutable
3. Its role in the system
4. Whether it's a singleton or multi-instance

---

## Current Naming Issues

### ❌ Problem Contracts

1. **EscrowAdminContract**
   - Issue: "Admin" implies direct control over escrows
   - Reality: Time-delayed governance for escrow parameters
   - Confusion: Sounds like it can admin individual escrows

2. **ModuleManagementContract**
   - Issue: "Management" is vague
   - Reality: Immutable snapshot registry for module configurations
   - Confusion: Sounds like it manages/changes modules

3. **DefaultYieldModule**
   - Issue: Inconsistent with other yield modules
   - Reality: Same as AaveYieldGenerationModule but default implementation
   - Confusion: Missing "Generation" in name

---

## Proposed Naming Convention

```
Pattern: [Domain][Purpose][Type]

Domain: Escrow, Module, Bond, Yield, Dispute, etc.
Purpose: What it does (Governance, Registry, Coordinator, etc.)
Type: Contract, Module, Ops, View, Helper

Examples:
- EscrowGovernanceTimelock (governance for escrow params)
- ModuleSnapshotRegistry (immutable module snapshots)
- BondTrackingRegistry (tracks posted bonds)
```

### Suffixes & Their Meaning

| Suffix | Meaning | Mutability | Examples |
|--------|---------|------------|----------|
| **Ops** | Operational logic library | Immutable | CreateOps, YieldOps |
| **Registry** | Records/tracks state | Mutable state | ModuleSnapshotRegistry |
| **Timelock** | Time-delayed governance | Governance-controlled | EscrowGovernanceTimelock |
| **Module** | Pluggable component | Configurable | AaveYieldGenerationModule |
| **View** | Read-only queries | Stateless | EscrowView |
| **Contract** | General escrow implementation | Varies | BaseEscrow |
| **Helper** | Utility/assistant | Typically stateless | (future use) |

---

## Proposed Renames

### Infrastructure - Singleton Contracts

#### Ops (No Changes - Already Clear)
✅ **CreateOps** - Operational logic for escrow creation
✅ **YieldOps** - Operational logic for yield management
✅ **DisputeOps** - Operational logic for dispute handling
✅ **SettlementOps** - Operational logic for escrow settlement
✅ **GuardianOps** - Operational logic for guardian actions

#### Management (3 Renames)

**Current:** `EscrowAdminContract`  
**Proposed:** `EscrowGovernanceTimelock`  
**Why:** Makes it clear this is a time-delayed governance contract for escrow parameters, not direct admin control  
**Description:** Time-delayed governance controller for managing escrow configuration parameters (fees, modules, resolution) across all escrow contracts.

---

**Current:** `ModuleManagementContract`  
**Proposed:** `ModuleSnapshotRegistry`  
**Why:** Emphasizes immutability - snapshots are frozen at creation, not "managed"  
**Description:** Immutable registry that snapshots module configurations at escrow creation, ensuring deployed escrows maintain consistent module references throughout their lifecycle.

---

**Current:** `BondCollector`  
**Proposed:** `AppealBondRegistry` OR keep as `BondCollector`  
**Why:** "Registry" emphasizes tracking/recording role; "Collector" is also acceptable  
**Description:** Registry for tracking appeal bond deposits, releases, and slashing during dispute escalation across all escrow contracts.

**Recommendation:** Keep as `BondCollector` (already clear)

#### Views (No Change)

✅ **EscrowViewContract** → Could shorten to **EscrowView**  
**Description:** Read-only view contract providing aggregated query functions for escrow state across all escrow implementations.

---

### Escrow - Multi-Instance Contracts

✅ **BaseEscrow** - No change (standard abstract base pattern)  
**Description:** Abstract base contract defining core escrow lifecycle (create, dispute, settle, release) shared by all escrow implementations.

✅ **EscrowVault** - No change (clear)  
**Description:** Vault-based escrow implementation for token-agnostic peer-to-peer escrows with pluggable yield generation and dispute resolution.

✅ **EscrowableERC20** - No change (clear)  
**Description:** ERC20 token contract with integrated escrow functionality, enabling direct token escrows with built-in yield generation and disputes.

---

### Modules - Singleton Module Contracts

#### Yield Modules (1 Rename for Consistency)

✅ **AaveYieldGenerationModule** - No change  
**Description:** Yield generation module that deposits escrow funds to Aave V3 lending pools, supporting multi-escrow multi-token yield aggregation.

**Current:** `DefaultYieldModule`  
**Proposed:** `DefaultYieldGenerationModule`  
**Why:** Consistency with AaveYieldGenerationModule naming  
**Description:** Default no-op yield generation module that holds funds in the vault without generating external yield (baseline implementation).

✅ **DefaultYieldDistributionModule** - No change  
**Description:** Default yield distribution module that allocates generated yield between protocol fees, seller allocation, and buyer allocation per escrow settings.

✅ **TestYieldDistributionModule** - No change (test contract)  
**Description:** Test implementation of yield distribution module for testing custom distribution logic.

#### Resolution Modules (No Changes)

✅ **DefaultResolutionModule** - No change  
**Description:** Default dispute resolution module enabling single-resolver dispute escalation with time-bounded resolution phases.

✅ **DefaultReleaseStrategy** - No change  
**Description:** Default release strategy module defining standard escrow release conditions (buyer/seller approval, timeout, resolution).

---

## Summary of Proposed Changes

### Required Renames (High Priority)

| Current | Proposed | Justification |
|---------|----------|---------------|
| `EscrowAdminContract` | `EscrowGovernanceTimelock` | Clarifies time-delayed governance role, not direct admin |
| `ModuleManagementContract` | `ModuleSnapshotRegistry` | Emphasizes immutability of snapshots |
| `DefaultYieldModule` | `DefaultYieldGenerationModule` | Consistency with Aave module naming |

### Optional Improvements (Low Priority)

| Current | Proposed | Justification |
|---------|----------|---------------|
| `EscrowViewContract` | `EscrowView` | Shorter, "View" suffix implies contract |
| `BondCollector` | `AppealBondRegistry` | "Registry" emphasizes tracking role (but current is fine) |

---

## Naming Convention Summary

### For Future Contracts

```
Infrastructure Singletons:
  - [Purpose]Ops (e.g., CreateOps) - Operational logic libraries
  - [Domain][Purpose]Registry (e.g., ModuleSnapshotRegistry) - State tracking
  - [Domain][Purpose]Timelock (e.g., EscrowGovernanceTimelock) - Governance
  - [Domain]View (e.g., EscrowView) - Read-only queries

Escrow Multi-Instance:
  - Base[Type] (e.g., BaseEscrow) - Abstract base
  - Escrow[Variant] (e.g., EscrowVault) - Implementations
  - Escrowable[Type] (e.g., EscrowableERC20) - Token-integrated

Modules:
  - [Implementation][Domain][Type]Module
    Examples:
    - AaveYieldGenerationModule
    - DefaultYieldGenerationModule
    - CustomResolutionModule
```

---

## Benefits of Proposed Changes

### For Auditors

1. **EscrowGovernanceTimelock**
   - ✅ "Governance" = governance-controlled
   - ✅ "Timelock" = time-delayed changes
   - ✅ "Escrow" = affects escrow parameters
   - ❌ "Admin" removed (implies direct control)

2. **ModuleSnapshotRegistry**
   - ✅ "Snapshot" = immutable capture
   - ✅ "Registry" = records/tracks
   - ✅ Clear that it doesn't "manage" modules actively
   - ❌ "Management" removed (implies active changes)

3. **DefaultYieldGenerationModule**
   - ✅ Consistent with AaveYieldGenerationModule
   - ✅ "Generation" clarifies it generates yield (even if no-op)
   - ✅ Parallel naming for similar functionality

### For Developers

1. **Consistent Patterns**
   - All yield generation modules end with "GenerationModule"
   - All ops contracts end with "Ops"
   - All registries end with "Registry"

2. **Clear Purpose**
   - Name tells you what it does
   - Suffix tells you category
   - Prefix tells you domain

3. **Easy Discovery**
   - Looking for governance? Search "Governance"
   - Looking for immutable snapshots? Search "Registry" or "Snapshot"
   - Looking for operational logic? Search "Ops"

---

## Implementation Plan

### Phase 1: Rename Contracts (Files)
```bash
# High priority renames
git mv contracts/admin/EscrowAdminContract.sol \
       contracts/admin/EscrowGovernanceTimelock.sol

git mv contracts/core/ModuleManagementContract.sol \
       contracts/core/ModuleSnapshotRegistry.sol

git mv contracts/modules/DefaultYieldModule.sol \
       contracts/modules/DefaultYieldGenerationModule.sol

# Optional renames
git mv contracts/core/EscrowViewContract.sol \
       contracts/core/EscrowView.sol
```

### Phase 2: Update Contract Declarations
```solidity
// Before
contract EscrowAdminContract { ... }

// After
contract EscrowGovernanceTimelock { ... }
```

### Phase 3: Update All Imports
```bash
# Automated with sed/script
find . -name "*.sol" -exec sed -i \
  's/EscrowAdminContract/EscrowGovernanceTimelock/g' {} \;
```

### Phase 4: Update Documentation
- README.md
- All architecture docs
- Deployment guides
- Test documentation

### Phase 5: Update Deploy Scripts
- deploy/ directory
- Hardhat deployment scripts
- Foundry scripts

### Phase 6: Test Everything
```bash
forge build
forge test
npm run compile
npm test
```

---

## Timeline

| Phase | Task | Time |
|-------|------|------|
| 1 | Rename files | 15 min |
| 2 | Update contract declarations | 15 min |
| 3 | Update imports | 30 min |
| 4 | Update documentation | 45 min |
| 5 | Update deploy scripts | 30 min |
| 6 | Test everything | 20 min |
| **TOTAL** | | **~2.5 hours** |

---

## Rollback Plan

All changes tracked by git:
```bash
git reset --hard HEAD  # Before commit
git revert <commit>    # After commit
```

---

## Recommendation

**Proceed with high-priority renames:**
1. ✅ EscrowAdminContract → EscrowGovernanceTimelock
2. ✅ ModuleManagementContract → ModuleSnapshotRegistry  
3. ✅ DefaultYieldModule → DefaultYieldGenerationModule

**Optional (low priority):**
4. ⚠️ EscrowViewContract → EscrowView (can do later)
5. ⚠️ BondCollector → AppealBondRegistry (current name is fine)

**Combine with directory reorganization:**
- Do renames BEFORE directory moves
- Then directory reorg uses new names
- Single comprehensive PR

**Total time:** 2.5 hours (renames) + 4 hours (reorg) = 6.5 hours

---

## Decision

**Awaiting approval for:**
1. Contract renames (which ones?)
2. Do renames before or after directory reorg?
3. Combine into single PR or separate?

