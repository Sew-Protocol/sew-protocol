# Sew Protocol: Contract Dependency Map

## Overview

This document maps all contracts in the Sew protocol and shows:
- **What each contract does**
- **What other contracts it uses/calls**
- **Who calls it**
- **When it's used in workflows**

This helps developers understand how contracts relate to each other.

---

## Quick Reference: Contract Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    USER FACING LAYER                        │
│                                                             │
│  EscrowVault (multi-token)  ·  EscrowableERC20 (single-token)│
│                                                             │
└──────────────────────┬──────────────────────────────────────┘
                       │ Extends
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                  CORE ORCHESTRATION LAYER                   │
│                                                             │
│              BaseEscrow (Abstract)                          │
│        - Holds all escrow state                            │
│        - Orchestrates workflows                            │
│        - Delegates computation to *Ops contracts           │
│                                                             │
└──────────────────────┬──────────────────────────────────────┘
                       │ Uses
        ┌──────────────┼──────────────┬──────────────┐
        │              │              │              │
        ▼              ▼              ▼              ▼
    CreateOps     DisputeOps    SettlementOps   YieldOps
    (Compute)    (Compute)      (Compute)       (Logic)
        │              │              │              │
        │ Returns      │ Returns      │ Returns     │ Returns
        │ CreateResult │ Escalation   │ Resolution  │ YieldResult
        │             │ Result       │ Result      │
        └──────────────┴──────────────┴──────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   MODULE MANAGEMENT LAYER                   │
│                                                             │
│     ModuleManagementContract                               │
│   - Stores default modules per vault                       │
│   - Slow-lane activation (7-day delay)                     │
│   - Reads by: BaseEscrow during operations                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                 PLUGIN MODULES (Configurable)               │
│                                                             │
│  Yield Modules:         Resolution Modules:                │
│  - DefaultYieldModule   - DefaultResolutionModule          │
│  - AaveYieldGen.Module  - DecentralizedResolutionModule    │
│                         - KlerosArbitrableProxy            │
│                                                             │
│  Distribution Modules:  Release Strategies:                │
│  - DefaultYieldDist.    - DefaultReleaseStrategy           │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│              ADMINISTRATIVE & SUPPORT LAYER                 │
│                                                             │
│  EscrowAdminContract    BondCollector    EscrowViewContract│
│  - Fee configuration    - Bond handling  - Read-only views │
│  - Slow-lane settings   - Protocol fees  - Safe for indexer│
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│           GOVERNANCE & INFRASTRUCTURE LAYER                 │
│                                                             │
│  (Deployed separately - not part of core escrow)           │
│  - SewToken (ERC20Votes)                                   │
│  - GovGovernor (OpenZeppelin Governor)                     │
│  - TimelockController (2-day delay)                        │
│  - SlowLaneQueueActivate (base class, 7-day delay)         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Detailed Contract Map

### TIER 1: CORE ESCROW CONTRACTS

#### 1. **BaseEscrow** (Abstract)
**Location:** `contracts/core/BaseEscrow.sol`

**Purpose:** 
- Central state holder for all escrow operations
- Orchestrates complete escrow workflows
- Delegates computation to *Ops contracts

**Storage:**
```solidity
mapping(uint256 => EscrowTransfer) escrowTransfers;
mapping(uint256 => DisputeRecord) disputes;
mapping(uint256 => PendingSettlement) pendingSettlements;
mapping(address => uint256) totalHeldInEscrowPerToken;
```

**What It Uses (Calls):**
```
✓ CreateOps.computeEscrowCreation()
  ├─ Called during: createEscrow()
  └─ Gets back: CreateResult (fee, resolver, yield settings)

✓ DisputeOps.computeEscalation()
  ├─ Called during: escalateDispute()
  └─ Gets back: EscalationResult (new resolver, level, fee)

✓ SettlementOps.computeResolutionExecution()
  ├─ Called during: releaseEscrowTransfer(), cancelEscrow()
  └─ Gets back: ResolutionResult (should execute, appeal deadline)

✓ SettlementOps.computeTimedActions()
  ├─ Called during: Auto-timeout checking
  └─ Gets back: Action type (release or cancel)

✓ YieldOps.handleYield()
  ├─ Called during: releaseEscrowTransfer() (yield withdrawal)
  └─ Gets back: YieldResult (yield amount, distribution)

✓ ModuleManagementContract (queries)
  ├─ getDefaultResolutionModule(escrow)
  ├─ getDefaultYieldGenerationModule(escrow)
  ├─ getDefaultYieldDistributionModule(escrow)
  └─ getDefaultReleaseStrategy(escrow)

✓ IYieldGenerationModule (module calls)
  ├─ depositForYield() [during createEscrow if yield enabled]
  └─ withdrawWithYield() [during release/cancel]

✓ IYieldDistributionModule (module calls)
  └─ distributeYield() [during yield withdrawal]

✓ IResolutionModule (module calls)
  └─ Various based on dispute flow

✓ BondCollector (if using escalation)
  └─ collectBond() [during escalation]
```

**Who Calls It:**
- `EscrowVault` (extends it)
- `EscrowableERC20` (extends it)
- External users/contracts via public functions:
  - `createEscrow()`
  - `releaseEscrowTransfer()`
  - `cancelEscrow()`
  - `raiseDispute()`
  - `escalateDispute()`

**Key Workflows:**
```
CREATE:  User → createEscrow() → CreateOps → State applied to BaseEscrow
RELEASE: User → releaseEscrow() → YieldOps → SettlementOps → State applied
DISPUTE: User → raiseDispute() → Module → BaseEscrow updates state
ESCALATE: User → escalateDispute() → DisputeOps → BondCollector → State applied
```

---

#### 2. **EscrowVault**
**Location:** `contracts/core/EscrowVault.sol`

**Purpose:**
- Multi-token escrow vault
- Accepts any ERC20 token
- Main user-facing contract

**Extends:** `BaseEscrow`

**Storage:**
```solidity
ModuleManagementContract public immutable moduleManagement;
mapping(address => uint256) totalFeesPerToken;
mapping(address => uint256) totalHeldInEscrowPerToken;
```

**What It Uses:**
```
✓ BaseEscrow (all functionality via inheritance)
  └─ All *Ops calls are inherited

✓ ModuleManagementContract (stored reference)
  ├─ Constructor: Get default modules
  └─ During operations: Get modules via BaseEscrow
```

**What Calls It:**
```
✓ External users via:
  - createEscrow(token, from, to, amount, ...)
  - releaseEscrowTransfer(workflowId)
  - cancelEscrow(workflowId)
  - raiseDispute(workflowId, reason)
  - escalateDispute(workflowId)

✓ Governance:
  - setEscrowFee()
  - setYieldProtocolFeeBps()
  - setResolutionModule()
  - pause() / unpause()

✓ Internal contracts:
  - YieldOps (calls back to release funds)
  - BondCollector (calls back for protocol fees)
```

**Workflow Example: Create Escrow**
```
User → EscrowVault.createEscrow()
    → BaseEscrow.createEscrow()
      → CreateOps.computeEscrowCreation()
        ← Returns CreateResult (fee, resolver, yield enabled)
      → Apply state to BaseEscrow (save escrow transfer, deduct fee)
      → If yield enabled:
          → YieldGenerationModule.depositForYield()
            ← Returns yield token balance
          → Store yield tracking in BaseEscrow
    ← Success, return workflowId
```

---

#### 3. **EscrowableERC20**
**Location:** `contracts/core/EscrowableERC20.sol`

**Purpose:**
- ERC20 token + escrow combined in one contract
- Single-token escrow (token = self)
- Alternative to multi-token EscrowVault

**Extends:** `ERC20` + `BaseEscrow`

**Key Difference from EscrowVault:**
```
EscrowVault:       createEscrow(token, amount)  // token param required
EscrowableERC20:   createEscrow(amount)         // token = address(this)
```

**Storage:**
```solidity
ModuleManagementContract public immutable moduleManagement;
uint256 totalHeldInEscrow;      // Single token, no mapping needed
uint256 totalFees;
```

**What It Uses:**
- Same as EscrowVault (all via BaseEscrow)

**Who Calls It:**
- Same as EscrowVault, but users interact with ERC20 interface

---

### TIER 2: COMPUTATION & LOGIC CONTRACTS

#### 4. **CreateOps**
**Location:** `contracts/CreateOps.sol`

**Purpose:**
- Compute-only contract (no state writes)
- Validates escrow creation
- Calculates fee deductions
- Determines yield settings

**Type:** **Compute-Only** (returns results for BaseEscrow to apply)

**What It Uses:**
```
✓ No other contracts directly
✓ Uses libraries:
  - EscrowCreationLibrary
  - YieldPresets
  - Validation libraries
```

**Functions Called By BaseEscrow:**
```solidity
computeEscrowCreation(
  address escrowContract,
  address token,
  address from,
  address to,
  uint256 amount,
  string calldata yieldPreset,
  address customResolver,
  address resolutionModule
) → CreateResult {
  uint256 fee,
  uint256 amountAfterFee,
  address resolver,
  bool yieldEnabled,
  bool shouldDepositYield
}
```

**When It's Called:**
- During `BaseEscrow.createEscrow()`
- Before any state is modified

**Access Control:**
```solidity
onlyRole(ROLE_ESCROW_CONTRACT)  // Only registered escrows
```

**Key Logic:**
- Calculate escrow fee (fixed or percentage)
- Validate resolver (must be contract or EOA)
- Check yield preset (standard presets: "aave-default", etc.)
- Determine if yield should be auto-enabled
- Return results WITHOUT writing state

---

#### 5. **DisputeOps**
**Location:** `contracts/DisputeOps.sol`

**Purpose:**
- Compute-only contract for dispute escalation
- Calculates escalation fees
- Determines new resolver
- Checks escalation level limits

**Type:** **Compute-Only** (returns results for BaseEscrow to apply)

**What It Uses:**
```
✓ IResolutionModule (interface, called by BaseEscrow)
✓ Libraries:
  - DisputeEscalationLibrary
  - EscalationCostLibrary
```

**Functions Called By BaseEscrow:**
```solidity
computeEscalation(
  IResolutionModule resolutionModule,
  uint256 workflowId,
  address caller,
  address from,
  address to,
  address token,
  uint256 amountAfterFee,
  EscrowTransfer memory escrowState
) → EscalationResult {
  bool success,
  address newResolver,
  uint8 newLevel,
  uint256 escalationFee,
  string failureReason
}
```

**When It's Called:**
- During `BaseEscrow.escalateDispute()`
- After dispute exists but before escalation is finalized

**Key Logic:**
- Query current resolution module for new resolver
- Calculate escalation fee (increases per level)
- Check escalation level hasn't exceeded max
- Validate caller (from or to can escalate)
- Return results WITHOUT writing state

---

#### 6. **SettlementOps**
**Location:** `contracts/SettlementOps.sol`

**Purpose:**
- Compute-only contract for settlement execution
- Determines if resolution should execute
- Calculates appeal window deadlines
- Checks timeout-based auto-execution

**Type:** **Compute-Only** (returns results for BaseEscrow to apply)

**What It Uses:**
```
✓ IResolutionModule (interface)
✓ Libraries:
  - Settlement logic libraries
  - EscrowTypes
```

**Functions Called By BaseEscrow:**
```solidity
// Check if resolution can execute now
computeResolutionExecution(
  IResolutionModule resolutionModule,
  uint256 workflowId,
  bool isRelease,
  TimeoutConfig memory timeoutConfig
) → ResolutionResult {
  bool shouldExecute,
  bool isRelease,
  uint256 appealDeadline,
  bool isFinalRound
}

// Check for timed auto-actions
computeTimedActions(
  uint256 workflowId,
  EscrowTransfer memory et,
  PendingSettlement memory pendingMem,
  TimeoutConfig memory timeoutConfig
) → (ActionType, bool isRelease)

// Check if pending settlement ready
computePendingSettlementExecution(
  uint256 workflowId,
  PendingSettlement memory pendingMem,
  EscrowTransfer memory escrowState
) → (bool canExecute, bool isRelease)
```

**When It's Called:**
- During `BaseEscrow.releaseEscrowTransfer()` (check if ready)
- During `BaseEscrow.cancelEscrow()` (check if ready)
- During timeout automation (check if should auto-execute)

---

#### 7. **YieldOps**
**Location:** `contracts/YieldOps.sol`

**Purpose:**
- Handles yield withdrawal from Aave
- Distributes yield to parties
- Collects protocol fees
- NOT compute-only (makes external calls to yield modules)

**Type:** **Logic Contract** (performs stateful operations)

**What It Uses:**
```
✓ IYieldGenerationModule (interface)
  └─ withdrawWithYield() [Aave]

✓ IYieldDistributionModule (interface)
  └─ distributeYield() [yield distribution]

✓ SafeERC20 (token operations)
```

**Functions Called By BaseEscrow:**
```solidity
handleYield(
  IYieldGenerationModule genModule,
  IYieldDistributionModule distModule,
  uint256 workflowId,
  address token,
  uint256 amount,
  uint16 protocolFeeBps,
  address feeAddress,
  bytes calldata distributionData
) → YieldResult {
  uint256 actualAmount,
  uint256 yield,
  bool yieldDistributed,
  bool success,
  string failureReason
}
```

**When It's Called:**
- During `BaseEscrow.releaseEscrowTransfer()` (if yield is enabled)
- Also called for yield-only distributions

**Access Control:**
```solidity
onlyRole(ROLE_ESCROW_CONTRACT)  // Only registered escrows
```

**Key Logic:**
- Calls yield module to withdraw from Aave
- Calculates yield (actual - original)
- Calls distribution module to split yield
- Transfers funds back to escrow
- Records protocol fees

---

### TIER 3: MANAGEMENT & CONFIGURATION

#### 8. **ModuleManagementContract**
**Location:** `contracts/core/ModuleManagementContract.sol`

**Purpose:**
- Centralized registry for default modules per vault
- Slow-lane activation (7-day delay) for module changes
- Single source of truth for which modules each vault uses

**Storage:**
```solidity
mapping(address => ModuleState) escrowModuleStates;

struct ModuleState {
  IReleaseStrategy defaultReleaseStrategy;
  IYieldGenerationModule defaultYieldGenerationModule;
  IYieldDistributionModule defaultYieldDistributionModule;
  IResolutionModule defaultResolutionModule;
  mapping(BaseEscrow.ModuleType => PendingAddress) pendingModules;
}
```

**What It Uses:**
```
✓ SlowLaneQueueActivate (base class)
  └─ 7-day delay for module changes
✓ AccessControl (OpenZeppelin)
  └─ ROLE_TIMELOCK for governance
```

**What Calls It:**
```
✓ BaseEscrow (reads, doesn't write)
  - getDefaultResolutionModule(escrow)
  - getDefaultYieldGenerationModule(escrow)
  - getDefaultYieldDistributionModule(escrow)
  - getDefaultReleaseStrategy(escrow)

✓ Governance (writes via slow-lane)
  - queueDefaultResolutionModule()
  - activateDefaultResolutionModule()
  - queueDefaultYieldGenerationModule()
  - activateDefaultYieldGenerationModule()
  - queueDefaultYieldDistributionModule()
  - activateDefaultYieldDistributionModule()
  - queueDefaultReleaseStrategy()
  - activateDefaultReleaseStrategy()
```

**Slow-Lane Flow:**
```
Governance (DAO) → TimelockController
    ↓ (after 2-day timelock)
Governance calls queueModule(vault, newModule)
    ↓
Module enters pending state with eta = now + 7 days
    ↓ (after 7 days)
Governance calls activateModule(vault)
    ↓
New module becomes default for THIS VAULT ONLY
    ↓
Future escrows in this vault use new module
(Existing escrows locked to original module via snapshot immutability)
```

---

#### 9. **EscrowAdminContract**
**Location:** `contracts/admin/EscrowAdminContract.sol`

**Purpose:**
- Centralized admin for protocol configuration
- Manages fee settings per vault
- Slow-lane activation for configuration changes
- Prevents sudden governance changes mid-transaction

**Storage:**
```solidity
mapping(address => AdminState) escrowAdminStates;

struct AdminState {
  PendingAddress pendingFeeRecipient;
  PendingUint pendingEscrowFee;
  PendingUint pendingYieldProtocolFeeBps;
  PendingUint pendingAppealBondProtocolFeeBps;
  PendingAddress pendingResolutionModule;
}
```

**What It Uses:**
```
✓ SlowLaneQueueActivate (base class)
  └─ 7-day delay for settings changes
✓ AccessControl
  └─ ROLE_TIMELOCK for governance
✓ BaseEscrow (interface for callbacks)
```

**What Calls It:**
```
✓ Governance (TimelockController)
  - queueFeeRecipient(vault, newRecipient)
  - activateFeeRecipient(vault)
  - queueEscrowFee(vault, newFee)
  - activateEscrowFee(vault)
  - queueYieldProtocolFeeBps(vault, newFee)
  - activateYieldProtocolFeeBps(vault)
  - queueAppealBondProtocolFeeBps(vault, newFee)
  - activateAppealBondProtocolFeeBps(vault)
  - queueResolutionModule(vault, newModule)
  - activateResolutionModule(vault)
```

**Integration with BaseEscrow:**
```
EscrowAdminContract.activateFeeRecipient(vault)
    ↓
Calls vault.setFeeRecipient(newValue)
    ↓
BaseEscrow applies change
    (Must verify: vault has granted ROLE_ADMIN_CONTRACT)
```

---

#### 10. **BondCollector**
**Location:** `contracts/core/BondCollector.sol`

**Purpose:**
- External contract for bond collection (extracted to reduce size)
- Collects escalation bonds (ETH or ERC20)
- Deducts protocol fees
- Handles custody of ERC20 bonds

**What It Uses:**
```
✓ IIncentiveModule (interface)
  └─ recordBond() [for resolver staking systems]
✓ SafeERC20
  └─ Token operations
✓ AccessControl
  └─ ROLE_ESCROW_CONTRACT for authorized escrows
```

**What Calls It:**
```
✓ BaseEscrow
  └─ collectBond() [during escalation]

✓ Governance (ROLE_TIMELOCK)
  └─ registerEscrowContract(escrow)
```

**Workflow: Bond Collection**
```
User escalates dispute
    ↓
BaseEscrow.escalateDispute()
    ↓ (after DisputeOps returns new resolver)
BaseEscrow.collectBond()
    ↓
BondCollector.collectBond(workflowId, bond amount, ...)
    ├─ Deduct protocol fee
    ├─ Transfer bond to incentive module (if one exists)
    └─ Emit ProtocolFeeCollected event
```

---

### TIER 4: PLUGINS & MODULES

#### 11. **Yield Modules** (Pluggable)

**DefaultYieldModule**
- Location: `contracts/modules/DefaultYieldModule.sol`
- Does nothing (no-op)
- Used when yield is disabled
- Implements: `IYieldGenerationModule`

**AaveYieldGenerationModule**
- Location: `contracts/modules/AaveYieldGenerationModule.sol`
- Integrates with Aave V3
- Single module manages multiple vaults
- Deposits funds to Aave, tracks shares
- Implements: `IYieldGenerationModule`

**Who Calls Yield Modules:**
```
✓ BaseEscrow
  - depositForYield(workflowId, token, amount)
  - withdrawWithYield(workflowId, token, amount, escrowContract)
  - calculateYield(workflowId, token, escrowContract)

✓ YieldOps
  - handleYield() calls module functions
```

---

#### 12. **Distribution Modules** (Pluggable)

**DefaultYieldDistributionModule**
- Location: `contracts/modules/DefaultYieldDistributionModule.sol`
- Splits yield 50/50 between from/to
- Implements: `IYieldDistributionModule`

**Who Calls Distribution Modules:**
```
✓ YieldOps
  - distributeYield(workflowId, token, yieldAmount, distributionData)
```

---

#### 13. **Resolution Modules** (Pluggable)

**DefaultResolutionModule**
- Single resolver who decides outcome
- Implements: `IResolutionModule`

**DecentralizedResolutionModule**
- Multiple resolvers, voting-based
- Implements: `IResolutionModule`

**KlerosArbitrableProxy**
- External arbitration via Kleros
- Implements: `IArbitrable` + custom logic

**Who Calls Resolution Modules:**
```
✓ DisputeOps
  - getNewResolver(workflowId, ...)
  - checkCanExecute(workflowId)

✓ BaseEscrow
  - Various status checks during dispute lifecycle
```

---

#### 14. **Release Strategies** (Pluggable)

**DefaultReleaseStrategy**
- Time-based release conditions
- Implements: `IReleaseStrategy`

**Who Calls Release Strategies:**
```
✓ BaseEscrow
  - Used to check if release conditions are met
  - Checked during releaseEscrowTransfer()
```

---

### TIER 5: VIEWS & ADMINISTRATION

#### 15. **EscrowViewContract**
**Location:** `contracts/core/EscrowViewContract.sol`

**Purpose:**
- Read-only views into escrow state
- Safe for frontends and indexers (no state writes possible)
- Queries escrow data without loading main contract

**What It Uses:**
```
✓ EscrowVault (queried, read-only)
✓ EscrowableERC20 (queried, read-only)
✓ ModuleManagementContract (queried)
```

**What Calls It:**
```
✓ External users / Indexers / Frontends
  - Querying escrow status
  - Viewing escrow details
  - Safe query operations
```

**Example Functions:**
```solidity
function getEscrowTransfer(address vault, uint256 workflowId)
  → EscrowTransfer view
function getDispute(address vault, uint256 workflowId)
  → DisputeRecord view
function getEscrowState(address vault, uint256 workflowId)
  → string (status: "CREATED", "FINALIZED", etc.)
```

---

#### 16. **GuardianOps**
**Location:** `contracts/ops/GuardianOps.sol`

**Purpose:**
- Emergency pause/unpause operations
- Guardian role for emergency intervention

**What It Uses:**
```
✓ AccessControl
  └─ ROLE_GUARDIAN for emergency ops
```

**What Calls It:**
```
✓ Governance (ROLE_GUARDIAN)
  └─ pauseEscrowVault()
  └─ unpauseEscrowVault() [ROLE_TIMELOCK only]
```

---

## Contract Call Relationships (Summary Table)

| Caller | Called Contract | Function | Purpose |
|--------|-----------------|----------|---------|
| BaseEscrow | CreateOps | `computeEscrowCreation()` | Validate creation, calculate fees |
| BaseEscrow | DisputeOps | `computeEscalation()` | Validate escalation, new resolver |
| BaseEscrow | SettlementOps | `computeResolutionExecution()` | Check if ready to execute |
| BaseEscrow | SettlementOps | `computeTimedActions()` | Check auto-timeouts |
| BaseEscrow | YieldOps | `handleYield()` | Withdraw & distribute yield |
| BaseEscrow | ModuleManagementContract | `getDefaultXModule()` | Get modules for vault |
| BaseEscrow | IYieldGenerationModule | `depositForYield()` | Deposit to yield protocol |
| BaseEscrow | IYieldGenerationModule | `withdrawWithYield()` | Withdraw from yield protocol |
| BaseEscrow | IYieldDistributionModule | `distributeYield()` | Split yield between parties |
| BaseEscrow | IResolutionModule | Various | Dispute resolution logic |
| BaseEscrow | BondCollector | `collectBond()` | Collect escalation bond |
| EscrowVault | ModuleManagementContract | Constructor | Store module management ref |
| DisputeOps | IResolutionModule | `getNewResolver()` | Get next resolver in chain |
| YieldOps | IYieldGenerationModule | `withdrawWithYield()` | Get yield amount & withdraw |
| YieldOps | IYieldDistributionModule | `distributeYield()` | Split yield |
| Governance | ModuleManagementContract | `queueX()` / `activateX()` | Queue/activate module changes |
| Governance | EscrowAdminContract | `queueX()` / `activateX()` | Queue/activate config changes |
| Governance | BondCollector | `registerEscrowContract()` | Authorize vault |

---

## Call Flow Examples

### Example 1: Creating an Escrow with Yield

```
User
  ↓
EscrowVault.createEscrow(token, from, to, amount, yieldPreset="aave-default")
  ↓
BaseEscrow.createEscrow()
  ├─ CreateOps.computeEscrowCreation()
  │   ├─ Validate yield preset
  │   ├─ Calculate fee
  │   └─ Return CreateResult
  │
  ├─ Save escrow transfer to state
  ├─ Deduct fee
  │
  ├─ If yieldEnabled:
  │   └─ ModuleManagementContract.getDefaultYieldGenerationModule(EscrowVault)
  │       ↓
  │       Returns AaveYieldGenerationModule
  │       ↓
  │       AaveYieldGenerationModule.depositForYield(workflowId, token, amount)
  │         ├─ Check cap
  │         ├─ Supply to Aave
  │         ├─ Track shares
  │         └─ Return shares
  │
  └─ Save yield tracking to state
```

### Example 2: Releasing Escrow with Yield Distribution

```
User
  ↓
EscrowVault.releaseEscrowTransfer(workflowId)
  ↓
BaseEscrow.releaseEscrowTransfer()
  ├─ Check state is CREATED
  │
  ├─ If yieldEnabled:
  │   ├─ YieldOps.handleYield()
  │   │   ├─ ModuleManagementContract.getDefaultYieldGenerationModule(EscrowVault)
  │   │   │   ↓
  │   │   │   Returns AaveYieldGenerationModule
  │   │   │
  │   │   ├─ AaveYieldGenerationModule.withdrawWithYield(...)
  │   │   │   ├─ Withdraw from Aave
  │   │   │   └─ Return actualAmount, yield
  │   │   │
  │   │   ├─ ModuleManagementContract.getDefaultYieldDistributionModule(EscrowVault)
  │   │   │   ↓
  │   │   │   Returns DefaultYieldDistributionModule
  │   │   │
  │   │   ├─ DefaultYieldDistributionModule.distributeYield(yield)
  │   │   │   ├─ Calculate 50% to buyer, 50% to seller
  │   │   │   └─ Return distribution
  │   │   │
  │   │   ├─ Transfer principal to "to" address
  │   │   ├─ Transfer yield splits to respective parties
  │   │   └─ Return YieldResult
  │   │
  │   └─ Apply yield results to state
  │
  ├─ SettlementOps.computeResolutionExecution()
  │   └─ Check if ready to finalize
  │
  └─ Finalize escrow (state = FINALIZED)
```

### Example 3: Escalating a Dispute

```
User (from or to)
  ↓
EscrowVault.escalateDispute(workflowId)
  ↓
BaseEscrow.escalateDispute()
  ├─ Load current dispute
  ├─ DisputeOps.computeEscalation()
  │   ├─ ModuleManagementContract.getDefaultResolutionModule(EscrowVault)
  │   │   ↓
  │   │   Returns DecentralizedResolutionModule
  │   │
  │   ├─ DecentralizedResolutionModule.getNewResolver(escalation level)
  │   │   └─ Return new resolver address
  │   │
  │   ├─ Calculate escalation fee (increases per level)
  │   └─ Return EscalationResult
  │
  ├─ Deduct escalation fee (via BondCollector.collectBond())
  │
  ├─ Collect bond (if escalation bonds enabled)
  │   └─ BondCollector.collectBond()
  │       ├─ Transfer bond from caller
  │       ├─ Deduct protocol fee
  │       └─ Transfer to resolver staking module
  │
  └─ Update dispute state (new resolver, new level)
```

---

## Access Control Summary

### ROLE_TIMELOCK (Governance)
Controls:
- ModuleManagementContract.registerEscrowContract()
- ModuleManagementContract.queue/activate module changes
- EscrowAdminContract.queue/activate config changes
- BondCollector.registerEscrowContract()
- AaveYieldGenerationModule.registerEscrowContract()
- AaveYieldGenerationModule.setGlobalCap()

### ROLE_ESCROW_CONTRACT (Registered Vaults)
Controls:
- CreateOps.computeEscrowCreation()
- DisputeOps.computeEscalation()
- SettlementOps functions
- YieldOps.handleYield()
- BondCollector.collectBond()
- AaveYieldGenerationModule.depositForYield()

### ROLE_ADMIN_CONTRACT
Controls:
- EscrowVault.setEscrowFee()
- EscrowVault.setYieldProtocolFeeBps()
- EscrowVault.setResolutionModule()

### ROLE_GUARDIAN
Controls:
- EscrowVault.pause()
- (Cannot unpause - only ROLE_TIMELOCK can)

---

## Deployment Order & Dependencies

```
1. Deploy implementations
   ├─ Create*Ops (CreateOps, DisputeOps, SettlementOps, YieldOps)
   ├─ BondCollector
   ├─ ModuleManagementContract
   └─ EscrowAdminContract

2. Deploy modules
   ├─ DefaultYieldModule
   ├─ AaveYieldGenerationModule
   ├─ DefaultYieldDistributionModule
   ├─ DefaultResolutionModule
   └─ DefaultReleaseStrategy

3. Deploy vaults (depends on ModuleManagementContract)
   ├─ EscrowVault (or)
   └─ EscrowableERC20

4. Deploy views (depends on vaults)
   └─ EscrowViewContract

5. Wire everything (governance setup)
   ├─ Register vaults in *Ops contracts
   ├─ Grant ROLE_TIMELOCK to TimelockController
   ├─ Grant ROLE_ADMIN_CONTRACT to EscrowAdminContract
   └─ Register modules in ModuleManagementContract
```

---

## Conclusion

The contract architecture uses a **modular compute + apply pattern**:

1. **Compute Contracts** (*Ops): Calculate results without writing state
2. **Core Contract** (BaseEscrow): Holds state, orchestrates, applies results
3. **Management Contract** (ModuleManagementContract): Manages pluggable modules
4. **Admin Contract** (EscrowAdminContract): Manages configuration
5. **Plugins** (Modules): Implement yield, distribution, resolution logic

This design keeps contracts under size limits while maintaining clear separation of concerns and enabling plugin upgrades via governance.
