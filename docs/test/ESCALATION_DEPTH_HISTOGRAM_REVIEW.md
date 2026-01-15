# Escalation Depth Histogram Review & Test Strategy

**Date:** 2026-01-09  
**Component:** `ResolverIncentiveModuleV2.escalationDepthHistogram`  
**Status:** Review Complete - Test Strategy Required

---

## Overview

The `escalationDepthHistogram` is a mapping that tracks the count of appeal bonds recorded at each escalation round. It provides observability metrics about how disputes escalate through the resolution system.

---

## Implementation Review

### Code Location

**Contract:** `ResolverIncentiveModuleV2.sol`  
**Line:** 51 (declaration), 171 (increment), 410-420 (getter)

### State Variable

```solidity
// Escalation depth histogram: round => count
mapping(uint8 => uint256) public escalationDepthHistogram;
```

### Update Logic

**Where it's incremented:**
- `recordAppealBond()` function (line 171)
- Incremented when a bond is successfully recorded: `escalationDepthHistogram[round]++`
- Only incremented once per bond recording (bonds cannot be recorded twice)

**When `recordAppealBond()` is called:**
- Called from `BaseEscrow` during dispute escalation (lines 883, 900)
- Called when a user escalates a dispute by posting an appeal bond
- The `round` parameter represents the round being escalated **TO**

### Round Semantics

- **Round 0:** Initial resolver round (no appeal bond - disputes start here)
- **Round 1:** Escalation from round 0 → 1 (first appeal)
- **Round 2:** Escalation from round 1 → 2 (second appeal, final)

**Key Understanding:**
- `escalationDepthHistogram[round]` tracks the number of disputes that reached that round
- Round 0 should always be 0 (disputes don't start with bonds)
- Round 1 counts disputes that were escalated from round 0
- Round 2 counts disputes that were escalated from round 1

### Getter Function

```solidity
function getEscalationDepthHistogram()
    external
    view
    returns (uint256 round0, uint256 round1, uint256 round2)
{
    return (
        escalationDepthHistogram[0],
        escalationDepthHistogram[1],
        escalationDepthHistogram[2]
    );
}
```

---

## Current Test Coverage

### Existing Tests

**Invariant Test (DRv2Invariants.t.sol:182-205):**
- `invariant_EscalationHistogramAccuracy()` - Verifies histogram matches actual bonds
- Checks that histogram counts match or exceed actual bond counts
- Verifies round 0 is always 0

### Issues Found in Review

1. **Limited Test Coverage:**
   - Only invariant test exists
   - No unit tests for direct histogram updates
   - No edge case testing
   - No reentrancy testing

2. **Invariant Test Limitations:**
   - Only scans first 1000 workflow IDs (arbitrary limit)
   - May miss bonds in higher workflow IDs
   - Doesn't test increment accuracy in isolation

3. **Potential Issues:**
   - No check that histogram is never decremented
   - No test for multiple bonds in same round (should not happen)
   - No test for round validation (round must be 1 or 2)

---

## Test Strategy

### 1. Unit Tests: Direct Histogram Updates

#### Test File: `test/foundry/decentralized-resolution-module/EscalationDepthHistogram.unit.t.sol`

**Purpose:** Test histogram updates in isolation, independent of full escalation flow

**Test Cases:**

1. **`test_histogramIncrementOnRecordBond_Round1`**
   - Setup: Fresh incentive module
   - Action: Record bond for workflowId=1, round=1
   - Verify:
     - `escalationDepthHistogram[1] == 1`
     - `escalationDepthHistogram[0] == 0`
     - `escalationDepthHistogram[2] == 0`
     - `getEscalationDepthHistogram()` returns (0, 1, 0)

2. **`test_histogramIncrementOnRecordBond_Round2`**
   - Setup: Fresh incentive module
   - Action: Record bond for workflowId=1, round=2
   - Verify:
     - `escalationDepthHistogram[2] == 1`
     - `escalationDepthHistogram[0] == 0`
     - `escalationDepthHistogram[1] == 0`
     - `getEscalationDepthHistogram()` returns (0, 0, 1)

3. **`test_histogramIncrementMultipleBonds_SameRound`**
   - Setup: Record multiple bonds at same round
   - Action: Record bonds for workflowIds 1, 2, 3, all at round=1
   - Verify:
     - `escalationDepthHistogram[1] == 3`
     - Each bond is recorded correctly

4. **`test_histogramIncrementMultipleBonds_DifferentRounds`**
   - Setup: Record bonds at different rounds
   - Action:
     - Record bond at round=1 (workflowId=1)
     - Record bond at round=2 (workflowId=2)
     - Record bond at round=1 (workflowId=3)
   - Verify:
     - `escalationDepthHistogram[1] == 2`
     - `escalationDepthHistogram[2] == 1`
     - `escalationDepthHistogram[0] == 0`

5. **`test_histogramNeverIncrementsRound0`**
   - Setup: Attempt to record bond at round=0
   - Action: Call `recordAppealBond()` with round=0
   - Verify: Transaction reverts (round must be > 0)
   - Verify: `escalationDepthHistogram[0]` remains 0

6. **`test_histogramRound3Rejected`**
   - Setup: Attempt to record bond at round=3
   - Action: Call `recordAppealBond()` with round=3
   - Verify: Transaction reverts (round must be <= 2)
   - Verify: Histogram unchanged

7. **`test_histogramPersistsAcrossDistributions`**
   - Setup: Record bond, then distribute it
   - Action:
     - Record bond at round=1
     - Verify histogram[1] == 1
     - Distribute bond (refund)
     - Verify histogram[1] == 1 (unchanged - histogram is cumulative)
   - Verify: Histogram never decreases

8. **`test_histogramGetterReturnsCorrectValues`**
   - Setup: Record bonds at various rounds
   - Action: Record bonds, then call getter
   - Verify:
     - Direct mapping access matches getter return values
     - All three rounds returned correctly
     - Round 0 always returns 0

### 2. Integration Tests: Full Escalation Flow

#### Test File: `test/foundry/decentralized-resolution-module/EscalationDepthHistogram.integration.t.sol`

**Purpose:** Test histogram updates during actual dispute escalation flows

**Test Cases:**

1. **`test_histogramUpdatesOnEscalation_Round0To1`**
   - Setup: Create escrow, raise dispute, get to round 0 decision
   - Action: Escalate dispute (round 0 → 1)
   - Verify:
     - Bond recorded at round=1
     - `escalationDepthHistogram[1]` incremented
     - `escalationDepthHistogram[0]` remains 0

2. **`test_histogramUpdatesOnEscalation_Round1To2`**
   - Setup: Dispute already at round 1 with decision
   - Action: Escalate dispute (round 1 → 2)
   - Verify:
     - Bond recorded at round=2
     - `escalationDepthHistogram[2]` incremented
     - `escalationDepthHistogram[1]` unchanged (already incremented)
     - `escalationDepthHistogram[0]` remains 0

3. **`test_histogramAccumulatesAcrossMultipleDisputes`**
   - Setup: Create multiple disputes
   - Action:
     - Dispute 1: Escalate to round 1 only
     - Dispute 2: Escalate to round 1, then to round 2
     - Dispute 3: Escalate to round 1 only
   - Verify:
     - `escalationDepthHistogram[1] == 3` (all three escalated to round 1)
     - `escalationDepthHistogram[2] == 1` (only dispute 2 reached round 2)
     - `escalationDepthHistogram[0] == 0`

4. **`test_histogramNoUpdateOnFailedBondRecording`**
   - Setup: Attempt to record bond with invalid parameters
   - Action: Try to record bond with:
     - Zero amount (should revert)
     - Invalid round (should revert)
     - Duplicate bond (should revert)
   - Verify: Histogram unchanged after each failed attempt

5. **`test_histogramMatchesActualBondCount`**
   - Setup: Record multiple bonds
   - Action: Manually count bonds vs histogram
   - Verify:
     - Scan all workflow IDs with bonds
     - Count bonds at round 1 vs histogram[1]
     - Count bonds at round 2 vs histogram[2]
     - Values match exactly

### 3. Invariant Tests: Long-Running Accuracy

#### Test File: `test/foundry/decentralized-resolution-module/EscalationDepthHistogram.invariants.t.sol`

**Purpose:** Fuzz and invariant tests to ensure histogram remains accurate

**Test Cases:**

1. **`invariant_histogramMonotonicity`**
   - Invariant: Histogram values never decrease
   - Action: Any sequence of operations
   - Verify: After each operation, histogram values are >= previous values

2. **`invariant_histogramRound0AlwaysZero`**
   - Invariant: Round 0 always equals 0
   - Action: Any sequence of operations
   - Verify: After each operation, `escalationDepthHistogram[0] == 0`

3. **`invariant_histogramMatchesActualBonds`**
   - Invariant: Histogram counts match actual bonds (enhanced version)
   - Action: Fuzz test with random bond recordings
   - Verify:
     - Scan all possible workflow IDs (or use bounded search)
     - Count actual bonds per round
     - Histogram matches exactly

4. **`testFuzz_histogramAccuracyAcrossOperations`**
   - Fuzz: Random sequence of bond recordings and distributions
   - Verify: After each operation, histogram is accurate
   - Verify: Distribution operations don't affect histogram

5. **`testFuzz_histogramBounds`**
   - Fuzz: Random rounds (0-255)
   - Verify: Only rounds 1-2 increment histogram
   - Verify: Invalid rounds revert without affecting histogram

### 4. Edge Cases & Error Handling

**Test Cases:**

1. **`test_histogramWithMaxWorkflowId`**
   - Setup: Record bond with workflowId = type(uint256).max
   - Verify: Histogram increments correctly
   - Verify: Getter returns correct value

2. **`test_histogramWithMaxRound`**
   - Setup: Record bond with round = 2 (maximum)
   - Verify: Histogram[2] increments
   - Verify: Cannot record at round > 2

3. **`test_histogramCumulativeAcrossManyBonds`**
   - Setup: Record 100 bonds at round 1
   - Action: Verify histogram[1] == 100
   - Verify: No overflow or precision issues

4. **`test_histogramReentrancyProtection`**
   - Setup: Malicious contract attempting reentrancy
   - Action: Record bond, attempt reentrancy during callback
   - Verify: Histogram only increments once
   - Verify: Reentrancy guard prevents double-counting

### 5. Gas Optimization Tests

**Test Cases:**

1. **`test_histogramStorageReads`**
   - Verify: Direct mapping access is cheaper than getter
   - Verify: Getter reads all three rounds efficiently
   - Benchmark gas costs

2. **`test_histogramIncrementGasCost`**
   - Benchmark: Gas cost of histogram increment
   - Compare: With and without histogram tracking
   - Verify: Increment is efficient (single SLOAD + SSTORE)

---

## Test Implementation Priority

### High Priority (Must Have)
1. ✅ Unit tests: Basic increment operations (rounds 1-2)
2. ✅ Integration tests: Escalation flow updates
3. ✅ Invariant: Round 0 always zero
4. ✅ Invariant: Histogram matches actual bonds

### Medium Priority (Should Have)
5. ⚪ Edge cases: Invalid rounds, duplicate bonds
6. ⚪ Fuzz tests: Random sequences
7. ⚪ Integration: Multiple disputes accumulation

### Low Priority (Nice to Have)
8. ⚪ Gas optimization tests
9. ⚪ Reentrancy specific tests (covered by general reentrancy tests)
10. ⚪ Performance tests with many bonds

---

## Test Coverage Goals

- **Unit Test Coverage:** 100% of histogram update paths
- **Integration Coverage:** All escalation scenarios
- **Invariant Coverage:** Critical invariants always hold
- **Edge Case Coverage:** All round validation and error paths

---

## Potential Improvements

### Current Implementation Strengths
- ✅ Simple, clear increment logic
- ✅ Efficient storage (single mapping)
- ✅ Public getter for observability

### Potential Enhancements
1. **Add Events:**
   ```solidity
   event EscalationDepthHistogramUpdated(uint8 round, uint256 newCount);
   ```
   Emit when histogram is incremented for better observability

2. **Add Reset Function (Emergency Only):**
   ```solidity
   function resetEscalationDepthHistogram() external onlyRole(ROLE_TIMELOCK);
   ```
   For emergency situations (requires governance)

3. **Add Time-Series Tracking:**
   - Track histogram per time period (e.g., per week)
   - Would require new storage structure
   - Useful for analytics but may be overkill

4. **Add Round 0 Validation:**
   - Explicit check in getter that round 0 is always 0
   - Could help catch bugs earlier

---

## Summary

The `escalationDepthHistogram` implementation is **simple and correct**, but needs **comprehensive test coverage**. The existing invariant test provides basic coverage, but unit tests and edge case tests are missing.

**Recommended Next Steps:**
1. Implement unit tests for histogram increments (Priority 1)
2. Add integration tests for escalation flows (Priority 1)
3. Enhance invariant tests with fuzzing (Priority 2)
4. Add edge case tests (Priority 2)
5. Consider adding events for better observability (Priority 3)

---

**Review Status:** ✅ Complete  
**Test Strategy Status:** ✅ Complete  
**Implementation Priority:** High
