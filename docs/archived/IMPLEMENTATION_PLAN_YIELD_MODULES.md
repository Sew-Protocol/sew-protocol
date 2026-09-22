# Implementation Plan: Yield Module Externalization

## Overview

This document outlines the step-by-step implementation of the yield module externalization architecture. It should be executed in two focused sessions over 8-11 hours total.

---

## Session 1: Architecture & Core Extraction (4-5 hours)

### Phase 1.1: Create IYieldModule Interface (30 min)

**File to create:** `contracts/interfaces/IYieldModule.sol`

**Tasks:**
- [ ] Copy interface definition from ARCHITECTURE_YIELD_MODULES.md
- [ ] Add NatSpec documentation
- [ ] Include all method signatures with clear parameter docs
- [ ] Add event definitions (YieldInitialized, YieldHandled, YieldUnwound)

**Deliverable:** Complete, documented interface ready for implementation

**Verification:**
```bash
npx hardhat compile  # Should compile without errors
```

---

### Phase 1.2: Extract AaveYieldModule (2 hours)

**File to create:** `contracts/modules/yield/AaveYieldModule.sol`

**Tasks:**
- [ ] Create module skeleton implementing IYieldModule
- [ ] Extract `_handleYieldAndGetActualAmount()` from BaseEscrow (~300 lines)
- [ ] Extract `_depositYieldForEscrow()` logic
- [ ] Extract YieldOps integration code
- [ ] Extract Aave-specific validation logic
- [ ] Update all function signatures to match IYieldModule
- [ ] Add error handling and events

**Key methods to implement:**

1. `initializeYield()`
   - Currently: part of `_snapshotModulesForEscrow()` in BaseEscrow
   - Move to: AaveYieldModule
   - Returns: (bool success, uint256 initializedAmount)

2. `handleYieldAndGetAmount()`
   - Currently: `_handleYieldAndGetActualAmount()` (~300 lines)
   - Move entire implementation
   - Returns: (actualAmount, yieldAmount, yieldDistributed)

3. `emergencyUnwind()`
   - Currently: error handling in _handleYieldAndGetActualAmount
   - Extract recovery logic
   - Returns: (recoveredAmount, yieldAbandonedAmount)

4. `canHandle()`
   - New method (not in current code)
   - Check: token is registered, amount is reasonable
   - Returns: (bool, string reason)

5. `getModuleInfo()`
   - New method (not in current code)
   - Returns: ("AaveYieldModule", "1.0.0", "Aave")

**Notes:**
- Will need to import YieldOps, YieldPresetLibrary, Aave contracts
- Reuse as much existing code as possible (minimize rewriting)
- Keep same logic, just reorganize into module structure

**Deliverable:** Compiling AaveYieldModule with all logic extracted

**Verification:**
```bash
npx hardhat compile  # Should compile
grep -c "_handleYieldAndGetActualAmount" contracts/core/BaseEscrow.sol  # Should be < 5
```

---

### Phase 1.3: Create Thin Delegation Methods in BaseEscrow (1 hour)

**File to modify:** `contracts/core/BaseEscrow.sol`

**Tasks:**

1. **Remove from BaseEscrow:**
   - [ ] Delete entire `_handleYieldAndGetActualAmount()` function
   - [ ] Delete `_depositYieldForEscrow()` implementation
   - [ ] Delete YieldOps integration code
   - [ ] Delete YieldPresetLibrary functions
   - [ ] Delete Aave-specific validation

2. **Add to BaseEscrow:**
   - [ ] Import IYieldModule interface
   - [ ] Add thin `_delegateYieldInitialization()` method (~30 lines)
   - [ ] Add thin `_handleYieldAndGetActualAmount()` dispatcher (~40 lines)
   - [ ] Add thin `_emergencyUnwindYield()` method (~25 lines)
   - [ ] Keep virtual placeholders if needed for child contracts

3. **Update ModuleSnapshot struct:**
   - [ ] Add `address yieldModule` field
   - [ ] Document: "Snapshotted at creation, immutable"

**Code to add (dispatcher methods):**

```solidity
// Thin delegation - all yield logic moved to module
function _delegateYieldInitialization(
    uint256 workflowId,
    address token,
    uint256 amount,
    YieldPreset yieldMode
) internal returns (uint256) {
    address mod = moduleSnapshots[workflowId].yieldModule;
    if (mod == address(0)) return amount;  // No yield, pass-through
    
    (bool ok, bytes memory ret) = mod.call(
        abi.encodeWithSelector(
            IYieldModule.initializeYield.selector,
            workflowId, token, amount, yieldMode
        )
    );
    if (!ok) return amount;  // Fall back if init fails
    
    (bool success, uint256 initialized) = abi.decode(ret, (bool, uint256));
    return success ? initialized : amount;
}

function _handleYieldAndGetActualAmount(
    uint256 workflowId,
    address token,
    uint256 amount
) internal virtual returns (uint256) {
    address mod = moduleSnapshots[workflowId].yieldModule;
    if (mod == address(0)) return amount;  // No yield, return as-is
    
    (bool ok, bytes memory ret) = mod.call(
        abi.encodeWithSelector(
            IYieldModule.handleYieldAndGetAmount.selector,
            workflowId, token, amount
        )
    );
    
    if (!ok) {
        emit OperationFailure(2, workflowId, mod, 
            IYieldModule.handleYieldAndGetAmount.selector, 
            uint8(FailureReason.CALL_FAILED));
        return amount;  // Fall back: return principal
    }
    
    (uint256 actualAmount, uint256 yield, uint256 distributed) = 
        abi.decode(ret, (uint256, uint256, uint256));
    
    if (yield > 0) emit YieldHandled(workflowId, yield, distributed);
    return actualAmount;
}

function _emergencyUnwindYield(
    uint256 workflowId,
    address token,
    uint256 principalAmount
) internal returns (uint256) {
    address mod = moduleSnapshots[workflowId].yieldModule;
    if (mod == address(0)) return principalAmount;
    
    (bool ok, bytes memory ret) = mod.call(
        abi.encodeWithSelector(
            IYieldModule.emergencyUnwind.selector,
            workflowId, token, principalAmount
        )
    );
    
    if (!ok) return principalAmount;
    
    (uint256 recovered,) = abi.decode(ret, (uint256, uint256));
    return recovered;
}
```

**Deliverable:** BaseEscrow compiles with thin delegation in place, old logic removed

**Verification:**
```bash
npx hardhat compile  # Must compile
wc -l contracts/core/BaseEscrow.sol  # Should decrease by ~300 lines
```

---

### Phase 1.4: Verify Bytecode Savings (30 min)

**Tasks:**
- [ ] Compile all contracts
- [ ] Run size report script
- [ ] Measure savings per contract
- [ ] Verify targets met (should see ~1,600 B savings)

**Expected results:**
```
EscrowVault:            27,514 → 25,914 B (-1,600 B) ✅
EscrowableERC20:        28,163 → 26,563 B (-1,600 B) ✅
BasicEscrowVault:       24,598 → 23,000 B (-1,600 B) ✅ COMPLIANT
BasicEscrowableERC20:   25,904 → 24,304 B (-1,600 B) ✅ COMPLIANT
```

**Verification:**
```bash
npm run build
npx ts-node scripts/print-contract-sizes.ts
```

**If not hitting targets:**
- Check that old yield code was fully removed from BaseEscrow
- Verify module delegation methods are as thin as possible
- Look for other embeddings of yield logic

---

## Session 2: Testing & Polish (4-6 hours)

### Phase 2.1: Update EscrowVault & EscrowableERC20 (30 min)

**Files to modify:**
- `contracts/core/EscrowVault.sol`
- `contracts/core/EscrowableERC20.sol`

**Tasks:**
- [ ] Remove any custom yield handling
- [ ] Update constructors if needed to pass yieldModule
- [ ] Remove YieldOps imports if no longer needed
- [ ] Update any yield-related method overrides

**Expected:** Minimal changes, likely just removing unused overrides

**Verification:**
```bash
npx hardhat compile
```

---

### Phase 2.2: Update Module Registry (30 min)

**File to modify:** `contracts/core/ModuleSnapshotRegistry.sol`

**Tasks:**
- [ ] Add yieldModule address field to snapshot creation
- [ ] Register AaveYieldModule as default for each YieldPreset
- [ ] Update snapshot getter to include yieldModule
- [ ] Add helper to query which module handles a preset

**Example registration:**
```solidity
// Register default modules for each preset
yieldModules[keccak256("aave")][YieldPreset.OFF] = address(0);
yieldModules[keccak256("aave")][YieldPreset.TO_SENDER] = aaveYieldModuleAddress;
yieldModules[keccak256("aave")][YieldPreset.TO_RECIPIENT] = aaveYieldModuleAddress;
yieldModules[keccak256("aave")][YieldPreset.SPLIT] = aaveYieldModuleAddress;
```

**Deliverable:** Registry can resolve module for any escrow

**Verification:**
```bash
npx hardhat compile
```

---

### Phase 2.3: Create Mock IYieldModule for Tests (1 hour)

**File to create:** `test/foundry/mocks/MockYieldModule.sol`

**Purpose:** Allow core escrow tests to run without Aave dependencies

**Methods to implement:**
```solidity
contract MockYieldModule is IYieldModule {
    bool public shouldFail = false;
    uint256 public mockYieldAmount = 0;
    
    function initializeYield(...) external returns (bool, uint256) {
        if (shouldFail) return (false, 0);
        return (true, amount);  // Accept full amount
    }
    
    function handleYieldAndGetAmount(...) external returns (uint256, uint256, uint256) {
        if (shouldFail) return (principalAmount, 0, 0);  // No yield on failure
        return (principalAmount, mockYieldAmount, mockYieldAmount);
    }
    
    function emergencyUnwind(...) external returns (uint256, uint256) {
        return (principalAmount, 0);
    }
    
    function canHandle(...) external pure returns (bool, string memory) {
        return (true, "");  // Always accepts
    }
    
    function getModuleInfo() external pure returns (string memory, string memory, string memory) {
        return ("MockYieldModule", "1.0.0", "Mock");
    }
}
```

**Deliverable:** Mock that can be used in all core tests

---

### Phase 2.4: Move Yield Tests to AaveYieldModule Tests (1.5 hours)

**Task:**
- [ ] Identify all yield-specific tests in current test suite
- [ ] Create `test/foundry/modules/AaveYieldModule.t.sol`
- [ ] Move yield test logic to module tests
- [ ] Update test mocks to use AaveYieldModule instead of MockYieldModule

**Files affected:**
- All test files referencing yield behavior
- Look for: YieldAccounting, YieldPresets, YieldDistribution tests

**Expected:** ~20-30 yield-specific tests moved to module test suite

**Verification:**
```bash
npm test  # Should compile, some tests still fail (expected)
```

---

### Phase 2.5: Update Core Tests (1 hour)

**Tasks:**
- [ ] Update test setup to use MockYieldModule
- [ ] Add yieldModule address to escrow creation calls
- [ ] Fix test failures related to missing yield logic
- [ ] Update assertions if yield test methods were removed

**Expected:** 50-60% of previous 71 failures should auto-fix because core logic is unchanged

**Key changes:**
- Instead of testing yield behavior in core tests, just verify module is called
- Add simple assertion: `mockYieldModule.lastCalled(workflowId) == true`

**Verification:**
```bash
npm test 2>&1 | grep "passing\|failing"
# Expected: Failing count drops from 71 to ~30-40
```

---

### Phase 2.6: Fix Remaining Test Failures (2 hours)

**Tasks:**
- [ ] Run test suite and analyze remaining failures
- [ ] Group failures by root cause
- [ ] Fix integration issues (module initialization, registry, etc.)
- [ ] Verify all core escrow logic tests pass
- [ ] Verify all module tests pass

**Expected failure patterns:**
1. Module not registered: Fix ModuleSnapshotRegistry setup
2. Module address mismatch: Fix snapshot creation
3. Module call format wrong: Update delegation code
4. Test setup issues: Update test fixtures

**Verification:**
```bash
npm test
# Should see: All core tests passing, module tests passing
# Remaining failures should be integration-only
```

---

### Phase 2.7: Final Verification & Cleanup (30 min)

**Tasks:**
- [ ] Run full test suite: `npm test`
- [ ] Verify bytecode sizes haven't regressed
- [ ] Check for unused imports/variables
- [ ] Run linter if available
- [ ] Verify git history is clean

**Verification:**
```bash
npm test  # Should pass
npx ts-node scripts/print-contract-sizes.ts  # Should show ~1,600 B savings
npm run lint  # Should pass (if linter exists)
git status  # Should show clean changes
```

---

### Phase 2.8: Documentation & PR Prep (30 min)

**Tasks:**
- [ ] Update README.md with yield module architecture
- [ ] Document how to add new yield modules (e.g., Morpho)
- [ ] Create PR template with testing checklist
- [ ] Add comments to IYieldModule and delegation methods
- [ ] Update CONTRIBUTING.md if needed

**Deliverable:** Clear documentation for future Morpho, Lido integrations

---

## Success Criteria

### Bytecode Targets
✅ BasicEscrowVault < 24 KB (currently 23,000 B)
✅ BasicEscrowableERC20 < 24 KB (currently 24,304 B)
✅ Core contracts reduced by ~1,600 B each

### Functionality Targets
✅ Yield still works (Aave integration working)
✅ All escrow features working (cancel, release, dispute, appeal, pause)
✅ Module can be optional (escrow works with yieldModule = 0x0)
✅ New modules can be added without changing core

### Test Targets
✅ All core escrow tests pass
✅ All module tests pass
✅ All integration tests pass (or minor fixes only)
✅ No regressions in existing functionality

### Code Quality Targets
✅ No compiler warnings
✅ All interfaces properly documented
✅ Module pattern follows IResolutionModule style
✅ Thin delegation with clear error handling

---

## Rollback Plan

If something breaks unexpectedly:

1. **Commit points to know:**
   - After Phase 1.2: AaveYieldModule extraction (before BaseEscrow changes)
   - After Phase 1.3: BaseEscrow refactoring (before testing)
   - After Phase 2.4: All tests compiled

2. **Rollback commands:**
   ```bash
   # Go back to last known good commit
   git reset --hard feature/externalize-yield-modules~1
   
   # Or cherry-pick specific fixes
   git revert <bad-commit>
   ```

3. **What to check if rolling back:**
   - Bytecode sizes back to pre-refactor
   - All 71 tests still failing (expected state)
   - BaseEscrow still has yield logic embedded

---

## Checkpoint Summary

After Session 1:
- Interface designed
- Yield logic extracted to module
- BaseEscrow has thin delegation
- Bytecode savings measured (~1,600 B)
- Code compiles without errors

After Session 2:
- All tests passing
- Module registry working
- Can add new yield modules
- Documentation complete
- Ready for production

---

## Time Breakdown

| Phase | Time | Status |
|-------|------|--------|
| 1.1: Interface | 30 min | ⏱️ Scheduled |
| 1.2: Extract Aave | 2 hrs | ⏱️ Scheduled |
| 1.3: Thin delegation | 1 hr | ⏱️ Scheduled |
| 1.4: Verify savings | 30 min | ⏱️ Scheduled |
| **Session 1 Total** | **4-5 hrs** | |
| 2.1: Update contracts | 30 min | ⏱️ Scheduled |
| 2.2: Module registry | 30 min | ⏱️ Scheduled |
| 2.3: Mock module | 1 hr | ⏱️ Scheduled |
| 2.4: Move tests | 1.5 hrs | ⏱️ Scheduled |
| 2.5: Fix tests | 1 hr | ⏱️ Scheduled |
| 2.6: Final fixes | 2 hrs | ⏱️ Scheduled |
| 2.7: Verification | 30 min | ⏱️ Scheduled |
| 2.8: Documentation | 30 min | ⏱️ Scheduled |
| **Session 2 Total** | **4-6 hrs** | |
| **GRAND TOTAL** | **8-11 hrs** | |

---

## Questions Before Starting

Before proceeding with implementation:

1. **Aave YieldModule structure**: Should it keep all current Aave-specific logic, or can we simplify?
2. **Module registry deployment**: Pre-deploy AaveYieldModule? Or lazy-load?
3. **Morpho timeline**: Should we design Morpho module now (non-implemented) or later?
4. **Breaking changes**: Are we OK with escrow creation changing to require yieldModule selection?

---

## Next Steps

1. **Review this plan** with stakeholder
2. **Approve architecture** from ARCHITECTURE_YIELD_MODULES.md
3. **Start Session 1** when ready (Phase 1.1: Interface design)
4. **Track progress** through checkpoints above
5. **Report results** after each session

Ready to proceed with Session 1?
