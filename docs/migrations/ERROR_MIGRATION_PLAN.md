# Error Standardization Migration Plan

**Date:** 2025-01-27  
**Status:** Ready for Execution  
**Target:** Complete migration of all error handling to custom errors  
**Executor:** LLM (Claude Haiku or similar)

---

## Overview

This document provides a step-by-step migration plan for standardizing all error handling across the codebase. Each task is designed to be executed independently by an LLM, with clear acceptance criteria and verification steps.

**Total Estimated Tasks:** 50+  
**Estimated Time:** 3-4 weeks  
**Priority Order:** Critical → High → Medium → Low

---

## Prerequisites

Before starting migration:

1. ✅ Read `docs/ERROR_STANDARDIZATION.md` for context
2. ✅ Understand custom error syntax and benefits
3. ✅ Review existing custom errors in `BaseEscrow.sol` and `EscrowTypes.sol`
4. ✅ Set up development environment (Hardhat/Foundry)

---

## Phase 1: Critical Fixes (IMMEDIATE - Day 1)

### Task 1.1: Fix Single-Letter Error Strings in BaseEscrow.sol

**File:** `contracts/core/BaseEscrow.sol`  
**Priority:** CRITICAL  
**Estimated Time:** 30 minutes

**Current Issues:**

- Line ~499: `require(ts > 0 && block.timestamp >= ts + timeoutConfig.maxDisputeDuration, "T");`
- Line ~592: `require(s, "F");`
- Line ~609: `require(s, "R");`

**Action:**

1. Create appropriate custom errors in `BaseEscrow.sol`:

   ```solidity
   error InvalidTimeout(uint256 timestamp, uint256 currentTime, uint256 maxDuration);
   error TransferFailed(address token, address to, uint256 amount);
   error RefundFailed(address recipient, uint256 amount);
   ```

2. Replace all three instances with custom errors:

   ```solidity
   // Before
   require(ts > 0 && block.timestamp >= ts + timeoutConfig.maxDisputeDuration, "T");

   // After
   if (ts == 0 || block.timestamp < ts + timeoutConfig.maxDisputeDuration) {
       revert InvalidTimeout(ts, block.timestamp, timeoutConfig.maxDisputeDuration);
   }
   ```

**Verification:**

- [ ] All three single-letter strings replaced
- [ ] Code compiles without errors
- [ ] Error names are descriptive
- [ ] Error parameters include relevant context

---

### Task 1.2: Fix Single-Letter Error String in DecentralizedResolutionModule.sol

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`  
**Priority:** CRITICAL  
**Estimated Time:** 15 minutes

**Current Issue:**

- Line ~700: `require(t > 0 && t <= MAX_DISPUTE_TIMEOUT, "T");`

**Action:**

1. Add custom error to file (or import from error library):

   ```solidity
   error InvalidDisputeTimeout(uint256 timeout, uint256 min, uint256 max);
   ```

2. Replace the require:

   ```solidity
   // Before
   require(t > 0 && t <= MAX_DISPUTE_TIMEOUT, "T");

   // After
   if (t == 0 || t > MAX_DISPUTE_TIMEOUT) {
       revert InvalidDisputeTimeout(t, 1, MAX_DISPUTE_TIMEOUT);
   }
   ```

**Verification:**

- [ ] Single-letter string replaced
- [ ] Code compiles
- [ ] Error includes min/max values

---

## Phase 2: Create Error Libraries (Day 1-2)

### Task 2.1: Create ValidationErrors Library

**File:** `contracts/errors/ValidationErrors.sol` (NEW FILE)  
**Priority:** HIGH  
**Estimated Time:** 1 hour

**Action:**

1. Create directory: `contracts/errors/`
2. Create file with all validation errors:

   ```solidity
   // SPDX-License-Identifier: Apache-2.0
   pragma solidity ^0.8.33;

   /// @title ValidationErrors
   /// @notice Shared validation error definitions
   library ValidationErrors {
     // Address validation
     error InvalidAddress(address addr);
     error InvalidAddressWithReason(string reason, address addr);
     error ZeroAddress(string field);

     // Amount validation
     error InvalidAmount(uint256 amount);
     error InvalidAmountWithReason(string reason, uint256 amount);
     error ZeroAmount(string field);
     error AmountExceeded(uint256 requested, uint256 max);

     // Array validation
     error ArrayLengthMismatch(uint256 expectedLength, uint256 actualLength);
     error EmptyArray(string field);

     // Range validation
     error OutOfBounds(string field, uint256 value, uint256 min, uint256 max);
     error BelowMinimum(string field, uint256 value, uint256 minimum);
     error AboveMaximum(string field, uint256 value, uint256 maximum);

     // Time validation
     error InvalidTimestamp(uint256 timestamp, uint256 currentTime);
     error InvalidDuration(uint256 duration, uint256 min, uint256 max);
   }
   ```

**Verification:**

- [ ] File created in correct location
- [ ] All errors defined
- [ ] Code compiles
- [ ] NatSpec comments added

---

### Task 2.2: Create AccessControlErrors Library

**File:** `contracts/errors/AccessControlErrors.sol` (NEW FILE)  
**Priority:** HIGH  
**Estimated Time:** 45 minutes

**Action:**

1. Create file with access control errors (see ERROR_STANDARDIZATION.md for full list)
2. Include errors for:
   - Authorization failures
   - Role-based access
   - Participant validation
   - Escrow contract registration

**Verification:**

- [ ] File created
- [ ] All access control errors defined
- [ ] Code compiles

---

### Task 2.3: Create EscrowErrors Library

**File:** `contracts/errors/EscrowErrors.sol` (NEW FILE)  
**Priority:** HIGH  
**Estimated Time:** 45 minutes

**Action:**

1. Create file with escrow-specific errors
2. Import `EscrowTypes.sol` for `EscrowState` enum
3. Include errors for workflow validation, state transitions, fees

**Verification:**

- [ ] File created
- [ ] EscrowTypes imported correctly
- [ ] All escrow errors defined
- [ ] Code compiles

---

### Task 2.4: Create ModuleErrors Library

**File:** `contracts/errors/ModuleErrors.sol` (NEW FILE)  
**Priority:** HIGH  
**Estimated Time:** 30 minutes

**Action:**

1. Create file with module-specific errors
2. Include errors for module configuration, calls, registration

**Verification:**

- [ ] File created
- [ ] All module errors defined
- [ ] Code compiles

---

### Task 2.5: Create ResolutionErrors Library

**File:** `contracts/errors/ResolutionErrors.sol` (NEW FILE)  
**Priority:** HIGH  
**Estimated Time:** 1 hour

**Action:**

1. Create file with resolution-specific errors
2. Include errors for:
   - Resolver validation
   - Dispute lifecycle
   - Escalation
   - Timeout configuration

**Verification:**

- [ ] File created
- [ ] All resolution errors defined
- [ ] Code compiles

---

## Phase 3: Migrate Core Contracts (Day 2-4)

### Task 3.1: Migrate BaseEscrow.sol - Part 1 (require() strings)

**File:** `contracts/core/BaseEscrow.sol`  
**Priority:** HIGH  
**Estimated Time:** 2 hours

**Action:**

1. Import error libraries at top of file
2. Find all `require()` statements with strings (grep for `require(`)
3. Replace each with appropriate custom error:
   - Line ~271: `require(duration >= 7 days && duration <= 365 days, "Invalid duration: must be 7-365 days");`
     → Use `ValidationErrors.InvalidDuration()`
   - Line ~282: `require(duration >= 1 days && duration <= 7 days, "Invalid duration: must be 1-7 days");`
     → Use `ValidationErrors.InvalidDuration()`

**Verification:**

- [ ] All require() strings replaced
- [ ] Appropriate error library imported
- [ ] Code compiles
- [ ] Error parameters match context

---

### Task 3.2: Migrate BaseEscrow.sol - Part 2 (consolidate existing errors)

**File:** `contracts/core/BaseEscrow.sol`  
**Priority:** HIGH  
**Estimated Time:** 1 hour

**Action:**

1. Review existing custom errors in file
2. Move common errors to error libraries (if not already there)
3. Update imports to use error libraries
4. Ensure no duplicate error definitions

**Verification:**

- [ ] Errors consolidated into libraries
- [ ] No duplicate definitions
- [ ] All imports correct
- [ ] Code compiles

---

### Task 3.3: Migrate YieldOps.sol

**File:** `contracts/YieldOps.sol`  
**Priority:** HIGH  
**Estimated Time:** 1 hour

**Current require() statements:**

- Line ~118: `require(msg.sender == address(this), "Internal only");`
- Line ~128: `require(success, "Distribution failed");`
- Line ~145: `require(to != address(0), "Invalid recipient");`
- Line ~149: `require(success, "Transfer failed");`

**Action:**

1. Import appropriate error libraries
2. Replace each require() with custom error
3. Use `AccessControlErrors` for access checks
4. Use `ValidationErrors` for address validation
5. Create specific errors for operation failures

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles
- [ ] Error names are descriptive

---

### Task 3.4: Migrate DisputeOps.sol

**File:** `contracts/DisputeOps.sol`  
**Priority:** HIGH  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with appropriate custom errors
3. Import error libraries as needed

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 3.5: Migrate EscrowVault.sol

**File:** `contracts/core/EscrowVault.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 30 minutes

**Action:**

1. Check for any remaining require() strings
2. Replace with custom errors
3. Ensure consistency with BaseEscrow

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 3.6: Migrate EscrowableERC20.sol

**File:** `contracts/core/EscrowableERC20.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 15 minutes

**Action:**

1. Check for any require() strings
2. Replace with custom errors
3. Ensure consistency

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

## Phase 4: Migrate Modules (Day 4-7)

### Task 4.1: Migrate AaveYieldModule.sol

**File:** `contracts/modules/AaveYieldModule.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with custom errors
3. Use existing error patterns from AaveYieldGenerationModule.sol as reference

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 4.2: Migrate DefaultReleaseStrategy.sol

**File:** `contracts/modules/DefaultReleaseStrategy.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 30 minutes

**Action:**

1. Find all require() statements
2. Replace with custom errors
3. Import error libraries

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 4.3: Migrate DefaultResolutionModule.sol

**File:** `contracts/core/modules/DefaultResolutionModule.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 30 minutes

**Action:**

1. Find all require() statements
2. Replace with custom errors
3. Import error libraries

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 4.4: Migrate TestYieldDistributionModule.sol

**File:** `contracts/modules/TestYieldDistributionModule.sol`  
**Priority:** LOW  
**Estimated Time:** 30 minutes

**Action:**

1. Find all require() statements
2. Replace with custom errors

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

## Phase 5: Migrate Decentralized Resolution Module (Day 7-12)

### Task 5.1: Migrate DecentralizedResolutionModule.sol - Part 1 (Modifiers)

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`  
**Priority:** HIGH  
**Estimated Time:** 1 hour

**Current Issues:**

- Line ~146: `require(isApprovedSeniorResolver[_msgSender()], "Not senior resolver");`
- Line ~147: `require(isApprovedResolver[_msgSender()] || isApprovedSeniorResolver[_msgSender()], "Not authorized resolver");`
- Line ~148: `require(registeredEscrowContracts[_msgSender()], "Not registered escrow contract");`

**Action:**

1. Replace modifier require() statements with custom errors
2. Use `AccessControlErrors` library
3. Update all modifiers

**Verification:**

- [ ] All modifier require() strings replaced
- [ ] Code compiles
- [ ] Modifiers still work correctly

---

### Task 5.2: Migrate DecentralizedResolutionModule.sol - Part 2 (Resolver Management)

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`  
**Priority:** HIGH  
**Estimated Time:** 2 hours

**Current Issues:**

- Lines ~182, ~195: Resolver validation require() statements
- Lines ~209, ~217: Resolver removal require() statements

**Action:**

1. Replace all resolver management require() statements
2. Use `ResolutionErrors` library
3. Ensure error parameters include resolver addresses

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles
- [ ] Error parameters are correct

---

### Task 5.3: Migrate DecentralizedResolutionModule.sol - Part 3 (Dispute Functions)

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`  
**Priority:** HIGH  
**Estimated Time:** 3 hours

**Action:**

1. Find all require() statements in dispute-related functions
2. Replace with custom errors from `ResolutionErrors`
3. Pay special attention to:
   - Dispute initialization
   - Escalation logic
   - Resolution recording
   - Finalization

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles
- [ ] Error context is preserved

---

### Task 5.4: Migrate DecentralizedResolutionModule.sol - Part 4 (Governance Functions)

**File:** `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements in governance functions
2. Replace with custom errors
3. Use appropriate error libraries

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 5.5: Migrate ResolverIncentiveModuleV1.sol

**File:** `contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 2 hours

**Current Issues:**

- Multiple require() statements for validation
- Line ~173: `require(registeredEscrowContracts[_msgSender()], "Not registered escrow contract");`
- Lines ~185-186: Constructor validation
- Lines ~227-228: Resolver validation
- Lines ~261-262: Token/amount validation
- Lines ~280-282: Amount validation
- Lines ~306-307: Token validation
- Lines ~311, ~332-333: Array validation
- Line ~336: Share validation

**Action:**

1. Replace all require() statements
2. Use appropriate error libraries
3. Ensure error parameters match context

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles
- [ ] Error parameters are correct

---

### Task 5.6: Migrate ResolverIncentiveModuleV2.sol

**File:** `contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with custom errors
3. Use error libraries

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 5.7: Migrate ResolverStakingModuleV1.sol

**File:** `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with custom errors

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 5.8: Migrate ResolverSlashingModuleV1.sol

**File:** `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with custom errors

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 5.9: Migrate InsurancePoolVault.sol

**File:** `contracts/decentralized-resolution-module/InsurancePoolVault.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with custom errors

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

## Phase 6: Migrate Libraries (Day 12-15)

### Task 6.1: Migrate PaymentCalculationLibraryV1.sol

**File:** `contracts/decentralized-resolution-module/PaymentCalculationLibraryV1.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Current Issues:**

- Lines ~30-31: Array and percentage validation
- Line ~35: Resolver address validation
- Line ~43: Weight validation
- Line ~152: `revert("Invalid level");`

**Action:**

1. Replace all require() and revert() statements
2. **Note:** Libraries cannot define errors, so errors must be imported from error libraries
3. Import appropriate error libraries

**Verification:**

- [ ] All require()/revert() strings replaced
- [ ] Errors imported from libraries
- [ ] Code compiles

---

### Task 6.2: Migrate ResolutionAnalytics.sol

**File:** `contracts/decentralized-resolution-module/ResolutionAnalytics.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 30 minutes

**Current Issues:**

- Line ~89: `require(outcome <= EMA_PRECISION, "Invalid outcome");`
- Line ~90: `require(alphaBps <= BASIS_POINTS_DENOMINATOR, "Invalid alpha");`

**Action:**

1. Replace require() statements
2. Import errors from libraries

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 6.3: Migrate BondValuationLibrary.sol

**File:** `contracts/decentralized-resolution-module/BondValuationLibrary.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Current Issues:**

- Multiple require() statements for validation (haircut, price, utilization)

**Action:**

1. Replace all require() statements
2. Import errors from libraries

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 6.4: Migrate Other Libraries

**Files:** All other library files  
**Priority:** LOW  
**Estimated Time:** 2 hours

**Action:**

1. Check each library for require()/revert() statements
2. Replace with imported custom errors
3. Ensure errors are imported from error libraries (libraries can't define errors)

**Verification:**

- [ ] All require()/revert() strings replaced
- [ ] Code compiles

---

## Phase 7: Migrate Remaining Contracts (Day 15-17)

### Task 7.1: Migrate KlerosArbitrableProxy.sol

**File:** `contracts/arbitration/KlerosArbitrableProxy.sol`  
**Priority:** MEDIUM  
**Estimated Time:** 1 hour

**Current Issues:**

- Multiple require() statements for validation

**Action:**

1. Replace all require() statements
2. Create arbitration-specific errors if needed

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 7.2: Migrate EvidenceModuleV1.sol

**File:** `contracts/evidence-module/EvidenceModuleV1.sol`  
**Priority:** LOW  
**Estimated Time:** 30 minutes

**Action:**

1. Find all require() statements
2. Replace with custom errors

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 7.3: Migrate Governance Contracts

**Files:** `contracts/governance/*.sol`  
**Priority:** LOW  
**Estimated Time:** 1 hour

**Action:**

1. Find all require() statements
2. Replace with custom errors

**Verification:**

- [ ] All require() strings replaced
- [ ] Code compiles

---

### Task 7.4: Migrate Mock Contracts (Optional)

**Files:** `contracts/mocks/*.sol`, `contracts/arbitration/mocks/*.sol`  
**Priority:** LOWEST  
**Estimated Time:** 1 hour

**Action:**

1. Find all require()/revert() statements
2. Replace with custom errors (optional - mocks can keep simple patterns)

**Verification:**

- [ ] All require()/revert() strings replaced (if doing)
- [ ] Code compiles

---

## Phase 8: Update Tests (Day 17-20)

### Task 8.1: Update Hardhat Tests

**Files:** `test/hardhat/**/*.ts`  
**Priority:** HIGH  
**Estimated Time:** 4 hours

**Action:**

1. Find all test assertions checking error messages
2. Update to use `revertedWithCustomError`:

   ```typescript
   // Before
   await expect(tx).to.be.revertedWith('Not senior resolver');

   // After
   await expect(tx).to.be.revertedWithCustomError(contract, 'NotSeniorResolver');
   ```

3. Update error parameter checks:
   ```typescript
   await expect(tx)
     .to.be.revertedWithCustomError(contract, 'InvalidTimeout')
     .withArgs(0, 1, MAX_DISPUTE_TIMEOUT);
   ```

**Verification:**

- [ ] All error assertions updated
- [ ] Tests pass
- [ ] Error parameters verified

---

### Task 8.2: Update Foundry Tests

**Files:** `test/foundry/**/*.sol`  
**Priority:** HIGH  
**Estimated Time:** 3 hours

**Action:**

1. Find all `vm.expectRevert()` calls
2. Update to use custom errors:

   ```solidity
   // Before
   vm.expectRevert("Not senior resolver");

   // After
   vm.expectRevert(AccessControlErrors.NotSeniorResolver.selector);
   ```

**Verification:**

- [ ] All error assertions updated
- [ ] Tests pass

---

## Phase 9: Verification & Documentation (Day 20-21)

### Task 9.1: Verify No String Literals Remain

**Priority:** HIGH  
**Estimated Time:** 1 hour

**Action:**

1. Run grep: `grep -r 'require(' contracts/ | grep '"'`
2. Run grep: `grep -r 'revert(' contracts/ | grep '"'`
3. Verify no string literals in require()/revert() remain
4. Check for single-letter strings specifically

**Verification:**

- [ ] No require() with strings found
- [ ] No revert() with strings found
- [ ] No single-letter strings found

---

### Task 9.2: Compile All Contracts

**Priority:** HIGH  
**Estimated Time:** 30 minutes

**Action:**

1. Run `npx hardhat compile`
2. Fix any compilation errors
3. Verify all contracts compile successfully

**Verification:**

- [ ] All contracts compile
- [ ] No compilation errors
- [ ] No warnings about missing errors

---

### Task 9.3: Run Test Suite

**Priority:** HIGH  
**Estimated Time:** 1 hour

**Action:**

1. Run Hardhat tests: `npm test` or `npx hardhat test`
2. Run Foundry tests: `forge test`
3. Fix any failing tests
4. Verify all tests pass

**Verification:**

- [ ] All Hardhat tests pass
- [ ] All Foundry tests pass
- [ ] No test failures related to errors

---

### Task 9.4: Create Error Reference Documentation

**File:** `docs/ERROR_REFERENCE.md` (NEW FILE)  
**Priority:** MEDIUM  
**Estimated Time:** 2 hours

**Action:**

1. Create comprehensive error reference
2. List all errors by category
3. Document parameters and when each error is triggered
4. Include examples

**Verification:**

- [ ] All errors documented
- [ ] Parameters explained
- [ ] Examples provided

---

## Success Criteria

### Must Complete

- [ ] Zero single-letter error strings in codebase
- [ ] Zero require() statements with string literals
- [ ] Zero revert() statements with string literals
- [ ] All contracts compile successfully
- [ ] All tests pass
- [ ] Error libraries created and used consistently

### Nice to Have

- [ ] Error reference documentation complete
- [ ] Gas savings verified via gas reports
- [ ] Code coverage maintained or improved

---

## Notes for LLM Executor

### General Guidelines

1. **One task at a time:** Complete each task fully before moving to next
2. **Test after each change:** Run compilation and tests after significant changes
3. **Preserve functionality:** Ensure logic remains the same, only error handling changes
4. **Use appropriate errors:** Match error to the validation being performed
5. **Include context:** Always include relevant parameters (addresses, amounts, IDs)

### Common Patterns

**Address Validation:**

```solidity
// Before
require(addr != address(0), "Invalid address");

// After
if (addr == address(0)) {
    revert ValidationErrors.ZeroAddress("parameterName");
}
```

**Amount Validation:**

```solidity
// Before
require(amount > 0, "Invalid amount");

// After
if (amount == 0) {
    revert ValidationErrors.ZeroAmount("amount");
}
```

**Access Control:**

```solidity
// Before
require(hasRole(ROLE, msg.sender), "Not authorized");

// After
if (!hasRole(ROLE, msg.sender)) {
    revert AccessControlErrors.NotAuthorized(msg.sender, ROLE);
}
```

**Range Validation:**

```solidity
// Before
require(value >= min && value <= max, "Out of range");

// After
if (value < min || value > max) {
    revert ValidationErrors.OutOfBounds("value", value, min, max);
}
```

### Error Library Import Pattern

```solidity
import '../errors/ValidationErrors.sol';
import '../errors/AccessControlErrors.sol';
// ... other error libraries as needed
```

### When to Create New Errors

- If error doesn't fit existing categories
- If error is specific to a module/contract
- If error needs unique parameters

### When to Use Existing Errors

- Always check error libraries first
- Reuse common errors (InvalidAddress, ZeroAmount, etc.)
- Maintain consistency across codebase

---

## Progress Tracking

Use this checklist to track progress:

### Phase 1: Critical Fixes

- [ ] Task 1.1: BaseEscrow single-letter strings
- [ ] Task 1.2: DecentralizedResolutionModule single-letter string

### Phase 2: Error Libraries

- [ ] Task 2.1: ValidationErrors
- [ ] Task 2.2: AccessControlErrors
- [ ] Task 2.3: EscrowErrors
- [ ] Task 2.4: ModuleErrors
- [ ] Task 2.5: ResolutionErrors

### Phase 3: Core Contracts

- [ ] Task 3.1: BaseEscrow require() strings
- [ ] Task 3.2: BaseEscrow consolidate errors
- [ ] Task 3.3: YieldOps
- [ ] Task 3.4: DisputeOps
- [ ] Task 3.5: EscrowVault
- [ ] Task 3.6: EscrowableERC20

### Phase 4: Modules

- [ ] Task 4.1: AaveYieldModule
- [ ] Task 4.2: DefaultReleaseStrategy
- [ ] Task 4.3: DefaultResolutionModule
- [ ] Task 4.4: TestYieldDistributionModule

### Phase 5: Decentralized Resolution

- [ ] Task 5.1: DecentralizedResolutionModule modifiers
- [ ] Task 5.2: DecentralizedResolutionModule resolver management
- [ ] Task 5.3: DecentralizedResolutionModule dispute functions
- [ ] Task 5.4: DecentralizedResolutionModule governance
- [ ] Task 5.5: ResolverIncentiveModuleV1
- [ ] Task 5.6: ResolverIncentiveModuleV2
- [ ] Task 5.7: ResolverStakingModuleV1
- [ ] Task 5.8: ResolverSlashingModuleV1
- [ ] Task 5.9: InsurancePoolVault

### Phase 6: Libraries

- [ ] Task 6.1: PaymentCalculationLibraryV1
- [ ] Task 6.2: ResolutionAnalytics
- [ ] Task 6.3: BondValuationLibrary
- [ ] Task 6.4: Other libraries

### Phase 7: Remaining Contracts

- [ ] Task 7.1: KlerosArbitrableProxy
- [ ] Task 7.2: EvidenceModuleV1
- [ ] Task 7.3: Governance contracts
- [ ] Task 7.4: Mock contracts (optional)

### Phase 8: Tests

- [ ] Task 8.1: Hardhat tests
- [ ] Task 8.2: Foundry tests

### Phase 9: Verification

- [ ] Task 9.1: Verify no string literals
- [ ] Task 9.2: Compile all contracts
- [ ] Task 9.3: Run test suite
- [ ] Task 9.4: Create error reference

---

**Document Version:** 1.0  
**Created:** 2025-01-27  
**For:** LLM Execution (Claude Haiku or similar)
