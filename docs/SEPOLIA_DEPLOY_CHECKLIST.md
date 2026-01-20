# Pre-Sepolia Deploy Checklist

**Date:** 2026-01-28  
**Status:** Pre-deployment validation  
**Target:** Sepolia Testnet deployment  

---

## 🎯 Priority: Core Module Tests Passing, Constructor Locked, Ready for Sepolia

---

## 1. ✅ Constructor Validations & Ranges

### EscrowVault Constructor
- [x] **escrowFeeBps validation**: `0 <= escrowFeeBps <= MAX_ESCROW_FEE_BPS (200 bps = 2%)`
  - ✅ Implemented: `if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(...)`
  - ⚠️ **MISSING**: Minimum check (should allow 0, but document if there's a minimum)
  - 📝 **Action**: Add test for `escrowFeeBps = 0` (should be valid)
  - 📝 **Action**: Add test for `escrowFeeBps = 200` (should be valid)
  - 📝 **Action**: Add test for `escrowFeeBps = 201` (should revert)

- [x] **Address validations**: All addresses validated against zero address
  - ✅ `feeAddress`, `yieldOpsAddress`, `disputeOpsAddress` validated
  - ✅ Deployer validated (defensive check)

- [x] **Protocol fee initialization**: `MAX_PROTOCOL_FEE_BPS (3000 bps = 30%)`
  - ✅ `yieldProtocolFeeBps` initialized to 3000 (validated)
  - ✅ `appealBondProtocolFeeBps` initialized to 0 (validated)

### EscrowableERC20 Constructor
- [x] **Same validations as EscrowVault** ✅
- [x] **INITIAL_SUPPLY minted** ✅

### Constructor Overflow Protection
- [x] **Solidity 0.8.33**: Automatic overflow checks ✅
- [x] **Fee calculations**: `(amount * escrowFee) / ESCROW_FEE_DENOMINATOR` - safe if escrowFee <= 200
- 📝 **Action**: Add fuzz test for constructor parameters to verify overflow protection

### Constructor Tests Needed
```solidity
// test/foundry/core/ConstructorValidation.t.sol (NEW FILE)
function test_EscrowVault_constructor_reverts_escrowFeeTooHigh() public
function test_EscrowVault_constructor_succeeds_escrowFeeZero() public
function test_EscrowVault_constructor_succeeds_escrowFeeMax() public
function test_EscrowVault_constructor_reverts_zeroFeeAddress() public
function test_EscrowVault_constructor_reverts_zeroYieldOpsAddress() public
function test_EscrowVault_constructor_reverts_zeroDisputeOpsAddress() public
function test_EscrowVault_constructor_fuzz_validRange(uint256 feeBps) public // 0-200
function test_EscrowVault_constructor_protocolFeeValidation() public
```

---

## 2. ✅ createEscrow Validations & Ranges

### Amount Validation
- [x] **Minimum amount**: `amount >= MIN_ESCROW_AMOUNT (1000 wei)`
  - ✅ Implemented: `SettingsValidationLibrary.validateEscrowAmount(amount)`
  - 📝 **Action**: Add test for `amount = 999` (should revert)
  - 📝 **Action**: Add test for `amount = 1000` (should succeed)
  - 📝 **Action**: Add test for `amount = type(uint256).max` (check overflow in fee calculation)

### Recipient Validation
- [x] **Zero address check**: `recipient != address(0)`
  - ✅ Implemented: `SettingsValidationLibrary.validateRecipient(to, _msgSender())`
  - 📝 **Action**: Add test for `recipient = address(0)` (should revert)

- [x] **Sender != Recipient**: `recipient != sender`
  - ✅ Implemented: `validateRecipient` checks this
  - 📝 **Action**: Add test for `recipient = sender` (should revert)

### EscrowSettings Validation
- [x] **Auto times**: Cannot set both `autoReleaseTime` and `autoCancelTime`
  - ✅ Implemented in `_validateEscrowSettings`

- [x] **Auto time duration**: `autoTime <= currentTime + MAX_ESCROW_DURATION (365 days)`
  - ✅ Implemented: `MAX_ESCROW_DURATION = 365 days`
  - 📝 **Action**: Add test for `autoReleaseTime > currentTime + 365 days` (should revert)

- [x] **Custom resolver**: If set, must be a contract (not EOA)
  - ✅ Implemented: Checks `settings.customResolver.code.length > 0`
  - 📝 **Action**: Add test for EOA as custom resolver (should revert)

- [x] **Yield preset**: Uses `YieldPreset` enum (OFF, TO_SENDER)
  - ✅ Implemented: `YieldPresetLibrary.validatePresetParams`
  - 📝 **Action**: Add test for invalid enum value (if possible)

### Fee Calculation Overflow Protection
- [x] **Multiplication**: `fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR`
  - ⚠️ **CONCERN**: If `amount = type(uint256).max` and `escrowFee = 200`, multiplication could overflow
  - ✅ **MITIGATION**: Solidity 0.8+ reverts on overflow automatically
  - 📝 **Action**: Add test for maximum amount with maximum fee (should revert or handle gracefully)

### createEscrow Tests Needed (from TEST_PLAN_MISSING_CONSTRAINTS.md)
```solidity
// test/foundry/core/EscrowConstraints.t.sol (NEW FILE - Priority HIGH)
function test_createEscrow_reverts_belowMinimumAmount() public
function test_createEscrow_succeeds_atMinimumAmount() public
function test_createEscrow_reverts_zeroRecipient() public
function test_createEscrow_reverts_senderEqualsRecipient() public
function test_createEscrow_reverts_autoReleaseExceedsMaxDuration() public
function test_createEscrow_reverts_customResolverIsEOA() public
function test_createEscrow_overflow_maxAmount_maxFee() public // NEW - check overflow
```

---

## 3. 🔴 Unsolved Concerns & Issues

### Critical Issues
- ✅ **All critical issues from holistic review are FIXED**
  1. ✅ Solidity version inconsistencies (fixed)
  2. ✅ Duplicate deployment script numbering (fixed)

### Medium Priority Issues
- [ ] **Issue 6: Test file naming inconsistency** (Low impact, post-launch)
  - Mix of `*.t.sol` and `*.test.t.sol`
  - **Action**: Standardize post-launch

- [ ] **Issue 7: Migrated test directory** (Medium impact, post-launch)
  - 23 migrated test files with outdated patterns
  - **Action**: Update and integrate post-launch

- [ ] **Issue 8: Module location inconsistency** (Medium impact, post-launch)
  - Modules in multiple locations
  - **Action**: Document and standardize post-launch

### Code Quality Issues
- [ ] **TODO in ResolverSlashingModuleV1.sol:827**
  ```solidity
  // TODO: Transfer protocol portion to treasury (when treasury contract exists)
  ```
  - **Status**: Non-blocking for Sepolia (treasury not implemented yet)
  - **Action**: Document in code that this is post-launch enhancement

- [ ] **HIGH/LOW severity markers in comments**
  - Multiple instances: `// HIGH-1:`, `// LOW-3:`, etc.
  - **Status**: Code review markers, should be cleaned before public release
  - **Action**: Remove or convert to standard NatSpec comments before Sepolia

### Validation Gaps
- [ ] **Missing minimum escrowFee validation in constructor**
  - Currently allows `escrowFeeBps = 0` (should be valid, but not tested)
  - **Action**: Add test confirming `escrowFeeBps = 0` is valid

- [ ] **Missing maximum amount overflow test for createEscrow**
  - `amount = type(uint256).max` with `escrowFee = 200` could overflow multiplication
  - **Action**: Add fuzz test or explicit test for maximum values

---

## 4. 📋 Documentation TODOs & Actions

### Unaddressed TODOs in Docs
- [ ] **docs/dispute-resolution/DR_V3_TODO.md**
  - **Action**: Review and determine if relevant for Sepolia launch
  - **Status**: Likely post-launch items

- [ ] **docs/dispute-resolution/TODO_STATUS_UPDATE.md**
  - **Action**: Review and determine if relevant for Sepolia launch

- [ ] **docs/dispute-resolution/DR_TODOS.md**
  - **Action**: Review and determine if relevant for Sepolia launch

- [ ] **docs/dispute-resolution/RESOLVER_ECONOMICS_TODOS.md**
  - **Action**: Review and determine if relevant for Sepolia launch

### Review Status Docs
- [x] **docs/REVIEW_STATUS_AND_YIELD_LAUNCH.md**
  - ✅ Documents completed fixes
  - ✅ Documents remaining medium-priority issues (post-launch)

- [x] **docs/REPOSITORY_HOLISTIC_REVIEW.md**
  - ✅ Documents all findings
  - ✅ Critical issues marked as FIXED

### Test Plan Status
- [x] **docs/test/TEST_PLAN_MISSING_CONSTRAINTS.md**
  - ✅ Comprehensive test plan created
  - ⚠️ **32 new tests planned** - Only critical ones needed for Sepolia
  - **Action**: Prioritize constructor and createEscrow validation tests

---

## 5. 🔧 Code/Comment/NatSpec Changes Before Public Release

### Comment Cleanup
- [ ] **Remove HIGH/LOW severity markers**
  - **Files to clean:**
    - `contracts/core/EscrowVault.sol`: `// LOW-3:`
    - `contracts/core/EscrowableERC20.sol`: `// LOW-3:`, `// HIGH-2:`
    - `contracts/core/BaseEscrow.sol`: Multiple `// HIGH-X:`, `// LOW-X:`
    - `contracts/modules/AaveYieldGenerationModule.sol`: Multiple `// HIGH-X:`
    - `contracts/decentralized-resolution-module/*`: Multiple markers
  - **Action**: Replace with standard NatSpec `@notice` or `@dev` comments
  - **Priority**: 🔴 **HIGH** (before Sepolia)

### Deprecated Code Comments
- [x] **Deprecated yield distribution comments**
  - ✅ Already marked: `// DEPRECATED: Per-escrow yield distribution removed...`
  - **Status**: Acceptable for testnet (clearly marked as deprecated)

### TODO Comments
- [ ] **ResolverSlashingModuleV1.sol:827**
  ```solidity
  // TODO: Transfer protocol portion to treasury (when treasury contract exists)
  ```
  - **Action**: Replace with NatSpec:
    ```solidity
    /// @dev Protocol portion will be transferred to treasury once treasury contract is deployed.
    ///      Currently retained in slashing module for future transfer.
    ```

### NatSpec Completeness
- [x] **Constructors**: Well-documented ✅
- [x] **createEscrow**: Well-documented ✅
- [x] **Public functions**: Generally well-documented ✅

### Error Messages
- [x] **Custom errors**: Comprehensive and descriptive ✅
- [x] **Error parameters**: Include relevant context (amounts, addresses, etc.) ✅

---

## 6. ✅ Pre-Deployment Test Checklist

### Required Tests (Critical for Sepolia)
- [ ] **Constructor validation tests** (NEW FILE)
  - [ ] `test_EscrowVault_constructor_reverts_escrowFeeTooHigh`
  - [ ] `test_EscrowVault_constructor_succeeds_escrowFeeZero`
  - [ ] `test_EscrowVault_constructor_succeeds_escrowFeeMax`
  - [ ] `test_EscrowVault_constructor_reverts_zeroAddresses`

- [ ] **createEscrow validation tests** (NEW FILE)
  - [ ] `test_createEscrow_reverts_belowMinimumAmount` (amount < 1000)
  - [ ] `test_createEscrow_succeeds_atMinimumAmount` (amount = 1000)
  - [ ] `test_createEscrow_reverts_zeroRecipient`
  - [ ] `test_createEscrow_reverts_senderEqualsRecipient`
  - [ ] `test_createEscrow_reverts_autoReleaseExceedsMaxDuration`
  - [ ] `test_createEscrow_reverts_customResolverIsEOA`
  - [ ] `test_createEscrow_overflow_maxAmount_maxFee` (edge case)

### Existing Tests (Verify Passing)
- [ ] **Core module tests**: `pnpm test:foundry:release-resolution`
  - [ ] All core escrow tests passing
  - [ ] All resolution module tests passing
  - [ ] Module metadata tests passing

### Fuzz Tests (Recommended)
- [ ] **Constructor fuzz test**: `test_EscrowVault_constructor_fuzz_validRange(uint256 feeBps)`
- [ ] **createEscrow fuzz test**: Amount and fee combinations

---

## 7. 🚀 Sepolia Deployment Readiness

### Code Lock Status
- [x] **Constructors**: ✅ **LOCKED** - All validations in place
- [x] **createEscrow**: ✅ **VALIDATED** - All constraints enforced
- [ ] **HIGH/LOW comment markers**: ⚠️ **CLEANUP NEEDED** before public release

### Test Coverage
- [ ] **Constructor tests**: ❌ **MISSING** - Create new test file
- [ ] **createEscrow validation tests**: ❌ **MISSING** - Create new test file
- [ ] **Core module tests**: ✅ **EXISTING** - Verify all passing

### Documentation
- [x] **Review status**: ✅ Documented
- [x] **Test plan**: ✅ Comprehensive plan exists
- [ ] **Unaddressed TODOs**: ⚠️ Review dispute-resolution TODOs

---

## 8. 🎯 Action Items Summary

### 🔴 **MUST DO** Before Sepolia
1. [ ] **Create constructor validation tests** (`test/foundry/core/ConstructorValidation.t.sol`)
2. [ ] **Create createEscrow validation tests** (`test/foundry/core/EscrowConstraints.t.sol`)
3. [ ] **Remove HIGH/LOW comment markers** from all contracts
4. [ ] **Run core module tests**: `pnpm test:foundry:release-resolution` (verify all passing)

### 🟡 **SHOULD DO** Before Sepolia
5. [ ] **Add overflow test for maximum amount + maximum fee**
6. [ ] **Review and address dispute-resolution TODOs** (if blocking)
7. [ ] **Update TODO comment in ResolverSlashingModuleV1** to NatSpec

### 🟢 **NICE TO HAVE** (Post-Launch)
8. [ ] Standardize test file naming
9. [ ] Update migrated test directory
10. [ ] Consolidate module locations

---

## 9. ✅ Deployment Checklist (Final Steps)

### Before Deploy
- [ ] All critical tests passing
- [ ] Constructor validation tests added and passing
- [ ] createEscrow validation tests added and passing
- [ ] HIGH/LOW comment markers removed
- [ ] Code compiled without warnings
- [ ] Deployment scripts tested on local network

### Deploy to Sepolia
- [ ] Deploy contracts
- [ ] Verify constructor arguments are within valid ranges
- [ ] Test createEscrow with minimum amount (1000 wei)
- [ ] Test createEscrow with maximum fee (200 bps)
- [ ] Verify module registry integration (if applicable)
- [ ] Verify yield preset defaults to OFF

### Post-Deploy Validation
- [ ] Verify all core functions working
- [ ] Test dispute resolution flow
- [ ] Monitor for unexpected errors
- [ ] Document any issues found

---

## 📝 Notes

- **Constructor overflow protection**: Solidity 0.8.33 provides automatic overflow checks, but explicit tests are recommended for edge cases.
- **Fee calculation overflow**: `(amount * escrowFee) / ESCROW_FENOMINATOR` is safe for normal values, but test maximum values explicitly.
- **Minimum escrow amount**: `MIN_ESCROW_AMOUNT = 1000 wei` - ensure this is appropriate for all tokens (consider 18-decimal tokens).
- **Test priority**: Focus on constructor and createEscrow validations first, then add comprehensive tests post-launch.

---

**Status**: ⚠️ **IN PROGRESS** - Tests and cleanup needed before Sepolia deployment
