# Yield Module Architecture - Generation vs Distribution

## Overview

This document explains the v2.5 yield module architecture, specifically why yield generation and distribution are separated into different modules, and the naming conventions used.

---

## Why Separate Generation and Distribution?

### Design Principle: Separation of Concerns

The v2.5 architecture separates yield operations into two distinct responsibilities:

| Concern          | Module                    | Responsibility                                                          |
| ---------------- | ------------------------- | ----------------------------------------------------------------------- |
| **Generation**   | Yield Generation Module   | Deposits funds to external protocol (Aave), tracks positions, withdraws |
| **Distribution** | Yield Distribution Module | Routes yield to recipients (seller, buyer, protocol)                    |

### Why This Separation Matters

1. **Module Simplicity**
   - Each module has a single, focused responsibility
   - Easier to audit and reason about
   - Smaller attack surface

2. **Policy Consistency**
   - Distribution policy lives in core (EscrowVault), not in modules
   - One source of truth for how yield is split
   - Escrow settings determine distribution, not module logic

3. **Fund Safety**
   - Clear invariants: generation modules only return funds to caller
   - Distribution modules only send to configured recipients
   - No ambiguous states where funds could be redirected

4. **Easy Extensibility**
   - Add new yield protocols (Aave → Morpho → EigenLayer) without touching distribution
   - Swap distribution strategies without changing yield generation
   - Independent upgrade paths

### The Flow

```
Escrow Creation
      │
      ▼
Escrow transfers principal to Yield Generation Module
      │
      ▼
Yield Generation Module deposits to Aave (tracks position)
      │
      ▼
Escrow Release/Cancel
      │
      ▼
Yield Generation Module withdraws from Aave → returns to Escrow
      │
      ▼
Escrow calculates yield (principal out, yield = total - principal)
      │
      ▼
Escrow calls Yield Distribution Module to route yield
      │
      ▼
Yield Distribution Module sends to recipients per escrow settings
```

---

## Module Naming Convention

### Before v2.5 (Legacy)

```
AaveYieldGenerationModule    ← "Generation" explicitly in name
DefaultYieldGenerationModule ← Same pattern
DefaultYieldDistributionModule ← Explicitly "Distribution"
```

### v2.5 and After

```
AaveYieldModule              ← Implements IYieldModule (generation is implicit)
DefaultYieldGenerationModule ← Still explicit for the no-op variant
DefaultYieldDistributionModule ← Explicit (distribution is separate concern)
```

### Why the Change?

1. **Unified Interface**: Created `IYieldModule` - a single interface for ALL yield generation modules
2. **Implicity of "Generation"**: Since modules implementing `IYieldModule` are by definition yield generation modules, the "Generation" suffix is redundant for the primary implementation
3. **Consistency**: The main Aave implementation is just `AaveYieldModule` (implements IYieldModule), while fallback implementations keep explicit names

### Current Modules

| Module                           | Interface                  | Handles Generation | Handles Distribution |
| -------------------------------- | -------------------------- | ------------------ | -------------------- |
| `AaveYieldModule`                | `IYieldModule`             | ✅ Yes             | ❌ No                |
| `DefaultYieldGenerationModule`   | `IYieldGenerationModule`   | ✅ Yes (no-op)     | ❌ No                |
| `DefaultYieldDistributionModule` | `IYieldDistributionModule` | ❌ No              | ✅ Yes               |

---

## Interface Definitions

### IYieldModule (Generation)

```solidity
interface IYieldModule {
    function initializeYield(...) external returns (uint256 accepted);
    function unwindToEscrow(...) external returns (uint256 principalOut, uint256 yieldOut);
    function emergencyUnwind(...) external returns (uint256 recovered);
    function canHandle(...) external view returns (...);
    function getModuleInfo() external view returns (string name, string version, bytes32 protocolId);
}
```

### IYieldDistributionModule (Distribution)

```solidity
interface IYieldDistributionModule {
    function distributeYield(...) external returns (bool success, uint256 distributedAmount);
    function moduleVersion() external pure returns (string version);
}
```

---

## Metadata Functions

Each module exposes version information for debugging and upgrade tracking:

### AaveYieldModule

```solidity
string public constant MODULE_NAME = "AaveYieldModule";
string public constant MODULE_VERSION = "2.5.0";
bytes32 public constant PROTOCOL_ID = keccak256("aave-v3");

function getModuleInfo() external view returns (string memory name, string memory version, bytes32 protocolId)
```

### DefaultYieldGenerationModule

```solidity
function moduleName() external pure returns (string memory name); // "DefaultYieldGenerationModule"
function moduleVersion() external pure returns (string memory version); // "1.0.0"
```

### DefaultYieldDistributionModule

```solidity
function moduleVersion() external pure returns (string memory version); // "1.0.0"
```

---

## Singleton Pattern

All yield modules use the **singleton pattern**:

- One deployed instance of each module serves **multiple escrow contracts**
- Each escrow references modules via snapshot at creation time
- Module state is namespaced by `(escrowAddress, escrowId)` to prevent collisions

This is more gas-efficient than per-escrow module deployments and simplifies governance (one upgrade affects all).

---

## Related Documentation

- [IYieldModule Interface](../interfaces/IYieldModule.sol)
- [AaveYieldModule](../modules/AaveYieldModule.sol)
- [DefaultYieldGenerationModule](../modules/DefaultYieldGenerationModule.sol)
- [DefaultYieldDistributionModule](../modules/DefaultYieldDistributionModule.sol)
- [InvariantGuard Integration](./INVARIANT_GUARD_INTEGRATION.md) - For delegatecall-based patterns
