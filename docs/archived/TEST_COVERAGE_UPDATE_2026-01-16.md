# Test Coverage Update: Edge Cases

**Date:** 2026-01-16
**Author:** Gemini CLI Agent

## Executive Summary

Addressed "Medium Priority Gaps" from the Test Coverage Summary by implementing a new test suite for edge cases.

**New Test File:** `test/foundry/core/EscrowEdgeCases.t.sol`
**Tests Added:** 3

## Implemented Tests

### 1. Fee-on-Transfer Token Handling

**Test:** `test_createEscrow_FeeOnTransfer_Insolvency`
**Status:** ✅ PASS (Confirmed Insolvency Issue)
**Description:**
This test validates how the `EscrowVault` handles ERC20 tokens that charge a fee on transfer.
- **Scenario:** Buyer creates an escrow with a Fee-on-Transfer token.
- **Observation:**
    - The vault records the full `amount` as held.
    - The vault actually receives `amount - transferFee`.
    - When the escrow is released, the vault updates its internal accounting to release `amount - escrowFee`.
    - The vault successfully marks the funds as "claimable" (pull model).
    - **Issue:** When the fee recipient tries to withdraw the accumulated `escrowFee`, the transaction reverts because the vault is insolvent (actual balance < recorded liabilities).
- **Conclusion:** The system does not currently support Fee-on-Transfer tokens correctly. This test serves as documentation of this limitation/bug.

### 2. Large Bond Amounts (Overflow)

**Test:** `test_createEscrow_MaxAmount_Overflow`
**Status:** ✅ PASS (Reverts as expected)
**Description:**
Tests creation of an escrow with `amount` such that `amount * escrowFee` would overflow `uint256`.
- **Observation:** The transaction correctly reverts due to arithmetic overflow checks in Solidity 0.8+.

### 3. Maximum Safe Amount

**Test:** `test_createEscrow_MaxSafeAmount`
**Status:** ✅ PASS
**Description:**
Tests creation of an escrow with the maximum possible amount that does not cause an overflow during fee calculation.
- **Calculation:** `maxAmount = type(uint256).max / escrowFee`.
- **Observation:** The system handles this maximum amount correctly.

## Recommendations

1.  **Fee-on-Transfer Tokens:**
    -   **Short Term:** Document that Fee-on-Transfer tokens are not supported.
    -   **Long Term:** Update `EscrowVault._pullTokens` to measure actual balance increase and use that as the deposited amount, or revert if balance increase != amount.

2.  **Large Amounts:**
    -   Current overflow protection is sufficient.

## Next Steps

-   Proceed with other medium/high priority gaps if necessary.
-   Consider fixing the Fee-on-Transfer support if required by business logic.
