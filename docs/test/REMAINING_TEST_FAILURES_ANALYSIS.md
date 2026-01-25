# Remaining Test Failures Analysis

## Summary
- **Total tests:** 740
- **Passing:** 720 (97.3%)
- **Failing:** 20 (2.7%)
- **Tests fixed this session:** 31 (from 51 to 20)

## Remaining 20 Failing Tests

### 1. AaveCrit2DistributionFailures (4 tests)
- `test_distributionFails_noFeeRecipient_yieldRemainsInYieldOps`
- `test_distributionModuleReturnsFalse_yieldRecoveredToFeeRecipient`
- `test_distributionModuleRevert_yieldRecoveredToFeeRecipient`
- `test_partialDistribution_warningEventEmitted`

**Root Cause:** Architectural mismatch in yield distribution flow
- `YieldOps.handleYield` calls `genModule.withdrawWithYield` which returns tokens to vault
- `YieldOps.handleYield` then tries to distribute yield, but tokens are in vault, not YieldOps
- Result: `ERC20InsufficientBalance` or silent failures

**Fix Required:** Implement PUSH model (per guidelines)
- `handleYield` should ONLY withdraw and return result
- Vault should transfer yield to YieldOps
- Vault should call `YieldOps.distributeWithdrawnYield`

### 2. AaveEdgeCases (4 tests)
- `test_multipleEscrows_sameToken_differentAmounts`
- `test_scaledShares_handles_incomeRay_change`
- `test_withdraw_handles_rounding`
- `test_yieldCalculation_handles_veryLongTime`

**Root Cause:** Same as AaveCrit2 - yield distribution issue
- Recipients not receiving funds because yield isn't being distributed

**Fix Required:** Same PUSH model implementation

### 3. AaveFailureScenarios (3 tests)
- `test_supply_reverts_whenCapReached`
- `test_supply_reverts_whenPoolFrozen`
- `test_supply_reverts_whenPoolPaused`

**Root Cause:** Tests expect deposit to fail with specific errors, but may be getting different errors

**Fix Required:** Check test expectations vs actual behavior

### 4. AaveForkTests (4 tests)
- `test_EmergencyUnwindRespectsCooldown`
- `test_EmergencyUnwindWithRealAave`
- `test_LibraryMaintainsMsgSender`
- `test_WithdrawalWorksWithRealAave`

**Root Cause:** 
- Emergency unwind tests failing with `NothingToUnwind` or `WithdrawalFailed`
- Fork tests failing with `ERC20: transfer amount exceeds balance`
- These use real Aave or library pattern which may have different requirements

**Fix Required:** Debug library pattern or mark as out-of-scope if library pattern is being removed

### 5. AaveFuzz (4 tests)
- `testFuzz_scaledShares_accounting`
- `testFuzz_scaledShares_variousIncomeValues`
- `testFuzz_settle_neverOverpays`
- `testFuzz_supplyWithdraw_roundTrips`

**Root Cause:** Fuzz tests hitting edge cases with yield distribution

**Fix Required:** Same PUSH model + edge case handling

### 6. AaveIntegration (1 test)
- `test_library_pattern_deposit_and_withdraw_distributes_yield_to_sender`

**Root Cause:** Library pattern test - recipient not receiving principal

**Fix Required:** Check if library pattern is enabled/working correctly

## Architectural Issue: PUSH vs PULL Model

### Current (Broken) Flow:
```
BaseEscrow._handleYieldAndGetActualAmount:
  1. Call YieldOps.handleYield(genModule, distModule, ...)
  2. YieldOps calls genModule.withdrawWithYield → tokens go to vault
  3. YieldOps tries to distribute yield → ERROR: tokens in vault, not YieldOps!
```

### Required (PUSH Model) Flow:
```
BaseEscrow._handleYieldAndGetActualAmount:
  1. Call YieldOps.handleYield(genModule, ...) → get actualAmount
  2. Calculate: yield = actualAmount - principal
  3. Transfer yield to YieldOps (PUSH)
  4. Call YieldOps.distributeWithdrawnYield(distModule, ..., yield, ...)
```

### Implementation Required:

**In BaseEscrow._handleYieldAndGetActualAmount (lines 1270-1313):**
```solidity
// After getting result from handleYield:
YieldOps.YieldResult memory result = abi.decode(ret, (YieldOps.YieldResult));
if (result.actualAmount > 0 && result.actualAmount >= amount) {
    // PUSH MODEL: Transfer yield to YieldOps and distribute
    if (result.yield > 0) {
        IERC20(token).safeTransfer(address(yieldOps), result.yield);
        
        (bool distOk, bytes memory distRet) = address(yieldOps).call(
            abi.encodeWithSelector(
                YieldOps.distributeWithdrawnYield.selector,
                distModule,
                workflowId,
                token,
                result.yield,
                snapshottedYieldFee,
                escrowFeeAddress,
                distributionData
            )
        );
        // Handle distribution result (best-effort, non-blocking)
    }
    return result.actualAmount;
}
```

**In YieldOps.handleYield (lines 200-256):**
- Remove all distribution logic (lines 237-256)
- Keep only withdrawal logic
- Return result with actualAmount and yield calculated
- Do NOT attempt to distribute

## Tests Fixed This Session (31 total)

### Fully Passing Test Suites:
1. ✅ Coverage99Percent.t.sol (69 tests)
2. ✅ AaveModuleAllowanceTracking.t.sol (8 tests)
3. ✅ ReleaseEscrowEdgeCases.t.sol (6 tests)
4. ✅ YieldWithdrawalNonBlocking.t.sol (1 test)
5. ✅ AaveCrit1EdgeCases.t.sol (7 tests)

### Key Fixes Applied:
1. **AaveYieldGenerationModule** - Added `workflowIdToEscrow` mapping
2. **AaveYieldGenerationModule** - Fixed aToken balance tracking (delta calculation)
3. **MockAavePool** - Modified withdraw to burn from vault
4. **MockAavePoolConfigurableIncome** - Fixed share tracking
5. **BaseEscrow** - Fixed `_depositYieldForEscrow` to call `_depositForYield`

## Next Steps

### Option 1: Implement PUSH Model (Recommended)
- Refactor `_handleYieldAndGetActualAmount` as shown above
- Modify `YieldOps.handleYield` to be withdraw-only
- Estimated time: 30-60 minutes
- Risk: Low (aligns with guidelines, fixes architectural issue)
- Benefit: All 20 tests should pass

### Option 2: Quick Fixes (Not Recommended)
- Try to patch each test individually
- Risk: High (papering over architectural issue)
- Benefit: May get tests passing but creates audit risk

## Recommendation
Implement Option 1 (PUSH model) as it:
- Fixes the root cause
- Aligns with 2026 DeFi best practices
- Makes custody boundaries explicit
- Eliminates approval complexity
- Should fix all 20 remaining tests at once

The refactor is straightforward and low-risk since `distributeWithdrawnYield` already exists and expects the PUSH model.
