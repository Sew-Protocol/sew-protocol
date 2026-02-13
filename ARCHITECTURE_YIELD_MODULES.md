# Yield Module Externalization Architecture

## Executive Summary

This document outlines the architecture for externalizing yield logic from `BaseEscrow` into a modular system. The goal is to:

1. **Reduce core contract bytecode** by ~1,600 bytes (freeing lite variants to fit < 24 KB)
2. **Enable multiple yield sources** without modifying core escrow logic
3. **Future-proof** the system for integrations with Morpho, Lido, Curve, etc.
4. **Follow existing patterns** (similar to IResolutionModule, IYieldGenerationModule)
5. **Minimize runtime overhead** (single external call per yield operation)

---

## Current State Analysis

### Problem: Yield Logic is Embedded in Core

**BaseEscrow currently contains:**
```
- _handleYieldAndGetActualAmount()      ~300 lines, ~800 bytes bytecode
- _depositYieldForEscrow()              virtual, ~100 bytes
- YieldOps integration code             ~500 bytes
- YieldPresetLibrary usage              ~300 bytes
- Yield validation/error handling       ~200 bytes
- Yield state variables                 ~100 bytes
─────────────────────────────────────────────────────
TOTAL YIELD BYTECODE:                   ~1,800-2,000 bytes
```

**This causes:**
- Core contracts exceed 24 KB (too large for Mainnet)
- Yield logic mixed with core escrow logic (poor separation)
- Adding new yield sources requires modifying BaseEscrow
- Yield features cannot evolve independently

### Solution: Externalize Behind Module Interface

Move 1,600+ bytes of yield logic to an external contract implementing `IYieldModule` interface.

**BaseEscrow will contain only:**
```
- yieldMode enum or flag                ~20 bytes
- yieldModule address (snapshotted)     ~32 bytes (part of existing snapshot)
- Thin delegation methods               ~390 bytes total
  - _delegateYieldDeposit()            
  - _delegateYieldWithdrawal()         
  - _handleYieldAndGetAmount()         (dispatcher only)
  - Module failure handling             
─────────────────────────────────────────────────────
TOTAL YIELD GLUE IN CORE:               ~440 bytes
```

**Savings: 1,600 - 440 = 1,160+ bytes per contract**

---

## Proposed Architecture

### 1. IYieldModule Interface

**File:** `contracts/interfaces/IYieldModule.sol`

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/YieldPresets.sol';

/**
 * @title IYieldModule
 * @notice Unified interface for yield generation and distribution modules.
 * 
 * Yield modules handle all aspects of yield generation, tracking, and 
 * distribution for escrow transfers. This externalization allows:
 * 
 * - Multiple yield sources (Aave, Morpho, Lido, etc.) without core changes
 * - Independent evolution of yield logic
 * - Clean separation of concerns
 * - Reduced core contract bytecode
 * 
 * The module is called at key escrow lifecycle points:
 * - Creation: to configure yield settings
 * - Withdrawal/Release: to calculate and distribute yield
 * - Failure: to recover from unwind scenarios
 */
interface IYieldModule {
    
    /// @notice Initialize yield for a new escrow transfer
    /// @param workflowId Unique escrow identifier
    /// @param token Token address to yield on
    /// @param amount Initial amount to deposit for yield
    /// @param yieldMode Preset (OFF, TO_SENDER, TO_RECIPIENT, SPLIT, etc.)
    /// @return success Whether yield initialization succeeded
    /// @return initializedAmount Amount actually accepted for yielding
    function initializeYield(
        uint256 workflowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external returns (bool success, uint256 initializedAmount);
    
    /// @notice Handle yield generation and get actual withdrawal amount
    /// 
    /// Called when an escrow is released or cancelled to:
    /// 1. Calculate any generated yield
    /// 2. Distribute yield per the preset rules
    /// 3. Return the actual amount to withdraw (principal only)
    /// 
    /// @param workflowId Escrow identifier
    /// @param token Token to withdraw
    /// @param principalAmount Original escrow amount (not including yield)
    /// @return actualAmount Amount actually available to withdraw
    /// @return yieldAmount Amount generated as yield (may be 0)
    /// @return yieldDistributed Amount successfully distributed
    function handleYieldAndGetAmount(
        uint256 workflowId,
        address token,
        uint256 principalAmount
    ) external returns (
        uint256 actualAmount,
        uint256 yieldAmount,
        uint256 yieldDistributed
    );
    
    /// @notice Emergency unwind: recover escrow amount, discard yield
    /// 
    /// Called if yield operations fail in a way that might leave funds stuck.
    /// Should safely recover the original escrow amount.
    /// 
    /// @param workflowId Escrow identifier
    /// @param token Token to recover
    /// @param principalAmount Original amount to recover
    /// @return recoveredAmount Amount successfully recovered
    /// @return yieldAbandonedAmount Yield left behind (if any)
    function emergencyUnwind(
        uint256 workflowId,
        address token,
        uint256 principalAmount
    ) external returns (
        uint256 recoveredAmount,
        uint256 yieldAbandonedAmount
    );
    
    /// @notice Check if this module can handle the given configuration
    /// 
    /// Allows modules to refuse incompatible configurations before
    /// committing escrow funds.
    /// 
    /// @param token The token to yield on
    /// @param yieldMode The preset configuration
    /// @param amount Amount to yield on
    /// @return canHandle True if module can handle this configuration
    /// @return reason Error reason if canHandle is false
    function canHandle(
        address token,
        YieldPreset yieldMode,
        uint256 amount
    ) external view returns (bool canHandle, string memory reason);
    
    /// @notice Get metadata about this module
    /// @return name Human-readable name (e.g., "AaveYieldModule")
    /// @return version Version identifier (e.g., "1.0.0")
    /// @return protocolName Underlying protocol (e.g., "Aave", "Morpho")
    function getModuleInfo()
        external
        view
        returns (
            string memory name,
            string memory version,
            string memory protocolName
        );
}
```

### 2. Module Selection & Registration

**How modules are selected:**

1. **At Escrow Creation:**
   - Creator specifies `yieldMode` (OFF, TO_SENDER, etc.)
   - BaseEscrow looks up appropriate module via `ModuleSnapshotRegistry`
   - Module address is snapshotted (immutable per escrow)

2. **Module Discovery:**
   - Registry maps `(yieldMode, protocol)` → module address
   - Or: Uses a factory pattern to deploy per-escrow instances
   - Or: Module is pre-configured as "default for mode"

**Example with ModuleSnapshotRegistry:**

```solidity
// In ModuleSnapshotRegistry
mapping(bytes32 => mapping(YieldPreset => address)) public yieldModules;
// yieldModules[keccak256("aave")] -> YieldPreset.TO_SENDER -> AaveYieldModule address
```

### 3. BaseEscrow Integration (Minimal)

**New state in BaseEscrow:**

```solidity
// In ModuleSnapshot struct, add:
address yieldModule;  // Set at escrow creation, immutable after
```

**New thin delegation methods in BaseEscrow:**

```solidity
function _delegateYieldInitialization(
    uint256 workflowId,
    address token,
    uint256 amount,
    YieldPreset yieldMode
) internal returns (uint256 initializedAmount) {
    address mod = moduleSnapshots[workflowId].yieldModule;
    if (mod == address(0)) return amount;  // No yield, pass-through
    
    (bool ok, bytes memory ret) = mod.call(
        abi.encodeWithSelector(
            IYieldModule.initializeYield.selector,
            workflowId, token, amount, yieldMode
        )
    );
    if (!ok) return amount;  // Fall back to no yield if init fails
    
    (bool success, uint256 initialized) = abi.decode(ret, (bool, uint256));
    return success ? initialized : amount;
}

function _handleYieldAndGetActualAmount(
    uint256 workflowId,
    address token,
    uint256 amount
) internal returns (uint256) {
    address mod = moduleSnapshots[workflowId].yieldModule;
    if (mod == address(0)) return amount;  // No yield, return amount as-is
    
    (bool ok, bytes memory ret) = mod.call(
        abi.encodeWithSelector(
            IYieldModule.handleYieldAndGetAmount.selector,
            workflowId, token, amount
        )
    );
    
    if (!ok) {
        emit OperationFailure(2, workflowId, mod, ..., CALL_FAILED);
        return amount;  // Fall back: return principal on failure
    }
    
    (uint256 actualAmount, uint256 yield, uint256 distributed) = 
        abi.decode(ret, (uint256, uint256, uint256));
    
    emit YieldHandled(workflowId, yield, distributed);
    return actualAmount;
}

function _emergencyUnwindYield(
    uint256 workflowId,
    address token,
    uint256 principalAmount
) internal returns (uint256 recoveredAmount) {
    address mod = moduleSnapshots[workflowId].yieldModule;
    if (mod == address(0)) return principalAmount;
    
    (bool ok, bytes memory ret) = mod.call(
        abi.encodeWithSelector(
            IYieldModule.emergencyUnwind.selector,
            workflowId, token, principalAmount
        )
    );
    
    if (!ok) return principalAmount;
    
    (uint256 recovered, uint256 abandoned) = abi.decode(ret, (uint256, uint256));
    return recovered;
}
```

**Removed from BaseEscrow:**
- Entire `_handleYieldAndGetActualAmount()` implementation (~300 lines)
- YieldOps integration code
- YieldPresetLibrary functions
- Yield-specific validation

---

## Module Implementation Examples

### Example 1: AaveYieldModule (Reference Implementation)

**File:** `contracts/modules/yield/AaveYieldModule.sol`

This is what currently exists as embedded logic in BaseEscrow, now extracted:

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../../interfaces/IYieldModule.sol';
import '../YieldOps.sol';  // Reuse existing YieldOps for distribution logic

/**
 * @title AaveYieldModule
 * @notice Yield module for Aave-based yield generation.
 * 
 * Handles:
 * - Depositing tokens to Aave aToken pools
 * - Tracking yield over escrow duration
 * - Distributing yield to configured recipients
 * - Emergency recovery if yield operations fail
 */
contract AaveYieldModule is IYieldModule {
    
    // All current Aave integration logic moves here (~800 lines)
    // Including: _handleYieldAndGetActualAmount, distribution logic, etc.
    
    function initializeYield(
        uint256 workflowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external override returns (bool success, uint256 initializedAmount) {
        // Current aToken deposit logic
        // Returns (true, actualAmount) if successful
    }
    
    function handleYieldAndGetAmount(
        uint256 workflowId,
        address token,
        uint256 principalAmount
    ) external override returns (
        uint256 actualAmount,
        uint256 yieldAmount,
        uint256 yieldDistributed
    ) {
        // Current _handleYieldAndGetActualAmount logic
        // Now isolated and testable
    }
    
    function emergencyUnwind(
        uint256 workflowId,
        address token,
        uint256 principalAmount
    ) external override returns (
        uint256 recoveredAmount,
        uint256 yieldAbandonedAmount
    ) {
        // Current emergency recovery logic
    }
    
    function canHandle(
        address token,
        YieldPreset yieldMode,
        uint256 amount
    ) external view override returns (bool, string memory) {
        // Check Aave has this token, amount is reasonable, etc.
        if (!isAaveEnabled(token)) return (false, "Token not in Aave");
        if (amount < MIN_AAVE_AMOUNT) return (false, "Amount too small");
        return (true, "");
    }
    
    function getModuleInfo()
        external
        pure
        override
        returns (string memory, string memory, string memory)
    {
        return ("AaveYieldModule", "1.0.0", "Aave");
    }
}
```

### Example 2: MorphoYieldModule (Future, Fits Neatly)

**File:** `contracts/modules/yield/MorphoYieldModule.sol` (hypothetical future implementation)

```solidity
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../../interfaces/IYieldModule.sol';
import '@morpho-org/morpho-sdk/IMorphoMarketManager.sol';

/**
 * @title MorphoYieldModule
 * @notice Yield module for Morpho-based yield generation.
 * 
 * Demonstrates how easily new yield sources fit into the architecture.
 * Uses the exact same IYieldModule interface.
 */
contract MorphoYieldModule is IYieldModule {
    
    IMorphoMarketManager public morphoManager;
    
    function initializeYield(
        uint256 workflowId,
        address token,
        uint256 amount,
        YieldPreset yieldMode
    ) external override returns (bool success, uint256 initializedAmount) {
        // Deposit to Morpho market
        // Morpho is simpler than Aave, less bytecode needed
        uint256 shares = morphoManager.supply(token, amount);
        return (true, amount);
    }
    
    function handleYieldAndGetAmount(
        uint256 workflowId,
        address token,
        uint256 principalAmount
    ) external override returns (
        uint256 actualAmount,
        uint256 yieldAmount,
        uint256 yieldDistributed
    ) {
        // Withdraw from Morpho, calculate yield
        uint256 totalValue = morphoManager.totalSupplyValue(workflowId);
        uint256 yield = totalValue > principalAmount ? 
            totalValue - principalAmount : 0;
        
        // Distribute yield per preset rules
        // ...
        
        return (principalAmount, yield, yield);
    }
    
    function emergencyUnwind(
        uint256 workflowId,
        address token,
        uint256 principalAmount
    ) external override returns (uint256, uint256) {
        // Withdraw everything, return principal
        return (principalAmount, 0);
    }
    
    function canHandle(
        address token,
        YieldPreset yieldMode,
        uint256 amount
    ) external view override returns (bool, string memory) {
        if (!morphoManager.isMarketSupported(token)) 
            return (false, "Morpho: Token not supported");
        return (true, "");
    }
    
    function getModuleInfo()
        external
        pure
        override
        returns (string memory, string memory, string memory)
    {
        return ("MorphoYieldModule", "1.0.0", "Morpho");
    }
}
```

### Example 3: LidoYieldModule (Another Future Example)

```solidity
/**
 * @title LidoYieldModule
 * @notice Yield module for Lido stETH yield.
 * 
 * Handles ETH staking via Lido:
 * - Deposit ETH to Lido, receive stETH
 * - Track stETH balance growth (yield accumulation)
 * - Distribute staking rewards
 */
contract LidoYieldModule is IYieldModule {
    // Similar structure to MorphoYieldModule
    // Implements IYieldModule interface
    // Can coexist with AaveYieldModule without conflicts
}
```

---

## Compatibility Assessment: Multi-Yield Source Support

### Architecture is Naturally Compatible ✅

**Why:**

1. **Unified Interface**: All modules implement `IYieldModule`
   - Same methods, same return types
   - New protocols just implement the interface
   - No changes to BaseEscrow when adding new modules

2. **Module Registry Decouples Protocol**:
   ```solidity
   mapping(bytes32 => mapping(YieldPreset => address)) yieldModules;
   // Can have: aave_v3 -> AaveYieldModule
   //           morpho   -> MorphoYieldModule  
   //           lido     -> LidoYieldModule
   // All coexist, selected by creator preference
   ```

3. **Per-Escrow Module Immutability**:
   - Module address is snapshotted at creation
   - Different escrows can use different modules simultaneously
   - User chooses their preferred protocol at creation time

### Future-Proofing Strategy

**To add Morpho, Lido, Curve in the future:**

1. Create `MorphoYieldModule` implementing `IYieldModule` (~500-800 lines)
2. Register it in ModuleSnapshotRegistry
3. Update UI/SDK to show "Yield via Morpho" as an option
4. **Zero changes to BaseEscrow required**

**Comparison to monolithic design:**

| Aspect | Current (Monolithic) | New (Modular) |
|--------|----------------------|---------------|
| Add Morpho | Modify BaseEscrow (risky) | New contract only |
| Add Lido | Modify BaseEscrow (risky) | New contract only |
| Multiple protocols simultaneously | Not possible | Fully supported |
| Test isolation | Hard (mixed with core logic) | Easy (module in isolation) |
| Upgrade protocol | Redeploy core escrow | Redeploy module only |
| Bytecode impact | All contracts grow | Only module grows |

---

## Implementation Phases

### Phase 1: Interface Design (30 min)
- ✓ Define `IYieldModule` interface (done above)
- ✓ Plan module registry changes
- Estimated outcome: Interface spec ready for review

### Phase 2: Extract AaveYieldModule (2 hours)
- Move `_handleYieldAndGetActualAmount()` to AaveYieldModule
- Move Aave-specific logic from BaseEscrow
- Move YieldOps integration to module
- Implement `IYieldModule` interface

### Phase 3: Update BaseEscrow (1 hour)
- Remove embedded yield logic
- Add thin delegation methods
- Update ModuleSnapshot struct
- Add yieldModule parameter to creation

### Phase 4: Update ModuleRegistry (30 min)
- Register AaveYieldModule as default
- Support module selection at creation

### Phase 5: Update Child Contracts (30 min)
- EscrowVault: minimal changes
- EscrowableERC20: minimal changes
- BasicEscrowVault: inherits new structure
- BasicEscrowableERC20: inherits new structure

### Phase 6: Update Tests (2-3 hours)
- Move yield tests to AaveYieldModule tests
- Create mock IYieldModule for core tests
- Update integration tests

### Phase 7: Verify Bytecode (30 min)
- Compile all contracts
- Measure bytecode savings
- Verify targets met

### Phase 8: Full Test Suite (2-3 hours)
- Fix integration failures
- Run full test suite
- Verify all features work

**Total: 8-11 hours** (can be spread across 2 sessions)

---

## Expected Bytecode Changes

### Before Externalization
```
BaseEscrow (base):          ~24,000 B (with yield embedded)
  - Yield logic:            1,800-2,000 B
  - Core logic:             ~22,200 B

EscrowVault:                27,514 B (inherits BaseEscrow + yield)
EscrowableERC20:            28,163 B (inherits BaseEscrow + ERC20 + yield)
BasicEscrowVault:           24,598 B (inherits bloated parent)
BasicEscrowableERC20:       25,904 B (inherits bloated parent)
```

### After Externalization
```
BaseEscrow (base):          ~22,500 B (yield glue only)
  - Yield glue:             390 B (thin dispatcher)
  - Core logic:             ~22,200 B (unchanged)

AaveYieldModule:            ~3,000-3,500 B (extracted logic)
  - Aave integration:       ~2,000-2,500 B
  - Distribution logic:     ~800-1,000 B

EscrowVault:                25,914 B (-1,600 B, now fits with workaround)
EscrowableERC20:            26,563 B (-1,600 B, still needs L2)
BasicEscrowVault:           23,000 B ✅ COMPLIANT
BasicEscrowableERC20:       24,304 B ✅ COMPLIANT
```

---

## Risk Assessment

### Technical Risks: MEDIUM

| Risk | Mitigation |
|------|-----------|
| Module interface correctness | Follow IResolutionModule pattern; peer review before code |
| Delegation call failures | Graceful fallback to principal amount; emit event for debugging |
| Module version compatibility | Version field in getModuleInfo(); version check in registry |
| Gas overhead | One external call per yield operation; acceptable pattern in codebase |

### Breaking Change Risk: LOW

- **New escrows**: Module selected at creation, snapshotted
- **Old escrows**: Unaffected (module address immutable after creation)
- **No migration needed**: Old escrows work with old module, new with new

### Testing Risk: MEDIUM

- Current state: 71 failing tests (from recent changes)
- Expected after: 30-40 failures (module integration issues)
- Reason: Core logic is isolated, most failures auto-fixed
- Remediation: Module tests + integration tests, straightforward

---

## Monitoring & Observability

### New Events for Module Operations

```solidity
event YieldInitialized(
    uint256 indexed workflowId,
    address indexed yieldModule,
    uint256 amount,
    YieldPreset mode
);

event YieldHandled(
    uint256 indexed workflowId,
    uint256 yieldGenerated,
    uint256 yieldDistributed
);

event YieldModuleFailure(
    uint256 indexed workflowId,
    address indexed module,
    bytes reason,
    uint256 recoveredAmount
);
```

---

## Future Enhancements (Post-MVP)

1. **Module Factory Pattern**:
   - Deploy one module per escrow for isolation
   - Better accounting per-escrow
   - Enables complex yield strategies

2. **Yield Optimizer**:
   - Router that selects best yield protocol per token
   - Automatic rebalancing across modules
   - Dynamic protocol switching

3. **Composable Modules**:
   - Chain multiple protocols (Aave → Morpho → Lido)
   - Sophisticated yield strategies
   - Requires more complex interface

4. **Time-based Module Selection**:
   - Different modules for different escrow durations
   - Short-term: higher liquidity (Morpho)
   - Long-term: higher APY (stETH)

---

## Summary

This architecture:

✅ **Solves bytecode problem** - Lite variants now compliant
✅ **Enables Morpho, Lido, Curve** - Fits neatly into modular design
✅ **Follows existing patterns** - Similar to IResolutionModule
✅ **Separates concerns** - Yield logic is independent
✅ **Future-proof** - New modules without touching core
✅ **Backwards compatible** - Old escrows unaffected
✅ **Reasonable effort** - 8-11 hours to implement

Ready to proceed with implementation?
