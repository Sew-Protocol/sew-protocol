# Aave Integration Testing - Development Plan

**Date:** 2026-01-21  
**Status:** 🚧 **IN PROGRESS**

---

## Overview

This plan addresses the gaps identified in `AAVE_INTEGRATION_CHECKLIST_GAP_ANALYSIS.md`, prioritizing critical items for mainnet readiness.

---

## Phase 1: Critical Tests (Week 1) - 🔴 MUST FIX

### 1.1 Coverage Report & Baseline
**Priority:** CRITICAL  
**Estimated Time:** 1 hour  
**Status:** ⏳ PENDING

- [ ] Run `forge coverage` for Aave modules
- [ ] Document current coverage percentages
- [ ] Identify specific uncovered lines/branches
- [ ] Set up coverage tracking in CI/CD

**Files:**
- `scripts/coverage-aave.sh` (new)

---

### 1.2 Fuzz Tests
**Priority:** CRITICAL  
**Estimated Time:** 4-6 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveFuzz.t.sol` (new)

**Tests to implement:**
- [ ] `testFuzz_supplyWithdraw_roundTrips(uint256 amount, uint8 steps)` - Round-trip deposit/withdraw with various amounts
- [ ] `testFuzz_capsNeverExceeded(uint256[] amounts)` - Multiple escrows, verify caps respected
- [ ] `testFuzz_settle_neverOverpays(uint256 escrowId, uint256 amount)` - Settlement never overpays principal + yield
- [ ] `testFuzz_noLingeringAllowance(uint256 amount)` - Approvals reset after operations
- [ ] `testFuzz_yieldCalculation_precision(uint256 principal, uint256 timeElapsed)` - Yield calculation precision across ranges
- [ ] `testFuzz_scaledShares_accounting(uint256 amount1, uint256 amount2)` - Multiple escrows, scaled shares independent

**Key assertions:**
- Balances conserved
- Caps respected
- State machine valid
- No unexpected approvals

---

### 1.3 Invariant Tests
**Priority:** CRITICAL  
**Estimated Time:** 4-6 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveInvariants.t.sol` (new)

**Invariants to implement:**
- [ ] `invariant_totalEntitlement_le_totalAssetsHeld()` - Total user-entitled value ≤ total assets held
- [ ] `invariant_noStuckFunds_whenNotPaused()` - Every escrow in terminal state has realizable claim path
- [ ] `invariant_noCrossEscrowContamination()` - Escrow A actions cannot change Escrow B balances
- [ ] `invariant_principalMonotonicity()` - Principal only changes on explicit deposit/withdraw
- [ ] `invariant_interestAttributionCorrectness()` - Interest allocated exactly per spec (user/protocol split)
- [ ] `invariant_capsEnforced()` - Total in yield per token ≤ global cap; per-escrow ≤ per-escrow cap
- [ ] `invariant_whenPaused_enterYieldBlocked_exitAllowed()` - Pause semantics
- [ ] `invariant_emergencyWithdraw_onlyRoutesToEscrowVault()` - Emergency unwind safety

**Implementation approach:**
- Use Foundry's `invariant_*` function pattern
- Create handler contract for stateful fuzz
- Track shadow accounting model

---

### 1.4 Failure Scenario Tests
**Priority:** CRITICAL  
**Estimated Time:** 3-4 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveFailureScenarios.t.sol` (new)

**Tests to implement:**
- [ ] `test_supply_reverts_whenPoolPaused()` - Pool paused state
- [ ] `test_supply_reverts_whenPoolFrozen()` - Pool frozen state
- [ ] `test_supply_reverts_whenCapReached()` - Global/per-escrow cap reached
- [ ] `test_supply_reverts_onBadApproval()` - Insufficient allowance
- [ ] `test_withdraw_reverts_onInsufficientLiquidity()` - Aave pool drained
- [ ] `test_withdraw_softFails_onPoolFailure()` - Soft-fail behavior (if applicable)
- [ ] `test_registerAToken_rejects_wrongUnderlying()` - Wrong underlying asset
- [ ] `test_registerAToken_rejects_nonContract()` - Non-contract address
- [ ] `test_registerAToken_rejects_wrongMarket()` - Wrong Aave market

**Mock requirements:**
- Enhance `MockAavePoolReverting.sol` with configurable revert modes
- Add pause/frozen/cap simulation

---

### 1.5 Pause Semantics Tests
**Priority:** CRITICAL  
**Estimated Time:** 2-3 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AavePauseSemantics.t.sol` (new)

**Tests to implement:**
- [ ] `test_pause_blocksEnterYield_allowsExitYield()` - Core pause semantics
- [ ] `test_pause_newEscrows_cannotEnterYield()` - New escrows blocked
- [ ] `test_pause_existingEscrows_canExitYield()` - Existing escrows can exit
- [ ] `test_unpause_allowsEnterYield()` - Unpause restores functionality
- [ ] `test_pause_emergencyUnwind_stillWorks()` - Emergency unwind works when paused

**Integration:**
- Extend existing `AaveIntegration.test.t.sol` or create new file
- Use `EscrowVault.pause()` / `unpause()`

---

### 1.6 Edge Case Tests
**Priority:** CRITICAL  
**Estimated Time:** 2-3 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveEdgeCases.t.sol` (new)

**Tests to implement:**
- [ ] `test_supply_handles_1wei()` - Minimum amount (1 wei)
- [ ] `test_supply_handles_tinyAmounts()` - Very small amounts (dust)
- [ ] `test_supply_handles_maxAmount()` - Maximum uint256 (if applicable)
- [ ] `test_withdraw_handles_rounding()` - Aave rounding edge cases
- [ ] `test_yieldCalculation_handles_zeroTime()` - Zero time elapsed
- [ ] `test_yieldCalculation_handles_veryLongTime()` - Very long time (years)
- [ ] `test_scaledShares_handles_incomeRay_change()` - Normalized income changes
- [ ] `test_multipleEscrows_sameToken_differentAmounts()` - Various amount combinations

---

## Phase 2: High Priority Tests (Week 2) - 🟡 SHOULD FIX

### 2.1 Registration Validation Tests
**Priority:** HIGH  
**Estimated Time:** 2 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveRegistrationValidation.t.sol` (new)

**Tests:**
- [ ] Wrong underlying asset rejection
- [ ] Non-contract address rejection
- [ ] Wrong Aave market rejection
- [ ] Duplicate registration handling
- [ ] Registration after module swap

---

### 2.2 Protocol Fee Accounting Tests
**Priority:** HIGH  
**Estimated Time:** 2-3 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveProtocolFeeAccounting.t.sol` (new)

**Tests:**
- [ ] Protocol fee doesn't leak into yield bucket
- [ ] Protocol fee calculated correctly on yield
- [ ] Protocol fee recipient receives funds
- [ ] Zero protocol fee works correctly
- [ ] Maximum protocol fee works correctly
- [ ] Protocol fee doesn't affect principal accounting

---

### 2.3 Caps Enforcement Tests
**Priority:** HIGH  
**Estimated Time:** 2-3 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveCapsEnforcement.t.sol` (new)

**Tests:**
- [ ] Global cap enforced across all escrows
- [ ] Per-escrow cap enforced per escrow
- [ ] Cap changes via governance
- [ ] Cap reached blocks new deposits
- [ ] Cap increase allows new deposits
- [ ] Multiple escrows respect global cap

---

### 2.4 Telemetry/Event Tests
**Priority:** HIGH  
**Estimated Time:** 2 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveTelemetry.t.sol` (new)

**Tests:**
- [ ] Correct failure reason emitted for each soft-failure path
- [ ] No "defined but never emitted" codes
- [ ] Event parameters match state changes
- [ ] Yield handling events emitted correctly

---

## Phase 3: Medium Priority Tests (Week 3) - 🟢 NICE TO HAVE

### 3.1 Stateful Fuzz Tests
**Priority:** MEDIUM  
**Estimated Time:** 4-6 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveStatefulFuzz.t.sol` (new)

**Handler contract with actions:**
- [ ] `openEscrow(amount)`
- [ ] `enterYield(escrowId, amount)` (implicit in createEscrow)
- [ ] `exitYield(escrowId, amount)` (via release/cancel)
- [ ] `settle(escrowId)`
- [ ] `pause/unpause`
- [ ] `changeCaps`

**Randomization:**
- Random actors (buyer/seller/guardian/timelock/attacker)
- Shadow accounting model in handler

---

### 3.2 Differential Tests (Mock vs Fork)
**Priority:** MEDIUM  
**Estimated Time:** 3-4 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveDifferential.t.sol` (new)

**Tests:**
- [ ] Same scenario: mock pool vs fork pool
- [ ] Assert matching outcomes where applicable
- [ ] Identify discrepancies (if any)

---

### 3.3 Re-entrancy Tests
**Priority:** MEDIUM  
**Estimated Time:** 2-3 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AaveReentrancy.t.sol` (new)

**Tests:**
- [ ] Malicious receiver contract on settlement paths
- [ ] Read-only reentrancy scenarios
- [ ] View-based checks don't authorize state changes

---

### 3.4 Poisoned aToken Tests
**Priority:** MEDIUM  
**Estimated Time:** 2 hours  
**Status:** ⏳ PENDING

**File:** `test/foundry/integration/AavePoisonedToken.t.sol` (new)

**Tests:**
- [ ] Receiving unexpected aToken dust doesn't break withdrawal
- [ ] Accounting doesn't assume "aToken balance == principal"
- [ ] Scaled shares approach handles unexpected balances

---

## Implementation Order

### Week 1 (Critical)
1. ✅ Coverage report & baseline
2. ✅ Fuzz tests (basic set)
3. ✅ Invariant tests (critical invariants)
4. ✅ Failure scenario tests
5. ✅ Pause semantics tests
6. ✅ Edge case tests

### Week 2 (High Priority)
1. Registration validation tests
2. Protocol fee accounting tests
3. Caps enforcement tests
4. Telemetry/event tests

### Week 3 (Medium Priority)
1. Stateful fuzz tests
2. Differential tests
3. Re-entrancy tests
4. Poisoned aToken tests

---

## Success Criteria

### Phase 1 (Critical) - ✅ COMPLETE
- [ ] Coverage report shows 90%+ lines, 80%+ branches for Aave modules
- [ ] All critical fuzz tests passing
- [ ] All critical invariants passing
- [ ] All failure scenarios tested
- [ ] Pause semantics validated
- [ ] Edge cases covered

### Phase 2 (High Priority) - ⏳ PENDING
- [ ] Registration validation complete
- [ ] Protocol fee accounting validated
- [ ] Caps enforcement validated
- [ ] Telemetry validated

### Phase 3 (Medium Priority) - ⏳ PENDING
- [ ] Stateful fuzz harness operational
- [ ] Differential tests passing
- [ ] Re-entrancy tests passing
- [ ] Poisoned aToken tests passing

---

## Notes

- **Partial Withdrawals:** Excluded per user requirement ("partial withdraws are not supported")
- **Scaled Shares:** Implementation uses Aave's scaled shares mechanism - tests should validate this explicitly
- **Mock Enhancements:** May need to enhance `MockAavePoolReverting.sol` for failure scenario tests
- **Fork Tests:** Some tests may require fork environment - document which ones

---

## Progress Tracking

**Last Updated:** 2026-01-21  
**Current Phase:** Phase 1 (Critical)  
**Status:** 🚧 IN PROGRESS
