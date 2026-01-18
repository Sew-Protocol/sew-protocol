# Governance Roles Consistency Review

**Date**: 2026-01-27  
**Status**: ✅ **COMPLETE**

---

## Overview

All contracts have been reviewed and updated to ensure consistent governance role usage. The principle is:

- **DEFAULT_ADMIN_ROLE**: Only for constructor initialization (transferred to TimelockController after deployment)
- **ROLE_TIMELOCK**: For all operational functions (governance-controlled, slow lane)
- **ROLE_GUARDIAN**: For emergency pause functions (fast lane, pause only)

---

## Contracts Updated

### 1. CreateOps.sol ✅

**Changes**:
- Added `ROLE_GUARDIAN` and `ROLE_TIMELOCK` constants
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`
- Split `setYieldDepositsPaused(bool)` into:
  - `pauseYieldDeposits(string reason)` - `ROLE_GUARDIAN` OR `ROLE_TIMELOCK`
  - `resumeYieldDeposits()` - `ROLE_TIMELOCK` only

**Pattern**: Guardian can pause (emergency), Timelock can pause/resume (governance)

---

### 2. BondCollector.sol ✅

**Changes**:
- Added `ROLE_TIMELOCK` constant
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`

**Functions**:
- `registerEscrowContract()`: `ROLE_TIMELOCK` only

---

### 3. SettlementOps.sol ✅

**Changes**:
- Added `ROLE_TIMELOCK` constant
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`

**Functions**:
- `registerEscrowContract()`: `ROLE_TIMELOCK` only

---

### 4. YieldOps.sol ✅

**Changes**:
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`
- Already had `ROLE_TIMELOCK` and `ROLE_GUARDIAN` constants

**Functions**:
- `registerEscrowContract()`: `ROLE_TIMELOCK` only

---

### 5. DisputeOps.sol ✅

**Changes**:
- Added `ROLE_TIMELOCK` constant
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`

**Functions**:
- `registerEscrowContract()`: `ROLE_TIMELOCK` only

---

### 6. ModuleManagementContract.sol ✅

**Changes**:
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`
- Already had `ROLE_TIMELOCK` constant

**Functions**:
- `registerEscrowContract()`: `ROLE_TIMELOCK` only

---

### 7. EscrowAdminContract.sol ✅

**Changes**:
- Changed `registerEscrowContract()` from `DEFAULT_ADMIN_ROLE` to `ROLE_TIMELOCK`
- Already had `ROLE_TIMELOCK` constant

**Functions**:
- `registerEscrowContract()`: `ROLE_TIMELOCK` only

---

## Contracts Already Consistent

These contracts already use the correct governance pattern:

- **BaseEscrow.sol**: Uses `ROLE_GUARDIAN` for pause, `ROLE_TIMELOCK` for unpause
- **DecentralizedResolutionModule.sol**: Uses `ROLE_TIMELOCK` for all operations
- **ResolverIncentiveModuleV1.sol**: Uses `ROLE_TIMELOCK` for all operations
- **ResolverStakingModuleV1.sol**: Uses `ROLE_TIMELOCK` for all operations
- **KlerosArbitrableProxy.sol**: Uses `ROLE_TIMELOCK` for registration

---

## Governance Pattern Summary

### Role Usage

| Role | Purpose | Usage |
|------|---------|-------|
| `DEFAULT_ADMIN_ROLE` | Initial setup only | Constructor grants to deployer, then transferred to TimelockController |
| `ROLE_TIMELOCK` | Governance (slow lane) | All operational functions, pause/resume, parameter updates |
| `ROLE_GUARDIAN` | Emergency (fast lane) | Pause only (cannot unpause) |

### Function Patterns

**Registration Functions**:
```solidity
function registerEscrowContract(address escrow) external onlyRole(ROLE_TIMELOCK) {
    // ...
}
```

**Emergency Pause** (if applicable):
```solidity
function pause(string memory reason) external {
    if (!hasRole(ROLE_TIMELOCK, msg.sender) && !hasRole(ROLE_GUARDIAN, msg.sender)) {
        revert NotAuthorized(msg.sender);
    }
    // ...
}
```

**Resume** (if applicable):
```solidity
function resume() external onlyRole(ROLE_TIMELOCK) {
    // Guardian cannot resume (down-only control)
    // ...
}
```

---

## Deployment Impact

All updated contracts are included in `deploy/60_protocol_governance.ts`:
- `CreateOps`
- `SettlementOps`
- `DisputeOps`
- `YieldOps`
- `BondCollector`
- `ModuleManagementContract`

The deployment script will:
1. Grant `ROLE_TIMELOCK` to TimelockController (if contract supports it)
2. Grant `ROLE_GUARDIAN` to Guardian multisig (if contract supports it)
3. Transfer `DEFAULT_ADMIN_ROLE` from deployer to TimelockController

---

## Verification Checklist

- [x] All ops contracts use `ROLE_TIMELOCK` for `registerEscrowContract()`
- [x] All contracts have `ROLE_TIMELOCK` constant defined (if needed)
- [x] Emergency pause functions allow both `ROLE_GUARDIAN` and `ROLE_TIMELOCK`
- [x] Resume functions only allow `ROLE_TIMELOCK`
- [x] `DEFAULT_ADMIN_ROLE` only used in constructors
- [x] All contracts compile successfully
- [x] Deployment scripts updated

---

## Status

✅ **ALL CONTRACTS NOW USE CONSISTENT GOVERNANCE ROLES**

**Last Updated**: 2026-01-27
