# Next Optimization Actions to Get Under 24KB

**Date:** 2025-01-27  
**Current Status:**
- EscrowVault: 38.91 KB (62.1% over limit)
- EscrowableERC20: 38.90 KB (62.1% over limit)

## Phase 1 Results: EscrowQueryLibrary ⚠️

**Status:** Completed but **increased size** by ~0.3 KB  
**Reason:** Library linking overhead exceeded savings for simple view functions  
**Decision Needed:** Revert or keep for code organization?

**Recommendation:** **Keep for now** - Code is better organized, and we can optimize later if needed.

---

## Phase 2: Module Management Contract (Priority: HIGHEST)

### Why This First?

1. **Highest Impact:** ~6-8 KB savings per contract
2. **Clear Duplication:** 12 identical functions × 2 contracts = 24 functions
3. **No Library Overhead:** Using a contract avoids linking overhead
4. **Proven Pattern:** Similar to EscrowOps contract

### Current Duplication

**EscrowVault & EscrowableERC20 each have:**
- `queueDefaultReleaseStrategy()` - ~30 lines
- `activateDefaultReleaseStrategy()` - ~10 lines
- `getPendingDefaultReleaseStrategy()` - ~5 lines
- `queueDefaultResolutionModule()` - ~30 lines
- `activateDefaultResolutionModule()` - ~10 lines
- `getPendingDefaultResolutionModule()` - ~5 lines
- `queueDefaultYieldGenerationModule()` - ~30 lines
- `activateDefaultYieldGenerationModule()` - ~10 lines
- `getPendingDefaultYieldGenerationModule()` - ~5 lines
- `queueDefaultYieldDistributionModule()` - ~30 lines
- `activateDefaultYieldDistributionModule()` - ~10 lines
- `getPendingDefaultYieldDistributionModule()` - ~5 lines

**Total:** ~180 lines per contract × 2 = **360 lines of duplication**

### Proposed Solution: ModuleManager Contract

**Design:**
```solidity
contract ModuleManager {
    // Stores pending changes for each escrow contract
    mapping(address => mapping(bytes32 => PendingAddress)) public pendingModules;
    
    // Generic queue function
    function queueModule(
        address escrowContract,
        bytes32 moduleType,
        address newModule,
        bytes4 interfaceId
    ) external;
    
    // Generic activate function
    function activateModule(
        address escrowContract,
        bytes32 moduleType
    ) external returns (address oldModule, address newModule);
    
    // Generic getPending function
    function getPendingModule(
        address escrowContract,
        bytes32 moduleType
    ) external view returns (address value, uint64 eta, bool exists);
}
```

**Child Contract Changes:**
- Remove all 12 module management functions
- Add thin wrappers that call ModuleManager
- Keep module storage in child contracts (or move to ModuleManager?)

**Estimated Savings:** ~6-8 KB per contract

**Risk:** Medium - Requires architectural change, but pattern is proven

---

## Phase 3: Governance Library (Priority: MEDIUM)

### Target: Slow-Lane Pattern Functions

**Functions to Extract:**
- `queueEscrowFeeAddress()` / `activateEscrowFeeAddress()` / `getPendingFeeRecipient()`
- `queueEscrowFee()` / `activateEscrowFee()` / `getPendingEscrowFee()`
- Common slow-lane validation logic

**Estimated Savings:** ~1-1.5 KB per contract

**Implementation:**
- Create `GovernanceLibrary.sol` for slow-lane pattern
- Extract common queue/activate/getPending logic
- Keep contract-specific logic in BaseEscrow

---

## Phase 4: Dispute Resolution Simplification (Priority: MEDIUM)

### Target: Resolver Action Functions

**Opportunities:**
1. Consolidate `partialReleaseAsDisputeResolver` and `partialCancelAsDisputeResolver`
2. Simplify `resolve()` function
3. Extract common resolver validation logic

**Estimated Savings:** ~1-2 KB per contract

**Risk:** Medium-High - Core functionality, must be careful

---

## Phase 5: Optimize Compiler Settings (Priority: LOW)

### Target: Compiler Optimizer

**Options:**
1. Increase `runs` parameter (currently 10000)
2. Test `runs: 20000` or `runs: 50000`
3. Review `viaIR` setting

**Estimated Savings:** ~0.5-1 KB per contract

**Risk:** Low - Can test and revert

---

## Recommended Implementation Order

### Step 1: Module Management Contract ⭐ **START HERE**
**Why:** Highest impact, clear boundaries, proven pattern  
**Effort:** 4-6 hours  
**Expected Savings:** ~6-8 KB per contract  
**Risk:** Medium

### Step 2: Governance Library
**Why:** Medium impact, reduces duplication  
**Effort:** 2-3 hours  
**Expected Savings:** ~1-1.5 KB per contract  
**Risk:** Low

### Step 3: Dispute Resolution Simplification
**Why:** Medium impact, but more complex  
**Effort:** 3-4 hours  
**Expected Savings:** ~1-2 KB per contract  
**Risk:** Medium-High

### Step 4: Compiler Optimization
**Why:** Low impact, but easy to test  
**Effort:** 1-2 hours  
**Expected Savings:** ~0.5-1 KB per contract  
**Risk:** Low

---

## Expected Final Sizes

### After All Phases
- **EscrowVault:** 38.91 KB → ~30-32 KB (still over, but 20-25% reduction)
- **EscrowableERC20:** 38.90 KB → ~30-32 KB (still over, but 20-25% reduction)

### Remaining Gap
- Still need to reduce by ~6-8 KB to get under 24KB
- **Additional Options:**
  1. Split BaseEscrow into multiple contracts
  2. Use proxy pattern for BaseEscrow
  3. Further architectural changes

---

## Decision: EscrowQueryLibrary

**Options:**
1. **Keep** - Better code organization, minimal size impact
2. **Revert** - Remove library, inline functions back

**Recommendation:** **Keep for now** - Focus on higher-impact optimizations first. Can revisit later if needed.

---

## Next Immediate Action

**Start with Module Management Contract** - This has the highest potential impact and will give us the most progress toward the 24KB goal.



