# Tasks to Restore EscrowableERC20 to Full Implementation

## Overview
EscrowableERC20 was stripped down to placeholder stubs in commit `e9a546c` ("EscrowVault, EscrowableERC20, under 24KB") for contract size optimization. This document lists tasks needed to restore full functionality.

## Key Differences from EscrowVault

**EscrowableERC20** (single token, uses ERC20 internal `_transfer`):
- Token is always `address(this)` (itself)
- Uses ERC20's `_transfer()` for token movements
- Tracks single `totalHeldInEscrow` (not per-token)
- Tracks single `totalFees` (not per-token)
- Events don't include token parameter (always `address(this)`)

**EscrowVault** (multi-token, uses SafeERC20):
- Token can be any ERC20 address
- Uses `safeTransferFrom()` / `safeTransfer()` for token movements
- Tracks `totalHeldInEscrowPerToken[token]` mapping
- Tracks `totalFeesPerToken[token]` mapping
- Events include token parameter

## Required Tasks

### 1. State Variables ✅ Add
- [ ] `uint256 public constant INITIAL_SUPPLY = 1000000000000000000000000;` (1M tokens)
- [ ] `uint256 public totalHeldInEscrow = 0;` (single token tracking)
- [ ] `uint256 public totalFees = 0;` (single token fee tracking)
- [ ] `IReleaseStrategy public defaultReleaseStrategy;`
- [ ] `IResolutionModule public defaultDisputeResolutionModule;`
- [ ] `IYieldGenerationModule public defaultYieldGenerationModule;`
- [ ] `IYieldDistributionModule public defaultYieldDistributionModule;`
- [ ] Pending module storage (for SlowLaneQueueActivate) - check if BaseEscrow provides this now

### 2. Events ✅ Add
- [ ] `event EscrowTransferCreated(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);` (no token param)
- [ ] `event EscrowTransferReleased(uint256 indexed workflowId, address indexed to, uint256 amount);` (no token param)
- [ ] `event EscrowTransferCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);` (no token param)
- [ ] `event FeesWithdrawn(uint256 amount);` (no token param)
- [ ] Module queue/activate events (if not in BaseEscrow)

### 3. Constructor ✅ Update
- [ ] Mint `INITIAL_SUPPLY` to deployer (using `_mint()`)
- [ ] Verify current constructor already sets required fields

### 4. BaseEscrow Hook Implementations ✅ Implement

#### 4.1 `_pullTokens(address token, address from, uint256 amount)`
**Current**: Empty stub
**Required**: Transfer tokens from `from` to contract using ERC20 `_transfer()`
```solidity
function _pullTokens(address token, address from, uint256 amount) internal override {
    // For EscrowableERC20, token must always be address(this)
    require(token == address(this), "Invalid token");
    // Transfer from sender to contract
    _transfer(from, address(this), amount);
}
```

#### 4.2 `_recordFee(address token, uint256 amount)`
**Current**: Empty stub
**Required**: Track fees in `totalFees` (single token)
```solidity
function _recordFee(address token, uint256 amount) internal override {
    require(token == address(this), "Invalid token");
    // Prevent overflow
    if (totalFees > type(uint256).max - amount) {
        revert InvalidAmount('Fee accumulation would overflow');
    }
    totalFees += amount;
}
```

#### 4.3 `_transferTokens(address token, address to, uint256 amount)`
**Current**: Empty stub
**Required**: Transfer tokens using ERC20 `_transfer()`
```solidity
function _transferTokens(address token, address to, uint256 amount) internal override {
    require(token == address(this), "Invalid token");
    _transfer(address(this), to, amount);
}
```

#### 4.4 `_updateEscrowBalance(address token, uint256 amount, bool add)`
**Current**: Empty stub
**Required**: Update `totalHeldInEscrow` (single token tracking)
```solidity
function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
    require(token == address(this), "Invalid token");
    if (add) {
        totalHeldInEscrow += amount;
    } else {
        require(amount <= totalHeldInEscrow, "Amount exceeds total held");
        totalHeldInEscrow -= amount;
    }
}
```

#### 4.5 `_emitEscrowTransferCreated(uint256 workflowId, address token, address from, address to, uint256 amount)`
**Current**: Empty stub
**Required**: Emit event without token parameter
```solidity
function _emitEscrowTransferCreated(uint256 workflowId, address token, address from, address to, uint256 amount) internal override {
    require(token == address(this), "Invalid token");
    emit EscrowTransferCreated(workflowId, from, to, amount);
}
```

#### 4.6 `_emitEscrowTransferCancelled(uint256 workflowId, address token, address from, uint256 amount)`
**Current**: Empty stub
**Required**: Emit event without token parameter
```solidity
function _emitEscrowTransferCancelled(uint256 workflowId, address token, address from, uint256 amount) internal override {
    require(token == address(this), "Invalid token");
    emit EscrowTransferCancelled(workflowId, from, amount);
}
```

#### 4.7 `_emitEscrowTransferReleased(uint256 workflowId, address token, address to, uint256 amount)`
**Current**: Empty stub
**Required**: Emit event without token parameter
```solidity
function _emitEscrowTransferReleased(uint256 workflowId, address token, address to, uint256 amount) internal override {
    require(token == address(this), "Invalid token");
    emit EscrowTransferReleased(workflowId, to, amount);
}
```

#### 4.8 `_depositForYield(IYieldGenerationModule module, uint256 workflowId, address token, uint256 amount)`
**Current**: Empty stub
**Required**: Delegate to module's `depositForYield()`
```solidity
function _depositForYield(IYieldGenerationModule module, uint256 workflowId, address token, uint256 amount) internal override {
    require(token == address(this), "Invalid token");
    module.depositForYield(workflowId, token, amount);
}
```

### 5. Module Getters ✅ Implement

#### 5.1 `_getReleaseStrategy(uint256 workflowId)`
**Current**: Returns `IReleaseStrategy(address(0))`
**Required**: Return from module snapshot or default
```solidity
function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
    address snapshot = moduleSnapshots[workflowId].releaseStrategy;
    return snapshot != address(0) ? IReleaseStrategy(snapshot) : defaultReleaseStrategy;
}
```

#### 5.2 `_getResolutionModule(uint256 workflowId)`
**Current**: Returns `super._getResolutionModule(id)` (might be OK)
**Required**: Return from module snapshot or default
```solidity
function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
    address snapshot = moduleSnapshots[workflowId].resolutionModule;
    if (snapshot != address(0)) {
        return IResolutionModule(snapshot);
    }
    return address(defaultDisputeResolutionModule) != address(0) 
        ? defaultDisputeResolutionModule 
        : super._getResolutionModule(workflowId);
}
```

#### 5.3 `_getYieldGenerationModule(uint256 workflowId)`
**Current**: Returns `IYieldGenerationModule(address(0))`
**Required**: Return from module snapshot or default
```solidity
function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldGenerationModule) {
    address snapshot = moduleSnapshots[workflowId].yieldGenerationModule;
    return snapshot != address(0) ? IYieldGenerationModule(snapshot) : defaultYieldGenerationModule;
}
```

#### 5.4 `_getYieldDistributionModule(uint256 workflowId)`
**Current**: Returns `IYieldDistributionModule(address(0))`
**Required**: Return from module snapshot or default
```solidity
function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
    address snapshot = moduleSnapshots[workflowId].yieldDistributionModule;
    return snapshot != address(0) ? IYieldDistributionModule(snapshot) : defaultYieldDistributionModule;
}
```

### 6. Public Module Getters ✅ Implement
- [ ] `getReleaseStrategy(uint256 workflowId)` - returns `_getReleaseStrategy(workflowId)`
- [ ] `getResolutionModule(uint256 workflowId)` - returns `_getResolutionModule(workflowId)`
- [ ] `getYieldGenerationModule(uint256 workflowId)` - returns `_getYieldGenerationModule(workflowId)`
- [ ] `getYieldDistributionModule(uint256 workflowId)` - returns `_getYieldDistributionModule(workflowId)`

### 7. Module Management Functions ✅ Implement
Check if BaseEscrow now provides these via `SlowLaneQueueActivate`. If not, implement:
- [ ] `queueDefaultReleaseStrategy(address strategy)` - uses `_queueAddress()`
- [ ] `activateDefaultReleaseStrategy()` - uses `_activateAddress()`
- [ ] `getPendingDefaultReleaseStrategy()` - returns pending info
- [ ] Similar for resolution module, yield generation module, yield distribution module

### 8. Fee Management ✅ Implement
- [ ] `withdrawFees()` - withdraw `totalFees` to `escrowFeeAddress`

### 9. Constructor Overloads (Optional) ✅ Add
- [ ] `createEscrow(address seller, uint256 amount)` - convenience with default settings
- [ ] `createEscrow(address seller, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime)` - convenience with timing

### 10. Critical Notes ⚠️

1. **Token Validation**: All functions that take `address token` must validate `token == address(this)` since EscrowableERC20 only handles its own token.

2. **Balance Tracking**: Use single `totalHeldInEscrow` variable (not per-token mapping like EscrowVault).

3. **Fee Tracking**: Use single `totalFees` variable (not per-token mapping like EscrowVault).

4. **Events**: Events don't include token parameter since token is always `address(this)`.

5. **Module Snapshots**: Check if `moduleSnapshots` mapping is provided by BaseEscrow. If not, may need to store separately.

6. **SlowLaneQueueActivate**: Check if BaseEscrow now inherits this. Old implementation had EscrowableERC20 directly inherit it.

7. **DisputeResolver**: Check `_getDisputeResolverForNewEscrow()` implementation - may need to override to use `defaultDisputeResolutionModule`.

### 11. Testing Requirements ✅
- [ ] Unit tests for all hook implementations
- [ ] Integration tests for escrow creation/release/cancel
- [ ] Module management tests (queue/activate)
- [ ] Fee withdrawal tests
- [ ] Token validation tests (ensure `token == address(this)` requirement)

### 12. Contract Size Consideration ⚠️
- Original implementation was ~650 lines, reduced to ~50 lines for size optimization
- Consider if modular approach (like EscrowVault) can reduce size
- May need to split into library or remove some convenience functions

## Reference Files
- **Old implementation**: `git show e9a546c^:contracts/core/EscrowableERC20.sol`
- **Reference implementation**: `contracts/core/EscrowVault.sol` (similar patterns, different token handling)

## Priority Order
1. **Critical** (for basic functionality): Tasks 4.1-4.8 (BaseEscrow hooks)
2. **High** (for module support): Tasks 5, 6 (Module getters)
3. **Medium** (for governance): Tasks 7 (Module management)
4. **Low** (for completeness): Tasks 1, 2, 3, 8, 9 (State, events, convenience functions)
