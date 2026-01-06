# Escalation Flow Clarification

**Date**: 2025-01-XX  
**Status**: Design Document  
**Purpose**: Document the intended escalation flow and required implementation changes

---

## Current Implementation vs. Intended Behavior

### Current Implementation

**Current Flow**:
1. Dispute raised → Escrow state: `DISPUTED`
2. Resolver makes decision (`resolverRelease` or `resolverCancel`)
3. Escrow state changes to `RESOLVED` immediately
4. Funds are transferred
5. **Escalation requires `DISPUTED` state** → Cannot escalate after resolution

**Problem**: Once a resolver makes a decision, the escrow is immediately resolved and funds are transferred. Escalation is no longer possible because it requires the escrow to be in `DISPUTED` state.

---

### Intended Behavior

**Intended Flow**:
1. Dispute raised → Escrow state: `DISPUTED`
2. Resolver makes decision (RELEASE or CANCEL)
3. **Decision is recorded but NOT immediately finalized**
4. **Escrow remains in `DISPUTED` state** (or new state like `RESOLUTION_PENDING`)
5. **Buyer/seller have a time window** (e.g., 7 days) to escalate if they disagree
6. **Escalation fee is paid** (within the time period)
7. **Money stays in escrow** while next-level resolver assesses
8. If escalated:
   - Next resolver makes decision
   - If different outcome → **Reversal detected**
   - Final decision is executed
9. If not escalated within window:
   - Original resolver's decision is finalized
   - Funds are transferred according to original decision

---

## Required Implementation Changes

### 1. Resolution Grace Period

**New State** (Optional):
```solidity
enum EscrowState {
    PENDING,
    RELEASED,
    REFUNDED,
    DISPUTED,
    RESOLUTION_PENDING,  // NEW: Resolver made decision, waiting for escalation window
    RESOLVED
}
```

**Alternative**: Keep `DISPUTED` state but add resolution metadata:
```solidity
struct ResolutionPending {
    address resolver;
    ResolutionOutcome outcome;
    uint256 decisionTimestamp;
    uint256 escalationDeadline;
    bool finalized;
}
mapping(uint256 => ResolutionPending) public pendingResolutions;
```

---

### 2. Escalation Window Configuration

**New Configuration**:
```solidity
uint256 public escalationWindow = 7 days; // Time window to escalate after resolution
```

**Governance Function**:
```solidity
function setEscalationWindow(uint256 newWindow) external onlyRole(ROLE_TIMELOCK) {
    require(newWindow > 0 && newWindow <= 30 days, "Invalid window");
    escalationWindow = newWindow;
    emit EscalationWindowUpdated(newWindow);
}
```

---

### 3. Modified Resolution Functions

**Current** (`resolverRelease` / `resolverCancel`):
- Immediately change state to `RESOLVED`
- Immediately transfer funds

**New Behavior**:
- Record decision in `pendingResolutions`
- Set `escalationDeadline = block.timestamp + escalationWindow`
- Keep escrow in `DISPUTED` state (or `RESOLUTION_PENDING`)
- **Do NOT transfer funds yet**
- Emit `ResolutionDecisionMade` event

---

### 4. Escalation After Resolution

**Modified `escalateDispute`**:
```solidity
function escalateDispute(uint256 workflowId) public payable {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Allow escalation if:
    // 1. In DISPUTED state (normal escalation), OR
    // 2. Has pending resolution AND within escalation window
    bool canEscalate = (et.escrowState == EscrowState.DISPUTED) ||
                       (pendingResolutions[workflowId].exists && 
                        block.timestamp <= pendingResolutions[workflowId].escalationDeadline);
    
    require(canEscalate, "Cannot escalate");
    
    // If pending resolution exists, this is a reversal scenario
    if (pendingResolutions[workflowId].exists) {
        // Record that original resolver's decision is being challenged
        // Reversal will be detected when new resolver makes different decision
    }
    
    // Continue with escalation logic...
}
```

---

### 5. Finalization Function

**New Function**:
```solidity
function finalizeResolution(uint256 workflowId) external {
    ResolutionPending storage pending = pendingResolutions[workflowId];
    require(pending.exists, "No pending resolution");
    require(!pending.finalized, "Already finalized");
    require(block.timestamp > pending.escalationDeadline, "Still in escalation window");
    
    // Execute the original resolver's decision
    if (pending.outcome == ResolutionOutcome.RELEASE) {
        _executeRelease(workflowId);
    } else {
        _executeCancel(workflowId);
    }
    
    pending.finalized = true;
    escrowTransfers[workflowId].escrowState = EscrowState.RESOLVED;
}
```

**Alternative**: Auto-finalize after deadline (anyone can call)

---

### 6. Reversal Detection Update

**Current Logic** (in `recordResolution`):
- Detects reversal when `escalationLevel > 0` and outcome differs

**Updated Logic**:
- When escalated resolver makes decision:
  - Check if `pendingResolutions[workflowId]` exists
  - If exists and outcome differs → **Reversal detected**
  - Increment `resolutionReversals` for original resolver
  - Finalize immediately (no second escalation window)

---

## Implementation Considerations

### Contract Size

**BaseEscrow is already over size limit**. Adding this functionality will require:

1. **Move logic to library**:
   - Create `ResolutionManagementLibrary.sol`
   - Move resolution tracking logic there
   - Use library functions in BaseEscrow

2. **Optimize existing code**:
   - Review and optimize `_recordResolutionOutcome` (already done)
   - Consider removing or optimizing other functions
   - Use more assembly where safe

3. **Split functionality**:
   - Consider separate contract for resolution management
   - BaseEscrow delegates to resolution manager
   - More complex but reduces size

---

### Gas Costs

**Additional Costs**:
- Resolution pending storage: ~20,000 gas per resolution
- Escalation window checks: ~2,100 gas per check
- Finalization: ~50,000 gas (same as current resolution)

**Savings**:
- No immediate transfer on resolution (saves ~50,000 gas)
- Transfer only happens once (on finalization or escalation)

**Net Impact**: Slightly higher gas for resolution, but more flexible system

---

### Security Considerations

1. **Escalation Window Abuse**:
   - Participants might delay finalization
   - **Mitigation**: Auto-finalize after deadline (anyone can call)

2. **Multiple Escalations**:
   - What if escalated resolver's decision is also challenged?
   - **Design Decision**: Only first resolution can be escalated (one escalation per dispute)

3. **Funds Locked**:
   - Funds stay in escrow during escalation window
   - **Mitigation**: Clear deadline, auto-finalization

---

## Migration Path

### Phase 1: Add Resolution Pending Tracking
- Add `pendingResolutions` mapping
- Modify `resolverRelease` / `resolverCancel` to record pending resolution
- Keep current behavior (immediate finalization) for backward compatibility
- Add `finalizeResolution` function

### Phase 2: Add Escalation Window
- Add `escalationWindow` configuration
- Modify `escalateDispute` to allow escalation after resolution
- Add deadline checks

### Phase 3: Update Reversal Detection
- Update `recordResolution` to check pending resolutions
- Detect reversals when escalated resolver contradicts pending resolution

### Phase 4: Testing and Optimization
- Comprehensive testing
- Gas optimization
- Contract size optimization

---

## Alternative: Simpler Approach

If contract size is a major concern, consider a **simpler approach**:

### Option A: Escalation Before Resolution
- Resolver makes decision but doesn't execute
- Participants have window to escalate
- If escalated, new resolver makes decision
- If not escalated, original decision executes
- **Simpler**: No new state, just delay execution

### Option B: Post-Resolution Appeal
- Resolver makes decision and executes
- Participants can appeal (new dispute) within window
- Appeal creates new dispute with escalated resolver
- Original resolver's decision stands unless appealed
- **Simpler**: Uses existing dispute mechanism

---

## Recommendation

**Short Term**:
1. Optimize `_recordResolutionOutcome` (done)
2. Document current limitation
3. Plan for future enhancement

**Medium Term**:
1. Implement resolution pending tracking (library-based)
2. Add escalation window configuration
3. Update escalation logic

**Long Term**:
1. Full implementation with grace period
2. Comprehensive testing
3. Gas and size optimization

---

## Current Status

**Reversal Tracking**: ✅ Implemented and working
- Tracks reversals when escalated resolver makes different decision
- Works correctly for current escalation flow (before resolution)

**Escalation After Resolution**: ❌ Not yet implemented
- Requires design decisions and contract size considerations
- Documented for future implementation

---

*This document should be updated as the escalation flow is implemented.*

