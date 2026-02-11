# Cancel Semantics Design

## Current State

Cancel semantics are **hardcoded in BaseEscrow** with a **mutual consent model** that creates perverse incentives.

### Current Implementation

**Where Cancel is Defined:**
1. `senderCancel()` / `recipientCancel()` - BaseEscrow (lines 568-584)
   - Both parties must agree
   - Sets status flags: `SenderStatus.AGREE_TO_CANCEL`, `RecipientStatus.AGREE_TO_CANCEL`
   
2. `_cancelWorkflow()` - BaseEscrow (line 556)
   - Orchestrates the mutual consent check
   - Only executes `_cancelAndRefund()` when both parties agree
   
3. `_cancelAndRefund()` - BaseEscrow (lines 1321-1344)
   - Unwound yield
   - Refunds to SENDER only
   - Transitions state to REFUNDED

4. `automateTimedActions()` - BaseEscrow (lines 1007-1032)
   - Queries `SettlementOps.computeTimedActions()`
   - Returns: 1=auto-release, 2=auto-cancel, or 0=no action
   - **CRITICAL:** Release is checked before cancel (line 1023: `if (et.autoReleaseTime > 0)`)

**SettlementOps.computeTimedActions() Logic:**
```
if (autoReleaseTime > 0 && block.timestamp >= autoReleaseTime)
  return (1, true)  // Auto-release
else if (autoCancelTime > 0 && block.timestamp >= autoCancelTime)
  return (2, false) // Auto-cancel
else
  return (0, false) // No action
```

## The Problem: Seller Perverse Incentive

### Scenario: Buyer Wants Refund (Auto-Release Set)

```
Timeline:
  Day 0: Escrow created, autoReleaseTime=Day 10, autoCancelTime=Day 20
  
  Day 5: Buyer requests refund (calls recipientCancel)
    - Buyer status: AGREE_TO_CANCEL
    - Seller status: still NONE
    - Result: No refund (seller hasn't agreed)
    - Buyer is stuck waiting
  
  Day 10: Time passes
    - automateTimedActions() called (by keeper, user, or timelock)
    - computeTimedActions() checks: autoReleaseTime <= now?
    - Result: YES → return (1, true) // Auto-release
    - Refund status IGNORED
    - Seller gets funds automatically
    
  Outcome:
    ❌ Seller blocks cancellation indefinitely
    ❌ Seller waits for auto-release
    ❌ Buyer cannot force refund (mutual consent never achieved)
```

### Why This Happens

1. **Mutual Consent Model** requires both parties to agree
2. **Seller has no incentive to agree** if auto-release is coming
3. **Auto-Release Checked First** (line 1023: `if (et.autoReleaseTime > 0)`)
4. **Auto-Cancel Never Checked** if auto-release is true

Result: Auto-release overrides buyer's cancellation request.

## Issues with Current Architecture

### 1. Mutual Consent Blocks Buyer Control
- ❌ Buyer cannot force refund unilaterally
- ❌ Seller can block by simply not agreeing
- ❌ No time deadline on how long seller can refuse

### 2. Auto-Release vs Auto-Cancel Priority
- ❌ Release wins (checked first in automateTimedActions)
- ❌ If both times are set: auto-release always triggers first
- ❌ Auto-cancel never executes if auto-release is sooner
- ❌ Creates priority game between parties (who sets which time first)

### 3. Timed Actions Don't Account for Cancellation Status
- ❌ automateTimedActions() ignores cancel status flags
- ❌ Auto-release can execute even if buyer/seller are negotiating cancellation
- ❌ No "both parties requested cancel, override auto-release" logic

### 4. No Explicit Cancel Semantics Per-Escrow
- ❌ Cannot express: "buyer can cancel anytime"
- ❌ Cannot express: "seller can cancel anytime after Day 10"
- ❌ Cannot express: "one-party proposal, other party has 24h to reject"
- ❌ All escrows forced into same mutual-consent model

## Recommended Solution: Cancellation Strategy Module

### Architecture

Define `ICancellationStrategy` module with pluggable implementations.

**Interface:**
```solidity
interface ICancellationStrategy {
  /**
   * @notice Determine if cancellation is allowed for this caller
   * @dev Called by BaseEscrow._cancelWorkflow()
   * @param workflowId The escrow ID
   * @param caller The address requesting cancellation
   * @param et The EscrowTransfer state
   * @return allowed True if cancellation is allowed
   * @return immediate True if should execute immediately, false if queue/propose
   */
  function canCancel(
    uint256 workflowId,
    address caller,
    EscrowTransfer storage et
  ) external view returns (bool allowed, bool immediate);
}
```

### Standard Implementations

**1. MutualConsentWithAutoOverride (Default)**
```solidity
// Current behavior + auto-cancel override
// - Both parties must agree, OR
// - autoCancelTime has passed (forces refund)

function canCancel(workflowId, caller, et):
  // Check auto-cancel time first (hard deadline)
  if (block.timestamp >= et.autoCancelTime && et.autoCancelTime > 0):
    return (true, true)  // Force refund regardless of consent
  
  // Otherwise require mutual consent
  if (et.senderStatus == AGREE && et.recipientStatus == AGREE):
    return (true, true)
  
  return (false, false)
```

**2. BuyerUnilateralCancel**
```solidity
// Buyer can cancel anytime, seller cannot

function canCancel(workflowId, caller, et):
  if (caller == et.to):  // Buyer/recipient
    return (true, true)
  if (caller == et.from):  // Seller/sender
    return (false, false)  // Seller cannot initiate cancel
  
  return (false, false)
```

**3. SellerUnilateralCancel**
```solidity
// Seller can cancel anytime (for return goods cases)

function canCancel(workflowId, caller, et):
  if (caller == et.from):  // Seller/sender
    return (true, true)
  if (caller == et.to):  // Buyer/recipient
    return (false, false)
  
  return (false, false)
```

**4. TimedBuyerCancel**
```solidity
// Buyer can cancel before deadline, seller can cancel after deadline
// Represents: "30-day inspection period"

struct TimingConfig {
  buyerCancelDeadline: uint256  // Buyer can cancel until this time
  sellerCancelWindow: uint256   // Seller can cancel after this time
}

function canCancel(workflowId, caller, et):
  if (caller == et.to && block.timestamp < buyerCancelDeadline):
    return (true, true)  // Buyer within window
  
  if (caller == et.from && block.timestamp >= sellerCancelWindow):
    return (true, true)  // Seller within window
  
  return (false, false)
```

**5. ProposalWithTimeout**
```solidity
// One party proposes cancellation, other has N seconds to reject
// If no rejection: auto-cancel
// If rejection: cancel blocked

struct ProposalState {
  proposedBy: address
  proposalTime: uint256
  timeoutSeconds: uint256
}

function canCancel(workflowId, caller, et):
  // If no proposal: accept from anyone (initiates proposal)
  if (proposal.proposedBy == address(0)):
    return (true, false)  // Queue proposal, don't execute yet
  
  // If proposal active and timeout passed: execute
  if (block.timestamp >= proposal.proposalTime + proposal.timeoutSeconds):
    return (true, true)  // Execute refund
  
  // If other party initiates: they're rejecting (proposal fails)
  if (caller != proposal.proposedBy):
    return (true, false)  // Clear proposal, reset
  
  return (false, false)
```

### Integration with BaseEscrow

**In _cancelWorkflow():**
```solidity
function _cancelWorkflow(uint256 id, address caller, bool isSender) internal returns (bool) {
  EscrowTransfer storage et = escrowTransfers[id];
  ICancellationStrategy strategy = _getCancellationStrategy(id);
  
  // Consult strategy for authorization
  (bool allowed, bool immediate) = strategy.canCancel(id, caller, et);
  
  if (!allowed) revert CancellationNotAllowed(id, caller);
  
  if (immediate) {
    _cancelAndRefund(id);
    return true;
  } else {
    // For proposal-based strategies, queue proposal
    pendingCancellations[id] = PendingCancellation({
      proposedBy: caller,
      proposalTime: block.timestamp
    });
    emit CancellationProposed(id, caller);
    return false;  // Proposal queued, not executed yet
  }
}
```

### Storage and Snapshots

**Add to EscrowSettings:**
```solidity
struct EscrowSettings {
  // ... existing fields ...
  address cancellationStrategy;  // Defaults to MutualConsentWithAutoOverride
}
```

**Add to ModuleSnapshot (already frozen at creation):**
```solidity
struct ModuleSnapshot {
  // ... existing fields ...
  address cancellationStrategy;  // NEW: Snapshot strategy at creation
}
```

## Implementation Steps

### Phase 1: Create Infrastructure
1. Define `ICancellationStrategy` interface
2. Implement `MutualConsentWithAutoOverride` (default)
3. Add `cancellationStrategy` to `EscrowSettings`
4. Add to `ModuleSnapshot` and snapshot logic

### Phase 2: Integrate with BaseEscrow
1. Update `_cancelWorkflow()` to call strategy
2. Update `recipientCancel()` / `senderCancel()` to use strategy
3. Verify auto-cancel override in `automateTimedActions()`

### Phase 3: Implement Variants
1. `BuyerUnilateralCancel`
2. `SellerUnilateralCancel`
3. `TimedBuyerCancel`
4. `ProposalWithTimeout`

### Phase 4: Testing & Documentation
1. Unit tests for each strategy
2. Integration tests (strategy + auto-release/cancel)
3. Document use cases and business logic per strategy

## Auto-Cancel/Auto-Release Precedence (FIXED)

**New Logic in automateTimedActions():**
```
Check in order:
  1. Has auto-cancel time passed?
     → YES: Execute auto-cancel (returns 2, false)
     → Happens BEFORE release check
     → Buyer protection: guaranteed refund deadline
  
  2. Has auto-release time passed?
     → YES: Execute auto-release (returns 1, true)
     → Seller protection: guaranteed payment deadline
  
  3. No action (returns 0, false)
```

**Rationale:**
- Auto-cancel is buyer protection → higher priority
- Auto-release is seller protection → lower priority
- If both times set: earliest deadline wins

## Backwards Compatibility

- Default strategy = `MutualConsentWithAutoOverride` (current behavior + fix)
- Existing escrows unaffected (strategy defaults to original)
- New escrows can opt into alternative strategies

## Security Considerations

1. **Strategy Immutability** - Snapshot at creation, cannot change mid-escrow
2. **Reentrancy** - All strategy calls are `view`, no state changes
3. **Authorization** - Only BaseEscrow calls strategy (trusted caller)
4. **Timing** - Strategy checks are deterministic (only state + timestamp)

## Documentation Additions Needed

1. **User Guide:** "Choosing a Cancellation Strategy"
   - When to use mutual consent
   - When to use buyer unilateral
   - When to use timed windows
   
2. **Developer Guide:** "Implementing Custom Cancellation Strategies"
   - Interface requirements
   - Testing checklist
   - Example: ProposalWithTimeout
   
3. **Business Logic:** "Cancel Semantics Reference"
   - Each strategy's rules
   - Examples per strategy
   - Edge cases (auto-cancel + auto-release, etc.)

## Files to Create/Modify

### New Files
- `contracts/core/modules/ICancellationStrategy.sol` - Interface
- `contracts/core/modules/MutualConsentCancellation.sol` - Default
- `contracts/core/modules/BuyerUnilateralCancellation.sol`
- `contracts/core/modules/SellerUnilateralCancellation.sol`
- `contracts/core/modules/TimedCancellation.sol`
- `contracts/core/modules/ProposalBasedCancellation.sol`
- `test/foundry/core/CancellationStrategies.t.sol` - Tests

### Modified Files
- `contracts/core/BaseEscrow.sol` - Integrate strategy calls
- `contracts/types/EscrowTypes.sol` - Add cancellationStrategy to EscrowSettings
- `contracts/core/ModuleSnapshotRegistry.sol` - Snapshot strategies
- `contracts/ops/SettlementOps.sol` - Auto-cancel precedence
- Website documentation - Cancel semantics guide

## Timeline

**Immediate (Critical):**
- Fix auto-cancel precedence (auto-cancel checked before auto-release)
- Makes current mutual consent model safer

**Short-term (Phase 5, ~2 weeks):**
- Implement ICancellationStrategy infrastructure
- Create MutualConsentWithAutoOverride + BuyerUnilateral
- Full test coverage

**Long-term (Advanced):**
- ProposalWithTimeout, TimedBuyerCancel
- Advanced business logic per use case
- Community-contributed strategies
