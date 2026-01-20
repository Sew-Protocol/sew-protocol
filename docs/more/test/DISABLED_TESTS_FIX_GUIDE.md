# Disabled Tests Fix Guide

## Overview

Four test files are currently disabled and need to be evaluated:

1. `EscrowVaultComprehensive.t.sol.disabled` - Comprehensive EscrowVault tests
2. `ResolverIncentiveModuleComprehensive.t.sol.disabled` - Comprehensive ResolverIncentiveModuleV1 tests
3. `PaymentBoundsChecking.t.sol.disabled` - **UNIQUE** - Security tests for malicious payment library validation
4. `EscalationFeeEnforcement.t.sol.disabled` - Escalation fee enforcement tests

## Analysis Summary

### ✅ **PaymentBoundsChecking.t.sol.disabled** - **KEEP AND FIX**

**Status**: **UNIQUE - NO EQUIVALENT TESTS EXIST**

**Why Keep**:

- Tests critical security boundaries for payment calculation library validation
- Tests malicious library attack vectors:
  - Payment exceeding total fees
  - Payment sum mismatch
  - Zero resolver address
  - Excessive single payment (>90% max)
  - Array length mismatch
- No equivalent tests found in current test suite
- Critical for security audit coverage

**What Needs Fixing**:

1. Update deployment pattern: `ResolverIncentiveModuleV1` now uses constructor (not proxy)
   - Change: `new ResolverIncentiveModuleV1()` → `new ResolverIncentiveModuleV1(owner, address(paymentLib))`
   - Remove: `ERC1967Proxy` deployment and `initialize()` call
   - Remove: `@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol` import
2. Function names are correct (verified):
   - `arePaymentsDistributed()` - exists ✓
   - `arePaymentsCalculated()` - exists ✓ (both functions exist)
   - `getClaimablePayment()` - exists ✓
3. Update role constants:
   - Verify `ROLE_TIMELOCK` usage (should already be correct)

**Priority**: **HIGH** - Security-critical tests

---

### ⚠️ **EscalationFeeEnforcement.t.sol.disabled** - **KEEP AND FIX**

**Status**: **PARTIALLY REDUNDANT** - Has placeholder in migrated folder but no actual tests

**Why Keep**:

- Tests escalation fee enforcement logic
- `test/foundry/migrated/EscalationFee.test.t.sol` is just a placeholder
- Tests important security feature: fee must be paid before escalation

**What Needs Fixing**:

1. Update deployment pattern: `DecentralizedResolutionModule` now uses constructor
   - Change: `new DecentralizedResolutionModule()` → `new DecentralizedResolutionModule(owner)`
   - Remove: `ERC1967Proxy` deployment and `initialize()` call
   - Remove: `@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol` import
2. Verify function signatures match current implementation:
   - `markEscalationFeePaid()`
   - `executeEscalation()`
   - `escalationFeePaid()`
3. Update role usage:
   - `ROLE_TIMELOCK` should already be correct

**Priority**: **MEDIUM** - Important but not unique

---

### ⚠️ **ResolverIncentiveModuleComprehensive.t.sol.disabled** - **EVALUATE**

**Status**: **PARTIALLY REDUNDANT** - Has hardhat tests but may have more coverage

**Why Consider Keeping**:

- More comprehensive than placeholder in `test/foundry/migrated/ResolverIncentiveModule.test.t.sol`
- Tests distribution logic, multiple resolvers, governance functions
- Hardhat tests exist but this may have additional coverage

**What Needs Fixing**:

1. Update deployment pattern: `ResolverIncentiveModuleV1` now uses constructor
   - Change: `new ResolverIncentiveModuleV1()` → `new ResolverIncentiveModuleV1(owner, address(paymentLib))`
   - Remove: `ERC1967Proxy` deployment and `initialize()` call
   - Remove: `@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol` import
2. Update function names if changed:
   - `arePaymentsCalculated()` → `arePaymentsDistributed()` (check current implementation)
   - `getClaimablePayment()` → verify current function name
3. Update role constants:
   - Verify `ROLE_TIMELOCK` and `ROLE_ESCROW_CONTRACT` usage

**Decision**: Compare with `test/hardhat/decentralized-resolution-module/ResolverIncentiveModule.test.ts` to see if this adds unique coverage. If yes, keep and fix. If redundant, delete.

**Priority**: **LOW-MEDIUM** - May be redundant with hardhat tests

---

### ❌ **EscrowVaultComprehensive.t.sol.disabled** - **LIKELY REDUNDANT**

**Status**: **REDUNDANT** - Has equivalent tests

**Why Likely Redundant**:

- `test/foundry/core/BaseEscrowComprehensive.t.sol` tests BaseEscrow (parent of EscrowVault)
- `test/hardhat/EscrowVault.test.ts` has EscrowVault tests
- `test/hardhat/CoreContractsCoverage.test.ts` has EscrowVault coverage tests
- Tests similar functionality: escrow creation, release, module management, fees, recovery

**What It Tests**:

- Escrow creation (with/without settings, auto times)
- Release functionality
- Module management (queue/activate)
- Fee withdrawal
- Recovery functions
- View functions

**Decision**: **DELETE** - Functionality appears covered by existing tests. If specific test cases are missing, add them to existing test files rather than keeping this. For now just ignore this file, leave it disabled, and we'll return to it later

**Priority**: **LOW** - Likely redundant

---

## Fix Instructions

### For PaymentBoundsChecking.t.sol.disabled

1. **Rename file**: Remove `.disabled` extension
2. **Update imports**:

   ```solidity
   // REMOVE:
   import '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

   // KEEP:
   import 'forge-std/Test.sol';
   import '../../../contracts/decentralized-resolution-module/ResolverIncentiveModuleV1.sol';
   // ... other imports
   ```

3. **Update setUp() function**:

   ```solidity
   // BEFORE:
   ResolverIncentiveModuleV1 implementation = new ResolverIncentiveModuleV1();
   ERC1967Proxy proxy = new ERC1967Proxy(
       address(implementation),
       abi.encodeCall(ResolverIncentiveModuleV1.initialize, (owner, address(paymentLib)))
   );
   incentiveModule = ResolverIncentiveModuleV1(address(proxy));

   // AFTER:
   incentiveModule = new ResolverIncentiveModuleV1(owner, address(paymentLib));
   ```

4. **Function names verified** (no changes needed):
   - `arePaymentsCalculated()` - exists ✓
   - `arePaymentsDistributed()` - exists ✓
   - `getClaimablePayment(uint256 workflowId, address resolver)` - exists ✓

5. **Run tests** and fix any remaining compilation errors

---

### For EscalationFeeEnforcement.t.sol.disabled

1. **Rename file**: Remove `.disabled` extension
2. **Update imports**:

   ```solidity
   // REMOVE:
   import '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

   // KEEP:
   import 'forge-std/Test.sol';
   import '../../../contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol';
   // ... other imports
   ```

3. **Update setUp() function**:

   ```solidity
   // BEFORE:
   DecentralizedResolutionModule implementation = new DecentralizedResolutionModule();
   ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
   resolutionModule = DecentralizedResolutionModule(address(proxy));
   resolutionModule.initialize(owner);

   // AFTER:
   resolutionModule = new DecentralizedResolutionModule(owner);
   ```

4. **Verify function signatures**:
   - `markEscalationFeePaid(uint256 workflowId, uint256 fee)`
   - `executeEscalation(uint256 workflowId, bytes calldata escrowData)`
   - `escalationFeePaid(uint256 workflowId)` - check if this is a view function or mapping

5. **Run tests** and fix any remaining compilation errors

---

### For ResolverIncentiveModuleComprehensive.t.sol.disabled

1. **First**: Compare with `test/hardhat/decentralized-resolution-module/ResolverIncentiveModule.test.ts`
   - If this test has unique coverage, proceed with fixes
   - If redundant, delete the file

2. **If keeping, apply same fixes as PaymentBoundsChecking**:
   - Remove proxy deployment
   - Use constructor: `new ResolverIncentiveModuleV1(owner, address(paymentLib))`
   - Function names are correct (both `arePaymentsCalculated()` and `arePaymentsDistributed()` exist)
   - Verify role constants

---

## Testing Checklist

After fixing each test file:

- [ ] File renamed (removed `.disabled`)
- [ ] Imports updated (removed `ERC1967Proxy`)
- [ ] Deployment uses constructor (not proxy + initialize)
- [ ] Function names match current implementation
- [ ] Role constants correct (`ROLE_TIMELOCK`, etc.)
- [ ] Tests compile without errors
- [ ] Tests pass (run `forge test --match-path test/foundry/core/[filename]`)

---

## Recommended Action Plan

1. **IMMEDIATE**: Fix `PaymentBoundsChecking.t.sol.disabled` (security-critical, unique)
2. **NEXT**: Fix `EscalationFeeEnforcement.t.sol.disabled` (important security feature)
3. **EVALUATE**: Compare `ResolverIncentiveModuleComprehensive.t.sol.disabled` with hardhat tests, then decide
4. **DELETE**: `EscrowVaultComprehensive.t.sol.disabled` (redundant)

---

## Notes

- All disabled tests use the old UUPS proxy pattern
- All need to be updated to use constructor-based immutable deployment
- Function names may have changed - verify against current contract implementations
- Role constants should already be correct (`ROLE_TIMELOCK` instead of `ROLE_ADMIN`)
