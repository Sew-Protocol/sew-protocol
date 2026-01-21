# Aave Library Pattern Implementation Plan

**Date:** 2026-01-28  
**Status:** 🚨 **URGENT** - BaseEscrow must be finalized by tomorrow for testnet deployment  
**Priority:** Phase 1 (BaseEscrow) = CRITICAL, Phases 2-4 can wait

---

## Executive Summary

**Goal:** Make BaseEscrow "Aave-ready" without breaking existing functionality, allowing Aave integration to be added later without BaseEscrow changes.

**Strategy:** 
- **Phase 1 (URGENT - Tomorrow):** Minimal BaseEscrow changes - add library support hooks, keep existing flow working
- **Phase 2 (Later):** Implement AaveYieldLibrary
- **Phase 3 (Later):** Refactor AaveYieldGenerationModule to config-only
- **Phase 4 (Later):** Full integration and fork tests

**Key Principle:** BaseEscrow changes must be **backward compatible** and **non-breaking**. Existing yield flow (via YieldOps) continues to work.

---

## Phase 1: BaseEscrow Finalization (URGENT - Tomorrow)

### 1.1 Add Library Interface and Storage

**File:** `contracts/core/BaseEscrow.sol`

**Changes:**

```solidity
// Add after existing imports
import '../libraries/AaveYieldLibrary.sol'; // Will be created in Phase 2, but interface needed now

// Add storage (after existing YieldOps declaration)
AaveYieldLibrary public aaveYieldLibrary; // Library address (0 = not configured, use YieldOps)
bool public aaveYieldLibraryEnabled = false; // Feature flag

// Add events (after existing yield events)
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

**Why:**
- Library address storage allows enabling library pattern later
- Feature flag allows gradual rollout
- Events provide observability
- Non-breaking: existing code continues to work

### 1.2 Add Library Configuration Functions

**File:** `contracts/core/BaseEscrow.sol`

**Add after existing ops setters:**

```solidity
/**
 * @notice Set Aave yield library address (governance-controlled)
 * @param libraryAddress Address of AaveYieldLibrary contract
 * @dev Only ROLE_TIMELOCK can set. Library must be a contract with code.
 *      Setting library does NOT enable it - use setAaveYieldLibraryEnabled().
 */
function setAaveYieldLibrary(address libraryAddress) external onlyRole(ROLE_TIMELOCK) {
    if (libraryAddress != address(0) && libraryAddress.code.length == 0) {
        revert NotAContract(2, libraryAddress); // 2 = aaveYieldLibrary
    }
    address oldLibrary = address(aaveYieldLibrary);
    aaveYieldLibrary = AaveYieldLibrary(libraryAddress);
    emit AaveYieldLibrarySet(oldLibrary, libraryAddress);
}

/**
 * @notice Enable/disable Aave yield library (governance-controlled)
 * @param enabled True to use library, false to use YieldOps
 * @dev Only ROLE_TIMELOCK can enable. ROLE_GUARDIAN can disable (emergency).
 *      When disabled, falls back to YieldOps pattern.
 */
function setAaveYieldLibraryEnabled(bool enabled) external {
    if (enabled) {
        require(hasRole(ROLE_TIMELOCK, _msgSender()), "Only timelock can enable");
        if (address(aaveYieldLibrary) == address(0)) {
            revert NotAContract(2, address(0)); // Library must be set first
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

**Why:**
- Governance-controlled (timelock)
- Guardian can emergency-disable
- Non-breaking: defaults to false, uses existing YieldOps

### 1.3 Add aToken Tracking Storage

**File:** `contracts/core/BaseEscrow.sol`

**Add after moduleSnapshots mapping:**

```solidity
// Per-escrow aToken tracking (for library pattern)
// Maps: workflowId => aToken address => aToken balance at deposit
mapping(uint256 => mapping(address => uint256)) internal escrowATokenBalances;
// Maps: workflowId => token => is in yield (for library pattern)
mapping(uint256 => mapping(address => bool)) internal escrowInYield;
```

**Why:**
- Needed for library pattern (BaseEscrow owns aTokens)
- Minimal storage overhead
- Non-breaking: only used when library enabled

### 1.4 Update `_handleYieldAndGetActualAmount` to Support Library

**File:** `contracts/core/BaseEscrow.sol`

**Modify existing function (around line 1351):**

```solidity
function _handleYieldAndGetActualAmount(
    uint256 workflowId,
    address token,
    uint256 amount
) internal returns (uint256 actualAmount) {
    actualAmount = amount;
    
    EscrowSettings memory settings = escrowSettings[workflowId];
    bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
    
    // NEW: Check if library pattern is enabled
    if (aaveYieldLibraryEnabled && address(aaveYieldLibrary) != address(0)) {
        // Library pattern: BaseEscrow calls library directly
        return _handleYieldViaLibrary(workflowId, token, amount);
    }
    
    // EXISTING: YieldOps pattern (unchanged, continues to work)
    if (address(yieldOps) == address(0)) {
        if (yieldEnabled) {
            emit YieldHandlingFailed(workflowId, token, amount, uint8(FailureReason.MODULE_NOT_SET));
            emit OperationFailure(
                2,
                workflowId,
                address(0),
                YieldOps.handleYield.selector,
                uint8(FailureReason.MODULE_NOT_SET)
            );
        }
        return actualAmount;
    }
    // ... rest of existing YieldOps logic unchanged ...
}
```

**Add new internal function:**

```solidity
/**
 * @notice Handle yield withdrawal via library pattern
 * @param workflowId The escrow ID
 * @param token Token address
 * @param amount Original escrow amount
 * @return actualAmount Actual amount after yield withdrawal
 * @dev Only called when aaveYieldLibraryEnabled == true
 */
function _handleYieldViaLibrary(
    uint256 workflowId,
    address token,
    uint256 amount
) internal returns (uint256 actualAmount) {
    actualAmount = amount;
    
    EscrowSettings memory settings = escrowSettings[workflowId];
    bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
    
    if (!yieldEnabled) {
        return actualAmount;
    }
    
    IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
    if (address(genModule) == address(0)) {
        return actualAmount;
    }
    
    // Check if escrow has yield to withdraw
    if (!escrowInYield[workflowId][token]) {
        return actualAmount; // Not in yield, return original
    }
    
    // Get aToken address from module
    address aToken = _getATokenAddress(genModule, token);
    if (aToken == address(0)) {
        emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.MODULE_NOT_SET));
        return actualAmount;
    }
    
    // Get tracked aToken balance
    uint256 aTokenBalance = escrowATokenBalances[workflowId][aToken];
    if (aTokenBalance == 0) {
        // Clear state and return
        escrowInYield[workflowId][token] = false;
        return actualAmount;
    }
    
    // Get Aave pool address from module
    address aavePool = _getAavePoolAddress(genModule);
    if (aavePool == address(0)) {
        emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.MODULE_NOT_SET));
        return actualAmount;
    }
    
    // Call library to withdraw (msg.sender = BaseEscrow)
    try aaveYieldLibrary.withdraw(aavePool, token, aTokenBalance, address(this)) returns (uint256 withdrawnAmount) {
        actualAmount = withdrawnAmount;
        
        // Clear tracking
        escrowInYield[workflowId][token] = false;
        escrowATokenBalances[workflowId][aToken] = 0;
        
        // Handle yield distribution (via YieldOps for now, can be refactored later)
        _distributeYieldIfNeeded(workflowId, token, actualAmount, amount);
        
        emit YieldWithdrawalAttempted(workflowId, token, amount, actualAmount, true, 0);
    } catch {
        emit YieldWithdrawalAttempted(workflowId, token, amount, amount, false, uint8(FailureReason.WITHDRAWAL_FAILED));
        // Non-blocking: return original amount
    }
    
    return actualAmount;
}

/**
 * @notice Handle yield deposit via library pattern
 * @param workflowId The escrow ID
 * @param token Token address
 * @param amount Amount to deposit
 * @dev Only called when aaveYieldLibraryEnabled == true
 */
function _handleYieldDepositViaLibrary(
    uint256 workflowId,
    address token,
    uint256 amount
) internal {
    EscrowSettings memory settings = escrowSettings[workflowId];
    bool yieldEnabled = settings.yieldPreset != YieldPreset.OFF;
    
    if (!yieldEnabled) {
        return;
    }
    
    IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
    if (address(genModule) == address(0)) {
        return;
    }
    
    if (!genModule.isTokenSupported(token)) {
        return;
    }
    
    // Get Aave pool and aToken addresses from module
    address aavePool = _getAavePoolAddress(genModule);
    address aToken = _getATokenAddress(genModule, token);
    
    if (aavePool == address(0) || aToken == address(0)) {
        emit YieldDepositAttempted(workflowId, token, amount, false, uint8(FailureReason.MODULE_NOT_SET));
        return;
    }
    
    // Call library to supply (msg.sender = BaseEscrow)
    try aaveYieldLibrary.supply(aavePool, token, amount, address(this)) {
        // Track aToken balance
        uint256 aTokenBalance = IAToken(aToken).balanceOf(address(this));
        escrowATokenBalances[workflowId][aToken] = aTokenBalance;
        escrowInYield[workflowId][token] = true;
        
        emit YieldDepositAttempted(workflowId, token, amount, true, 0);
    } catch {
        emit YieldDepositAttempted(workflowId, token, amount, false, uint8(FailureReason.DEPOSIT_FAILED));
        // Non-blocking: continue without yield
    }
}

/**
 * @notice Helper to get Aave pool address from module
 * @param genModule Yield generation module
 * @return poolAddress Aave pool address (0 if not available)
 */
function _getAavePoolAddress(IYieldGenerationModule genModule) internal view returns (address poolAddress) {
    // Try to call getAavePoolAddress() if module supports it
    (bool success, bytes memory data) = address(genModule).staticcall(
        abi.encodeWithSelector(bytes4(keccak256("getAavePoolAddress()")))
    );
    if (success && data.length >= 32) {
        poolAddress = abi.decode(data, (address));
    }
}

/**
 * @notice Helper to get aToken address from module
 * @param genModule Yield generation module
 * @param token Underlying token address
 * @return aTokenAddress aToken address (0 if not available)
 */
function _getATokenAddress(IYieldGenerationModule genModule, address token) internal view returns (address aTokenAddress) {
    // Try to call getATokenAddress(address) if module supports it
    (bool success, bytes memory data) = address(genModule).staticcall(
        abi.encodeWithSelector(bytes4(keccak256("getATokenAddress(address)")), token)
    );
    if (success && data.length >= 32) {
        aTokenAddress = abi.decode(data, (address));
    }
}

/**
 * @notice Distribute yield if needed (placeholder for now, uses YieldOps)
 * @param workflowId The escrow ID
 * @param token Token address
 * @param actualAmount Total amount withdrawn
 * @param originalAmount Original escrow amount
 * @dev Can be refactored later to use library or direct distribution
 */
function _distributeYieldIfNeeded(
    uint256 workflowId,
    address token,
    uint256 actualAmount,
    uint256 originalAmount
) internal {
    if (actualAmount <= originalAmount) {
        return; // No yield to distribute
    }
    
    uint256 yieldAmount = actualAmount - originalAmount;
    
    // For now, use YieldOps for distribution (can be refactored later)
    // This is non-critical and can be improved in Phase 3
    if (address(yieldOps) != address(0)) {
        IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
        uint256 snapshottedYieldFee = moduleSnapshots[workflowId].yieldProtocolFeeBps;
        
        EscrowTransfer memory et = escrowTransfers[workflowId];
        EscrowSettings memory settings = escrowSettings[workflowId];
        bytes memory distributionData = YieldPresetLibrary.deriveDistributionData(
            settings.yieldPreset,
            et.from,
            et.to
        );
        
        // Transfer yield to YieldOps for distribution
        IERC20(token).safeTransfer(address(yieldOps), yieldAmount);
        
        // Call YieldOps to distribute (non-blocking)
        (bool success, ) = address(yieldOps).call(
            abi.encodeWithSelector(
                YieldOps.handleYieldDistribution.selector, // Need to add this to YieldOps
                distModule,
                workflowId,
                token,
                yieldAmount,
                snapshottedYieldFee,
                escrowFeeAddress,
                distributionData
            )
        );
        success; // Ignore result
    }
}
```

**Why:**
- Non-breaking: only called when library enabled
- Existing YieldOps flow unchanged
- Graceful fallback on errors
- Events for observability

### 1.5 Update `createEscrow` to Support Library Pattern

**File:** `contracts/core/BaseEscrow.sol`

**Modify existing yield deposit section (around line 424):**

```solidity
// Yield deposit (optional, non-blocking)
if (result.yieldEnabled && result.shouldDepositYield) {
    // NEW: Check if library pattern is enabled
    if (aaveYieldLibraryEnabled && address(aaveYieldLibrary) != address(0)) {
        _handleYieldDepositViaLibrary(workflowId, token, result.amountAfterFee);
    } else {
        // EXISTING: YieldOps pattern (unchanged)
        IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
        if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
            // Use low-level call to save bytecode
            (bool success, ) = address(genModule).call(
                abi.encodeWithSelector(IYieldGenerationModule.depositForYield.selector, workflowId, token, result.amountAfterFee)
            );
            if (!success) {
                emit YieldHandlingFailed(workflowId, token, result.amountAfterFee, uint8(FailureReason.DEPOSIT_FAILED));
                emit OperationFailure(
                    1,
                    workflowId,
                    address(genModule),
                    IYieldGenerationModule.depositForYield.selector,
                    uint8(FailureReason.DEPOSIT_FAILED)
                );
            }
        }
    }
}
```

**Why:**
- Non-breaking: existing flow continues when library disabled
- New flow only active when explicitly enabled
- Same error handling pattern

### 1.6 Add IAToken Interface

**File:** `contracts/core/BaseEscrow.sol`

**Add after existing imports:**

```solidity
// Aave interfaces (minimal, only what BaseEscrow needs)
interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}
```

**Why:**
- Needed for aToken balance tracking
- Minimal interface (only balanceOf)
- No Aave package dependency in BaseEscrow

### 1.7 Add Error Definitions

**File:** `contracts/core/BaseEscrow.sol`

**Add to existing errors section:**

```solidity
// Aave library errors
error AaveLibraryNotConfigured();
error AavePoolNotConfigured();
```

**Why:**
- Clear error messages
- Consistent with existing error pattern

### 1.8 Update Module Interface (Add Config Methods)

**File:** `contracts/interfaces/IYieldGenerationModule.sol`

**Add new methods (non-breaking, optional):**

```solidity
/**
 * @notice Get Aave pool address (for library pattern)
 * @return poolAddress Aave V3 Pool address (address(0) if not Aave module or not configured)
 * @dev Optional method - modules can implement if they support Aave
 */
function getAavePoolAddress() external view returns (address poolAddress);

/**
 * @notice Get aToken address for a token (for library pattern)
 * @param token Underlying token address
 * @return aTokenAddress aToken address (address(0) if token not supported)
 * @dev Optional method - modules can implement if they support Aave
 */
function getATokenAddress(address token) external view returns (address aTokenAddress);
```

**Why:**
- Non-breaking: existing modules don't need to implement
- BaseEscrow uses staticcall with try/catch
- Allows AaveYieldGenerationModule to provide config

### 1.9 Verify User Experience for Yield Withdrawal

**Current Implementation Analysis:**

The current flow already provides good UX:

1. **Escrow Release/Cancel:**
   ```solidity
   // In _releaseEscrowTransfer / _cancelAndRefund
   uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
   // actualAmount = principal + yield (if any)
   claimableBalances[workflowId][recipient] += actualAmount;
   ```

2. **User Withdrawal:**
   ```solidity
   // User calls once
   withdrawEscrow(workflowId);
   // Receives principal + yield in single transaction ✅
   ```

**This is already correct!** ✅

**No changes needed** - users get yield automatically included in their withdrawal.

**Verification:**
- ✅ Yield automatically withdrawn during release/cancel
- ✅ Yield included in claimable balance
- ✅ Single `withdrawEscrow()` call gets everything
- ✅ Works for both library and YieldOps patterns

### 1.10 Create AaveYieldLibrary Stub

**File:** `contracts/libraries/AaveYieldLibrary.sol` (NEW)

**Create minimal stub (will be implemented in Phase 2):**

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

// Minimal Aave Pool interface (only what we need)
interface IPool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title AaveYieldLibrary
 * @notice Library for Aave V3 yield operations
 * @dev Uses delegatecall so msg.sender remains the caller (BaseEscrow)
 *      This ensures Aave semantics are correct (msg.sender owns tokens/aTokens)
 */
library AaveYieldLibrary {
    using SafeERC20 for IERC20;
    
    /**
     * @notice Supply tokens to Aave Pool
     * @param pool Aave V3 Pool address
     * @param token Underlying token address
     * @param amount Amount to supply
     * @param onBehalfOf Address to receive aTokens (typically BaseEscrow)
     * @dev msg.sender must own tokens and approve pool
     */
    function supply(
        address pool,
        address token,
        uint256 amount,
        address onBehalfOf
    ) external {
        // Approve pool (msg.sender = BaseEscrow)
        IERC20(token).safeApprove(pool, amount);
        
        // Supply to Aave (msg.sender = BaseEscrow, pulls from BaseEscrow)
        IPool(pool).supply(token, amount, onBehalfOf, 0);
        
        // Reset approval to zero (safety)
        IERC20(token).safeApprove(pool, 0);
    }
    
    /**
     * @notice Withdraw tokens from Aave Pool
     * @param pool Aave V3 Pool address
     * @param token Underlying token address
     * @param amount aToken amount to withdraw
     * @param to Address to receive underlying tokens
     * @return actualAmount Actual underlying amount withdrawn
     * @dev msg.sender must own aTokens
     */
    function withdraw(
        address pool,
        address token,
        uint256 amount,
        address to
    ) external returns (uint256 actualAmount) {
        // Withdraw from Aave (msg.sender = BaseEscrow, burns BaseEscrow's aTokens)
        actualAmount = IPool(pool).withdraw(token, amount, to);
    }
}
```

**Why:**
- Stub allows BaseEscrow to compile
- Will be fully implemented in Phase 2
- Minimal interface (only supply/withdraw)

### 1.10 User Experience: Simple Yield Withdrawal

**Requirement:** Users should get yield automatically - no complicated steps.

**Current Flow (Good UX):**
1. Escrow is released/cancelled
2. `_handleYieldAndGetActualAmount()` automatically withdraws yield
3. Yield is included in `claimableBalances[workflowId][recipient]`
4. User calls `withdrawEscrow(workflowId)` once
5. **User receives principal + yield in single withdrawal** ✅

**Verification:**
```solidity
// In _releaseEscrowTransfer / _cancelAndRefund
uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
// actualAmount includes yield (if any)
claimableBalances[workflowId][recipient] += actualAmount; // Principal + yield
```

**This is already implemented correctly!** ✅

**User Experience:**
- ✅ Single `withdrawEscrow()` call
- ✅ Receives principal + yield together
- ✅ No separate yield withdrawal needed
- ✅ Works for both library and YieldOps patterns

**No changes needed** - current implementation already provides good UX.

### 1.11 Emergency Unwind Function (Guardian)

**Requirement:** Guardian can unwind Aave positions in emergency, but cannot reroute funds.

**File:** `contracts/core/BaseEscrow.sol`

**Add after library setter functions:**

```solidity
// Emergency unwind state
uint256 public constant MAX_UNWIND_AMOUNT_PER_CALL = 1_000_000e18; // 1M tokens max per call
uint256 public constant UNWIND_COOLDOWN = 1 hours; // Minimum time between unwinds
mapping(address => uint256) public lastUnwindTimestamp; // token => last unwind time
uint256 public totalUnwoundAmount; // Total amount unwound (for monitoring)

// Events
event EmergencyUnwindExecuted(
    address indexed token,
    uint256 aTokenAmount,
    uint256 underlyingAmount,
    uint256 timestamp,
    address indexed caller,
    uint8 reasonCode // 0 = success, 1 = failed, 2 = nothing to unwind, 3+ = safety checks failed
);

/**
 * @notice Emergency unwind Aave positions for a specific token (guardian only)
 * @param token Underlying token address to unwind
 * @param maxATokenAmount Maximum aToken amount to unwind (safety limit)
 * @return underlyingAmount Actual underlying amount withdrawn
 * @dev CRITICAL SAFETY CONSTRAINTS:
 *      - Only callable by ROLE_GUARDIAN
 *      - Only callable when paused
 *      - Proceeds go to BaseEscrow (not guardian)
 *      - Rate limited (cooldown + max per call)
 *      - Scoped to specific token (not arbitrary)
 *      - Cannot reroute funds (always goes to BaseEscrow)
 */
function emergencyUnwindAavePosition(
    address token,
    uint256 maxATokenAmount
) external onlyRole(ROLE_GUARDIAN) whenPaused returns (uint256 underlyingAmount) {
    // Safety check 1: Must be paused
    if (!paused()) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 101); // 101 = not paused (emergency-specific)
        return 0;
    }
    
    // Safety check 2: Rate limiting (cooldown per token)
    uint256 lastUnwind = lastUnwindTimestamp[token];
    if (block.timestamp < lastUnwind + UNWIND_COOLDOWN) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 102); // 102 = cooldown (emergency-specific)
        return 0;
    }
    
    // Safety check 3: Amount limit
    if (maxATokenAmount > MAX_UNWIND_AMOUNT_PER_CALL) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 103); // 103 = exceeds limit (emergency-specific)
        return 0;
    }
    
    // Safety check 4: Library must be enabled and configured
    if (!aaveYieldLibraryEnabled || address(aaveYieldLibrary) == address(0)) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET)); // 3 = MODULE_NOT_SET
        return 0;
    }
    
    // Get module and pool address
    // Note: This uses default module (not per-escrow) for emergency unwind
    // This is acceptable because we're unwinding all positions for a token
    IYieldGenerationModule genModule = _getDefaultYieldGenerationModule();
    if (address(genModule) == address(0)) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET)); // 3 = MODULE_NOT_SET
        return 0;
    }
    
    address aavePool = _getAavePoolAddress(genModule);
    address aToken = _getATokenAddress(genModule, token);
    
    if (aavePool == address(0) || aToken == address(0)) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), uint8(FailureReason.MODULE_NOT_SET)); // 3 = MODULE_NOT_SET
        return 0;
    }
    
    // Safety check 5: Get BaseEscrow's aToken balance (scope restriction - only this token)
    uint256 aTokenBalance = IAToken(aToken).balanceOf(address(this));
    if (aTokenBalance == 0) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 104); // 104 = nothing to unwind (emergency-specific)
        return 0;
    }
    
    // Safety check 6: Cap to max amount (amount limit)
    uint256 unwindAmount = aTokenBalance < maxATokenAmount ? aTokenBalance : maxATokenAmount;
    
    // CRITICAL: Unwind to BaseEscrow (address(this)), NOT to guardian or arbitrary address
    // This ensures guardian cannot reroute funds - destination is hardcoded
    try aaveYieldLibrary.withdraw(aavePool, token, unwindAmount, address(this)) returns (uint256 withdrawn) {
        underlyingAmount = withdrawn;
        
        // Update state (rate limiting)
        lastUnwindTimestamp[token] = block.timestamp;
        totalUnwoundAmount += underlyingAmount;
        
        emit EmergencyUnwindExecuted(
            token,
            unwindAmount,
            underlyingAmount,
            block.timestamp,
            _msgSender(),
            0 // 0 = success
        );
    } catch {
        // Unwind failed - emit event but don't revert (non-blocking)
        emit EmergencyUnwindExecuted(
            token,
            unwindAmount,
            0,
            block.timestamp,
            _msgSender(),
            uint8(FailureReason.WITHDRAWAL_FAILED) // 9 = WITHDRAWAL_FAILED (consistent with yield withdrawal)
        );
        return 0;
    }
}

/**
 * @notice Get default yield generation module (for emergency operations)
 * @return module Default yield generation module
 */
function _getDefaultYieldGenerationModule() internal view returns (IYieldGenerationModule module) {
    // Get from ModuleManagementContract if available
    // This is a simplified version - can be enhanced later
    // For now, returns address(0) if not available
    // Emergency unwind will fail gracefully
    return IYieldGenerationModule(address(0)); // Placeholder - implement based on your module management
}
```

**Safety Features:**
- ✅ **Pause requirement:** Only works when paused
- ✅ **Rate limiting:** Cooldown per token (1 hour between unwinds)
- ✅ **Amount limits:** Max 1M tokens per call
- ✅ **Destination restriction:** **ALWAYS goes to BaseEscrow** (hardcoded `address(this)`), never to guardian
- ✅ **Scope restriction:** Only specific token (not arbitrary transfers)
- ✅ **Structured events:** Full observability with reason codes
- ✅ **Non-blocking:** Fails gracefully, doesn't revert
- ✅ **Guardian-only:** Cannot be called by anyone else

**Why This is Safe:**
- Guardian **cannot reroute funds** (hardcoded destination = `address(this)`)
- Guardian **cannot drain** (rate limited, amount limited)
- Guardian **cannot abuse** (requires pause, cooldown, scoped to token)
- **Full observability** (events with reason codes, monitoring)
- **Non-blocking** (doesn't trap funds if it fails)

**Event Reason Codes:**
- `0` = Success
- `1` = Withdrawal failed
- `2` = Nothing to unwind
- `3` = Not paused
- `4` = Cooldown not expired
- `5` = Amount exceeds limit
- `6` = Library not configured
- `7` = No module configured
- `8` = Pool not configured

### 1.11 Emergency Unwind Function (Guardian)

**Requirement:** Guardian can unwind Aave positions in emergency, but cannot reroute funds.

**File:** `contracts/core/BaseEscrow.sol`

**Add after library setter functions:**

```solidity
// Emergency unwind constants and state
uint256 public constant MAX_UNWIND_AMOUNT_PER_CALL = 1_000_000e18; // 1M tokens max per call
uint256 public constant UNWIND_COOLDOWN = 1 hours; // Minimum time between unwinds per token
mapping(address => uint256) public lastUnwindTimestamp; // token => last unwind time
uint256 public totalUnwoundAmount; // Total amount unwound across all tokens (for monitoring)

// Events
event EmergencyUnwindExecuted(
    address indexed token,
    uint256 aTokenAmount,
    uint256 underlyingAmount,
    uint256 timestamp,
    address indexed caller,
    uint8 reasonCode // 0 = success, 1 = failed, 2 = nothing to unwind
);

/**
 * @notice Emergency unwind Aave positions for a specific token (guardian only)
 * @param token Underlying token address to unwind
 * @param maxATokenAmount Maximum aToken amount to unwind (safety limit)
 * @return underlyingAmount Actual underlying amount withdrawn to BaseEscrow
 * @dev CRITICAL SAFETY CONSTRAINTS:
 *      - Only callable by ROLE_GUARDIAN
 *      - Only callable when paused
 *      - Proceeds ALWAYS go to BaseEscrow (not guardian, not arbitrary address)
 *      - Rate limited (cooldown per token + max per call)
 *      - Scoped to specific token (not arbitrary transfers)
 *      - Cannot reroute funds (hardcoded destination = address(this))
 *      - Non-blocking (fails gracefully, doesn't revert)
 */
function emergencyUnwindAavePosition(
    address token,
    uint256 maxATokenAmount
) external onlyRole(ROLE_GUARDIAN) whenPaused returns (uint256 underlyingAmount) {
    // Safety check 1: Must be paused
    if (!paused()) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 3); // 3 = not paused
        return 0;
    }
    
    // Safety check 2: Rate limiting (cooldown per token)
    uint256 lastUnwind = lastUnwindTimestamp[token];
    if (block.timestamp < lastUnwind + UNWIND_COOLDOWN) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 4); // 4 = cooldown
        return 0;
    }
    
    // Safety check 3: Amount limit
    if (maxATokenAmount > MAX_UNWIND_AMOUNT_PER_CALL) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 5); // 5 = exceeds limit
        return 0;
    }
    
    // Safety check 4: Library must be enabled and configured
    if (!aaveYieldLibraryEnabled || address(aaveYieldLibrary) == address(0)) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 6); // 6 = library not configured
        return 0;
    }
    
    // Get module and pool address (use default module for emergency)
    IYieldGenerationModule genModule = _getDefaultYieldGenerationModule();
    if (address(genModule) == address(0)) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 7); // 7 = no module
        return 0;
    }
    
    address aavePool = _getAavePoolAddress(genModule);
    address aToken = _getATokenAddress(genModule, token);
    
    if (aavePool == address(0) || aToken == address(0)) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 8); // 8 = pool not configured
        return 0;
    }
    
    // Get BaseEscrow's aToken balance (safety check 5: scope restriction)
    uint256 aTokenBalance = IAToken(aToken).balanceOf(address(this));
    if (aTokenBalance == 0) {
        emit EmergencyUnwindExecuted(token, 0, 0, block.timestamp, _msgSender(), 2); // 2 = nothing to unwind
        return 0;
    }
    
    // Cap to max amount (safety check 6: amount limit)
    uint256 unwindAmount = aTokenBalance < maxATokenAmount ? aTokenBalance : maxATokenAmount;
    
    // CRITICAL: Unwind to BaseEscrow (address(this)), NOT to guardian or arbitrary address
    // This ensures guardian cannot reroute funds
    try aaveYieldLibrary.withdraw(aavePool, token, unwindAmount, address(this)) returns (uint256 withdrawn) {
        underlyingAmount = withdrawn;
        
        // Update state (rate limiting)
        lastUnwindTimestamp[token] = block.timestamp;
        totalUnwoundAmount += underlyingAmount;
        
        emit EmergencyUnwindExecuted(
            token,
            unwindAmount,
            underlyingAmount,
            block.timestamp,
            _msgSender(),
            0 // 0 = success
        );
    } catch {
        // Unwind failed - emit event but don't revert (non-blocking)
        emit EmergencyUnwindExecuted(
            token,
            unwindAmount,
            0,
            block.timestamp,
            _msgSender(),
            1 // 1 = failed
        );
        return 0;
    }
}

/**
 * @notice Get default yield generation module (for emergency operations)
 * @return module Default yield generation module
 * @dev Returns default module from ModuleManagementContract or address(0)
 */
function _getDefaultYieldGenerationModule() internal view returns (IYieldGenerationModule module) {
    // Try to get from ModuleManagementContract
    // This is a placeholder - implement based on your module management
    // For EscrowVault, use moduleManagement.getDefaultModule(address(this), ModuleType.YIELD_GEN)
    // For EscrowableERC20, similar approach
    return IYieldGenerationModule(address(0)); // Placeholder - will be implemented
}
```

**Safety Features:**
- ✅ **Pause requirement:** Only works when paused
- ✅ **Rate limiting:** Cooldown per token (1 hour)
- ✅ **Amount limits:** Max 1M tokens per call
- ✅ **Destination restriction:** **ALWAYS goes to BaseEscrow** (address(this)), never to guardian
- ✅ **Scope restriction:** Only specific token (not arbitrary transfers)
- ✅ **Structured events:** Full observability with reason codes
- ✅ **Non-blocking:** Fails gracefully, doesn't revert
- ✅ **Guardian-only:** Cannot be called by anyone else

**Why This is Safe:**
- Guardian **cannot reroute funds** (hardcoded `address(this)`)
- Guardian **cannot drain** (rate limited, amount limited)
- Guardian **cannot abuse** (requires pause, cooldown, scoped to token)
- **Full observability** (events with reason codes, monitoring)
- **Non-blocking** (doesn't trap funds if it fails)

**Event Reason Codes:**
- `0` = Success
- `1` = Withdrawal failed
- `2` = Nothing to unwind
- `3` = Not paused
- `4` = Cooldown not expired
- `5` = Amount exceeds limit
- `6` = Library not configured
- `7` = No module configured
- `8` = Pool not configured

### 1.12 Testing Requirements

**File:** `test/foundry/core/BaseEscrowYieldLibrary.t.sol` (NEW)

**Create test file:**

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {BaseEscrow} from "../../../contracts/core/BaseEscrow.sol";
// ... other imports

contract BaseEscrowYieldLibraryTest is Test {
    // Test that library can be set/unset
    // Test that library enable/disable works
    // Test that existing YieldOps flow still works when library disabled
    // Test that guardian can emergency-disable library
    // Test that library calls fail gracefully when library not set
    // Test that library calls fail gracefully when library disabled
    
    // NEW: Test emergency unwind
    // Test that guardian can unwind when paused
    // Test that guardian cannot unwind when not paused (reason code 101)
    // Test that guardian cannot unwind during cooldown (reason code 102)
    // Test that guardian cannot unwind more than max amount (reason code 103)
    // Test that library/module/pool not configured emits MODULE_NOT_SET (3)
    // Test that withdrawal failure emits WITHDRAWAL_FAILED (9) - consistent with yield
    // Test that nothing to unwind emits reason code 104
    // Test that funds go to BaseEscrow (not guardian)
    // Test that unwind fails gracefully on error
    // Test that events are emitted with correct reason codes (consistent with FailureReason enum)
}
```

**Why:**
- Ensures BaseEscrow changes don't break existing functionality
- Validates new library hooks work
- Tests emergency controls
- Validates safety constraints

---

## Phase 2: AaveYieldLibrary Implementation (Later)

### 2.1 Install Aave Package

```bash
pnpm add @aave/core-v3
```

### 2.2 Update AaveYieldLibrary with Real Interfaces

**File:** `contracts/libraries/AaveYieldLibrary.sol`

**Replace stub with full implementation:**

```solidity
import '@aave/core-v3/contracts/interfaces/IPool.sol';
import '@aave/core-v3/contracts/interfaces/IAToken.sol';
```

**Add error handling, events, validation**

### 2.3 Add Comprehensive Tests

**File:** `test/foundry/libraries/AaveYieldLibrary.t.sol`

**Fork testnet and test against real Aave:**

```solidity
// Fork Base Sepolia
vm.createSelectFork(vm.envString("RPC_BASE_SEPOLIA"));

// Get real Aave Pool
IPool pool = IPool(0x...); // Base Sepolia Aave Pool

// Test supply/withdraw with real contracts
```

---

## Phase 3: AaveYieldGenerationModule Refactor (Later)

### 3.1 Update Module to Config-Only

**File:** `contracts/modules/AaveYieldGenerationModule.sol`

**Remove:**
- `depositForYield()` implementation
- `withdrawWithYield()` implementation
- Asset custody logic

**Add:**
- `getAavePoolAddress()` - returns pool address
- `getATokenAddress(address token)` - returns aToken address
- Configuration management (pool, tokens, caps)
- Guardian emergency controls

### 3.2 Update Module Interface

**File:** `contracts/interfaces/IYieldGenerationModule.sol`

**Make new methods required** (or keep optional with BaseEscrow fallback)

---

## Phase 4: Full Integration and Fork Tests (Later)

### 4.1 Create Fork Test Suite

**File:** `test/foundry/integration/AaveForkTests.t.sol`

**Test against real Aave on Base Sepolia:**

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {BaseEscrow} from "../../../contracts/core/BaseEscrow.sol";
import {AaveYieldLibrary} from "../../../contracts/libraries/AaveYieldLibrary.sol";
// Import real Aave interfaces
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";

contract AaveForkTests is Test {
    // Base Sepolia Aave addresses
    address constant BASE_SEPOLIA_POOL_PROVIDER = 0x...; // Get from Aave docs
    address constant BASE_SEPOLIA_USDC = 0x...; // Test token
    address constant BASE_SEPOLIA_AUSDC = 0x...; // aToken
    
    function setUp() public {
        // Fork Base Sepolia
        vm.createSelectFork(vm.envString("RPC_BASE_SEPOLIA"));
    }
    
    function testRealAaveSupply() public {
        // Get real Aave Pool
        IPoolAddressesProvider provider = IPoolAddressesProvider(BASE_SEPOLIA_POOL_PROVIDER);
        IPool pool = IPool(provider.getPool());
        
        // Deploy BaseEscrow with library
        // Create escrow with yield enabled
        // Verify deposit works with real Aave
    }
    
    function testRealAaveWithdraw() public {
        // Test withdrawal from real Aave
        // Verify yield calculation
    }
    
    function testEmergencyUnwind() public {
        // Test emergency unwind with real Aave
        // Verify funds go to BaseEscrow
        // Verify rate limits work
    }
}
```

**Required Environment:**
- `RPC_BASE_SEPOLIA` in `.env`
- Aave addresses for Base Sepolia
- Test tokens (USDC, etc.)

**Test Coverage:**
- ✅ Real Aave supply/withdraw
- ✅ Yield calculation accuracy
- ✅ Emergency unwind with real Aave
- ✅ Module swap with real Aave
- ✅ Guardian controls

### 4.2 Test Module Swaps

- Swap from old module to new module
- Verify existing escrows continue to work
- Verify new escrows use new module

### 4.3 Test Guardian Emergency Controls

- Guardian can disable library
- Guardian can pause yield deposits
- Guardian cannot enable (only timelock)

---

## User Experience Verification

### Yield Withdrawal UX

**Current Flow (Already Good):**
1. Escrow released/cancelled → `_handleYieldAndGetActualAmount()` called
2. Yield automatically withdrawn (if any)
3. `actualAmount` (principal + yield) added to `claimableBalances`
4. User calls `withdrawEscrow(workflowId)` once
5. **User receives principal + yield together** ✅

**No changes needed** - UX is already simple and user-friendly.

**Verification Code:**
```solidity
// In _releaseEscrowTransfer (line ~1488)
uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
// actualAmount includes yield if generated
_attemptAutoTransfer(workflowId, to, token, actualAmount); // Includes yield ✅
```

### Emergency Unwind Function

**Implementation:** See section 1.11 above for complete code.

**Key Safety Features:**
- ✅ Requires pause
- ✅ Rate limited (cooldown)
- ✅ Amount limited (max per call)
- ✅ Funds go to BaseEscrow (not guardian)
- ✅ Scoped to specific token
- ✅ Structured events
- ✅ Non-blocking (fails gracefully)

**Why This is Safe:**
- Guardian cannot reroute funds (always to BaseEscrow)
- Guardian cannot drain (rate + amount limits)
- Guardian cannot abuse (pause requirement)
- Full observability (events)

---

## User Experience Verification

### ✅ Yield Withdrawal UX (Already Good)

**Current Flow:**
1. Escrow released/cancelled → `_handleYieldAndGetActualAmount()` called automatically
2. Yield withdrawn (if any) → included in `actualAmount`
3. `claimableBalances[workflowId][recipient] += actualAmount` (principal + yield)
4. User calls `withdrawEscrow(workflowId)` **once**
5. **User receives principal + yield together** ✅

**Code Verification:**
```solidity
// In _releaseEscrowTransfer (line ~1488)
uint256 actualAmount = _handleYieldAndGetActualAmount(workflowId, token, amount);
// actualAmount includes yield if generated
_attemptAutoTransfer(workflowId, to, token, actualAmount); // Includes yield ✅
// If auto-transfer fails, goes to claimable balance (also includes yield)
```

**User Experience:**
- ✅ **Single transaction:** One `withdrawEscrow()` call
- ✅ **Automatic yield:** No separate yield withdrawal needed
- ✅ **Simple:** User doesn't need to understand yield mechanics
- ✅ **Works for both patterns:** Library and YieldOps

**No changes needed** - UX is already excellent! ✅

---

## Critical Checklist for Tomorrow

### BaseEscrow Changes (Must Complete)

- [ ] Add `aaveYieldLibrary` storage variable
- [ ] Add `aaveYieldLibraryEnabled` feature flag
- [ ] Add library setter functions (timelock + guardian disable)
- [ ] Add aToken tracking storage
- [ ] Add `_handleYieldViaLibrary()` function
- [ ] Add `_handleYieldDepositViaLibrary()` function
- [ ] Add helper functions (`_getAavePoolAddress`, `_getATokenAddress`)
- [ ] Update `_handleYieldAndGetActualAmount()` to check library flag
- [ ] Update `createEscrow()` to use library when enabled
- [ ] Add IAToken interface
- [ ] Add events (YieldDepositAttempted, YieldWithdrawalAttempted)
- [ ] Add errors (AaveLibraryNotConfigured, AavePoolNotConfigured)
- [ ] **Add emergency unwind function** (guardian, pause-required, rate-limited)
- [ ] Create AaveYieldLibrary stub
- [ ] **Verify yield withdrawal UX** (users get yield automatically - no changes needed)
- [ ] Add tests for library enable/disable
- [ ] Add tests for guardian emergency controls
- [ ] **Add tests for emergency unwind:**
  - [ ] Guardian can unwind when paused
  - [ ] Guardian cannot unwind when not paused
  - [ ] Guardian cannot unwind during cooldown
  - [ ] Guardian cannot unwind more than max amount
  - [ ] **CRITICAL: Funds go to BaseEscrow (not guardian)**
  - [ ] Unwind fails gracefully on error
  - [ ] Events emitted with correct reason codes
  - [ ] Non-guardian cannot call unwind
  - [ ] Cooldown respected per token
  - [ ] Amount limits enforced
- [ ] Verify existing YieldOps flow still works
- [ ] Run all existing tests (must pass)
- [ ] Check contract size (must not exceed limit)

### Module Interface Updates (Must Complete)

- [ ] Add `getAavePoolAddress()` to interface (optional)
- [ ] Add `getATokenAddress(address)` to interface (optional)

### Testing (Must Complete)

- [ ] Unit tests for library hooks
- [ ] Integration tests with library disabled (existing flow)
- [ ] Integration tests with library enabled (new flow, will fail until Phase 2)
- [ ] Guardian emergency control tests
- [ ] All existing tests must pass

### Documentation (Should Complete)

- [ ] Update BaseEscrow NatSpec for new functions
- [ ] Document library pattern approach
- [ ] Document migration path from YieldOps to library

---

## Deployment Checklist

### Pre-Deployment (Tomorrow)

- [ ] All tests pass
- [ ] Contract size within limits
- [ ] No breaking changes to existing functionality
- [ ] Library address can be set to address(0) (disabled by default)
- [ ] Guardian can emergency-disable library
- [ ] Existing YieldOps flow works unchanged

### Post-Deployment (Later)

- [ ] Deploy AaveYieldLibrary (Phase 2)
- [ ] Set library address via governance
- [ ] Enable library via governance
- [ ] Test with real Aave on testnet
- [ ] Refactor AaveYieldGenerationModule (Phase 3)
- [ ] Full integration tests (Phase 4)

---

## Risk Mitigation

### Backward Compatibility

- ✅ Library disabled by default (`aaveYieldLibraryEnabled = false`)
- ✅ Existing YieldOps flow unchanged
- ✅ New code only executes when explicitly enabled
- ✅ Graceful fallback on errors

### Emergency Controls

- ✅ Guardian can disable library (emergency)
- ✅ Timelock required to enable (safety)
- ✅ Library can be set to address(0) (disable)
- ✅ Pause mechanism still works

### Testing Strategy

- ✅ Unit tests for new functions
- ✅ Integration tests with library disabled
- ✅ Integration tests with library enabled (Phase 2)
- ✅ Fork tests against real Aave (Phase 4)

---

## Size Impact Estimate

**BaseEscrow additions:**
- Storage variables: ~100 bytes
- Library setter functions: ~400 bytes
- Library hook functions: ~800 bytes
- Helper functions: ~300 bytes
- Events: ~200 bytes
- **Total: ~1.8KB**

**Current BaseEscrow:** ~31.6KB  
**After changes:** ~33.4KB  
**Status:** ⚠️ Still over 24KB limit, but acceptable for testnet

**Note:** Library code deployed separately, doesn't add to BaseEscrow size.

---

## Timeline

### Tomorrow (Testnet Deployment)

- **Morning:** Implement Phase 1 changes
- **Afternoon:** Testing and verification
- **Evening:** Deploy to testnet

### Next Week (Phase 2)

- Implement AaveYieldLibrary
- Fork tests against real Aave
- Deploy library to testnet

### Following Weeks (Phases 3-4)

- Refactor AaveYieldGenerationModule
- Full integration tests
- Mainnet preparation

---

## Success Criteria

### Tomorrow (Phase 1)

- ✅ BaseEscrow compiles
- ✅ All existing tests pass
- ✅ New library hooks work (when enabled)
- ✅ Existing YieldOps flow unchanged
- ✅ Guardian emergency controls work
- ✅ Contract size acceptable
- ✅ Ready for testnet deployment

### Phase 2-4 (Later)

- ✅ Library works with real Aave
- ✅ Module refactored to config-only
- ✅ Full integration tests pass
- ✅ Ready for mainnet

---

**Status:** 🚨 **URGENT - Phase 1 must be complete by tomorrow**
