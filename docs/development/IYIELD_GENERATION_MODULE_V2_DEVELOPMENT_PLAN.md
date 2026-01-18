# Development Plan: IYieldGenerationModule V2 Enhancement

**Date**: 2026-01-27  
**Target**: Enhanced IYieldGenerationModule Interface + Module Registry  
**Estimated Effort**: 2-3 weeks  
**Status**: 📋 Planning

---

## Executive Summary

This development plan outlines the implementation of enhanced capabilities for `IYieldGenerationModule` and the introduction of a `YieldModuleRegistry` pattern. The enhancements will enable:

1. **Capability Detection**: Query what features a module supports
2. **Yield Prediction**: Get current pending yield for an escrow
3. **APY Queries**: Retrieve annual percentage yield for tokens
4. **Emergency Withdrawal**: Support for emergency fund recovery
5. **Module Versioning**: Track and manage module versions
6. **Module Registry**: Centralized discovery and management system

---

## Phase 1: Enhanced IYieldGenerationModule Interface

### 1.1 Current State Analysis

**Current Interface** (`contracts/interfaces/IYieldGenerationModule.sol`):
```solidity
interface IYieldGenerationModule {
    // Core operations
    function depositForYield(uint256 workflowId, address token, uint256 amount) 
        external returns (bool success, uint256 yieldTokenBalance);
    function withdrawWithYield(uint256 workflowId, address token, uint256 originalAmount) 
        external returns (bool success, uint256 actualAmount, uint256 yieldAmount);
    
    // Existing capabilities
    function calculateYield(uint256 workflowId, address token) 
        external view returns (uint256 yieldAmount);  // ✅ EXISTS
    function isTokenSupported(address token) 
        external view returns (bool supported);
    function getApprovalTarget(address token) 
        external view returns (address approvalTarget);
    
    // Versioning (already exists)
    function moduleName() external pure returns (string memory name);  // ✅ EXISTS
    function moduleVersion() external pure returns (string memory version);  // ✅ EXISTS
}
```

**Already Implemented**:
- ✅ `calculateYield()` - Current yield calculation (similar to `getCurrentYield()`)
- ✅ `moduleName()` - Module identifier
- ✅ `moduleVersion()` - Semantic versioning

**Current Usage Points**:
- `BaseEscrow._depositForYield()` - Deposits tokens
- `YieldOps.handleYield()` - Withdraws with yield
- `EscrowVault` / `EscrowableERC20` - Module snapshots

**Files to Review**:
- `contracts/interfaces/IYieldGenerationModule.sol`
- `contracts/modules/AaveYieldGenerationModule.sol`
- `contracts/core/BaseEscrow.sol` (yield handling)
- `contracts/YieldOps.sol`

---

### 1.2 Feature Flags & Capability Detection

#### Task 1.2.1: Define Feature Constants

**File**: `contracts/interfaces/IYieldGenerationModule.sol`

**Implementation**:
```solidity
// Feature flags for module capabilities
bytes32 public constant FEATURE_PARTIAL_WITHDRAWAL = keccak256("PARTIAL_WITHDRAWAL");
bytes32 public constant FEATURE_YIELD_PREDICTION = keccak256("YIELD_PREDICTION");
bytes32 public constant FEATURE_APY_QUERY = keccak256("APY_QUERY");
bytes32 public constant FEATURE_EMERGENCY_WITHDRAW = keccak256("EMERGENCY_WITHDRAW");
bytes32 public constant FEATURE_CURRENT_YIELD = keccak256("CURRENT_YIELD");

interface IYieldGenerationModule {
    // Existing methods...
    
    /**
     * @notice Check if module supports a specific feature
     * @param feature Feature identifier (keccak256 hash of feature name)
     * @return supported True if feature is supported
     * @dev Allows capability-based feature detection
     *      Returns false for unknown/unsupported features (graceful degradation)
     */
    function supportsFeature(bytes32 feature) external view returns (bool supported);
}
```

**Acceptance Criteria**:
- ✅ All feature constants defined
- ✅ `supportsFeature()` method signature added
- ✅ Documentation explains feature flag pattern
- ✅ Returns `false` for unsupported features (not revert)

**Testing Requirements**:
- Unit test: `supportsFeature()` returns correct values for each feature
- Unit test: `supportsFeature()` returns `false` for unknown features
- Integration test: BaseEscrow checks features before calling

---

### 1.3 Yield Prediction & Current Yield

#### Task 1.3.1: Add `getCurrentYield()` Method (or alias `calculateYield()`)

**Status**: ⚠️ **ALREADY EXISTS** - `calculateYield()` provides similar functionality

**Analysis**:
- Current interface has `calculateYield()` which returns current yield
- Consider if `getCurrentYield()` is needed or if `calculateYield()` is sufficient
- May want to add `getCurrentYield()` as alias for consistency with other interfaces

**Decision**: Either:
- **Option A**: Use existing `calculateYield()` (recommended - no change needed)
- **Option B**: Add `getCurrentYield()` as alias (for consistency)

**If adding `getCurrentYield()`**:
```solidity
interface IYieldGenerationModule {
    // Existing: calculateYield() already exists
    
    /**
     * @notice Get current pending yield for an escrow (alias for calculateYield)
     * @param workflowId The escrow workflow ID
     * @param token Token address
     * @return pendingYield Current pending yield amount (0 if not applicable)
     * @dev Optional feature - delegates to calculateYield() if implemented
     */
    function getCurrentYield(
        uint256 workflowId,
        address token
    ) external view returns (uint256 pendingYield) {
        return this.calculateYield(workflowId, token);
    }
}
```

**Recommendation**: **Use existing `calculateYield()`** - no interface change needed. Update documentation to clarify usage.

---

### 1.4 APY Queries

#### Task 1.4.1: Add `getYieldRate()` Method

**File**: `contracts/interfaces/IYieldGenerationModule.sol`

**Implementation**:
```solidity
interface IYieldGenerationModule {
    // Existing methods...
    
    /**
     * @notice Get annual percentage yield (APY) for a token
     * @param token Token address
     * @return apyBps APY in basis points (e.g., 500 = 5% APY, 1500 = 15% APY)
     * @return isValid True if APY data is current and valid
     * @dev Returns 0 and isValid=false if token not supported or data unavailable
     *      APY may change over time (variable rate protocols)
     *      Frontends should display with appropriate disclaimers
     */
    function getYieldRate(address token) 
        external view returns (uint256 apyBps, bool isValid);
}
```

**Implementation Notes**:
- Should return basis points (100 = 1%, 10000 = 100%)
- `isValid` flag indicates if data is fresh/reliable
- Consider caching for gas efficiency (APY changes slowly)
- Different protocols have different update frequencies

**Acceptance Criteria**:
- ✅ Method signature added with `apyBps` and `isValid` returns
- ✅ Returns 0 and `isValid=false` for unsupported tokens
- ✅ Accurately reflects current APY from underlying protocol
- ✅ Handles variable-rate protocols gracefully

**Testing Requirements**:
- Unit test: `getYieldRate()` returns correct APY for supported tokens
- Unit test: `getYieldRate()` returns (0, false) for unsupported tokens
- Unit test: `isValid` flag correctly indicates data freshness
- Integration test: Frontend can display APY from multiple modules

---

### 1.5 Emergency Withdrawal Support

#### Task 1.5.1: Add `emergencyWithdraw()` Method

**File**: `contracts/interfaces/IYieldGenerationModule.sol`

**Implementation**:
```solidity
interface IYieldGenerationModule {
    // Existing methods...
    
    /**
     * @notice Emergency withdrawal - bypass normal yield withdrawal logic
     * @param workflowId The escrow workflow ID
     * @param token Token address
     * @return success True if withdrawal succeeded
     * @return actualAmount Amount withdrawn (may be less than deposited if emergency)
     * @dev Emergency function - should only be called by ROLE_GUARDIAN
     *      May forfeit yield or incur penalties depending on protocol
     *      Used when normal withdrawal fails or protocol issues arise
     *      Should emit event for audit trail
     */
    function emergencyWithdraw(
        uint256 workflowId,
        address token
    ) external returns (bool success, uint256 actualAmount);
}
```

**Implementation Notes**:
- Should be protected by access control (ROLE_GUARDIAN)
- May incur penalties (e.g., Aave early withdrawal fee)
- Should emit event for audit trail
- Consider different emergency scenarios (protocol pause, slashing, etc.)

**Acceptance Criteria**:
- ✅ Method signature added to interface
- ✅ Access control enforced (only ROLE_GUARDIAN)
- ✅ Handles various emergency scenarios gracefully
- ✅ Returns accurate amounts (may include penalties)
- ✅ Emits events for audit trail

**Testing Requirements**:
- Unit test: `emergencyWithdraw()` succeeds when called by guardian
- Unit test: `emergencyWithdraw()` reverts when called by non-guardian
- Unit test: `emergencyWithdraw()` handles protocol penalties correctly
- Integration test: Emergency withdrawal recovers funds during protocol issues
- Security test: Access control cannot be bypassed

---

### 1.6 Module Versioning

#### Task 1.6.1: Verify Version Methods Implementation

**Status**: ✅ **ALREADY EXISTS** - Both `moduleName()` and `moduleVersion()` are in interface

**Action Required**:
1. **Verify implementations**: Check that all existing modules implement these methods
   - `AaveYieldGenerationModule`
   - `DefaultYieldModule`
   - Any other modules

2. **Update implementations** (if needed):
   ```solidity
   // Example for AaveYieldGenerationModule
   function moduleName() external pure override returns (string memory) {
       return "AaveYieldGeneration";
   }
   
   function moduleVersion() external pure override returns (string memory) {
       return "1.0.0";  // Update to reflect current version
   }
   ```

3. **Documentation**: Ensure NatSpec explains semantic versioning expectations

**Acceptance Criteria**:
- ✅ All modules implement `moduleName()`
- ✅ All modules implement `moduleVersion()`
- ✅ Versions follow semantic versioning
- ✅ Registry can query versions successfully

**Testing Requirements**:
- Unit test: All modules return valid names
- Unit test: All modules return valid semantic versions
- Integration test: Registry queries versions correctly

---

### 1.7 Update Existing Module Implementations

#### Task 1.7.1: Update AaveYieldGenerationModule

**File**: `contracts/modules/AaveYieldGenerationModule.sol`

**Implementation Steps**:
1. Implement `supportsFeature()`:
   ```solidity
   function supportsFeature(bytes32 feature) external pure override returns (bool) {
       if (feature == FEATURE_YIELD_PREDICTION) return true;
       if (feature == FEATURE_APY_QUERY) return true;
       if (feature == FEATURE_EMERGENCY_WITHDRAW) return true;
       if (feature == FEATURE_CURRENT_YIELD) return true;
       return false; // FEATURE_PARTIAL_WITHDRAWAL not supported
   }
   ```

2. Implement `getCurrentYield()`:
   - Query Aave pool for current balance
   - Calculate difference from deposited amount
   - Return pending yield

3. Implement `getYieldRate()`:
   - Query Aave pool's current liquidity rate
   - Convert to APY (consider compounding)
   - Return basis points and `isValid=true`

4. Implement `emergencyWithdraw()`:
   - Call Aave's emergency withdrawal (if available)
   - Or normal withdrawal with penalty handling
   - Emit `EmergencyWithdrawalExecuted` event

5. Implement `moduleName()` and `moduleVersion()`:
   ```solidity
   function moduleName() external pure override returns (string memory) {
       return "AaveYieldGeneration";
   }
   
   function moduleVersion() external pure override returns (string memory) {
       return "1.0.0";
   }
   ```

**Acceptance Criteria**:
- ✅ All new interface methods implemented
- ✅ Feature flags correctly indicate capabilities
- ✅ Graceful degradation for unsupported features
- ✅ Events emitted for important operations
- ✅ Gas-efficient implementations

**Testing Requirements**:
- Unit tests for all new methods
- Integration tests with Aave pool
- Edge case handling (empty pools, paused protocols, etc.)

---

## Phase 2: Module Registry Pattern

### 2.1 Registry Contract Design

#### Task 2.1.1: Create YieldModuleRegistry Contract

**File**: `contracts/registry/YieldModuleRegistry.sol` (new file)

**Design Decisions**:
- Centralized registry for all yield modules
- Per-token module discovery
- Version management and upgrade tracking
- Module activation/deactivation (guardian control)

**Implementation**:
```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '../interfaces/IYieldGenerationModule.sol';

/**
 * @title YieldModuleRegistry
 * @notice Centralized registry for yield generation modules
 * @dev Enables discovery, version management, and per-token module selection
 */
contract YieldModuleRegistry is AccessControl {
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    
    struct ModuleInfo {
        address module;
        string name;
        string version;
        bool isActive;
        address[] supportedTokens;
        mapping(address => uint256) tokenApyBps; // Cached APY per token
        uint256 registeredAt;
        uint256 lastUpdatedAt;
    }
    
    mapping(address => ModuleInfo) public modules;
    address[] public moduleList; // All registered modules
    
    // Per-token default module selection
    mapping(address => address) public defaultModuleForToken;
    
    // Per-token module list (for discovery)
    mapping(address => address[]) public modulesForToken;
    
    event ModuleRegistered(
        address indexed module,
        string name,
        string version,
        address[] supportedTokens
    );
    event ModuleUpdated(
        address indexed module,
        string version,
        address[] supportedTokens
    );
    event ModuleActivated(address indexed module, bool isActive);
    event DefaultModuleSet(address indexed token, address indexed module);
    event ModuleRemoved(address indexed token, address indexed module);
    
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }
    
    // ... implementation methods ...
}
```

**Key Methods**:
- `registerModule()` - Register new module
- `updateModule()` - Update module info (version, tokens)
- `activateModule()` / `deactivateModule()` - Enable/disable modules
- `setDefaultModuleForToken()` - Set default per token
- `getModulesForToken()` - Discovery method
- `getModuleInfo()` - Get full module details

**Acceptance Criteria**:
- ✅ Contract compiles without errors
- ✅ All events defined
- ✅ Access control enforced
- ✅ Gas-efficient storage layout

---

### 2.2 Module Registration

#### Task 2.2.1: Implement `registerModule()`

**Implementation**:
```solidity
/**
 * @notice Register a new yield generation module
 * @param module Module contract address
 * @param supportedTokens Array of token addresses supported by module
 * @dev Validates module implements IYieldGenerationModule
 *      Queries module for name/version via interface
 *      Fetches APY for each token if supported
 */
function registerModule(
    address module,
    address[] calldata supportedTokens
) external onlyRole(ROLE_TIMELOCK) {
    // Validate module implements interface
    require(
        IYieldGenerationModule(module).supportsInterface(
            type(IYieldGenerationModule).interfaceId
        ),
        "Module does not implement IYieldGenerationModule"
    );
    
    // Get module metadata
    string memory name = IYieldGenerationModule(module).moduleName();
    string memory version = IYieldGenerationModule(module).moduleVersion();
    
    // Store module info
    ModuleInfo storage info = modules[module];
    require(info.module == address(0), "Module already registered");
    
    info.module = module;
    info.name = name;
    info.version = version;
    info.isActive = true;
    info.supportedTokens = supportedTokens;
    info.registeredAt = block.timestamp;
    info.lastUpdatedAt = block.timestamp;
    
    // Update per-token lists
    for (uint256 i = 0; i < supportedTokens.length; i++) {
        address token = supportedTokens[i];
        modulesForToken[token].push(module);
        
        // Cache APY if available
        if (IYieldGenerationModule(module).supportsFeature(FEATURE_APY_QUERY)) {
            (uint256 apyBps, bool isValid) = IYieldGenerationModule(module).getYieldRate(token);
            if (isValid) {
                info.tokenApyBps[token] = apyBps;
            }
        }
    }
    
    moduleList.push(module);
    emit ModuleRegistered(module, name, version, supportedTokens);
}
```

**Acceptance Criteria**:
- ✅ Validates interface implementation
- ✅ Queries module for name/version
- ✅ Caches APY for supported tokens
- ✅ Updates per-token module lists
- ✅ Emits events
- ✅ Access control enforced

**Testing Requirements**:
- Unit test: Successful registration
- Unit test: Reverts if module already registered
- Unit test: Reverts if not ROLE_TIMELOCK
- Unit test: APY caching works correctly
- Integration test: Registered modules discoverable

---

### 2.3 Discovery Methods

#### Task 2.3.1: Implement `getModulesForToken()`

**Implementation**:
```solidity
/**
 * @notice Get all active modules that support a token
 * @param token Token address
 * @return activeModules Array of active module addresses
 * @dev Returns only active modules for frontend discovery
 *      Ordered by registration (newest first)
 */
function getModulesForToken(address token) 
    external view returns (address[] memory activeModules) {
    address[] memory allModules = modulesForToken[token];
    uint256 activeCount = 0;
    
    // Count active modules
    for (uint256 i = 0; i < allModules.length; i++) {
        if (modules[allModules[i]].isActive) {
            activeCount++;
        }
    }
    
    // Build active modules array
    activeModules = new address[](activeCount);
    uint256 index = 0;
    for (uint256 i = 0; i < allModules.length; i++) {
        if (modules[allModules[i]].isActive) {
            activeModules[index] = allModules[i];
            index++;
        }
    }
    
    return activeModules;
}

/**
 * @notice Get full module information
 * @param module Module address
 * @return info Struct with module details
 * @dev Returns full module info for frontend display
 */
function getModuleInfo(address module) 
    external view returns (
        address moduleAddr,
        string memory name,
        string memory version,
        bool isActive,
        address[] memory supportedTokens,
        uint256 registeredAt,
        uint256 lastUpdatedAt
    ) {
    ModuleInfo storage info = modules[module];
    require(info.module != address(0), "Module not registered");
    
    return (
        info.module,
        info.name,
        info.version,
        info.isActive,
        info.supportedTokens,
        info.registeredAt,
        info.lastUpdatedAt
    );
}

/**
 * @notice Get APY for token from specific module
 * @param module Module address
 * @param token Token address
 * @return apyBps APY in basis points
 * @return isValid True if APY data is valid
 * @dev Queries module directly (may be cached in registry)
 */
function getModuleApyForToken(address module, address token)
    external view returns (uint256 apyBps, bool isValid) {
    ModuleInfo storage info = modules[module];
    require(info.module != address(0), "Module not registered");
    
    // Try cached value first
    uint256 cachedApy = info.tokenApyBps[token];
    if (cachedApy > 0) {
        return (cachedApy, true);
    }
    
    // Query module directly if supports feature
    if (IYieldGenerationModule(module).supportsFeature(FEATURE_APY_QUERY)) {
        return IYieldGenerationModule(module).getYieldRate(token);
    }
    
    return (0, false);
}
```

**Acceptance Criteria**:
- ✅ Returns only active modules
- ✅ Efficient gas usage (minimal external calls)
- ✅ Handles empty results gracefully
- ✅ Returns accurate module information

**Testing Requirements**:
- Unit test: Returns active modules only
- Unit test: Handles tokens with no modules
- Unit test: Cached APY used when available
- Integration test: Frontend can discover modules

---

### 2.4 Per-Token Module Selection (TBD)

#### Task 2.4.1: Implement Default Module Selection

**Status**: TBD - Design decision needed

**Open Questions**:
1. Should defaults be set by governance or module creators?
2. Should multiple modules be selectable per token?
3. How to handle module conflicts or priority?

**Proposed Implementation** (if approved):
```solidity
/**
 * @notice Set default module for a token
 * @param token Token address
 * @param module Module address (must support token)
 * @dev Allows governance to set preferred module per token
 */
function setDefaultModuleForToken(address token, address module)
    external onlyRole(ROLE_TIMELOCK) {
    require(
        IYieldGenerationModule(module).isTokenSupported(token),
        "Module does not support token"
    );
    require(modules[module].isActive, "Module not active");
    
    defaultModuleForToken[token] = module;
    emit DefaultModuleSet(token, module);
}

/**
 * @notice Get default module for token
 * @param token Token address
 * @return module Default module address (address(0) if none set)
 */
function getDefaultModuleForToken(address token)
    external view returns (address module) {
    return defaultModuleForToken[token];
}
```

**Decision Required**: Proceed with per-token default selection?

---

### 2.5 Version Management

#### Task 2.5.1: Implement Module Update Mechanism

**Implementation**:
```solidity
/**
 * @notice Update module information (version, supported tokens)
 * @param module Module address
 * @param supportedTokens Updated list of supported tokens
 * @dev Allows updating module metadata without re-registration
 *      Useful when module is upgraded to new version
 */
function updateModule(
    address module,
    address[] calldata supportedTokens
) external onlyRole(ROLE_TIMELOCK) {
    ModuleInfo storage info = modules[module];
    require(info.module != address(0), "Module not registered");
    
    // Get updated version
    string memory newVersion = IYieldGenerationModule(module).moduleVersion();
    
    // Remove from old token lists
    address[] memory oldTokens = info.supportedTokens;
    for (uint256 i = 0; i < oldTokens.length; i++) {
        _removeModuleFromToken(oldTokens[i], module);
    }
    
    // Update supported tokens
    info.supportedTokens = supportedTokens;
    info.version = newVersion;
    info.lastUpdatedAt = block.timestamp;
    
    // Add to new token lists
    for (uint256 i = 0; i < supportedTokens.length; i++) {
        address token = supportedTokens[i];
        if (!_moduleInTokenList(token, module)) {
            modulesForToken[token].push(module);
        }
        
        // Update APY cache
        if (IYieldGenerationModule(module).supportsFeature(FEATURE_APY_QUERY)) {
            (uint256 apyBps, bool isValid) = IYieldGenerationModule(module).getYieldRate(token);
            if (isValid) {
                info.tokenApyBps[token] = apyBps;
            }
        }
    }
    
    emit ModuleUpdated(module, newVersion, supportedTokens);
}

function _removeModuleFromToken(address token, address module) internal {
    address[] storage tokenModules = modulesForToken[token];
    for (uint256 i = 0; i < tokenModules.length; i++) {
        if (tokenModules[i] == module) {
            tokenModules[i] = tokenModules[tokenModules.length - 1];
            tokenModules.pop();
            break;
        }
    }
}

function _moduleInTokenList(address token, address module) internal view returns (bool) {
    address[] storage tokenModules = modulesForToken[token];
    for (uint256 i = 0; i < tokenModules.length; i++) {
        if (tokenModules[i] == module) {
            return true;
        }
    }
    return false;
}
```

**Acceptance Criteria**:
- ✅ Updates module metadata correctly
- ✅ Maintains per-token module lists
- ✅ Updates APY cache
- ✅ Emits events

**Testing Requirements**:
- Unit test: Module update succeeds
- Unit test: Token lists updated correctly
- Unit test: Version changes tracked
- Integration test: Frontend sees updated versions

---

## Phase 3: Integration & Testing

### 3.1 Update BaseEscrow Integration

#### Task 3.1.1: Add Registry Support to BaseEscrow

**Files to Modify**:
- `contracts/core/BaseEscrow.sol`

**Changes Needed**:
1. Optional registry reference (if available)
2. Helper methods to query module capabilities
3. Default module selection from registry

**Implementation** (if approved):
```solidity
// Optional registry (address(0) if not deployed)
address public yieldModuleRegistry;

function setYieldModuleRegistry(address registry) external onlyRole(ROLE_TIMELOCK) {
    yieldModuleRegistry = registry;
}

function _getDefaultModuleForToken(address token) internal view returns (address) {
    if (yieldModuleRegistry != address(0)) {
        try YieldModuleRegistry(yieldModuleRegistry).getDefaultModuleForToken(token) 
            returns (address module) {
            if (module != address(0)) {
                return module;
            }
        } catch {
            // Registry call failed, use contract default
        }
    }
    return address(defaultYieldGenerationModule); // Fallback
}
```

**Decision Required**: Should BaseEscrow integrate with registry or keep separate?

---

### 3.2 Testing Strategy

#### Task 3.2.1: Unit Tests

**Files to Create**:
- `test/foundry/modules/YieldModuleRegistry.t.sol`
- `test/foundry/modules/AaveYieldGenerationModuleV2.t.sol`
- `test/hardhat/modules/YieldModuleRegistry.test.ts`

**Test Coverage**:
- ✅ Interface method implementations
- ✅ Feature flag detection
- ✅ Yield prediction accuracy
- ✅ APY query correctness
- ✅ Emergency withdrawal access control
- ✅ Registry registration/discovery
- ✅ Version management

#### Task 3.2.2: Integration Tests

**Test Scenarios**:
- ✅ Multiple modules registered for same token
- ✅ Module upgrade preserves escrow compatibility
- ✅ Frontend discovery workflow
- ✅ Emergency withdrawal scenarios
- ✅ APY caching and updates

---

### 3.3 Documentation

#### Task 3.3.1: Update Interface Documentation

**Files to Update**:
- `contracts/interfaces/IYieldGenerationModule.sol` - NatSpec for all methods
- `docs/reference/YIELD_MODULES.md` - Module guide (create if needed)

#### Task 3.3.2: Create Registry Guide

**File**: `docs/guides/YIELD_MODULE_REGISTRY.md` (new)

**Content**:
- How to register modules
- How to query modules for tokens
- How to set defaults
- Version management best practices
- Frontend integration examples

---

## Implementation Checklist

### Phase 1: Interface Enhancement
- [ ] Define feature constants
- [ ] Add `supportsFeature()` method
- [ ] Add `getCurrentYield()` method
- [ ] Add `getYieldRate()` method
- [ ] Add `emergencyWithdraw()` method
- [ ] Add `moduleName()` and `moduleVersion()` methods
- [ ] Update AaveYieldGenerationModule implementation
- [ ] Unit tests for interface methods

### Phase 2: Module Registry
- [ ] Create YieldModuleRegistry contract
- [ ] Implement `registerModule()`
- [ ] Implement `updateModule()`
- [ ] Implement `activateModule()` / `deactivateModule()`
- [ ] Implement `getModulesForToken()`
- [ ] Implement `getModuleInfo()`
- [ ] Implement `getModuleApyForToken()`
- [ ] (TBD) Implement per-token default selection
- [ ] Unit tests for registry
- [ ] Integration tests

### Phase 3: Integration & Polish
- [ ] (Optional) BaseEscrow registry integration
- [ ] End-to-end integration tests
- [ ] Documentation updates
- [ ] Gas optimization review
- [ ] Security review
- [ ] Audit preparation

---

## Open Questions & Decisions Required

### Design Decisions:
1. **Per-Token Default Selection**: Should governance set default modules per token?
   - **Pro**: Clear preference, simpler UX
   - **Con**: Governance overhead, less flexibility

2. **BaseEscrow Registry Integration**: Should BaseEscrow use registry for defaults?
   - **Pro**: Centralized module management
   - **Con**: Additional dependency, complexity

3. **APY Caching Strategy**: How often should APY be refreshed?
   - **Option A**: On-demand (query module each time)
   - **Option B**: Cached with TTL (e.g., 1 hour)
   - **Option C**: Manual refresh via governance

4. **Emergency Withdrawal Access**: Only ROLE_GUARDIAN or also ROLE_TIMELOCK?
   - **Recommendation**: ROLE_GUARDIAN only (emergency function)

### Technical Decisions:
1. **Feature Flag Storage**: Store in registry or query module each time?
   - **Recommendation**: Query module (source of truth)

2. **Version Comparison**: Need helper functions to compare versions?
   - **Recommendation**: Defer to v2.1 (string comparison in Solidity is complex)

3. **Module Deletion**: Should modules be removable from registry?
   - **Recommendation**: Deactivate only (preserve history)

---

## Gas Impact Analysis

### Storage Costs (Registry):
- Module registration: ~200k gas (first time)
- Module update: ~100k gas
- Per-token mapping: ~20k gas per token

### Query Costs (View Functions):
- `supportsFeature()`: ~2k gas (pure function)
- `getCurrentYield()`: ~50k-100k gas (depends on protocol)
- `getYieldRate()`: ~30k-50k gas (depends on protocol)
- `getModulesForToken()`: ~5k gas + (2k * num_modules)

### Optimization Opportunities:
- Cache frequently-accessed APY values
- Use events for module changes (reduce storage)
- Lazy-load module info (query on-demand)

---

## Success Criteria

### Functional Requirements:
- ✅ All interface methods implemented
- ✅ Registry enables module discovery
- ✅ Existing escrows continue working (backward compatible)
- ✅ New features gracefully degrade (don't revert)

### Non-Functional Requirements:
- ✅ Gas costs acceptable (<100k for common operations)
- ✅ Documentation complete
- ✅ Test coverage >90%
- ✅ Security review passed

---

## Estimated Timeline

| Phase | Duration | Dependencies |
|-------|----------|--------------|
| Phase 1: Interface Enhancement | 1 week | None |
| Phase 2: Module Registry | 1 week | Phase 1 complete |
| Phase 3: Integration & Testing | 1 week | Phase 1 & 2 complete |
| **Total** | **3 weeks** | |

**Note**: Timeline assumes single developer, may vary based on complexity of existing modules.

---

## Next Steps

1. **Review & Approve Design**: Review this plan, answer open questions
2. **Create GitHub Issues**: Break down into trackable tasks
3. **Start Phase 1**: Begin interface enhancement
4. **Iterate**: Review progress weekly, adjust as needed

---

**Document Status**: 📋 **READY FOR IMPLEMENTATION**

**Last Updated**: 2026-01-27  
**Author**: Development Planning (for LLM implementation)
