# Module Registry & Yield Preset Integration Analysis

**Date:** 2026-01-28  
**Purpose:** Validate module registry design and impact on YieldPreset interface

---

## Current State Analysis

### **Module Selection Today**

1. **Default Modules (Per Contract):**
   ```solidity
   // EscrowVault.sol / EscrowableERC20.sol
   IYieldGenerationModule public defaultYieldGenerationModule;
   IYieldDistributionModule public defaultYieldDistributionModule;
   ```

2. **Module Snapshots (Per Escrow):**
   ```solidity
   // BaseEscrow.sol - _snapshotModulesForEscrow()
   moduleSnapshots[workflowId] = ModuleSnapshot({
       yieldGenerationModule: genMod,        // From default or snapshot
       yieldDistributionModule: distMod,     // From default or snapshot
       // ... other modules
   });
   ```

3. **No Registry:**
   - No central allowlist
   - No module validation beyond ERC165 interface checks
   - Modules set directly via `queueDefaultYieldGenerationModule()` / `activate...()`

4. **Module Interfaces:**
   - `IYieldGenerationModule.moduleName()` ✅ Exists
   - `IYieldGenerationModule.moduleVersion()` ✅ Exists
   - `IYieldDistributionModule.moduleName()` ✅ Exists
   - `IYieldDistributionModule.moduleVersion()` ✅ Exists
   - Both extend `IERC165` ✅ Interface detection available

---

## Module Registry Requirements

### **Registry Features (v2.1+)**

```solidity
// Minimum requirements
- Enumerate approved modules by type:
  - YieldGeneration
  - YieldDistribution
  - Resolution (already exists via defaultResolverModule)

- Metadata:
  - name, version, feature flags
  - supported tokens (optional)

- Status:
  - active / deprecated

- Events for indexing:
  - ModuleAdded, ModuleDeprecated
```

### **What to Avoid**

- ❌ Per-token module selection logic on-chain (heavy governance surface)
- ❌ Complex dependency graphs between modules
- ✅ Keep it: simple allowlist + per-module capability flags

---

## Impact on YieldPreset Interface

### **Key Question: Do Presets Need Module Addresses?**

**Answer: NO** - Presets are abstraction layer above modules

#### **YieldPreset Flow:**

```
User selects: YieldPreset.TO_SENDER
    ↓
System derives: distributionData = [sender: 100%]
    ↓
System uses: defaultYieldGenerationModule (from registry)
    ↓
System uses: defaultYieldDistributionModule (from registry)
    ↓
Modules execute: generation + distribution
```

**Key Insight:** Presets don't reference modules directly. They reference **default modules** which are registry-validated.

---

## Proposed Architecture

### **Layer 1: Module Registry** (New)

**Purpose:** Allowlist + metadata for safety

```solidity
// contracts/registry/ModuleRegistry.sol
interface IModuleRegistry {
    enum ModuleType {
        YIELD_GENERATION,
        YIELD_DISTRIBUTION,
        RESOLUTION
    }
    
    enum ModuleStatus {
        ACTIVE,
        DEPRECATED
    }
    
    struct ModuleMetadata {
        string name;
        string version;
        ModuleStatus status;
        uint256 featureFlags; // Bit flags for capabilities
        address[] supportedTokens; // Optional: empty = all tokens
    }
    
    // Functions
    function isApproved(ModuleType moduleType, address module) external view returns (bool);
    function getMetadata(ModuleType moduleType, address module) external view returns (ModuleMetadata memory);
    function addModule(ModuleType moduleType, address module, ModuleMetadata calldata metadata) external;
    function deprecateModule(ModuleType moduleType, address module) external;
    
    // Events
    event ModuleAdded(ModuleType indexed moduleType, address indexed module, string name, string version);
    event ModuleDeprecated(ModuleType indexed moduleType, address indexed module);
}
```

**Access Control:**
- `addModule()` / `deprecateModule()` → `ROLE_TIMELOCK` (governance)

**Validation:**
- Module must implement correct interface (`IERC165`)
- Module must be a contract (code.length > 0)
- Metadata.name/version must match module's `moduleName()` / `moduleVersion()`

---

### **Layer 2: Registry-Enabled Escrow Contracts** (Modified)

**Purpose:** Validate default modules against registry

```solidity
// EscrowVault.sol / EscrowableERC20.sol
IModuleRegistry public moduleRegistry; // NEW

function queueDefaultYieldGenerationModule(address newModule) external onlyRole(ROLE_TIMELOCK) {
    // NEW: Validate against registry
    require(
        moduleRegistry.isApproved(ModuleType.YIELD_GENERATION, newModule),
        'Module not approved in registry'
    );
    
    // Existing queue logic
    _queueAddress(_pendingModules[ModuleType.YIELD_GEN], newModule);
    // ...
}
```

**Deployment:**
- Registry deployed first
- Escrow contracts reference registry address
- Default modules must be in registry before activation

---

### **Layer 3: YieldPreset System** (New, No Registry Dependency)

**Purpose:** User-friendly abstraction for yield configuration

```solidity
// contracts/types/YieldPresets.sol
enum YieldPreset {
    OFF,           // No yield (uses DefaultYieldModule - always approved)
    TO_SENDER      // Yield to sender (uses defaultYieldGenerationModule + defaultYieldDistributionModule)
}

// contracts/libraries/YieldPresetLibrary.sol
library YieldPresetLibrary {
    function deriveDistributionData(
        YieldPreset preset,
        address sender
    ) internal pure returns (bytes memory distributionData) {
        if (preset == YieldPreset.OFF) {
            return ""; // No distribution
        }
        
        if (preset == YieldPreset.TO_SENDER) {
            address[] memory recipients = new address[](1);
            uint256[] memory percentages = new uint256[](1);
            recipients[0] = sender;
            percentages[0] = 10000; // 100%
            
            return abi.encode(recipients, percentages);
        }
        
        revert InvalidYieldPreset();
    }
    
    function isYieldEnabled(YieldPreset preset) internal pure returns (bool) {
        return preset != YieldPreset.OFF;
    }
}
```

**Key Point:** Preset library has **no dependency on registry**. It's pure logic.

---

## Interface Impact Analysis

### **Question 1: Does YieldPreset need registry?**

**Answer: NO**

- ✅ Presets don't reference modules directly
- ✅ Presets use `defaultYieldGenerationModule` / `defaultYieldDistributionModule`
- ✅ Registry validates defaults at **module setting time**, not at escrow creation
- ✅ Preset → distributionData derivation is deterministic (no module lookup needed)

### **Question 2: Does registry impact preset implementation?**

**Answer: INDIRECTLY - Registry validates defaults, presets use defaults**

**Flow:**
```
1. Registry.addModule(YIELD_GENERATION, aaveModule, metadata) ✅
2. EscrowVault.queueDefaultYieldGenerationModule(aaveModule) → checks registry ✅
3. EscrowVault.activateDefaultYieldGenerationModule() → sets default
4. User.createEscrow(YieldPreset.TO_SENDER) → uses default (already validated) ✅
```

**Impact:** 
- ✅ No changes to preset library needed
- ✅ No registry dependency in preset logic
- ✅ Registry ensures defaults are safe before presets use them

### **Question 3: Can we implement presets before registry?**

**Answer: YES, but not recommended for production**

**Without Registry:**
- ✅ Presets work with any default modules
- ⚠️ No validation that defaults are approved
- ⚠️ Risk of unsafe modules being set as defaults

**With Registry:**
- ✅ Presets work with validated default modules
- ✅ Governance enforces module approval before setting defaults
- ✅ Production-ready safety

**Recommendation:** **Implement registry first** (simple), then presets. Registry is smaller and independent.

---

## Implementation Order

### **Option A: Registry First (Recommended)** ✅

**Phase 1: Module Registry**
1. Create `IModuleRegistry` interface
2. Implement `ModuleRegistry` contract
3. Deploy registry
4. Add existing modules to registry

**Phase 2: Registry Integration**
1. Add `moduleRegistry` to EscrowVault/EscrowableERC20
2. Validate default module setting against registry
3. Test module validation flow

**Phase 3: YieldPreset (Registry-Ready)**
1. Implement `YieldPreset` enum
2. Implement `YieldPresetLibrary`
3. Update `EscrowSettings` (remove `yieldEnabled`, `yieldDistribution`)
4. Update `createEscrow` to use presets
5. Presets automatically use registry-validated defaults

**Benefits:**
- ✅ Registry is independent (can test separately)
- ✅ Presets inherit safety from registry
- ✅ Clear separation of concerns
- ✅ Registry useful even without presets

---

### **Option B: Presets First**

**Phase 1: YieldPreset**
1. Implement presets
2. Remove old yield config
3. Test with current module system

**Phase 2: Registry (Later)**
1. Add registry
2. Integrate with default module setting
3. Presets automatically become safer

**Risks:**
- ⚠️ Presets released without module validation
- ⚠️ Need to ensure defaults are safe manually
- ⚠️ Later registry integration may require changes

**Recommendation:** **Option A** - Registry first is safer and cleaner

---

## Module Registry Design

### **Simple Registry Contract**

```solidity
// contracts/registry/ModuleRegistry.sol
contract ModuleRegistry is AccessControl {
    enum ModuleType { YIELD_GENERATION, YIELD_DISTRIBUTION, RESOLUTION }
    enum ModuleStatus { ACTIVE, DEPRECATED }
    
    struct ModuleMetadata {
        string name;
        string version;
        ModuleStatus status;
        uint256 featureFlags;
        address[] supportedTokens; // Empty = all tokens
    }
    
    mapping(ModuleType => mapping(address => ModuleMetadata)) public modules;
    mapping(ModuleType => address[]) public moduleList; // For enumeration
    
    event ModuleAdded(ModuleType indexed moduleType, address indexed module, string name, string version);
    event ModuleDeprecated(ModuleType indexed moduleType, address indexed module);
    
    function isApproved(ModuleType moduleType, address module) external view returns (bool) {
        ModuleMetadata memory meta = modules[moduleType][module];
        return meta.status == ModuleStatus.ACTIVE;
    }
    
    function addModule(
        ModuleType moduleType,
        address module,
        ModuleMetadata calldata metadata
    ) external onlyRole(ROLE_TIMELOCK) {
        require(module.code.length > 0, "Not a contract");
        require(modules[moduleType][module].status == ModuleStatus.DEPRECATED || 
                modules[moduleType][module].name == "", "Already exists");
        
        // Validate interface if applicable
        if (moduleType == ModuleType.YIELD_GENERATION) {
            require(IERC165(module).supportsInterface(type(IYieldGenerationModule).interfaceId), "Invalid interface");
        } else if (moduleType == ModuleType.YIELD_DISTRIBUTION) {
            require(IERC165(module).supportsInterface(type(IYieldDistributionModule).interfaceId), "Invalid interface");
        }
        
        modules[moduleType][module] = metadata;
        if (metadata.status == ModuleStatus.ACTIVE) {
            moduleList[moduleType].push(module);
        }
        
        emit ModuleAdded(moduleType, module, metadata.name, metadata.version);
    }
    
    function deprecateModule(ModuleType moduleType, address module) external onlyRole(ROLE_TIMELOCK) {
        require(modules[moduleType][module].status == ModuleStatus.ACTIVE, "Not active");
        modules[moduleType][module].status = ModuleStatus.DEPRECATED;
        emit ModuleDeprecated(moduleType, module);
    }
    
    function enumerateModules(ModuleType moduleType) external view returns (address[] memory) {
        return moduleList[moduleType];
    }
}
```

**Features:**
- ✅ Simple allowlist (status: ACTIVE/DEPRECATED)
- ✅ Metadata (name, version, feature flags, supported tokens)
- ✅ Events for indexing
- ✅ Interface validation
- ✅ Enumeration support

---

## Integration Points

### **1. Escrow Contract Default Module Setting**

```solidity
// EscrowVault.sol
function queueDefaultYieldGenerationModule(address newModule) external onlyRole(ROLE_TIMELOCK) {
    // NEW: Registry validation
    require(
        moduleRegistry.isApproved(IModuleRegistry.ModuleType.YIELD_GENERATION, newModule),
        'Module not approved in registry'
    );
    
    // Existing logic
    _queueAddress(_pendingModules[ModuleType.YIELD_GEN], newModule);
    // ...
}
```

### **2. Registry Events (For Indexing)**

```solidity
// Indexers listen for:
ModuleAdded(YIELD_GENERATION, aaveModule, "AaveV3", "1.0.0")
ModuleAdded(YIELD_DISTRIBUTION, defaultModule, "Default", "1.0.0")
ModuleDeprecated(YIELD_GENERATION, oldModule)
```

### **3. Preset Usage (No Registry Dependency)**

```solidity
// BaseEscrow.sol - createEscrow()
YieldPreset preset = settings.yieldPreset;

// Derive distribution data (no registry lookup)
bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(preset, _msgSender());

// Use default modules (already validated when set)
IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
// ... rest of logic
```

---

## Summary: Registry Impact on Presets

### **Key Findings:**

1. ✅ **No Direct Impact:** Presets don't depend on registry
2. ✅ **Indirect Safety:** Registry validates defaults before presets use them
3. ✅ **Independent Design:** Registry and presets can be designed separately
4. ✅ **Recommended Order:** Registry first, then presets (safer for production)

### **Interface Changes Required:**

**Registry (New):**
- `IModuleRegistry` interface
- `ModuleRegistry` contract

**Escrow Contracts (Modified):**
- Add `moduleRegistry` storage variable
- Validate default module setting against registry
- No changes to `createEscrow()` or preset logic

**Preset System (New, Registry-Agnostic):**
- `YieldPreset` enum
- `YieldPresetLibrary` (pure functions)
- `EscrowSettings` update (remove `yieldEnabled`, `yieldDistribution`)

### **Conclusion:**

**Registry and Presets are complementary but independent:**

- **Registry:** Validates modules are safe before being used
- **Presets:** Provides user-friendly abstraction over yield configuration
- **Integration:** Registry ensures defaults are safe → Presets use safe defaults

**Recommendation:** ✅ Implement registry first (1-2 days), then presets (3-4 days). Both are needed for launch, but registry provides safety foundation.

---

**Status:** ✅ **VALIDATED** - Registry doesn't impact preset interface. Both can proceed independently.
