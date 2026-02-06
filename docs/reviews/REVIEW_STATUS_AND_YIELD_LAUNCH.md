# Review Status Update & Yield Configuration for Launch

**Date:** 2026-01-28  
**Status:** Review fixes in progress | Yield launch config missing

---

## 📊 Review Status: What's Remaining

### ✅ **COMPLETED FIXES**

1. **Issue 1: Solidity Version Inconsistency** ✅
   - Fixed: All 24 test files updated from `^0.8.19`/`^0.8.28` to `^0.8.33`

2. **Issue 2: Duplicate Deployment Script Numbering** ✅
   - Fixed: Renamed `10_proxy.ts` to `11_proxy.ts`

3. **Issue 3: Inconsistent Constructor Validation** ✅
   - Fixed: Added zero address validation to `EscrowVault` constructor
   - Fixed: Added `MAX_ESCROW_FEE_BPS` constant and validation (200 bps = 2%)

4. **Issue 4: Ownable vs Ownable2Step** ✅
   - Fixed: Changed `SewToken` and `AaveYieldModule` to use `Ownable2Step`

5. **Issue 5: Error Handling Inconsistency** ✅
   - Fixed: Converted all `require()` statements to custom errors in `GovGovernor`

---

### ⏳ **REMAINING MEDIUM PRIORITY ISSUES**

#### Issue 6: Test File Naming
- **Status:** ⏳ **PENDING**
- **Problem:** Mix of `*.t.sol` and `*.test.t.sol`
- **Impact:** Low - Works but inconsistent
- **Fix:** Standardize on `*.t.sol` for Foundry tests
- **Effort:** 🟢 **LOW** (30 minutes)

#### Issue 7: Migrated Test Directory
- **Status:** 📋 **PROPOSED** (Option 1 recommended)
- **Problem:** 23 migrated test files with outdated patterns
- **Impact:** Medium - Maintenance burden
- **Proposed Solution:** Update and integrate tests into domain directories
- **Effort:** 🟡 **MEDIUM** (1-2 days)

#### Issue 8: Module Location Inconsistency
- **Status:** 📋 **PROPOSED** (Option 1 recommended)
- **Problem:** Modules in multiple locations
- **Impact:** Medium - Harder to find modules
- **Proposed Solution:** Domain-based organization with documentation
- **Effort:** 🟢 **LOW** (1 day, mostly documentation)

---

### 🟢 **MINOR ISSUES (Nice to Have)**

1. Import style variation
2. Console logging style
3. Directory naming
4. Interface organization
5. Test setup patterns
6. Configuration validation
7. Documentation organization
8. Code comments
9. Environment variable naming
10. Helper function organization
11. Error naming convention
12. Deployment error handling

**Status:** Can be addressed post-launch

---

## 🚀 Yield Configuration for Launch: What's Missing

### **Launch Requirements (v1.0 - Launch-Safe)**

```
Default: yield off
If yield enabled: yield recipient = sender
Simple YieldConfiguration
Deterministic distributionData derivation
No referrers, no fee routing, no per-escrow fee overrides
User picks from presets, not module addresses
```

---

### **Current State Analysis**

#### ✅ **What Exists:**

1. **Yield Toggle:**
   - `EscrowSettings.yieldEnabled` (boolean) - ✅ Exists
   - Default is `false` when not set - ✅ Correct

2. **Yield Generation Module:**
   - `defaultYieldGenerationModule` - ✅ Exists
   - `DefaultYieldModule` (no-op) - ✅ Exists
   - `AaveYieldGenerationModule` - ✅ Exists

3. **Yield Distribution Module:**
   - `defaultYieldDistributionModule` - ✅ Exists
   - `DefaultYieldDistributionModule` - ✅ Exists

4. **Distribution Data Structure:**
   - `YieldDistribution` struct with `recipients[]` and `percentages[]` - ✅ Exists

#### ❌ **What's Missing:**

1. **❌ Preset System for Yield Configuration**
   - **Current:** Users must pass module addresses directly
   - **Required:** Users pick from presets (e.g., "yield_to_sender", "yield_off")
   - **Missing:** Preset enum/constants and mapping logic

2. **❌ Deterministic Distribution Data Derivation**
   - **Current:** Users manually set `EscrowSettings.yieldDistribution` with recipients/percentages
   - **Required:** Automatically derive `distributionData` from preset + sender address
   - **Missing:** Derivation function that creates distribution data from preset

3. **❌ Default Yield Recipient = Sender**
   - **Current:** Users can set any recipients in `yieldDistribution`
   - **Required:** When yield enabled, automatically set recipient = sender
   - **Missing:** Logic to set sender as recipient when yield enabled

4. **❌ Simplified Yield Configuration**
   - **Current:** Complex `EscrowSettings` struct with `yieldDistribution` sub-struct
   - **Required:** Simple preset selection (e.g., `YieldPreset.OFF`, `YieldPreset.TO_SENDER`)
   - **Missing:** Simplified API that hides complexity

5. **✅ No Per-Escrow Fee Overrides**
   - **Current:** Escrow fee is calculated from global `escrowFee` (line 600 in BaseEscrow.sol)
   - **Required:** No per-escrow fee overrides allowed
   - **Status:** ✅ **VERIFIED** - No per-escrow fee overrides exist

6. **✅ No Referrers**
   - **Current:** No referrer system found in codebase
   - **Required:** No referrer system
   - **Status:** ✅ **VERIFIED** - No referrer system exists

---

### **Implementation Plan**

#### **Phase 1: Define Yield Presets** 🔴 **CRITICAL**

**Create:**
```solidity
// contracts/types/YieldPresets.sol
enum YieldPreset {
    OFF,           // No yield (default)
    TO_SENDER      // Yield goes to sender (buyer)
}
```

**Add to EscrowSettings:**
```solidity
struct EscrowSettings {
    address customResolver;
    YieldPreset yieldPreset;  // NEW: Simple preset instead of complex config
    // ... other fields
    // REMOVE: yieldEnabled, yieldDistribution (replaced by preset)
}
```

---

#### **Phase 2: Deterministic Distribution Data Derivation** 🔴 **CRITICAL**

**Create helper function:**
```solidity
// contracts/libraries/YieldPresetLibrary.sol
library YieldPresetLibrary {
    function deriveDistributionData(
        YieldPreset preset,
        address sender
    ) internal pure returns (bytes memory distributionData) {
        if (preset == YieldPreset.OFF) {
            return ""; // Empty = no distribution
        }
        
        if (preset == YieldPreset.TO_SENDER) {
            // Deterministic: 100% to sender
            address[] memory recipients = new address[](1);
            uint256[] memory percentages = new uint256[](1);
            recipients[0] = sender;
            percentages[0] = 10000; // 100% in basis points
            
            return abi.encode(recipients, percentages);
        }
        
        revert InvalidYieldPreset();
    }
    
    function isYieldEnabled(YieldPreset preset) internal pure returns (bool) {
        return preset != YieldPreset.OFF;
    }
}
```

---

#### **Phase 3: Update Escrow Creation** 🔴 **CRITICAL**

**Modify `createEscrow` function:**
```solidity
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public returns (uint256 workflowId) {
    // ... existing code ...
    
    // NEW: Derive distribution data from preset
    bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(
        settings.yieldPreset,
        _msgSender() // sender
    );
    
    // NEW: Determine if yield should be enabled
    bool yieldEnabled = YieldPresetLibrary.isYieldEnabled(settings.yieldPreset);
    
    // Update settings for backward compatibility (if needed)
    // Or refactor to use preset directly
    
    // ... rest of creation logic ...
}
```

---

#### **Phase 4: Update Default Settings** 🟡 **IMPORTANT**

**Update `getDefaultSettings()`:**
```solidity
function getDefaultSettings() public pure returns (EscrowSettings memory) {
    return EscrowSettings({
        customResolver: address(0),
        yieldPreset: YieldPreset.OFF,  // NEW: Default to OFF
        autoReleaseTime: 0,
        autoCancelTime: 0,
        // Remove yieldDistribution
    });
}
```

---

#### **Phase 5: Remove Complex Configuration** 🟡 **IMPORTANT**

**Remove from EscrowSettings:**
- ❌ `bool yieldEnabled` (replaced by preset)
- ❌ `YieldDistribution yieldDistribution` (replaced by derivation)

**Keep:**
- ✅ `YieldPreset yieldPreset` (simple enum)

---

#### **Phase 6: Verify No Fee Overrides/Referrers** ✅ **COMPLETE**

**Verified:**
- ✅ No per-escrow fee override parameters (fee calculated from global `escrowFee`)
- ✅ No referrer parameters in `createEscrow`
- ✅ No fee routing logic beyond standard escrow fee
- ✅ No changes needed

---

### **Files to Modify**

1. **New Files:**
   - `contracts/types/YieldPresets.sol` - Preset enum
   - `contracts/libraries/YieldPresetLibrary.sol` - Derivation logic

2. **Modified Files:**
   - `contracts/types/EscrowTypes.sol` - Update `EscrowSettings` struct
   - `contracts/core/BaseEscrow.sol` - Update `createEscrow` logic
   - `contracts/libraries/SettingsValidationLibrary.sol` - Update validation
   - `contracts/core/EscrowVault.sol` - Update if needed
   - `contracts/core/EscrowableERC20.sol` - Update if needed

3. **Tests:**
   - Update all tests that use `EscrowSettings`
   - Add tests for preset derivation
   - Add tests for default behavior

---

### **Migration Strategy**

#### **Option 1: Backward Compatible (Recommended for Launch)**

Keep both systems temporarily:
- Add `YieldPreset` to `EscrowSettings`
- Keep `yieldEnabled` and `yieldDistribution` for backward compatibility
- Derive from preset if set, otherwise use old fields
- Mark old fields as deprecated

**Pros:**
- ✅ No breaking changes
- ✅ Gradual migration
- ✅ Safe for launch

**Cons:**
- ⚠️ More complex code
- ⚠️ Technical debt

#### **Option 2: Clean Break**

Remove old fields entirely:
- Replace `yieldEnabled` and `yieldDistribution` with `yieldPreset`
- Update all callers immediately

**Pros:**
- ✅ Clean code
- ✅ No technical debt

**Cons:**
- ❌ Breaking changes
- ❌ Requires updating all callers
- ❌ Riskier for launch

**Recommendation:** **Option 1** for launch safety

---

### **Testing Requirements**

1. **Unit Tests:**
   - ✅ Preset derivation (OFF → empty distribution)
   - ✅ Preset derivation (TO_SENDER → 100% to sender)
   - ✅ Default preset is OFF
   - ✅ Invalid preset reverts

2. **Integration Tests:**
   - ✅ Create escrow with preset OFF (no yield)
   - ✅ Create escrow with preset TO_SENDER (yield to sender)
   - ✅ Verify distribution data is correct
   - ✅ Verify yield generation works with preset

3. **Edge Cases:**
   - ✅ Sender is zero address (should revert)
   - ✅ Preset changes after escrow creation (should not affect existing escrows)

---

### **Summary: What's Missing**

| Requirement | Status | Priority |
|------------|--------|----------|
| Preset system | ❌ Missing | 🔴 Critical |
| Deterministic derivation | ❌ Missing | 🔴 Critical |
| Default yield recipient = sender | ❌ Missing | 🔴 Critical |
| Simplified API | ❌ Missing | 🔴 Critical |
| No per-escrow fee overrides | ✅ Verified | ✅ Complete |
| No referrers | ✅ Verified | ✅ Complete |

---

### **Estimated Effort**

- **Phase 1-3 (Core Implementation):** 2-3 days
- **Phase 4-5 (Cleanup):** 1 day
- **Phase 6 (Verification):** ✅ Complete
- **Testing:** 1-2 days
- **Total:** **4-5 days**

---

### **Next Steps**

1. ✅ **Complete:** Verified no fee overrides/referrers exist
2. 🔴 **Critical:** Implement preset system (Phase 1-3)
3. 🟡 **Important:** Update default settings (Phase 4)
4. 🟡 **Important:** Remove complex config (Phase 5)
5. ✅ **Testing:** Comprehensive test coverage

---

**Status:** 🚨 **YIELD CONFIGURATION NOT READY FOR LAUNCH** - Core features missing
