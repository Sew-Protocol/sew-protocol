# Module Developer Role - Scope Analysis

**Date**: 2025-01-XX  
**Status**: Analysis  
**Purpose**: Analyze the scoped permissions of the module developer role and identify potential issues

---

## Role Scope Definition

### ✅ What Module Developer Role CAN Do

1. **Upgrade DecentralizedResolutionModule Implementation**
   - Upgrade the UUPS proxy implementation
   - Change internal logic, add features, fix bugs
   - Preserve all state (resolvers, disputes, stats, config)

2. **Upgrade Internal Dependencies**
   - Upgrade ResolverIncentiveModule (if upgradeable)
   - Upgrade PaymentCalculationLibrary (if upgradeable)
   - Change internal module references

### ❌ What Module Developer Role CANNOT Do

1. **Cannot Swap Modules in BaseEscrow**
   - Cannot change `resolutionModule` address in BaseEscrow
   - Cannot bypass slow-lane queue/activate process
   - Cannot swap to a different module entirely

2. **Cannot Bypass Governance**
   - Cannot perform standard-lane actions (requires `ROLE_TIMELOCK`)
   - Cannot perform slow-lane actions (requires `ROLE_TIMELOCK`)
   - Cannot modify governance parameters

3. **Cannot Swap Other Modules**
   - Cannot change release strategy module
   - Cannot change yield generation module
   - Cannot change yield distribution module

4. **Cannot Modify Access Control**
   - Cannot grant/revoke roles
   - Cannot change role permissions
   - Cannot escalate privileges

---

## Current Architecture

### Module Relationships

```
BaseEscrow
  └── resolutionModule (address) → DecentralizedResolutionModule (proxy)
        ├── incentiveModule (address) → ResolverIncentiveModule
        └── paymentLibrary (via incentiveModule) → PaymentCalculationLibraryV1
```

### Upgrade Authorization

**DecentralizedResolutionModule**:
- `_authorizeUpgrade()` allows `ROLE_TIMELOCK` OR `ROLE_MODULE_DEVELOPER`
- Can upgrade its own implementation

**BaseEscrow Module Swapping**:
- `queueResolutionModule()` requires `ROLE_TIMELOCK` (slow-lane)
- `activateResolutionModule()` requires `ROLE_TIMELOCK` (slow-lane)
- Module developer role does NOT have `ROLE_TIMELOCK` → cannot swap

**ResolverIncentiveModule**:
- Currently not upgradeable (needs analysis)
- If upgradeable, who controls upgrades?

**PaymentCalculationLibrary**:
- Currently a contract (not library)
- Can be swapped via ResolverIncentiveModule governance
- Module developer role cannot directly upgrade

---

## Potential Issues

### ⚠️ Issue 1: ResolverIncentiveModule Upgrade Control

**Problem**: 
- ResolverIncentiveModule is a separate contract
- DecentralizedResolutionModule references it via `incentiveModule` address
- If ResolverIncentiveModule becomes upgradeable, who controls its upgrades?

**Current State**:
- ResolverIncentiveModule is NOT upgradeable (uses constructor)
- It can swap payment libraries via governance (`ROLE_TIMELOCK`)

**Question**: Should module developer role be able to upgrade ResolverIncentiveModule?

**Options**:
1. **Option A**: ResolverIncentiveModule remains non-upgradeable
   - Pros: Clear separation, governance controls library swaps
   - Cons: Cannot fix bugs in incentive module quickly

2. **Option B**: ResolverIncentiveModule becomes upgradeable, controlled by module developer role
   - Pros: Can fix bugs quickly, maintains internal consistency
   - Cons: Requires ResolverIncentiveModule to also grant module developer role

3. **Option C**: ResolverIncentiveModule becomes upgradeable, controlled by its own governance
   - Pros: Independent governance
   - Cons: Two separate upgrade paths, potential coordination issues

**Recommendation**: **Option B** - Make ResolverIncentiveModule upgradeable and grant module developer role on it. This maintains the "internal dependency" principle.

---

### ⚠️ Issue 2: PaymentCalculationLibrary Upgrade Control

**Problem**:
- PaymentCalculationLibrary is swapped via ResolverIncentiveModule governance
- Current process: `queuePaymentLibrary()` → `activatePaymentLibrary()` (slow-lane)
- Module developer role cannot bypass this

**Current State**:
- Library swapping requires `ROLE_TIMELOCK` (slow-lane)
- Module developer role does not have `ROLE_TIMELOCK`

**Question**: Should module developer role be able to swap payment libraries instantly?

**Options**:
1. **Option A**: Keep slow-lane for library swaps
   - Pros: Governance oversight for payment logic changes
   - Cons: Cannot fix payment bugs quickly

2. **Option B**: Allow module developer to swap libraries instantly
   - Pros: Can fix payment bugs quickly
   - Cons: Payment logic changes without governance review

**Recommendation**: **Option B** - Allow module developer to swap libraries instantly, but require disclosure. Payment calculation is an internal implementation detail of the resolution system.

---

### ⚠️ Issue 3: Role Scope Clarity

**Problem**:
- Module developer role is defined on DecentralizedResolutionModule
- But it needs to control upgrades of ResolverIncentiveModule
- This requires ResolverIncentiveModule to also recognize the role

**Solution**:
- ResolverIncentiveModule should also have `ROLE_MODULE_DEVELOPER`
- Same role constant (keccak256 hash) across contracts
- Module developer role granted on both contracts

**Implementation**:
```solidity
// In both DecentralizedResolutionModule and ResolverIncentiveModule
bytes32 public constant ROLE_MODULE_DEVELOPER = keccak256("ROLE_MODULE_DEVELOPER");

// In ResolverIncentiveModule upgrade authorization
function _authorizeUpgrade(address newImplementation) 
    internal 
    override 
{
    require(
        hasRole(ROLE_TIMELOCK, _msgSender()) || 
        hasRole(ROLE_MODULE_DEVELOPER, _msgSender()),
        "Not authorized to upgrade"
    );
}
```

---

### ⚠️ Issue 4: Library Swapping Authorization

**Problem**:
- ResolverIncentiveModule has `queuePaymentLibrary()` and `activatePaymentLibrary()`
- Both require `ROLE_TIMELOCK` (slow-lane)
- Module developer role cannot bypass this

**Solution**:
- Add instant library swap function for module developer role
- Or modify existing functions to allow module developer role

**Implementation**:
```solidity
// In ResolverIncentiveModule
function swapPaymentLibraryInstant(address newLibrary) 
    external 
    onlyRole(ROLE_MODULE_DEVELOPER) 
{
    // Validate library
    require(IPaymentCalculationLibrary(newLibrary).version() > 0, "Invalid library");
    
    // Swap immediately (no queue)
    address oldLibrary = address(paymentLibrary);
    paymentLibrary = IPaymentCalculationLibrary(newLibrary);
    
    emit PaymentLibrarySwapped(oldLibrary, newLibrary, _msgSender(), block.timestamp);
}
```

---

### ⚠️ Issue 5: State Consistency

**Problem**:
- If module developer upgrades DecentralizedResolutionModule
- But ResolverIncentiveModule is not upgraded to match
- Could cause interface mismatches or state inconsistencies

**Mitigation**:
- Comprehensive testing before upgrades
- Interface versioning
- Upgrade both contracts together if needed

---

## Recommended Improvements

### 1. Make ResolverIncentiveModule Upgradeable

**Rationale**: 
- It's an internal dependency of DecentralizedResolutionModule
- Module developer should be able to fix bugs quickly
- Maintains internal consistency

**Implementation**:
- Convert ResolverIncentiveModule to UUPS upgradeable
- Grant module developer role on it
- Allow instant upgrades (same as DecentralizedResolutionModule)

---

### 2. Allow Instant Library Swapping

**Rationale**:
- Payment calculation is an internal implementation detail
- Module developer should be able to fix payment bugs quickly
- Disclosure process provides transparency

**Implementation**:
- Add `swapPaymentLibraryInstant()` function
- Requires `ROLE_MODULE_DEVELOPER`
- Emits event for transparency
- Still requires disclosure

---

### 3. Role Granting Strategy

**Rationale**:
- Module developer role should be granted on all internal dependencies
- Ensures consistent upgrade control
- Maintains "internal dependency" principle

**Implementation**:
- Grant `ROLE_MODULE_DEVELOPER` on:
  - DecentralizedResolutionModule (proxy)
  - ResolverIncentiveModule (if upgradeable)
- Use same role constant across contracts

---

### 4. Clear Scope Documentation

**Rationale**:
- Prevents confusion about what module developer can/cannot do
- Helps governance understand boundaries
- Aids in security review

**Implementation**:
- Document exact permissions
- List all functions module developer can call
- List all functions module developer cannot call
- Provide examples

---

### 5. Upgrade Coordination

**Rationale**:
- Internal dependencies may need coordinated upgrades
- Module developer should be able to upgrade multiple contracts atomically

**Implementation**:
- Create upgrade script that upgrades:
  - DecentralizedResolutionModule
  - ResolverIncentiveModule (if needed)
  - Swaps payment library (if needed)
- All in one transaction (if possible) or coordinated sequence

---

## Security Considerations

### ✅ Protections Maintained

1. **Cannot Swap Modules**: Module developer cannot change which module BaseEscrow uses
2. **Cannot Bypass Governance**: Standard/slow-lane actions still require `ROLE_TIMELOCK`
3. **Cannot Modify Access Control**: Role cannot grant/revoke other roles
4. **Storage Safety**: Storage layout mismatches cause obvious failures
5. **Transparency**: Events emitted for all upgrades

### ⚠️ New Considerations

1. **Internal Dependency Upgrades**: ResolverIncentiveModule upgrades need same security rigor
2. **Library Swaps**: Payment library swaps need validation and disclosure
3. **Coordination**: Multiple contract upgrades need careful coordination

---

## Implementation Checklist

### Phase 1: Scope Definition
- [x] Define exact permissions
- [x] Document what can/cannot be done
- [x] Identify internal dependencies

### Phase 2: ResolverIncentiveModule Upgradeability
- [ ] Convert ResolverIncentiveModule to UUPS upgradeable
- [ ] Add `ROLE_MODULE_DEVELOPER` to ResolverIncentiveModule
- [ ] Update upgrade authorization
- [ ] Test upgrade process

### Phase 3: Library Swapping
- [ ] Add instant library swap function
- [ ] Add `ROLE_MODULE_DEVELOPER` authorization
- [ ] Add event emission
- [ ] Test swap process

### Phase 4: Role Granting
- [ ] Grant `ROLE_MODULE_DEVELOPER` on DecentralizedResolutionModule
- [ ] Grant `ROLE_MODULE_DEVELOPER` on ResolverIncentiveModule
- [ ] Verify role grants
- [ ] Document role holders

### Phase 5: Documentation
- [ ] Update role design document
- [ ] Document internal dependency upgrades
- [ ] Create upgrade coordination guide
- [ ] Update security considerations

---

## Summary

### Current Scope (As Defined)
- ✅ Can upgrade DecentralizedResolutionModule implementation
- ✅ Can upgrade internal dependencies (ResolverIncentiveModule, PaymentCalculationLibrary)
- ❌ Cannot swap modules in BaseEscrow
- ❌ Cannot bypass governance

### Issues Identified
1. ⚠️ ResolverIncentiveModule not upgradeable (needs conversion)
2. ⚠️ Library swapping requires slow-lane (needs instant function)
3. ⚠️ Role needs to be granted on multiple contracts
4. ⚠️ Upgrade coordination needed

### Recommended Improvements
1. ✅ Make ResolverIncentiveModule upgradeable
2. ✅ Allow instant library swapping
3. ✅ Grant role on all internal dependencies
4. ✅ Document scope clearly
5. ✅ Create upgrade coordination process

---

*This analysis should be updated as implementation progresses.*

