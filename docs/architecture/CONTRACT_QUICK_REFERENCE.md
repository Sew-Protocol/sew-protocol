# Contract Dependency Map: Quick Reference

## Layer Visualization

```
╔══════════════════════════════════════════════════════════════════════╗
║                       USER INTERFACE LAYER                          ║
║                                                                      ║
║  EscrowVault (Multi-Token) · EscrowableERC20 (Single ERC20 Token)   ║
║       ↓                                  ↓                          ║
║  ┌─────────────────────────────────────────────────────────────┐   ║
║  │ Both extend BaseEscrow                                      │   ║
║  │ • Store reference to ModuleManagementContract              │   ║
║  │ • Implement all escrow workflows                           │   ║
║  │ • Accept user transactions                                 │   ║
║  └─────────────────────────────────────────────────────────────┘   ║
╚══════════════════════════════════════════════════════════════════════╝
                           ▲
                           │ extends
                           │
╔══════════════════════════════════════════════════════════════════════╗
║                   CORE ORCHESTRATION LAYER                          ║
║                                                                      ║
║                      BaseEscrow (Abstract)                          ║
║                                                                      ║
║  ┌─────────────────────────────────────────────────────────────┐   ║
║  │ Primary Responsibilities:                                   │   ║
║  │ • Hold all escrow state                                     │   ║
║  │ • Manage escrow lifecycle (CREATE → FINALIZED)             │   ║
║  │ • Orchestrate dispute workflows                             │   ║
║  │ • Delegate computation to *Ops contracts                    │   ║
║  │ • Call yield/distribution/resolution modules                │   ║
║  └─────────────────────────────────────────────────────────────┘   ║
║                                                                      ║
║           ┌─ Uses ─┬─ Uses ─┬─ Uses ──┬─ Uses ─┐                  ║
║           │        │        │         │        │                  ║
║           ▼        ▼        ▼         ▼        ▼                  ║
║       CreateOps DisputeOps SettlementOps YieldOps ModuleMgmt       ║
║       (Compute) (Compute)  (Compute)    (Logic)   (Storage)        ║
║           │        │        │         │                           ║
║           └────────┴────────┴─────────┘                           ║
║                    Returns results                                  ║
║              (BaseEscrow applies to state)                          ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
```

## Contract Matrix: Who Uses Whom

```
┌─────────────────┬──────────────┬────────────────┬─────────────────┐
│ Contract        │ Used By      │ Uses           │ Purpose         │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ BaseEscrow      │ EscrowVault  │ *Ops, Modules  │ Core state &    │
│ (Abstract)      │ EscrowableERC20 ModuleManage  │ orchestration   │
│                 │ Users/Ext    │                │                 │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ EscrowVault     │ Users        │ BaseEscrow     │ Multi-token     │
│                 │ Governance   │ ModuleManage   │ escrow vault    │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ EscrowableERC20 │ Users        │ BaseEscrow     │ Single-token    │
│                 │ Governance   │ ModuleManage   │ ERC20 + escrow  │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ CreateOps       │ BaseEscrow   │ Libraries      │ Validate        │
│                 │              │                │ creation        │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ DisputeOps      │ BaseEscrow   │ Modules        │ Validate        │
│                 │              │ Libraries      │ escalation      │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ SettlementOps   │ BaseEscrow   │ Modules        │ Check if ready  │
│                 │              │ Libraries      │ to execute      │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ YieldOps        │ BaseEscrow   │ Modules        │ Handle yield    │
│                 │              │ SafeERC20      │ withdrawal      │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ ModuleManagement│ BaseEscrow   │ SlowLane       │ Module registry │
│ Contract        │ Governance   │ AccessControl  │ & activation    │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ EscrowAdminCtrct│ Governance   │ SlowLane       │ Config slow-lane│
│                 │              │ BaseEscrow     │ (fee settings)  │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ BondCollector   │ BaseEscrow   │ Modules        │ Bond handling   │
│                 │ Governance   │ SafeERC20      │ & protocol fees │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ EscrowViewCtrct │ Frontends    │ Vaults         │ Read-only views │
│                 │ Indexers     │ ModuleManage   │ (safe queries)  │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ GuardianOps     │ Governance   │ AccessControl  │ Emergency       │
│                 │              │                │ pause/unpause   │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ Yield Modules   │ BaseEscrow   │ Aave/External  │ Yield ops       │
│ (pluggable)     │ YieldOps     │                │                 │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ Distribution    │ YieldOps     │ SafeERC20      │ Yield splitting │
│ Modules         │              │                │                 │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ Resolution      │ DisputeOps   │ Validators     │ Dispute logic   │
│ Modules         │ SettlementOps│                │                 │
├─────────────────┼──────────────┼────────────────┼─────────────────┤
│ Release         │ BaseEscrow   │ Time checks    │ Release         │
│ Strategies      │              │                │ conditions      │
└─────────────────┴──────────────┴────────────────┴─────────────────┘
```

## Operation Call Chains

### CREATE OPERATION
```
User calls: EscrowVault.createEscrow(token, from, to, amount, yieldPreset)
    ↓
BaseEscrow.createEscrow()
    ├─ CreateOps.computeEscrowCreation() ◄── COMPUTE
    │   └─ Returns: fee, resolver, yieldEnabled
    ├─ Update state (save escrow transfer)
    ├─ Deduct & record fee
    ├─ If yield enabled:
    │   └─ Get module: ModuleManagementContract.getDefaultYieldGenerationModule()
    │       ↓
    │       IYieldGenerationModule.depositForYield() ◄── MODULE CALL
    │       └─ Returns: shares, yieldTokenBalance
    │
    └─ Return workflowId

Timeline: IMMEDIATE
Access: Public
```

### RELEASE OPERATION
```
User calls: EscrowVault.releaseEscrowTransfer(workflowId)
    ↓
BaseEscrow.releaseEscrowTransfer()
    ├─ Check state = CREATED
    ├─ If yield enabled:
    │   ├─ Get modules from ModuleManagementContract
    │   ├─ YieldOps.handleYield()
    │   │   ├─ IYieldGenerationModule.withdrawWithYield() ◄── MODULE CALL
    │   │   │   └─ Returns: actualAmount, yield
    │   │   ├─ IYieldDistributionModule.distributeYield() ◄── MODULE CALL
    │   │   │   └─ Returns: buyerYield, sellerYield
    │   │   └─ Transfer principal & yield splits
    │   └─ Record yield generated
    ├─ SettlementOps.computeResolutionExecution() ◄── COMPUTE
    │   └─ Returns: shouldExecute, appealDeadline
    ├─ Transfer escrow amount to "to" address
    │
    └─ State → FINALIZED

Timeline: IMMEDIATE
Access: Public
```

### DISPUTE OPERATION
```
User calls: EscrowVault.raiseDispute(workflowId, reason)
    ↓
BaseEscrow.raiseDispute()
    ├─ Check state = CREATED
    ├─ Get module: ModuleManagementContract.getDefaultResolutionModule()
    ├─ Create dispute record (resolver, level, etc.)
    └─ State → IN_DISPUTE

    LATER:
    User calls: EscrowVault.escalateDispute(workflowId)
    ↓
BaseEscrow.escalateDispute()
    ├─ DisputeOps.computeEscalation() ◄── COMPUTE
    │   ├─ IResolutionModule.getNewResolver() ◄── MODULE CALL
    │   ├─ Calculate escalation fee
    │   └─ Returns: newResolver, newLevel, fee
    ├─ BondCollector.collectBond() ◄── EXTERNAL CONTRACT CALL
    │   ├─ Transfer bond from user
    │   ├─ Deduct protocol fee
    │   └─ Record bond with incentive module
    └─ Update dispute (new resolver, new level)

Timeline: IMMEDIATE for each step
Access: Public
```

## Data Flow Summary

```
User Transaction
    ↓
EscrowVault (entry point)
    ↓
BaseEscrow (state management)
    ├─ Computation: Call *Ops → Get results
    ├─ Modules: Call plugins → Get yields/decisions
    ├─ Config: Query ModuleManagementContract
    ├─ Fees: Call BondCollector if needed
    └─ Update internal state

Result: State change + events emitted
```

## Reference: Which Contract For What Task

| What do you want to do? | Which contract? |
|-------------------------|-----------------|
| Create an escrow | `EscrowVault.createEscrow()` or `EscrowableERC20` |
| Release funds | `EscrowVault.releaseEscrowTransfer()` |
| Raise a dispute | `EscrowVault.raiseDispute()` |
| Escalate dispute | `EscrowVault.escalateDispute()` |
| Query escrow state | `EscrowViewContract` (read-only) |
| Get escrow details | `EscrowViewContract` (safe for indexers) |
| Deposit to Aave | Called by `BaseEscrow`, no direct call |
| Withdraw from Aave | Called by `YieldOps`, no direct call |
| Change default module | `ModuleManagementContract.queue/activate*()` |
| Change fees/config | `EscrowAdminContract.queue/activate*()` |
| Collect escalation bond | Called by `BaseEscrow` → `BondCollector` |
| Split yield | Called by `YieldOps` → Distribution module |
| Get new resolver | Called by `DisputeOps` → Resolution module |
| Pause vault | `GuardianOps.pauseEscrowVault()` |

## Contract Size Optimization Pattern

**Problem:** Monolithic contract exceeds Ethereum size limit (24KB)

**Solution:** Extract logic to separate compute contracts

```
BEFORE:
┌─────────────────────────────────┐
│      EscrowVault (too large)    │
│ • All state                     │
│ • All validation logic          │
│ • All dispute logic             │
│ • All yield logic               │
│ • All settlement logic          │
│ → EXCEEDS 24KB LIMIT ❌         │
└─────────────────────────────────┘

AFTER:
┌──────────────────┐
│  EscrowVault     │ ~15KB (state + orchestration)
│  (manageable)    │
└─────────┬────────┘
          │
    ┌─────┴─────┬──────────┬──────────────┐
    │            │          │              │
    ▼            ▼          ▼              ▼
┌──────────┐ ┌─────────┐ ┌───────────┐ ┌────────┐
│CreateOps │ │Dispute  │ │Settlement │ │YieldOps│
│~4KB      │ │Ops~4KB  │ │Ops~4KB    │ │~3KB    │
└──────────┘ └─────────┘ └───────────┘ └────────┘

Result: All contracts ✅ under 24KB limit
Benefit: Cleaner separation of concerns
```

## Governance Flow (Slow-Lane Updates)

```
┌──────────────────┐
│  DAO Governance  │
│  (SewToken vote) │
└────────┬─────────┘
         │
         ▼
┌──────────────────────────┐
│ TimelockController       │
│ (2-day delay)            │
└────────┬─────────────────┘
         │
         ├─ Can queue module change in ModuleManagementContract
         │   └─ queue*Module(vault, newModule)
         │       └─ Enters 7-day queue
         │       └─ After 7 days: activate*Module(vault)
         │           └─ Module becomes default for THIS vault
         │           └─ Only affects NEW escrows
         │
         └─ Can queue config change in EscrowAdminContract
             └─ queueFee/FeeRecipient/Module/etc.
                 └─ Enters 7-day queue
                 └─ After 7 days: activate*
                     └─ Takes effect for new escrows
                     └─ Existing escrows unaffected (snapshot immutability)

Key: All governance changes have 7-day delay AFTER 2-day timelock
     = 9 days total before taking effect
     = Existing escrows NEVER affected (snapshot-based)
     = Time for community to exit if disagree with change
```

## Summary

**Key Insight:** Sew uses a **computation → application** pattern:

1. **Compute Contracts** (*Ops) → Calculate results (pure logic)
2. **Core Contract** (BaseEscrow) → Apply results (state writes)
3. **Plugins** (Modules) → Pluggable strategies (yield, resolution, distribution)
4. **Management** (ModuleManagementContract) → Central module registry
5. **Views** (EscrowViewContract) → Safe external queries

This design enables:
- ✅ Staying under contract size limits
- ✅ Clear separation of concerns
- ✅ Plugin upgrades via governance
- ✅ Safe views for frontends/indexers
- ✅ Snapshot immutability (old escrows unaffected by upgrades)

---

**For more details, see:** `CONTRACT_DEPENDENCY_MAP.md`
