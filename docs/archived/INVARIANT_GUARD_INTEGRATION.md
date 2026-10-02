# Using InvariantGuard to Secure Delegatecall Functions

## Overview

This document describes how to integrate [InvariantGuard](https://github.com/Helkomine/invariant-guard) to protect the `delegatecall` functions in this codebase. InvariantGuard provides a powerful mechanism to enforce state invariants before and after execution, preventing malicious or buggy delegated code from making unintended state changes.

## Does This Increase EscrowVault Size?

**No.** The integration approach below adds InvariantGuard to the **library** (`AaveYieldHandlingLibrary`), NOT to BaseEscrow/EscrowVault. This is critical because:

1. **Libraries don't count toward main contract size** - When using delegatecall, the library code runs in the context of the caller but is deployed separately. EscrowVault stays at ~27.8KB.

2. **Only the library grows** - The guard code goes into `AaveYieldHandlingLibrary`, which is already deployed as a separate contract.

3. **24KB limit applies to EscrowVault** - The library can be any size since it's deployed independently.

This is the same pattern already used: the yield library handles Aave operations via delegatecall, and adding invariant guards follows the same architecture.

## The Problem

`DELEGATECALL` allows a contract to execute code from another contract in its own storage context. This is powerful but dangerous - any code executed via delegatecall can modify the caller's storage. A malicious or buggy logic contract can:

1. **Steal ownership** by modifying owner storage slots
2. **Drain funds** by manipulating balance-related state
3. **Break contract invariants** by altering critical state variables
4. **Install backdoors** by modifying proxy pointers or access control slots

## Current Delegatecall Usage in This Project

**Note:** The delegatecall pattern has been **deprecated** in favor of the module pattern. The code in `AaveYieldHandlingLibrary.sol` exists but is no longer actively called - it remains for backward compatibility.

If you need to support the delegatecall pattern (e.g., for existing deployments that use a single yield library for multiple escrows), the guarded version provides enhanced security.

### Historical Delegatecall Usages (Deprecated)

The original delegatecall implementations in `contracts/libraries/AaveYieldHandlingLibrary.sol`:

### 1. Yield Withdrawal (line 180)

```solidity
(bool success, bytes memory returnData) = aaveYieldLibrary.delegatecall(
    abi.encodeWithSelector(AaveYieldLibrary.withdraw.selector, aavePool, token, underlyingToWithdraw, address(this))
);
```

### 2. Yield Deposit (line 280)

```solidity
(bool success, ) = aaveYieldLibrary.delegatecall(
    abi.encodeWithSelector(AaveYieldLibrary.supply.selector, aavePool, token, amount, address(this))
);
```

## How InvariantGuard Works

InvariantGuard works by:

1. **Taking snapshots** of selected state values before execution
2. **Executing** the target logic
3. **Validating** post-execution state against expected invariants

This is similar to flash loan validation patterns but more flexible.

### Supported Invariant Types

| Category              | Description                                          | Modifiers                                                                    |
| --------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------- |
| **Code**              | Contract bytecode hash must remain unchanged         | `invariantCode()`                                                            |
| **Balance**           | ETH balance must satisfy delta constraint            | `invariantBalance()`, `exactIncreaseBalance()`, `maxIncreaseBalance()`, etc. |
| **Storage**           | Specific storage slots must satisfy delta constraint | `invariantStorage()`, `exactIncreaseStorage()`, etc.                         |
| **Transient Storage** | Same as storage but for transient storage (EIP-1153) | `invariantTransientStorage()`                                                |

## Implementation

The InvariantGuard contracts are implemented in `contracts/guards/`:

### Files Created

1. **`contracts/guards/InvariantGuardHelper.sol`** - Helper library with delta validation logic
2. **`contracts/guards/InvariantGuardInternal.sol`** - Abstract contract with invariant modifiers
3. **`contracts/guards/InvariantGuardedAaveYieldLibrary.sol`** - Guarded yield library with versioning

### Version Information

The guarded library uses semantic versioning:

```
LIBRARY_NAME = "InvariantGuardedAaveYieldLibrary"
LIBRARY_VERSION = "1.0.0"
PROTOCOL_ID = keccak256("aave-v3-guarded")
```

Query via `getLibraryInfo()` which returns `(name, version, protocolId)`.

### Protected Slots

The library exposes getter functions for the protected storage slots:

- `getProtectedSlots()` - All critical slots (5 total)
- `getOwnerSlots()` - Owner and pendingOwner (2 slots)
- `getModuleSlots()` - Module pointers and fee address (3 slots)

### Usage

To use the guarded library, create a contract that inherits both:

```solidity
import { AaveYieldHandlingLibrary } from '../libraries/AaveYieldHandlingLibrary.sol';
import { InvariantGuardedAaveYieldLibrary } from './guards/InvariantGuardedAaveYieldLibrary.sol';

abstract contract AaveYieldHandlingLibraryGuarded is
  AaveYieldHandlingLibrary,
  InvariantGuardedAaveYieldLibrary
{
  // Inherit guarded functions from InvariantGuardedAaveYieldLibrary
}
```

Then call `guardedYieldWithdrawal()` or `guardedYieldDeposit()` instead of direct library calls.

## Additional Security Recommendations

### 1. Combine with ReentrancyGuard

InvariantGuard and ReentrancyGuard serve different purposes and can be used together:

```solidity
function execute(...) internal invariantStorage(_getCriticalSlots()) nonReentrant returns (...) {
    // ...
}
```

### 2. Protect Balance Changes

For functions that should change balance by a specific amount:

```solidity
// For withdrawals - allow balance to decrease by exact amount
function _guardedWithdrawal(...) internal exactDecreaseBalance(withdrawalAmount) {
    // ...
}

// For deposits - allow balance to increase by exact amount
function _guardedDeposit(...) internal exactIncreaseBalance(depositAmount) {
    // ...
}
```

### 3. Protect Code Integrity

Prevent code changes (important for proxy patterns):

```solidity
function executeWithCodeProtection(
  address target,
  bytes calldata data
)
  external
  invariantCode // Ensures bytecode doesn't change
  invariantStorage(_getCriticalSlots())
  returns (bytes memory)
{
  return target.functionDelegateCall(data);
}
```

### 4. Use Transient Storage for Temporary State

For guards that need to persist across reentrancy:

```solidity
function execute(...) internal invariantTransientStorage(_getGuardSlots()) {
    // ...
}
```

## Limitations

1. **Storage slots must be explicitly enumerated** - mappings and dynamic arrays require manual slot calculation
2. **Not a silver bullet** - protects against unintended changes but cannot prevent all attack vectors
3. **Gas overhead** - each invariant check adds SLOAD operations
4. **Not audited** - InvariantGuard is not audited; use with caution in production
5. **Cannot protect all state** - only specified slots are protected; other slots remain vulnerable

## Testing

Add tests to verify the guard works correctly:

```solidity
// test/guards/AaveYieldHandlingLibraryGuard.t.sol

pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import { AaveYieldHandlingLibraryGuarded } from '../contracts/guards/AaveYieldHandlingLibraryGuarded.sol';
import { MaliciousModule } from './mocks/MaliciousModule.sol';

contract AaveYieldHandlingLibraryGuardTest is Test {
  function test_guardedWithdrawal_preventsOwnershipChange() public {
    // Deploy malicious module that tries to change owner
    MaliciousModule malicious = new MaliciousModule();

    // Attempting to call guarded withdrawal with malicious module
    // should revert due to invariant violation
    vm.expectRevert(); // InvariantViolationStorage
    // ... call guardedYieldWithdrawal with malicious module
  }
}
```

## References

- InvariantGuard Repository: https://github.com/Helkomine/invariant-guard
- EIP-7201 (Storage Namespaces): https://eips.ethereum.org/EIPS/eip-7201
- EIP-1153 (Transient Storage): https://eips.ethereum.org/EIPS/eip-1153
- OpenZeppelin ReentrancyGuard: https://docs.openzeppelin.com/contracts/4.x/api/security#ReentrancyGuard
