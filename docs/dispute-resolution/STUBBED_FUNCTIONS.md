# Stubbed Functions Inventory

**Date**: 2025-01-XX  
**Status**: Current implementation review

---

## Stubbed Functions (Not Implemented)

### 1. `ResolverSlashingModuleV1.slashForFraud()`

**Location**: `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol:384-391`  
**Status**: ❌ **STUBBED**  
**Implementation**:

```solidity
function slashForFraud(
  uint256 workflowId,
  address resolver,
  bytes calldata evidence
) external returns (uint256 slashId) {
  // Fraud slashing not implemented yet
  revert('Not implemented');
}
```

**Reason**: Fraud proof verification is complex and requires off-chain evidence validation. Deferred to v3 fraud lane implementation.

**Impact**: Medium - Fraud slashing is a v3 feature, not critical for v1/v2 operations.

**Action**: Keep stub for interface compliance, implement in fraud lane module (Phase 4).

---

### 2. Counter-Party Compensation in Slash Distribution

**Location**: `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol:613`  
**Status**: ⚠️ **PARTIALLY STUBBED**  
**Implementation**:

```solidity
distribution.toCounterParty = 0; // Not implemented yet
```

**Reason**: Counter-party identification and compensation logic not yet implemented.

**Impact**: Medium - Users harmed by bad decisions don't receive compensation from slashes.

**Action**: Implement counter-party identification and payout logic (v3 enhancement).

---

### 3. Slash Proposer Rewards

**Location**: `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol:614`  
**Status**: ⚠️ **PARTIALLY STUBBED**  
**Implementation**:

```solidity
distribution.toSlashProposer = 0; // Not implemented yet
```

**Reason**: Slash proposer tracking and reward mechanism not yet implemented.

**Impact**: Low - Reduces incentive for reporting slashable behavior, but not critical.

**Action**: Implement slash proposer tracking and rewards (v3 enhancement).

---

### 4. Treasury Transfer in Slashing Module

**Location**: `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol:625`  
**Status**: ⚠️ **STUBBED**  
**Implementation**:

```solidity
// TODO: Transfer protocol portion to treasury (when treasury contract exists)
// For now, protocol portion remains in this contract
```

**Reason**: Treasury contract doesn't exist yet. Funds remain in slashing module contract.

**Impact**: Low - Funds are not lost, just not routed to treasury. Can be transferred manually or when treasury exists.

**Action**: Implement treasury transfer when treasury contract is deployed.

---

## Fixed Stubs (Previously Stubbed, Now Fixed)

### 1. `ResolverIncentiveModuleV2.getRequiredAppealBond()`

**Location**: `contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol:104-115`  
**Previous Status**: ❌ Returned misleading zeros  
**Current Status**: ✅ **FIXED** - Now reverts with clear message  
**Fix Applied**: Changed to revert with "Use IResolutionModule.getRequiredAppealBond() instead"

---

## Summary

### Active Stubs: 4

1. `slashForFraud()` - Fraud slashing (v3 feature)
2. Counter-party compensation - Not implemented
3. Slash proposer rewards - Not implemented
4. Treasury transfer - Waiting for treasury contract

### Fixed Stubs: 1

1. `getRequiredAppealBond()` - Now properly reverts

### Recommendations

- **Keep stubbed**: `slashForFraud()` (v3 feature)
- **Implement soon**: Counter-party compensation (medium priority)
- **Future enhancement**: Slash proposer rewards (low priority)
- **Wait for dependency**: Treasury transfer (low priority, depends on treasury contract)

---

**End of Inventory**
