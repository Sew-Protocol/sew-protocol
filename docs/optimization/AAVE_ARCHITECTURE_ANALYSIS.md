# Aave Architecture Analysis

**Last Updated**: 2026-01-23  
**Status**: ✅ **CURRENT** - Reflects module pattern implementation

## Current State

### ✅ AaveYieldGenerationModule (Module - CORRECT)
**Location**: `contracts/modules/AaveYieldGenerationModule.sol`

**Handles:**
- ✅ `depositForYield(workflowId, token, amount)` - Aave deposits
- ✅ `withdrawWithYield(workflowId, token, originalAmount)` - Aave withdrawals
- ✅ Tracks Aave state:
  - `escrowInAave[escrowContract][workflowId]` - is in Aave
  - `escrowATokenBalance[escrowContract][workflowId]` - aToken balance
  - `escrowOriginalDeposit[escrowContract][workflowId]` - original deposit
- ✅ All Aave-specific logic (pool, aToken, scaled shares calculations)

**Interface**: `IYieldGenerationModule` - generic interface

### ✅ BaseEscrow (Escrow - GENERIC, NO AAVE CODE)
**Location**: `contracts/core/BaseEscrow.sol`  
**Status**: ✅ **CLEANED** - All Aave-specific code removed (2026-01-23)

**Removed (delegatecall pattern):**
1. ✅ **Storage removed:**
   - `aaveYieldLibrary` - removed
   - `aaveYieldLibraryEnabled` - removed
   - `escrowInYield[workflowId][token]` - removed (module tracks this)
   - `escrowYieldScaledShares[workflowId][token]` - removed (module tracks this)
   - `escrowATokenBalances[workflowId][aToken]` - removed (module tracks this)

2. ✅ **Functions removed:**
   - `setAaveYieldLibrary(address)` - removed
   - `setAaveYieldLibraryEnabled(bool)` - removed
   - `emergencyUnwindAavePosition(...)` - moved to GuardianOps
   - `_handleYieldViaLibrary(...)` - removed
   - `_handleYieldDepositViaLibrary(...)` - removed

3. ✅ **Events removed:**
   - `AaveYieldLibrarySet` - removed
   - `AaveYieldLibraryEnabled`
   - `YieldDepositAttempted` (if only used by delegatecall path)
   - `YieldWithdrawalAttempted` (if only used by delegatecall path)
   - `YieldWithdrawalPrincipalOnly` (if only used by delegatecall path)
   - `EmergencyUnwindExecuted` (if only used by delegatecall path)

4. **Imports (TO REMOVE):**
   - `AaveYieldLibrary.sol`
   - `AaveYieldHandlingLibrary.sol`
   - `AaveV3Interfaces.sol` (if only used by delegatecall)

### ✅ YieldOps (Generic Orchestration - CORRECT)
**Location**: `contracts/YieldOps.sol`

**Handles:**
- ✅ Generic `handleYield(genModule, distModule, ...)` 
- ✅ Calls `genModule.withdrawWithYield()` - works with any module
- ✅ Handles distribution via `distModule`

## Architecture Flow

### Current (WRONG - Two Paths):
```
BaseEscrow._depositYieldForEscrow()
  ├─> if (aaveYieldLibraryEnabled) → _handleYieldDepositViaLibrary() [DELEGATECALL PATH - REMOVE]
  └─> else → genModule.depositForYield() [GENERIC PATH - KEEP]

BaseEscrow._handleYieldAndGetActualAmount()
  ├─> if (aaveYieldLibraryEnabled) → _handleYieldViaLibrary() [DELEGATECALL PATH - REMOVE]
  └─> else → yieldOps.handleYield() → genModule.withdrawWithYield() [GENERIC PATH - KEEP]
```

### Target (CORRECT - Single Generic Path):
```
BaseEscrow._depositYieldForEscrow()
  └─> genModule.depositForYield() [GENERIC - works with any module]

BaseEscrow._handleYieldAndGetActualAmount()
  └─> yieldOps.handleYield() → genModule.withdrawWithYield() [GENERIC - works with any module]
```

## Test Verification

### ✅ Tests Updated (2026-01-23)
- ✅ `test/foundry/integration/AaveForkTests.t.sol` - Updated to use `GuardianOps` for emergency unwind
- ✅ `test/foundry/integration/AavePauseSemantics.t.sol` - Updated to use `GuardianOps` for emergency unwind
- ✅ `test/foundry/core/AaveLibraryMultiEscrow.t.sol` - Removed delegatecall library setup
- ✅ All tests now use module pattern (no delegatecall library)

### Tests using correct path:
- ✅ `test/foundry/ops/OpsCoverage.t.sol` - tests `YieldOps.handleYield()` with modules
- ✅ Module tests call `AaveYieldGenerationModule.depositForYield()` and `withdrawWithYield()` directly

## ✅ Removal Plan (COMPLETED - 2026-01-23)

### ✅ Phase 1: Remove Delegatecall Pattern from BaseEscrow
1. ✅ Removed storage: `aaveYieldLibrary`, `aaveYieldLibraryEnabled`, `escrowInYield`, `escrowYieldScaledShares`, `escrowATokenBalances`
2. ✅ Removed functions: `setAaveYieldLibrary()`, `setAaveYieldLibraryEnabled()`, `_handleYieldViaLibrary()`, `_handleYieldDepositViaLibrary()`
3. ✅ Removed imports: `AaveYieldLibrary`, `AaveYieldHandlingLibrary`, `AaveV3Interfaces`
4. ✅ Removed events: All Aave-specific events listed above
5. ✅ Simplified `_depositYieldForEscrow()` - removed delegatecall path check
6. ✅ Simplified `_handleYieldAndGetActualAmount()` - removed delegatecall path check

### ✅ Phase 2: Move Emergency Unwind to GuardianOps
1. ✅ Created `contracts/ops/GuardianOps.sol`
2. ✅ Moved `emergencyUnwindAavePosition()` logic to GuardianOps
3. ✅ GuardianOps accesses module via `staticcall` on escrow contract
4. ✅ Removed from BaseEscrow

### ✅ Phase 3: Update Tests
1. ✅ Updated tests to use GuardianOps for emergency unwind
2. ✅ Removed/updated tests for delegatecall library pattern
3. ✅ Verified all tests use module interface

## ✅ Actual Savings Achieved

- **Storage removal**: ~500-800 bytes
- **Function removal**: ~1,500-2,500 bytes
- **Import removal**: ~200-400 bytes
- **Event removal**: ~300-500 bytes
- **Total**: ~2,500-4,200 bytes saved

**Result**: EscrowVault reduced from 28,887 bytes to 23,491 bytes (22.94 KB) ✅ **UNDER 24KB LIMIT**

## Verification Commands

```bash
# Check what's in BaseEscrow vs Module
rg -n "escrowInYield|escrowYieldScaledShares|escrowATokenBalances" contracts/
rg -n "aaveYieldLibrary|aaveYieldLibraryEnabled" contracts/
rg -n "AaveYieldHandlingLibrary|AaveYieldLibrary" contracts/core/BaseEscrow.sol

# Check tests
rg -n "emergencyUnwindAavePosition|setAaveYieldLibrary" test/
rg -n "depositForYield|withdrawWithYield" test/
```
