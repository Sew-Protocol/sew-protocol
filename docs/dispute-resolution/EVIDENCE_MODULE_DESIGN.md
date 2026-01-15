# Evidence Module Design

## Overview

Evidence storage was removed from `BaseEscrow` to reduce contract size below 24KB. This document proposes a modular evidence storage solution that:
- Keeps escrow contract small
- Aligns with threat model (TB1: on-chain evidence commitment)
- Supports both Kleros and Decentralized Resolution paths
- Follows existing module architecture patterns

## Architecture

### Module Pattern
- **New Module Type**: `EVIDENCE` added to `ModuleType` enum
- **Interface**: `IEvidenceModule` (ERC-165 compatible)
- **Implementation**: `EvidenceModuleV1` (upgradeable via UUPS)
- **Snapshot**: Per-escrow module snapshot (like resolution/yield modules)

### Storage Strategy
- **On-chain**: Store only evidence hashes (`bytes32[]`) - gas efficient
- **Off-chain**: Full evidence content (IPFS, URLs) via events
- **Limit**: Configurable max evidence per dispute (default: 20 hashes)
- **Lifecycle**: Evidence can be submitted during dispute lifecycle

## Interface Design

```solidity
interface IEvidenceModule is IERC165 {
    /**
     * @notice Submit evidence for a dispute
     * @param workflowId The escrow workflow ID
     * @param evidenceHash Hash of evidence (keccak256 of content)
     * @param metadata Additional metadata (IPFS hash, document type, etc.)
     * @return evidenceId Unique evidence ID for this dispute
     */
    function submitEvidence(
        uint256 workflowId,
        bytes32 evidenceHash,
        string calldata metadata
    ) external returns (uint256 evidenceId);
    
    /**
     * @notice Get all evidence hashes for a dispute
     * @param workflowId The escrow workflow ID
     * @return hashes Array of evidence hashes
     * @return submitters Array of submitter addresses
     * @return timestamps Array of submission timestamps
     */
    function getEvidence(
        uint256 workflowId
    ) external view returns (
        bytes32[] memory hashes,
        address[] memory submitters,
        uint256[] memory timestamps
    );
    
    /**
     * @notice Get evidence count for a dispute
     * @param workflowId The escrow workflow ID
     * @return count Number of evidence submissions
     */
    function getEvidenceCount(uint256 workflowId) external view returns (uint256 count);
    
    /**
     * @notice Check if evidence submission is allowed
     * @param workflowId The escrow workflow ID
     * @param submitter Address attempting to submit
     * @return allowed True if submission allowed
     */
    function canSubmitEvidence(
        uint256 workflowId,
        address submitter
    ) external view returns (bool allowed);
}
```

## Implementation: EvidenceModuleV1

### Storage Structure
```solidity
struct EvidenceRecord {
    bytes32 hash;           // keccak256 of evidence content
    address submitter;      // Who submitted
    uint256 submittedAt;    // Timestamp
    string metadata;       // IPFS hash, document type, etc. (emitted, not stored)
}

mapping(uint256 => EvidenceRecord[]) public disputeEvidence;
mapping(uint256 => uint256) public maxEvidencePerDispute; // Configurable per dispute type
```

### Access Control
- **Participants**: Buyer and seller can always submit
- **Resolvers**: Current assigned resolver can submit
- **Anyone**: Optional (configurable per module instance)
- **Lifecycle**: Only during `DISPUTED` state (configurable)

### Gas Optimization
- Store only `bytes32` hashes (32 bytes each)
- Metadata stored in events only (not contract storage)
- Batch operations for multiple submissions
- Configurable limits to prevent gas griefing

## Integration Points

### 1. BaseEscrow Integration

```solidity
// Add to BaseEscrow
address public evidenceModule;
mapping(uint256 => address) internal snapshotEvidenceModules;

// Snapshot on escrow creation
function _snapshotModulesForEscrow(uint256 workflowId) internal {
    // ... existing snapshots ...
    snapshotEvidenceModules[workflowId] = evidenceModule;
}

// Helper to get evidence module for escrow
function _getEvidenceModule(uint256 workflowId) internal view returns (IEvidenceModule) {
    address snap = snapshotEvidenceModules[workflowId];
    if (snap != address(0)) {
        return IEvidenceModule(snap);
    }
    return IEvidenceModule(evidenceModule);
}

// Optional: Auto-notify evidence module on dispute
function raiseDispute(uint256 workflowId) public returns (bool) {
    // ... existing dispute logic ...
    
    // Notify evidence module (if enabled)
    IEvidenceModule evModule = _getEvidenceModule(workflowId);
    if (address(evModule) != address(0)) {
        try evModule.onDisputeOpened(workflowId) {} catch {}
    }
}
```

### 2. Resolution Module Integration

#### DecentralizedResolutionModule
```solidity
// Add evidence query helper
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
    address evModule = evidenceModule; // Could be per-escrow
    if (evModule != address(0)) {
        return IEvidenceModule(evModule).getEvidence(workflowId);
    }
    return (new bytes32[](0), new address[](0), new uint256[](0));
}
```

#### KlerosArbitrableProxy
```solidity
// Enhance existing submitEvidence to also store hash
function submitEvidence(uint256 workflowId, string calldata evidence) external {
    // ... existing logic ...
    
    // Also commit hash to evidence module (if available)
    bytes32 evidenceHash = keccak256(bytes(evidence));
    address evModule = evidenceModule; // Could be per-escrow
    if (evModule != address(0)) {
        try IEvidenceModule(evModule).submitEvidence(
            workflowId,
            evidenceHash,
            evidence // IPFS hash or URL
        ) {} catch {}
    }
}
```

## Governance & Configuration

### Module Registration
- **Queue/Activate**: Same slow-lane pattern as other modules
- **Per-Escrow Snapshot**: Evidence module snapshotted on escrow creation
- **Optional**: Can be `address(0)` (no evidence storage)

### Configuration
- **Max Evidence**: Configurable per dispute type (default: 20)
- **Access Control**: Configurable (participants only, or open)
- **Lifecycle Window**: Configurable (dispute only, or post-resolution)

## Events

```solidity
event EvidenceSubmitted(
    uint256 indexed workflowId,
    uint256 indexed evidenceId,
    address indexed submitter,
    bytes32 evidenceHash,
    string metadata
);

event EvidenceModuleUpdated(
    address indexed oldModule,
    address indexed newModule
);
```

## Migration Path

### Phase 1: Core Module
1. Create `IEvidenceModule` interface
2. Implement `EvidenceModuleV1`
3. Add module type to `BaseEscrow`
4. Add snapshot mechanism

### Phase 2: Integration
1. Add hooks in `BaseEscrow.raiseDispute()`
2. Add query helpers in resolution modules
3. Enhance `KlerosArbitrableProxy.submitEvidence()`

### Phase 3: UI/Off-chain
1. Index evidence events
2. Build evidence viewer
3. IPFS integration for full content

## Gas Costs

### Per Evidence Submission
- **Storage**: ~20,000 gas (SSTORE for new slot)
- **Event**: ~3,000 gas
- **Total**: ~25,000 gas per evidence

### Query Costs
- **View function**: Free (no gas)
- **Batch query**: Linear with evidence count

## Security Considerations

### Threat Model Alignment (TB1)
- ✅ **On-chain commitment**: Hashes stored on-chain
- ✅ **UI independence**: Evidence verifiable via on-chain hashes
- ✅ **Tamper-proof**: Hashes cannot be modified after submission

### Additional Protections
- **Spam prevention**: Configurable limits per dispute
- **Access control**: Only authorized parties can submit
- **Lifecycle gating**: Evidence only during appropriate states
- **Replay protection**: Evidence IDs prevent duplicates

## Alternative: Lightweight Approach

If full module is too heavy, consider:

### Option A: Event-Only Storage
- Store hashes only in events (no contract storage)
- Off-chain indexers build evidence registry
- **Pros**: Zero contract size increase
- **Cons**: Not queryable on-chain

### Option B: Minimal Storage
- Store only count + latest hash in escrow contract
- Full history in events
- **Pros**: Minimal contract size increase
- **Cons**: Limited on-chain queryability

### Option C: External Registry
- Separate evidence registry contract (not a module)
- Escrow contract calls registry on dispute
- **Pros**: Keeps escrow contract small
- **Cons**: Additional contract deployment

## Recommendation

**Implement full EvidenceModuleV1** because:
1. Aligns with modular architecture
2. Provides on-chain queryability (threat model requirement)
3. Follows existing patterns (snapshot, slow-lane)
4. Optional (can be disabled per escrow)
5. Upgradeable (can improve without breaking existing escrows)

The gas cost (~25K per evidence) is acceptable given the security benefits and threat model alignment.
