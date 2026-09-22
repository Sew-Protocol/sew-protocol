# Contract Size Reduction - Master Plan

**⚠️ OUTDATED - See Active Plan Below**

**Date**: 2026-01-18 (Original)  
**Last Updated**: 2026-01-23  
**Status**: This document contains the original master plan. Many optimizations have been completed.

## 📋 CURRENT ACTIVE PLAN

**Use this document**: [`ESCROWVAULT_SIZE_REDUCTION_ACTIVE_PLAN.md`](./ESCROWVAULT_SIZE_REDUCTION_ACTIVE_PLAN.md)

**Current Status** (2026-01-23):
- EscrowVault: **27,832 bytes** (27.18 KB) - 13.2% over limit
- Target: < 24,576 bytes (24 KB)
- Remaining: **3,256 bytes** needed

---

## Original Master Plan (For Reference)

**Date**: 2026-01-18  
**Original Status**: EscrowVault 35,561 bytes (44.7% over limit), EscrowableERC20 37,197 bytes (51.4% over limit)  
**Target**: All contracts < 24,576 bytes (24 KB)

## Priority Ranking (Biggest Wins First)

### ⭐⭐⭐ **PRIORITY 1: Extract Admin/Slow-Lane Config** (Estimated: **3-5 KB savings**)

**Current State**:
- BaseEscrow inherits `SlowLaneQueueActivate` (~800 bytes)
- Queue/activate/getPending functions for:
  - `escrowFeeAddress` (queue/activate/getPending)
  - `escrowFee` (queue/activate/getPending)
  - `yieldProtocolFeeBps` (queue/activate/getPending)
  - `appealBondProtocolFeeBps` (queue/activate/getPending)
  - `timeoutConfig` (multiple setters: `setDefaultAutoReleaseTime`, `setDefaultAutoCancelTime`, `setMaxDisputeDuration`, `setAppealWindowDuration`)
  - `disputeResolutionModule` (queue/activate/getPending)
- Total: ~15 functions + SlowLaneQueueActivate bytecode

**Solution**: Create `EscrowAdminContract`
- Owns all slow-lane state (pending values + eta)
- Enforces roles/timelock
- Calls minimal setters on EscrowVault/BaseEscrow:
  - `setFeeRecipient(address)`
  - `setEscrowFeeBps(uint256)`
  - `setYieldProtocolFeeBps(uint256)`
  - `setAppealBondProtocolFeeBps(uint256)`
  - `setTimeoutConfig(TimeoutConfig memory)`
  - `setResolutionModule(address)`

**Implementation Steps**:
1. Create `EscrowAdminContract.sol` with all queue/activate logic
2. Remove `SlowLaneQueueActivate` inheritance from BaseEscrow
3. Remove all queue/activate/getPending functions from BaseEscrow
4. Add minimal setter functions to BaseEscrow (only callable by admin contract)
5. Update EscrowVault to remove admin functions (already done for modules via ModuleManagementContract)
6. Update all tests to use EscrowAdminContract

**Files to Modify**:
- `contracts/core/EscrowAdminContract.sol` (NEW)
- `contracts/core/BaseEscrow.sol` (remove ~15 functions, remove SlowLaneQueueActivate)
- `contracts/core/EscrowVault.sol` (already minimal, verify)
- `contracts/core/EscrowableERC20.sol` (remove admin functions)
- `contracts/governance/SlowLaneQueueActivate.sol` (move to EscrowAdminContract)

**Estimated Savings**: **3-5 KB** (removes SlowLaneQueueActivate bytecode + 15 functions + pending state structs)

---

### ⭐⭐⭐ **PRIORITY 2: Extract Dispute Automation + Escalation Plumbing** (Estimated: **2-3 KB savings**)

**Current State**:
- `automateTimedActions()` - complex logic with SettlementOps integration
- `executePendingSettlement()` - settlement execution logic
- `_validateAndPrepareEscalation()` - validation and preparation
- `_collectEscalationBond()` - **CHUNKY**: ETH handling, fee deduction, approvals, events (~600-800 bytes)
- `_getIncentiveModuleFromResolution()` - dynamic discovery with try/catch

**Solution**: Move to DisputeOps/SettlementOps
- DisputeOps returns compact `EscalationAction` struct:
  ```solidity
  struct EscalationAction {
      address newResolver;
      uint8 newLevel;
      uint256 bondAmount;
      address bondToken;
      bool requiresBond;
      string failureReason; // or bytes4 reason code
  }
  ```
- BaseEscrow only:
  - Pulls/collects bond (or calls dedicated BondCollector contract)
  - Updates resolver
  - Emits event
  - State transitions

**Implementation Steps**:
1. Move `_collectEscalationBond()` logic to `DisputeOps.collectBond()`
2. Move `_validateAndPrepareEscalation()` to `DisputeOps.validateEscalation()`
3. Move `automateTimedActions()` core logic to `SettlementOps.automate()`
4. Move `executePendingSettlement()` to `SettlementOps.executeSettlement()`
5. BaseEscrow calls Ops contracts and executes minimal state changes
6. Remove `_getIncentiveModuleFromResolution()` (see Priority 3)

**Files to Modify**:
- `contracts/DisputeOps.sol` (add bond collection, validation)
- `contracts/SettlementOps.sol` (add automation, settlement execution)
- `contracts/core/BaseEscrow.sol` (remove ~4 functions, simplify escalation)

**Estimated Savings**: **2-3 KB** (removes complex logic, try/catch patterns, bond collection)

---

### ⭐⭐ **PRIORITY 3: Snapshot Incentive Module at Creation** (Estimated: **0.5-1 KB savings**)

**Current State**:
- `_getIncentiveModuleFromResolution()` uses try/catch + low-level staticcall
- Called multiple times during escalation
- Adds branching and error handling bytecode

**Solution**: Snapshot at escrow creation
- Add `incentiveModule` field to `ModuleSnapshot` struct
- At `createEscrow`, if resolution module supports it, read `incentiveModule()` once
- Store in snapshot
- Use snapshot directly in escalation (no discovery needed)

**Implementation Steps**:
1. Add `incentiveModule address` to `ModuleSnapshot` struct
2. Update `_snapshotModules()` to read and store incentive module
3. Remove `_getIncentiveModuleFromResolution()` function
4. Update escalation to use `moduleSnapshots[workflowId].incentiveModule`
5. Update tests

**Files to Modify**:
- `contracts/types/EscrowTypes.sol` (add field to ModuleSnapshot)
- `contracts/core/BaseEscrow.sol` (remove discovery function, use snapshot)

**Estimated Savings**: **0.5-1 KB** (removes discovery function, try/catch, branching)

---

### ⭐⭐ **PRIORITY 4: Externalize View Getters** (Estimated: **1-2 KB savings**)

**Current State**:
- Multiple per-escrow getters:
  - `getEscrowSettings(uint256)` - returns struct (ABI encoding cost)
  - `getEscrowTransfer(uint256)` - returns struct
  - `getEscrowStatusInfo(uint256)` - returns struct
  - `getEscrowParticipants(uint256)` - returns struct
  - `getModuleSnapshot(uint256)` - returns struct
  - `getPendingSettlement(uint256)` - returns struct
  - `getTimeoutConfig()` - returns struct
  - `getTotalDeposited(uint256)` - simple getter
  - `getEscrowCount()` - simple getter
  - `getDefaultSettings()` - pure function

**Solution**: Create `EscrowViewContract`
- Reads BaseEscrow/EscrowVault via public storage/getters
- Repackages results for frontend
- Core contracts keep only:
  - `escrowTransfers(uint256)` (public array getter)
  - `claimableBalances(workflowId, user)` (if needed onchain)
  - `getEscrowSummary(workflowId)` - compact view with fixed-size fields:
    ```solidity
    struct EscrowSummary {
        EscrowState state;
        address token;
        address from;
        address to;
        uint256 amountAfterFee;
        address resolver;
        uint256 autoReleaseTime;
        uint256 autoCancelTime;
    }
    ```

**Implementation Steps**:
1. Create `EscrowViewContract.sol` with all view functions
2. Remove view getters from BaseEscrow (except `escrowTransfers`, `claimableBalances`, `getEscrowSummary`)
3. Update frontend/integrations to use EscrowViewContract
4. Keep `moduleSnapshots` only if needed onchain (otherwise emit on creation)

**Files to Modify**:
- `contracts/view/EscrowViewContract.sol` (NEW)
- `contracts/core/BaseEscrow.sol` (remove ~10 view functions)

**Estimated Savings**: **1-2 KB** (removes struct-returning functions, ABI encoding)

---

### ⭐ **PRIORITY 5: Remove Rarely Used Endpoints** (Estimated: **0.5-1 KB savings**)

**Current State**:
- `reconcileAccounting()` / `getAccountingDelta()` - operational monitoring
- `recoverNativeETH()` - recovery function
- Verbose event suite (already optimized with reason codes)

**Solution**: 
- Move accounting reconciliation to external `AccountingOps` contract
- Remove `recoverNativeETH()` from EscrowVault (ERC20 vault doesn't need it)
- Keep only in ETH-specific vault or separate Recovery contract

**Implementation Steps**:
1. Create `AccountingOps.sol` with reconciliation logic
2. Remove `recoverNativeETH()` from EscrowVault
3. Remove `reconcileAccounting()` from BaseEscrow
4. Keep only `expectedBalance(token)` getter if needed

**Files to Modify**:
- `contracts/AccountingOps.sol` (NEW, optional)
- `contracts/core/BaseEscrow.sol` (remove reconciliation)
- `contracts/core/EscrowVault.sol` (remove recoverNativeETH)

**Estimated Savings**: **0.5-1 KB** (removes rarely used functions)

---

## Implementation Order

1. **Phase 1**: Priority 1 (Admin extraction) - **3-5 KB savings**
2. **Phase 2**: Priority 2 (Dispute automation) - **2-3 KB savings**
3. **Phase 3**: Priority 3 (Incentive module snapshot) - **0.5-1 KB savings**
4. **Phase 4**: Priority 4 (View getters) - **1-2 KB savings**
5. **Phase 5**: Priority 5 (Rare endpoints) - **0.5-1 KB savings**

**Total Estimated Savings**: **7-12 KB**

This should bring EscrowVault from 35,561 bytes to **23-28 KB** (under or close to limit).

---

## Critical Notes

1. **Admin Contract Must Own State**: To win size, escrow contracts must expose ONLY minimal setters. If we "proxy" calls but keep queue/activate code, we don't save much.

2. **Incentive Module Snapshot**: Only affects new escrows (as stated in model). Resolution module changes don't affect existing escrows.

3. **View Contract Trade-off**: Deploying EscrowViewContract adds gas for frontend calls, but saves core contract size. This is acceptable for v1.0.

4. **Testing Impact**: Each phase requires updating tests to use new contracts. Plan for comprehensive test updates.

5. **Backward Compatibility**: These are breaking changes. Plan for migration or versioning if needed.

---

## Next Steps

1. Start with **Priority 1** (Admin extraction) - highest impact
2. Measure size reduction after each phase
3. Adjust priorities if Phase 1 doesn't achieve target
4. Consider additional optimizations if still over limit
