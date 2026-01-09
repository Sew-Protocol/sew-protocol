# Testing Guidelines Adherence Plan

**Date:** 2026-01-06  
**Status:** Ready for Execution  
**Estimated Time:** 25-35 hours over 4 weeks

---

## Quick Reference

**Current State:** ✅ Strong foundation (420 passing tests)  
**Critical Gaps:** 3 items (ERC20 edge cases, DoS vectors, coverage docs)  
**Timeline:** 4 weeks to full adherence

---

## Phase 1: Critical Gaps (Week 1-2) - 18-26 hours

### Task 1.1: ERC20 Edge Case Tests ⚠️ **HIGH PRIORITY**
**Time:** 8-12 hours  
**File:** `test/foundry/token/ERC20EdgeCases.t.sol`

**Test Cases:**
1. Fee-on-transfer tokens
   - Test with mock fee-on-transfer token
   - Verify explicit rejection or proper handling
   - Document policy decision

2. Rebasing tokens
   - Test with mock rebasing token
   - Verify explicit rejection or proper handling
   - Document policy decision

3. Non-standard return values
   - Test tokens that don't return `bool` from `transfer()`
   - Verify `SafeERC20` handles correctly
   - Test edge cases

4. ERC777 hooks (if applicable)
   - Test interaction with ERC777 tokens
   - Verify no unexpected behavior

5. Decimals assumptions
   - Test with non-18 decimal tokens (e.g., USDC with 6 decimals)
   - Verify no hardcoded decimal assumptions

**Acceptance Criteria:**
- [ ] All edge cases tested
- [ ] Explicit policy documented in `SECURITY_MODEL.md`
- [ ] Tests pass/fail as expected based on policy
- [ ] Policy clearly states supported vs rejected token types

---

### Task 1.2: DoS Vector Tests ⚠️ **HIGH PRIORITY**
**Time:** 6-8 hours  
**File:** `test/foundry/security/DoSVectors.t.sol`

**Test Cases:**
1. Large attachment arrays
   - Test max attachments limit enforcement
   - Test batch operations with max items
   - Verify gas costs don't grow unbounded

2. Iteration limits
   - Test `automateTimedActions` with large ranges
   - Verify iteration limits enforced
   - Test gas consumption

3. Griefing attacks
   - Test malicious patterns (e.g., many small escrows)
   - Verify griefing prevention mechanisms
   - Test rate limiting (if any)

4. Revert-on-transfer patterns
   - Test ERC20 tokens that revert on transfer
   - Verify graceful handling
   - Test refund paths

5. Gas griefing
   - Test operations that could consume excessive gas
   - Verify gas limits enforced
   - Test worst-case scenarios

**Acceptance Criteria:**
- [ ] All DoS vectors identified and tested
- [ ] Limits enforced correctly
- [ ] Griefing patterns fail as expected
- [ ] Gas costs documented for worst-case scenarios

---

### Task 1.3: Coverage Documentation ⚠️ **HIGH PRIORITY**
**Time:** 4-6 hours  
**Files:** `docs/TESTING.md`, `docs/COVERAGE_MAP.md`

**TESTING.md (Already Created):**
- ✅ What is tested in Forge vs Hardhat
- ✅ How to run each suite
- ✅ Known limitations
- ✅ Test statistics

**COVERAGE_MAP.md (To Create):**
1. Per-contract "tested-by" map
   ```
   BaseEscrow.sol:
     - State machine: priority2_state_machine.t.sol
     - Reentrancy: priority3_reentrancy.t.sol
     - Governance: governance/01_AccessControl.test.ts
     - ...
   ```

2. Critical path coverage
   - Escrow lifecycle: create → fund → release/cancel → dispute → resolve → timeout
   - Access control: who can call what, and when
   - Upgrade/module swap: what can change, who can change it, safety rails

3. Branch/edge-case matrix
   - State transitions (valid and invalid)
   - Access control scenarios
   - Error conditions

**Acceptance Criteria:**
- [ ] TESTING.md complete (✅ Done)
- [ ] COVERAGE_MAP.md created with all contracts mapped
- [ ] Critical paths documented
- [ ] Branch/edge-case matrix complete
- [ ] Easy to understand for auditors

---

## Phase 2: Medium Priority (Week 3) - 6-10 hours

### Task 2.1: Comprehensive Event Validation
**Time:** 4-6 hours  
**File:** `test/hardhat/integration/EventValidation.test.ts`

**Test Cases:**
1. All user-visible state changes emit events
   - Escrow creation → `EscrowTransferCreated`
   - State transitions → `EscrowStateChanged`
   - Disputes → `DisputeOpened`
   - Resolutions → `EscrowTransferResolved`
   - etc.

2. Indexed topics match off-chain expectations
   - Verify indexed parameters are correct
   - Test event parsing by off-chain consumers

3. Event parameters correct
   - Verify all event parameters match actual state
   - Test event emission timing

4. Event ordering correct
   - Verify events emitted in correct order
   - Test multiple events in single transaction

**Acceptance Criteria:**
- [ ] All events validated
- [ ] Indexed topics verified
- [ ] Event consumers can parse correctly
- [ ] Event ordering documented

---

### Task 2.2: Test Distribution Review
**Time:** 2-4 hours

**Actions:**
1. Review all test files for framework appropriateness
2. Identify tests in wrong framework:
   - Contract logic tests in Hardhat → move to Forge
   - Integration tests in Forge → move to Hardhat (if any)
3. Eliminate duplication where appropriate
4. Document test distribution decisions

**Acceptance Criteria:**
- [ ] Tests in correct framework
- [ ] Minimal duplication
- [ ] Clear separation of concerns
- [ ] Distribution documented

---

## Phase 3: Documentation & Reporting (Week 4) - 3-5 hours

### Task 3.1: Combined Coverage Reporting Script
**Time:** 2-3 hours  
**File:** `scripts/generate-coverage-report.ts`

**Functionality:**
1. Run Hardhat coverage
2. Attempt Foundry coverage (with fallback if it fails)
3. Generate combined report
4. Create coverage map from test files
5. Output summary to console and file

**Acceptance Criteria:**
- [ ] Script generates useful coverage report
- [ ] Handles Forge coverage failures gracefully
- [ ] Produces coverage map
- [ ] Outputs summary statistics

---

### Task 3.2: Update CI/CD for Coverage Reporting
**Time:** 1-2 hours  
**File:** `.github/workflows/ci.yml`

**Actions:**
1. Add coverage job that runs reporting script
2. Upload coverage artifacts
3. Display coverage summary in CI output
4. Comment coverage on PRs (optional)

**Acceptance Criteria:**
- [ ] CI generates coverage reports
- [ ] Coverage visible in PRs
- [ ] Artifacts available for download
- [ ] Summary displayed in CI output

---

## Execution Checklist

### Week 1
- [ ] Start ERC20 Edge Case Tests
- [ ] Create mock tokens for edge cases
- [ ] Document policy decisions

### Week 2
- [ ] Complete ERC20 Edge Case Tests
- [ ] Start DoS Vector Tests
- [ ] Create COVERAGE_MAP.md
- [ ] Complete Coverage Documentation

### Week 3
- [ ] Complete DoS Vector Tests
- [ ] Create Event Validation test suite
- [ ] Review and optimize test distribution
- [ ] Document test distribution decisions

### Week 4
- [ ] Create coverage reporting script
- [ ] Update CI/CD for coverage
- [ ] Final review and documentation updates

---

## Success Criteria

### Pre-Audit Gate:
- ✅ All critical gaps addressed
- ✅ Coverage documentation complete
- ✅ ERC20 edge cases tested and documented
- ✅ DoS vectors tested
- ✅ Event validation comprehensive
- ✅ Test distribution optimized

### Audit Readiness:
- ✅ All checklist items (A-E) complete
- ✅ Coverage map available
- ✅ TESTING.md complete
- ✅ All tests passing
- ✅ CI/CD running all checks
- ✅ Documentation clear for auditors

---

## Risk Mitigation

### If ERC20 Edge Cases Take Longer:
- Prioritize fee-on-transfer and rebasing tokens (highest risk)
- Document explicit rejection policy if handling is complex
- Defer ERC777 and decimals to post-audit if needed

### If DoS Tests Reveal Issues:
- Fix issues immediately (security priority)
- Document mitigations
- Add additional tests for fixes

### If Coverage Documentation Takes Longer:
- Start with critical contracts (BaseEscrow, EscrowVault, EscrowableERC20)
- Expand to other contracts incrementally
- Use automated tools where possible

---

## Timeline Summary

| Phase | Tasks | Time | Priority |
|-------|-------|------|----------|
| 1 | ERC20 Edge Cases, DoS Vectors, Coverage Docs | 18-26h | HIGH |
| 2 | Event Validation, Test Distribution | 6-10h | MEDIUM |
| 3 | Coverage Reporting, CI/CD Updates | 3-5h | LOW |
| **Total** | | **27-41h** | |

---

**Status:** Plan ready for execution. Begin with Phase 1, Task 1.1 (ERC20 Edge Cases).



