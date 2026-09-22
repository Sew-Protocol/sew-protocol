# Module Naming Consistency Status

## Current State (Inconsistent)

### ModuleManagementContract
- ✅ `queueDefaultModule(escrowContract, moduleType, module)` - Generic function
- ✅ `activateDefaultModule(escrowContract, moduleType)` - Generic function
- ✅ `getDefaultModule(escrowContract, moduleType)` - Generic function

### EscrowVault / EscrowableERC20
- ⚠️ `queueDefaultReleaseStrategy(newModule)` - **Only for RELEASE module**
- ⚠️ `activateDefaultReleaseStrategy()` - **Only for RELEASE module**
- ❌ **Missing wrappers for other 3 module types** (RESOLUTION, YIELD_GEN, YIELD_DIST)

## The Problem

1. **Naming Inconsistency**:
   - ModuleManagementContract uses `queueDefaultModule` (generic, has "Default" in name)
   - EscrowVault uses `queueDefaultReleaseStrategy` (specific, has "Default" in name)
   - Both have "Default" but it means different things:
     - In ModuleManagementContract: "Default" refers to default modules (vs per-escrow custom modules)
     - In EscrowVault: "Default" is redundant since these ARE the default modules

2. **Incomplete Coverage**:
   - Only RELEASE module has wrapper functions
   - Other 3 module types (RESOLUTION, YIELD_GEN, YIELD_DIST) have no wrappers
   - Governance must call ModuleManagementContract directly for those (but can't due to `msg.sender == escrowContract` check)

3. **Why Only RELEASE?**
   - Likely historical: RELEASE was the first module type that needed swapping
   - Other modules may not have needed swapping yet
   - But this creates inconsistency and confusion

## Proposed Solution: Switch to `queueModule` Naming

### Rationale
- "Default" is a **naming convention**, not a functional distinction
- All modules managed by ModuleManagementContract are "default" modules
- Generic naming (`queueModule`) is cleaner and more consistent
- Matches the pattern in `CHILD_CONTRACTS_OPTIMIZATION_ANALYSIS.md`

### Changes Required

#### 1. ModuleManagementContract
```solidity
// OLD:
function queueDefaultModule(address escrowContract, BaseEscrow.ModuleType moduleType, address module)
function activateDefaultModule(address escrowContract, BaseEscrow.ModuleType moduleType)
function getDefaultModule(address escrowContract, BaseEscrow.ModuleType moduleType)

// NEW:
function queueModule(address escrowContract, BaseEscrow.ModuleType moduleType, address module)
function activateModule(address escrowContract, BaseEscrow.ModuleType moduleType)
function getModule(address escrowContract, BaseEscrow.ModuleType moduleType)
```

#### 2. EscrowVault / EscrowableERC20
**Option A: Generic Wrapper (Recommended)**
```solidity
// Single generic wrapper for all module types
function queueModule(BaseEscrow.ModuleType moduleType, address newModule) external onlyRole(ROLE_TIMELOCK) {
    moduleManagement.queueModule(address(this), moduleType, newModule);
}

function activateModule(BaseEscrow.ModuleType moduleType) external onlyRole(ROLE_TIMELOCK) {
    moduleManagement.activateModule(address(this), moduleType);
}
```

**Option B: Keep Specific Wrappers (Current Pattern)**
```solidity
// Keep specific wrappers but rename to match ModuleManagementContract
function queueReleaseStrategy(address newModule) external onlyRole(ROLE_TIMELOCK) {
    moduleManagement.queueModule(address(this), ModuleType.RELEASE, newModule);
}
// ... same for other 3 module types
```

**Option C: Remove Wrappers Entirely**
- Only possible if ModuleManagementContract is changed to `onlyRole(ROLE_TIMELOCK)`
- See `MODULE_MANAGEMENT_SECURITY_ANALYSIS.md` for details

### Recommendation: Option A (Generic Wrapper)

**Benefits**:
- ✅ Consistent naming with ModuleManagementContract
- ✅ Covers all 4 module types with 2 functions (vs 8 specific functions)
- ✅ Saves bytecode (~400 bytes vs Option B)
- ✅ More flexible (easy to add new module types)
- ✅ Matches the library pattern proposed in `CHILD_CONTRACTS_OPTIMIZATION_ANALYSIS.md`

**Trade-offs**:
- ⚠️ Slightly less explicit (caller must pass `ModuleType` enum)
- ⚠️ Breaking change for existing callers (but likely minimal impact)

## Implementation Status

### ✅ Completed
- Analysis of current state
- Documentation of inconsistency
- Proposal for solution

### ⏳ Pending
- [ ] Rename functions in ModuleManagementContract
- [ ] Update EscrowVault wrapper functions
- [ ] Update EscrowableERC20 wrapper functions
- [ ] Update all tests
- [ ] Update governance scripts
- [ ] Update documentation

## Breaking Changes

### ModuleManagementContract
- `queueDefaultModule` → `queueModule` (breaking)
- `activateDefaultModule` → `activateModule` (breaking)
- `getDefaultModule` → `getModule` (breaking)

### EscrowVault / EscrowableERC20
- `queueDefaultReleaseStrategy` → `queueModule(ModuleType.RELEASE, ...)` (breaking)
- `activateDefaultReleaseStrategy` → `activateModule(ModuleType.RELEASE)` (breaking)

**Impact**: 
- Governance scripts need updates
- Any external callers need updates
- Tests need updates

## Migration Path

1. **Phase 1**: Rename ModuleManagementContract functions
2. **Phase 2**: Update EscrowVault/EscrowableERC20 to use generic wrappers
3. **Phase 3**: Update all callers (tests, scripts, docs)
4. **Phase 4**: Remove old function names (if keeping both temporarily)

## Size Impact

**Current** (Option B - specific wrappers):
- 2 functions × 2 contracts = 4 wrapper functions
- ~100 bytes per function = ~400 bytes total

**Proposed** (Option A - generic wrappers):
- 2 functions × 2 contracts = 4 wrapper functions
- ~80 bytes per function = ~320 bytes total
- **Savings: ~80 bytes**

**If removing wrappers** (Option C - requires ModuleManagementContract change):
- **Savings: ~400 bytes**
- See `MODULE_MANAGEMENT_SECURITY_ANALYSIS.md` for security implications

## Next Steps

1. **Decision**: Choose Option A, B, or C
2. **Implementation**: Rename functions and update callers
3. **Testing**: Verify all tests pass
4. **Documentation**: Update all references

---

**Status**: Proposal Ready, Awaiting Decision  
**Last Updated**: 2026-01-XX  
**Related Docs**:
- `CHILD_CONTRACTS_OPTIMIZATION_ANALYSIS.md` - Original proposal for `queueModule`
- `MODULE_MANAGEMENT_SECURITY_ANALYSIS.md` - Security implications of removing wrappers
