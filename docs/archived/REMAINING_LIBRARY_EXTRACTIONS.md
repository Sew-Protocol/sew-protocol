# Remaining Library Extraction Opportunities

## Already Extracted ✅
1. ✅ FeeRecordingLibrary (~200 bytes)
2. ✅ BalanceUpdateLibrary (~200 bytes)
3. ✅ ModuleGetterConsolidationLibrary (~250 bytes)
4. ✅ FeeWithdrawalLibrary (~200 bytes)

## Remaining Opportunities

### 1. TokenRecoveryLibrary (~150-200 bytes) ⚠️ MEDIUM PRIORITY
**Function**: `recoverERC20(address token, address recipient, uint256 amount)`

**Current Code**:
```solidity
function recoverERC20(address token, address recipient, uint256 amount) external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 protected = totalHeldInEscrowPerToken[token] + totalFeesPerToken[token];
    uint256 available = balance > protected ? balance - protected : 0;
    uint256 recoveryAmount = amount == 0 ? available : amount;
    if (recoveryAmount == 0 || recoveryAmount > available) revert AmountExceedsAvailable(token, recoveryAmount, available);
    IERC20(token).safeTransfer(recipient, recoveryAmount);
    emit ERC20Recovered(token, recipient, recoveryAmount);
    return true;
}
```

**Library Implementation**:
```solidity
library TokenRecoveryLibrary {
    using SafeERC20 for IERC20;
    
    function recoverERC20(
        mapping(address => uint256) storage totalHeldInEscrowPerToken,
        mapping(address => uint256) storage totalFeesPerToken,
        address token,
        address recipient,
        uint256 amount
    ) internal returns (uint256 recoveryAmount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 protected = totalHeldInEscrowPerToken[token] + totalFeesPerToken[token];
        uint256 available = balance > protected ? balance - protected : 0;
        recoveryAmount = amount == 0 ? available : amount;
        if (recoveryAmount == 0 || recoveryAmount > available) revert AmountExceedsAvailable(token, recoveryAmount, available);
        IERC20(token).safeTransfer(recipient, recoveryAmount);
    }
}
```

**EscrowVault Usage**:
```solidity
function recoverERC20(address token, address recipient, uint256 amount) external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
    uint256 recoveryAmount = TokenRecoveryLibrary.recoverERC20(totalHeldInEscrowPerToken, totalFeesPerToken, token, recipient, amount);
    emit ERC20Recovered(token, recipient, recoveryAmount);
    return true;
}
```

**Savings**: ~150-200 bytes  
**Risk**: Low (pure logic extraction)  
**Note**: Event emission must stay in contract

---

### 2. TokenTransferLibrary (~100-150 bytes) ⚠️ LOW PRIORITY
**Functions**: `_pullTokens`, `_transferTokens`

**Current Code**:
```solidity
function _pullTokens(address token, address from, uint256 amount) internal override {
    IERC20(token).safeTransferFrom(from, address(this), amount);
}
function _transferTokens(address token, address to, uint256 amount) internal override {
    IERC20(token).safeTransfer(to, amount);
}
```

**Library Implementation**:
```solidity
library TokenTransferLibrary {
    using SafeERC20 for IERC20;
    
    function pullTokens(address token, address from, uint256 amount) internal {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }
    
    function transferTokens(address token, address to, uint256 amount) internal {
        IERC20(token).safeTransfer(to, amount);
    }
}
```

**Savings**: ~100-150 bytes (both functions)  
**Risk**: Low  
**Note**: Very small functions - library overhead may offset savings. Test to verify.

---

### 3. ModuleWrapperLibrary (~50-100 bytes) ⚠️ LOW PRIORITY
**Functions**: `queueModule`, `activateModule`, `_getDefaultYieldGenerationModule`

**Current Code**:
```solidity
function queueModule(BaseEscrow.ModuleType moduleType, address newModule) external onlyRole(ROLE_TIMELOCK) {
    moduleManagement.queueModule(address(this), moduleType, newModule);
}
function activateModule(BaseEscrow.ModuleType moduleType) external onlyRole(ROLE_TIMELOCK) {
    moduleManagement.activateModule(address(this), moduleType);
}
function _getDefaultYieldGenerationModule() internal view override returns (IYieldGenerationModule module) {
    return IYieldGenerationModule(moduleManagement.getModule(address(this), ModuleType.YIELD_GEN));
}
```

**Library Implementation**:
```solidity
library ModuleWrapperLibrary {
    function queueModule(ModuleManagementContract moduleManagement, address escrowContract, BaseEscrow.ModuleType moduleType, address newModule) internal {
        moduleManagement.queueModule(escrowContract, moduleType, newModule);
    }
    
    function activateModule(ModuleManagementContract moduleManagement, address escrowContract, BaseEscrow.ModuleType moduleType) internal {
        moduleManagement.activateModule(escrowContract, moduleType);
    }
    
    function getDefaultYieldGenerationModule(ModuleManagementContract moduleManagement, address escrowContract) internal view returns (IYieldGenerationModule) {
        return IYieldGenerationModule(moduleManagement.getModule(escrowContract, ModuleType.YIELD_GEN));
    }
}
```

**Savings**: ~50-100 bytes  
**Risk**: Low  
**Note**: Very small wrappers - may not be worth the complexity

---

## Functions That CANNOT Be Extracted

### 1. `releaseEscrowTransfer`
- **Reason**: Has modifiers (`nonReentrant`, `whenNotPaused`) that must stay in contract
- **Reason**: Calls BaseEscrow internal function `_releaseEscrowTransfer`
- **Reason**: Returns `bool` required by interface

### 2. Empty Override Functions
- `_emitEscrowTransferCreated`
- `_emitEscrowTransferCancelled`
- `_emitEscrowTransferReleased`
- **Reason**: Required by BaseEscrow virtual functions, must exist in contract

### 3. `_depositForYield`
- **Reason**: Very simple (one line), library overhead would exceed savings
- **Reason**: Direct module call, no complex logic

### 4. Constructor
- **Reason**: Must stay in contract for initialization

---

## Summary

| Library | Functions | Estimated Savings | Risk | Priority | Recommendation |
|---------|-----------|------------------|------|----------|----------------|
| TokenRecoveryLibrary | `recoverERC20` | ~150-200 bytes | Low | MEDIUM | ✅ **Recommended** |
| TokenTransferLibrary | `_pullTokens`, `_transferTokens` | ~100-150 bytes | Low | LOW | ⚠️ Test first (may not save) |
| ModuleWrapperLibrary | `queueModule`, `activateModule`, `_getDefaultYieldGenerationModule` | ~50-100 bytes | Low | LOW | ❌ Not recommended (too small) |

## Total Remaining Potential Savings

- **TokenRecoveryLibrary**: ~150-200 bytes
- **TokenTransferLibrary**: ~100-150 bytes (if beneficial)
- **Total**: ~250-350 bytes

## Recommendation

1. ✅ **Implement TokenRecoveryLibrary** (~150-200 bytes) - Good savings, low risk
2. ⚠️ **Test TokenTransferLibrary** - May not save due to library overhead
3. ❌ **Skip ModuleWrapperLibrary** - Too small, not worth complexity

---

**Status**: Analysis Complete  
**Next**: Implement TokenRecoveryLibrary if still over 24KB
