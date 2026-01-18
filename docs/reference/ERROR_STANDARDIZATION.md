# Error Standardization Document

**Date:** 2025-01-27  
**Status:** Partially Implemented  
**Scope:** Entire codebase error handling standardization

**Last Updated:** 2026-01-16  
**Implementation Progress:**
- ✅ Phase 1 (Critical Fixes): All single-letter errors replaced (4/4)
- 🔄 Phase 2 (High Priority): Partial - BaseEscrow.sol in progress
- ⏳ Phase 3 (Medium Priority): Pending
- ⏳ Phase 4 (Low Priority): Pending

---

## Executive Summary

This document analyzes current error handling patterns across the entire repository and proposes a standardized approach using Solidity custom errors. The standardization will improve gas efficiency, provide better error messages, and ensure consistency across all contracts.

**Key Benefits:**

- **Gas Savings:** Custom errors save ~50-200 gas per revert compared to string-based errors
- **Better UX:** Structured error data with typed parameters
- **Consistency:** Uniform error handling across all contracts
- **Type Safety:** Compile-time checking of error parameters

---

## Current State Analysis

### Error Pattern Distribution

#### 1. Custom Errors (Preferred Pattern)

**Location:** `BaseEscrow.sol`, `EscrowTypes.sol`, `AaveYieldGenerationModule.sol`, `AaveYieldModule.sol`

**Examples:**

```solidity
// BaseEscrow.sol
error InsufficientTokenBalance(uint256 balance, uint256 required);
error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
error NotAuthorizedResolver(address caller, address expectedResolver);

// EscrowTypes.sol
error InvalidAddress(string reason, address addr);
error InvalidAmount(string reason);
error ArrayLengthMismatch(uint256 expectedLength, uint256 actualLength);

// AaveYieldGenerationModule.sol
error AavePoolNotConfigured();
error TokenNotSupportedByAave(address token);
error InvalidATokenAddress(address token, address aToken);
error InvalidPoolAddress(address pool);
error PoolAddressIsNotContract(address pool);
error PoolProviderCallFailed(address provider);
```

**Coverage:** ~15% of error cases

---

#### 2. require() with Descriptive Strings

**Location:** `DecentralizedResolutionModule.sol`, `KlerosArbitrableProxy.sol`, libraries, modules

**Examples:**

```solidity
// DecentralizedResolutionModule.sol
require(isApprovedSeniorResolver[_msgSender()], "Not senior resolver");
require(resolver != address(0) && !isApprovedResolver[resolver], "Invalid resolver");
require(level <= MAX_ROUND, "Invalid level");
require(dm.resolverAtRound[0] == address(0), "Already initialized");

// KlerosArbitrableProxy.sol
require(_arbitrator != address(0), "Invalid arbitrator");
require(workflowToKlerosDispute[workflowId] == 0, "Dispute already exists");
require(msg.value >= cost, "Insufficient arbitration fee");

// Libraries
require(input.resolvers.length > 0, "No resolvers");
require(haircutBps <= BASIS_POINTS, "Haircut > 100%");
```

**Coverage:** ~60% of error cases

---

#### 3. require() with Single-Letter Strings (Critical Issue)

**Location:** `BaseEscrow.sol`, `DecentralizedResolutionModule.sol`

**Examples:**

```solidity
// BaseEscrow.sol
require(ts > 0 && block.timestamp >= ts + timeoutConfig.maxDisputeDuration, "T");
require(s, "F");
require(s, "R");

// DecentralizedResolutionModule.sol
require(t > 0 && t <= MAX_DISPUTE_TIMEOUT, "T");
```

**Coverage:** ~5% of error cases (but critical - completely unreadable)

**Impact:** These provide zero debugging value and must be fixed immediately.

---

#### 4. revert() with Strings

**Location:** `PaymentCalculationLibraryV1.sol`, `KlerosArbitrableProxy.sol`, mocks

**Examples:**

```solidity
// PaymentCalculationLibraryV1.sol
revert("Invalid level");

// KlerosArbitrableProxy.sol
revert("No escalation from Kleros");

// MockKlerosArbitrator.sol
revert("Appeal not implemented in mock");
```

**Coverage:** ~10% of error cases

---

#### 5. Mixed Patterns in Same Contract

**Location:** Multiple contracts use both custom errors and require() strings

**Example:** `BaseEscrow.sol` uses:

- Custom errors for most cases
- `require()` with strings for some validations
- Single-letter strings for some cases

---

## Proposed Standardized Approach

### Principle: Use Custom Errors Everywhere

**Rationale:**

1. **Gas Efficiency:** Custom errors are ~50-200 gas cheaper per revert
2. **Type Safety:** Compile-time checking of parameters
3. **Better Debugging:** Structured data with typed parameters
4. **ABI Compatibility:** Errors are part of the ABI and can be decoded off-chain
5. **Consistency:** Single pattern across entire codebase

---

### Error Naming Convention

#### Pattern: `[Category][SpecificIssue]`

**Categories:**

- `Invalid*` - Invalid input/state (e.g., `InvalidAddress`, `InvalidAmount`)
- `Not*` - Authorization/access issues (e.g., `NotAuthorized`, `NotSender`)
- `*Exceeded` - Limit violations (e.g., `CapExceeded`, `AmountExceeded`)
- `*NotConfigured` - Missing configuration (e.g., `PoolNotConfigured`)
- `*Failed` - Operation failures (e.g., `TransferFailed`, `CallFailed`)
- `*Already*` - State conflicts (e.g., `AlreadyInitialized`, `AlreadyResolved`)
- `*Required` - Missing requirements (e.g., `FeeRequired`, `BondRequired`)

**Examples:**

```solidity
// Good
error InvalidAddress(address addr);
error NotAuthorizedResolver(address caller, address expected);
error CapExceeded(address token, uint256 requested, uint256 cap);
error PoolNotConfigured();
error TransferFailed(address token, address to, uint256 amount);
error AlreadyInitialized(uint256 workflowId);
error FeeRequired(uint256 required, uint256 provided);

// Bad (too generic)
error Error();
error Invalid();
error Failed();
```

---

### Error Parameter Guidelines

1. **Include Context:** Always include relevant identifiers

   ```solidity
   // Good
   error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
   error NotSender(uint256 workflowId, address caller, address expectedSender);

   // Bad (missing context)
   error InvalidId();
   error NotAuthorized();
   ```

2. **Order Parameters Logically:** Most specific → least specific

   ```solidity
   // Good
   error InsufficientBalance(address token, address account, uint256 balance, uint256 required);

   // Bad (wrong order)
   error InsufficientBalance(uint256 required, uint256 balance, address account, address token);
   ```

3. **Use Appropriate Types:** Prefer specific types over generic

   ```solidity
   // Good
   error InvalidEscrowState(uint256 workflowId, EscrowState current, EscrowState required);

   // Bad (using string for enum)
   error InvalidEscrowState(uint256 workflowId, string current, string required);
   ```

---

### Error Organization

#### Centralized Error Definitions

**Proposal:** Create shared error libraries by category

**Structure:**

```
contracts/errors/
  ├── AccessControlErrors.sol      // Authorization errors
  ├── ValidationErrors.sol         // Input validation errors
  ├── StateErrors.sol              // State transition errors
  ├── ModuleErrors.sol             // Module-specific errors
  ├── EscrowErrors.sol             // Escrow-specific errors
  └── ResolutionErrors.sol         // Resolution-specific errors
```

**Example:**

```solidity
// contracts/errors/ValidationErrors.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @title ValidationErrors
/// @notice Shared validation error definitions
library ValidationErrors {
  error InvalidAddress(address addr);
  error InvalidAddressWithReason(string reason, address addr);
  error InvalidAmount(uint256 amount);
  error InvalidAmountWithReason(string reason, uint256 amount);
  error ArrayLengthMismatch(uint256 expectedLength, uint256 actualLength);
  error OutOfBounds(string field, uint256 value, uint256 min, uint256 max);
  error ZeroValue(string field);
}
```

**Benefits:**

- Single source of truth for common errors
- Easy to import and use
- Consistent naming across contracts
- Easier to maintain and update

---

### Migration Strategy

#### Phase 1: Critical Fixes (Immediate)

**Priority:** HIGH  
**Timeline:** 1-2 days

**Tasks:**

1. Replace all single-letter strings with custom errors
   - `"T"` → `error InvalidTimeout(uint256 timeout, uint256 min, uint256 max);`
   - `"F"` → `error TransferFailed(address token, address to, uint256 amount);`
   - `"R"` → `error RefundFailed(address recipient, uint256 amount);`

2. Files to fix:
   - `contracts/core/BaseEscrow.sol` (3 instances)
   - `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol` (1 instance)

---

#### Phase 2: Core Contracts (High Priority)

**Priority:** HIGH  
**Timeline:** 3-5 days

**Tasks:**

1. Create error library structure
2. Migrate core contracts:
   - `BaseEscrow.sol` - Complete migration
   - `EscrowVault.sol` - Complete migration
   - `EscrowableERC20.sol` - Complete migration
   - `YieldOps.sol` - Complete migration
   - `DisputeOps.sol` - Complete migration

3. Create shared error libraries:
   - `ValidationErrors.sol`
   - `AccessControlErrors.sol`
   - `EscrowErrors.sol`

---

#### Phase 3: Modules (Medium Priority)

**Priority:** MEDIUM  
**Timeline:** 5-7 days

**Tasks:**

1. Migrate all modules:
   - `AaveYieldGenerationModule.sol` (already partially done)
   - `AaveYieldModule.sol` (already partially done)
   - `DefaultReleaseStrategy.sol`
   - `DefaultResolutionModule.sol`
   - All other modules

2. Create module-specific error libraries:
   - `ModuleErrors.sol`
   - `YieldErrors.sol`

---

#### Phase 4: Decentralized Resolution Module (Medium Priority)

**Priority:** MEDIUM  
**Timeline:** 7-10 days

**Tasks:**

1. Migrate `DecentralizedResolutionModule.sol` (largest file, ~100+ require statements)
2. Migrate related contracts:
   - `ResolverIncentiveModuleV1.sol`
   - `ResolverIncentiveModuleV2.sol`
   - `ResolverStakingModuleV1.sol`
   - `ResolverSlashingModuleV1.sol`
   - `InsurancePoolVault.sol`

3. Create resolution-specific error library:
   - `ResolutionErrors.sol`

---

#### Phase 5: Libraries (Lower Priority)

**Priority:** LOW  
**Timeline:** 3-5 days

**Tasks:**

1. Migrate all libraries:
   - `SettingsValidationLibrary.sol`
   - `PaymentCalculationLibraryV1.sol`
   - `ResolutionAnalytics.sol`
   - `BondValuationLibrary.sol`
   - All other libraries

**Note:** Libraries can use `revert` with custom errors, but cannot define them. Errors must be defined in contracts or shared error libraries.

---

#### Phase 6: Arbitration & Other Contracts (Lower Priority)

**Priority:** LOW  
**Timeline:** 2-3 days

**Tasks:**

1. Migrate arbitration contracts:
   - `KlerosArbitrableProxy.sol`
   - `MockKlerosArbitrator.sol`

2. Migrate other contracts:
   - `EvidenceModuleV1.sol`
   - Governance contracts

---

#### Phase 7: Mocks & Tests (Lowest Priority)

**Priority:** LOWEST  
**Timeline:** 1-2 days

**Tasks:**

1. Migrate mock contracts (optional - mocks can keep simple patterns)
2. Update test files to use new error names

---

## Implementation Details

### Error Library Structure

```solidity
// contracts/errors/ValidationErrors.sol
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

```solidity
// contracts/errors/AccessControlErrors.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @title AccessControlErrors
/// @notice Shared access control error definitions
library AccessControlErrors {
  error NotAuthorized(address caller, bytes32 requiredRole);
  error NotOwner(address caller, address owner);
  error NotResolver(address caller, address expectedResolver);
  error NotSeniorResolver(address caller);
  error NotEscrowContract(address caller);
  error NotFeeAddress(address caller, address expectedFeeAddress);
  error NotParticipant(uint256 workflowId, address caller, address sender, address recipient);
  error NotSender(uint256 workflowId, address caller, address expectedSender);
  error NotRecipient(uint256 workflowId, address caller, address expectedRecipient);
}
```

```solidity
// contracts/errors/EscrowErrors.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/// @title EscrowErrors
/// @notice Shared escrow-specific error definitions
library EscrowErrors {
  error InvalidWorkflowId(uint256 workflowId, uint256 maxWorkflowId);
  error TransferNotPending(uint256 workflowId, EscrowState currentStatus);
  error TransferNotInDispute(uint256 workflowId, EscrowState currentStatus);
  error TransferAlreadyCancelled(uint256 workflowId);
  error TransferAlreadyReleased(uint256 workflowId);
  error TransferAlreadyResolved(uint256 workflowId);
  error InsufficientTokenBalance(uint256 balance, uint256 required);
  error AmountExceedsTransfer(uint256 workflowId, uint256 requestedAmount, uint256 availableAmount);
  error InvalidEscrowFee(uint256 fee, uint256 maxFee);
  error NoFeesToWithdraw(address token, uint256 availableFees);
  error InvalidAutoTime(string reason, uint256 providedTime, uint256 currentTime);
  error CannotSetBothAutoTimes(uint256 autoReleaseTime, uint256 autoCancelTime);
  error AutoTimeExceedsMaxLimit(uint256 providedTime, uint256 maxTime);
}
```

```solidity
// contracts/errors/ModuleErrors.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @title ModuleErrors
/// @notice Shared module-specific error definitions
library ModuleErrors {
  error ModuleNotConfigured(string moduleType);
  error ModuleNotReady(uint256 currentTime, uint256 eta);
  error ModuleCallFailed(string moduleType, address module);
  error ModuleReturnedZeroAddress(string moduleType);
  error InvalidModuleAddress(address module, string reason);
  error ModuleNotRegistered(address module);
}
```

```solidity
// contracts/errors/ResolutionErrors.sol
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/// @title ResolutionErrors
/// @notice Shared resolution-specific error definitions
library ResolutionErrors {
  error InvalidResolver(address resolver, string reason);
  error ResolverNotActive(address resolver);
  error ResolverNotAcceptingDisputes(address resolver);
  error ResolverCapacityExceeded(address resolver, uint256 current, uint256 max);
  error InvalidLevel(uint8 level, uint8 maxLevel);
  error AlreadyInitialized(uint256 workflowId);
  error NoPendingChange();
  error InvalidTimeout(uint256 timeout, uint256 min, uint256 max);
  error InvalidAlpha(uint256 alphaBps, uint256 max);
  error InvalidThreshold(uint256 threshold, uint256 max);
  error InvalidTimeoutRate(uint256 rate, uint256 max);
  error InvalidResolveDeadline(uint256 deadline, uint256 max);
  error DisputeAlreadyExists(uint256 workflowId);
  error DisputeDoesNotExist(uint256 workflowId);
  error DisputeAlreadyResolved(uint256 workflowId);
  error InsufficientArbitrationFee(uint256 provided, uint256 required);
  error OnlyArbitratorCanRule(address caller, address arbitrator);
}
```

---

### Migration Example

#### Before (require with string):

```solidity
function setDisputeTimeout(uint256 t) external onlyRole(ROLE_TIMELOCK) {
  require(t > 0 && t <= MAX_DISPUTE_TIMEOUT, 'T');
  disputeTimeout = t;
}
```

#### After (custom error):

```solidity
import '../errors/ResolutionErrors.sol';

function setDisputeTimeout(uint256 t) external onlyRole(ROLE_TIMELOCK) {
  if (t == 0 || t > MAX_DISPUTE_TIMEOUT) {
    revert ResolutionErrors.InvalidTimeout(t, 1, MAX_DISPUTE_TIMEOUT);
  }
  disputeTimeout = t;
}
```

#### Before (require with descriptive string):

```solidity
require(isApprovedSeniorResolver[_msgSender()], "Not senior resolver");
```

#### After (custom error):

```solidity
import "../errors/AccessControlErrors.sol";

if (!isApprovedSeniorResolver[_msgSender()]) {
    revert AccessControlErrors.NotSeniorResolver(_msgSender());
}
```

---

## Testing Considerations

### Test Updates Required

1. **Update error assertions:**

   ```typescript
   // Before
   await expect(tx).to.be.revertedWith('Not senior resolver');

   // After
   await expect(tx).to.be.revertedWithCustomError(contract, 'NotSeniorResolver');
   ```

2. **Update error parameter checks:**

   ```typescript
   // Before
   await expect(tx).to.be.revertedWith('Invalid timeout');

   // After
   await expect(tx)
     .to.be.revertedWithCustomError(contract, 'InvalidTimeout')
     .withArgs(0, 1, MAX_DISPUTE_TIMEOUT);
   ```

3. **Files to update:**
   - All test files that check for specific error messages
   - Integration tests
   - Foundry tests (use `vm.expectRevert` with custom errors)

---

## Gas Impact Analysis

### Estimated Gas Savings

**Per Revert:**

- Custom error: ~50-200 gas saved vs string-based error
- Custom error with parameters: ~100-300 gas saved vs string with parameters

**Total Impact (estimated):**

- ~100-200 error cases across codebase
- Average savings: ~150 gas per revert
- **Total potential savings: ~15,000-30,000 gas** (if all errors triggered)

**Note:** Gas savings are realized only when errors are triggered. However, the code size reduction from removing string literals also saves deployment gas.

---

## Breaking Changes

### ABI Compatibility

**Impact:** Custom errors are part of the ABI. Changing error signatures is a breaking change.

**Mitigation:**

1. Keep old error names during transition period (if needed)
2. Document all error changes in release notes
3. Update off-chain tooling that parses errors

**Recommendation:** Complete migration before mainnet deployment to avoid ABI changes post-deployment.

---

## Rollout Plan

### Week 1: Foundation

- [ ] Create error library structure
- [ ] Define all shared errors
- [ ] Fix critical single-letter strings (Phase 1)

### Week 2: Core Contracts

- [ ] Migrate BaseEscrow
- [ ] Migrate EscrowVault
- [ ] Migrate EscrowableERC20
- [ ] Migrate YieldOps/DisputeOps

### Week 3: Modules

- [ ] Migrate all yield modules
- [ ] Migrate resolution modules
- [ ] Migrate release strategies

### Week 4: Decentralized Resolution

- [ ] Migrate DecentralizedResolutionModule
- [ ] Migrate incentive modules
- [ ] Migrate staking/slashing modules

### Week 5: Libraries & Remaining

- [ ] Migrate all libraries
- [ ] Migrate arbitration contracts
- [ ] Update all tests

---

## Success Criteria

1. ✅ **Zero single-letter error strings** in codebase
2. ✅ **100% custom errors** for all user-facing errors
3. ✅ **Consistent naming** across all contracts
4. ✅ **All tests updated** to use new error names
5. ✅ **Documentation updated** with error reference
6. ✅ **Gas savings verified** via gas reports

---

## Maintenance Guidelines

### Adding New Errors

1. **Check if error exists** in shared libraries first
2. **Use appropriate library** (ValidationErrors, AccessControlErrors, etc.)
3. **Follow naming convention** (`[Category][SpecificIssue]`)
4. **Include context parameters** (workflowId, addresses, amounts, etc.)
5. **Document in NatSpec** if error is public-facing

### Error Documentation

Create `docs/ERROR_REFERENCE.md` with:

- Complete list of all errors
- Error parameters and meanings
- When each error is triggered
- Example usage

---

## Appendix: Error Inventory

### Current Error Count by Pattern

| Pattern                | Count    | Files Affected |
| ---------------------- | -------- | -------------- |
| Custom Errors          | ~50      | 7 files        |
| require() with strings | ~150     | 20+ files      |
| Single-letter strings  | 4        | 2 files        |
| revert() with strings  | ~10      | 5 files        |
| **Total**              | **~214** | **30+ files**  |

### Files Requiring Migration

#### High Priority (Core)

- `contracts/core/BaseEscrow.sol` - Mixed (custom errors + requires)
- `contracts/core/EscrowVault.sol` - Mostly custom errors
- `contracts/core/EscrowableERC20.sol` - Custom errors
- `contracts/YieldOps.sol` - require() strings
- `contracts/DisputeOps.sol` - require() strings

#### Medium Priority (Modules)

- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol` - Many require() strings
- `contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol` - require() strings
- `contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol` - require() strings
- `contracts/modules/AaveYieldGenerationModule.sol` - Mostly custom errors (good)
- `contracts/modules/AaveYieldModule.sol` - Mixed

#### Lower Priority (Libraries)

- `contracts/libraries/SettingsValidationLibrary.sol` - Custom errors (good)
- `contracts/libraries/PaymentCalculationLibraryV1.sol` - require() strings
- `contracts/libraries/ResolutionAnalytics.sol` - require() strings
- `contracts/libraries/BondValuationLibrary.sol` - require() strings

---

## Best Practices for Standardization

### Core Principles

1. **Always use custom errors over string literals** in `require()` or `revert()` for better gas efficiency and clarity.
   - Custom errors save ~50-200 gas per revert
   - Provide structured, typed error data
   - Enable better off-chain error parsing

2. **Validate inputs with `require()` before executing logic.**
   - Check all external inputs at function entry
   - Validate state transitions before execution
   - Fail fast with clear error messages

3. **Use `assert()` only for internal logic bugs, not for user errors.**
   - `assert()` consumes all gas (should never fail in production)
   - Use for invariants that should never be violated
   - Use `require()` for user input validation

4. **Implement comprehensive testing** using tools like Foundry, Hardhat, or Truffle to cover all error paths.
   - Test every error condition
   - Verify error parameters are correct
   - Test error handling in integration scenarios

5. **Perform security audits before deployment**, especially for contracts handling significant value.
   - Review all error conditions
   - Ensure no error paths allow unexpected behavior
   - Verify error messages don't leak sensitive information

6. **Follow the OpenZeppelin style guide** and use well-audited libraries.
   - Adopt proven patterns from OpenZeppelin contracts
   - Use SafeMath for older Solidity versions (< 0.8.0)
   - Leverage OpenZeppelin's AccessControl, ReentrancyGuard, etc.

### Error Handling Guidelines

- **Fail Fast:** Validate and revert early in function execution
- **Clear Messages:** Error names should clearly describe what went wrong
- **Context-Rich:** Include relevant parameters (addresses, amounts, IDs) in errors
- **Consistent Naming:** Follow the `[Category][SpecificIssue]` pattern
- **Type Safety:** Use appropriate types (address, uint256, enums) instead of strings where possible

### Security Considerations

- **No Information Leakage:** Don't include sensitive data in error messages
- **Access Control:** Always check permissions before state changes
- **Reentrancy:** Use ReentrancyGuard for functions that modify state and call external contracts
- **Input Validation:** Validate all external inputs, especially addresses and amounts
- **State Consistency:** Ensure state transitions are atomic and consistent

---

## References

### Official Documentation

- [Solidity Custom Errors Documentation](https://docs.soliditylang.org/en/v0.8.19/contracts.html#errors)
- [Gas Optimization: Custom Errors vs require()](https://blog.soliditylang.org/2021/04/21/custom-errors/)

### Security Best Practices

- [CertiK: Top 10 DeFi Security Best Practices](https://www.certik.com/resources/blog/top-10-defi-security-best-practices)
- [Coddy: Solidity Error Handling](https://ref.coddy.tech/solidity/solidity-error-handling)

### Reference Implementations

- [OpenZeppelin Error Patterns](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/ReentrancyGuard.sol)
- [Aave Protocol Contracts](https://github.com/aave)

---

**Document Version:** 1.1  
**Last Updated:** 2025-01-27  
**Next Review:** After Phase 1 completion
