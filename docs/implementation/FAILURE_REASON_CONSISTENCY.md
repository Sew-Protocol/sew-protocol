# Failure Reason Code Consistency

**Date:** 2026-01-28  
**Status:** Implementation guide for consistent failure reason codes

---

## Overview

All failure reason codes in the emergency unwind function and yield operations must be consistent with the existing `FailureReason` enum in `BaseEscrow.sol`.

---

## BaseEscrow FailureReason Enum

```solidity
enum FailureReason {
    UNKNOWN, // 0
    CALL_FAILED, // 1
    MALFORMED_RETURN_DATA, // 2
    MODULE_NOT_SET, // 3
    MODULE_NOT_CONTRACT, // 4
    CONTRACT_INSUFFICIENT_BALANCE, // 5
    TRANSFER_FAILED, // 6
    PUSH_FAILED_FALLBACK_TO_PULL, // 7
    DEPOSIT_FAILED, // 8
    WITHDRAWAL_FAILED, // 9
    LESS_THAN_PRINCIPAL, // 10
    TIMEOUT // 11
}
```

---

## Emergency Unwind Reason Codes

### Success
- `0` = Success (unwind completed successfully)

### Standard Failures (Use FailureReason enum)
- `uint8(FailureReason.WITHDRAWAL_FAILED)` = `9` = Withdrawal failed (Aave call failed)
  - **Used when:** Aave `withdraw()` call fails
  - **Consistent with:** `YieldHandlingFailed` events for yield withdrawal failures

- `uint8(FailureReason.MODULE_NOT_SET)` = `3` = Library/Module/Pool not configured
  - **Used when:** Library not enabled, module not set, pool not configured
  - **Consistent with:** `YieldHandlingFailed` events for module wiring failures

### Emergency-Specific Checks (Custom codes 100+)
- `101` = Not paused (emergency unwind requires pause)
- `102` = Cooldown not expired (rate limiting)
- `103` = Amount exceeds limit (safety limit exceeded)
- `104` = Nothing to unwind (no aToken balance for this token)

**Why custom codes?**
- Emergency-unwind-specific checks don't map to standard `FailureReason` enum
- Using 100+ avoids conflicts with existing enum values
- Allows clear distinction between standard failures and emergency-specific checks

---

## Yield Operations Reason Codes

### Existing Yield Failure Handling

**Yield Deposit Failures:**
- `uint8(FailureReason.DEPOSIT_FAILED)` = `8` = Deposit failed
  - **Used in:** `YieldHandlingFailed` events when yield deposit fails
  - **Used in:** `OperationFailure` events (op=1, reason=DEPOSIT_FAILED)

**Yield Withdrawal Failures:**
- `uint8(FailureReason.WITHDRAWAL_FAILED)` = `9` = Withdrawal failed
  - **Used in:** `YieldHandlingFailed` events when yield withdrawal fails
  - **Used in:** `OperationFailure` events (op=2, reason=WITHDRAWAL_FAILED)

**Module Wiring Failures:**
- `uint8(FailureReason.MODULE_NOT_SET)` = `3` = Module not set
  - **Used in:** `YieldHandlingFailed` events when module is missing
- `uint8(FailureReason.MODULE_NOT_CONTRACT)` = `4` = Module not a contract
  - **Used in:** `YieldHandlingFailed` events when module address is invalid

**Other Yield Failures:**
- `uint8(FailureReason.MALFORMED_RETURN_DATA)` = `2` = Malformed return data
  - **Used in:** `OperationFailure` events when return data cannot be decoded
- `uint8(FailureReason.LESS_THAN_PRINCIPAL)` = `10` = Withdrawal returns less than principal
  - **Used in:** `YieldHandlingFailed` events when withdrawal amount < original deposit

---

## Consistency Matrix

| Failure Type | Emergency Unwind | Yield Operations | FailureReason Enum |
|-------------|------------------|------------------|---------------------|
| Withdrawal failed | `9` (WITHDRAWAL_FAILED) | `9` (WITHDRAWAL_FAILED) | ✅ Consistent |
| Module not set | `3` (MODULE_NOT_SET) | `3` (MODULE_NOT_SET) | ✅ Consistent |
| Module not contract | N/A | `4` (MODULE_NOT_CONTRACT) | ✅ Consistent |
| Deposit failed | N/A | `8` (DEPOSIT_FAILED) | ✅ Consistent |
| Malformed return | N/A | `2` (MALFORMED_RETURN_DATA) | ✅ Consistent |
| Less than principal | N/A | `10` (LESS_THAN_PRINCIPAL) | ✅ Consistent |
| Not paused | `101` (custom) | N/A | N/A (emergency-specific) |
| Cooldown | `102` (custom) | N/A | N/A (emergency-specific) |
| Amount limit | `103` (custom) | N/A | N/A (emergency-specific) |
| Nothing to unwind | `104` (custom) | N/A | N/A (emergency-specific) |

---

## Implementation Pattern

### Emergency Unwind Function

```solidity
// Standard failures - use FailureReason enum
if (!aaveYieldLibraryEnabled || address(aaveYieldLibrary) == address(0)) {
    emit EmergencyUnwindExecuted(..., uint8(FailureReason.MODULE_NOT_SET)); // 3
    return 0;
}

// Withdrawal failure - use FailureReason enum
try aaveYieldLibrary.withdraw(...) returns (uint256 withdrawn) {
    // Success
    emit EmergencyUnwindExecuted(..., 0); // 0 = success
} catch {
    emit EmergencyUnwindExecuted(..., uint8(FailureReason.WITHDRAWAL_FAILED)); // 9
    return 0;
}

// Emergency-specific checks - use custom codes
if (!paused()) {
    emit EmergencyUnwindExecuted(..., 101); // 101 = not paused
    return 0;
}
```

### Yield Operations

```solidity
// Deposit failure
try genModule.depositForYield(...) {
    // Success
} catch {
    emit YieldHandlingFailed(..., uint8(FailureReason.DEPOSIT_FAILED)); // 8
}

// Withdrawal failure
try genModule.withdrawWithYield(...) returns (...) {
    // Success
} catch {
    emit YieldHandlingFailed(..., uint8(FailureReason.WITHDRAWAL_FAILED)); // 9
}
```

---

## Testing Requirements

### Emergency Unwind Tests

```solidity
// Test standard failures use FailureReason enum
function testEmergencyUnwind_UsesFailureReasonEnum() public {
    // Withdrawal failure should emit WITHDRAWAL_FAILED (9)
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(..., uint8(FailureReason.WITHDRAWAL_FAILED));
    
    // Module not set should emit MODULE_NOT_SET (3)
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(..., uint8(FailureReason.MODULE_NOT_SET));
}

// Test emergency-specific codes
function testEmergencyUnwind_UsesCustomCodes() public {
    // Not paused should emit 101
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(..., 101);
}
```

### Yield Operations Tests

```solidity
// Test yield failures use FailureReason enum
function testYieldWithdrawal_UsesFailureReasonEnum() public {
    // Withdrawal failure should emit WITHDRAWAL_FAILED (9)
    vm.expectEmit(true, true, true, true);
    emit YieldHandlingFailed(..., uint8(FailureReason.WITHDRAWAL_FAILED));
}
```

---

## Benefits of Consistency

1. **Indexer/Backend Integration:**
   - Single mapping of reason codes across all operations
   - Easier to build dashboards and alerts
   - Consistent telemetry across yield and emergency operations

2. **Developer Experience:**
   - Clear understanding of what each code means
   - Reusable error handling logic
   - Easier debugging and troubleshooting

3. **Protocol Safety:**
   - Consistent failure handling patterns
   - Easier to audit and verify
   - Clear separation between standard failures and emergency-specific checks

---

## Summary

✅ **Standard failures** (withdrawal, module wiring) use existing `FailureReason` enum values  
✅ **Emergency-specific checks** (pause, cooldown, limits) use custom codes (100+)  
✅ **Consistent with** existing `YieldHandlingFailed` and `OperationFailure` events  
✅ **Clear separation** between standard failures and emergency-specific validation

---

**Status:** ✅ **Consistent and ready for implementation**
