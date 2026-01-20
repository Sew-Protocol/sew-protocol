# Contract Size Optimization Plan

**Date:** 2025-01-27  
**Goal:** Reduce EscrowVault and EscrowableERC20 below 24KB limit  
**Current Status:**

- EscrowVault: 38.57 KB (60.7% over limit)
- EscrowableERC20: 38.73 KB (61.4% over limit)

## Phase 1: Extract EscrowQueryLibrary (Priority: HIGH) ✅ COMPLETED

### Target: View/Getter Functions (~2.1 KB, 9% of BaseEscrow)

**Functions Extracted:**

1. ✅ `getEscrowTransfer(uint256 workflowId)` - ~0.3 KB
2. ✅ `getEscrowStatusInfo(uint256 workflowId)` - ~0.4 KB
3. ✅ `getAttachments(uint256 workflowId)` - ~0.2 KB
4. ✅ `getEscrowSettings(uint256 workflowId)` - ~0.2 KB
5. ✅ `getTotalDeposited(uint256 workflowId)` - ~0.1 KB
6. ✅ `getRemainingBalance(uint256 workflowId)` - ~0.1 KB
7. ✅ `getEscrowParticipants(uint256 workflowId)` - ~0.1 KB
8. ⚠️ `getEscrowCount()` - Kept in BaseEscrow (too simple)
9. ⚠️ `getNextWorkflowId()` - Kept in BaseEscrow (too simple)
10. ✅ `getTotalEscrowsByStatus(EscrowState status)` - ~0.3 KB
11. ✅ `getPendingFeeRecipient()` - ~0.1 KB
12. ✅ `getPendingEscrowFee()` - ~0.1 KB
13. ✅ `isDisputeTimedOut(uint256 workflowId)` - ~0.2 KB

**Actual Results:**

- **Before:** EscrowVault: 38.57 KB, EscrowableERC20: 38.73 KB
- **After:** EscrowVault: 38.91 KB, EscrowableERC20: 38.90 KB
- **Change:** +0.34 KB (EscrowVault), +0.17 KB (EscrowableERC20)
- **Status:** ⚠️ **Size increased due to library linking overhead**

**Analysis:**

- Library linking overhead exceeded savings from function extraction
- View functions are simple and don't benefit much from library extraction
- Library function calls add bytecode overhead (function selectors, ABI encoding)

**Recommendation:**

- Revert EscrowQueryLibrary extraction
- Focus on larger, more complex functions for extraction
- Consider inlining small view functions instead

---

## Phase 2: Optimize Governance Functions (Priority: MEDIUM)

### Target: Governance & Configuration (~3.2 KB, 13% of BaseEscrow)

**Functions to Optimize:**

1. Consolidate queue/activate/getPending pattern
2. Extract common slow-lane logic to library
3. Reduce event emissions where possible

**Estimated Savings:** ~1-1.5 KB per contract

**Implementation:**

- Create `GovernanceLibrary.sol` for slow-lane pattern
- Consolidate fee address, escrow fee, resolution module queue/activate
- Reduce duplicate validation logic

**Risk:** Medium - Need to maintain slow-lane pattern integrity

---

## Phase 3: Simplify Dispute Resolution (Priority: MEDIUM)

### Target: Dispute Resolution (~6.2 KB, 26% of BaseEscrow)

**Optimizations:**

1. Extract common resolver action logic
2. Consolidate partial release/cancel functions
3. Simplify escalation fee handling

**Estimated Savings:** ~1-2 KB per contract

**Implementation:**

- Already using `ResolverActionLibrary` - optimize further
- Consider consolidating `partialReleaseAsDisputeResolver` and `partialCancelAsDisputeResolver`
- Simplify `resolve()` function if possible

**Risk:** Medium-High - Core functionality, must be careful

---

## Phase 4: Reduce Library Overhead (Priority: LOW)

### Target: Library Calls (~1.5 KB, 6% of BaseEscrow)

**Optimizations:**

1. Inline small library functions
2. Reduce library linking overhead
3. Optimize compiler settings

**Estimated Savings:** ~0.5 KB per contract

**Implementation:**

- Review small library functions (< 50 bytes) for inlining
- Consider compiler optimizer settings
- Test different `runs` values

**Risk:** Low - Can test and revert if needed

---

## Phase 5: Extract Module Management (Priority: HIGH)

### Target: Module Management in Child Contracts (~360 lines, ~6-8 KB)

**Functions to Extract:**

- All `queueDefault*Module()` functions (4 functions)
- All `activateDefault*Module()` functions (4 functions)
- All `getPendingDefault*Module()` functions (4 functions)
- Total: 12 functions × 2 contracts = 24 functions

**Estimated Savings:** ~6-8 KB per contract

**Implementation:**

- Create `ModuleManager.sol` contract
- Child contracts delegate module management to ModuleManager
- Use proxy pattern or direct delegation

**Risk:** Medium - Requires architectural change

---

## Implementation Order

### Step 1: EscrowQueryLibrary (Immediate)

**Why First:**

- Low risk (view functions are stateless)
- Clear boundaries (all view functions)
- High impact (~2.1 KB savings)
- Easy to test

**Steps:**

1. Create `EscrowQueryLibrary.sol`
2. Move all view functions to library
3. Update BaseEscrow to call library
4. Test all view functions
5. Measure size reduction

**Expected Result:** ~2.1 KB savings per contract

---

### Step 2: Module Management Contract (High Impact)

**Why Second:**

- Highest potential savings (~6-8 KB)
- Affects child contracts, not BaseEscrow
- Can be done in parallel with other optimizations

**Steps:**

1. Design ModuleManager contract interface
2. Create ModuleManager contract
3. Refactor EscrowVault to use ModuleManager
4. Refactor EscrowableERC20 to use ModuleManager
5. Test module management functions
6. Measure size reduction

**Expected Result:** ~6-8 KB savings per contract

---

### Step 3: Governance Optimization (Medium Impact)

**Why Third:**

- Medium savings (~1-1.5 KB)
- Can be done after view functions
- Reduces duplication

**Steps:**

1. Create `GovernanceLibrary.sol`
2. Extract slow-lane pattern logic
3. Consolidate queue/activate functions
4. Test governance functions
5. Measure size reduction

**Expected Result:** ~1-1.5 KB savings per contract

---

### Step 4: Dispute Resolution Simplification (Medium Impact)

**Why Fourth:**

- Medium savings (~1-2 KB)
- More complex, needs careful testing
- Can be done after other optimizations

**Steps:**

1. Review dispute resolution functions
2. Identify consolidation opportunities
3. Extract common patterns
4. Test thoroughly
5. Measure size reduction

**Expected Result:** ~1-2 KB savings per contract

---

### Step 5: Library Overhead Reduction (Low Impact)

**Why Last:**

- Lowest savings (~0.5 KB)
- Can be done incrementally
- Test different approaches

**Steps:**

1. Identify small library functions
2. Test inlining vs library calls
3. Optimize compiler settings
4. Measure size reduction

**Expected Result:** ~0.5 KB savings per contract

---

## Actual Results vs Expected

| Phase                             | Expected Savings | Actual Result             | Status                                            |
| --------------------------------- | ---------------- | ------------------------- | ------------------------------------------------- |
| Phase 1: EscrowQueryLibrary       | ~2.1 KB          | **+0.3 KB** (increased)   | ⚠️ **FAILED** - Library overhead exceeded savings |
| Phase 1b: createEscrow Extraction | ~2-3 KB          | **-2.2 KB** (EscrowVault) | ✅ **SUCCESS** - Net savings achieved             |
| Phase 2: Module Management        | ~6-8 KB          | Not started               | ⏳ **PENDING**                                    |
| Phase 3: Governance Optimization  | ~1-1.5 KB        | Not started               | ⏳ **PENDING**                                    |
| Phase 4: Dispute Resolution       | ~1-2 KB          | Not started               | ⏳ **PENDING**                                    |
| Phase 5: Library Overhead         | ~0.5 KB          | Not started               | ⏳ **PENDING**                                    |

**Current Status:**

- EscrowVault: 38.91 KB (was 38.57 KB) - **+0.34 KB** ⚠️
- EscrowableERC20: 38.90 KB (was 38.73 KB) - **+0.17 KB** ⚠️

**Net Savings So Far:** ~-2 KB (from createEscrow extraction, offset by EscrowQueryLibrary overhead)

**Revised Target After All Phases:**

- EscrowVault: 38.91 KB → ~30-32 KB (still over, but closer)
- EscrowableERC20: 38.90 KB → ~30-32 KB (still over, but closer)

**Note:** Even with all optimizations, contracts may still exceed 24KB. Additional architectural changes (splitting BaseEscrow) may be necessary.

---

## Next Immediate Action: Module Management Contract (REVISED)

### Why Module Management Contract First?

1. **Highest Impact:** ~6-8 KB savings per contract (vs ~2 KB for view functions)
2. **Clear Boundaries:** All module management functions are in child contracts
3. **No Library Overhead:** Using a contract instead of library avoids linking overhead
4. **Proven Pattern:** Similar to EscrowOps contract (batch operations)

### Implementation Plan

1. **Design ModuleManager Contract**
   - Interface for module queue/activate/getPending
   - Handles all 4 module types (release strategy, resolution, yield gen, yield dist)
   - Uses slow-lane pattern (7-day delay)

2. **Create ModuleManager Contract**
   - Deployable contract (not library)
   - Stores pending module changes
   - Provides queue/activate/getPending functions

3. **Refactor Child Contracts**
   - EscrowVault and EscrowableERC20 delegate to ModuleManager
   - Remove 12 module management functions from each contract
   - Keep module storage in child contracts (or move to ModuleManager?)

4. **Test**
   - Test module queue/activate/getPending
   - Verify slow-lane pattern works
   - Check contract sizes

5. **Measure**
   - Compare before/after sizes
   - Target: ~6-8 KB savings per contract

---

## Success Criteria

- [ ] ModuleManager contract created and tested
- [ ] All module management functions extracted
- [ ] Contract size reduced by ~6-8 KB per contract
- [ ] All tests passing
- [ ] Slow-lane pattern maintained

---

## Risks & Mitigations

### Risk 1: Library Overhead Exceeds Savings

**Mitigation:** Test with small subset first, measure actual savings

### Risk 2: ABI Compatibility Broken

**Mitigation:** Keep function signatures identical, only change implementation

### Risk 3: Gas Costs Increase

**Mitigation:** View functions don't cost gas, but test to ensure no regressions

### Risk 4: Storage Access Issues

**Mitigation:** Use `storage` keyword for storage references, test thoroughly

---

## Timeline Estimate

- **Phase 1 (EscrowQueryLibrary):** 2-3 hours
- **Phase 2 (Module Management):** 4-6 hours
- **Phase 3 (Governance):** 2-3 hours
- **Phase 4 (Dispute Resolution):** 3-4 hours
- **Phase 5 (Library Overhead):** 1-2 hours

**Total:** ~12-18 hours of development + testing
