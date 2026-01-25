# Aave Library Pattern Removal - Implementation Plan

**Branch**: `size-reduction-aave-removal`  
**Goal**: Get EscrowVault under 24KB by removing Aave delegatecall pattern and inlining trivial libraries  
**Based on**: ChatGPT 5.2 Plus recommendations

## Current Status

- **EscrowVault**: 28,887 bytes (28.21 KB) - 17.5% over limit
- **Target**: < 24,576 bytes (24 KB)
- **Remaining**: 4,311 bytes needed

## Implementation Plan (Prioritized)

### Phase 1: Remove Aave Library Pattern from BaseEscrow (~2-3KB expected)

**Remove from BaseEscrow.sol:**
1. ✅ Remove imports:
   - `AaveYieldLibrary.sol`
   - `AaveYieldHandlingLibrary.sol`
   - `AaveV3Interfaces.sol`

2. ✅ Remove storage variables:
   - `aaveYieldLibrary` (address)
   - `aaveYieldLibraryEnabled` (bool)
   - `escrowATokenBalances` (mapping)
   - `escrowInYield` (mapping) - if only used by Aave path
   - `escrowYieldScaledShares` (mapping)

3. ✅ Remove functions:
   - `setAaveYieldLibrary(address)`
   - `setAaveYieldLibraryEnabled(bool)`
   - `emergencyUnwindAavePosition(...)` - move to GuardianOps
   - `_handleYieldViaLibrary(...)`
   - `_handleYieldDepositViaLibrary(...)`

4. ✅ Remove events:
   - `AaveYieldLibrarySet`
   - `AaveYieldLibraryEnabled`
   - `YieldDepositAttempted` (if only used by Aave path)
   - `YieldWithdrawalAttempted` (if only used by Aave path)
   - `YieldWithdrawalPrincipalOnly`
   - `EmergencyUnwindExecuted`

5. ✅ Simplify `_handleYieldAndGetActualAmount`:
   - Remove Aave library path check
   - Keep only YieldOps path

6. ✅ Simplify `_depositYieldForEscrow`:
   - Remove Aave library path check
   - Keep only direct `genModule.depositForYield()` call

### Phase 2: Create GuardianOps Contract (~200-300 bytes in BaseEscrow)

**New Contract**: `contracts/ops/GuardianOps.sol`
- Immutable escrow address
- Immutable aavePool/module addresses
- `emergencyUnwind(...)` function
- Guards:
  - `escrow.hasRole(ROLE_GUARDIAN, msg.sender)` (staticcall)
  - `escrow.paused()` (staticcall)
- Calls Aave to withdraw to escrow contract address

**Remove from BaseEscrow:**
- `emergencyUnwindAavePosition` function

### Phase 3: Inline Trivial Libraries in EscrowVault (~0.5-2KB expected)

**Remove library imports:**
- `FeeRecordingLibrary`
- `BalanceUpdateLibrary`
- `FeeWithdrawalLibrary`
- `TokenRecoveryLibrary`

**Inline implementations:**
1. `_recordFee`: `unchecked { totalFeesPerToken[token] += amount; }`
2. `_updateEscrowBalance`: unchecked add, checked subtract
3. `withdrawFees`: minimal implementation (transfer to escrowFeeAddress)
4. `recoverERC20`: minimal availability check and transfer

### Phase 4: Simplify Module Getters (~300-500 bytes expected)

**Remove library imports:**
- `ModuleGetterLibrary`
- `ModuleGetterConsolidationLibrary`

**Inline in EscrowVault:**
- Direct implementation of module resolution logic
- Keep special-case fallback for resolution module

### Phase 5: Optimize Compiler Settings (~200-500 bytes expected)

**Update `foundry.toml` or `hardhat.config.ts`:**
- Enable `viaIR: true`
- Increase optimizer runs: `200_000` (or higher)
- Ensure optimizer is enabled

### Phase 6: Optional - Remove Telemetry Events (~300-500 bytes)

**If still over limit:**
- Make `OperationFailure` events compile-time optional
- Remove "attempted" yield events if not critical

## Testing Strategy

1. ✅ Build and verify size reduction after each phase
2. ✅ Run existing tests to ensure no regressions
3. ✅ Add tests for GuardianOps contract
4. ✅ Verify YieldOps path still works correctly
5. ✅ Test emergency unwind via GuardianOps

## Expected Savings

| Phase | Expected Savings | Cumulative |
|-------|------------------|------------|
| Phase 1: Remove Aave Pattern | 2,000-3,000 bytes | 2,000-3,000 |
| Phase 2: GuardianOps | 200-300 bytes | 2,200-3,300 |
| Phase 3: Inline Libraries | 500-2,000 bytes | 2,700-5,300 |
| Phase 4: Simplify Getters | 300-500 bytes | 3,000-5,800 |
| Phase 5: Compiler Settings | 200-500 bytes | 3,200-6,300 |
| Phase 6: Optional Events | 300-500 bytes | 3,500-6,800 |

**Target**: 4,311 bytes needed  
**Expected Total**: 3,500-6,800 bytes saved  
**Confidence**: High (should easily exceed target)

## Implementation Order

1. ✅ Phase 1 (biggest impact)
2. ✅ Phase 2 (safety feature preservation)
3. ✅ Phase 3 (quick wins)
4. ✅ Phase 4 (cleanup)
5. ✅ Phase 5 (compiler optimization)
6. ⏸️ Phase 6 (only if needed)

## Notes

- All changes preserve core escrow semantics
- GuardianOps maintains emergency unwind safety
- YieldOps path remains fully functional
- No breaking changes to external interfaces
