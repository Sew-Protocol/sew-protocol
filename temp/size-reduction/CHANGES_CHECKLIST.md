# Size Reduction Changes Checklist

## Phase 3: View Function Removal

### BaseEscrow.sol
- [ ] Remove `isDisputeTimedOut()` function (lines ~605-616)
  - File: `BaseEscrow_PHASE3_FINAL.sol` shows what to delete

### EscrowViewContract.sol
- [ ] Add import: `import '../libraries/DisputeManagementLibrary.sol';` (if not present)
- [ ] Add `isDisputeTimedOut()` function after `getTimeoutConfig()`
  - File: `EscrowViewContract_PHASE3_FINAL.sol` shows what to add

### Tests
- [ ] Search for `isDisputeTimedOut` in test files
- [ ] Update tests to use `EscrowViewContract.isDisputeTimedOut()` instead of `BaseEscrow.isDisputeTimedOut()`

---

## Phase 4: Settlement Automation Extraction

### SettlementOps.sol
- [ ] Add `ActionPlan` struct after `ResolutionResult` struct (around line 39)
  - File: `SettlementOps_PHASE4_FINAL.sol` shows the struct
- [ ] Add `computeNextAction()` function after `computeTimedActions()` (around line 167)
  - File: `SettlementOps_PHASE4_FINAL.sol` shows the function

### BaseEscrow.sol
- [ ] Add `_applyActionPlan()` function after `_executeResolution()` (around line 905)
  - File: `BaseEscrow_PHASE4_FINAL.sol` shows the function
- [ ] Add `_finalizeDisputeInModule()` function after `_applyActionPlan()`
  - File: `BaseEscrow_PHASE4_FINAL.sol` shows the function
- [ ] Replace `automateTimedActions()` function (lines ~464-525)
  - File: `BaseEscrow_PHASE4_FINAL.sol` shows the replacement
- [ ] Replace `executePendingSettlement()` function (lines ~914-969)
  - File: `BaseEscrow_PHASE4_FINAL.sol` shows the replacement

### Tests
- [ ] Run tests for `automateTimedActions()`
- [ ] Run tests for `executePendingSettlement()`
- [ ] Verify all settlement flows work correctly

---

## Verification Steps

### After Each Phase:
1. [ ] Compile contracts
2. [ ] Run relevant tests
3. [ ] Measure contract size
4. [ ] Document size reduction

### Final Verification:
1. [ ] All tests pass
2. [ ] Contract size < 24 KB
3. [ ] No compilation errors
4. [ ] Frontend/integrations updated (if needed)

---

## Expected Results

### Phase 3:
- **Removed**: ~12 lines from BaseEscrow
- **Added**: ~15 lines to EscrowViewContract
- **Size Reduction**: ~0.3-0.5 KB

### Phase 4:
- **Removed**: ~120 lines of complex branching logic from BaseEscrow
- **Added**: ~80 lines to SettlementOps + ~40 lines to BaseEscrow (helpers)
- **Net Reduction**: ~40 lines removed from BaseEscrow
- **Size Reduction**: ~0.8-1.5 KB

### Total (Phases 3 & 4):
- **Size Reduction**: ~1.1-2.0 KB
- **Combined with Previous**: 6.17-11.17 KB total
- **Final Size**: Should be under 24 KB ✅
