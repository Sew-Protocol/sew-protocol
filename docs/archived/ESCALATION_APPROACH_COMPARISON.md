# Escalation Implementation Approach Comparison

**Date**: 2025-01-XX  
**Status**: Design Decision Document  
**Purpose**: Compare approaches for implementing escalation-after-resolution without changing BaseEscrow interface

---

## Executive Summary

**Recommendation**: **Approach 2 (Module as Intermediary)** - Keep BaseEscrow unchanged, have resolution module act as intermediary.

**Rationale**:
- ✅ Preserves stable BaseEscrow interface (6 months testnet)
- ✅ Enables complex modules without BaseEscrow changes
- ✅ Cleaner separation of concerns
- ✅ Easier Kleros integration
- ✅ Better upgradeability path

---

## Approach 1: Modify BaseEscrow

### Description

Add escalation-after-resolution functionality directly to BaseEscrow:
- New state: `RESOLUTION_PENDING`
- Grace period tracking
- Escalation window enforcement
- Finalization logic

### Implementation Details

**BaseEscrow Changes**:
```solidity
enum EscrowState {
    PENDING,
    RELEASED,
    REFUNDED,
    DISPUTED,
    RESOLUTION_PENDING,  // NEW
    RESOLVED
}

struct ResolutionPending {
    address resolver;
    ResolutionOutcome outcome;
    uint256 decisionTimestamp;
    uint256 escalationDeadline;
    bool finalized;
}
mapping(uint256 => ResolutionPending) public pendingResolutions;

uint256 public escalationWindow = 7 days;

function resolverRelease(uint256 workflowId) public {
    // Record decision but don't finalize
    pendingResolutions[workflowId] = ResolutionPending({
        resolver: _msgSender(),
        outcome: ResolutionOutcome.RELEASE,
        decisionTimestamp: block.timestamp,
        escalationDeadline: block.timestamp + escalationWindow,
        finalized: false
    });
    // Keep in DISPUTED state
    emit ResolutionDecisionMade(workflowId, _msgSender(), ResolutionOutcome.RELEASE);
}

function escalateDispute(uint256 workflowId) public payable {
    // Allow escalation if pending resolution exists and within window
    if (pendingResolutions[workflowId].exists) {
        require(block.timestamp <= pendingResolutions[workflowId].escalationDeadline, "Window expired");
        // Escalate...
    }
}

function finalizeResolution(uint256 workflowId) external {
    ResolutionPending storage pending = pendingResolutions[workflowId];
    require(block.timestamp > pending.escalationDeadline, "Still in window");
    // Execute original decision...
}
```

### Pros

✅ **Single Source of Truth**: All logic in one place  
✅ **Direct Control**: BaseEscrow has full control over escalation flow  
✅ **Simpler Integration**: No need for module coordination  

### Cons

❌ **Contract Size**: BaseEscrow already over limit, this makes it worse  
❌ **Interface Changes**: Breaks stable interface (6 months testnet)  
❌ **Complexity**: Adds significant complexity to core contract  
❌ **Upgradeability**: Harder to upgrade without changing BaseEscrow  
❌ **Module Flexibility**: All modules must use same escalation logic  
❌ **Kleros Integration**: Harder to integrate (needs BaseEscrow changes)  

---

## Approach 2: Module as Intermediary (RECOMMENDED)

### Description

Keep BaseEscrow unchanged. Resolution module acts as intermediary:
- Resolvers call resolution module functions
- Module handles escalation logic, time limits, grace periods
- Module only calls BaseEscrow when outcome is final
- BaseEscrow functions remain simple and unchanged

### Implementation Details

**New IResolutionModule Interface Extensions**:
```solidity
interface IResolutionModule {
    // Existing functions...
    
    /**
     * @notice Resolver makes a decision (called by resolver, not BaseEscrow)
     * @param workflowId The escrow transfer ID
     * @param outcome RELEASE or CANCEL
     * @dev Module records decision, starts grace period, waits for escalation window
     */
    function resolverDecision(
        uint256 workflowId,
        ResolutionOutcome outcome
    ) external;
    
    /**
     * @notice Finalize resolution and execute on BaseEscrow
     * @param workflowId The escrow transfer ID
     * @dev Called after escalation window expires or when escalated resolver makes final decision
     */
    function finalizeResolution(uint256 workflowId) external;
    
    /**
     * @notice Check if resolution is pending (for UI/off-chain systems)
     * @param workflowId The escrow transfer ID
     * @return isPending True if resolution is pending finalization
     * @return deadline Timestamp when escalation window expires
     */
    function getResolutionStatus(uint256 workflowId) 
        external view returns (bool isPending, uint256 deadline);
}
```

**DecentralizedResolutionModule Implementation**:
```solidity
contract DecentralizedResolutionModule {
    struct PendingResolution {
        address resolver;
        ResolutionOutcome outcome;
        uint256 decisionTimestamp;
        uint256 escalationDeadline;
        bool finalized;
    }
    mapping(uint256 => PendingResolution) public pendingResolutions;
    
    uint256 public escalationWindow = 7 days;
    
    // Resolver calls this instead of BaseEscrow directly
    function resolverDecision(uint256 workflowId, ResolutionOutcome outcome) external {
        require(_isAuthorizedResolver(workflowId, _msgSender()), "Not authorized");
        require(outcome != ResolutionOutcome.NONE, "Invalid outcome");
        
        DisputeMetadata storage dm = disputeMetadata[workflowId];
        require(dm.currentResolver != address(0), "No dispute");
        
        // Check for reversal if escalated
        if (dm.escalationLevel > 0 && dm.lastResolver != address(0)) {
            if (dm.lastResolutionOutcome != ResolutionOutcome.NONE && 
                dm.lastResolutionOutcome != outcome) {
                // Reversal detected
                _recordReversal(workflowId, dm.lastResolver, dm.lastResolutionOutcome, outcome);
            }
        }
        
        // Record decision
        dm.lastResolutionOutcome = outcome;
        dm.lastResolver = _msgSender();
        
        // If this is an escalated resolution, finalize immediately (no second window)
        if (dm.escalationLevel > 0) {
            _finalizeAndExecute(workflowId, outcome);
            return;
        }
        
        // Otherwise, start grace period
        pendingResolutions[workflowId] = PendingResolution({
            resolver: _msgSender(),
            outcome: outcome,
            decisionTimestamp: block.timestamp,
            escalationDeadline: block.timestamp + escalationWindow,
            finalized: false
        });
        
        emit ResolutionDecisionMade(workflowId, _msgSender(), outcome, block.timestamp + escalationWindow);
    }
    
    // Participants can escalate during grace period
    function escalateDispute(uint256 workflowId) external payable {
        PendingResolution storage pending = pendingResolutions[workflowId];
        require(pending.exists, "No pending resolution");
        require(block.timestamp <= pending.escalationDeadline, "Window expired");
        require(!pending.finalized, "Already finalized");
        
        // Mark as escalated (prevents finalization)
        pending.finalized = true;
        
        // Execute escalation logic (existing executeEscalation)
        // ...
    }
    
    // Finalize after window expires
    function finalizeResolution(uint256 workflowId) external {
        PendingResolution storage pending = pendingResolutions[workflowId];
        require(pending.exists, "No pending resolution");
        require(!pending.finalized, "Already finalized");
        require(block.timestamp > pending.escalationDeadline, "Still in window");
        
        pending.finalized = true;
        _finalizeAndExecute(workflowId, pending.outcome);
    }
    
    // Internal: Execute decision on BaseEscrow
    function _finalizeAndExecute(uint256 workflowId, ResolutionOutcome outcome) internal {
        BaseEscrow escrow = BaseEscrow(escrowContract);
        
        if (outcome == ResolutionOutcome.RELEASE) {
            escrow.resolverRelease(workflowId);
        } else {
            escrow.resolverCancel(workflowId);
        }
        
        emit ResolutionFinalized(workflowId, outcome);
    }
}
```

**BaseEscrow Changes**: **NONE** ✅

### Pros

✅ **No BaseEscrow Changes**: Preserves stable interface  
✅ **Contract Size**: BaseEscrow stays within limits  
✅ **Separation of Concerns**: Escalation logic in module, execution in BaseEscrow  
✅ **Module Flexibility**: Different modules can implement different escalation logic  
✅ **Upgradeability**: Can deploy new modules without changing BaseEscrow  
✅ **Kleros Integration**: Easier to integrate (module handles it)  
✅ **Backward Compatibility**: Simple modules (DefaultResolutionModule) still work  

### Cons

❌ **Module Complexity**: Resolution module becomes more complex  
❌ **Two-Step Process**: Resolvers call module, module calls BaseEscrow  
❌ **Module Registration**: Need to ensure module is registered with BaseEscrow  

---

## Kleros Integration (Level 3 Escalation)

### ERC-792 Arbitrable Standard

Kleros uses ERC-792 (Arbitrable) standard. Key components:
- **Arbitrable**: Contract that submits disputes
- **Arbitrator**: Kleros contract that resolves disputes
- **Evidence**: Submitted by parties
- **Ruling**: Returned by arbitrator

### Integration Approach

**Option A: Module Creates Arbitrable Token**

```solidity
contract KlerosArbitrable is IArbitrable {
    BaseEscrow public escrow;
    uint256 public workflowId;
    IArbitrator public arbitrator;
    uint256 public disputeID;
    
    constructor(
        BaseEscrow _escrow,
        uint256 _workflowId,
        IArbitrator _arbitrator
    ) {
        escrow = _escrow;
        workflowId = _workflowId;
        arbitrator = _arbitrator;
    }
    
    function submitDispute(bytes calldata evidence) external payable {
        // Submit dispute to Kleros
        disputeID = arbitrator.createDispute{value: msg.value}(
            2, // Number of choices (RELEASE or CANCEL)
            ""
        );
    }
    
    function rule(uint256 _disputeID, uint256 _ruling) external override {
        require(_disputeID == disputeID, "Invalid dispute");
        require(msg.sender == address(arbitrator), "Not arbitrator");
        require(_ruling <= 2, "Invalid ruling");
        
        // Ruling: 0 = no ruling, 1 = RELEASE, 2 = CANCEL
        ResolutionOutcome outcome = _ruling == 1 
            ? ResolutionOutcome.RELEASE 
            : ResolutionOutcome.CANCEL;
        
        // Execute on BaseEscrow
        if (outcome == ResolutionOutcome.RELEASE) {
            escrow.resolverRelease(workflowId);
        } else {
            escrow.resolverCancel(workflowId);
        }
    }
}
```

**DecentralizedResolutionModule Integration**:
```solidity
function escalateToKleros(uint256 workflowId) external payable {
    require(escalationLevel == 2, "Not at Kleros level");
    
    // Get escrow details
    EscrowTransfer memory et = BaseEscrow(escrowContract).getEscrowTransfer(workflowId);
    
    // Create arbitrable contract
    KlerosArbitrable arbitrable = new KlerosArbitrable(
        BaseEscrow(escrowContract),
        workflowId,
        klerosArbitrator
    );
    
    // Transfer funds to arbitrable (if needed for arbitration fees)
    // OR: Arbitrable pulls funds from BaseEscrow via approval
    
    // Submit dispute
    arbitrable.submitDispute{value: msg.value}(evidence);
    
    // Store arbitrable address
    klerosArbitrables[workflowId] = address(arbitrable);
    
    emit EscalatedToKleros(workflowId, address(arbitrable));
}
```

### Fund Transfer to Kleros

**Question**: Does BaseEscrow need to allow resolution module to transfer funds?

**Answer**: **Depends on Kleros fee model**:

1. **If Kleros fees paid separately** (participant pays):
   - No BaseEscrow changes needed
   - Participant pays Kleros directly
   - Arbitrable only needs to call `resolverRelease`/`resolverCancel` after ruling

2. **If Kleros fees come from escrow**:
   - BaseEscrow needs to approve resolution module
   - Module transfers funds to Kleros arbitrable
   - **OR**: Use a pull pattern (arbitrable pulls from BaseEscrow)

**Recommended Approach**: **Separate Payment**
- Participant pays Kleros fees directly
- Escrow funds stay in BaseEscrow
- Arbitrable only executes ruling (no fund transfer needed)

**If Fund Transfer Required**:
```solidity
// In BaseEscrow (if needed)
function approveResolutionModule(uint256 workflowId, address module, uint256 amount) 
    external onlyRole(ROLE_TIMELOCK) 
{
    // Approve module to transfer funds for Kleros fees
    // Only for specific workflowId
    // Limited to escalation fees, not full escrow amount
}
```

### Kleros Ruling Interface

**ERC-792 Interface**:
```solidity
interface IArbitrable {
    function rule(uint256 _disputeID, uint256 _ruling) external;
}

interface IArbitrator {
    function createDispute(
        uint256 _choices,
        bytes calldata _extraData
    ) external payable returns (uint256 disputeID);
}
```

**Ruling Values**:
- `0`: No ruling / Refuse to arbitrate
- `1`: Choice 1 (RELEASE to recipient)
- `2`: Choice 2 (CANCEL / refund to sender)

**Implementation**:
```solidity
function rule(uint256 _disputeID, uint256 _ruling) external override {
    require(msg.sender == address(arbitrator), "Not arbitrator");
    
    // Map ruling to outcome
    ResolutionOutcome outcome;
    if (_ruling == 1) {
        outcome = ResolutionOutcome.RELEASE;
    } else if (_ruling == 2) {
        outcome = ResolutionOutcome.CANCEL;
    } else {
        revert("Invalid ruling");
    }
    
    // Execute on BaseEscrow
    BaseEscrow(escrowContract).resolverRelease(workflowId); // or resolverCancel
}
```

---

## Detailed Comparison

### Contract Size Impact

| Aspect | Approach 1 | Approach 2 |
|--------|-----------|------------|
| BaseEscrow Size | +~5-8KB | 0 bytes |
| Module Size | 0 bytes | +~3-5KB |
| Total | +~5-8KB | +~3-5KB |
| BaseEscrow Status | ❌ Over limit | ✅ Within limit |

### Interface Stability

| Aspect | Approach 1 | Approach 2 |
|--------|-----------|------------|
| BaseEscrow Interface | ❌ Changes | ✅ Unchanged |
| Breaking Changes | ❌ Yes | ✅ No |
| Backward Compatibility | ❌ Partial | ✅ Full |
| Testnet Stability | ❌ Broken | ✅ Preserved |

### Complexity

| Aspect | Approach 1 | Approach 2 |
|--------|-----------|------------|
| BaseEscrow Complexity | ❌ High | ✅ Low |
| Module Complexity | ✅ Low | ⚠️ Medium |
| Total System Complexity | ⚠️ Medium | ⚠️ Medium |
| Separation of Concerns | ❌ Poor | ✅ Good |

### Upgradeability

| Aspect | Approach 1 | Approach 2 |
|--------|-----------|------------|
| BaseEscrow Upgrades | ❌ Hard | ✅ Easy |
| Module Upgrades | ✅ Easy | ✅ Easy |
| Feature Additions | ❌ Requires BaseEscrow change | ✅ New module only |
| Kleros Integration | ❌ Requires BaseEscrow change | ✅ Module only |

### Kleros Integration

| Aspect | Approach 1 | Approach 2 |
|--------|-----------|------------|
| BaseEscrow Changes | ❌ Required | ✅ Not needed |
| Fund Transfer | ❌ Complex | ✅ Simple |
| Arbitrable Creation | ❌ In BaseEscrow | ✅ In module |
| Ruling Execution | ❌ In BaseEscrow | ✅ In module/arbitrable |

---

## Implementation Plan (Approach 2)

### Phase 1: Interface Extensions

1. **Extend IResolutionModule**:
   - Add `resolverDecision(uint256, ResolutionOutcome)`
   - Add `finalizeResolution(uint256)`
   - Add `getResolutionStatus(uint256)`

2. **Update DecentralizedResolutionModule**:
   - Add pending resolution tracking
   - Implement `resolverDecision()`
   - Implement `finalizeResolution()`
   - Add escalation window logic

### Phase 2: Resolver Flow Update

1. **Update Resolver Documentation**:
   - Resolvers call `module.resolverDecision()` instead of `escrow.resolverRelease()`
   - Module handles escalation logic
   - Module calls BaseEscrow when final

2. **Backward Compatibility**:
   - Keep existing `resolverRelease`/`resolverCancel` in BaseEscrow
   - Simple modules (DefaultResolutionModule) can still use direct calls
   - Advanced modules use new flow

### Phase 3: Kleros Integration

1. **Create KlerosArbitrable Contract**:
   - Implements IArbitrable
   - Handles Kleros dispute submission
   - Executes ruling on BaseEscrow

2. **Integrate into Module**:
   - Add `escalateToKleros()` function
   - Create arbitrable on escalation
   - Store arbitrable address
   - Handle ruling execution

3. **Testing**:
   - Test with Kleros testnet
   - Verify ruling execution
   - Test edge cases

---

## Migration Strategy

### For Existing Escrows

**No Migration Needed**: Existing escrows continue to work with current flow.

**New Escrows**: Can use new module with escalation-after-resolution.

### For Resolvers

**Training Required**: Resolvers need to call module instead of BaseEscrow directly.

**Documentation**: Clear guide on new resolution flow.

**Gradual Rollout**: Start with testnet, then mainnet.

---

## Recommendation: Approach 2

**Choose Approach 2 (Module as Intermediary)** because:

1. ✅ **Preserves BaseEscrow Stability**: 6 months testnet stability maintained
2. ✅ **Contract Size**: BaseEscrow stays within limits
3. ✅ **Clean Architecture**: Clear separation of concerns
4. ✅ **Flexibility**: Different modules can implement different escalation logic
5. ✅ **Upgradeability**: Can add features via new modules without BaseEscrow changes
6. ✅ **Kleros Integration**: Easier to implement in module
7. ✅ **Backward Compatibility**: Simple modules still work

**Trade-offs**:
- Module becomes more complex (acceptable)
- Resolvers call module instead of BaseEscrow (minor change)
- Two-step process (module → BaseEscrow)

**These trade-offs are worth it** for the benefits of maintaining BaseEscrow stability and enabling future enhancements without core contract changes.

---

## Next Steps

1. **Design Review**: Review this document with team
2. **Interface Design**: Finalize IResolutionModule extensions
3. **Implementation**: Implement Approach 2
4. **Testing**: Comprehensive testing including Kleros integration
5. **Documentation**: Update resolver and developer documentation
6. **Deployment**: Deploy to testnet, then mainnet

---

*This document should be updated as implementation progresses.*

