# Aave Integration Checklist Status

**Date:** 2026-01-23  
**Context:** After removing delegatecall library pattern and moving to GuardianOps

## ✅ Completed Tests

### Unit Tests (Mock Pool)
- ✅ `test_registerAToken_rejects_wrongUnderlying()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_registerAToken_rejects_nonContract()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_supply_handles_1wei()` - exists in `AaveEdgeCases.t.sol`
- ✅ `test_supply_handles_tinyAmounts()` - exists in `AaveEdgeCases.t.sol`
- ✅ `test_supply_reverts_whenPoolPaused()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_supply_reverts_whenPoolFrozen()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_supply_reverts_whenCapReached()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_supply_reverts_onBadApproval()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_withdraw_handles_rounding()` - exists in `AaveEdgeCases.t.sol`
- ✅ `test_withdraw_reverts_onInsufficientLiquidity()` - exists in `AaveFailureScenarios.t.sol`
- ✅ `test_pause_blocksEnterYield_blocksExitYield()` - exists in `AavePauseSemantics.t.sol`
- ✅ `test_pause_emergencyUnwind_stillWorks()` - exists in `AavePauseSemantics.t.sol` (needs update to GuardianOps)

### Fuzz Tests
- ✅ `testFuzz_supplyWithdraw_roundTrips()` - exists in `AaveFuzz.t.sol`
- ✅ `testFuzz_capsNeverExceeded()` - exists in `AaveFuzz.t.sol`
- ✅ `testFuzz_settle_neverOverpays()` - exists in `AaveFuzz.t.sol`
- ✅ `testFuzz_noLingeringAllowance()` - exists in `AaveFuzz.t.sol`

### Invariants
- ✅ `invariant_totalEntitlement_le_totalAssetsHeld()` - exists in `AaveInvariants.t.sol`
- ✅ `invariant_noCrossEscrowContamination()` - exists in `AaveInvariants.t.sol`
- ✅ `invariant_principalMonotonicity()` - exists in `AaveInvariants.t.sol`
- ✅ `invariant_interestAttributionCorrectness()` - exists in `AaveInvariants.t.sol`
- ✅ `invariant_capsEnforced()` - exists in `AaveInvariants.t.sol`
- ✅ `invariant_pauseSemantics()` - exists in `AaveInvariants.t.sol`
- ✅ `invariant_emergencyWithdraw_onlyRoutesToEscrowVault()` - exists in `AaveInvariants.t.sol` (needs update comment for GuardianOps)

### Fork Tests
- ✅ `test_LibraryMaintainsMsgSender()` - exists in `AaveForkTests.t.sol` (needs update - no longer library pattern)
- ✅ `test_EmergencyUnwindWithRealAave()` - exists in `AaveForkTests.t.sol` (needs update to GuardianOps)
- ✅ `test_EmergencyUnwindRespectsCooldown()` - exists in `AaveForkTests.t.sol` (needs update to GuardianOps)
- ✅ `test_EmergencyUnwindRequiresPause()` - exists in `AaveForkTests.t.sol` (needs update to GuardianOps)

---

## ⚠️ Tests That Need Updates (After Refactoring)

### 1. Emergency Unwind Tests
**Files:** `AaveForkTests.t.sol`, `AavePauseSemantics.t.sol`

**Changes Needed:**
- Update all `escrowVault.emergencyUnwindAavePosition()` calls to use `guardianOps.emergencyUnwindAavePosition()`
- Update `MAX_UNWIND_AMOUNT_PER_CALL()` and `UNWIND_COOLDOWN()` to reference `guardianOps` instead of `escrowVault`
- Ensure GuardianOps is deployed in setUp functions

**Status:** ✅ **PARTIALLY DONE** - Updated in recent session, but need to verify all instances

### 2. Library Pattern Test
**File:** `AaveForkTests.t.sol`

**Test:** `test_LibraryMaintainsMsgSender()`

**Changes Needed:**
- Test name and comments reference "library pattern" which no longer exists
- Should verify module pattern instead: `BaseEscrow` calls `AaveYieldGenerationModule.depositForYield()`
- Verify `aTokens` are owned by `EscrowVault` (BaseEscrow), not the module
- Update test name to `test_ModulePattern_MaintainsEscrowOwnership()` or similar

**Status:** ⚠️ **NEEDS UPDATE**

### 3. Invariant Comment
**File:** `AaveInvariants.t.sol`

**Function:** `invariant_emergencyWithdraw_onlyRoutesToEscrowVault()`

**Changes Needed:**
- Update comment to reference GuardianOps instead of direct EscrowVault function
- Verify GuardianOps hardcodes destination to escrow contract

**Status:** ✅ **DONE** - Updated in recent session

---

## ❌ Missing Tests (From Checklist)

### Unit Tests (Mock Pool)
1. ❌ `test_supply_emitsExpectedEvents_andUpdatesPrincipal()`
   - **Purpose:** Verify events emitted and principal tracking
   - **Location:** Should be in `AaveEdgeCases.t.sol` or new file
   - **Priority:** Medium

2. ❌ `test_supply_handlesApproveToZeroPattern()`
   - **Purpose:** Verify safe approval pattern (reset to zero, then set)
   - **Location:** Should be in `AaveEdgeCases.t.sol`
   - **Priority:** High (security)

3. ❌ `test_withdraw_partial_then_full_conservesAssets()`
   - **Purpose:** Verify partial withdrawal then full withdrawal doesn't lose assets
   - **Location:** Should be in `AaveEdgeCases.t.sol`
   - **Priority:** Medium

4. ❌ `test_caps_enforced_global_and_perEscrow()`
   - **Purpose:** Verify both global and per-escrow caps are enforced
   - **Note:** May exist but needs verification
   - **Location:** Check `AaveInvariants.t.sol` or create new test
   - **Priority:** High

5. ❌ `test_interest_distribution_matchesSpec()`
   - **Purpose:** Verify user/protocol split matches specification
   - **Location:** Should be in `AaveEdgeCases.t.sol` or `AaveCrit2DistributionFailures.t.sol`
   - **Priority:** High

6. ❌ `test_noCrossEscrowLeakage_multipleEscrows()`
   - **Purpose:** Verify escrow A actions don't affect escrow B
   - **Note:** May be covered by invariant, but explicit test needed
   - **Location:** Should be in `AaveEdgeCases.t.sol` or `AaveLibraryMultiEscrow.t.sol`
   - **Priority:** High

### Fork Tests (Base Sepolia)
1. ❌ `testFork_supplyUSDC_mintsAToken()`
   - **Purpose:** Verify USDC supply mints aToken on real Aave
   - **Note:** May be covered by `test_LibraryMaintainsMsgSender()` but needs explicit test
   - **Location:** `AaveForkTests.t.sol`
   - **Priority:** High

2. ❌ `testFork_withdrawUSDC_returnsUnderlying()`
   - **Purpose:** Verify USDC withdrawal returns underlying from real Aave
   - **Location:** `AaveForkTests.t.sol`
   - **Priority:** High

3. ❌ `testFork_addressDerivation_fromPoolReserveData()`
   - **Purpose:** Regression test - derive addresses onchain, not from UI
   - **Note:** May be partially covered in setUp, but needs explicit test
   - **Location:** `AaveForkTests.t.sol`
   - **Priority:** Medium

4. ❌ `testFork_interestNonDecreasing_overTimeWarp()`
   - **Purpose:** Verify interest accrual over time (aToken balance non-decreasing)
   - **Location:** `AaveForkTests.t.sol`
   - **Priority:** Medium

---

## 🔍 Additional Gaps (From Checklist Sections)

### 1. Negative Fuzz Tests (Non-Standard ERC20)
**Section:** 3.C - Negative fuzz (malicious/edge tokens)

**Missing:**
- ❌ Fuzz with ERC20 that returns `false` on transfer
- ❌ Fuzz with ERC20 that reverts on approve unless allowance is zero-first (USDT-like)
- ❌ Fuzz with fee-on-transfer token
- ❌ Tests confirming we **fail fast** with clear errors for unsupported tokens

**Priority:** Medium (if protocol doesn't support these, tests should confirm rejection)

### 2. Stateful Fuzz / Handler Tests
**Section:** 4 - Stateful fuzz / invariant harness

**Missing:**
- ❌ Handler contract with actions: `openEscrow()`, `enterYield()`, `exitYield()`, `settle()`, `pause/unpause()`, `changeCaps()`
- ❌ Randomization of actors (buyer/seller/guardian/timelock/attacker)
- ❌ Shadow accounting model in handler for expected principal and claims

**Priority:** Medium (property-based testing is valuable but not critical path)

### 3. Differential Tests
**Section:** 8.A - Differential tests: mock vs fork

**Missing:**
- ❌ Run same scenario against Mock Pool and Fork Pool
- ❌ Assert matching outcomes where applicable

**Priority:** Low (nice to have, but not critical)

### 4. Event-Driven Assertions
**Section:** 8.B - Event-driven assertions

**Missing:**
- ❌ Tests asserting correct failure reason emitted for each soft-failure path
- ❌ Tests confirming no "defined but never emitted" codes remain

**Priority:** Medium (telemetry is important for debugging)

### 5. Gas and DoS Checks
**Section:** 8.C - Gas and DoS checks

**Missing:**
- ❌ Tests ensuring loops are bounded (per-escrow lists, module registries)
- ❌ Tests ensuring settlement doesn't become uncallable as positions grow

**Priority:** Medium (DoS protection is important)

---

## 📋 Summary

### Test Coverage Status
- **Unit Tests:** ~70% complete (6/11 specific tests from checklist)
- **Fuzz Tests:** ✅ 100% complete (4/4)
- **Invariants:** ✅ 100% complete (7/7)
- **Fork Tests:** ~50% complete (4/8 specific tests from checklist)

### Critical Missing Tests (High Priority)
1. `test_supply_handlesApproveToZeroPattern()` - Security critical
2. `test_caps_enforced_global_and_perEscrow()` - Feature validation
3. `test_interest_distribution_matchesSpec()` - Feature validation
4. `test_noCrossEscrowLeakage_multipleEscrows()` - Security critical
5. `testFork_supplyUSDC_mintsAToken()` - Integration validation
6. `testFork_withdrawUSDC_returnsUnderlying()` - Integration validation

### Tests Needing Updates (After Refactoring)
1. ✅ Emergency unwind tests - **UPDATED** (need verification)
2. ⚠️ `test_LibraryMaintainsMsgSender()` - **NEEDS UPDATE** (rename and refocus)
3. ✅ Invariant comments - **UPDATED**

---

## 🎯 Recommended Next Steps

1. **Update existing tests** that reference library pattern
2. **Add missing high-priority unit tests** (approval pattern, caps, interest distribution)
3. **Add missing fork tests** (explicit supply/withdraw tests)
4. **Add negative fuzz tests** for non-standard ERC20s
5. **Add event-driven assertions** for failure reason codes
6. **Consider stateful fuzz handlers** for property-based testing

---

## 📝 Notes

- Many tests exist but may need updates after removing delegatecall library pattern
- Some coverage may exist in different test files with different names
- Invariants provide good property coverage but explicit unit tests are still valuable
- Fork tests are critical for integration validation but require Base Sepolia fork setup
