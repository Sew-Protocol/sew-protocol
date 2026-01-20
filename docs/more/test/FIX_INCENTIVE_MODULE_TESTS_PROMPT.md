# Fix Incentive Module Tests - LLM Prompt

**Context**: Fix failing tests in the incentive module test suite. Tests compile but fail at runtime due to architectural changes: **escalation fees have been replaced with appeal bonds**.

---

## Critical Context: Escalation Fees → Appeal Bonds Migration

### ⚠️ **BREAKING CHANGE**: Escalation Fees Removed

**Old System (Deprecated)**:

- Escalation required paying a **fee** (non-refundable)
- Fee went to protocol treasury
- `recordEscalationFee()` was called during escalation
- `EscalationFeePaid` events were emitted

**New System (Current)**:

- Escalation requires posting an **appeal bond** (refundable deposit)
- Bond is calculated via `EscalationCostConfig` (quadratic curve by default)
- Bond is **refunded** if appeal succeeds (decision changes)
- Bond is **paid to prior round resolvers** if appeal fails (decision upheld)
- `recordAppealBond()` is called during escalation
- `AppealBondRecorded`, `AppealBondRefunded`, `AppealBondPaidToResolvers` events are emitted

### Key Differences

| Aspect           | Old (Fees)              | New (Bonds)                                       |
| ---------------- | ----------------------- | ------------------------------------------------- |
| **Payment Type** | Fee (non-refundable)    | Bond (refundable)                                 |
| **Calculation**  | Fixed fee per level     | Quadratic cost curve: `baseCost + stepSize * k^2` |
| **Refund**       | Never                   | Yes, if appeal succeeds                           |
| **Distribution** | To treasury             | To prior round resolvers (if appeal fails)        |
| **Function**     | `recordEscalationFee()` | `recordAppealBond()`                              |
| **Module**       | V1 only                 | V2+ only                                          |

---

## Current Test Failures

### Failing Tests (5 total)

1. **`test_recordAppealBond_Integration`** - Error: `NoPending()`
   - **Issue**: Escalation cost config not activated (needs 7-day delay bypass)
   - **Location**: `IncentiveModuleIntegration.test.t.sol:202`

2. **`test_recordAppealBond_PreventDuplicate`** - Error: `NoPending()`
   - **Issue**: Same as above - config activation issue
   - **Location**: `IncentiveModuleIntegration.test.t.sol:247`

3. **`test_distributeAppealBond_AppealSucceeds`** - Error: `InvalidAmount("Fee")`
   - **Issue**: Test tries to escalate without bond payment
   - **Location**: `IncentiveModuleIntegration.test.t.sol:322`

4. **`test_distributeAppealBond_AppealFails`** - Error: `InvalidAmount("Fee")`
   - **Issue**: Same - missing bond payment on escalation
   - **Location**: `IncentiveModuleIntegration.test.t.sol:383`

5. **`test_BondDistribution_RoundingError`** - Error: `InvalidAmount("Fee")`
   - **Issue**: Same - missing bond payment
   - **Location**: `IncentiveModuleIntegration.test.t.sol:451`

---

## Essential Information for Fixing Tests

### 1. Appeal Bond Flow

**How Bonds Work**:

1. User calls `escalateDispute(workflowId)` with ETH value = bond amount
2. `BaseEscrow.escalateDispute()` calls `DisputeOps.computeEscalation()`
3. `DecentralizedResolutionModule.canEscalate()` returns bond amount (not fee)
4. `BaseEscrow` transfers ETH to incentive module
5. `BaseEscrow` calls `incentiveModule.recordAppealBond(workflowId, depositor, amount, token, round)`
6. When dispute finalizes:
   - If appeal succeeded: `distributeAppealBond(workflowId, priorRound, true)` → refunds to depositor
   - If appeal failed: `distributeAppealBond(workflowId, priorRound, false)` → pays to resolvers

### 2. Escalation Cost Configuration

**Configuration Structure**:

```solidity
EscalationCostConfig {
    enabled: true,
    curveType: CostCurveType.QUADRATIC,
    baseCost: 0.01 ether,      // Base bond amount
    stepSize: 0.01 ether,       // Step size for quadratic curve
    multiplier: 0,              // Not used for quadratic
    bondToken: address(0)      // ETH (or ERC20 address)
}
```

**Bond Calculation**:

- Round 0 → 1: `baseCost + stepSize * 0^2 = 0.01 ether`
- Round 1 → 2: `baseCost + stepSize * 1^2 = 0.02 ether`

**Activation**:

- Uses slow-lane governance (7-day delay)
- Must call `queueEscalationCostConfig()` then wait 7 days, then `activateEscalationCostConfig()`
- **For tests**: Use `vm.warp(block.timestamp + 7 days + 1)` to bypass delay

### 3. Test Setup Requirements

**For V2 Bond Tests**:

1. Deploy `ResolverIncentiveModuleV2` (not V1)
2. Set incentive module in resolution module: `resolutionModule.setIncentiveModule(address(incentiveModuleV2))`
3. Configure escalation cost:
   ```solidity
   EscalationCostConfig memory costConfig = EscalationCostConfig({
       enabled: true,
       curveType: CostCurveType.QUADRATIC,
       baseCost: 0.01 ether,
       stepSize: 0.01 ether,
       multiplier: 0,
       bondToken: address(0)
   });
   resolutionModule.queueEscalationCostConfig(costConfig);
   vm.warp(block.timestamp + 7 days + 1); // Bypass delay
   resolutionModule.activateEscalationCostConfig();
   ```
4. When escalating: `escrow.escalateDispute{value: bondAmount}(workflowId)`

### 4. Bond Distribution Logic

**When Appeal Succeeds** (decision changes):

- `distributeAppealBond(workflowId, priorRound, true)`
- Bond refunded to depositor via `_refundBond()` (push pattern - immediate transfer)
- Event: `AppealBondRefunded`

**When Appeal Fails** (decision upheld):

- `distributeAppealBond(workflowId, priorRound, false)`
- Bond paid to resolvers from `priorRound` via `_payBondToResolvers()` (pull pattern - added to `claimablePayments`)
- Event: `AppealBondPaidToResolvers`

**Resolver Matching**:

- Resolvers are matched by `level` field in `disputeResolvers[workflowId]` array
- `level` corresponds to round number (0, 1, 2)
- Bond is split equally among resolvers at that round (with remainder handling)

### 5. Rounding Fix Implementation

**Fixed in `_payBondToResolvers()`**:

```solidity
uint256 amountPerResolver = bond.amount / count;
uint256 remainder = bond.amount % count;

for (uint256 i = 0; i < count; i++) {
    uint256 payment = amountPerResolver;
    if (i < remainder) {
        payment += 1; // Distribute remainder to first resolver(s)
    }
    claimablePayments[workflowId][eligibleResolvers[i]] += payment;
}
```

**Test Verification**:

- Total distributed must equal bond amount (no wei loss)
- Remainder distributed to first resolver(s)

---

## Specific Fixes Needed

### Fix 1: `test_recordAppealBond_Integration` and `test_recordAppealBond_PreventDuplicate`

**Error**: `NoPending()` when trying to activate escalation cost config

**Root Cause**: Config is queued but not activated (7-day delay)

**Fix**:

```solidity
vm.prank(timelock);
resolutionModule.queueEscalationCostConfig(costConfig);

// Bypass 7-day delay for tests
vm.warp(block.timestamp + 7 days + 1);

vm.prank(timelock);
resolutionModule.activateEscalationCostConfig();
```

### Fix 2: `test_distributeAppealBond_AppealSucceeds`, `test_distributeAppealBond_AppealFails`, `test_BondDistribution_RoundingError`

**Error**: `InvalidAmount("Fee")` when escalating

**Root Cause**:

1. Escalation cost config not activated (needs 7-day delay bypass)
2. Escalation requires bond payment, but test doesn't send ETH or config not set up

**Fix Pattern**:

```solidity
// 1. Switch to V2 and configure escalation cost
vm.prank(timelock);
resolutionModule.setIncentiveModule(address(incentiveModuleV2));

EscalationCostConfig memory costConfig = EscalationCostConfig({
    enabled: true,
    curveType: CostCurveType.QUADRATIC,
    baseCost: 0.01 ether,
    stepSize: 0.01 ether,
    multiplier: 0,
    bondToken: address(0)
});
vm.prank(timelock);
resolutionModule.queueEscalationCostConfig(costConfig);
vm.warp(block.timestamp + 7 days + 1);  // CRITICAL: Bypass delay
vm.prank(timelock);
resolutionModule.activateEscalationCostConfig();

// 2. Get required bond amount
bytes memory escrowData = abi.encode(token, user1, user2, amountAfterFee);
(uint256 bondAmount, address bondToken) = resolutionModule.getRequiredAppealBond(
    workflowId, 0, escrowData
);

// 3. Fund user and escalate with bond
vm.deal(user1, bondAmount);
vm.prank(user1);
escrow.escalateDispute{value: bondAmount}(workflowId);
```

**Note**:

- `bondToken` will be `address(0)` for ETH bonds
- If ERC20, user must approve escrow contract which then transfers to incentive module
- Bond amount is returned by `canEscalate()` and stored in `result.escalationFee` field (legacy naming)

### Fix 3: Remove or Update Escalation Fee Tests

**Files to Check**:

- `test/foundry/core/EscalationFeeEnforcement.t.sol.disabled` - Already disabled, good
- `test/foundry/migrated/EscalationFee.test.t.sol` - **NEEDS REVIEW**
- Any tests calling `recordEscalationFee()` - **SHOULD BE REMOVED OR UPDATED**

**Action**:

- Remove tests that verify escalation fee collection
- Replace with appeal bond tests if functionality is similar
- Update any tests that call `recordEscalationFee()` to use `recordAppealBond()` instead

### Fix 4: Test Setup - Resolver Recording

**Issue**: Tests need resolvers recorded at specific rounds for bond distribution

**Current Pattern** (correct):

```solidity
vm.prank(address(escrow));
incentiveModule.recordResolver(workflowId, resolver1, 0); // Round 0
```

**For Bond Distribution Tests**:

- Must record resolvers at the round being appealed FROM
- Example: Testing bond distribution for round 0 → 1 escalation:
  - Record resolver at round 0: `recordResolver(workflowId, resolver1, 0)`
  - Bond is recorded at round 1: `recordAppealBond(workflowId, depositor, amount, token, 1)`
  - When distributing: `distributeAppealBond(workflowId, 0, outcomeFlipped)` - pays to round 0 resolvers

---

## Test File Locations

### Files Needing Fixes

1. **`test/foundry/decentralized-resolution-module/IncentiveModuleIntegration.test.t.sol`**
   - Fix: Add bond payment to escalation calls
   - Fix: Add time warp for config activation
   - Status: 5 failing tests

2. **`test/foundry/migrated/EscalationFee.test.t.sol`** (if exists)
   - Action: Remove or convert to appeal bond tests
   - Status: Unknown - needs verification

3. **`test/foundry/core/EscalationFeeEnforcement.t.sol.disabled`**
   - Status: Already disabled - leave as-is

### Files That Are Correct

1. **`test/foundry/decentralized-resolution-module/AppealBondRecording.unit.t.sol`**
   - Status: Should be working (unit tests, no integration)

2. **`test/foundry/decentralized-resolution-module/AppealBondDistribution.unit.t.sol`**
   - Status: Should be working (unit tests)

3. **`test/foundry/decentralized-resolution-module/BondRounding.unit.t.sol`**
   - Status: Should be working (unit tests)

---

## Key Contract Interfaces

### ResolverIncentiveModuleV2 Functions

```solidity
// Record bond (called by BaseEscrow during escalation)
function recordAppealBond(
  uint256 workflowId,
  address depositor,
  uint256 amount,
  address token,
  uint8 round
) external onlyEscrowContract;

// Distribute bond (called when dispute finalizes)
function distributeAppealBond(
  uint256 workflowId,
  uint8 round, // Round being appealed FROM
  bool outcomeFlipped // true = appeal succeeded, false = failed
) external onlyEscrowContract;

// Get bond record
function getAppealBond(
  uint256 workflowId,
  uint8 round
) external view returns (AppealBondRecord memory);
```

### DecentralizedResolutionModule Functions

```solidity
// Get required bond amount
function getRequiredAppealBond(
  uint256 workflowId,
  uint8 currentLevel,
  bytes calldata escrowData
) external view returns (uint256 amount, address token);

// Configure escalation costs (governance)
function queueEscalationCostConfig(
  EscalationCostConfig memory config
) external onlyRole(ROLE_TIMELOCK);

function activateEscalationCostConfig() external onlyRole(ROLE_TIMELOCK); // Requires 7-day delay
```

### BaseEscrow.escalateDispute()

**Signature**: `function escalateDispute(uint256 workflowId) public payable`

**Behavior**:

- Accepts ETH via `msg.value` (bond amount)
- Calls `DisputeOps.computeEscalation()` which returns bond amount
- If bond token is ETH: transfers to incentive module, then calls `recordAppealBond()`
- If bond token is ERC20: assumes tokens already in contract (user must approve/transfer first)

---

## Test Patterns to Follow

### Pattern 1: Escalation with Bond (ETH)

```solidity
// 1. Configure escalation cost
EscalationCostConfig memory costConfig = EscalationCostConfig({
    enabled: true,
    curveType: CostCurveType.QUADRATIC,
    baseCost: 0.01 ether,
    stepSize: 0.01 ether,
    multiplier: 0,
    bondToken: address(0)  // ETH
});
vm.prank(timelock);
resolutionModule.queueEscalationCostConfig(costConfig);
vm.warp(block.timestamp + 7 days + 1);  // Bypass delay
vm.prank(timelock);
resolutionModule.activateEscalationCostConfig();

// 2. Get required bond
bytes memory escrowData = abi.encode(token, from, to, amount);
(uint256 bondAmount, address bondToken) = resolutionModule.getRequiredAppealBond(
    workflowId, 0, escrowData
);

// 3. Escalate with bond
vm.deal(user1, bondAmount);
vm.prank(user1);
escrow.escalateDispute{value: bondAmount}(workflowId);

// 4. Verify bond recorded
AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(workflowId, 1);
assertEq(bond.amount, bondAmount);
assertEq(bond.depositor, user1);
```

### Pattern 2: Bond Distribution on Appeal Success

```solidity
// Setup: Bond at round 1, decision at round 0 (CANCEL), decision at round 1 (RELEASE)
// This is a reversal, so appeal succeeded

// Record bond
vm.deal(address(incentiveModuleV2), 0.01 ether);
vm.prank(address(escrow));
incentiveModuleV2.recordAppealBond(workflowId, user1, 0.01 ether, address(0), 1);

// Record resolver at round 0
vm.prank(address(escrow));
incentiveModuleV2.recordResolver(workflowId, resolver1, 0);

// Simulate decisions
vm.prank(address(escrow));
resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.CANCEL, 1 days);

// Escalate (bond already recorded above)
vm.prank(user1);
escrow.escalateDispute{value: 0.01 ether}(workflowId);

// New decision (reversal)
vm.prank(address(escrow));
resolutionModule.recordResolution(workflowId, seniorResolver, ResolutionOutcome.RELEASE, 1 days);

// Record reversal - triggers bond distribution
uint256 balanceBefore = user1.balance;
vm.prank(address(escrow));
resolutionModule.recordReversal(workflowId, 0);

// Verify bond refunded
AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(workflowId, 1);
assertTrue(bond.distributed);
assertTrue(bond.refunded);
// Note: Balance check may not work if refund happens in different transaction
```

### Pattern 3: Bond Distribution on Appeal Failure

```solidity
// Setup: Bond at round 1, same decision at both rounds (appeal failed)

// Record resolvers at round 0
vm.prank(address(escrow));
incentiveModuleV2.recordResolver(workflowId, resolver1, 0);
vm.prank(address(escrow));
incentiveModuleV2.recordResolver(workflowId, resolver2, 0);

// Record bond
vm.deal(address(incentiveModuleV2), 0.01 ether);
vm.prank(address(escrow));
incentiveModuleV2.recordAppealBond(workflowId, user1, 0.01 ether, address(0), 1);

// Same decision at both rounds
vm.prank(address(escrow));
resolutionModule.recordResolution(workflowId, resolver1, ResolutionOutcome.CANCEL, 1 days);
vm.prank(user1);
escrow.escalateDispute{value: 0.01 ether}(workflowId);
vm.prank(address(escrow));
resolutionModule.recordResolution(workflowId, seniorResolver, ResolutionOutcome.CANCEL, 1 days);

// Finalize - should distribute bond to round 0 resolvers
vm.prank(address(escrow));
resolutionModule.finalizeDispute(workflowId);

// Verify resolvers can claim
uint256 claimable1 = incentiveModuleV2.getClaimablePayment(workflowId, resolver1);
uint256 claimable2 = incentiveModuleV2.getClaimablePayment(workflowId, resolver2);
assertTrue(claimable1 > 0);
assertTrue(claimable2 > 0);
assertEq(claimable1 + claimable2, 0.01 ether);  // Total equals bond
```

---

## Common Mistakes to Avoid

1. **Don't call `recordEscalationFee()`** - This function still exists in V1 but is deprecated. Use `recordAppealBond()` for V2.

2. **Don't forget bond payment** - Escalation requires `msg.value` = bond amount when bond token is ETH.

3. **Don't forget config activation delay** - Must warp time forward 7 days after queueing.

4. **Don't mix rounds** - Bond is recorded at the round being escalated TO (round+1), but distributed based on the round being appealed FROM.

5. **Don't forget resolver recording** - Resolvers must be recorded at the correct round for bond distribution to work.

6. **Event parameter names** - Events use `escrowId` not `workflowId` in some cases. Check actual event definitions.

---

## Files to Review

### Must Fix

- `test/foundry/decentralized-resolution-module/IncentiveModuleIntegration.test.t.sol` - 5 failing tests

### Should Review/Update

- `test/foundry/migrated/EscalationFee.test.t.sol` - **REMOVE** (just a placeholder, no real tests)
- `test/foundry/core/PaymentBoundsChecking.t.sol` - Uses `recordEscalationFee()` - **UPDATE** to use bonds or remove escalation fee tests
- `test/foundry/core/ResolverIncentiveModuleComprehensive.t.sol` - Has `test_RecordEscalationFee()` - **UPDATE** or remove
- `test/foundry/core/EscalationFeeEnforcement.t.sol.disabled` - Already disabled, leave as-is

### Reference (Working Examples)

- `test/foundry/decentralized-resolution-module/AppealBondRecording.unit.t.sol` - Good examples
- `test/foundry/decentralized-resolution-module/AppealBondDistribution.unit.t.sol` - Good examples
- `test/foundry/decentralized-resolution-module/BondRounding.unit.t.sol` - Good examples

---

## Expected Outcomes

After fixes:

- All 5 failing tests should pass
- Tests should properly verify:
  - Bond recording during escalation
  - Bond refund on successful appeal
  - Bond distribution to resolvers on failed appeal
  - Rounding error fix (no wei loss)
- Escalation fee tests removed or converted

---

## Quick Reference: Key Changes Summary

| Old (Fees)                | New (Bonds)                        |
| ------------------------- | ---------------------------------- |
| `recordEscalationFee()`   | `recordAppealBond()`               |
| Fee to treasury           | Bond refunded or paid to resolvers |
| `EscalationFeePaid` event | `AppealBondRecorded` event         |
| Fixed fee amount          | Quadratic cost curve               |
| Non-refundable            | Refundable if appeal succeeds      |
| V1 only                   | V2+ only                           |

---

## Specific Test Fixes Required

### Fix 1: `test_recordAppealBond_Integration` (Line ~202)

**Current Issue**: `NoPending()` error - config not activated

**Fix**: Add time warp after queueing:

```solidity
vm.prank(timelock);
resolutionModule.queueEscalationCostConfig(costConfig);
vm.warp(block.timestamp + 7 days + 1);  // ADD THIS
vm.prank(timelock);
resolutionModule.activateEscalationCostConfig();
```

### Fix 2: `test_recordAppealBond_PreventDuplicate` (Line ~265)

**Current Issue**: Same as Fix 1 - config activation

**Fix**: Same as Fix 1 - add time warp

### Fix 3: `test_distributeAppealBond_AppealSucceeds` (Line ~320)

**Current Issue**: `InvalidAmount("Fee")` - missing bond payment and/or config

**Fix**:

1. Add escalation cost config setup (like Fix 1)
2. Bond is already recorded manually (line 346) - this is fine for testing
3. When escalating (line 355), ensure bond amount matches what was recorded
4. The test already has `{value: 0.01 ether}` which is correct

**Note**: This test manually records bond before escalation. That's fine for testing, but in real flow, bond is recorded during escalation.

### Fix 4: `test_distributeAppealBond_AppealFails` (Line ~383)

**Current Issue**: `InvalidAmount("Fee")` - missing config and bond payment

**Current Code** (Line ~417):

```solidity
// Escalate to round 1
vm.prank(user1);
escrow.escalateDispute(workflowId);  // ❌ Missing bond payment
```

**Fix**:

1. Add escalation cost config setup at start of test (after switching to V2)
2. Get bond amount and add payment:

```solidity
// Get required bond amount
bytes memory escrowData = abi.encode(address(token), user1, user2, amountAfterFee);
(uint256 bondAmount, ) = resolutionModule.getRequiredAppealBond(workflowId, 0, escrowData);

// Escalate to round 1 with bond payment
vm.deal(user1, bondAmount);
vm.prank(user1);
escrow.escalateDispute{value: bondAmount}(workflowId);  // ✅ Add bond payment
```

### Fix 5: `test_BondDistribution_RoundingError` (Line ~443)

**Current Issue**: `InvalidAmount("Fee")` - missing config and bond payment

**Current Code** (Line ~484):

```solidity
vm.prank(user1);
escrow.escalateDispute(workflowId);  // ❌ Missing bond payment
```

**Fix**:

1. Add escalation cost config setup
2. Add bond payment (test uses 100 wei bond, so payment should match):

```solidity
// Get required bond amount (or use known amount: 100 wei)
vm.deal(user1, 100);
vm.prank(user1);
escrow.escalateDispute{value: 100}(workflowId);  // ✅ Add bond payment
```

**Note**: This test manually records a 100 wei bond (line 478), so the escalation bond should also be 100 wei to match.

---

## Additional Notes

### Escalation Fee Tests to Remove/Update

1. **`test/foundry/core/PaymentBoundsChecking.t.sol`** (Line 63):
   - Calls `recordEscalationFee()` - **REMOVE** this call or convert to bond test
   - Test is about payment bounds, not escalation fees specifically
   - Can keep test but remove escalation fee recording

2. **`test/foundry/core/ResolverIncentiveModuleComprehensive.t.sol`** (Line 128):
   - `test_RecordEscalationFee()` - **REMOVE** or convert to `test_RecordAppealBond()`
   - Escalation fees are deprecated in favor of bonds

3. **`test/foundry/migrated/EscalationFee.test.t.sol`**:
   - Just a placeholder - **REMOVE** entirely

---

## Verification Checklist

After fixes, verify:

- [ ] All 5 failing tests pass
- [ ] Escalation cost config is activated in all bond tests (with time warp)
- [ ] Bond payments are sent with `{value: bondAmount}` on escalation
- [ ] No tests call `recordEscalationFee()` (except in V1-only tests)
- [ ] Bond distribution tests verify correct behavior (refund vs pay to resolvers)
- [ ] Rounding tests verify no wei loss

---

## Important Implementation Details

### Bond Recording During Escalation

**In Real Flow** (BaseEscrow.escalateDispute):

1. User calls `escalateDispute{value: bondAmount}(workflowId)`
2. BaseEscrow gets bond amount from `canEscalate()` (stored in `result.escalationFee`)
3. BaseEscrow transfers ETH to incentive module
4. BaseEscrow calls `incentiveModule.recordAppealBond()`

**In Tests**:

- You can manually record bond before escalation (for testing convenience)
- OR let the real flow record it during escalation
- Both approaches are valid for testing

### Appeal Window and Finalization

**Important**: Disputes must be finalized before bond distribution can complete:

- `finalizeDispute()` calls `onDisputeFinalized()` hook
- `finalizeDispute()` also distributes all pending appeal bonds
- Appeal window must expire OR dispute must be at final round (MAX_ROUND = 2)

**For Tests**:

- Can call `finalizeDispute()` directly (bypasses appeal window check if at final round)
- OR warp time forward to expire appeal window

---

## Quick Fix Template

For each failing test, add this pattern after switching to V2:

```solidity
// 1. Configure and activate escalation cost
DecentralizedResolverStructs.EscalationCostConfig memory costConfig =
    DecentralizedResolverStructs.EscalationCostConfig({
        enabled: true,
        curveType: DecentralizedResolverStructs.CostCurveType.QUADRATIC,
        baseCost: 0.01 ether,
        stepSize: 0.01 ether,
        multiplier: 0,
        bondToken: address(0)
    });
vm.prank(timelock);
resolutionModule.queueEscalationCostConfig(costConfig);
vm.warp(block.timestamp + 7 days + 1);  // Bypass delay
vm.prank(timelock);
resolutionModule.activateEscalationCostConfig();

// 2. When escalating, get bond amount and send payment
bytes memory escrowData = abi.encode(token, user1, user2, amountAfterFee);
(uint256 bondAmount, address bondToken) = resolutionModule.getRequiredAppealBond(
    workflowId, currentRound, escrowData
);
vm.deal(user1, bondAmount);
vm.prank(user1);
escrow.escalateDispute{value: bondAmount}(workflowId);
```

---

**End of Prompt**
