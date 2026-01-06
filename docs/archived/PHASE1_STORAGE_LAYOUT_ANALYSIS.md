# Phase 1.1: Storage Layout Analysis

**Date**: 2025-01-XX  
**Status**: Analysis Complete  
**Contract**: `DecentralizedResolutionModule.sol`

---

## Executive Summary

This document provides a comprehensive analysis of the storage layout for `DecentralizedResolutionModule` to ensure safe upgrades via proxy pattern. All state variables are mapped to their storage slots, and potential risks are identified.

**Total State Variables**: 25+ mappings + 4 arrays + 5 single values  
**Estimated Storage Slots**: ~50+ (excluding dynamic arrays and mappings)  
**Risk Level**: Medium (complex state structure, but well-organized)

---

## Storage Layout Mapping

### Inherited Contracts Storage

#### AccessControl (OpenZeppelin)
- **Slot 0**: `_roles` (mapping(bytes32 => RoleData))
- **Slot 1**: Reserved for future use

#### ReentrancyGuard (OpenZeppelin)
- **Slot 2**: `_status` (uint256) - ReentrancyGuard status

#### SlowLaneQueueActivate
- **No storage** (abstract contract, only functions)

**Total Inherited Slots**: 3

---

### DecentralizedResolutionModule State Variables

#### Constants (No Storage)
- `ROLE_TIMELOCK` (bytes32 constant)
- `MAX_ESCALATION_LEVEL` (uint8 constant)
- `BASIS_POINTS_DENOMINATOR` (uint256 constant)
- `DEFAULT_DISPUTE_TIMEOUT` (uint256 constant)
- `MAX_DISPUTE_TIMEOUT` (uint256 constant)
- `INITIAL_ESCALATION_LEVEL` (uint8 constant)
- `SENIOR_ESCALATION_LEVEL` (uint8 constant)
- `EXTERNAL_ESCALATION_LEVEL` (uint8 constant)

**Note**: Constants don't use storage slots.

---

#### Single Value State Variables

| Slot | Variable | Type | Size | Notes |
|------|----------|------|------|-------|
| 3 | `disputeTimeout` | uint256 | 32 bytes | Configurable timeout |
| 4 | `externalResolver` | address | 20 bytes | External resolver address |
| 5 | `incentiveModule` | address | 20 bytes | ResolverIncentiveModule address |

**Total Single Value Slots**: 3

---

#### Array State Variables

| Slot | Variable | Type | Storage | Notes |
|------|----------|------|---------|-------|
| 6 | `approvedResolvers` | address[] | Keccak256(6) | Dynamic array, length at slot 6 |
| 7 | `approvedSeniorResolvers` | address[] | Keccak256(7) | Dynamic array, length at slot 7 |

**Array Storage**:
- Length stored at slot (6, 7)
- Elements stored at `keccak256(slot) + index`
- Each element = 1 slot (20 bytes address, padded to 32 bytes)

**Total Array Slots**: 2 (length slots) + dynamic elements

---

#### Mapping State Variables

**Resolver Registry Mappings**:
| Slot | Variable | Key Type | Value Type | Storage Location |
|------|----------|----------|------------|------------------|
| 8 | `resolverRoles` | address | ResolverRole (enum) | keccak256(key, 8) |
| 9 | `isApprovedResolver` | address | bool | keccak256(key, 9) |
| 10 | `isApprovedSeniorResolver` | address | bool | keccak256(key, 10) |
| 11 | `resolverMetadata` | address | ResolverMetadata (struct) | keccak256(key, 11) |
| 12 | `resolverActive` | address | bool | keccak256(key, 12) |
| 13 | `resolverLastActive` | address | uint256 | keccak256(key, 13) |
| 14 | `resolverActiveDisputes` | address | uint256 | keccak256(key, 14) |
| 15 | `resolverCapacity` | address | ResolverCapacity (struct) | keccak256(key, 15) |
| 16 | `resolverStats` | address | ResolverStats (struct) | keccak256(key, 16) |
| 17 | `resolverIndex` | address | uint256 | keccak256(key, 17) |
| 18 | `seniorResolverIndex` | address | uint256 | keccak256(key, 18) |

**Dispute Mappings**:
| Slot | Variable | Key Type | Value Type | Storage Location |
|------|----------|----------|------------|------------------|
| 19 | `disputeMetadata` | uint256 | DisputeMetadata (struct) | keccak256(key, 19) |
| 20 | `escrowCategory` | uint256 | bytes32 | keccak256(key, 20) |

**Configuration Mappings**:
| Slot | Variable | Key Type | Value Type | Storage Location |
|------|----------|----------|------------|------------------|
| 21 | `escalationConfig` | uint8 | EscalationConfig (struct) | keccak256(key, 21) |
| 22 | `_pendingEscalationConfig` | uint8 | PendingEscalationConfig (struct) | keccak256(key, 22) |
| 23 | `resolutionTable` | bytes32 | ResolutionTableEntry (struct) | keccak256(key, 23) |

**Round-Robin Mappings**:
| Slot | Variable | Key Type | Value Type | Storage Location |
|------|----------|----------|------------|------------------|
| 24 | `categoryResolverIndex` | bytes32 | uint256 | keccak256(key, 24) |
| 25 | `categorySeniorResolverIndex` | bytes32 | uint256 | keccak256(key, 25) |

**Access Control Mappings**:
| Slot | Variable | Key Type | Value Type | Storage Location |
|------|----------|----------|------------|------------------|
| 26 | `registeredEscrowContracts` | address | bool | keccak256(key, 26) |

**Total Mapping Slots**: 19

---

### Struct Storage Layouts

#### ResolverMetadata (Slot 11)
```solidity
struct ResolverMetadata {
    string name;           // Slot: keccak256(key, 11) + 0 (length), +1+ (data)
    string description;    // Slot: keccak256(key, 11) + N (length), +N+1+ (data)
    uint256 appointedAt;  // Slot: keccak256(key, 11) + M
    address appointedBy;  // Slot: keccak256(key, 11) + M + 1 (packed with bool)
    bool active;          // Slot: keccak256(key, 11) + M + 1 (packed with address)
}
```
**Storage**: Dynamic (strings use dynamic storage)

#### DisputeMetadata (Slot 19)
```solidity
struct DisputeMetadata {
    address currentResolver;           // Slot: keccak256(key, 19) + 0
    uint8 escalationLevel;            // Slot: keccak256(key, 19) + 1 (packed)
    address escalatedBy;               // Slot: keccak256(key, 19) + 1 (packed with uint8)
    uint256 escalationTimestamp;       // Slot: keccak256(key, 19) + 2
    uint256 timeoutTimestamp;          // Slot: keccak256(key, 19) + 3
    bytes resolutionData;               // Slot: keccak256(key, 19) + 4 (length), +5+ (data)
    ResolutionOutcome lastResolutionOutcome; // Slot: keccak256(key, 19) + N (enum = uint8)
    address lastResolver;               // Slot: keccak256(key, 19) + N + 1
}
```
**Storage**: ~6-10 slots per dispute (depending on resolutionData size)

#### ResolverCapacity (Slot 15)
```solidity
struct ResolverCapacity {
    uint256 maxConcurrentDisputes;  // Slot: keccak256(key, 15) + 0
    uint256 currentDisputes;        // Slot: keccak256(key, 15) + 1
    bool acceptsNewDisputes;         // Slot: keccak256(key, 15) + 2 (packed)
}
```
**Storage**: 3 slots per resolver

#### ResolverStats (Slot 16)
```solidity
struct ResolverStats {
    uint256 disputesResolved;           // Slot: keccak256(key, 16) + 0
    uint256 disputesEscalated;           // Slot: keccak256(key, 16) + 1
    uint256 resolutionReversals;         // Slot: keccak256(key, 16) + 2
    uint256 totalResolutionTime;       // Slot: keccak256(key, 16) + 3
    uint256 lastResolutionTimestamp;    // Slot: keccak256(key, 16) + 4
    uint256 qualityScore;               // Slot: keccak256(key, 16) + 5
    uint256 totalDisputes;              // Slot: keccak256(key, 16) + 6
}
```
**Storage**: 7 slots per resolver

#### EscalationConfig (Slot 21)
```solidity
struct EscalationConfig {
    address resolver;  // Slot: keccak256(key, 21) + 0
    uint256 fee;      // Slot: keccak256(key, 21) + 1
    bool enabled;     // Slot: keccak256(key, 21) + 2 (packed)
}
```
**Storage**: 3 slots per level

#### PendingEscalationConfig (Slot 22)
```solidity
struct PendingEscalationConfig {
    uint8 level;              // Slot: keccak256(key, 22) + 0 (packed)
    EscalationConfig config;  // Slot: keccak256(key, 22) + 1-3 (nested struct)
    uint64 eta;               // Slot: keccak256(key, 22) + 4 (packed)
    bool exists;              // Slot: keccak256(key, 22) + 4 (packed with uint64)
}
```
**Storage**: 5 slots per pending config

#### ResolutionTableEntry (Slot 23)
```solidity
struct ResolutionTableEntry {
    address initialResolver;      // Slot: keccak256(key, 23) + 0
    uint8 maxEscalationLevel;     // Slot: keccak256(key, 23) + 1 (packed)
    uint256 escalationFee;       // Slot: keccak256(key, 23) + 2
    bool enabled;                 // Slot: keccak256(key, 23) + 3 (packed)
    string categoryName;          // Slot: keccak256(key, 23) + 4+ (dynamic)
}
```
**Storage**: ~5+ slots per category (depending on categoryName length)

---

## Storage Slot Summary

### Sequential Slots (0-26)
- **0-2**: Inherited contracts (AccessControl, ReentrancyGuard)
- **3-5**: Single value variables
- **6-7**: Array length slots
- **8-26**: Mapping slots

### Dynamic Storage
- **Arrays**: Elements stored at `keccak256(slot) + index`
- **Mappings**: Values stored at `keccak256(key, slot)`
- **Strings/Bytes**: Length at slot, data at `keccak256(slot) + 1+`

---

## Storage Layout Risks

### ✅ Low Risk

1. **Well-Organized Structure**: State variables are logically grouped
2. **No Storage Collisions**: Each variable has unique slot
3. **Clear Slot Assignment**: Sequential slots, no gaps

### ⚠️ Medium Risk

1. **Struct Packing**: Some structs use packing (uint8 + address), must preserve order
2. **Dynamic Arrays**: Array growth doesn't affect other variables
3. **String Storage**: Dynamic strings use separate storage, safe to modify

### ❌ High Risk (Requires Attention)

1. **Struct Field Order**: Cannot reorder struct fields
2. **Enum Values**: Cannot change enum values (must append only)
3. **Inherited Contracts**: Must maintain AccessControl/ReentrancyGuard slots

---

## Upgrade Compatibility Requirements

### ✅ Safe to Add

- New mappings (new slots)
- New single value variables (new slots)
- New arrays (new slots)
- New struct fields (append only, at end)
- New enum values (append only)

### ❌ Unsafe to Change

- Reorder existing state variables
- Reorder struct fields
- Change enum values (can only append)
- Remove state variables (leave as unused)
- Change variable types (except compatible types)

### ⚠️ Requires Care

- Modify struct fields (must append, not reorder)
- Change mapping key/value types
- Modify array element types

---

## Storage Gap Recommendation

**Recommended Storage Gap**: 50 slots

```solidity
uint256[50] private __gap;
```

**Rationale**:
- Provides room for ~50 new state variables
- Allows for future expansion
- Standard practice for upgradeable contracts

**Placement**: After all state variables, before functions

---

## Storage Layout Verification

### Automated Checks

```bash
# Verify storage layout compatibility
npx hardhat verify-storage-layout \
  --contract DecentralizedResolutionModule \
  --new DecentralizedResolutionModuleV2
```

### Manual Verification Checklist

- [ ] All existing state variables preserved
- [ ] No reordering of state variables
- [ ] No reordering of struct fields
- [ ] New variables appended only
- [ ] Storage gap added
- [ ] Inherited contract slots preserved

---

## Migration Considerations

### State Preservation

**All State Will Be Preserved**:
- ✅ Resolver registries
- ✅ Dispute metadata
- ✅ Resolver statistics
- ✅ Configuration
- ✅ Round-robin counters

**No Migration Needed**: Proxy upgrades preserve all state automatically.

---

## Recommendations

1. **Add Storage Gap**: Reserve 50 slots for future expansion
2. **Document All Changes**: Track all storage layout changes
3. **Automated Checks**: Use storage layout verification tools
4. **Test Upgrades**: Comprehensive upgrade testing
5. **Version Control**: Track storage layout versions

---

## Next Steps

1. Verify storage layout with compiler
2. Create storage layout diagram
3. Document upgrade compatibility rules
4. Add storage gap to contract
5. Create storage layout test suite

---

*This analysis should be updated whenever state variables are added or modified.*

