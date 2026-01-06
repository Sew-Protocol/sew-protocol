# DecentralizedResolutionModule Extraction & ROLE_MODULE_DEVELOPER Removal - Execution Plan

**Date:** 2026-01-06  
**Purpose:** Unified plan to extract DecentralizedResolutionModule and remove ROLE_MODULE_DEVELOPER  
**Approach:** Monorepo package structure (simple folder reorganization)

---

## Overview

This plan combines:
1. **Extraction** of DecentralizedResolutionModule into separate package
2. **Removal** of ROLE_MODULE_DEVELOPER for governance consistency
3. **Documentation updates** across all affected files

**Strategy:** Simple folder reorganization first, can evolve to packages later if needed.

---

## Phase 1: Code Extraction & Role Removal

### Step 1.1: Create Package Structure

```bash
# Create new package directories
mkdir -p contracts/decentralized-resolution-module
mkdir -p contracts/core
mkdir -p contracts/shared/interfaces
mkdir -p contracts/shared/governance

# Create test directories
mkdir -p test/hardhat/decentralized-resolution-module
```

### Step 1.2: Move Contracts

**Move to `contracts/decentralized-resolution-module/`:**
- [ ] `contracts/modules/DecentralizedResolutionModule.sol`
- [ ] `contracts/modules/ResolverIncentiveModule.sol`
- [ ] `contracts/modules/PaymentCalculationLibraryV1.sol`
- [ ] `contracts/interfaces/IPaymentCalculationLibrary.sol`

**Move to `contracts/core/`:**
- [ ] `contracts/BaseEscrow.sol`
- [ ] `contracts/EscrowVault.sol`
- [ ] `contracts/EscrowableERC20.sol`
- [ ] `contracts/modules/DefaultResolutionModule.sol`

**Move to `contracts/shared/interfaces/`:**
- [ ] `contracts/interfaces/IResolutionModule.sol` (keep here, used by both)

**Move to `contracts/shared/governance/`:**
- [ ] `contracts/governance/SlowLaneQueueActivateUpgradeable.sol` (only used by extracted modules)

**Keep at root `contracts/`:**
- [ ] `contracts/interfaces/` (other interfaces)
- [ ] `contracts/libraries/` (shared libraries)
- [ ] `contracts/governance/SlowLaneQueueActivate.sol` (used by core)
- [ ] Other modules (AaveYieldGenerationModule, etc.)

### Step 1.3: Remove ROLE_MODULE_DEVELOPER from Contracts

**Update `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`:**
- [ ] Remove `ROLE_MODULE_DEVELOPER` constant (line 33)
- [ ] Update `_authorizeUpgrade()` to only allow `ROLE_TIMELOCK`:
  ```solidity
  function _authorizeUpgrade(address newImplementation)
      internal
      override
  {
      require(
          hasRole(ROLE_TIMELOCK, _msgSender()),
          "Not authorized to upgrade"
      );
      
      address oldImplementation = ERC1967Utils.getImplementation();
      
      emit ModuleUpgraded(
          oldImplementation,
          newImplementation,
          _msgSender(),
          block.timestamp,
          0, // No delay for timelock
          "TIMELOCK"
      );
  }
  ```
- [ ] Remove `queueUpgrade()` function (lines ~1818-1857)
- [ ] Remove `activateUpgrade()` function (lines ~1864-1877)
- [ ] Remove staged delay logic (upgradeCount, deploymentTimestamp, getUpgradeDelay, getCurrentPhase)
- [ ] Remove upgrade delay constants (INSTANT_UPGRADES_COUNT, LAUNCH_PHASE_DURATION, etc.)
- [ ] Update comments to remove module developer references

**Update `contracts/decentralized-resolution-module/ResolverIncentiveModule.sol`:**
- [ ] Remove `ROLE_MODULE_DEVELOPER` constant (line 33)
- [ ] Update `_authorizeUpgrade()` to only allow `ROLE_TIMELOCK`:
  ```solidity
  function _authorizeUpgrade(address newImplementation)
      internal
      override
  {
      require(
          hasRole(ROLE_TIMELOCK, _msgSender()),
          "Not authorized to upgrade"
      );
      
      address oldImplementation = ERC1967Utils.getImplementation();
      
      emit ModuleUpgraded(
          oldImplementation,
          newImplementation,
          _msgSender(),
          block.timestamp
      );
  }
  ```
- [ ] Remove any module developer-specific functions

### Step 1.4: Update Import Paths

**Update imports in moved contracts:**
- [ ] `DecentralizedResolutionModule.sol`:
  - Change `../interfaces/IResolutionModule.sol` → `../../shared/interfaces/IResolutionModule.sol`
  - Change `../governance/SlowLaneQueueActivateUpgradeable.sol` → `../../shared/governance/SlowLaneQueueActivateUpgradeable.sol`
  - Change `./ResolverIncentiveModule.sol` → `./ResolverIncentiveModule.sol` (same directory)

- [ ] `ResolverIncentiveModule.sol`:
  - Change `../interfaces/IPaymentCalculationLibrary.sol` → `../../shared/interfaces/IPaymentCalculationLibrary.sol` (if moved)
  - Change `../governance/SlowLaneQueueActivateUpgradeable.sol` → `../../shared/governance/SlowLaneQueueActivateUpgradeable.sol`

- [ ] `BaseEscrow.sol`:
  - Change `./interfaces/IResolutionModule.sol` → `../shared/interfaces/IResolutionModule.sol`
  - Update other imports as needed

- [ ] `DefaultResolutionModule.sol`:
  - Update imports as needed

### Step 1.5: Update Foundry Remappings

**Update `remappings.txt`:**
```toml
forge-std/=lib/forge-std/src/
@openzeppelin/=node_modules/@openzeppelin/
@core/=contracts/core/
@decentralized-resolution-module/=contracts/decentralized-resolution-module/
@shared/=contracts/shared/
```

### Step 1.6: Update BaseEscrow Comment

**Update `contracts/core/BaseEscrow.sol` (line ~969):**
- [ ] Change comment from:
  ```solidity
  *      Calls recordResolution on DecentralizedResolutionModule if available.
  ```
- [ ] To:
  ```solidity
  *      Calls recordResolution on the active resolution module if it supports the interface.
  ```

### Step 1.7: Move Tests

**Move test files:**
- [ ] `test/hardhat/DecentralizedResolutionModule.test.ts` → `test/hardhat/decentralized-resolution-module/DecentralizedResolutionModule.test.ts`
- [ ] `test/hardhat/ResolverIncentiveModule.test.ts` → `test/hardhat/decentralized-resolution-module/ResolverIncentiveModule.test.ts` (if exists)

**Update test imports:**
- [ ] Update all import paths in moved test files
- [ ] Remove module developer role tests
- [ ] Update tests to use timelock-only upgrades

### Step 1.8: Update Other Tests

**Update `test/hardhat/EscalationFee.test.ts`:**
- [ ] Remove DecentralizedResolutionModule-specific tests
- [ ] Keep only DefaultResolutionModule tests (if applicable)

**Update `test/hardhat/BaseEscrow.moduleValidation.test.ts`:**
- [ ] Remove DecentralizedResolutionModule validation tests

**Update `test/hardhat/ModuleMetadata.test.ts`:**
- [ ] Remove DecentralizedResolutionModule metadata tests (lines 40-44, 84+)

**Update `test/hardhat/MainnetReleaseSequence.test.ts`:**
- [ ] Review and remove DecentralizedResolutionModule references (if any)

### Step 1.9: Update Deployment Scripts

**Update `deploy/60_protocol_governance.ts`:**
- [ ] Remove `'DecentralizedResolutionModule'` from `contractsToGovern` array (line 38)
- [ ] Update contract paths if needed

**Review other deployment scripts:**
- [ ] Check for DecentralizedResolutionModule references
- [ ] Update paths if needed

### Step 1.10: Verify Compilation

- [ ] Run `pnpm compile` - verify no errors
- [ ] Run `forge build` - verify no errors
- [ ] Fix any import path issues
- [ ] Verify all contracts compile successfully

---

## Phase 2: Documentation Updates

### Step 2.1: Core Governance Documentation

**Update `docs/governance.md`:**
- [ ] **Remove entire "Module Developer (ROLE_MODULE_DEVELOPER)" section** (lines ~246-270)
- [ ] Update any references to module developer role
- [ ] Update module upgrade references to remove DecentralizedResolutionModule-specific content
- [ ] Ensure governance lanes section only mentions Standard/Slow/Emergency

**Update `docs/GOVERNANCE_SURFACE_MAP.md`:**
- [ ] **Remove DecentralizedResolutionModule function mapping table** (lines ~123-142)
  - Remove `upgradeTo()`, `upgradeToAndCall()`, `queueUpgrade()`, `activateUpgrade()`, `getUpgradeDelay()`, `getCurrentPhase()`, `getPendingUpgrade()` entries
- [ ] **Remove Module Upgrade Lane section references** to DecentralizedResolutionModule
- [ ] **Remove ROLE_MODULE_DEVELOPER** from role permissions matrix
- [ ] Update any other references to module developer role
- [ ] Ensure only Standard/Slow/Emergency lanes are documented

**Update `docs/SECURITY_MODEL.md`:**
- [ ] **System Overview** - Remove DecentralizedResolutionModule from component list (line ~64)
- [ ] **Deployment Posture** - Remove future enhancement note about DecentralizedResolutionModule (lines ~88-95)
- [ ] **Governance & Admin Controls** - Remove ROLE_MODULE_DEVELOPER from roles section
- [ ] **Threat Model** - Remove upgrade/migration risks specific to DecentralizedResolutionModule (update line ~209)
- [ ] **Trust Model** - Update resolver honesty statement if it references DecentralizedResolutionModule specifically
- [ ] Search for any other DecentralizedResolutionModule or module developer references

### Step 2.2: Module-Specific Documentation

**Archive/Move (to extracted module repo or archive folder):**
- [ ] `docs/MODULE_DEVELOPER_ROLE_DESIGN.md` → Move to `docs/archived/` or new repo
- [ ] `docs/MODULE_DEVELOPER_ROLE_SUMMARY.md` → Move to `docs/archived/` or new repo
- [ ] `docs/MODULE_UPGRADE_IMPLEMENTATION_PLAN.md` → Review, move if DecentralizedResolutionModule-specific
- [ ] `docs/plans/DISPUTE_RESOLUTION_IMPLEMENTATION_PLAN.md` → Review, move if DecentralizedResolutionModule-specific
- [ ] `docs/plans/DECENTRALIZED_RESOLUTION_COMPLETION_PLAN.md` → Move if exists

**Update `docs/MODULE_MAP.md`:**
- [ ] Remove DecentralizedResolutionModule from IResolutionModule implementations table (line 42)
- [ ] Add note: "DecentralizedResolutionModule is in separate package/repo and can be swapped in via governance once proven"
- [ ] Update module change instructions to note DecentralizedResolutionModule availability

**Update `docs/CONTRACTS_SUMMARY.md`:**
- [ ] Remove DecentralizedResolutionModule section (lines ~63-72)
- [ ] Update to note that DecentralizedResolutionModule is in separate package

**Update `docs/TECHNICAL_OVERVIEW.md`:**
- [ ] Remove DecentralizedResolutionModule references
- [ ] Update module architecture section
- [ ] Note that DecentralizedResolutionModule is in separate package

### Step 2.3: Planning & Assessment Documentation

**Update `docs/MAINNET_CHECKLIST_ASSESSMENT.md`:**
- [ ] Remove references to DecentralizedResolutionModule complexity
- [ ] Update any module developer role references

**Update `docs/OUTSTANDING_ISSUES.md`:**
- [ ] Remove any DecentralizedResolutionModule-specific issues
- [ ] Remove module developer role issues

**Update `docs/plans/MAINNET_DEPLOYMENT_PLAN.md`:**
- [ ] Remove DecentralizedResolutionModule from optional modules list (line 56)
- [ ] Update deployment plan to note DecentralizedResolutionModule is separate

**Update `docs/MODULE_UPGRADE_STRATEGY.md`:**
- [ ] Remove module developer role references
- [ ] Update to reflect timelock-only upgrades
- [ ] Remove DecentralizedResolutionModule-specific upgrade strategies

**Update `docs/GOVERNANCE_IMPLEMENTATION_STATUS.md`:**
- [ ] Remove module developer role status
- [ ] Update governance implementation status

### Step 2.4: Review Documentation

**Update `docs/_DOCUMENT_INDEX.md`:**
- [ ] Remove links to DecentralizedResolutionModule-specific docs
- [ ] Remove links to module developer role docs
- [ ] Add note about separate package for DecentralizedResolutionModule
- [ ] Update document organization

**Update `docs/README.md` (if exists in docs/):**
- [ ] Update to reflect new structure
- [ ] Note DecentralizedResolutionModule separation

**Review other documentation:**
- [ ] `docs/20260106-SMART_CONTRACT_REVIEW.md` - Remove module developer references
- [ ] `docs/SMART_CONTRACT_REVIEW.md` - Remove module developer references
- [ ] `docs/CONTRIBUTING_ADHERENCE_ASSESSMENT.md` - Update if needed
- [ ] Any other docs found via grep

### Step 2.5: Update Extraction Plan

**Update `docs/DECENTRALIZED_RESOLUTION_MODULE_EXTRACTION_PLAN.md`:**
- [ ] Mark as "In Progress" or "Completed"
- [ ] Add note about ROLE_MODULE_DEVELOPER removal
- [ ] Update status of completed steps

---

## Phase 3: Verification & Testing

### Step 3.1: Compilation Verification

- [ ] Run `pnpm compile` - all contracts compile
- [ ] Run `forge build` - all contracts compile
- [ ] No import errors
- [ ] No missing dependencies

### Step 3.2: Test Suite

- [ ] Run `pnpm test:hardhat` - all tests pass (except removed DecentralizedResolutionModule tests)
- [ ] Run `pnpm test:foundry` - all tests pass
- [ ] Verify DefaultResolutionModule tests still work
- [ ] Verify core escrow functionality unaffected
- [ ] Verify no broken test imports

### Step 3.3: Documentation Verification

- [ ] Search for "ROLE_MODULE_DEVELOPER" - should find no results (except in archived docs)
- [ ] Search for "Module Developer" - should find no results (except in archived docs)
- [ ] Search for "DecentralizedResolutionModule" - should only find references to separate package
- [ ] Verify governance docs only mention Standard/Slow/Emergency lanes
- [ ] Verify all links in `_DOCUMENT_INDEX.md` are valid

### Step 3.4: Code Review

- [ ] Verify no ROLE_MODULE_DEVELOPER constants remain
- [ ] Verify all upgrade functions require ROLE_TIMELOCK only
- [ ] Verify no module developer-specific functions remain
- [ ] Verify import paths are correct
- [ ] Verify contract structure is clear

---

## Phase 4: Cleanup

### Step 4.1: Remove Old Files

- [ ] Delete old contract locations (after verification)
- [ ] Delete old test locations (after verification)
- [ ] Clean up any duplicate files

### Step 4.2: Update Configuration Files

**Update `scripts/print-contract-sizes.ts`:**
- [ ] Remove DecentralizedResolutionModule from size checks (if explicitly listed)

**Update `coverage.json`:**
- [ ] Remove DecentralizedResolutionModule from coverage (if explicitly configured)

**Update `slither.config.json`:**
- [ ] Update paths if needed

### Step 4.3: Git Cleanup

- [ ] Commit extraction changes
- [ ] Commit role removal changes
- [ ] Commit documentation updates
- [ ] Create summary commit message

---

## Detailed File-by-File Checklist

### Contracts to Move

| File | From | To | Status |
|------|------|-----|--------|
| `DecentralizedResolutionModule.sol` | `contracts/modules/` | `contracts/decentralized-resolution-module/` | ⬜ |
| `ResolverIncentiveModule.sol` | `contracts/modules/` | `contracts/decentralized-resolution-module/` | ⬜ |
| `PaymentCalculationLibraryV1.sol` | `contracts/modules/` | `contracts/decentralized-resolution-module/` | ⬜ |
| `IPaymentCalculationLibrary.sol` | `contracts/interfaces/` | `contracts/decentralized-resolution-module/` | ⬜ |
| `BaseEscrow.sol` | `contracts/` | `contracts/core/` | ⬜ |
| `EscrowVault.sol` | `contracts/` | `contracts/core/` | ⬜ |
| `EscrowableERC20.sol` | `contracts/` | `contracts/core/` | ⬜ |
| `DefaultResolutionModule.sol` | `contracts/modules/` | `contracts/core/modules/` | ⬜ |
| `IResolutionModule.sol` | `contracts/interfaces/` | `contracts/shared/interfaces/` | ⬜ |
| `SlowLaneQueueActivateUpgradeable.sol` | `contracts/governance/` | `contracts/shared/governance/` | ⬜ |

### Contracts to Update (Remove ROLE_MODULE_DEVELOPER)

| File | Changes | Status |
|------|---------|--------|
| `DecentralizedResolutionModule.sol` | Remove role, simplify upgrade auth, remove queue/activate | ⬜ |
| `ResolverIncentiveModule.sol` | Remove role, simplify upgrade auth | ⬜ |

### Documentation Files to Update

| File | Changes | Status |
|------|---------|--------|
| `docs/governance.md` | Remove Module Developer section | ⬜ |
| `docs/GOVERNANCE_SURFACE_MAP.md` | Remove module developer role, remove DecentralizedResolutionModule table | ⬜ |
| `docs/SECURITY_MODEL.md` | Remove DecentralizedResolutionModule, remove ROLE_MODULE_DEVELOPER | ⬜ |
| `docs/MODULE_MAP.md` | Remove DecentralizedResolutionModule, add note about separate package | ⬜ |
| `docs/CONTRACTS_SUMMARY.md` | Remove DecentralizedResolutionModule section | ⬜ |
| `docs/TECHNICAL_OVERVIEW.md` | Remove DecentralizedResolutionModule references | ⬜ |
| `docs/MAINNET_CHECKLIST_ASSESSMENT.md` | Remove DecentralizedResolutionModule complexity references | ⬜ |
| `docs/OUTSTANDING_ISSUES.md` | Remove DecentralizedResolutionModule issues | ⬜ |
| `docs/plans/MAINNET_DEPLOYMENT_PLAN.md` | Remove DecentralizedResolutionModule from modules list | ⬜ |
| `docs/MODULE_UPGRADE_STRATEGY.md` | Remove module developer references | ⬜ |
| `docs/GOVERNANCE_IMPLEMENTATION_STATUS.md` | Remove module developer status | ⬜ |
| `docs/_DOCUMENT_INDEX.md` | Remove links, add note about separate package | ⬜ |
| `docs/20260106-SMART_CONTRACT_REVIEW.md` | Remove module developer references | ⬜ |
| `docs/SMART_CONTRACT_REVIEW.md` | Remove module developer references | ⬜ |

### Documentation Files to Archive/Move

| File | Action | Status |
|------|--------|--------|
| `docs/MODULE_DEVELOPER_ROLE_DESIGN.md` | Move to `docs/archived/` | ⬜ |
| `docs/MODULE_DEVELOPER_ROLE_SUMMARY.md` | Move to `docs/archived/` | ⬜ |
| `docs/MODULE_UPGRADE_IMPLEMENTATION_PLAN.md` | Review, move if DecentralizedResolutionModule-specific | ⬜ |
| `docs/plans/DISPUTE_RESOLUTION_IMPLEMENTATION_PLAN.md` | Review, move if DecentralizedResolutionModule-specific | ⬜ |
| `docs/plans/DECENTRALIZED_RESOLUTION_COMPLETION_PLAN.md` | Move if exists | ⬜ |

### Test Files to Move/Update

| File | Action | Status |
|------|--------|--------|
| `test/hardhat/DecentralizedResolutionModule.test.ts` | Move to `test/hardhat/decentralized-resolution-module/` | ⬜ |
| `test/hardhat/ResolverIncentiveModule.test.ts` | Move if exists | ⬜ |
| `test/hardhat/EscalationFee.test.ts` | Remove DecentralizedResolutionModule tests | ⬜ |
| `test/hardhat/BaseEscrow.moduleValidation.test.ts` | Remove DecentralizedResolutionModule tests | ⬜ |
| `test/hardhat/ModuleMetadata.test.ts` | Remove DecentralizedResolutionModule tests | ⬜ |
| `test/hardhat/MainnetReleaseSequence.test.ts` | Remove DecentralizedResolutionModule references | ⬜ |

### Deployment Scripts to Update

| File | Changes | Status |
|------|---------|--------|
| `deploy/60_protocol_governance.ts` | Remove DecentralizedResolutionModule from contractsToGovern | ⬜ |

---

## Verification Commands

### Check for Remaining References

```bash
# Check for ROLE_MODULE_DEVELOPER in contracts
grep -r "ROLE_MODULE_DEVELOPER" contracts/

# Check for Module Developer in docs (should only be in archived)
grep -r "Module Developer\|ROLE_MODULE_DEVELOPER" docs/ --exclude-dir=archived

# Check for DecentralizedResolutionModule in core contracts
grep -r "DecentralizedResolutionModule" contracts/core/

# Check for import errors
pnpm compile 2>&1 | grep -i "error\|cannot find"
```

### Verify Tests

```bash
# Run all tests
pnpm test

# Run specific test suites
pnpm test:hardhat
pnpm test:foundry
```

### Verify Documentation

```bash
# Check for broken links (if link checker exists)
# Or manually verify _DOCUMENT_INDEX.md

# Verify no module developer references remain
grep -r "module developer" docs/ --exclude-dir=archived -i
```

---

## Success Criteria

### Code
- ✅ All contracts compile without errors
- ✅ All tests pass (except removed DecentralizedResolutionModule tests)
- ✅ No ROLE_MODULE_DEVELOPER constants remain
- ✅ All upgrade functions require ROLE_TIMELOCK only
- ✅ Import paths are correct
- ✅ Contract structure is clear and organized

### Documentation
- ✅ No ROLE_MODULE_DEVELOPER references (except archived)
- ✅ No Module Developer role documentation (except archived)
- ✅ DecentralizedResolutionModule only mentioned as separate package
- ✅ Governance docs only mention Standard/Slow/Emergency lanes
- ✅ All documentation links are valid
- ✅ Extraction and role removal are documented

### Testing
- ✅ DefaultResolutionModule tests pass
- ✅ Core escrow functionality tests pass
- ✅ No broken test imports
- ✅ Integration tests work

---

## Timeline Estimate

### Phase 1: Code Extraction & Role Removal
- **Estimated time:** 4-6 hours
- **Complexity:** Medium
- **Dependencies:** None

### Phase 2: Documentation Updates
- **Estimated time:** 3-4 hours
- **Complexity:** Low-Medium
- **Dependencies:** Phase 1 complete

### Phase 3: Verification & Testing
- **Estimated time:** 2-3 hours
- **Complexity:** Low
- **Dependencies:** Phase 1 & 2 complete

### Phase 4: Cleanup
- **Estimated time:** 1 hour
- **Complexity:** Low
- **Dependencies:** Phase 3 complete

**Total estimated time:** 10-14 hours

---

## Risk Mitigation

### Risk: Broken Imports
- **Mitigation:** Update imports incrementally, test compilation after each change
- **Rollback:** Git commit after each major step

### Risk: Missing Documentation Updates
- **Mitigation:** Use grep to find all references before starting
- **Verification:** Final grep check before completion

### Risk: Test Failures
- **Mitigation:** Update tests incrementally, run test suite frequently
- **Rollback:** Keep old test files until new ones pass

### Risk: Deployment Script Issues
- **Mitigation:** Test deployment scripts on testnet first
- **Verification:** Verify deployment scripts work before mainnet

---

## Notes

- **Approach:** Simple folder reorganization first, can evolve to pnpm packages later
- **Interface compatibility:** `IResolutionModule` must remain compatible for future swaps
- **Governance:** All upgrades now go through standard timelock governance
- **Future:** DecentralizedResolutionModule can be swapped in via slow-lane governance once proven

---

## Status Tracking

**Current Status:** ⬜ Not Started

**Phase 1:** ⬜ Not Started  
**Phase 2:** ⬜ Not Started  
**Phase 3:** ⬜ Not Started  
**Phase 4:** ⬜ Not Started

**Last Updated:** 2026-01-06

