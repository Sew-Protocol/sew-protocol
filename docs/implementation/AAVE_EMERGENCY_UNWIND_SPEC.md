# Emergency Unwind Function Specification

**Date:** 2026-01-28  
**Status:** Design specification for guardian emergency unwind

---

## Requirements

### User Requirements

1. **Simple Yield Withdrawal** ✅
   - Users call `withdrawEscrow(workflowId)` once
   - Receives principal + yield together
   - No complicated steps
   - **Status:** Already implemented correctly

### Guardian Requirements

2. **Emergency Unwind** (Lower Priority)
   - Guardian can unwind Aave positions in emergency
   - **Cannot reroute funds** (always goes to BaseEscrow)
   - Rate limited (cooldown + max per call)
   - Only when paused
   - Scoped to specific token
   - Full observability

---

## Emergency Unwind Design

### Function Signature

```solidity
function emergencyUnwindAavePosition(
    address token,
    uint256 maxATokenAmount
) external onlyRole(ROLE_GUARDIAN) whenPaused returns (uint256 underlyingAmount)
```

### Safety Constraints

#### 1. Authorization
- ✅ Only `ROLE_GUARDIAN` can call
- ✅ Cannot be called by timelock or anyone else
- ✅ Guardian cannot enable library (only disable)

#### 2. Pause Requirement
- ✅ Only callable when `paused() == true`
- ✅ Prevents abuse during normal operation
- ✅ Emits reason code `3` if not paused

#### 3. Rate Limiting
- ✅ Cooldown: 1 hour per token
- ✅ Tracks `lastUnwindTimestamp[token]`
- ✅ Prevents rapid-fire unwinds
- ✅ Emits reason code `4` if cooldown not expired

#### 4. Amount Limits
- ✅ Max per call: 1M tokens (`MAX_UNWIND_AMOUNT_PER_CALL`)
- ✅ Caps to actual balance if less
- ✅ Prevents single-call drain
- ✅ Emits reason code `5` if exceeds limit

#### 5. Destination Restriction (CRITICAL)
- ✅ **Hardcoded destination:** `address(this)` (BaseEscrow)
- ✅ **Cannot be changed:** No parameter for destination
- ✅ **Guardian cannot reroute:** Funds always go to BaseEscrow
- ✅ **No arbitrary transfers:** Only unwinds to BaseEscrow

#### 6. Scope Restriction
- ✅ Only specific token (parameter)
- ✅ Cannot unwind arbitrary tokens
- ✅ Checks BaseEscrow's aToken balance for that token only
- ✅ Emits reason code `2` if nothing to unwind

#### 7. Configuration Checks
- ✅ Library must be enabled
- ✅ Library must be configured
- ✅ Module must be configured
- ✅ Pool must be configured
- ✅ Emits reason codes `6`, `7`, `8` for configuration issues

#### 8. Non-Blocking
- ✅ Uses try/catch
- ✅ Never reverts (returns 0 on failure)
- ✅ Emits events for all outcomes
- ✅ Doesn't trap funds if unwind fails

### Event Structure

```solidity
event EmergencyUnwindExecuted(
    address indexed token,
    uint256 aTokenAmount,
    uint256 underlyingAmount,
    uint256 timestamp,
    address indexed caller,
    uint8 reasonCode // 0 = success, FailureReason enum values, or 100+ for emergency-specific codes
);
```

**Reason Code Mapping:**
- `0` = Success (unwind completed successfully)
- `uint8(FailureReason.WITHDRAWAL_FAILED)` = 9 = Aave withdrawal call failed
- `uint8(FailureReason.MODULE_NOT_SET)` = 3 = Library/Module/Pool not configured
- `100+` = Emergency-unwind-specific checks (see below)

**Reason Codes (Consistent with BaseEscrow FailureReason enum):**
- `0` = Success (unwind completed successfully)
- `uint8(FailureReason.WITHDRAWAL_FAILED)` = `9` = Withdrawal failed (Aave call failed) - **consistent with yield withdrawal failures**
- `uint8(FailureReason.MODULE_NOT_SET)` = `3` = Library/Module/Pool not configured - **consistent with module wiring failures**
- Custom codes (100+) for emergency-unwind-specific checks:
  - `101` = Not paused (emergency unwind requires pause)
  - `102` = Cooldown not expired (rate limiting)
  - `103` = Amount exceeds limit (safety limit exceeded)
  - `104` = Nothing to unwind (no aToken balance for this token)

**Consistency Strategy:**
- **Standard failures** use existing `FailureReason` enum values (matches `YieldHandlingFailed` events)
- **Emergency-specific checks** use custom codes (100+) to avoid conflicts with `FailureReason` enum
- **Pattern matches** existing BaseEscrow yield failure handling

### Implementation Details

**Flow:**
1. Check pause → fail if not paused → emit reason code `101`
2. Check cooldown → fail if cooldown active → emit reason code `102`
3. Check amount limit → fail if exceeds → emit reason code `103`
4. Check library config → fail if not configured → emit `FailureReason.MODULE_NOT_SET` (3)
5. Get module/pool addresses → fail if not available → emit `FailureReason.MODULE_NOT_SET` (3)
6. Get BaseEscrow's aToken balance → fail if zero → emit reason code `104`
7. Cap to max amount
8. **Call library.withdraw(pool, token, amount, address(this))** ← Hardcoded destination
9. On success: Update state (cooldown, total), emit reason code `0`
10. On failure: Emit `FailureReason.WITHDRAWAL_FAILED` (9)

**Key Line:**
```solidity
// CRITICAL: Hardcoded destination - guardian cannot change this
aaveYieldLibrary.withdraw(aavePool, token, unwindAmount, address(this));
//                                                                  ^^^^
//                                                          Always BaseEscrow
```

---

## Why This Design is Safe

### Cannot Reroute Funds
- ✅ Destination is hardcoded (`address(this)`)
- ✅ No parameter for destination
- ✅ Guardian cannot specify where funds go
- ✅ Funds always return to BaseEscrow

### Cannot Drain
- ✅ Rate limited (1 hour cooldown)
- ✅ Amount limited (1M per call)
- ✅ Requires pause (governance-controlled)
- ✅ Scoped to specific token

### Cannot Abuse
- ✅ Requires pause (timelock-controlled)
- ✅ Cooldown prevents rapid unwinds
- ✅ Amount limits prevent large drains
- ✅ Full observability (events)

### Full Observability
- ✅ Structured events with reason codes
- ✅ Timestamp tracking
- ✅ Total unwound amount tracking
- ✅ Per-token cooldown tracking

---

## Testing Requirements

### Unit Tests

```solidity
function testEmergencyUnwind_RequiresPause() public {
    // Should fail if not paused
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, guardian, 101); // 101 = not paused
    baseEscrow.emergencyUnwindAavePosition(token, amount);
}

function testEmergencyUnwind_RespectsCooldown() public {
    // Should fail if cooldown active
    baseEscrow.pause();
    baseEscrow.emergencyUnwindAavePosition(token, amount);
    // Try again immediately - should fail
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, guardian, 102); // 102 = cooldown
    baseEscrow.emergencyUnwindAavePosition(token, amount);
}

function testEmergencyUnwind_RespectsAmountLimit() public {
    // Should fail if amount exceeds limit
    baseEscrow.pause();
    uint256 tooLarge = MAX_UNWIND_AMOUNT_PER_CALL + 1;
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, guardian, 103); // 103 = exceeds limit
    baseEscrow.emergencyUnwindAavePosition(token, tooLarge);
}

function testEmergencyUnwind_FundsGoToBaseEscrow() public {
    // CRITICAL: Verify funds go to BaseEscrow, not guardian
    baseEscrow.pause();
    uint256 balanceBefore = IERC20(token).balanceOf(address(baseEscrow));
    
    vm.expectEmit(true, true, true, true);
    emit EmergencyUnwindExecuted(token, amount, amount, block.timestamp, guardian, 0); // 0 = success
    baseEscrow.emergencyUnwindAavePosition(token, amount);
    
    uint256 balanceAfter = IERC20(token).balanceOf(address(baseEscrow));
    assertGt(balanceAfter, balanceBefore); // Funds increased in BaseEscrow
    
    // Verify guardian did NOT receive funds
    uint256 guardianBalance = IERC20(token).balanceOf(guardian);
    assertEq(guardianBalance, 0); // Guardian has no funds
}

function testEmergencyUnwind_NonGuardianCannotCall() public {
    // Should fail if not guardian
    baseEscrow.pause();
    vm.prank(user);
    vm.expectRevert(); // Access control
    baseEscrow.emergencyUnwindAavePosition(token, amount);
}
```

### Fork Tests (Phase 4)

```solidity
function testEmergencyUnwind_RealAave() public {
    // Fork Base Sepolia
    vm.createSelectFork(vm.envString("RPC_BASE_SEPOLIA"));
    
    // Setup BaseEscrow with library enabled
    // Create escrow with yield, let it accrue
    
    // Pause and unwind
    baseEscrow.pause();
    uint256 unwound = baseEscrow.emergencyUnwindAavePosition(USDC, maxAmount);
    
    // Verify funds in BaseEscrow
    assertGt(unwound, 0);
    assertGt(IERC20(USDC).balanceOf(address(baseEscrow)), 0);
}
```

---

## Integration with Module Swaps

**When module is swapped:**
- Emergency unwind uses default module
- Gets pool address from current default module
- Works with any Aave-compatible module
- No changes needed to unwind function

**Safety:**
- Module swap doesn't affect unwind safety
- Unwind still goes to BaseEscrow
- Rate limits still apply
- Pause requirement still applies

---

## Monitoring and Alerts

**Events to Monitor:**
- `EmergencyUnwindExecuted` - All unwind attempts
- Reason code `0` = Success (normal)
- Reason code `uint8(FailureReason.WITHDRAWAL_FAILED)` = `9` = Withdrawal failed (investigate Aave call)
- Reason code `uint8(FailureReason.MODULE_NOT_SET)` = `3` = Configuration issue (investigate module/pool setup)
- Reason codes `101-104` = Emergency-specific checks failed (investigate pause/cooldown/limits)

**Metrics:**
- `totalUnwoundAmount` - Total unwound across all tokens
- `lastUnwindTimestamp[token]` - Last unwind per token
- Frequency of unwinds (should be rare)

**Alerts:**
- Unwind executed (reason code 0)
- Multiple unwinds in short time
- Large unwind amounts
- Unwind failures (reason codes 1-8)

---

## Conclusion

**Emergency unwind is safe because:**
- ✅ Guardian cannot reroute funds (hardcoded destination)
- ✅ Guardian cannot drain (rate + amount limits)
- ✅ Guardian cannot abuse (pause requirement)
- ✅ Full observability (events, monitoring)
- ✅ Non-blocking (doesn't trap funds)

**Recommended:** Implement in Phase 1 (tomorrow) as it's a critical safety feature, even if Aave isn't live yet.

---

**Status:** ✅ **Design complete - ready for implementation**
