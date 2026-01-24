# Function Migration Verification

## Balance Accounting Analysis

### Current Flow (YieldOps Path - CORRECT):
1. **Deposit:**
   - `BaseEscrow._depositYieldForEscrow()` → `genModule.depositForYield()`
   - Module deposits to Aave, tokens leave BaseEscrow contract
   - `_updateEscrowBalance(token, amountAfterFee, true)` - tracks principal in escrow

2. **Withdrawal:**
   - `BaseEscrow._handleYieldAndGetActualAmount()` → `YieldOps.handleYield()`
   - `YieldOps.handleYield()` → `genModule.withdrawWithYield()`
   - **Module withdraws from Aave → tokens go to BaseEscrow contract** ✅
   - YieldOps distributes yield (protocol fee + distribution) - transfers OUT from BaseEscrow
   - YieldOps returns `result.actualAmount` (total withdrawn including yield)
   - BaseEscrow: `_updateEscrowBalance(token, amount, false)` - decrements principal tracking
   - BaseEscrow transfers `actualAmount` to user

### Balance Accounting Verification:
- **On deposit:** Principal tracked, tokens leave contract (to Aave)
- **On withdrawal:** 
  - Module withdraws `actualAmount` (principal + yield) to BaseEscrow ✅
  - YieldOps distributes yield portion (transfers out) ✅
  - Principal remains in BaseEscrow ✅
  - `_updateEscrowBalance` decrements principal tracking ✅
  - User receives `actualAmount` ✅

**Conclusion:** Balance accounting is CORRECT. The yield portion is distributed by YieldOps, principal stays in BaseEscrow for user transfer.

## Function Migration Plan

### Functions to REMOVE (Delegatecall Pattern):

1. **`setAaveYieldLibrary(address)`** - REMOVE
   - **Reason:** Configures delegatecall library (not needed)
   - **Replacement:** None needed (module handles Aave directly)

2. **`setAaveYieldLibraryEnabled(bool)`** - REMOVE
   - **Reason:** Enables/disables delegatecall pattern (not needed)
   - **Replacement:** None needed (module has its own enable/disable)

3. **`_handleYieldViaLibrary(...)`** - REMOVE
   - **Reason:** Uses delegatecall for withdrawals (duplicate of YieldOps path)
   - **Replacement:** `YieldOps.handleYield()` → `genModule.withdrawWithYield()` ✅

4. **`_handleYieldDepositViaLibrary(...)`** - REMOVE
   - **Reason:** Uses delegatecall for deposits (duplicate of module path)
   - **Replacement:** `genModule.depositForYield()` ✅

### Functions to MOVE (Emergency Unwind):

5. **`emergencyUnwindAavePosition(...)`** - MOVE TO GuardianOps
   - **Reason:** Emergency function, rarely used, bytecode expensive
   - **Destination:** `contracts/ops/GuardianOps.sol` (NEW)
   - **Safety:** Must preserve all safety checks:
     - `onlyRole(ROLE_GUARDIAN)`
     - `whenPaused`
     - Cooldown + max amount limits
     - Withdraw to escrow contract (not guardian)
   - **Implementation:** GuardianOps calls module or Aave directly

### Storage to REMOVE (Duplicate Tracking):

6. **`aaveYieldLibrary`** - REMOVE
   - **Reason:** Delegatecall library address (not needed)
   - **Module tracks:** N/A (module doesn't use delegatecall)

7. **`aaveYieldLibraryEnabled`** - REMOVE
   - **Reason:** Delegatecall feature flag (not needed)
   - **Module tracks:** `aaveEnabled` (in AaveYieldGenerationModule)

8. **`escrowInYield[workflowId][token]`** - REMOVE
   - **Reason:** Duplicate of module tracking
   - **Module tracks:** `escrowInAave[escrowContract][workflowId]` ✅

9. **`escrowYieldScaledShares[workflowId][token]`** - REMOVE
   - **Reason:** Only used by delegatecall pattern
   - **Module tracks:** Uses `escrowATokenBalance` (actual aToken balance) ✅

10. **`escrowATokenBalances[workflowId][aToken]`** - REMOVE
    - **Reason:** Duplicate of module tracking
    - **Module tracks:** `escrowATokenBalance[escrowContract][workflowId]` ✅

### Events to REMOVE (Delegatecall Pattern):

11. **`AaveYieldLibrarySet`** - REMOVE
    - **Reason:** Only emitted by `setAaveYieldLibrary()` (removed)

12. **`AaveYieldLibraryEnabled`** - REMOVE
    - **Reason:** Only emitted by `setAaveYieldLibraryEnabled()` (removed)

13. **`YieldDepositAttempted`** - VERIFY USAGE
    - **Check:** Is this only used by delegatecall path?
    - **If yes:** REMOVE
    - **If no:** Keep but update to use module events

14. **`YieldWithdrawalAttempted`** - VERIFY USAGE
    - **Check:** Is this only used by delegatecall path?
    - **If yes:** REMOVE
    - **If no:** Keep but update to use module events

15. **`YieldWithdrawalPrincipalOnly`** - VERIFY USAGE
    - **Check:** Is this only used by delegatecall path?
    - **If yes:** REMOVE
    - **If no:** Keep but update to use module events

16. **`EmergencyUnwindExecuted`** - MOVE TO GuardianOps
    - **Reason:** Emitted by `emergencyUnwindAavePosition()` (moved)
    - **Destination:** GuardianOps contract

### Imports to REMOVE:

17. **`AaveYieldLibrary.sol`** - REMOVE
    - **Reason:** Only used by delegatecall pattern

18. **`AaveYieldHandlingLibrary.sol`** - REMOVE
    - **Reason:** Only used by delegatecall pattern

19. **`AaveV3Interfaces.sol`** - VERIFY USAGE
    - **Check:** Is `IAaveAToken` used anywhere else?
    - **If only in delegatecall:** REMOVE
    - **If used elsewhere:** Keep

## Verification Checklist

- [ ] All removed functions have replacements in module/YieldOps
- [ ] Balance accounting verified (yield distribution doesn't break accounting)
- [ ] Emergency unwind moved to GuardianOps with all safety checks
- [ ] Module events cover all removed events
- [ ] Tests updated to use new paths
- [ ] No orphaned code or dead paths
