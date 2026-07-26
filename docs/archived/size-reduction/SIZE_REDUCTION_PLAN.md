# EscrowVault Size Reduction Plan
## Target: Save 3.26 KB (3,330 bytes) to get under 24 KB limit

### Current Size: 27.26 KB (27,930 bytes)
### Target Size: < 24 KB (24,576 bytes)
### Required Savings: 3,330 bytes

---

## Optimization Strategies (Estimated Savings)

### 1. Extract Module Getter Logic to Library (~1,200 bytes)
**Location**: Lines 155-198
**Action**: 
- Create `ModuleGetterLibrary.sol` to handle `_getModuleAddress` logic
- Use assembly or optimized pattern for module type lookup
- Move all 4 getter functions to use library pattern
**Savings**: ~1,200 bytes

### 2. Optimize Constructor (~300 bytes)
**Location**: Lines 41-74
**Action**:
- Consolidate validation into single helper
- Use assembly for multiple assignments
- Remove redundant comments
**Savings**: ~300 bytes

### 3. Simplify recoverERC20 (~200 bytes)
**Location**: Lines 257-274
**Action**:
- Inline calculations
- Remove intermediate variables where possible
- Simplify error handling
**Savings**: ~200 bytes

### 4. Optimize withdrawFees (~150 bytes)
**Location**: Lines 229-246
**Action**:
- Inline balance check
- Simplify error handling
- Remove redundant comments
**Savings**: ~150 bytes

### 5. Optimize _getModuleAddress with Assembly (~600 bytes)
**Location**: Lines 155-173
**Action**:
- Use assembly for switch-like pattern
- Optimize storage reads
- Reduce conditional branching
**Savings**: ~600 bytes

### 6. Consolidate Error Definitions (~200 bytes)
**Location**: Line 39
**Action**:
- Use more compact error encoding
- Combine related errors
**Savings**: ~200 bytes

### 7. Remove Empty Override Functions (~280 bytes)
**Location**: Lines 111-119, 137-152
**Action**:
- Remove `_emitEscrowTransferCreated` (already empty)
- Remove `_emitEscrowTransferCancelled` (already empty)
- Remove `_emitEscrowTransferReleased` (already empty)
- Make BaseEscrow functions non-virtual if not needed
**Savings**: ~280 bytes

### 8. Optimize releaseEscrowTransfer (~100 bytes)
**Location**: Lines 83-89
**Action**:
- Inline validation
- Simplify return pattern
**Savings**: ~100 bytes

### 9. Remove Unused Constants/Comments (~100 bytes)

### 10. Optimize Module Getter Wrappers (~300 bytes)
**Location**: Lines 175-198
**Action**:
- Inline simple getters that just cast `_getModuleAddress` result
- Use assembly for type casting where possible
- Reduce function overhead
**Savings**: ~300 bytes
**Location**: Throughout file
**Action**:
- Remove excessive comments
- Remove unused constants if any
**Savings**: ~100 bytes

---

## Total Estimated Savings: ~3,430 bytes
## Buffer: ~200 bytes (safety margin)

---

## Implementation Priority Order:
1. Extract module getter logic to library (highest impact)
2. Optimize _getModuleAddress with assembly
3. Remove empty override functions
4. Optimize module getter wrappers
5. Optimize constructor
6. Simplify recoverERC20 and withdrawFees
7. Other optimizations

## NOTE: Wrapper Functions Cannot Be Removed
- `queueDefaultReleaseStrategy` and `activateDefaultReleaseStrategy` are REQUIRED
- ModuleManagementContract requires `msg.sender == escrowContract`
- These wrappers allow governance (ROLE_TIMELOCK) to swap modules via the escrow contract

---

## Notes:
- All changes must preserve functionality
- Test coverage must be maintained
- No breaking changes to public interface
