# Interface Versioning

**Date**: 2025-01-27  
**Purpose**: Document interface versioning approach for protocol contracts  
**Status**: Active

This document describes how interface versioning works for Sew Protocol contracts, enabling wallets and integrations to detect and adapt to different interface versions.

---

## Resolution Interface Versioning

### RESOLUTION_INTERFACE_V1

**Interface ID**: `RESOLUTION_INTERFACE_V1` (calculated via XOR of function selectors)

**Functions**:
- `cancelAsDisputeResolver(uint256,bytes32)`
- `releaseAsDisputeResolver(uint256,bytes32)`
- `partialReleaseAsDisputeResolver(uint256,uint256,bytes32)`
- `partialCancelAsDisputeResolver(uint256,uint256,bytes32)`

**Key Features**:
- All resolution functions include `bytes32 resolutionHash` parameter
- Consistent interface across all resolution methods
- Interface version detectable via `supportsInterface(RESOLUTION_INTERFACE_V1)`

**Detection**:
```solidity
if (escrowContract.supportsInterface(RESOLUTION_INTERFACE_V1)) {
    // Use V1 interface with resolutionHash
    escrowContract.releaseAsDisputeResolver(workflowId, resolutionHash);
} else {
    // Fallback to older interface (if exists)
    escrowContract.releaseAsDisputeResolver(workflowId);
}
```

---

## Module Interface Considerations

### Current State

**`recordResolution()` Call**:
- Currently called via low-level call: `recordResolution(uint256,address,uint8,bool,uint256)`
- Parameters: `(workflowId, disputeResolver, isRelease ? 1 : 2, false, 0)`
- `resolutionHash` is **not** passed to modules

**Why Not Yet**:
- Modules can access `resolutionHash` via `EscrowResolved` event if needed
- Avoids breaking changes to module interfaces
- Can be added in future module interface version

### Future Consideration: Module Interface V2

**Proposed Addition**:
```solidity
// Future module interface could include:
function recordResolution(
    uint256 workflowId,
    address resolver,
    uint8 outcome,  // 1 = release, 2 = cancel
    bool wasEscalated,
    uint256 resolutionTime,
    bytes32 resolutionHash  // NEW: Hash of resolution details
) external;
```

**Benefits**:
- Modules can verify resolution hash on-chain
- Enables module-level resolution verification
- Supports future features (e.g., resolution verification, analytics)

**Migration Path**:
1. Add new interface version (e.g., `IResolutionModuleV2`)
2. Modules can implement both V1 and V2 interfaces
3. BaseEscrow can detect and use V2 if available
4. Gradual migration as modules upgrade

**Current Recommendation**: 
- ✅ Keep current approach (hash available via events)
- ✅ Document future consideration
- ⚠️ Add to module interface when needed for specific use cases

---

## Buyer/Seller Interface

### Current Functions (Stable)

**Escrow Creation**:
- `createEscrow(address token, address to, uint256 amount, EscrowSettings memory settings)`

**Escrow Actions**:
- `releaseEscrowTransfer(uint256 id)` - Recipient releases
- `senderCancel(uint256 workflowId)` - Sender cancels
- `recipientCancel(uint256 workflowId)` - Recipient cancels
- `raiseDispute(uint256 workflowId)` - Either party raises dispute

**Interface Stability**: ✅ **Stable** - No changes planned

---

## Resolver Interface

### Current Functions (V1)

**Resolution Functions** (all include `resolutionHash`):
- `cancelAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash)`
- `releaseAsDisputeResolver(uint256 workflowId, bytes32 resolutionHash)`
- `partialReleaseAsDisputeResolver(uint256 workflowId, uint256 amount, bytes32 resolutionHash)`
- `partialCancelAsDisputeResolver(uint256 workflowId, uint256 amount, bytes32 resolutionHash)`

**Interface Version**: `RESOLUTION_INTERFACE_V1`

**Breaking Change**: ✅ **Yes** - Added `resolutionHash` parameter (January 2025)

**Migration**:
- Wallets must update to include `resolutionHash` parameter
- Can use `bytes32(0)` if hash not yet implemented
- Interface version detectable for graceful degradation

---

## Version Detection Best Practices

### For Wallets

```solidity
// Check interface version before calling
bytes4 resolutionInterface = escrowContract.RESOLUTION_INTERFACE_V1();
if (escrowContract.supportsInterface(resolutionInterface)) {
    // V1 interface - include resolutionHash
    bytes32 hash = keccak256(abi.encodePacked(workflowId, resolutionDetails));
    escrowContract.releaseAsDisputeResolver(workflowId, hash);
} else {
    // Older interface (if exists) - no hash
    // escrowContract.releaseAsDisputeResolver(workflowId);
}
```

### For Modules

```solidity
// Modules can check BaseEscrow interface version
if (escrowContract.supportsInterface(RESOLUTION_INTERFACE_V1)) {
    // V1 interface - resolutionHash available via events
    // Can listen to EscrowResolved event for hash
}
```

---

## Future Interface Versions

### RESOLUTION_INTERFACE_V2 (Future Consideration)

**Potential Additions**:
- Multi-recipient resolution (with participant approval)
- Escalation fee deduction from escrow
- Enhanced resolution metadata

**Migration Strategy**:
- Increment interface version
- Maintain backward compatibility where possible
- Clear documentation of breaking changes

---

## Summary

**Current State**:
- ✅ Resolution interface versioned (V1)
- ✅ Buyer/seller interface stable
- ✅ Module interface stable (hash via events)

**Future Considerations**:
- ⚠️ Module interface V2 (add resolutionHash parameter)
- ⚠️ Resolution interface V2 (multi-recipient, fee deduction)

**Recommendation**: 
- Keep buyer/seller interface stable
- Version resolver interface when needed
- Add module interface versioning when specific use cases require it
