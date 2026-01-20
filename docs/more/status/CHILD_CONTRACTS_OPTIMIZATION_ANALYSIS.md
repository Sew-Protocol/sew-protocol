# Child Contracts Optimization Analysis

**Date**: Current
**Goal**: Reduce EscrowVault and EscrowableERC20 below 24KB
**Current Status**:

- EscrowVault: 32,667 bytes (needs -8,667 bytes)
- EscrowableERC20: 33,420 bytes (needs -9,420 bytes)
  **Priority**: HIGH - Blocking mainnet deployment

---

## Analysis Summary

Both contracts share significant code duplication, particularly in module management functions. The largest optimization opportunities come from extracting common patterns into libraries.

---

## Major Optimization Opportunities

### 1. Module Management Library (HIGH PRIORITY - Estimated Savings: 4-5KB per contract)

**Problem**: Both contracts have identical patterns for managing 4 modules:

- `queueDefault[Module]()` - 4 functions per contract
- `activateDefault[Module]()` - 4 functions per contract
- `getPendingDefault[Module]()` - 4 functions per contract

**Duplication**:

- EscrowVault: ~200 lines of module management code
- EscrowableERC20: ~200 lines of module management code
- Total: ~400 lines duplicated across both contracts

**Solution**: Create `ModuleManagementLibrary.sol` that handles:

- Generic queue/activate/getPending for any module type
- Validation logic (address checks, ERC-165 checks)
- Event emission

**Estimated Savings**: 4-5KB per contract (8-10KB total)

**Implementation**:

```solidity
library ModuleManagementLibrary {
  function queueModule(
    PendingAddress storage pending,
    address newModule,
    address currentModule,
    bytes4 interfaceId, // For ERC-165 validation
    string memory moduleName
  ) internal returns (uint64 eta);

  function activateModule(
    PendingAddress storage pending,
    address currentModule,
    string memory moduleName
  ) internal returns (address oldModule, address newModule);

  function getPendingModule(
    PendingAddress storage pending
  ) internal view returns (address value, uint64 eta, bool exists);
}
```

**Risk**: Low - Pure refactoring, no logic changes

---

### 2. CreateEscrow Overload Consolidation (MEDIUM PRIORITY - Estimated Savings: 1-1.5KB per contract)

**Problem**: Both contracts have 3 `createEscrow` overloads:

1. `createEscrow(token/seller, amount, settings)` - Full version
2. `createEscrow(token/seller, amount, autoReleaseTime, autoCancelTime)` - Timing convenience
3. `createEscrow(token/seller, amount)` - Default convenience

**Solution**: Consolidate to single function with optional parameters or use a helper function.

**Current Code**:

```solidity
// EscrowVault - 3 overloads (~30 lines each = 90 lines)
function createEscrow(address token, address seller, uint256 amount, EscrowSettings memory settings)
function createEscrow(address token, address seller, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime)
function createEscrow(address token, address seller, uint256 amount)
```

**Optimized Approach**: Keep full version, make others thin wrappers that call it.

**Estimated Savings**: 1-1.5KB per contract (2-3KB total)

**Risk**: Low - Interface compatibility maintained

---

### 3. Module Getter Functions Simplification (LOW PRIORITY - Estimated Savings: 0.5-1KB per contract)

**Problem**: Both contracts have 4 identical getter functions that just return default modules:

```solidity
function getReleaseStrategy(uint256 workflowId) public view returns (IReleaseStrategy) {
  workflowId; // Silence unused parameter warning
  return defaultReleaseStrategy;
}
```

**Solution**:

- Option A: Remove `workflowId` parameter (breaking change)
- Option B: Keep but simplify (minimal savings)
- Option C: Consolidate into single function returning all modules

**Estimated Savings**: 0.5-1KB per contract (1-2KB total)

**Risk**: Medium - May break interface compatibility

---

### 4. Event Consolidation (LOW PRIORITY - Estimated Savings: 0.3-0.5KB per contract)

**Problem**: Both contracts emit similar events for module changes:

- `Default[Module]Queued` - 4 events per contract
- `Default[Module]Activated` - 4 events per contract
- `Default[Module]Set` - 2 events per contract (only yield modules)

**Solution**: Use generic events with module type parameter:

```solidity
event DefaultModuleQueued(
  bytes32 indexed moduleType,
  address indexed oldModule,
  address indexed newModule,
  uint64 eta
);
event DefaultModuleActivated(
  bytes32 indexed moduleType,
  address indexed oldModule,
  address indexed newModule
);
```

**Estimated Savings**: 0.3-0.5KB per contract (0.6-1KB total)

**Risk**: Medium - Breaking change for off-chain indexing

---

### 5. EscrowVault-Specific Optimizations

#### 5.1 Fee Withdrawal Functions (MEDIUM PRIORITY - Estimated Savings: 0.8-1.2KB)

**Problem**: `withdrawFees()` and `withdrawFeesBatch()` have similar logic.

**Solution**: Extract common logic to library or make `withdrawFees()` call `withdrawFeesBatch()`.

**Estimated Savings**: 0.8-1.2KB

**Risk**: Low

#### 5.2 Token Balance Tracking (LOW PRIORITY - Estimated Savings: 0.2-0.3KB)

**Problem**: `totalFeesPerToken` and `totalHeldInEscrowPerToken` mappings are straightforward but could be optimized.

**Solution**: Minimal - these are essential for functionality.

**Estimated Savings**: 0.2-0.3KB

**Risk**: Low

---

### 6. EscrowableERC20-Specific Optimizations

#### 6.1 Aave Pool Address Helper (LOW PRIORITY - Estimated Savings: 0.3-0.5KB)

**Problem**: `_getAavePoolAddress()` uses low-level call which adds complexity.

**Solution**: Extract to library or simplify if possible.

**Estimated Savings**: 0.3-0.5KB

**Risk**: Low

#### 6.2 Single Token Tracking (LOW PRIORITY - Estimated Savings: 0.1-0.2KB)

**Problem**: `totalHeldInEscrow` is simpler than EscrowVault's per-token tracking.

**Solution**: Already optimized.

**Estimated Savings**: Minimal

---

## Recommended Implementation Plan

### Phase 1: High-Impact Library Extraction (Target: 4-5KB per contract)

1. **Create ModuleManagementLibrary**
   - Extract queue/activate/getPending pattern
   - Handle validation and events generically
   - Refactor both contracts to use library

**Estimated Savings**: 4-5KB per contract
**Effort**: Medium (2-3 hours)
**Risk**: Low

### Phase 2: CreateEscrow Consolidation (Target: 1-1.5KB per contract)

2. **Simplify createEscrow overloads**
   - Keep full version as primary
   - Make convenience overloads thin wrappers
   - Reduce duplication

**Estimated Savings**: 1-1.5KB per contract
**Effort**: Low (1 hour)
**Risk**: Low

### Phase 3: Additional Optimizations (Target: 1-2KB per contract)

3. **Fee withdrawal optimization (EscrowVault)**
4. **Event consolidation (if acceptable)**
5. **Minor cleanup**

**Estimated Savings**: 1-2KB per contract
**Effort**: Low-Medium (1-2 hours)
**Risk**: Low-Medium

---

## Total Estimated Savings

| Phase     | EscrowVault | EscrowableERC20 | Total       |
| --------- | ----------- | --------------- | ----------- |
| Phase 1   | 4-5KB       | 4-5KB           | 8-10KB      |
| Phase 2   | 1-1.5KB     | 1-1.5KB         | 2-3KB       |
| Phase 3   | 1-2KB       | 1-2KB           | 2-4KB       |
| **Total** | **6-8.5KB** | **6-8.5KB**     | **12-17KB** |

**Remaining After Optimizations**:

- EscrowVault: 24,167-26,667 bytes (may still need 167-2,667 bytes more)
- EscrowableERC20: 24,920-27,420 bytes (may still need 920-3,420 bytes more)

---

## Alternative Approaches (If Still Over Limit)

### Option A: Split Module Management to External Contract

- Create `ModuleManager.sol` contract
- Both child contracts delegate module management to it
- **Savings**: ~5-6KB per contract
- **Risk**: Medium (additional contract, gas costs for calls)

### Option B: Remove Convenience Functions

- Remove `createEscrow` overloads (users call full version)
- Remove some getter functions
- **Savings**: ~2-3KB per contract
- **Risk**: Medium (UX degradation)

### Option C: Further BaseEscrow Optimization

- Continue optimizing BaseEscrow (affects both children)
- **Savings**: Variable
- **Risk**: Low-Medium

---

## Implementation Priority

1. **Phase 1 (ModuleManagementLibrary)** - Highest impact, lowest risk
2. **Phase 2 (CreateEscrow consolidation)** - Good savings, low risk
3. **Phase 3 (Additional optimizations)** - Incremental improvements

---

## Success Criteria

- EscrowVault < 24,576 bytes
- EscrowableERC20 < 24,576 bytes
- All tests pass
- No breaking interface changes (unless explicitly approved)
- Gas costs remain acceptable

---

**Status**: Analysis Complete, Ready for Implementation
**Last Updated**: Current
