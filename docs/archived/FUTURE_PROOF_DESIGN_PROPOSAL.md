# Future-Proof Settings & Configuration Design Proposal

**Date**: 2026-01-27  
**Scope**: Per-escrow settings, yield distribution, fee splitting, extensibility

---

## Current State Analysis

### ✅ Who Gets Yield Currently?

**Answer**: **It depends on configuration, but defaults to fee recipient**

**Current Flow**:
1. Protocol fee deducted first (0-30% of yield)
2. Remaining yield distributed via `IYieldDistributionModule.distributeYield()`
3. `distributionData` parameter is currently **empty** (`''`) in `YieldOps._distributeYieldInternal()`
4. **If `distributionData` is empty**:
   - DefaultYieldDistributionModule returns success with 0 distributed
   - Yield **stays in contract** or goes to fee recipient as fallback

**Problem**: 
- ❌ No default per-escrow yield recipient
- ❌ Yield distribution requires explicit `distributionData` configuration
- ❌ No automatic "buyer gets yield" or "seller gets yield" behavior

**Current Code**:
```solidity
// YieldOps.sol:221 - Always passes empty distributionData
bytes memory distributionData = '';
distModule.distributeYield(workflowId, token, yieldAmount, distributionData);
```

---

## Proposed Future-Proof Design

### Design Principles

1. **Extensibility**: Easy to add new yield generation modules
2. **Flexibility**: Per-escrow configuration without breaking changes
3. **Backward Compatibility**: Existing escrows continue working
4. **Gas Efficiency**: Minimize storage costs for common cases
5. **Type Safety**: Use enums and structs for clarity

---

## Proposed Settings Structure

### Enhanced `EscrowSettings` (v2.0)

```solidity
struct EscrowSettings {
    // ============ Core Settings (v1.0 - Current) ============
    address customResolver;      // Override default resolver
    bool yieldEnabled;           // Opt-in for yield generation
    uint256 autoReleaseTime;     // Custom release time
    uint256 autoCancelTime;      // Custom cancel time
    
    // ============ Fee Configuration (v2.0 - Proposed) ============
    FeeConfiguration feeConfig;  // Fee payer and split configuration
    
    // ============ Yield Configuration (v2.0 - Proposed) ============
    YieldConfiguration yieldConfig; // Yield recipient and distribution
}

enum FeePayer {
    SENDER,      // Buyer/sender pays (current behavior)
    RECIPIENT,   // Seller/recipient pays
    SPLIT        // Split between parties
}

struct FeeConfiguration {
    FeePayer payer;              // Who pays the escrow fee
    uint256 senderPercent;       // If SPLIT: sender's share (basis points, 0-10000)
    uint256 recipientPercent;    // If SPLIT: recipient's share (basis points, 0-10000)
    uint256 customFeeBps;        // 0 = use global, >0 = override per-escrow fee
}

enum YieldRecipient {
    NONE,           // No yield (current if not configured)
    SENDER,         // Buyer/sender gets all yield
    RECIPIENT,      // Seller/recipient gets all yield
    SPLIT,          // Split between parties
    CUSTOM          // Custom distribution (via YieldDistribution)
}

struct YieldConfiguration {
    YieldRecipient recipient;    // Default yield recipient strategy
    uint256 senderPercent;       // If SPLIT: sender's share (basis points)
    uint256 recipientPercent;    // If SPLIT: recipient's share (basis points)
    YieldDistribution custom;    // If CUSTOM: detailed distribution
}

struct YieldDistribution {
    address[] recipients;
    uint256[] percentages;       // Basis points, sum to 10000
    bool isSet;
}
```

---

## Migration Path: v1.0 → v2.0

### Backward Compatibility Strategy

```solidity
// v1.0 EscrowSettings (current)
struct EscrowSettings {
    address customResolver;
    bool yieldEnabled;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
}

// v2.0 EscrowSettings (extended)
struct EscrowSettings {
    // v1.0 fields (unchanged)
    address customResolver;
    bool yieldEnabled;
    uint256 autoReleaseTime;
    uint256 autoCancelTime;
    
    // v2.0 fields (new, with defaults)
    FeeConfiguration feeConfig;
    YieldConfiguration yieldConfig;
}

// Helper function for v1.0 → v2.0 migration
function getEscrowSettingsV2(uint256 workflowId) 
    public view returns (EscrowSettingsV2 memory) {
    EscrowSettingsV1 memory v1 = escrowSettings[workflowId];
    
    return EscrowSettingsV2({
        // Copy v1.0 fields
        customResolver: v1.customResolver,
        yieldEnabled: v1.yieldEnabled,
        autoReleaseTime: v1.autoReleaseTime,
        autoCancelTime: v1.autoCancelTime,
        
        // Default v2.0 fields (backward compatible)
        feeConfig: FeeConfiguration({
            payer: FeePayer.SENDER,  // Current behavior
            senderPercent: 0,
            recipientPercent: 0,
            customFeeBps: 0          // Use global fee
        }),
        yieldConfig: YieldConfiguration({
            recipient: v1.yieldEnabled ? YieldRecipient.SENDER : YieldRecipient.NONE,
            senderPercent: 0,
            recipientPercent: 0,
            custom: YieldDistribution({
                recipients: new address[](0),
                percentages: new uint256[](0),
                isSet: false
            })
        })
    });
}
```

---

## Fee Splitting Implementation

### Fee Payer Logic

```solidity
function _calculateFeeSplit(
    EscrowTransfer storage et,
    FeeConfiguration memory feeConfig,
    uint256 totalFee
) internal view returns (uint256 senderFee, uint256 recipientFee) {
    if (feeConfig.payer == FeePayer.SENDER) {
        return (totalFee, 0);
    } else if (feeConfig.payer == FeePayer.RECIPIENT) {
        return (0, totalFee);
    } else if (feeConfig.payer == FeePayer.SPLIT) {
        require(
            feeConfig.senderPercent + feeConfig.recipientPercent == 10000,
            "Fee split must sum to 100%"
        );
        senderFee = (totalFee * feeConfig.senderPercent) / 10000;
        recipientFee = (totalFee * feeConfig.recipientPercent) / 10000;
        return (senderFee, recipientFee);
    }
    revert("Invalid fee payer configuration");
}

function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public returns (uint256) {
    // ... existing validation ...
    
    // Calculate fee (use custom if set, otherwise global)
    uint256 feeRate = settings.feeConfig.customFeeBps > 0 
        ? settings.feeConfig.customFeeBps 
        : escrowFee;
    
    uint256 totalFee = (amount * feeRate) / ESCROW_FEE_DENOMINATOR;
    
    // Calculate fee split
    (uint256 senderFee, uint256 recipientFee) = _calculateFeeSplit(
        escrowTransfers[workflowId],
        settings.feeConfig,
        totalFee
    );
    
    // Collect fees
    if (senderFee > 0) {
        _pullTokens(token, _msgSender(), senderFee);
        _recordFee(token, senderFee);
    }
    if (recipientFee > 0) {
        // For recipient fee: either pull upfront or escrow and deduct on release
        // Option A: Pull upfront (requires recipient approval)
        // Option B: Escrow recipient fee, deduct on release
        // Recommend Option B for better UX
        _escrowRecipientFee(workflowId, token, recipientFee);
    }
    
    uint256 amountAfterFee = amount - totalFee;
    // ... rest of creation logic ...
}
```

---

## Yield Distribution Implementation

### Yield Recipient Logic

```solidity
function _getYieldDistributionData(
    EscrowTransfer storage et,
    YieldConfiguration memory yieldConfig
) internal view returns (bytes memory distributionData) {
    if (yieldConfig.recipient == YieldRecipient.NONE) {
        return ''; // No yield distribution
    }
    
    if (yieldConfig.recipient == YieldRecipient.SENDER) {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](1);
        recipients[0] = et.from;
        percentages[0] = 10000;
        return abi.encode(recipients, percentages);
    }
    
    if (yieldConfig.recipient == YieldRecipient.RECIPIENT) {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](1);
        recipients[0] = et.to;
        percentages[0] = 10000;
        return abi.encode(recipients, percentages);
    }
    
    if (yieldConfig.recipient == YieldRecipient.SPLIT) {
        require(
            yieldConfig.senderPercent + yieldConfig.recipientPercent == 10000,
            "Yield split must sum to 100%"
        );
        address[] memory recipients = new address[](2);
        uint256[] memory percentages = new uint256[](2);
        recipients[0] = et.from;
        recipients[1] = et.to;
        percentages[0] = yieldConfig.senderPercent;
        percentages[1] = yieldConfig.recipientPercent;
        return abi.encode(recipients, percentages);
    }
    
    if (yieldConfig.recipient == YieldRecipient.CUSTOM) {
        require(yieldConfig.custom.isSet, "Custom distribution not set");
        return abi.encode(yieldConfig.custom.recipients, yieldConfig.custom.percentages);
    }
    
    revert("Invalid yield recipient configuration");
}

// Updated YieldOps integration
function _handleYieldForEscrow(uint256 workflowId) internal {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    EscrowSettings memory settings = escrowSettings[workflowId];
    
    if (!settings.yieldEnabled) return;
    
    // Get distribution data from yield config
    bytes memory distributionData = _getYieldDistributionData(et, settings.yieldConfig);
    
    // Call YieldOps with distribution data
    IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
    IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
    
    YieldOps.YieldResult memory result = yieldOps.handleYield(
        genModule,
        distModule,
        workflowId,
        et.token,
        et.amountAfterFee,
        moduleSnapshots[workflowId].yieldProtocolFeeBps,
        escrowFeeAddress
    );
    
    // Update accounting with actual amount (may include yield)
    _updateEscrowBalance(et.token, result.actualAmount, false);
}
```

---

## Future Yield Generation Modules

### Interface Extensibility

**Current Interface**:
```solidity
interface IYieldGenerationModule {
    function withdrawWithYield(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external returns (
        bool success,
        uint256 actualAmount,
        uint256 yieldGenerated
    );
    
    function isTokenSupported(address token) external view returns (bool);
}
```

**Proposed Enhanced Interface** (v2.0):
```solidity
interface IYieldGenerationModuleV2 is IYieldGenerationModule {
    // Version identifier
    function moduleVersion() external pure returns (string memory);
    
    // Module capabilities
    function supportsFeature(bytes32 feature) external view returns (bool);
    
    // Advanced features
    function getCurrentYield(uint256 workflowId, address token) 
        external view returns (uint256 pendingYield);
    
    function getYieldRate(address token) 
        external view returns (uint256 apyBps); // Annual percentage yield in basis points
    
    // Emergency withdrawal (if module supports)
    function emergencyWithdraw(
        uint256 workflowId,
        address token
    ) external returns (bool success);
}

// Feature flags for module capabilities
bytes32 constant FEATURE_PARTIAL_WITHDRAWAL = keccak256("PARTIAL_WITHDRAWAL");
bytes32 constant FEATURE_YIELD_PREDICTION = keccak256("YIELD_PREDICTION");
bytes32 constant FEATURE_EMERGENCY_WITHDRAW = keccak256("EMERGENCY_WITHDRAW");
```

**Module Registry Pattern**:
```solidity
contract YieldModuleRegistry {
    struct ModuleInfo {
        address module;
        string name;
        string version;
        address[] supportedTokens;
        uint256[] apyBps; // APY for each token
        bool isActive;
    }
    
    mapping(address => ModuleInfo) public modules;
    address[] public moduleList;
    
    event ModuleRegistered(address indexed module, string name, string version);
    event ModuleActivated(address indexed module, bool isActive);
    
    function registerModule(
        address module,
        string memory name,
        string memory version,
        address[] memory supportedTokens,
        uint256[] memory apyBps
    ) external onlyRole(ROLE_TIMELOCK) {
        // Register module with metadata
        modules[module] = ModuleInfo({
            module: module,
            name: name,
            version: version,
            supportedTokens: supportedTokens,
            apyBps: apyBps,
            isActive: true
        });
        moduleList.push(module);
        emit ModuleRegistered(module, name, version);
    }
    
    function getModulesForToken(address token) 
        external view returns (ModuleInfo[] memory availableModules) {
        // Return all active modules that support this token
        // ... implementation ...
    }
}
```

**Benefits**:
- ✅ Easy to add new yield generation modules (Aave, Compound, Curve, etc.)
- ✅ Per-escrow module selection (via `EscrowSettings`)
- ✅ Module versioning and capability detection
- ✅ Discovery mechanism for frontends

---

## Settings Validation Library Enhancement

### Enhanced Validation

```solidity
library SettingsValidationLibrary {
    // Existing validation...
    
    function validateFeeConfiguration(FeeConfiguration memory config) internal pure {
        if (config.customFeeBps > MAX_FEE_BPS) {
            revert OutOfBounds('customFeeBps', config.customFeeBps, 0, MAX_FEE_BPS);
        }
        
        if (config.payer == FeePayer.SPLIT) {
            require(
                config.senderPercent + config.recipientPercent == 10000,
                "Fee split must sum to 100%"
            );
            require(config.senderPercent > 0, "Sender percent must be > 0");
            require(config.recipientPercent > 0, "Recipient percent must be > 0");
        }
    }
    
    function validateYieldConfiguration(
        YieldConfiguration memory config,
        bool yieldEnabled
    ) internal pure {
        if (!yieldEnabled && config.recipient != YieldRecipient.NONE) {
            revert("Yield recipient set but yield not enabled");
        }
        
        if (config.recipient == YieldRecipient.SPLIT) {
            require(
                config.senderPercent + config.recipientPercent == 10000,
                "Yield split must sum to 100%"
            );
        }
        
        if (config.recipient == YieldRecipient.CUSTOM) {
            validateYieldDistribution(config.custom);
        }
    }
}
```

---

## Gas Optimization Strategy

### Storage Optimization

**Option A: Packed Storage** (Recommended)
```solidity
struct EscrowSettings {
    // Pack into single storage slot where possible
    address customResolver;      // 20 bytes
    uint96 autoReleaseTime;      // 12 bytes (sufficient for timestamps)
    uint96 autoCancelTime;       // 12 bytes
    bool yieldEnabled;           // 1 byte
    FeePayer feePayer;           // 1 byte (enum)
    YieldRecipient yieldRecipient; // 1 byte (enum)
    // Total: ~47 bytes (2 storage slots vs. current 3+)
}

// Separate structs for complex configs (stored separately)
mapping(uint256 => FeeSplitConfig) public feeSplitConfigs; // Only if SPLIT
mapping(uint256 => YieldDistribution) public yieldDistributions; // Only if CUSTOM
```

**Option B: Default Values** (Simpler)
```solidity
// Use zero values as defaults (no storage needed for defaults)
// Only store non-default configurations
mapping(uint256 => FeeConfiguration) public customFeeConfigs; // Only if non-default
mapping(uint256 => YieldConfiguration) public customYieldConfigs; // Only if non-default
```

---

## Default Behavior Migration

### Default Yield Recipient

**Proposed Default**: `YieldRecipient.SENDER` (buyer gets yield)

**Rationale**:
- ✅ Most intuitive: Buyer locks funds, should benefit from yield
- ✅ Aligns with DeFi norms (lender gets interest)
- ✅ Can be overridden per-escrow

**Implementation**:
```solidity
function getDefaultYieldConfig() internal view returns (YieldConfiguration memory) {
    return YieldConfiguration({
        recipient: YieldRecipient.SENDER,  // NEW DEFAULT
        senderPercent: 0,
        recipientPercent: 0,
        custom: YieldDistribution({
            recipients: new address[](0),
            percentages: new uint256[](0),
            isSet: false
        })
    });
}
```

---

## Summary: Design Comparison

| Aspect | Current (v1.0) | Proposed (v2.0) | Benefit |
|--------|----------------|-----------------|---------|
| **Fee Payer** | Always sender | Configurable (sender/recipient/split) | ✅ Fairness |
| **Yield Recipient** | Must configure | Defaults to sender, configurable | ✅ Usability |
| **Per-Escrow Fee** | Global only | Can override per-escrow | ✅ Flexibility |
| **Yield Splitting** | Custom only | Simple split options | ✅ Simplicity |
| **Module Extensibility** | Basic interface | Enhanced with capabilities | ✅ Future-proof |
| **Gas Cost** | Low (4 fields) | Medium (extended fields) | ⚠️ Trade-off |
| **Backward Compat** | N/A | ✅ Yes | ✅ Safe migration |

---

## Implementation Roadmap

### Phase 1: Core Settings (v1.0) - Current ✅
- Basic `EscrowSettings`
- Global fees with snapshots
- Per-escrow yield opt-in

### Phase 2: Fee Splitting (v2.0) - Proposed
- Add `FeeConfiguration` to `EscrowSettings`
- Implement fee split logic
- Migration path for existing escrows

### Phase 3: Yield Configuration (v2.0) - Proposed
- Add `YieldConfiguration` to `EscrowSettings`
- Default to sender receiving yield
- Support simple splits

### Phase 4: Enhanced Interfaces (v2.1) - Future
- `IYieldGenerationModuleV2`
- Module registry
- Capability detection

---

## Recommendations

### ✅ **Implement Now (v2.0)**
1. **Default Yield Recipient** → Sender (buyer)
2. **Fee Splitting** → Sender/Recipient/Split options
3. **Yield Splitting** → Simple split option (mirrors fee split)

### 🟡 **Consider for v2.1**
1. **Per-Escrow Fee Override** → Enterprise feature (adds complexity)
2. **Enhanced Module Interface** → When adding new yield modules
3. **Module Registry** → When multiple modules exist

### ⚠️ **Keep Simple for v1.0**
- Current design is acceptable for launch
- Add complexity incrementally based on user demand
- Monitor gas costs as features are added

---

**Status**: 📋 **PROPOSAL** - Ready for review and implementation planning

---

**Review Completed**: 2026-01-27  
**Next Steps**: Review proposal, decide on v2.0 scope, plan implementation timeline
