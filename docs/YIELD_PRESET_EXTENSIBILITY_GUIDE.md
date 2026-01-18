# Yield Preset Extensibility Guide

**Date:** 2026-01-28  
**Purpose:** Step-by-step guide for adding new yield presets

---

## Overview

This guide demonstrates how to add new yield presets to the system. As an example, we'll add `YIELD_BOTH` - a preset where both sender and recipient share yield equally (50/50).

---

## Current Preset System

### **Initial Presets (v1.0 - Launch)**

```solidity
// contracts/types/YieldPresets.sol
enum YieldPreset {
    OFF,           // No yield (default)
    TO_SENDER      // Yield goes to sender (buyer) - 100%
}
```

### **Preset Derivation Logic**

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

## Adding New Presets: Step-by-Step

### **Example: YIELD_BOTH (50/50 Split)**

**Goal:** Add a preset where both sender and recipient share yield equally.

---

### **Step 1: Add Enum Value** 🔴 **REQUIRED**

**File:** `contracts/types/YieldPresets.sol`

```solidity
enum YieldPreset {
    OFF,           // No yield (default)
    TO_SENDER,     // Yield goes to sender (buyer) - 100%
    YIELD_BOTH     // Yield shared between sender and recipient - 50/50
}
```

**Considerations:**
- ✅ Enum values are backward compatible (existing values unchanged)
- ✅ New enum value can be added at any position
- ⚠️ Cannot remove enum values (breaks backward compatibility)
- ⚠️ Cannot reorder enum values (breaks encoding)

---

### **Step 2: Update Derivation Function** 🔴 **REQUIRED**

**File:** `contracts/libraries/YieldPresetLibrary.sol`

**Challenge:** `deriveDistributionData()` currently only receives `sender` address. For `YIELD_BOTH`, we need both `sender` and `recipient`.

**Solution:** Update function signature to accept recipient address.

```solidity
library YieldPresetLibrary {
    /**
     * @notice Derive distribution data from preset
     * @param preset The yield preset enum value
     * @param sender The sender address (buyer)
     * @param recipient The recipient address (seller)
     * @return distributionData Encoded (address[] recipients, uint256[] percentages)
     */
    function deriveDistributionData(
        YieldPreset preset,
        address sender,
        address recipient
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
        
        if (preset == YieldPreset.YIELD_BOTH) {
            // Deterministic: 50% to sender, 50% to recipient
            address[] memory recipients = new address[](2);
            uint256[] memory percentages = new uint256[](2);
            
            recipients[0] = sender;
            percentages[0] = 5000; // 50%
            
            recipients[1] = recipient;
            percentages[1] = 5000; // 50%
            
            return abi.encode(recipients, percentages);
        }
        
        revert InvalidYieldPreset();
    }
    
    /**
     * @notice Check if yield is enabled for preset
     * @param preset The yield preset enum value
     * @return enabled True if yield should be enabled
     */
    function isYieldEnabled(YieldPreset preset) internal pure returns (bool) {
        return preset != YieldPreset.OFF;
    }
    
    /**
     * @notice Validate preset parameters
     * @param preset The yield preset enum value
     * @param sender The sender address
     * @param recipient The recipient address
     * @dev Reverts if preset requires addresses that are invalid
     */
    function validatePresetParams(
        YieldPreset preset,
        address sender,
        address recipient
    ) internal pure {
        if (preset == YieldPreset.YIELD_BOTH) {
            if (sender == address(0)) revert InvalidAddress('Sender cannot be zero', sender);
            if (recipient == address(0)) revert InvalidAddress('Recipient cannot be zero', recipient);
            if (sender == recipient) revert InvalidAddress('Sender and recipient must be different', sender);
        }
        
        // TO_SENDER only needs sender (already validated in createEscrow)
        // OFF needs no addresses
    }
}
```

**Key Changes:**
- ✅ Function signature: `deriveDistributionData(preset, sender, recipient)`
- ✅ Added `YIELD_BOTH` case: 2 recipients, 50/50 split
- ✅ Added `validatePresetParams()` helper for address validation
- ⚠️ **Breaking Change:** Function signature changed (requires updating callers)

---

### **Step 3: Update Caller (BaseEscrow.createEscrow)** 🔴 **REQUIRED**

**File:** `contracts/core/BaseEscrow.sol`

```solidity
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public nonReentrant whenNotPaused returns (uint256) {
    // ... existing validation ...
    
    // Get sender address (buyer)
    address sender = _msgSender();
    
    // Validate preset parameters
    YieldPresetLibrary.validatePresetParams(settings.yieldPreset, sender, to);
    
    // Derive distribution data from preset (now includes recipient)
    bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(
        settings.yieldPreset,
        sender,      // buyer
        to           // seller (recipient)
    );
    
    // ... rest of creation logic ...
}
```

**Key Changes:**
- ✅ Pass `to` (recipient) to `deriveDistributionData()`
- ✅ Call `validatePresetParams()` before derivation
- ✅ No changes to other logic needed

---

### **Step 4: Update Tests** 🔴 **REQUIRED**

**File:** `test/foundry/core/YieldPreset.t.sol` (new test file)

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import 'forge-std/Test.sol';
import '../../contracts/libraries/YieldPresetLibrary.sol';
import '../../contracts/types/YieldPresets.sol';

contract YieldPresetTest is Test {
    address constant SENDER = address(0x1);
    address constant RECIPIENT = address(0x2);
    
    function test_YIELD_BOTH_Distribution() public {
        bytes memory data = YieldPresetLibrary.deriveDistributionData(
            YieldPreset.YIELD_BOTH,
            SENDER,
            RECIPIENT
        );
        
        (address[] memory recipients, uint256[] memory percentages) = abi.decode(
            data,
            (address[], uint256[])
        );
        
        assertEq(recipients.length, 2);
        assertEq(recipients[0], SENDER);
        assertEq(recipients[1], RECIPIENT);
        assertEq(percentages[0], 5000); // 50%
        assertEq(percentages[1], 5000); // 50%
    }
    
    function test_YIELD_BOTH_Validation() public {
        // Valid: different addresses
        YieldPresetLibrary.validatePresetParams(
            YieldPreset.YIELD_BOTH,
            SENDER,
            RECIPIENT
        );
        
        // Invalid: zero sender
        vm.expectRevert();
        YieldPresetLibrary.validatePresetParams(
            YieldPreset.YIELD_BOTH,
            address(0),
            RECIPIENT
        );
        
        // Invalid: zero recipient
        vm.expectRevert();
        YieldPresetLibrary.validatePresetParams(
            YieldPreset.YIELD_BOTH,
            SENDER,
            address(0)
        );
        
        // Invalid: same address
        vm.expectRevert();
        YieldPresetLibrary.validatePresetParams(
            YieldPreset.YIELD_BOTH,
            SENDER,
            SENDER
        );
    }
    
    function test_YIELD_BOTH_Integration() public {
        // Integration test: create escrow with YIELD_BOTH preset
        // ... full escrow creation flow ...
    }
}
```

---

### **Step 5: Update Documentation** 🟡 **IMPORTANT**

**File:** `docs/governance/YIELD_PRESETS.md` (new documentation)

```markdown
# Yield Presets

## Available Presets

### OFF
- **Description:** No yield generation
- **Distribution:** None
- **Use Case:** Standard escrow without yield

### TO_SENDER
- **Description:** All yield goes to sender (buyer)
- **Distribution:** 100% to sender
- **Use Case:** Buyer receives all yield benefits

### YIELD_BOTH
- **Description:** Yield shared equally between sender and recipient
- **Distribution:** 50% to sender, 50% to recipient
- **Use Case:** Fair sharing of yield benefits between parties
```

---

## Design Patterns for Future Presets

### **Pattern 1: Single Recipient (100% to one party)**

```solidity
if (preset == YieldPreset.TO_SENDER) {
    address[] memory recipients = new address[](1);
    uint256[] memory percentages = new uint256[](1);
    recipients[0] = sender;
    percentages[0] = 10000; // 100%
    return abi.encode(recipients, percentages);
}
```

**Examples:**
- `TO_SENDER` - 100% to sender
- `TO_RECIPIENT` - 100% to recipient
- `TO_REFERRER` - 100% to referrer (if referrer system added)

---

### **Pattern 2: Split Between Two Parties**

```solidity
if (preset == YieldPreset.YIELD_BOTH) {
    address[] memory recipients = new address[](2);
    uint256[] memory percentages = new uint256[](2);
    recipients[0] = sender;
    percentages[0] = 5000; // 50%
    recipients[1] = recipient;
    percentages[1] = 5000; // 50%
    return abi.encode(recipients, percentages);
}
```

**Examples:**
- `YIELD_BOTH` - 50/50 split
- `YIELD_SENDER_MAJOR` - 70% sender, 30% recipient
- `YIELD_RECIPIENT_MAJOR` - 30% sender, 70% recipient

---

### **Pattern 3: Custom Split (Configurable Percentages)**

**Note:** For launch, avoid configurable percentages. Keep it simple with fixed splits.

**Future v2.1+ Pattern:**
```solidity
// Not recommended for v1.0 - adds complexity
if (preset == YieldPreset.CUSTOM_SPLIT) {
    // Would require additional parameters or encoding
    // Better handled as custom EscrowSettings.yieldDistribution
}
```

**Recommendation:** Use fixed presets for v1.0. Custom splits can be added later if needed.

---

### **Pattern 4: Three or More Recipients**

```solidity
if (preset == YieldPreset.YIELD_THREE_WAY) {
    address[] memory recipients = new address[](3);
    uint256[] memory percentages = new uint256[](3);
    recipients[0] = sender;
    percentages[0] = 3333; // 33.33%
    recipients[1] = recipient;
    percentages[1] = 3333; // 33.33%
    recipients[2] = protocolFeeAddress;
    percentages[2] = 3334; // 33.34% (to sum to 10000)
    return abi.encode(recipients, percentages);
}
```

**Note:** Ensure percentages sum to exactly 10000 (100% in basis points).

---

## Validation Checklist

When adding a new preset, ensure:

- [ ] **Enum value added** to `YieldPreset` enum
- [ ] **Derivation logic** implemented in `deriveDistributionData()`
- [ ] **Validation logic** added to `validatePresetParams()` (if needed)
- [ ] **Function signature** updated if recipient address needed
- [ ] **Caller updated** (`BaseEscrow.createEscrow()`)
- [ ] **Unit tests** added for derivation logic
- [ ] **Integration tests** added for full flow
- [ ] **Edge case tests** (zero addresses, same addresses, etc.)
- [ ] **Documentation** updated with preset description
- [ ] **Percentages sum to 10000** (100% in basis points)
- [ ] **No zero addresses** in recipients array
- [ ] **Backward compatibility** maintained (existing presets unchanged)

---

## Migration Considerations

### **Backward Compatibility**

✅ **Safe:**
- Adding new enum values
- Adding new preset cases (doesn't affect existing)
- Adding validation (only affects new preset)

⚠️ **Breaking:**
- Changing function signature (affects all callers)
- Changing existing preset distribution logic
- Removing enum values

### **Recommended Approach**

1. **Add enum value** (no breaking change)
2. **Update function signature** (one-time breaking change)
   - Update all callers in same PR
   - Ensure all tests pass
3. **Add new preset case** (no breaking change)
4. **Add tests** (no breaking change)
5. **Deploy** (no breaking change if enum values unchanged)

---

## Example: Complete YIELD_BOTH Implementation

### **1. Enum Addition**

```solidity
// contracts/types/YieldPresets.sol
enum YieldPreset {
    OFF,
    TO_SENDER,
    YIELD_BOTH  // NEW
}
```

### **2. Library Update**

```solidity
// contracts/libraries/YieldPresetLibrary.sol
function deriveDistributionData(
    YieldPreset preset,
    address sender,
    address recipient
) internal pure returns (bytes memory distributionData) {
    if (preset == YieldPreset.OFF) {
        return "";
    }
    
    if (preset == YieldPreset.TO_SENDER) {
        address[] memory recipients = new address[](1);
        uint256[] memory percentages = new uint256[](1);
        recipients[0] = sender;
        percentages[0] = 10000;
        return abi.encode(recipients, percentages);
    }
    
    if (preset == YieldPreset.YIELD_BOTH) {  // NEW
        address[] memory recipients = new address[](2);
        uint256[] memory percentages = new uint256[](2);
        recipients[0] = sender;
        percentages[0] = 5000;
        recipients[1] = recipient;
        percentages[1] = 5000;
        return abi.encode(recipients, percentages);
    }
    
    revert InvalidYieldPreset();
}
```

### **3. Validation Helper**

```solidity
function validatePresetParams(
    YieldPreset preset,
    address sender,
    address recipient
) internal pure {
    if (preset == YieldPreset.YIELD_BOTH) {
        if (sender == address(0)) revert InvalidAddress('Sender cannot be zero', sender);
        if (recipient == address(0)) revert InvalidAddress('Recipient cannot be zero', recipient);
        if (sender == recipient) revert InvalidAddress('Sender and recipient must be different', sender);
    }
}
```

### **4. BaseEscrow Integration**

```solidity
// contracts/core/BaseEscrow.sol - createEscrow()
address sender = _msgSender();

// Validate preset parameters
YieldPresetLibrary.validatePresetParams(settings.yieldPreset, sender, to);

// Derive distribution data
bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(
    settings.yieldPreset,
    sender,      // buyer
    to           // seller
);
```

---

## Future Preset Ideas

### **Potential Presets for Future Versions**

1. **YIELD_BOTH** (50/50) - ✅ Example above
2. **YIELD_SENDER_MAJOR** (70/30) - Sender gets majority
3. **YIELD_RECIPIENT_MAJOR** (30/70) - Recipient gets majority
4. **YIELD_PROTOCOL** (100% to protocol) - Protocol fee
5. **YIELD_SPLIT_THREE** (33/33/34) - Three-way split
6. **YIELD_ESCROW_FEE** (Yield to cover escrow fees) - Reduce fee burden

**Note:** For v1.0, keep it simple with just `OFF` and `TO_SENDER`. Add more presets based on user demand.

---

## Summary

### **Quick Reference: Adding a New Preset**

1. ✅ Add enum value: `YIELD_BOTH` to `YieldPreset` enum
2. ✅ Add derivation case: Implement in `deriveDistributionData()`
3. ✅ Add validation: Implement in `validatePresetParams()` (if needed)
4. ✅ Update caller: Pass `recipient` to `deriveDistributionData()`
5. ✅ Add tests: Unit + integration tests
6. ✅ Update docs: Document new preset

### **Key Principles**

- ✅ **Deterministic:** Preset → distribution data is pure function
- ✅ **Simple:** Fixed splits, no configurable parameters
- ✅ **Validated:** Address validation before derivation
- ✅ **Backward Compatible:** Existing presets unchanged
- ✅ **Well Tested:** Comprehensive test coverage

---

**Status:** ✅ **EXTENSIBILITY DESIGNED** - System supports easy addition of new presets
