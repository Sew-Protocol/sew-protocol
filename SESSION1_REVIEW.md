# Session 1 Code Review Checklist

## What to Review

### 1. IYieldModule Interface
**File:** `contracts/interfaces/IYieldModule.sol`

**Key Points to Check:**
- [ ] 5 methods match v2.5 architecture spec (initializeYield, unwindToEscrow, emergencyUnwind, canHandle, getModuleInfo)
- [ ] `accepted` return from initializeYield documents handling of fee-on-transfer
- [ ] emergencyUnwind docstring clearly states: "MUST return funds or REVERT (never return 0)"
- [ ] All 6 INVARIANT comments present
- [ ] Event types defined for Initialized, Withdrawn, EmergencyUnwind

**Safety Critical:**
- Comments on fund flow: "Module NEVER sends funds to arbitrary recipients"
- Comments on principal: "accepted amount, not requested (INVARIANT 4)"
- Comments on balance: "delta check, not absolute (INVARIANT 5)"

### 2. AaveYieldModule Implementation
**File:** `contracts/modules/AaveYieldModule.sol`

**Key Points to Check:**
- [ ] YieldPosition struct stores `principalDeposited` (not shares)
- [ ] onlyEscrow modifier gates all state-changing calls
- [ ] approveEscrow/revokeEscrow functions for authorization
- [ ] initializeYield:
  - [ ] Receives transferred tokens (push model)
  - [ ] Calculates actual deposited via delta (balBefore - balAfter)
  - [ ] Stores actualDeposited in position
  - [ ] Returns accepted amount
- [ ] unwindToEscrow:
  - [ ] Gets aToken balance for withdrawal
  - [ ] Calls withdraw() correctly with `address(this)` as recipient
  - [ ] Transfers back to `msg.sender` (escrow)
  - [ ] Calculates yield as: received - principalDeposited
  - [ ] Returns (principal, yield) tuple
  - [ ] Deletes position on success
- [ ] emergencyUnwind:
  - [ ] Attempts withdrawal on aToken balance
  - [ ] Transfers back to escrow
  - [ ] **REVERTS if out == 0** (strict semantics)
  - [ ] Emits EmergencyUnwindExecuted event
- [ ] canHandle: Simple check (returns true for now, can be enhanced)

**Safety Critical:**
- [ ] Uses IAavePool interface (not trying to call non-existent methods)
- [ ] No lingering allowances
- [ ] Proper error messages

### 3. BaseEscrow Integration
**File:** `contracts/core/BaseEscrow.sol`

**Storage Added:**
- [ ] v25YieldModules mapping (workflowId -> module address)
- [ ] v25YieldPrincipals mapping (workflowId -> accepted principal)
- [ ] Located separate from existing yield system

**Import Added:**
- [ ] `import '../interfaces/IYieldModule.sol';`

**Method: _handleYieldModuleUnwind**
- [ ] Takes (workflowId, token, amount) → returns (principalOut, yieldOut)
- [ ] Early returns if module not set or yieldPrincipal == 0
- [ ] **INVARIANT 5: Captures balBefore**
- [ ] **Try/catch on unwindToEscrow:**
  - [ ] Captures balAfter
  - [ ] Calculates received = balAfter - balBefore (delta check)
  - [ ] **Requires: received >= principal + yield**
  - [ ] Returns (principal, yield)
- [ ] **Try/catch emergency path:**
  - [ ] Calls emergencyUnwind
  - [ ] Checks: recovered >= yieldPrincipal
  - [ ] If yes: returns (recovered, 0)
  - [ ] If no: **REVERTS** with "YieldModulePartialRecovery: Principal lost"
  - [ ] If emerge fails: **REVERTS** with "YieldModuleUnwindAndRecoveryFailed"

**Safety Critical:**
- [ ] No partial recovery silently accepted (reverts if recovered < principal)
- [ ] Balance delta proves module returned funds (not pre-existing)
- [ ] emergencyUnwind never silently fails (reverts if emergency also fails)

---

## What's NOT Changed (Backward Compatibility)

- [ ] ModuleSnapshot struct untouched (existing code not affected)
- [ ] Existing YieldOps system untouched
- [ ] No breaking changes to escrow creation/release flow
- [ ] EscrowViewContract unpacking corrected (same struct size)

---

## What to Test (Session 2)

1. **Happy Path:**
   - Create escrow with v2.5 module
   - initializeYield: transfers principal, receives accepted
   - unwindToEscrow: withdraws successfully, calculates yield
   - Verify delta check passes

2. **Emergency Path:**
   - Create escrow with v2.5 module
   - initializeYield succeeds
   - unwindToEscrow fails (mock Aave error)
   - emergencyUnwind called, recovers full principal
   - Verify funds returned

3. **Fund Loss Prevention:**
   - Create escrow with v2.5 module
   - initializeYield succeeds
   - unwindToEscrow fails
   - emergencyUnwind can only recover 50% of principal
   - **MUST REVERT** (don't proceed with shortfall)

4. **Fee-on-Transfer Tokens:**
   - Create escrow with fee-on-transfer token
   - initializeYield: transfers 100, only 99 gets deposited
   - Module stores principalDeposited = 99
   - unwindToEscrow: withdraws and calculates yield correctly (ignores lost fee)

---

## Architecture Alignment Check

**v2.5 Hardened Features Present:**
- [ ] INVARIANT 1: No silent fund loss ✓ (revert if emergency fails)
- [ ] INVARIANT 2: Module can't redirect ✓ (onlyEscrow, return to msg.sender)
- [ ] INVARIANT 3: Distribution canonical ✓ (escrow distributes, module doesn't)
- [ ] INVARIANT 4: Principal accounting ✓ (store accepted, not requested)
- [ ] INVARIANT 5: Balance provable ✓ (delta check)
- [ ] INVARIANT 6: Emergency strict ✓ (return > 0 or revert)

**v2.5 Critical Fixes Applied:**
- [ ] Principal stored as `principalDeposited` (not `shares`)
- [ ] Balance checked as delta (not absolute)
- [ ] emergencyUnwind never returns 0 (strict semantics)
- [ ] Partial recovery rejected (reverts)
- [ ] Fund transfer is push model (no approve/pull)
- [ ] Protocol scope marked sync-only (Lido removed from v2)

---

## Sign-Off

Reviewed by: _________________  Date: _________________

Code Quality: ___/5
Safety: ___/5
Architecture Alignment: ___/5

Notes:
_____________________________________________________________________________
_____________________________________________________________________________
