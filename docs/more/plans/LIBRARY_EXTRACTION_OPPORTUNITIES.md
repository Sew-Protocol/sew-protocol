# Library Extraction Opportunities for EscrowVault

## Current Status
- **Already Extracted**: ModuleGetterLibrary (~1,200 bytes saved)
- **Remaining Size**: 27.26 KB (need ~2,684 bytes)

## Available Library Extractions

### 1. FeeRecordingLibrary (~200 bytes) ⚠️ HIGH PRIORITY
**Function**: `_recordFee(address token, uint256 amount)`

**Current Code**:
```solidity
function _recordFee(address token, uint256 amount) internal override {
    // MED-4: Prevent overflow when accumulating fees
    // currentFees is the current total accumulated fees for this token before adding the new fee
    uint256 currentFees = totalFeesPerToken[token];
    if (amount > type(uint256).max - currentFees) {
        revert FeeOverflow();
    }
    totalFeesPerToken[token] = currentFees + amount;
}
```

**Library Implementation**:
```solidity
library FeeRecordingLibrary {
    function recordFee(
        mapping(address => uint256) storage totalFeesPerToken,
        address token,
        uint256 amount
    ) internal {
        uint256 currentFees = totalFeesPerToken[token];
        if (amount > type(uint256).max - currentFees) revert FeeOverflow();
        totalFeesPerToken[token] = currentFees + amount;
    }
}
```

**EscrowVault Usage**:
```solidity
function _recordFee(address token, uint256 amount) internal override {
    FeeRecordingLibrary.recordFee(totalFeesPerToken, token, amount);
}
```

**Savings**: ~200 bytes  
**Risk**: Low (pure logic extraction)

---

### 2. BalanceUpdateLibrary (~200 bytes) ⚠️ HIGH PRIORITY
**Function**: `_updateEscrowBalance(address token, uint256 amount, bool add)`

**Current Code**:
```solidity
function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
    // MED-3: Input validation (use compact error)
    if (token == address(0)) revert ZeroAddress(0);
    
    if (add) {
        totalHeldInEscrowPerToken[token] += amount;
    } else {
        // CRIT-1: Prevent underflow that could break accounting
        if (totalHeldInEscrowPerToken[token] < amount) {
            revert BalanceUnderflow(token, totalHeldInEscrowPerToken[token], amount);
        }
        totalHeldInEscrowPerToken[token] -= amount;
    }
}
```

**Library Implementation**:
```solidity
library BalanceUpdateLibrary {
    function updateBalance(
        mapping(address => uint256) storage totalHeldInEscrowPerToken,
        address token,
        uint256 amount,
        bool add
    ) internal {
        if (token == address(0)) revert ZeroAddress(0);
        if (add) {
            totalHeldInEscrowPerToken[token] += amount;
        } else {
            if (totalHeldInEscrowPerToken[token] < amount) {
                revert BalanceUnderflow(token, totalHeldInEscrowPerToken[token], amount);
            }
            totalHeldInEscrowPerToken[token] -= amount;
        }
    }
}
```

**EscrowVault Usage**:
```solidity
function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
    BalanceUpdateLibrary.updateBalance(totalHeldInEscrowPerToken, token, amount, add);
}
```

**Savings**: ~200 bytes  
**Risk**: Low (pure logic extraction)

---

### 3. TokenTransferLibrary (~150 bytes) ⚠️ MEDIUM PRIORITY
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

**EscrowVault Usage**:
```solidity
function _pullTokens(address token, address from, uint256 amount) internal override {
    TokenTransferLibrary.pullTokens(token, from, amount);
}
function _transferTokens(address token, address to, uint256 amount) internal override {
    TokenTransferLibrary.transferTokens(token, to, amount);
}
```

**Savings**: ~150 bytes (both functions)  
**Risk**: Low (simple wrapper extraction)  
**Note**: May not save much if library overhead exceeds function size

---

### 4. FeeWithdrawalLibrary (~200 bytes) ⚠️ MEDIUM PRIORITY
**Function**: `withdrawFees(address token)`

**Current Code**:
```solidity
function withdrawFees(address token) external onlyRole(ROLE_FEE_RECIPIENT) nonReentrant returns (bool) {
    uint256 feeAmount = totalFeesPerToken[token];
    if (feeAmount == 0) revert NoFeesToWithdraw(token, feeAmount);
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance < feeAmount) revert InsufficientContractBalance(token, feeAmount, balance);
    IERC20(token).safeTransfer(escrowFeeAddress, feeAmount);
    totalFeesPerToken[token] = 0;
    emit FeesWithdrawn(token, feeAmount);
    return true;
}
```

**Library Implementation**:
```solidity
library FeeWithdrawalLibrary {
    using SafeERC20 for IERC20;
    
    function withdrawFees(
        mapping(address => uint256) storage totalFeesPerToken,
        address token,
        address feeRecipient
    ) internal returns (uint256 feeAmount) {
        feeAmount = totalFeesPerToken[token];
        if (feeAmount == 0) revert NoFeesToWithdraw(token, feeAmount);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < feeAmount) revert InsufficientContractBalance(token, feeAmount, balance);
        IERC20(token).safeTransfer(feeRecipient, feeAmount);
        totalFeesPerToken[token] = 0;
    }
}
```

**EscrowVault Usage**:
```solidity
function withdrawFees(address token) external onlyRole(ROLE_FEE_RECIPIENT) nonReentrant returns (bool) {
    uint256 feeAmount = FeeWithdrawalLibrary.withdrawFees(totalFeesPerToken, token, escrowFeeAddress);
    emit FeesWithdrawn(token, feeAmount);
    return true;
}
```

**Savings**: ~200 bytes  
**Risk**: Medium (requires event emission in contract)

---

### 5. RecoveryLibrary (Already Exists) ⚠️ LOW PRIORITY
**Function**: `recoverERC20(address token, address recipient, uint256 amount)`

**Current Code**: Already simplified, but could use existing RecoveryLibrary more

**Note**: BaseEscrow already has a `recoverERC20` that uses RecoveryLibrary, but EscrowVault overrides it for accounting checks.

**Savings**: ~100 bytes (if we can reuse more from RecoveryLibrary)  
**Risk**: Medium (accounting logic must stay)

---

### 6. ModuleGetterConsolidationLibrary (~250 bytes) ⚠️ MEDIUM PRIORITY
**Functions**: `_getReleaseStrategy`, `_getResolutionModule`, `_getYieldGenerationModule`, `_getYieldDistributionModule`

**Current Code**:
```solidity
function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
    return IReleaseStrategy(_getModuleAddress(workflowId, ModuleType.RELEASE));
}
function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
    address moduleAddr = _getModuleAddress(workflowId, ModuleType.RESOLUTION);
    if (moduleAddr != address(0)) {
        return IResolutionModule(moduleAddr);
    }
    return IResolutionModule(disputeResolutionModule);
}
// ... similar for YIELD_GEN and YIELD_DIST
```

**Library Implementation**:
```solidity
library ModuleGetterConsolidationLibrary {
    function getReleaseStrategy(address moduleAddr) internal pure returns (IReleaseStrategy) {
        return IReleaseStrategy(moduleAddr);
    }
    function getResolutionModule(address moduleAddr, address fallbackModule) internal pure returns (IResolutionModule) {
        return IResolutionModule(moduleAddr != address(0) ? moduleAddr : fallbackModule);
    }
    function getYieldGenerationModule(address moduleAddr) internal pure returns (IYieldGenerationModule) {
        return IYieldGenerationModule(moduleAddr);
    }
    function getYieldDistributionModule(address moduleAddr) internal pure returns (IYieldDistributionModule) {
        return IYieldDistributionModule(moduleAddr);
    }
}
```

**EscrowVault Usage**:
```solidity
function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
    return ModuleGetterConsolidationLibrary.getReleaseStrategy(_getModuleAddress(workflowId, ModuleType.RELEASE));
}
function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
    return ModuleGetterConsolidationLibrary.getResolutionModule(
        _getModuleAddress(workflowId, ModuleType.RESOLUTION),
        disputeResolutionModule
    );
}
// ... similar for others
```

**Savings**: ~250 bytes  
**Risk**: Low (type casting optimization)

---

## Summary of Library Extraction Opportunities

| Library | Functions | Estimated Savings | Risk | Priority |
|---------|-----------|------------------|------|----------|
| FeeRecordingLibrary | `_recordFee` | ~200 bytes | Low | HIGH |
| BalanceUpdateLibrary | `_updateEscrowBalance` | ~200 bytes | Low | HIGH |
| FeeWithdrawalLibrary | `withdrawFees` | ~200 bytes | Medium | MEDIUM |
| ModuleGetterConsolidationLibrary | 4 getter functions | ~250 bytes | Low | MEDIUM |
| TokenTransferLibrary | `_pullTokens`, `_transferTokens` | ~150 bytes | Low | MEDIUM |
| RecoveryLibrary (enhance) | `recoverERC20` | ~100 bytes | Medium | LOW |

**Total Potential Savings**: ~1,100 bytes

## Implementation Priority

### Phase 1: High-Impact, Low-Risk (~400 bytes)
1. ✅ FeeRecordingLibrary
2. ✅ BalanceUpdateLibrary

### Phase 2: Medium-Impact (~450 bytes)
3. ✅ ModuleGetterConsolidationLibrary
4. ✅ FeeWithdrawalLibrary

### Phase 3: Lower-Impact (~250 bytes)
5. ✅ TokenTransferLibrary
6. ✅ RecoveryLibrary enhancement

## Notes

### Functions That CANNOT Be Extracted
- **Empty override functions** (`_emitEscrowTransferCreated`, etc.) - Must stay for BaseEscrow compatibility
- **Constructor** - Must stay in contract
- **Public functions with modifiers** (`releaseEscrowTransfer`, `withdrawFees`, `recoverERC20`) - Modifiers must stay, but logic can be extracted
- **Functions requiring `this` context** - Any function that needs `address(this)`

### Library Overhead Considerations
- Each library adds some overhead (import, using statement)
- Small functions may not benefit from extraction if library overhead exceeds function size
- Test each extraction to verify actual savings

### Storage Access Pattern
- Libraries can access storage via `storage` keyword
- Pass storage mappings as `mapping(address => uint256) storage` parameters
- This allows libraries to modify contract storage directly

---

**Status**: Ready for Implementation  
**Estimated Total Savings**: ~1,100 bytes  
**Combined with other optimizations**: Should get close to 24KB target
