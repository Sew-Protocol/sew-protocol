# Module Upgrade Strategy

**Date**: 2025-01-XX  
**Status**: Design Document  
**Purpose**: Analyze upgrade mechanisms for modules, especially DecentralizedResolutionModule

---

## Executive Summary

**Current State**: Modules are upgraded by **swapping them out** (new deployment, update reference in BaseEscrow)

**Recommendation**: For frequently-changing modules like `DecentralizedResolutionModule`, implement **proxy-based upgrades** (UUPS or Transparent) to preserve state and enable seamless upgrades.

---

## Current Module Upgrade Mechanism

### Module Swapping (Current Approach)

**How It Works**:
1. Deploy new module contract
2. Use slow-lane queue (`queueResolutionModule`)
3. After delay, activate new module (`activateResolutionModule`)
4. BaseEscrow now uses new module address
5. **State is lost** - new module starts fresh

**Implementation** (BaseEscrow.sol):
```solidity
address public resolutionModule;
address public pendingResolutionModule;
uint256 public pendingResolutionModuleEta;
uint256 public resolutionModuleDelay = 0;

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

**Cons**:
- ❌ **State Loss**: All module state is lost (resolvers, disputes, stats)
- ❌ **Migration Required**: Must migrate data from old to new module
- ❌ **Gas Cost**: Deploy new contract + migration
- ❌ **Downtime Risk**: Brief window during migration
- ❌ **Complex State**: Hard to migrate complex state (mappings, arrays)

---

## Proxy-Based Upgrades (Available Infrastructure)

### Existing Infrastructure

**Codebase Has**:
- ✅ OpenZeppelin upgradeable contracts support
- ✅ Hardhat-upgrades plugin
- ✅ UUPS and Transparent proxy examples
- ✅ Deployment scripts for proxy patterns

**Examples**:
- `UpgradeableBox.sol` - Example upgradeable contract
- `deploy/10_proxy.ts` - Proxy deployment script
- `test/hardhat/upgradeableBox.test.ts` - Upgrade tests

### Proxy Patterns Available

#### 1. UUPS (Universal Upgradeable Proxy Standard)

**How It Works**:
- Implementation contract contains upgrade logic
- Proxy delegates calls to implementation
- Upgrade function in implementation contract
- More gas-efficient (no admin contract)

**Pros**:
- ✅ Gas efficient
- ✅ Upgrade logic in implementation
- ✅ Standard pattern (ERC-1967)

**Cons**:
- ⚠️ Must be careful with upgrade function security
- ⚠️ Implementation must inherit `UUPSUpgradeable`

#### 2. Transparent Proxy

**How It Works**:
- ProxyAdmin contract manages upgrades
- Proxy delegates calls to implementation
- Upgrade function in ProxyAdmin (not implementation)
- More secure (separate admin)

**Pros**:
- ✅ More secure (admin separate from implementation)
- ✅ Clear separation of concerns
- ✅ Standard OpenZeppelin pattern

**Cons**:
- ⚠️ Slightly more gas (admin contract)
- ⚠️ More complex deployment

---

## DecentralizedResolutionModule State Analysis

### Critical State That Must Be Preserved

**Resolver Registries**:
```solidity
mapping(address => bool) public isApprovedResolver;
mapping(address => bool) public isApprovedSeniorResolver;
address[] public approvedResolvers;
address[] public approvedSeniorResolvers;
```

**Dispute Metadata**:
```solidity
mapping(uint256 => DisputeMetadata) public disputeMetadata;
mapping(uint256 => bytes32) public escrowCategory;
```

**Resolver Statistics**:
```solidity
mapping(address => ResolverStats) public resolverStats;
mapping(address => ResolverCapacity) public resolverCapacity;
```

**Configuration**:
```solidity
mapping(uint8 => EscalationConfig) public escalationConfig;
mapping(bytes32 => ResolutionTableEntry) public resolutionTable;
uint256 public disputeTimeout;
```

**Round-Robin Counters**:
```solidity
mapping(bytes32 => uint256) public categoryResolverIndex;
mapping(bytes32 => uint256) public categorySeniorResolverIndex;
```

**Integration**:
```solidity
ResolverIncentiveModule public incentiveModule;
mapping(address => bool) public registeredEscrowContracts;
```

### State Migration Complexity

**Easy to Migrate**:
- ✅ Simple mappings (address → bool)
- ✅ Single values (timeouts, configs)

**Hard to Migrate**:
- ❌ Arrays (approvedResolvers, approvedSeniorResolvers)
- ❌ Complex structs (DisputeMetadata, ResolverStats)
- ❌ Nested mappings
- ❌ Round-robin counters (must maintain order)

**Very Hard to Migrate**:
- ❌ Active dispute state (must ensure continuity)
- ❌ Resolver statistics (must preserve history)
- ❌ Integration state (registered escrow contracts)

---

## Recommendation: Hybrid Approach

### Strategy

**Use Proxy Upgrades for Stateful Modules**:
- `DecentralizedResolutionModule` → UUPS proxy
- `ResolverIncentiveModule` → UUPS proxy

**Use Module Swapping for Stateless Modules**:
- `DefaultResolutionModule` → Simple swap (no state)
- `PaymentCalculationLibraryV1` → Already swappable

### Implementation Plan

#### Phase 1: Make DecentralizedResolutionModule Upgradeable

**Step 1: Convert to Upgradeable Contract**
```solidity
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract DecentralizedResolutionModule is 
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IResolutionModule,
    UUPSUpgradeable,
    SlowLaneQueueActivate 
{
    // Remove constructor, use initialize instead
    function initialize(address admin) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ROLE_TIMELOCK, admin);
    }
    
    // Add upgrade authorization
    function _authorizeUpgrade(address newImplementation) 
        internal 
        override 
        onlyRole(ROLE_TIMELOCK) 
    {}
}
```

**Step 2: Update Deployment Script**
```typescript
// deploy/DecentralizedResolutionModule.ts
const { deploy } = deployments;
const { deployer } = await getNamedAccounts();

await deploy('DecentralizedResolutionModule', {
  from: deployer,
  contract: 'DecentralizedResolutionModule',
  log: true,
  proxy: {
    proxyContract: 'ERC1967Proxy',
    execute: {
      methodName: 'initialize',
      args: [deployer], // admin
    },
  },
});
```

**Step 3: Update BaseEscrow Integration**
```solidity
// BaseEscrow still uses module address
// But now module is a proxy, so upgrades preserve state
address public resolutionModule; // Points to proxy address
```

#### Phase 2: Upgrade Process

**Upgrade Flow**:
1. Deploy new implementation contract (V2)
2. Call `upgradeTo(newImplementation)` on proxy (via ROLE_TIMELOCK)
3. State is preserved automatically
4. No migration needed

**Example Upgrade**:
```solidity
// DecentralizedResolutionModuleV2.sol
contract DecentralizedResolutionModuleV2 is DecentralizedResolutionModule {
    // New functionality
    function newFeature() external {
        // ...
    }
    
    // Preserve existing functionality
    // All state from V1 is automatically available
}
```

**Upgrade Script**:
```typescript
const module = await ethers.getContract('DecentralizedResolutionModule');
const ModuleV2 = await ethers.getContractFactory('DecentralizedResolutionModuleV2');

await upgrades.upgradeProxy(module.address, ModuleV2, { 
  kind: 'uups',
  call: 'reinitialize' // If needed
});
```

---

## Comparison: Module Swap vs Proxy Upgrade

### Module Swap (Current)

| Aspect | Rating | Notes |
|--------|--------|-------|
| **State Preservation** | ❌ None | All state lost |
| **Migration Complexity** | ❌ High | Must migrate all data |
| **Gas Cost** | ⚠️ Medium | Deploy + migrate |
| **Downtime Risk** | ⚠️ Medium | Brief window during swap |
| **Simplicity** | ✅ High | Just swap address |
| **Safety** | ✅ High | Old module still exists |
| **Use Case** | Stateless modules | DefaultResolutionModule |

### Proxy Upgrade (Recommended)

| Aspect | Rating | Notes |
|--------|--------|-------|
| **State Preservation** | ✅ Full | All state preserved |
| **Migration Complexity** | ✅ None | Automatic |
| **Gas Cost** | ✅ Low | Just deploy implementation |
| **Downtime Risk** | ✅ Low | Atomic upgrade |
| **Simplicity** | ⚠️ Medium | Requires proxy setup |
| **Safety** | ✅ High | Storage layout checks |
| **Use Case** | Stateful modules | DecentralizedResolutionModule |

---

## Storage Layout Safety

### Critical Requirement

**Storage Layout Must Be Compatible**:
- New implementation must not change storage layout
- Can only append new state variables
- Cannot remove or reorder existing variables

**OpenZeppelin Tooling**:
```bash
# Check storage layout compatibility
npx hardhat verify-storage-layout --contract DecentralizedResolutionModule
```

**Best Practices**:
1. Always run storage layout checks before upgrade
2. Use `storage gaps` for future-proofing:
```solidity
uint256[50] private __gap; // Reserve 50 storage slots
```
3. Document all storage changes
4. Test upgrades on testnet first

---

## Implementation Steps

### Step 1: Convert DecentralizedResolutionModule to Upgradeable

1. **Update Imports**:
   - `AccessControl` → `AccessControlUpgradeable`
   - `ReentrancyGuard` → `ReentrancyGuardUpgradeable`
   - Add `UUPSUpgradeable`

2. **Replace Constructor with Initialize**:
   - Remove constructor
   - Add `initialize()` function
   - Add `initializer` modifier

3. **Add Upgrade Authorization**:
   ```solidity
   function _authorizeUpgrade(address newImplementation) 
       internal 
       override 
       onlyRole(ROLE_TIMELOCK) 
   {}
   ```

4. **Add Storage Gap** (for future-proofing):
   ```solidity
   uint256[50] private __gap;
   ```

### Step 2: Update Deployment

1. **Create Proxy Deployment Script**:
   - Use `deploy/DecentralizedResolutionModule.ts`
   - Deploy via ERC1967Proxy
   - Initialize with admin address

2. **Update BaseEscrow Integration**:
   - BaseEscrow points to proxy address
   - No changes needed to BaseEscrow

### Step 3: Test Upgrade Path

1. **Deploy V1**:
   - Deploy via proxy
   - Initialize with test data
   - Verify functionality

2. **Deploy V2**:
   - Create V2 implementation
   - Run storage layout check
   - Upgrade proxy to V2
   - Verify state preserved
   - Verify new functionality works

### Step 4: Production Deployment

1. **Deploy V1 to Mainnet**:
   - Deploy via proxy
   - Initialize
   - Register with BaseEscrow

2. **Future Upgrades**:
   - Deploy new implementation
   - Verify storage layout
   - Execute upgrade via governance
   - State automatically preserved

---

## Alternative: Module Versioning

### If Proxy Upgrades Are Not Desired

**Option: Versioned Modules**:
```solidity
contract DecentralizedResolutionModuleV1 {
    // V1 implementation
}

contract DecentralizedResolutionModuleV2 {
    // V2 implementation
    // Can import/read from V1 for migration
}
```

**Migration Script**:
```typescript
// Read state from V1
const v1 = await ethers.getContract('DecentralizedResolutionModuleV1');
const resolvers = await v1.getApprovedResolvers();

// Deploy V2
const v2 = await deploy('DecentralizedResolutionModuleV2');

// Migrate state
for (const resolver of resolvers) {
    await v2.appointResolver(resolver);
}
```

**Pros**: No proxy complexity  
**Cons**: Manual migration, gas cost, downtime risk

---

## Recommendation Summary

### For DecentralizedResolutionModule

**Use UUPS Proxy**:
- ✅ Preserves all state automatically
- ✅ No migration needed
- ✅ Lower gas cost for upgrades
- ✅ Atomic upgrades (no downtime)
- ✅ Infrastructure already exists
- ⚠️ Requires careful storage layout management

### For Other Modules

**Stateless Modules** (DefaultResolutionModule):
- Continue using module swap (simple, no state to preserve)

**Stateful Modules** (ResolverIncentiveModule):
- Consider UUPS proxy if state becomes complex

---

## Next Steps

1. **Design Review**: Review this strategy with team
2. **Implementation**: Convert DecentralizedResolutionModule to upgradeable
3. **Testing**: Comprehensive upgrade testing
4. **Documentation**: Update deployment and upgrade guides
5. **Governance**: Define upgrade process in governance docs

---

## Critical Design Constraint: Module Snapshotting and In-Flight Escrows

### The Core Principle

**Design Rule**: Changes to modules should only impact **future escrows**, and **in-flight escrows are unaffected**.

This is enforced via **module snapshotting**: When an escrow is created, the current module addresses are snapshotted into the `EscrowTransfer` struct:

```solidity
struct EscrowTransfer {
    // ...
    address snapshotResolutionModule;    // Resolution module at creation time
    // ...
}
```

When an escrow needs to interact with a module (e.g., check resolver authorization), it uses the **snapshot address**, not the current module address:

```solidity
function _isAuthorizedResolver(uint256 workflowId, address resolver) internal view returns (bool) {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    address snapshotModule = et.snapshotResolutionModule;
    
    // Use snapshot module, not current module
    if (snapshotModule != address(0)) {
        // Check authorization with snapshot module
        return IResolutionModule(snapshotModule).isAuthorizedResolver(...);
    }
}
```

### The Proxy Upgrade Concern

**Question**: If we upgrade a module via proxy, does this break the constraint?

**Answer**: It depends on how we define "module change":

1. **Module Swapping** (Current): Changing `resolutionModule` address → **Breaks constraint** ❌
   - Old escrows use old module address
   - New escrows use new module address
   - ✅ Constraint preserved (snapshot prevents switching)

2. **Proxy Upgrading** (Proposed): Upgrading implementation behind same proxy → **Preserves constraint** ✅
   - Old escrows use same proxy address (snapshot)
   - New escrows use same proxy address
   - Implementation changes, but address stays same
   - ⚠️ **But**: In-flight escrows DO see the upgraded implementation

### The Distinction: Module Swapping vs Module Upgrading

#### Module Swapping (Immutable Modules)

**Definition**: Replacing one module contract with a completely different module contract.

**Example**:
- Old: `DefaultResolutionModule` at `0xAAA`
- New: `DecentralizedResolutionModule` at `0xBBB`
- BaseEscrow: `resolutionModule = 0xBBB` (swapped)

**Behavior**:
- Old escrows: Snapshot = `0xAAA` → Continue using `DefaultResolutionModule`
- New escrows: Snapshot = `0xBBB` → Use `DecentralizedResolutionModule`
- ✅ **Constraint preserved**: Escrows never switch between modules

**Use Case**: Stateless modules, simple modules, or when you want complete isolation.

#### Module Upgrading (Upgradeable Modules)

**Definition**: Upgrading the implementation of an upgradeable module while keeping the same proxy address.

**Example**:
- Module: `DecentralizedResolutionModule` proxy at `0xCCC`
- V1 Implementation: `0xDDD`
- V2 Implementation: `0xEEE`
- Upgrade: Proxy at `0xCCC` now points to `0xEEE`

**Behavior**:
- Old escrows: Snapshot = `0xCCC` → Use upgraded V2 implementation
- New escrows: Snapshot = `0xCCC` → Use upgraded V2 implementation
- ⚠️ **Both see upgrade**: In-flight escrows are affected

**Use Case**: Complex stateful modules that need improvements without losing state.

### The Design Rule: Refined

**Original Rule**: "Changes only impact future escrows, in-flight escrows are unaffected"

**Refined Rule**: 
1. **Escrows never switch between modules mid-flight** (module swapping is prevented by snapshots)
2. **Upgradeable modules can be upgraded** (same module address, improved implementation)
3. **In-flight escrows using upgradeable modules will see upgrades** (by design)

### When Are Upgrades Acceptable?

#### ✅ Acceptable: Bug Fixes and Improvements

**Examples**:
- Fix critical bug in resolver selection
- Improve gas efficiency
- Add new features (backward compatible)
- Fix security vulnerability

**Rationale**: These improve the module without changing its fundamental behavior. In-flight escrows benefit from fixes.

#### ⚠️ Acceptable with Caution: Feature Additions

**Examples**:
- Add new escalation level
- Add new resolver selection algorithm
- Add new configuration options

**Rationale**: Must be backward compatible. Existing escrows should continue working with old behavior, new escrows can use new features.

#### ❌ Not Acceptable: Breaking Changes

**Examples**:
- Change core dispute resolution logic
- Change escalation fee structure mid-dispute
- Remove features that in-flight escrows depend on

**Rationale**: These could break in-flight escrows or change expected behavior.

### Proposed Module Classification

#### Immutable Modules

**Definition**: Modules that cannot be upgraded. Once deployed, they are fixed.

**Characteristics**:
- Deployed as regular contracts (no proxy)
- Upgraded by swapping to new contract
- Old escrows continue using old contract
- New escrows use new contract

**Examples**:
- `DefaultResolutionModule` (simple, stateless)
- `DefaultReleaseStrategy` (simple logic)

**Upgrade Path**: Deploy new version → Swap via `proposeResolutionModule()` → Activate

#### Upgradeable Modules

**Definition**: Modules that can be upgraded via proxy while preserving state.

**Characteristics**:
- Deployed via proxy (UUPS or Transparent)
- Upgraded by pointing proxy to new implementation
- All escrows (old and new) use same proxy address
- State is preserved across upgrades

**Examples**:
- `DecentralizedResolutionModule` (complex, stateful)
- `ResolverIncentiveModule` (tracks payments, stateful)

**Upgrade Path**: Deploy new implementation → Upgrade proxy → All escrows see upgrade

### Implementation Strategy

#### For Immutable Modules

**Current Approach** (Keep as-is):
```solidity
// Deploy as regular contract
DefaultResolutionModule module = new DefaultResolutionModule();

// Swap via BaseEscrow
baseEscrow.proposeResolutionModule(newModule);
baseEscrow.activateResolutionModule();
```

**Behavior**:
- Old escrows: Snapshot = old module address
- New escrows: Snapshot = new module address
- ✅ Constraint preserved

#### For Upgradeable Modules

**New Approach**:
```solidity
// Deploy via proxy
DecentralizedResolutionModule impl = new DecentralizedResolutionModule();
ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);

// BaseEscrow points to proxy
baseEscrow.proposeResolutionModule(address(proxy));
baseEscrow.activateResolutionModule();

// Future upgrade (no BaseEscrow change needed)
DecentralizedResolutionModuleV2 impl2 = new DecentralizedResolutionModuleV2();
proxy.upgradeTo(address(impl2)); // All escrows see upgrade
```

**Behavior**:
- Old escrows: Snapshot = proxy address → Use upgraded implementation
- New escrows: Snapshot = proxy address → Use upgraded implementation
- ⚠️ Both see upgrade (by design)

### Governance Considerations

#### Upgrade Authorization

**For Immutable Modules**:
- Swapping requires `proposeResolutionModule()` + `activateResolutionModule()`
- Slow-lane queue (48h-30 days delay)
- Old module remains available for old escrows

**For Upgradeable Modules**:
- Upgrading requires `upgradeTo()` on proxy (via ROLE_TIMELOCK)
- Should also use slow-lane queue for safety
- All escrows see upgrade immediately

#### Upgrade Policy

**Recommendation**: Define clear upgrade policy:

1. **Immutable Modules**: Can be swapped freely (old escrows unaffected)
2. **Upgradeable Modules**: Can be upgraded, but:
   - Must be backward compatible
   - Must preserve storage layout
   - Must not break in-flight escrows
   - Should use slow-lane queue

### Risk Analysis

#### Risk: In-Flight Escrows Affected by Upgrade

**Scenario**: Dispute is in progress, module is upgraded, behavior changes.

**Mitigation**:
- ✅ Only backward-compatible upgrades
- ✅ Storage layout preservation
- ✅ Comprehensive testing
- ✅ Slow-lane queue (time to review)

**Acceptance**: This is a **feature, not a bug** - in-flight escrows benefit from bug fixes and improvements.

#### Risk: Breaking Changes

**Scenario**: Upgrade introduces breaking change, in-flight escrow breaks.

**Mitigation**:
- ❌ Never allow breaking changes
- ✅ Storage layout checks
- ✅ Comprehensive testing
- ✅ Testnet validation
- ✅ Governance review

**Prevention**: Strict upgrade policy, governance oversight, testing requirements.

### Alternative: Versioned Upgradeable Modules

**If we want stricter isolation**:

**Approach**: Deploy new proxy for each major version:
- V1: Proxy at `0xAAA` → Implementation V1
- V2: Proxy at `0xBBB` → Implementation V2
- BaseEscrow: Swap from `0xAAA` to `0xBBB`

**Behavior**:
- Old escrows: Snapshot = `0xAAA` → Stay on V1
- New escrows: Snapshot = `0xBBB` → Use V2
- ✅ Constraint fully preserved

**Trade-off**:
- ✅ Complete isolation
- ❌ State migration required
- ❌ More complex
- ❌ Higher gas cost

**Recommendation**: Only use if strict isolation is required. Otherwise, single proxy with careful upgrades is better.

### Conclusion

**The Constraint**: "Changes only impact future escrows, in-flight escrows are unaffected"

**Refined Understanding**:
- ✅ **Module Swapping**: Constraint preserved (snapshots prevent switching)
- ⚠️ **Module Upgrading**: Constraint relaxed (same module, improved implementation)
- ✅ **Design Rule**: Escrows never switch modules, but upgradeable modules can be upgraded

**Recommendation**:
1. **Classify modules** as Immutable or Upgradeable
2. **Immutable modules**: Use module swapping (current approach)
3. **Upgradeable modules**: Use proxy upgrades (new approach)
4. **Governance**: Define clear upgrade policy for upgradeable modules
5. **Testing**: Comprehensive testing to ensure backward compatibility

**Key Insight**: The constraint is about **module identity** (address), not **module implementation**. Upgrading an upgradeable module is acceptable because it's still the "same module" (same proxy address), just with improved functionality.

---

## Module Developer Role for Instant Upgrades

### New Governance Model

To provide flexibility for rapid iteration, a new role **"module developer - mainnet ops"** (`ROLE_MODULE_DEVELOPER`) is introduced. This role allows **instant upgrades** of DecentralizedResolutionModule (via UUPS proxy) while maintaining security through event emission and disclosure requirements.

**Key Design**:
- ✅ Role issued by DAO (`ROLE_TIMELOCK` can grant/revoke)
- ✅ Instant upgrades (no slow-lane delay)
- ✅ Events emitted on every upgrade
- ✅ Well-defined disclosure process
- ✅ Maintains security through role management

**See**: `MODULE_DEVELOPER_ROLE_DESIGN.md` for complete design.

---

*This document should be updated as upgrade patterns are implemented and refined.*

