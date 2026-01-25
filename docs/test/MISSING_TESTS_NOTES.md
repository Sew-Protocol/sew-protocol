# Missing Tests - Implementation Notes

**Date**: 2026-01-23  
**Context**: After Aave delegatecall library pattern removal and GuardianOps creation  
**Status**: ⚠️ **NOT YET IMPLEMENTED** - Documented for future implementation

---

## High Priority Missing Tests

### 1. `test_supply_handlesApproveToZeroPattern()`
**Purpose**: Verify safe approval pattern (reset to zero, then set)  
**Location**: `test/foundry/integration/AaveEdgeCases.t.sol`  
**Priority**: 🔴 **HIGH** (Security critical)

**What to test**:
- Module resets approval to zero before setting new approval
- Handles USDT-like tokens that require zero-first approval
- No lingering infinite approvals after operations
- Approval is bounded to minimal expected value

**Implementation notes**:
- Test with mock token that reverts on approve unless allowance is zero-first
- Verify `AaveYieldGenerationModule.depositForYield()` uses safe approval pattern
- Check approval state before and after deposit

---

### 2. `test_caps_enforced_global_and_perEscrow()`
**Purpose**: Verify both global and per-escrow caps are enforced  
**Location**: `test/foundry/integration/AaveEdgeCases.t.sol` or new test file  
**Priority**: 🔴 **HIGH** (Feature validation)

**What to test**:
- Global cap prevents total deposits exceeding limit
- Per-escrow cap prevents single escrow exceeding limit
- Caps are checked before deposit
- Caps are enforced across multiple escrows
- Cap updates (via governance) are respected

**Implementation notes**:
- Use `AaveYieldGenerationModule.setGlobalCap()` and `setTokenCap()`
- Create multiple escrows and verify total doesn't exceed global cap
- Verify single escrow doesn't exceed per-escrow cap
- Test cap updates via timelock

---

### 3. `test_interest_distribution_matchesSpec()`
**Purpose**: Verify user/protocol split matches specification  
**Location**: `test/foundry/integration/AaveEdgeCases.t.sol` or `AaveCrit2DistributionFailures.t.sol`  
**Priority**: 🔴 **HIGH** (Feature validation)

**What to test**:
- Interest is calculated correctly (aToken balance growth)
- User receives correct portion of interest
- Protocol fee is calculated and collected correctly
- Fee recipient receives protocol portion
- Distribution matches yield preset (TO_SENDER, TO_RECIPIENT, etc.)

**Implementation notes**:
- Create escrow with yield enabled
- Warp time to accrue interest
- Withdraw and verify interest distribution
- Check protocol fee calculation
- Verify fee recipient balance

---

### 4. `test_noCrossEscrowLeakage_multipleEscrows()`
**Purpose**: Verify escrow A actions don't affect escrow B  
**Location**: `test/foundry/integration/AaveEdgeCases.t.sol` or update `AaveLibraryMultiEscrow.t.sol`  
**Priority**: 🔴 **HIGH** (Security critical)

**What to test**:
- Creating escrow A doesn't affect escrow B balances
- Depositing yield for escrow A doesn't affect escrow B
- Withdrawing from escrow A doesn't affect escrow B
- Interest accrual is tracked per-escrow correctly
- Principal tracking is isolated per escrow

**Implementation notes**:
- Create two escrows with same token
- Verify module tracks `escrowInAave[escrowContract][workflowId]` separately
- Verify `escrowATokenBalance` is tracked per escrow
- Verify withdrawals don't cross-contaminate

---

### 5. `testFork_supplyUSDC_mintsAToken()`
**Purpose**: Verify USDC supply mints aToken on real Aave  
**Location**: `test/foundry/integration/AaveForkTests.t.sol`  
**Priority**: 🔴 **HIGH** (Integration validation)

**What to test**:
- Supply USDC to Aave via module
- Verify aToken is minted to EscrowVault
- Verify aToken balance matches expected amount
- Verify underlying USDC is transferred to Aave pool
- Verify `escrowInAave` mapping is updated

**Implementation notes**:
- Use Base Sepolia fork
- Get real USDC and aUSDC addresses from Aave
- Create escrow with yield enabled
- Verify aToken balance after deposit
- Compare with `test_LibraryMaintainsMsgSender()` but focus on module pattern

---

### 6. `testFork_withdrawUSDC_returnsUnderlying()`
**Purpose**: Verify USDC withdrawal returns underlying from real Aave  
**Location**: `test/foundry/integration/AaveForkTests.t.sol`  
**Priority**: 🔴 **HIGH** (Integration validation)

**What to test**:
- Withdraw USDC from Aave via module
- Verify underlying USDC is returned to EscrowVault
- Verify aToken is burned correctly
- Verify interest (if any) is included
- Verify `escrowInAave` mapping is updated

**Implementation notes**:
- Use Base Sepolia fork
- Create escrow with yield, deposit, then withdraw
- Verify USDC balance increase
- Verify aToken balance decrease
- Check interest calculation

---

## Medium Priority Missing Tests

### 7. `test_supply_emitsExpectedEvents_andUpdatesPrincipal()`
**Purpose**: Verify events emitted and principal tracking  
**Location**: `test/foundry/integration/AaveEdgeCases.t.sol`  
**Priority**: 🟡 **MEDIUM**

**What to test**:
- Events emitted: `YieldDepositAttempted`, `OperationFailure` (if fails)
- Principal is tracked correctly in module
- `escrowOriginalDeposit` mapping is updated
- `escrowATokenBalance` is updated

---

### 8. `test_withdraw_partial_then_full_conservesAssets()`
**Purpose**: Verify partial withdrawal then full withdrawal doesn't lose assets  
**Location**: `test/foundry/integration/AaveEdgeCases.t.sol`  
**Priority**: 🟡 **MEDIUM**

**What to test**:
- Deposit amount X
- Withdraw partial amount Y
- Verify remaining balance is X - Y (plus interest)
- Withdraw full remaining amount
- Verify all assets recovered (no dust left)

---

### 9. `testFork_addressDerivation_fromPoolReserveData()`
**Purpose**: Regression test - derive addresses onchain, not from UI  
**Location**: `test/foundry/integration/AaveForkTests.t.sol`  
**Priority**: 🟡 **MEDIUM**

**What to test**:
- Derive pool address from PoolAddressesProvider
- Derive aToken address from `pool.getReserveData(token).aTokenAddress`
- Verify addresses match expected values
- Ensure no hardcoded addresses in tests

---

### 10. `testFork_interestNonDecreasing_overTimeWarp()`
**Purpose**: Verify interest accrual over time (aToken balance non-decreasing)  
**Location**: `test/foundry/integration/AaveForkTests.t.sol`  
**Priority**: 🟡 **MEDIUM**

**What to test**:
- Deposit to Aave
- Record initial aToken balance
- Warp time forward (1 day, 1 week)
- Verify aToken balance is non-decreasing
- Note: May be slow on testnets, treat as "≥" not ">"

---

## Low Priority / Future Tests

### 11. Negative Fuzz Tests (Non-Standard ERC20)
**Purpose**: Verify we fail fast for unsupported tokens  
**Location**: New test file or `test/foundry/integration/AaveFuzz.t.sol`  
**Priority**: 🟢 **LOW**

**What to test**:
- ERC20 that returns `false` on transfer (should revert or handle)
- ERC20 that reverts on approve unless allowance is zero-first (USDT-like)
- Fee-on-transfer token (should revert or handle)
- Confirm clear error messages

---

### 12. Stateful Fuzz / Handler Tests
**Purpose**: Property-based testing with randomized actions  
**Location**: New test file `test/foundry/integration/AaveStatefulFuzz.t.sol`  
**Priority**: 🟢 **LOW**

**What to test**:
- Handler contract with actions: `openEscrow()`, `enterYield()`, `exitYield()`, `settle()`, `pause/unpause()`, `changeCaps()`
- Randomize actors: buyer/seller/guardian/timelock/attacker
- Shadow accounting model for expected principal and claims
- Invariants hold across all randomized sequences

---

### 13. Event-Driven Assertions
**Purpose**: Verify correct failure reason codes are emitted  
**Location**: New test file or existing test files  
**Priority**: 🟢 **LOW**

**What to test**:
- Each soft-failure path emits correct `FailureReason` code
- No "defined but never emitted" codes remain
- Event taxonomy matches actual failure scenarios

---

### 14. Gas and DoS Checks
**Purpose**: Ensure loops are bounded and settlement doesn't become uncallable  
**Location**: New test file or existing test files  
**Priority**: 🟢 **LOW**

**What to test**:
- Loops are bounded (per-escrow lists, module registries)
- Settlement gas cost doesn't grow unbounded
- Large number of escrows doesn't break settlement

---

## Tests Needing Updates (After Refactoring)

### 1. `test_LibraryMaintainsMsgSender()` → `test_ModulePattern_MaintainsEscrowOwnership()`
**File**: `test/foundry/integration/AaveForkTests.t.sol`  
**Status**: ⚠️ **NEEDS UPDATE**

**Changes needed**:
- Rename test to reflect module pattern (not library pattern)
- Update comments to reference `AaveYieldGenerationModule.depositForYield()`
- Verify `aTokens` are owned by `EscrowVault` (BaseEscrow), not the module
- Verify module tracks state correctly

---

## Implementation Order

### Phase 1: High Priority Security Tests
1. `test_supply_handlesApproveToZeroPattern()` - Security critical
2. `test_noCrossEscrowLeakage_multipleEscrows()` - Security critical
3. `test_caps_enforced_global_and_perEscrow()` - Feature validation

### Phase 2: High Priority Integration Tests
4. `testFork_supplyUSDC_mintsAToken()` - Integration validation
5. `testFork_withdrawUSDC_returnsUnderlying()` - Integration validation
6. `test_interest_distribution_matchesSpec()` - Feature validation

### Phase 3: Medium Priority Tests
7. `test_supply_emitsExpectedEvents_andUpdatesPrincipal()`
8. `test_withdraw_partial_then_full_conservesAssets()`
9. `testFork_addressDerivation_fromPoolReserveData()`
10. `testFork_interestNonDecreasing_overTimeWarp()`

### Phase 4: Update Existing Tests
11. Update `test_LibraryMaintainsMsgSender()` to module pattern

### Phase 5: Low Priority / Future
12. Negative fuzz tests
13. Stateful fuzz handlers
14. Event-driven assertions
15. Gas/DoS checks

---

## Notes

- All tests should use the module pattern (not delegatecall library pattern)
- Emergency unwind tests should use `GuardianOps` (already updated)
- Yield status checks should use `aaveModule.escrowInAave()` (not `escrowVault.escrowInYield()`)
- Fork tests require Base Sepolia RPC URL and fork setup
- Some tests may already exist with different names - verify before implementing

---

## Related Documents

- **Checklist**: `docs/test/AAVE_INTEGRATION_CHECKLIST.md`
- **Status**: `docs/test/AAVE_INTEGRATION_CHECKLIST_STATUS.md`
- **Module Pattern**: `docs/optimization/AAVE_ARCHITECTURE_ANALYSIS.md`
