# Module Upgrade Strategy

**Date**: 2026-01-16  
**Status**: Current Implementation  
**Purpose**: Document how modules are upgraded in the Sew Protocol

---

## Executive Summary

**Current Implementation**: Modules are upgraded by **swapping them out** (deploy new version, update reference in BaseEscrow via Slow lane governance).

**Key Principle**: All modules are **immutable**. Upgrades are performed by deploying a new version and swapping the module reference. Existing escrows are unaffected due to snapshot semantics.

---

## Module Upgrade Mechanism

### Module Swapping (Current Approach)

**How It Works**:

1. Deploy new module contract (immutable, no proxy)
2. Use slow-lane queue (`queueResolutionModule`, `queueDefaultReleaseStrategy`, etc.)
3. After delay (~9 days), activate new module (`activateResolutionModule`, `activateDefaultReleaseStrategy`, etc.)
4. BaseEscrow now uses new module address
5. **Existing escrows unaffected**: They continue using their snapshotted module addresses

**Implementation** (BaseEscrow.sol):

```solidity
address public resolutionModule;
address public pendingResolutionModule;
uint256 public pendingResolutionModuleEta;

function queueResolutionModule(address newModule) external onlyRole(ROLE_TIMELOCK) {
    // Slow lane queue with delay
    pendingResolutionModule = newModule;
    pendingResolutionModuleEta = block.timestamp + resolutionModuleDelay;
}

function activateResolutionModule() external onlyRole(ROLE_TIMELOCK) {
    require(block.timestamp >= pendingResolutionModuleEta, "Delay not met");
    resolutionModule = pendingResolutionModule;
    pendingResolutionModule = address(0);
}
```

**Pros**:

- ✅ Simple: Just swap addresses
- ✅ Safe: Slow-lane queue prevents immediate changes
- ✅ No proxy complexity
- ✅ Clear separation: Old module still exists
- ✅ Immutable modules: Maximum security and auditability
- ✅ Snapshot protection: Existing escrows unaffected

**Cons**:

- ⚠️ **State Loss**: All module state is lost (resolvers, disputes, stats)
- ⚠️ **Migration Required**: Must migrate data from old to new module if needed
- ⚠️ **Gas Cost**: Deploy new contract + potential migration
- ⚠️ **Brief Window**: Small window during activation

**Note**: State loss is acceptable because:
- Modules are designed to be stateless or have minimal state
- State can be reconstructed from onchain events if needed
- Migration scripts can be used for critical state

---

## Module Snapshotting

### The Core Principle

**Design Rule**: Changes to modules should only impact **future escrows**, and **in-flight escrows are unaffected**.

This is enforced via **module snapshotting**: When an escrow is created, the current module addresses are snapshotted into the `EscrowTransfer` struct:

```solidity
struct EscrowTransfer {
  // ... other fields ...
  address snapshotResolutionModule; // Resolution module at creation time
  address snapshotReleaseStrategy;
  address snapshotYieldGenerationModule;
  address snapshotYieldDistributionModule;
}
```

When an escrow needs to interact with a module (e.g., check resolver authorization), it uses the **snapshot address**, not the current module address:

```solidity
function _isAuthorizedResolver(uint256 workflowId, address resolver) internal view returns (bool) {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    address snapshotModule = et.snapshotResolutionModule;

    // Use snapshot module, not current module
    if (snapshotModule != address(0)) {
        return IResolutionModule(snapshotModule).isAuthorizedResolver(...);
    }
}
```

### Snapshot Guarantee

**Key Guarantee**: Once an escrow is created, its module addresses are locked. Even if governance swaps modules, existing escrows continue using their snapshotted modules.

**Example**:

- Escrow #1 created with `DefaultResolutionModule` at `0xAAA`
- Governance swaps to `DecentralizedResolutionModule` at `0xBBB`
- Escrow #1 continues using `0xAAA` (snapshot)
- Escrow #2 (created after swap) uses `0xBBB` (new default)

---

## Upgrade Process

### Step-by-Step Upgrade Flow

#### 1. Deploy New Module

```bash
# Deploy new module version
hardhat deploy --tags MyModuleV2 --network baseSepolia
```

**Requirements**:
- Module must implement the same interface
- Module must be immutable (no proxy)
- Module should have updated `moduleVersion()` returning new version

#### 2. Queue New Module (Slow Lane)

```solidity
// Via Timelock (after governance proposal)
baseEscrow.queueResolutionModule(newModuleAddress);
```

**Timeline**: 
- Governance proposal creation: ~48 hours
- Queue execution: Sets ETA to `block.timestamp + delay` (typically 7 days)

#### 3. Wait for Delay

**Delay Period**: ~7 days (enforced onchain via ETA)

This provides:
- Time for community review
- Opportunity to identify issues
- Transparency and predictability

#### 4. Activate New Module (Slow Lane)

```solidity
// Via Timelock (after governance proposal)
baseEscrow.activateResolutionModule();
```

**Timeline**:
- Governance proposal creation: ~48 hours
- Activation execution: After ETA has passed

**Total Time**: ~9 days wall-clock (48h queue proposal + 7d wait + 48h activate proposal)

---

## Module State Migration

### When State Migration Is Needed

If a module has important state that needs to be preserved:

1. **Resolver Registries**: List of approved resolvers
2. **Configuration**: Module-specific settings
3. **Statistics**: Historical data (if needed)

### Migration Strategy

**Option 1: Read-Only Access to Old Module**

New module can read state from old module during transition:

```solidity
contract MyModuleV2 is IMyModule {
    address public oldModule;
    
    constructor(address _oldModule) {
        oldModule = _oldModule;
    }
    
    function getResolver(uint256 workflowId) external view returns (address) {
        // Try new logic first
        address resolver = _getResolverNew(workflowId);
        if (resolver != address(0)) {
            return resolver;
        }
        // Fallback to old module
        return IMyModule(oldModule).getResolver(workflowId);
    }
}
```

**Option 2: Migration Script**

Deploy new module, then run migration script to copy state:

```typescript
// Migration script
const oldModule = await ethers.getContract('MyModuleV1');
const newModule = await ethers.getContract('MyModuleV2');

// Read state from old module
const resolvers = await oldModule.getApprovedResolvers();

// Write to new module
for (const resolver of resolvers) {
  await newModule.appointResolver(resolver);
}
```

**Option 3: Stateless Design**

Design modules to be stateless or reconstruct state from events:

```solidity
// Module reconstructs state from events
function getResolver(uint256 workflowId) external view returns (address) {
    // Query events or external registry
    // No internal state needed
}
```

---

## Module Classification

### Stateless Modules

**Definition**: Modules that don't maintain significant internal state.

**Examples**:
- `DefaultResolutionModule` - Simple resolver lookup
- `DefaultReleaseStrategy` - Time-based release logic
- `DefaultYieldDistributionModule` - Percentage-based distribution

**Upgrade Path**: 
- Deploy new version
- Swap via Slow lane
- No migration needed

### Stateful Modules

**Definition**: Modules that maintain important internal state.

**Examples**:
- `DecentralizedResolutionModule` - Resolver registry, dispute metadata, statistics
- `AaveYieldGenerationModule` - Token registrations, caps

**Upgrade Path**:
- Deploy new version
- Implement migration strategy (read-old, migration script, or stateless design)
- Swap via Slow lane
- Run migration if needed

**Note**: Even stateful modules are immutable. State is preserved by either:
1. Reading from old module during transition
2. Migrating state via script
3. Reconstructing from events

---

## Governance Considerations

### Upgrade Authorization

All module upgrades require:

1. **Governance Proposal**: Create proposal to queue new module
2. **Timelock Execution**: Execute via `ROLE_TIMELOCK` (TimelockController)
3. **Slow Lane**: ~9 days total delay (48h + 7d + 48h)

### Upgrade Policy

**Recommendation**: Define clear upgrade policy:

1. **Backward Compatibility**: New modules should be backward compatible with existing escrows
2. **Interface Compliance**: New modules must implement the same interface
3. **Testing**: Comprehensive testing on testnet before mainnet
4. **Documentation**: Document changes and migration requirements
5. **Transparency**: All upgrades are onchain and publicly verifiable

---

## Risk Analysis

### Risk: State Loss

**Scenario**: Module upgrade loses important state (resolvers, configuration).

**Mitigation**:
- ✅ Design modules to be stateless when possible
- ✅ Implement migration strategies for stateful modules
- ✅ Read from old module during transition
- ✅ Reconstruct state from events if needed

### Risk: Breaking Changes

**Scenario**: New module breaks existing escrows.

**Mitigation**:
- ✅ Snapshot semantics protect existing escrows
- ✅ New escrows use new module, old escrows use old module
- ✅ Interface compliance ensures compatibility
- ✅ Comprehensive testing before deployment

### Risk: Migration Failures

**Scenario**: Migration script fails or misses data.

**Mitigation**:
- ✅ Read-only access to old module as fallback
- ✅ Test migration on testnet first
- ✅ Design modules to handle missing state gracefully
- ✅ Events provide audit trail for reconstruction

---

## Best Practices

### 1. Versioning

Always update `moduleVersion()` when deploying new version:

```solidity
function moduleVersion() external pure override returns (string memory version) {
    return '2.0.0'; // Increment appropriately
}
```

### 2. Interface Compliance

Ensure new module implements the same interface:

```solidity
// New module must implement all interface methods
contract MyModuleV2 is IMyModule {
    // All interface methods must be present
}
```

### 3. Backward Compatibility

Design upgrades to be backward compatible:

- Don't remove functionality that existing escrows depend on
- Add new features without breaking existing behavior
- Maintain same function signatures

### 4. Testing

Comprehensive testing before upgrade:

- Test new module in isolation
- Test with existing escrows (should continue using old module)
- Test migration scripts if needed
- Test on testnet before mainnet

### 5. Documentation

Document all changes:

- What changed in new version
- Migration requirements (if any)
- Breaking changes (if any)
- Testing performed

---

## Example Upgrade Scenario

### Upgrading DefaultResolutionModule

**Current**: `DefaultResolutionModuleV1` at `0xAAA`

**Goal**: Upgrade to `DefaultResolutionModuleV2` with improved resolver selection

**Steps**:

1. **Deploy V2**:
   ```bash
   hardhat deploy --tags DefaultResolutionModuleV2 --network baseSepolia
   ```
   Result: `DefaultResolutionModuleV2` at `0xBBB`

2. **Queue V2** (via governance):
   ```solidity
   baseEscrow.queueResolutionModule(0xBBB);
   ```
   ETA set to `block.timestamp + 7 days`

3. **Wait 7 days**

4. **Activate V2** (via governance):
   ```solidity
   baseEscrow.activateResolutionModule();
   ```
   `resolutionModule` now points to `0xBBB`

5. **Result**:
   - Existing escrows: Continue using `0xAAA` (snapshot)
   - New escrows: Use `0xBBB` (new default)
   - Old module: Still exists at `0xAAA`, can be used by old escrows

---

## Why No Proxies?

### Design Decision

The protocol uses **immutable modules** instead of proxy-based upgrades because:

1. **Security**: Immutable contracts are simpler to audit and verify
2. **Transparency**: No hidden upgrade logic, all code is visible
3. **Snapshot Protection**: Existing escrows are protected by snapshot semantics
4. **Simplicity**: No proxy complexity, no storage layout concerns
5. **Auditability**: Each version is a separate contract, easy to verify

### Trade-offs

**Pros of Immutable Modules**:
- ✅ Maximum security
- ✅ Clear auditability
- ✅ No upgrade attack surface
- ✅ Snapshot protection

**Cons of Immutable Modules**:
- ⚠️ State migration needed (if module has state)
- ⚠️ Gas cost for new deployment
- ⚠️ Old modules remain onchain

**Acceptance**: The security and simplicity benefits outweigh the migration costs. Modules are designed to minimize state, and migration strategies handle stateful modules.

---

## Summary

**Module Upgrade Strategy**:

1. **All modules are immutable** - No proxies, no upgradeable patterns
2. **Upgrades via module swapping** - Deploy new version, swap reference
3. **Slow lane governance** - ~9 days delay for safety
4. **Snapshot protection** - Existing escrows unaffected
5. **State migration** - Handle stateful modules via read-old, migration scripts, or stateless design

**Key Principle**: Simplicity, security, and transparency over upgrade convenience. The protocol prioritizes immutable, auditable contracts with clear upgrade paths over complex proxy patterns.

---

## References

- [Module Map](./MODULE_MAP.md) - Complete module interface mapping
- [Module Development Guide](./MODULE_DEVELOPMENT_GUIDE.md) - Guide for developing modules
- [Governance Process](../governance/GOVERNANCE_PROCESS.md) - Governance workflow
- [Architecture Overview](../architecture/ARCHITECTURE_OVERVIEW.md) - System architecture

---

_Last Updated: 2026-01-16_
