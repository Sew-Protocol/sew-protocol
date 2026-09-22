# Test Plan: updateBalance and releaseEscrowTransfer Edge Cases

**Date**: 2026-01-23  
**Priority**: High  
**Status**: ⚠️ Missing test coverage for critical edge cases

## Critical Test Cases to Add

### Test 1: Partial Withdrawal (`actualAmount < amount`)

**File**: `test/foundry/core/ReleaseEscrowEdgeCases.t.sol` (NEW)

**Test Case**:
```solidity
function test_releaseEscrowTransfer_partialWithdrawal() public {
    // Setup: Create escrow with yield enabled
    vm.prank(sender);
    token.approve(address(vault), AMOUNT);
    
    EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
    settings.yieldPreset = YieldPreset.TO_RECIPIENT; // Enable yield
    vm.prank(sender);
    uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    
    // Mock YieldOps to return actualAmount < amount
    // This simulates a partial withdrawal scenario (shouldn't happen normally)
    MockYieldOps mockYieldOps = new MockYieldOps();
    mockYieldOps.setActualAmount(AMOUNT / 2); // Return half of principal
    
    // Replace yieldOps (requires governance, but for test we can use mock)
    // OR: Use a mock module that returns partial withdrawal
    
    // Release escrow
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid);
    
    // Verify: Transfer should fail (contract doesn't have enough)
    // Verify: Claimable should be set
    // Verify: Claimable amount should be actualAmount (not amount)
    // Note: Current implementation sets claimable to amount, which is incorrect
    // This test will expose the issue
}
```

**Expected Behavior**:
- Transfer fails (insufficient balance)
- Fallback to claimable
- Claimable should ideally be `actualAmount` (what's available), not `amount` (what was requested)

**Current Behavior** (Issue):
- Claimable is set to `amount` (full principal)
- But contract only has `actualAmount` available
- User's claimable balance is incorrect

---

### Test 2: Insufficient Balance After Yield Distribution

**File**: `test/foundry/core/ReleaseEscrowEdgeCases.t.sol`

**Test Case**:
```solidity
function test_releaseEscrowTransfer_insufficientBalanceAfterYield() public {
    // Setup: Create escrow with yield
    vm.prank(sender);
    token.approve(address(vault), AMOUNT);
    
    EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
    settings.yieldPreset = YieldPreset.TO_RECIPIENT;
    vm.prank(sender);
    uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    
    // Simulate yield generation (deposit to Aave, wait, generate yield)
    // ... yield generation setup ...
    
    // Edge case: Manually drain contract balance (simulate external drain)
    // This shouldn't happen in production, but we should handle it gracefully
    uint256 contractBalance = token.balanceOf(address(vault));
    // Transfer most of balance away (leave only small amount)
    vm.prank(address(vault));
    token.transfer(address(0xdead), contractBalance - 1);
    
    // Release escrow
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid);
    
    // Verify: Transfer should fail (insufficient balance)
    // Verify: Fallback to claimable works
    // Verify: Claimable is set correctly
}
```

**Expected Behavior**:
- YieldOps withdraws from Aave (adds to contract balance)
- YieldOps distributes yield (removes from contract balance)
- Contract should have principal remaining
- If balance is insufficient, fallback to claimable

---

### Test 3: Accounting Correctness with Multiple Escrows

**File**: `test/foundry/core/ReleaseEscrowEdgeCases.t.sol`

**Test Case**:
```solidity
function test_releaseEscrowTransfer_accountingCorrectnessMultipleEscrows() public {
    // Setup: Create multiple escrows with yield
    vm.prank(sender);
    token.approve(address(vault), AMOUNT * 3);
    
    EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
    settings.yieldPreset = YieldPreset.TO_RECIPIENT;
    
    uint256 wid1;
    uint256 wid2;
    uint256 wid3;
    
    vm.prank(sender);
    wid1 = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    vm.prank(sender);
    wid2 = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    vm.prank(sender);
    wid3 = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    
    // Verify totalHeldInEscrowPerToken is correct
    uint256 expectedTotal = (AMOUNT - (AMOUNT * ESCROW_FEE / 10000)) * 3;
    assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedTotal);
    
    // Generate yield for all escrows
    // ... yield generation ...
    
    // Release first escrow
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid1);
    
    // Verify accounting: totalHeldInEscrowPerToken decreased by principal (not actualAmount)
    uint256 expectedAfterFirst = expectedTotal - (AMOUNT - (AMOUNT * ESCROW_FEE / 10000));
    assertEq(vault.totalHeldInEscrowPerToken(address(token)), expectedAfterFirst);
    
    // Verify contract balance matches accounting
    uint256 contractBalance = token.balanceOf(address(vault));
    uint256 totalHeld = vault.totalHeldInEscrowPerToken(address(token));
    uint256 totalFees = vault.totalFeesPerToken(address(token));
    
    // Contract balance should be >= totalHeld + totalFees (may have yield)
    assertGe(contractBalance, totalHeld + totalFees);
    
    // Release remaining escrows
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid2);
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid3);
    
    // Verify final accounting
    assertEq(vault.totalHeldInEscrowPerToken(address(token)), 0);
}
```

**Expected Behavior**:
- `totalHeldInEscrowPerToken` tracks only principal amounts
- Yield is not tracked in `totalHeldInEscrowPerToken`
- Contract balance may exceed `totalHeldInEscrowPerToken + totalFeesPerToken` due to yield

---

### Test 4: Balance Decrement vs Transfer Amount Mismatch

**File**: `test/foundry/core/ReleaseEscrowEdgeCases.t.sol`

**Test Case**:
```solidity
function test_releaseEscrowTransfer_balanceDecrementVsTransferAmount() public {
    // Setup: Create escrow with yield
    vm.prank(sender);
    token.approve(address(vault), AMOUNT);
    
    EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
    settings.yieldPreset = YieldPreset.TO_RECIPIENT;
    vm.prank(sender);
    uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    
    uint256 fee = (AMOUNT * ESCROW_FEE) / 10000;
    uint256 principal = AMOUNT - fee;
    
    // Track balance before release
    uint256 totalHeldBefore = vault.totalHeldInEscrowPerToken(address(token));
    uint256 contractBalanceBefore = token.balanceOf(address(vault));
    
    // Generate yield (simulate Aave yield generation)
    // ... yield generation ...
    
    // Release escrow
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid);
    
    // Verify: Balance decremented by principal (not actualAmount)
    uint256 totalHeldAfter = vault.totalHeldInEscrowPerToken(address(token));
    assertEq(totalHeldBefore - totalHeldAfter, principal, "Balance should decrement by principal");
    
    // Verify: Transfer was for actualAmount (principal + yield)
    uint256 recipientBalance = token.balanceOf(recipient);
    // Recipient should receive actualAmount (>= principal)
    assertGe(recipientBalance, principal, "Recipient should receive at least principal");
    
    // Verify: Contract balance accounting
    uint256 contractBalanceAfter = token.balanceOf(address(vault));
    // Contract balance should have decreased by actualAmount (if transfer succeeded)
    // OR: Contract balance should be >= totalHeld + totalFees (if transfer failed, fallback to claimable)
}
```

**Expected Behavior**:
- Balance decrement: Uses `amount` (principal)
- Transfer: Uses `actualAmount` (principal + yield)
- Accounting remains correct because yield is not tracked in `totalHeldInEscrowPerToken`

---

### Test 5: Edge Case - actualAmount == 0

**File**: `test/foundry/core/ReleaseEscrowEdgeCases.t.sol`

**Test Case**:
```solidity
function test_releaseEscrowTransfer_actualAmountZero() public {
    // Setup: Create escrow with yield enabled
    vm.prank(sender);
    token.approve(address(vault), AMOUNT);
    
    EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
    settings.yieldPreset = YieldPreset.TO_RECIPIENT;
    vm.prank(sender);
    uint256 wid = vault.createEscrow(address(token), recipient, AMOUNT, settings);
    
    // Mock YieldOps to return actualAmount == 0
    // This simulates withdrawal failure (but didn't revert)
    MockYieldOps mockYieldOps = new MockYieldOps();
    mockYieldOps.setActualAmount(0);
    
    // Release escrow
    vm.prank(sender);
    vault.releaseEscrowTransfer(wid);
    
    // Verify: _handleYieldAndGetActualAmount returns amount (principal)
    // Verify: Transfer succeeds with amount (principal)
    // Verify: Balance decremented by amount
}
```

**Expected Behavior**:
- `_handleYieldAndGetActualAmount` returns `amount` (principal) when `actualAmount == 0`
- Transfer succeeds with `amount`
- Balance decremented by `amount`

---

## Implementation Priority

### High Priority (Critical Edge Cases)
1. ✅ Test 1: Partial withdrawal (`actualAmount < amount`)
2. ✅ Test 4: Balance decrement vs transfer amount mismatch

### Medium Priority (Defensive Testing)
3. ✅ Test 2: Insufficient balance after yield distribution
4. ✅ Test 3: Accounting correctness with multiple escrows

### Low Priority (Edge Cases)
5. ✅ Test 5: `actualAmount == 0` case

---

## Test File Structure

**New File**: `test/foundry/core/ReleaseEscrowEdgeCases.t.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {EscrowVault} from "../../../contracts/core/EscrowVault.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
// ... other imports ...

contract ReleaseEscrowEdgeCasesTest is Test {
    EscrowVault vault;
    MockERC20 token;
    address sender;
    address recipient;
    
    // Test cases from above
    function test_releaseEscrowTransfer_partialWithdrawal() public { ... }
    function test_releaseEscrowTransfer_insufficientBalanceAfterYield() public { ... }
    function test_releaseEscrowTransfer_accountingCorrectnessMultipleEscrows() public { ... }
    function test_releaseEscrowTransfer_balanceDecrementVsTransferAmount() public { ... }
    function test_releaseEscrowTransfer_actualAmountZero() public { ... }
}
```

---

## Notes

1. **Mock YieldOps**: May need to create a mock YieldOps contract that allows setting `actualAmount` for testing edge cases.

2. **Yield Generation**: Tests may need to simulate yield generation (deposit to Aave, wait, generate yield) or use mocks.

3. **Current Issue**: The partial withdrawal case (`actualAmount < amount`) exposes an accounting issue where claimable is set to `amount` but contract only has `actualAmount` available. This should be fixed.

4. **Accounting Model**: The accounting is correct for normal cases (yield is not tracked in `totalHeldInEscrowPerToken`), but edge cases need explicit testing.
