# Phase 1: Simplified Implementation Plan

## User Decisions

1. ✅ **Fixed Appeal Window Duration** - One duration in BaseEscrow, updatable by governance
2. ✅ **Remove Partial Resolution Support** - Discuss impact below
3. ✅ **Always Enforce Appeal Window** - No exceptions, consistent behavior

---

## Impact Analysis: Removing Partial Resolution Support

### Current Partial Resolution Usage

**Functions to Remove:**

- `partialReleaseAsDisputeResolver(uint256 workflowId, uint256 amount, bytes32 resolutionHash)`
- `partialCancelAsDisputeResolver(uint256 workflowId, uint256 amount, bytes32 resolutionHash)`
- `_executePartialResolution()` internal function

**Current Behavior:**

- Resolver can release/cancel partial amounts (e.g., 50% release, 50% cancel)
- Multiple partial resolutions can complete an escrow
- State remains `DISPUTED` until `remainingBalance == 0`
- Each partial sets claimable balance immediately (Phase 0)

**Test Coverage:**

- `test/hardhat/EscrowableERC20.ts`: "Should handle partial refund (75%) then partial release (25%) and resolve"
- `test/hardhat/CoreContractsCoverage.test.ts`: "Should allow resolver to partial release"
- `test/foundry/broken/PartialOperationsComprehensive.sol.disabled` (already disabled)

### Impact of Removal

**✅ Benefits:**

- **Simpler state machine** - No partial resolution tracking
- **Simpler logic** - Only full resolution paths
- **Easier appeal window enforcement** - Only one resolution per escrow
- **Consistent behavior** - All resolutions are full
- **Less code** - Remove ~100 lines of partial resolution code
- **Fewer edge cases** - No "isComplete" checks, no partial yield handling

**❌ Drawbacks:**

- **Less flexibility** - Resolvers can only do full release or full cancel
- **Breaking change** - Existing partial resolution functions removed
- **Migration** - Any in-progress partial resolutions need handling

**🔧 Migration Considerations:**

- Existing escrows with partial resolutions: Only escrows with `remainingBalance > 0` and `escrowState == DISPUTED`
- Options:
  1. **Force complete** - Governance can force-complete partial escrows
  2. **Allow legacy** - Keep partial functions deprecated for legacy escrows (not recommended)
  3. **Clean slate** - Only new escrows use simplified model (recommended)

**💡 Recommendation:**
Remove partial resolution support. Benefits (simplicity, consistency) outweigh costs (flexibility). Resolvers can still make nuanced decisions off-chain, but on-chain execution is binary (full release or full cancel).

---

## Additional Simplifications

### 1. Remove `amount` Parameter from Resolution Functions

**Current:**

```solidity
function _executeResolution(uint256 workflowId, bool isRelease, uint256 amount, bytes32 resolutionHash)
// amount: If 0 or >= remainingBalance, treat as full. If < remainingBalance, treat as partial.
```

**Simplified:**

```solidity
function _executeResolution(uint256 workflowId, bool isRelease, bytes32 resolutionHash)
// Always uses remainingBalance - no amount parameter needed
```

**Benefits:**

- ✅ Simpler function signatures
- ✅ No partial/full logic needed
- ✅ Always full resolution
- ✅ Less confusion

**Changes:**

- Remove `amount` parameter from `_executeResolution()`
- Remove `isFull` logic
- Always use `et.remainingBalance`

---

### 2. Unify Yield Handling (Remove Partial Yield Path)

**Current:**

- `handleFullYield()` - for full resolutions
- `handlePartialYield()` - for partial resolutions (no longer needed)

**Simplified:**

- Only `handleFullYield()` - all resolutions are full

**Benefits:**

- ✅ Remove `handlePartialYield()` complexity
- ✅ Single yield handling path
- ✅ Simpler YieldOps integration

**Changes:**

- Remove `handlePartialYield()` calls
- Only use `handleFullYield()` for all resolutions

---

### 3. Remove `remainingBalance` Tracking Complexity

**Current:**

- `remainingBalance` decrements with partial resolutions
- `isComplete` checks: `remainingBalance == 0`
- State transitions based on completion

**Simplified:**

- `remainingBalance` always equals `totalDeposited` at resolution time
- No `isComplete` checks needed
- State always transitions immediately

**Benefits:**

- ✅ Simpler state management
- ✅ No partial tracking
- ✅ Immediate state transitions

**Note:** `remainingBalance` still needed for:

- Yield calculations (remainingBalance at resolution time)
- Escrow data encoding
- But no partial decrements needed

---

### 4. Simplify Resolution Interface

**Current Interface (RESOLUTION_INTERFACE_V1):**

```solidity
bytes4 RESOLUTION_INTERFACE_V1 =
    bytes4(keccak256("cancelAsDisputeResolver(uint256,bytes32)")) ^
    bytes4(keccak256("releaseAsDisputeResolver(uint256,bytes32)")) ^
    bytes4(keccak256("partialReleaseAsDisputeResolver(uint256,uint256,bytes32)")) ^
    bytes4(keccak256("partialCancelAsDisputeResolver(uint256,uint256,bytes32)"));
```

**Simplified Interface:**

```solidity
bytes4 RESOLUTION_INTERFACE_V1 =
    bytes4(keccak256("cancelAsDisputeResolver(uint256,bytes32)")) ^
    bytes4(keccak256("releaseAsDisputeResolver(uint256,bytes32)"));
```

**Benefits:**

- ✅ Simpler interface
- ✅ Only two functions (release or cancel)
- ✅ Consistent with "no partial" decision

---

### 5. Remove `isComplete` Logic

**Current:**

```solidity
bool isComplete = (et.remainingBalance == 0);
if (isComplete) {
    et.escrowState = EscrowState.RESOLVED;
    totalEscrowsPending--;
    delete disputeRaisedTimestamp[workflowId];
}
```

**Simplified:**

```solidity
// Always complete - no check needed
et.escrowState = EscrowState.RESOLVED;
totalEscrowsPending--;
delete disputeRaisedTimestamp[workflowId];
```

**Benefits:**

- ✅ No conditional logic
- ✅ Always complete
- ✅ Simpler code

---

### 6. Simplify Pending Settlement Structure

**Current:**

```solidity
struct PendingSettlement {
  bool exists;
  bool isRelease;
  uint256 amount;
  uint256 appealDeadline;
  uint8 round;
  bytes32 resolutionHash;
}
```

**Simplified (remove unused fields):**

```solidity
struct PendingSettlement {
  bool exists;
  bool isRelease;
  uint256 appealDeadline;
  bytes32 resolutionHash;
}
```

**Removed fields:**

- `amount` - Always equals `remainingBalance` (can compute)
- `round` - Not needed if we don't query module state

**Benefits:**

- ✅ Smaller struct (less storage)
- ✅ Simpler structure
- ✅ Less data to track

---

### 7. Remove Module State Query Complexity

**Current Plan:**

- Query `appealWindows[currentRound]` from module
- Query `appealDeadline` from module
- Handle module-specific structs

**Simplified:**

- Use fixed `appealWindowDuration` (governance-controlled)
- Compute `appealDeadline = block.timestamp + appealWindowDuration`
- No module queries needed

**Benefits:**

- ✅ No module coupling
- ✅ No struct decoding
- ✅ Predictable behavior
- ✅ Governance-controlled

**Implementation:**

```solidity
uint256 public appealWindowDuration = 2 days;

function setAppealWindowDuration(uint256 duration) external onlyRole(ROLE_TIMELOCK) {
    appealWindowDuration = duration;
    emit AppealWindowDurationUpdated(duration);
}
```

---

### 8. Remove Exception: Final-Level Immediate Finalization

**Current Plan:**

- Check if `appealWindows[currentRound] == 0` (final level)
- If 0: finalize immediately
- If > 0: store pending settlement

**Simplified (always enforce):**

- Always store pending settlement
- Always enforce appeal window
- No exceptions

**Benefits:**

- ✅ Consistent behavior
- ✅ No special cases
- ✅ Simpler logic

**Trade-off:**

- Final-level resolutions (e.g., Kleros) wait for appeal window
- But consistent behavior is worth it

---

### 9. Simplify State Machine (Remove Partial States)

**Current:**

- `DISPUTED` → (partial resolution) → `DISPUTED` → (final partial) → `RESOLVED`
- `DISPUTED` → (full resolution) → `RESOLVED`

**Simplified:**

- `DISPUTED` → (full resolution) → `PENDING_SETTLEMENT` → (after appeal window) → `RESOLVED`
- Always single transition path

**Benefits:**

- ✅ Simpler state machine
- ✅ No partial states
- ✅ Easier to reason about

**Note:** We can still reuse `DISPUTED` state during appeal window (as planned), or add explicit state.

---

### 10. Remove Conditional Event Emissions

**Current:**

```solidity
if (isRelease) {
    emit EscrowTransferResolvedWithPartialRelease(...);
} else {
    emit EscrowTransferResolvedWithPartialCancel(...);
}
if (isComplete) {
    emit EscrowTransferResolved(...);
}
```

**Simplified:**

```solidity
emit EscrowResolved(workflowId, _msgSender(), resolutionHash);
emit EscrowTransferResolved(workflowId, et.from, et.to, et.totalDeposited);
```

**Benefits:**

- ✅ Simpler events
- ✅ No conditional emissions
- ✅ Consistent event structure

---

## Summary of Simplifications

| Simplification                      | Removes                                          | Benefits                           |
| ----------------------------------- | ------------------------------------------------ | ---------------------------------- |
| **1. Remove Partial Resolution**    | Partial functions, `_executePartialResolution()` | Simpler state, consistent behavior |
| **2. Remove `amount` Parameter**    | Amount logic, partial/full checks                | Simpler signatures, always full    |
| **3. Unify Yield Handling**         | `handlePartialYield()`                           | Single yield path                  |
| **4. Simplify Interface**           | Partial functions from interface                 | Two functions only                 |
| **5. Remove `isComplete` Logic**    | Conditional completion checks                    | Always complete                    |
| **6. Simplify Pending Settlement**  | `amount`, `round` fields                         | Smaller struct                     |
| **7. Fixed Appeal Window**          | Module state queries                             | No module coupling                 |
| **8. Always Enforce Appeal Window** | Final-level exception                            | Consistent behavior                |
| **9. Simplify State Machine**       | Partial states                                   | Single path                        |
| **10. Simplify Events**             | Conditional emissions                            | Consistent events                  |

---

## Simplified Implementation Flow

### Resolution Flow (Simplified)

```solidity
function releaseAsDisputeResolver(
  uint256 workflowId,
  bytes32 resolutionHash
) public nonReentrant returns (bool) {
  return _executeResolution(workflowId, true, resolutionHash);
}

function cancelAsDisputeResolver(
  uint256 workflowId,
  bytes32 resolutionHash
) public nonReentrant returns (bool) {
  return _executeResolution(workflowId, false, resolutionHash);
}

function _executeResolution(
  uint256 workflowId,
  bool isRelease,
  bytes32 resolutionHash
) internal returns (bool) {
  // 1. Validate
  _validateWorkflowId(workflowId);
  EscrowTransfer storage et = escrowTransfers[workflowId];
  require(et.escrowState == EscrowState.DISPUTED, 'Not in dispute');

  // 2. Authorize
  require(_isAuthorizedDisputeResolver(workflowId, _msgSender()), 'Not authorized');

  // 3. Record resolution (sets appeal deadline in module)
  _recordResolutionOutcome(workflowId, _msgSender(), isRelease, resolutionHash);

  // 4. Compute appeal deadline
  uint256 appealDeadline = block.timestamp + appealWindowDuration;

  // 5. Store pending settlement
  pendingSettlements[workflowId] = PendingSettlement({
    exists: true,
    isRelease: isRelease,
    appealDeadline: appealDeadline,
    resolutionHash: resolutionHash
  });

  // 6. Keep state as DISPUTED (not RESOLVED yet)
  emit PendingSettlementSet(workflowId, isRelease, appealDeadline);

  return true;
}

function finalizeAfterAppealWindow(uint256 workflowId) external nonReentrant {
  // 1. Validate
  _validateWorkflowId(workflowId);
  PendingSettlement storage pending = pendingSettlements[workflowId];
  require(pending.exists, 'No pending settlement');
  require(block.timestamp >= pending.appealDeadline, 'Appeal window not expired');

  // 2. Check not escalated (verify dispute status in module - optional)
  // For now, just check appeal deadline expired

  // 3. Get escrow data
  EscrowTransfer storage et = escrowTransfers[workflowId];
  uint256 amount = et.remainingBalance; // Always full amount

  // 4. Handle yield
  address token = et.token;
  IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
  if (address(yieldOps) != address(0) && address(genModule) != address(0)) {
    IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
    try yieldOps.handleFullYield(genModule, distModule, workflowId, token, amount) {} catch {}
  }

  // 5. Set claimable balance
  address recipient = pending.isRelease ? et.to : et.from;
  claimable[workflowId][recipient][token] += amount;
  emit ClaimableBalanceSet(workflowId, recipient, token, amount);

  // 6. Update state
  et.escrowState = EscrowState.RESOLVED;
  et.remainingBalance = 0; // Always 0 after full resolution
  totalEscrowsPending--;
  delete disputeRaisedTimestamp[workflowId];
  delete pendingSettlements[workflowId];

  // 7. Emit events
  emit EscrowFinalized(workflowId, recipient, amount);
  emit EscrowTransferResolved(workflowId, et.from, et.to, et.totalDeposited);
}
```

---

## Code Reduction Estimate

**Current Complexity:**

- Partial resolution functions: ~150 lines
- `_executePartialResolution()`: ~65 lines
- Partial yield handling: ~50 lines
- Partial event logic: ~20 lines
- `isComplete` checks: ~15 lines
- Module state queries: ~80 lines
- **Total to remove: ~380 lines**

**Simplified Code:**

- Single resolution path: ~100 lines
- Fixed appeal window: ~20 lines
- Simplified pending settlement: ~50 lines
- **Total simplified: ~170 lines**

**Net Reduction: ~210 lines of code removed**

---

## Consistency Checklist

After simplifications, ensure:

- ✅ **No partial resolution paths** - Only full resolution
- ✅ **No conditional finalization** - Always enforce appeal window
- ✅ **No module state queries** - Use fixed duration
- ✅ **No `isComplete` checks** - Always complete
- ✅ **No partial yield handling** - Only full yield
- ✅ **No exception cases** - Consistent behavior
- ✅ **Single code path** - No branches
- ✅ **Simpler events** - No conditionals

---

## Next Steps

1. ✅ Fix bug in `_recordResolutionOutcome()` (wrong function signature)
2. ✅ Remove partial resolution functions
3. ✅ Simplify `_executeResolution()` to always use full resolution
4. ✅ Add fixed `appealWindowDuration` (governance-controlled)
5. ✅ Implement simplified pending settlement storage
6. ✅ Implement `finalizeAfterAppealWindow()`
7. ✅ Update tests to remove partial resolution cases
8. ✅ Update interface to remove partial functions
