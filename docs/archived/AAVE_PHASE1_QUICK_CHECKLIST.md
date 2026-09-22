# Phase 1 Quick Checklist - BaseEscrow Finalization

**Date:** 2026-01-28  
**Deadline:** Tomorrow (Testnet Deployment)  
**Status:** 🚨 **URGENT**

---

## Critical Changes (Must Complete)

### 1. Storage Variables (BaseEscrow.sol)

```solidity
// Add after line 174 (after YieldOps declaration)
AaveYieldLibrary public aaveYieldLibrary;
bool public aaveYieldLibraryEnabled = false;

// Add after moduleSnapshots mapping (around line 165)
mapping(uint256 => mapping(address => uint256)) internal escrowATokenBalances;
mapping(uint256 => mapping(address => bool)) internal escrowInYield;
```

### 2. Interface Import (BaseEscrow.sol)

```solidity
// Add after existing imports (around line 28)
import '../libraries/AaveYieldLibrary.sol';

// Add IAToken interface (after imports, before contract)
interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}
```

### 3. Events (BaseEscrow.sol)

```solidity
// Add after existing yield events (around line 291)
event AaveYieldLibrarySet(address indexed oldLibrary, address indexed newLibrary);
event AaveYieldLibraryEnabled(bool enabled);
event YieldDepositAttempted(
    uint256 indexed workflowId,
    address indexed token,
    uint256 amount,
    bool success,
    uint8 reasonCode
);
event YieldWithdrawalAttempted(
    uint256 indexed workflowId,
    address indexed token,
    uint256 amount,
    uint256 actualAmount,
    bool success,
    uint8 reasonCode
);
```

### 4. Errors (BaseEscrow.sol)

```solidity
// Add to existing errors section (around line 100)
error AaveLibraryNotConfigured();
error AavePoolNotConfigured();
```

### 5. Setter Functions (BaseEscrow.sol)

**Add after `setBondCollector` (around line 360):**

```solidity
function setAaveYieldLibrary(address libraryAddress) external onlyRole(ROLE_TIMELOCK) {
    if (libraryAddress != address(0) && libraryAddress.code.length == 0) {
        revert NotAContract(2, libraryAddress);
    }
    address oldLibrary = address(aaveYieldLibrary);
    aaveYieldLibrary = AaveYieldLibrary(libraryAddress);
    emit AaveYieldLibrarySet(oldLibrary, libraryAddress);
}

function setAaveYieldLibraryEnabled(bool enabled) external {
    if (enabled) {
        require(hasRole(ROLE_TIMELOCK, _msgSender()), "Only timelock can enable");
        if (address(aaveYieldLibrary) == address(0)) {
            revert AaveLibraryNotConfigured();
        }
    } else {
        require(
            hasRole(ROLE_TIMELOCK, _msgSender()) || hasRole(ROLE_GUARDIAN, _msgSender()),
            "Only timelock or guardian can disable"
        );
    }
    aaveYieldLibraryEnabled = enabled;
    emit AaveYieldLibraryEnabled(enabled);
}
```

### 6. Helper Functions (BaseEscrow.sol)

**Add before `_handleYieldAndGetActualAmount` (around line 1350):**

```solidity
function _getAavePoolAddress(IYieldGenerationModule genModule) internal view returns (address poolAddress) {
    (bool success, bytes memory data) = address(genModule).staticcall(
        abi.encodeWithSelector(bytes4(keccak256("getAavePoolAddress()")))
    );
    if (success && data.length >= 32) {
        poolAddress = abi.decode(data, (address));
    }
}

function _getATokenAddress(IYieldGenerationModule genModule, address token) internal view returns (address aTokenAddress) {
    (bool success, bytes memory data) = address(genModule).staticcall(
        abi.encodeWithSelector(bytes4(keccak256("getATokenAddress(address)")), token)
    );
    if (success && data.length >= 32) {
        aTokenAddress = abi.decode(data, (address));
    }
}
```

### 7. Library Hook Functions (BaseEscrow.sol)

**Add after helper functions:**

```solidity
function _handleYieldViaLibrary(uint256 workflowId, address token, uint256 amount) internal returns (uint256) {
    // See full implementation plan for complete code
}

function _handleYieldDepositViaLibrary(uint256 workflowId, address token, uint256 amount) internal {
    // See full implementation plan for complete code
}

function _distributeYieldIfNeeded(uint256 workflowId, address token, uint256 actualAmount, uint256 originalAmount) internal {
    // See full implementation plan for complete code
}
```

### 8. Update Existing Functions

**Modify `_handleYieldAndGetActualAmount` (around line 1351):**

Add at start:
```solidity
if (aaveYieldLibraryEnabled && address(aaveYieldLibrary) != address(0)) {
    return _handleYieldViaLibrary(workflowId, token, amount);
}
```

**Modify `createEscrow` yield section (around line 424):**

Replace existing yield deposit with:
```solidity
if (result.yieldEnabled && result.shouldDepositYield) {
    if (aaveYieldLibraryEnabled && address(aaveYieldLibrary) != address(0)) {
        _handleYieldDepositViaLibrary(workflowId, token, result.amountAfterFee);
    } else {
        // Existing YieldOps pattern (unchanged)
        // ... existing code ...
    }
}
```

### 9. Create Library Stub

**File:** `contracts/libraries/AaveYieldLibrary.sol` (NEW)

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

library AaveYieldLibrary {
    using SafeERC20 for IERC20;
    
    function supply(address pool, address token, uint256 amount, address onBehalfOf) external {
        IERC20(token).safeApprove(pool, amount);
        IPool(pool).supply(token, amount, onBehalfOf, 0);
        IERC20(token).safeApprove(pool, 0);
    }
    
    function withdraw(address pool, address token, uint256 amount, address to) external returns (uint256) {
        return IPool(pool).withdraw(token, amount, to);
    }
}
```

### 10. Add Emergency Unwind Function

**File:** `contracts/core/BaseEscrow.sol`

**Add constants (after library storage):**
```solidity
uint256 public constant MAX_UNWIND_AMOUNT_PER_CALL = 1_000_000e18;
uint256 public constant UNWIND_COOLDOWN = 1 hours;
mapping(address => uint256) public lastUnwindTimestamp;
uint256 public totalUnwoundAmount;
```

**Add event:**
```solidity
event EmergencyUnwindExecuted(
    address indexed token,
    uint256 aTokenAmount,
    uint256 underlyingAmount,
    uint256 timestamp,
    address indexed caller,
    uint8 reasonCode
);
```

**Add function (after library setters):**
```solidity
function emergencyUnwindAavePosition(
    address token,
    uint256 maxATokenAmount
) external onlyRole(ROLE_GUARDIAN) whenPaused returns (uint256 underlyingAmount) {
    // See full implementation plan for complete code
    // Key: Funds ALWAYS go to address(this), never to guardian
}
```

### 11. Update Module Interface

**File:** `contracts/interfaces/IYieldGenerationModule.sol`

Add (optional methods):
```solidity
function getAavePoolAddress() external view returns (address poolAddress);
function getATokenAddress(address token) external view returns (address aTokenAddress);
```

### 12. Verify Yield Withdrawal UX

**Verification:**
- ✅ Users call `withdrawEscrow(workflowId)` once
- ✅ Receives principal + yield together
- ✅ No separate yield withdrawal needed
- ✅ Works automatically for both library and YieldOps patterns

**No changes needed** - UX is already excellent! ✅

---

## Testing Checklist

- [ ] Run all existing tests: `forge test`
- [ ] Create test for library setter
- [ ] Create test for library enable/disable
- [ ] Create test for guardian emergency disable
- [ ] **Test emergency unwind:**
  - [ ] Guardian can unwind when paused
  - [ ] Guardian cannot unwind when not paused
  - [ ] Guardian cannot unwind during cooldown
  - [ ] Guardian cannot unwind more than max amount
  - [ ] **CRITICAL: Funds go to BaseEscrow (not guardian)**
  - [ ] Unwind fails gracefully on error
  - [ ] Events emitted with correct reason codes
- [ ] Test that existing YieldOps flow still works
- [ ] Test that library hooks fail gracefully when disabled
- [ ] **Verify yield withdrawal UX** (users get yield automatically)
- [ ] Verify contract size: `pnpm size:check`

---

## Verification Steps

1. **Compile:** `pnpm compile`
2. **Test:** `pnpm test:foundry`
3. **Size:** `pnpm size:check`
4. **Lint:** `pnpm lint`
5. **Typecheck:** `pnpm typecheck`

---

## Critical Notes

- ✅ Library disabled by default (`aaveYieldLibraryEnabled = false`)
- ✅ Existing YieldOps flow unchanged
- ✅ New code only runs when explicitly enabled
- ✅ Guardian can emergency-disable
- ✅ All changes are backward compatible

---

**See full implementation plan for complete code:** `AAVE_LIBRARY_PATTERN_IMPLEMENTATION_PLAN.md`
