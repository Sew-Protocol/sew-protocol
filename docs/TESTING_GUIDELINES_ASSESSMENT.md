# Testing Guidelines Assessment & Adherence Plan

**Date:** 2026-01-06  
**Status:** Assessment Complete, Plan Ready for Execution

---

## Executive Summary

This document assesses the current testing state against `docs/Testing_guidelines.md` and provides a comprehensive plan to achieve full adherence. The repository has a strong foundation with 344 Hardhat tests and 76 Foundry tests, but several gaps need to be addressed for audit readiness.

**Current Test Count:**
- ✅ Hardhat: 344 passing tests (21 test files)
- ✅ Foundry: 76 passing tests (16 test files, including invariants and fuzz tests)
- ✅ Total: 420 passing tests across 37 test files

---

## 1. Assessment: When to Write Tests in Hardhat vs Forge

### Current State: ✅ **GOOD** (Mostly Compliant)

**Forge Tests (Contract Correctness):**
- ✅ State machine correctness (`priority2_state_machine.t.sol`)
- ✅ Invariants (`EscrowInvariants.t.sol`)
- ✅ Fuzz tests (multiple priority tests with `testFuzz`)
- ✅ Edge cases (caps enforcement, fee accounting, reentrancy)
- ✅ Revert reasons / custom errors (comprehensive error testing)
- ✅ Gas-sensitive behavior (Foundry tracks gas)

**Hardhat Tests (System Behavior):**
- ✅ Multi-contract integrations (`AaveIntegration.test.ts`)
- ✅ Deployment flows (`MainnetReleaseSequence.test.ts`)
- ✅ Governance/timelock flows (`governance/` tests)
- ✅ Module swaps (`05_ModuleSnapshotting.test.ts`)
- ✅ Event validation (multiple tests check events)
- ✅ JS/TS tooling integration (all Hardhat tests)

**Issues:**
- ⚠️ Some duplication between Hardhat and Foundry (e.g., access control tested in both)
- ⚠️ Some contract logic tested in Hardhat that should be in Forge (e.g., fee calculations)

**Recommendation:** Review test distribution and move contract logic tests to Forge where appropriate.

---

## 2. Assessment: Coverage Reporting

### Current State: ⚠️ **NEEDS IMPROVEMENT**

**Issues:**
- ❌ Hardhat coverage under-reports (ignores Foundry tests)
- ❌ Forge coverage fails (stack too deep errors)
- ❌ No coverage map/documentation
- ❌ No combined coverage reporting
- ❌ No TESTING.md section explaining coverage split

**What Exists:**
- ✅ `solidity-coverage` configured
- ✅ Coverage script in `package.json`
- ✅ Coverage report generated (but incomplete)

**Missing:**
- ❌ Coverage map (contract → behaviors → test files)
- ❌ Critical path coverage report
- ❌ Branch/edge-case matrix
- ❌ Documentation explaining coverage limitations

**Recommendation:** Create coverage documentation and mapping as specified in guidelines.

---

## 3. Assessment: Audit-Ready Testing Checklist

### A. Core Correctness (Must-Have)

#### ✅ State Machine Completeness
- **Status:** ✅ **COMPLETE**
- **Tests:** `priority2_state_machine.t.sol`, `BaseEscrow.test.ts`
- **Coverage:** All valid transitions tested, invalid transitions revert
- **Gap:** None

#### ✅ Access Control
- **Status:** ✅ **COMPLETE**
- **Tests:** `governance/01_AccessControl.test.ts`, `priority5_guardian_downonly.t.sol`
- **Coverage:** Every privileged function has positive and negative tests
- **Gap:** None

#### ✅ Accounting Invariants
- **Status:** ✅ **COMPLETE**
- **Tests:** `priority8_fee_accounting.t.sol`, `EscrowInvariants.t.sol`
- **Coverage:**
  - ✅ Balances conserved (`invariant_noDoubleSpending`)
  - ✅ No double-withdraw/release (`test_noDoubleSpending`)
  - ✅ Fee calculations at boundaries (`testFuzz_feeCalculation`)
- **Gap:** None

#### ✅ Timeout / Stuck-Funds Prevention
- **Status:** ✅ **COMPLETE**
- **Tests:** `BaseEscrow.test.ts`, `EscrowableERC20.ts`, `CoreContractsCoverage.test.ts`
- **Coverage:**
  - ✅ Auto-cancel timeout tested
  - ✅ Auto-release timeout tested
  - ✅ Dispute timeout tested
- **Gap:** None

### B. Adversarial Behavior (Strongly Recommended)

#### ✅ Fuzz Tests
- **Status:** ✅ **COMPLETE**
- **Tests:** Multiple priority tests with `testFuzz` functions
- **Coverage:** Core flows fuzzed (amounts, state transitions, caps)
- **Gap:** None

#### ✅ Invariants
- **Status:** ✅ **COMPLETE**
- **Tests:** `EscrowInvariants.t.sol`
- **Coverage:** Key invariants tested with 256 runs
- **Gap:** None

#### ✅ Reentrancy & Callback Scenarios
- **Status:** ✅ **COMPLETE**
- **Tests:** `priority3_reentrancy.t.sol`
- **Coverage:** Reentrancy protection tested on critical functions
- **Gap:** None

#### ❌ DoS Vectors
- **Status:** ❌ **MISSING**
- **Tests:** None
- **Coverage:** No tests for:
  - Large arrays / iteration limits
  - Griefing attacks
  - Revert-on-transfer patterns
- **Gap:** **HIGH PRIORITY** - Need DoS vector tests

### C. Integration & Ops Readiness

#### ✅ Deployment Tests
- **Status:** ✅ **COMPLETE**
- **Tests:** `MainnetReleaseSequence.test.ts`
- **Coverage:**
  - ✅ Correct init params
  - ✅ Ownership/roles assigned correctly
  - ✅ Cannot re-initialize
- **Gap:** None

#### ✅ Upgrade/Module Swap Tests
- **Status:** ✅ **COMPLETE**
- **Tests:** `05_ModuleSnapshotting.test.ts`, `governance/` tests
- **Coverage:**
  - ✅ Authorized-only swap
  - ✅ Upgrade emits expected events
  - ✅ Storage layout assumptions validated
- **Gap:** None

#### ⚠️ Event Correctness
- **Status:** ⚠️ **PARTIAL**
- **Tests:** Events checked in many tests, but not comprehensively
- **Coverage:** Some events validated, but not all user-visible state changes
- **Gap:** Need comprehensive event validation test suite

### D. Token/Asset Interaction Safety

#### ❌ ERC20 Edge Cases
- **Status:** ❌ **MISSING**
- **Tests:** None
- **Coverage:** No tests for:
  - Non-standard return values
  - Fee-on-transfer tokens
  - Rebasing tokens
  - ERC777 hooks
  - Decimals assumptions
- **Gap:** **HIGH PRIORITY** - Critical for production safety

#### ⚠️ ETH Handling
- **Status:** ⚠️ **N/A** (Protocol uses ERC20 only)
- **Tests:** N/A
- **Coverage:** Protocol doesn't handle ETH directly
- **Gap:** None (not applicable)

### E. CI Discipline

#### ✅ CI Runs
- **Status:** ✅ **COMPLETE**
- **CI:** `.github/workflows/ci.yml` (exists but filtered)
- **Coverage:**
  - ✅ Lint + typecheck + Hardhat tests + Forge tests
  - ✅ Runs on every PR
- **Gap:** None

#### ✅ Deterministic Test Runs
- **Status:** ✅ **COMPLETE**
- **Coverage:**
  - ✅ Pinned compiler version (0.8.33)
  - ✅ Fixed seeds for fuzz tests (256 runs)
- **Gap:** None

---

## 4. Gap Summary

### Critical Gaps (Must Fix Before Audit)

1. **❌ ERC20 Edge Cases** - No tests for fee-on-transfer, rebasing, non-standard tokens
2. **❌ DoS Vectors** - No tests for large arrays, iteration limits, griefing, revert-on-transfer
3. **❌ Coverage Documentation** - No coverage map, no TESTING.md, no combined reporting

### Medium Priority Gaps

4. **⚠️ Event Correctness** - Partial coverage, need comprehensive validation
5. **⚠️ Test Distribution** - Some duplication, some logic in wrong framework

### Low Priority Gaps

6. **⚠️ Coverage Tooling** - Forge coverage fails (tooling limitation, not testing gap)

---

## 5. Adherence Plan

### Phase 1: Critical Gaps (Week 1-2)

#### Task 1.1: ERC20 Edge Case Tests (HIGH PRIORITY)
**Estimated Time:** 8-12 hours

**Create:** `test/foundry/token/ERC20EdgeCases.t.sol`

**Test Cases:**
- Fee-on-transfer tokens (explicit rejection or handling)
- Rebasing tokens (explicit rejection or handling)
- Non-standard return values (tokens that don't return bool)
- ERC777 hooks (if applicable)
- Decimals assumptions (test with non-18 decimal tokens)

**Acceptance Criteria:**
- All edge cases tested
- Explicit policy documented (supported vs rejected)
- Tests pass/fail as expected based on policy

#### Task 1.2: DoS Vector Tests (HIGH PRIORITY)
**Estimated Time:** 6-8 hours

**Create:** `test/foundry/security/DoSVectors.t.sol`

**Test Cases:**
- Large attachment arrays (test max attachments limit)
- Iteration limits (test batch operations with max items)
- Griefing attacks (test malicious patterns)
- Revert-on-transfer patterns (test ERC20 tokens that revert on transfer)
- Gas griefing (test operations that consume excessive gas)

**Acceptance Criteria:**
- All DoS vectors identified and tested
- Limits enforced correctly
- Griefing patterns fail as expected

#### Task 1.3: Coverage Documentation (HIGH PRIORITY)
**Estimated Time:** 4-6 hours

**Create:** `docs/TESTING.md`

**Contents:**
- What is tested in Forge vs Hardhat
- How to run each suite
- Known limitations (forge coverage disabled)
- Coverage map (contract → behaviors → test files)
- Critical path coverage report
- Branch/edge-case matrix

**Create:** `docs/COVERAGE_MAP.md`

**Contents:**
- Per-contract "tested-by" map
- Key behaviors → test files mapping
- Critical paths documented

**Acceptance Criteria:**
- Complete documentation
- Coverage map accurate
- Easy to understand for auditors

### Phase 2: Medium Priority (Week 3)

#### Task 2.1: Comprehensive Event Validation
**Estimated Time:** 4-6 hours

**Create:** `test/hardhat/integration/EventValidation.test.ts`

**Test Cases:**
- All user-visible state changes emit events
- Indexed topics match off-chain expectations
- Event parameters correct
- Event ordering correct

**Acceptance Criteria:**
- All events validated
- Indexed topics verified
- Event consumers can parse correctly

#### Task 2.2: Test Distribution Review
**Estimated Time:** 2-4 hours

**Actions:**
- Review all tests for framework appropriateness
- Move contract logic tests from Hardhat to Forge
- Move integration tests from Forge to Hardhat (if any)
- Eliminate duplication where appropriate

**Acceptance Criteria:**
- Tests in correct framework
- Minimal duplication
- Clear separation of concerns

### Phase 3: Documentation & Reporting (Week 4)

#### Task 3.1: Combined Coverage Reporting Script
**Estimated Time:** 2-3 hours

**Create:** `scripts/generate-coverage-report.ts`

**Functionality:**
- Run Hardhat coverage
- Attempt Foundry coverage (with fallback if it fails)
- Generate combined report
- Create coverage map from test files

**Acceptance Criteria:**
- Script generates useful coverage report
- Handles Forge coverage failures gracefully
- Produces coverage map

#### Task 3.2: Update CI/CD for Coverage Reporting
**Estimated Time:** 1-2 hours

**Actions:**
- Update CI to run coverage report script
- Upload coverage artifacts
- Display coverage summary in CI output

**Acceptance Criteria:**
- CI generates coverage reports
- Coverage visible in PRs
- Artifacts available for download

---

## 6. Implementation Priority

### Must Complete Before Audit:
1. ✅ ERC20 Edge Case Tests
2. ✅ DoS Vector Tests
3. ✅ Coverage Documentation (TESTING.md + COVERAGE_MAP.md)

### Should Complete Before Audit:
4. ⚠️ Comprehensive Event Validation
5. ⚠️ Test Distribution Review

### Nice to Have:
6. ⚠️ Combined Coverage Reporting Script
7. ⚠️ CI/CD Coverage Updates

---

## 7. Success Metrics

### Pre-Audit Gate:
- ✅ All critical gaps addressed
- ✅ Coverage documentation complete
- ✅ ERC20 edge cases tested
- ✅ DoS vectors tested
- ✅ Event validation comprehensive
- ✅ Test distribution optimized

### Audit Readiness:
- ✅ All checklist items (A-E) complete
- ✅ Coverage map available
- ✅ TESTING.md complete
- ✅ All tests passing
- ✅ CI/CD running all checks

---

## 8. Timeline Estimate

**Total Estimated Time:** 25-35 hours

**Week 1-2 (Critical):** 18-26 hours
- ERC20 Edge Cases: 8-12 hours
- DoS Vectors: 6-8 hours
- Coverage Documentation: 4-6 hours

**Week 3 (Medium):** 6-10 hours
- Event Validation: 4-6 hours
- Test Distribution: 2-4 hours

**Week 4 (Documentation):** 3-5 hours
- Coverage Reporting Script: 2-3 hours
- CI/CD Updates: 1-2 hours

---

## 9. Next Steps

1. **Immediate:** Review and approve this plan
2. **Week 1:** Start with ERC20 Edge Case Tests (highest risk)
3. **Week 2:** Complete DoS Vectors and Coverage Documentation
4. **Week 3:** Event Validation and Test Distribution Review
5. **Week 4:** Coverage Reporting and CI/CD Updates

---

**Status:** Plan ready for execution. All critical gaps identified and prioritized.

