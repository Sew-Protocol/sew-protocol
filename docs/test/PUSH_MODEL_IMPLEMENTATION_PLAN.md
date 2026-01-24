# PUSH Model Implementation Plan

## Current Situation
- **Branch:** yield-push
- **Test Status:** ~20 failing tests (all Aave-related)
- **Root Cause:** `YieldOps.handleYield` tries to distribute tokens it doesn't have

## The Problem

### Current (Broken) Flow:
```
BaseEscrow._handleYieldAndGetActualAmount():
  1. Call YieldOps.handleYield(genModule, distModule, ...)
  2. YieldOps calls genModule.withdrawWithYield() → tokens return to VAULT
  3. YieldOps tries to distribute yield → ERROR: tokens in vault, not YieldOps!
```

### Why Tests Fail:
- `YieldOps.handleYield` (lines 200-296 in YieldOps.sol) tries to:
  - Transfer protocol fees to feeRecipient
  - Call `_distributeYieldInternal` which transfers to distribution module
- But YieldOps has balance 0 → `ERC20InsufficientBalance` errors
- Result: Recipients don't receive funds, yield isn't distributed

## The Solution: PUSH Model

### Required Flow:
```
BaseEscrow._handleYieldAndGetActualAmount():
  1. Call YieldOps.handleYield(genModule, ...) → get actualAmount (withdraw ONLY)
  2. Calculate: yield = actualAmount - principal
  3. Transfer yield to YieldOps (PUSH)
  4. Call YieldOps.distributeWithdrawnYield(...) → YieldOps distributes from its balance
```

## Implementation Steps

### Step 1: Modify `YieldOps.handleYield` (lines 200-296)

**Current:** Tries to withdraw AND distribute  
**Required:** ONLY withdraw, return result

```solidity
function handleYield(
    IYieldGenerationModule genModule,
    IYieldDistributionModule, // unused
    uint256 workflowId,
    address token,
    uint256 amount,
    uint256, // protocolFeeBps - unused
    address, // feeRecipient - unused
    bytes memory // distributionData - unused
) external onlyRole(ROLE_ESCROW_CONTRACT) returns (YieldResult memory result) {
    result.actualAmount = amount;
    result.yield = 0;
    result.yieldDistributed = 0;
    result.success = true;

    if (address(genModule) == address(0)) {
        return result;
    }

    // Withdraw with yield (try/catch to prevent blocking)
    // IMPORTANT: Tokens are returned to escrow (msg.sender), NOT to YieldOps
    try genModule.withdrawWithYield(workflowId, token, amount) returns (
        bool withdrawSuccess,
        uint256 actualAmount,
        uint256 /* yieldGenerated */
    ) {
        if (withdrawSuccess) {
            result.actualAmount = actualAmount;
            if (actualAmount > amount) {
                result.yield = actualAmount - amount;
                emit YieldWithdrawn(workflowId, token, result.yield);
            }
        }
    } catch {
        emit YieldDistributionFailed(workflowId, token, 0, 'Yield withdrawal failed');
    }

    // NOTE: Distribution is NOT done here
    // Escrow must transfer yield to YieldOps and call distributeWithdrawnYield
    return result;
}
```

**Changes:**
- Remove lines 237-296 (all distribution logic)
- Keep only withdrawal logic
- Add comment explaining PUSH model

### Step 2: Modify `BaseEscrow._handleYieldAndGetActualAmount` (lines 1270-1313)

**Add after line 1305 (after decoding result):**

```solidity
YieldOps.YieldResult memory result = abi.decode(ret, (YieldOps.YieldResult));
if (result.actualAmount > 0 && result.actualAmount >= amount) {
    // PUSH MODEL: If yield was generated, transfer it to YieldOps and distribute
    if (result.yield > 0) {
        // Transfer yield portion to YieldOps (PUSH)
        IERC20(token).safeTransfer(address(yieldOps), result.yield);
        
        // Call YieldOps to distribute the yield (best-effort, non-blocking)
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
        
        // Decode distribution result (best-effort)
        if (distOk && distRet.length >= 64) {
            (bool distSuccess, uint256 distributedAmount) = abi.decode(distRet, (bool, uint256));
            result.yieldDistributed = distributedAmount;
            result.success = distSuccess;
        } else {
            // Distribution call failed - yield is in YieldOps, emit failure
            if (yieldEnabled) {
                _emitYieldFailure(2, workflowId, address(yieldOps), YieldOps.distributeWithdrawnYield.selector, token, result.yield, uint8(FailureReason.CALL_FAILED));
            }
        }
    }
    return result.actualAmount;
}
```

**Changes:**
- Add yield transfer and distribution call after getting result from handleYield
- Use best-effort pattern (no revert on distribution failure)
- Keep principal payout separate from yield distribution

## Expected Results

### Tests That Should Pass:
1. **AaveCrit2DistributionFailures** (4 tests) - YieldOps will have tokens to distribute
2. **AaveEdgeCases** (remaining tests) - Recipients will receive funds
3. **AaveForkTests** (4 tests) - Balance accounting will be correct
4. **AaveFuzz** (tests) - Deterministic yield calculation
5. **AaveFailureScenarios** (3 tests) - Non-blocking failure handling

### Invariants Maintained:
- ✅ Vault custody: Principal stays in vault until payout
- ✅ Yield = delta: Calculated locally in vault
- ✅ PUSH model: Vault transfers yield to YieldOps before calling distribute
- ✅ Non-blocking: Distribution failures don't block principal settlement
- ✅ No approvals: Vault never approves YieldOps

## Testing Strategy

### Before Implementation:
1. Run current tests to establish baseline
2. Note which specific assertions are failing

### After Implementation:
1. Run `forge test --match-path "test/foundry/integration/AaveCrit2*"`
2. Check for `ERC20InsufficientBalance` errors (should disappear)
3. Run `forge test --match-path "test/foundry/integration/AaveEdgeCases*"`
4. Run full suite: `forge test`

### Success Criteria:
- All 20 tests pass
- No `ERC20InsufficientBalance` errors
- YieldOps balance = 0 after distribution (or = protocol fees if retained)
- Recipients receive correct amounts

## Rollback Plan

If implementation causes regressions:
1. The changes are localized to 2 functions
2. Can revert with: `git checkout HEAD -- contracts/YieldOps.sol contracts/core/BaseEscrow.sol`
3. Original `distributeWithdrawnYield` function remains unchanged

## Notes

- `distributeWithdrawnYield` already exists and expects PUSH model (tokens in YieldOps)
- This refactor aligns the main flow with the existing `_distributeYieldIfNeeded` pattern
- The fix is ~30 lines of code changes
- Low risk: Only changes token flow, not escrow state machine logic
