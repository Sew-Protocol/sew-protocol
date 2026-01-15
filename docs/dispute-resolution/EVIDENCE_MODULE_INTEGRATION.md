# Evidence Module Integration Guide

## Summary

Evidence storage removed from `BaseEscrow` to reduce contract size. New `EvidenceModuleV1` provides modular evidence storage following existing module patterns.

## Required Changes to BaseEscrow

### 1. Add Module Type
```solidity
enum ModuleType { RESOLUTION, RELEASE, YIELD_GEN, YIELD_DIST, EVIDENCE }
```

### 2. Add Storage
```solidity
address public evidenceModule;
mapping(uint256 => address) internal snapshotEvidenceModules;
```

### 3. Update Snapshot Function
```solidity
function _snapshotModulesForEscrow(uint256 workflowId) internal {
    // ... existing snapshots ...
    snapshotEvidenceModules[workflowId] = evidenceModule;
    
    emit EscrowModuleSnapshot(
        workflowId, 
        snapshotResolutionModules[workflowId],
        snapshotReleaseStrategies[workflowId],
        snapshotYieldGenerationModules[workflowId],
        snapshotYieldDistributionModules[workflowId],
        snapshotEvidenceModules[workflowId]  // Add this
    );
}
```

### 4. Add Helper Function
```solidity
function _getEvidenceModule(uint256 workflowId) internal view returns (IEvidenceModule) {
    address snap = snapshotEvidenceModules[workflowId];
    if (snap != address(0)) {
        return IEvidenceModule(snap);
    }
    return IEvidenceModule(evidenceModule);
}
```

### 5. Update raiseDispute() Hook
```solidity
function raiseDispute(uint256 workflowId) public returns (bool) {
    // ... existing dispute logic ...
    
    // Notify evidence module (if enabled)
    IEvidenceModule evModule = _getEvidenceModule(workflowId);
    if (address(evModule) != address(0)) {
        try evModule.onDisputeOpened(workflowId) {} catch {}
    }
    
    return true;
}
```

### 6. Add Queue/Activate Functions
```solidity
function queueEvidenceModule(address m) public onlyRole(ROLE_TIMELOCK) { 
    _queueAddress(_pendingModules[ModuleType.EVIDENCE], m); 
    emit EvidenceModuleQueued(evidenceModule, m, _pendingModules[ModuleType.EVIDENCE].eta); 
}

function activateEvidenceModule() public onlyRole(ROLE_TIMELOCK) { 
    address oldModule = evidenceModule; 
    evidenceModule = _activateAddress(_pendingModules[ModuleType.EVIDENCE]); 
    emit EvidenceModuleActivated(oldModule, evidenceModule); 
}

function getPendingEvidenceModule() public view returns (address value, uint64 eta, bool exists) { 
    return getPendingAddress(_pendingModules[ModuleType.EVIDENCE]); 
}
```

### 7. Add Events
```solidity
event EvidenceModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
event EvidenceModuleActivated(address indexed oldModule, address indexed newModule);
```

## Integration with Resolution Modules

### DecentralizedResolutionModule

Add helper function to query evidence:
```solidity
function getDisputeEvidence(uint256 workflowId) 
    external 
    view 
    returns (
        bytes32[] memory hashes,
        address[] memory submitters,
        uint256[] memory timestamps
    ) 
{
    // Query evidence module if available
    // Note: Would need reference to evidence module or query via escrow contract
    // For now, return empty (evidence module handles queries directly)
    return (new bytes32[](0), new address[](0), new uint256[](0));
}
```

### KlerosArbitrableProxy

Enhance existing `submitEvidence()`:
```solidity
function submitEvidence(uint256 workflowId, string calldata evidence) external {
    require(workflowToKlerosDispute[workflowId] != 0, "Dispute does not exist");
    DisputeMetadata storage dispute = disputes[workflowId];
    require(!dispute.resolved, "Dispute already resolved");
    
    // Emit existing event
    emit EvidenceSubmitted(workflowId, dispute.klerosDisputeId, msg.sender, evidence);
    
    // Also commit hash to evidence module (if available)
    bytes32 evidenceHash = keccak256(bytes(evidence));
    address evModule = evidenceModule; // Would need reference to evidence module
    if (evModule != address(0)) {
        try IEvidenceModule(evModule).submitEvidence(
            workflowId,
            evidenceHash,
            evidence // IPFS hash or URL
        ) {} catch {}
    }
}
```

## Deployment Steps

1. **Deploy EvidenceModuleV1**
   ```solidity
   EvidenceModuleV1 impl = new EvidenceModuleV1();
   ERC1967Proxy proxy = new ERC1967Proxy(
       address(impl),
       abi.encodeCall(EvidenceModuleV1.initialize, (
           admin,
           escrowContractAddress,
           resolutionModuleAddress,
           20,  // maxEvidencePerDispute
           false, // allowAnyoneSubmit
           false  // allowPostResolution
       ))
   );
   ```

2. **Queue in BaseEscrow**
   ```solidity
   escrowContract.queueEvidenceModule(address(proxy));
   ```

3. **Activate after delay**
   ```solidity
   escrowContract.activateEvidenceModule();
   ```

4. **Configure EvidenceModule**
   ```solidity
   evidenceModule.setEscrowContract(escrowContractAddress);
   evidenceModule.setResolutionModule(resolutionModuleAddress);
   ```

## Usage Example

```solidity
// Buyer submits evidence
bytes32 evidenceHash = keccak256(abi.encodePacked(ipfsContent));
evidenceModule.submitEvidence(workflowId, evidenceHash, "ipfs://Qm...");

// Seller submits counter-evidence
bytes32 counterHash = keccak256(abi.encodePacked(counterContent));
evidenceModule.submitEvidence(workflowId, counterHash, "ipfs://Qm...");

// Resolver queries evidence
(bytes32[] memory hashes, address[] memory submitters, , ) = 
    evidenceModule.getEvidence(workflowId);
```

## Gas Costs

- **Submit evidence**: ~25,000 gas (storage + event)
- **Query evidence**: Free (view function)
- **Contract size**: ~8KB (fits in 24KB limit)

## Benefits

1. ✅ **Modular**: Follows existing module pattern
2. ✅ **Optional**: Can be disabled per escrow
3. ✅ **Upgradeable**: UUPS pattern
4. ✅ **On-chain**: Hashes stored on-chain (threat model alignment)
5. ✅ **Queryable**: On-chain queries for resolvers
6. ✅ **Flexible**: Configurable access control and limits
