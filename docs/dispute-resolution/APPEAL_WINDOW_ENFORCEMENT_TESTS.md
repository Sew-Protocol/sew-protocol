# Appeal Window Enforcement Tests

**Date**: 2025-01-XX  
**Status**: ✅ **COMPLETE**  
**Test File**: `test/foundry/core/AppealWindowEnforcement.t.sol`

---

## Overview

Comprehensive test suite for appeal window enforcement feature, ensuring tokens are only transferred after appeal window expires.

---

## Test Coverage

### ✅ Core Functionality Tests

#### 1. `test_ResolutionAtRound0_StoresPendingSettlement()`

**Purpose**: Verify that resolution at round 0 stores pending settlement instead of executing immediately

**Test Steps**:

1. Create escrow and raise dispute
2. Initialize dispute
3. Resolver resolves (release)
4. Verify pending settlement exists
5. Verify state is still DISPUTED (not RELEASED)
6. Verify tokens not transferred yet

**Expected Results**:

- ✅ Pending settlement exists
- ✅ `isRelease = true`
- ✅ Appeal deadline in future
- ✅ State is DISPUTED
- ✅ No claimable balance for seller

---

#### 2. `test_ResolutionAtFinalRound_ExecutesImmediately()`

**Purpose**: Verify that resolution at final round (MAX_ROUND = 2) executes immediately

**Test Steps**:

1. Create escrow and raise dispute
2. Escalate to round 1, then round 2 (final)
3. Senior resolver resolves at final round
4. Verify no pending settlement
5. Verify state is RELEASED
6. Verify tokens transferred

**Expected Results**:

- ✅ No pending settlement
- ✅ State is RELEASED
- ✅ Seller has claimable balance

---

#### 3. `test_AppealWindowExpires_SettlementCanBeExecuted()`

**Purpose**: Verify that settlement can be executed after appeal window expires

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Get appeal deadline
4. Warp past appeal deadline
5. Execute pending settlement
6. Verify state is RELEASED
7. Verify tokens transferred
8. Verify pending settlement cleared

**Expected Results**:

- ✅ Settlement executes successfully
- ✅ State changes to RELEASED
- ✅ Seller has claimable balance
- ✅ Pending settlement cleared

---

#### 4. `test_AppealWindowNotExpired_SettlementCannotBeExecuted()`

**Purpose**: Verify that settlement cannot be executed before appeal window expires

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Get appeal deadline
4. Warp to just before appeal deadline
5. Try to execute pending settlement
6. Verify revert with "Appeal window not expired"
7. Verify state still DISPUTED

**Expected Results**:

- ✅ Revert with expected message
- ✅ State remains DISPUTED
- ✅ No tokens transferred

---

#### 5. `test_EscalationDuringWindow_CancelsPendingSettlement()`

**Purpose**: Verify that escalation during appeal window cancels pending settlement

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Verify pending settlement exists
4. Escalate during appeal window
5. Verify pending settlement cancelled
6. Verify state still DISPUTED

**Expected Results**:

- ✅ Pending settlement exists before escalation
- ✅ Pending settlement cancelled after escalation
- ✅ State remains DISPUTED
- ✅ `PendingSettlementCancelled` event emitted

---

#### 6. `test_automateTimedActions_ExecutesPendingSettlement()`

**Purpose**: Verify that `automateTimedActions` automatically executes pending settlements

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Get appeal deadline
4. Warp past appeal deadline
5. Call `automateTimedActions`
6. Verify state is RELEASED
7. Verify tokens transferred

**Expected Results**:

- ✅ `automateTimedActions` returns `true`
- ✅ State changes to RELEASED
- ✅ Seller has claimable balance

---

### ✅ Edge Case Tests

#### 7. `test_MultipleCallsToExecutePendingSettlement_Revert()`

**Purpose**: Verify that multiple calls to `executePendingSettlement` revert after first execution

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Warp past appeal deadline
4. First call succeeds
5. Second call reverts with "No pending settlement"

**Expected Results**:

- ✅ First call succeeds
- ✅ Second call reverts with expected message

---

#### 8. `test_StateChanged_ExecutePendingSettlementReverts()`

**Purpose**: Verify that `executePendingSettlement` reverts if state is not DISPUTED

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Warp past appeal deadline
4. Execute pending settlement (state changes to RELEASED)
5. Try to execute again
6. Verify revert with "Not in disputed state"

**Expected Results**:

- ✅ First execution succeeds
- ✅ Second execution reverts with expected message

---

#### 9. `test_CancelResolution_StoresPendingSettlement()`

**Purpose**: Verify that cancel resolution also stores pending settlement

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (cancel)
3. Verify pending settlement exists with `isRelease = false`
4. Warp past appeal deadline
5. Execute pending settlement
6. Verify state is REFUNDED
7. Verify tokens refunded to buyer

**Expected Results**:

- ✅ Pending settlement exists
- ✅ `isRelease = false`
- ✅ State changes to REFUNDED after execution
- ✅ Buyer has claimable balance

---

#### 10. `test_getPendingSettlement_ViewFunction()`

**Purpose**: Verify `getPendingSettlement` view function works correctly

**Test Steps**:

1. Create escrow and raise dispute
2. Resolver resolves (release)
3. Query pending settlement
4. Verify all fields correct
5. Warp past deadline
6. Query again, verify `canExecute = true`

**Expected Results**:

- ✅ All fields correct before deadline
- ✅ `canExecute = false` before deadline
- ✅ `canExecute = true` after deadline

---

#### 11. `test_NoPendingSettlement_ExecutePendingSettlementReverts()`

**Purpose**: Verify that `executePendingSettlement` reverts if no pending settlement exists

**Test Steps**:

1. Create escrow (no dispute raised)
2. Try to execute pending settlement
3. Verify revert with "No pending settlement"

**Expected Results**:

- ✅ Revert with expected message

---

## Test Statistics

- **Total Tests**: 11
- **Core Functionality**: 6 tests
- **Edge Cases**: 5 tests
- **Coverage**: All major code paths and edge cases

---

## Test Setup

The test suite uses:

- **EscrowVault**: Main escrow contract
- **DecentralizedResolutionModule**: Resolution module with appeal windows
- **ResolverIncentiveModuleV2**: Incentive module for bond handling
- **ERC20Mock**: Test token

**Setup Steps**:

1. Deploy all contracts
2. Set up roles (timelock, resolvers)
3. Register escrow contract in resolution module
4. Set appeal windows: [2 days, 3 days, 0]
5. Appoint and activate resolvers

---

## Running the Tests

```bash
# Run all appeal window enforcement tests
forge test --match-path test/foundry/core/AppealWindowEnforcement.t.sol -vvv

# Run specific test
forge test --match-test test_ResolutionAtRound0_StoresPendingSettlement -vvv

# Run with gas reporting
forge test --match-path test/foundry/core/AppealWindowEnforcement.t.sol --gas-report
```

---

## Test Coverage Summary

| Feature                                        | Test Coverage | Status   |
| ---------------------------------------------- | ------------- | -------- |
| Pending settlement storage                     | ✅            | Complete |
| Final round immediate execution                | ✅            | Complete |
| Appeal window expiration check                 | ✅            | Complete |
| Settlement execution                           | ✅            | Complete |
| Escalation cancellation                        | ✅            | Complete |
| Automatic execution via `automateTimedActions` | ✅            | Complete |
| Cancel resolution flow                         | ✅            | Complete |
| View function                                  | ✅            | Complete |
| Error cases                                    | ✅            | Complete |

---

## Integration with CI/CD

These tests should be run as part of:

- Pre-commit hooks
- Pull request validation
- Release candidate validation
- Regression testing

---

## Future Enhancements

Potential additional tests:

1. Test with different appeal window durations
2. Test with multiple escalations during window
3. Test with different resolution modules (backward compatibility)
4. Gas optimization tests
5. Fuzz testing for edge cases

---

**End of Test Documentation**
