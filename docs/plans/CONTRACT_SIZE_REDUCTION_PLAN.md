# Contract Size Reduction Plan

**Date**: 2025-01-XX  
**Goal**: Get all contracts under 24KB (24576 bytes)  
**Priority**: HIGH - Blocking mainnet deployment

---

## Current State Analysis

### Contract Sizes (Actual - from forge build)

**Current Sizes**:
- **EscrowVault**: 40,004 bytes (exceeds by **15,428 bytes**)
- **EscrowableERC20**: 37,972 bytes (exceeds by **13,396 bytes**)
- **BaseEscrow**: (inherited by above, need to check standalone)

**Target**: All contracts < 24,576 bytes (24KB)

**Critical**: We need to reduce by **~13-15KB** for child contracts. Since they inherit BaseEscrow, reducing BaseEscrow will help all three.

---

## Proposed Changes Analysis

### 1. Minimize Yield Distribution in BaseEscrow ⭐ **HIGH IMPACT**

**Current State**:
- `_distributeYield()` - ~30 lines with fallback logic
- `setDefaultYieldDistribution()` - ~15 lines
- `setEscrowYieldDistribution()` - ~20 lines
- `getDefaultYieldDistribution()` - ~5 lines
- `getEscrowYieldDistribution()` - ~5 lines
- `_encodeYieldDistribution()` - ~15 lines
- `_validateYieldDistribution()` - ~5 lines (already in library)
- Storage: `defaultYieldDistribution`, `escrowYieldDistribution` mapping

**Proposal**: 
- Remove fallback distribution logic from BaseEscrow
- Keep only module delegation: `_distributeYield()` → calls module only
- Remove `setDefaultYieldDistribution()` and `setEscrowYieldDistribution()` from BaseEscrow
- Move yield distribution management entirely to `DefaultYieldDistributionModule`
- Keep storage for backward compatibility (or remove if breaking change acceptable)

**Estimated Savings**: 
- Code: ~90 lines → **~3-4KB**
- Storage: Keep for compatibility (or remove for additional savings)

**Effort**: Medium (2-3 hours)
**Risk**: Low-Medium (requires module to handle all cases)

---

### 2. Library for Validation ⭐ **MEDIUM IMPACT**

**Current State**:
- Already extracted: `SettingsValidationLibrary`
- Still in BaseEscrow: Various inline validations

**Proposal**:
- Move remaining validation logic to libraries
- Already done for most validations
- Could extract resolver validation logic

**Estimated Savings**: 
- Minimal (~0.5-1KB) - most already extracted

**Effort**: Low (1-2 hours)
**Risk**: Low

---

### 3. Library for Propose/Queue/Activate ⭐ **MEDIUM-HIGH IMPACT**

**Current State**:
- `SlowLaneQueueActivate` mixin already exists
- BaseEscrow has: `proposeResolutionModule()`, `activateResolutionModule()`
- Slow lane functions: `queueEscrowFeeAddress()`, `activateEscrowFeeAddress()`, `queueEscrowFee()`, `activateEscrowFee()`, `queueDao()`, `activateDao()`

**Proposal**:
- Move propose/activate pattern to library
- Keep queue/activate in `SlowLaneQueueActivate` (already there)
- Extract `proposeResolutionModule()` logic to library
- Could create `ResolutionModuleLibrary` for module management

**Estimated Savings**:
- `proposeResolutionModule()` + `activateResolutionModule()`: ~30 lines → **~1-1.5KB**
- Slow lane functions already in mixin, minimal savings

**Effort**: Medium (2-3 hours)
**Risk**: Low

---

### 4. Remove Category Key Generation ⭐ **LOW IMPACT**

**Current State**:
- `_generateCategoryKey()` - ~10 lines
- Called in `_initializeDisputeInModule()`

**Proposal**:
- Move category key generation to `DecentralizedResolutionModule`
- BaseEscrow just passes token/amount, module generates key
- Or remove entirely if not needed

**Estimated Savings**: 
- ~10 lines → **~0.3-0.5KB**

**Effort**: Low (30 minutes)
**Risk**: Low

---

### 5. Escalate Dispute in Escalation Module ⭐ **MEDIUM IMPACT**

**Current State**:
- `escalateDispute()` in BaseEscrow - ~70 lines
- Handles: validation, fee collection, module call, resolver update

**Proposal**:
- Move escalation logic to `DecentralizedResolutionModule`
- BaseEscrow keeps minimal interface: `escalateDispute(workflowId)` → delegates to module
- Module handles: fee validation, fee collection, escalation execution
- BaseEscrow just updates resolver after module returns

**Estimated Savings**:
- ~70 lines → **~2-2.5KB**
- But need to add module interface calls

**Effort**: Medium-High (3-4 hours)
**Risk**: Medium (changes core escalation flow)

**Alternative**: Keep fee collection in BaseEscrow, move only escalation logic to module

---

### 6. Batch Release to External EscrowOps Contract ⭐ **LOW-MEDIUM IMPACT**

**Current State**:
- `batchReleaseEscrow()` - ~40 lines
- Called infrequently (gas efficiency less critical)

**Proposal**:
- Create `EscrowOps` contract for batch operations
- Move `batchReleaseEscrow()` to external contract
- BaseEscrow exposes minimal interface for batch operations
- Or remove entirely if not critical

**Estimated Savings**:
- ~40 lines → **~1-1.5KB**

**Effort**: Low-Medium (2-3 hours)
**Risk**: Low (can be added later if needed)

---

### 7. Recovery into Library ⭐ **LOW IMPACT**

**Current State**:
- `recoverNativeETH()` - ~25 lines
- `recoverERC20()` - ~40 lines

**Proposal**:
- Move to `RecoveryLibrary`
- BaseEscrow keeps thin wrapper

**Estimated Savings**:
- ~65 lines → **~2KB**

**Effort**: Low (1-2 hours)
**Risk**: Low

---

## Size Savings Summary

| Change | Estimated Savings | Effort | Risk | Priority |
|--------|------------------|--------|------|----------|
| 1. Minimize Yield Distribution | **3-4KB** | Medium | Low-Med | ⭐⭐⭐ **HIGH** |
| 2. Validation Library | 0.5-1KB | Low | Low | ⭐ Low |
| 3. Propose/Queue/Activate Library | 1-1.5KB | Medium | Low | ⭐⭐ Medium |
| 4. Remove Category Key | 0.3-0.5KB | Low | Low | ⭐ Low |
| 5. Escalate in Module | **2-2.5KB** | Medium-High | Medium | ⭐⭐ **MEDIUM** |
| 6. Batch Release External | 1-1.5KB | Low-Med | Low | ⭐ Low |
| 7. Recovery Library | **2KB** | Low | Low | ⭐⭐ Medium |

**Total Estimated Savings**: ~10-13KB

**Current Excess**: ~9KB (BaseEscrow)

**Conclusion**: With changes 1, 5, and 7, we should get BaseEscrow under 24KB (~7-8.5KB savings). Additional changes can provide buffer.

---

## Recommended Approach

### Phase 1: High-Impact Changes (Target: 7-8KB savings)

1. **Minimize Yield Distribution** (3-4KB) ⭐⭐⭐
   - Remove fallback logic
   - Move management to module
   - Keep storage for compatibility

2. **Recovery Library** (2KB) ⭐⭐
   - Extract to library
   - Thin wrapper in BaseEscrow

3. **Escalate in Module** (2-2.5KB) ⭐⭐
   - Move escalation logic to module
   - Keep fee collection in BaseEscrow (or move to module)

**Total Phase 1 Savings**: ~7-8.5KB

### Phase 2: Additional Optimizations (If needed)

4. **Propose/Queue/Activate Library** (1-1.5KB)
5. **Batch Release External** (1-1.5KB)
6. **Remove Category Key** (0.3-0.5KB)

**Total Phase 2 Savings**: ~2.8-3.5KB

---

## Decision: Split vs Optimize?

### Option A: Optimize BaseEscrow (Recommended)
- **Pros**: 
  - Maintains single contract architecture
  - Easier to understand and maintain
  - Changes are incremental
- **Cons**:
  - May need multiple optimization rounds
  - Some features may need to be removed
- **Estimated Savings**: 10-13KB (should be enough)

### Option B: Split BaseEscrow
- **Pros**:
  - Guaranteed to get under limit
  - Clear separation of concerns
- **Cons**:
  - High effort (3-5 days)
  - More complex architecture
  - More contracts to maintain
- **When to Consider**: If optimization doesn't work

**Recommendation**: Start with Option A (optimization). If after Phase 1 we're still over, consider splitting.

---

## Implementation Plan

### Step 1: Verify Current Sizes
- [ ] Compile contracts and get exact sizes
- [ ] Identify largest functions
- [ ] Calculate exact savings needed

### Step 2: Phase 1 Implementation
- [ ] Minimize yield distribution (3-4KB)
- [ ] Recovery library (2KB)
- [ ] Escalate in module (2-2.5KB)
- [ ] Test all changes
- [ ] Verify size reduction

### Step 3: Verify Size
- [ ] Compile and check sizes
- [ ] If still over 24KB, proceed to Phase 2

### Step 4: Phase 2 (If Needed)
- [ ] Propose/Queue/Activate library
- [ ] Batch release external
- [ ] Remove category key
- [ ] Test all changes
- [ ] Verify size reduction

### Step 5: Final Verification
- [ ] All contracts < 24KB
- [ ] All tests passing
- [ ] Documentation updated

---

## Risk Mitigation

1. **Yield Distribution**: Ensure module handles all cases before removing fallback
2. **Escalation**: Keep fee collection in BaseEscrow for safety, move only escalation logic
3. **Testing**: Comprehensive tests after each change
4. **Backward Compatibility**: Keep storage structures if possible

---

## Next Steps

1. **Verify current contract sizes** (compile and measure)
2. **Start with Phase 1, Change 1** (Minimize Yield Distribution)
3. **Measure after each change** to track progress
4. **Adjust plan** based on actual savings

---

**Status**: Planning  
**Priority**: HIGH  
**Estimated Timeline**: 1-2 days for Phase 1, 1 day for Phase 2 if needed

