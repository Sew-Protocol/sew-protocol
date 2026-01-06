# DecentralizedResolutionModule Extraction Plan

**Date:** 2026-01-06  
**Purpose:** Extract DecentralizedResolutionModule and related components into a dedicated repository  
**Rationale:** Simplify main repo, remove largest risk/complexity, enable isolated testing before mainnet integration

---

## Executive Summary

This plan outlines the extraction of `DecentralizedResolutionModule` and its dependencies into a separate repository. This simplifies the main escrow protocol repository and allows the decentralized resolution system to be developed, tested, and proven in isolation before being swapped into the main protocol via governance.

**Key Principle:** The module will be developed and tested separately, then swapped into the main protocol via slow-lane governance once proven.

---

## Components to Extract

### Core Contracts (Move to New Repo)

1. **`DecentralizedResolutionModule.sol`**
   - Main decentralized resolution module
   - UUPS upgradeable
   - ~2000 lines of code
   - Location: `contracts/modules/DecentralizedResolutionModule.sol`

2. **`ResolverIncentiveModule.sol`**
   - Tracks resolver activity and distributes fees
   - UUPS upgradeable
   - Tightly coupled with DecentralizedResolutionModule
   - Location: `contracts/modules/ResolverIncentiveModule.sol`

3. **`PaymentCalculationLibraryV1.sol`**
   - Payment calculation library used by ResolverIncentiveModule
   - Swappable library pattern
   - Location: `contracts/modules/PaymentCalculationLibraryV1.sol`

### Interfaces (Move to New Repo)

4. **`IPaymentCalculationLibrary.sol`**
   - Interface for payment calculation libraries
   - Used by ResolverIncentiveModule
   - Location: `contracts/interfaces/IPaymentCalculationLibrary.sol`

### Governance Libraries (Move to New Repo)

5. **`SlowLaneQueueActivateUpgradeable.sol`**
   - Upgradeable version of slow-lane queue/activate pattern
   - Used by DecentralizedResolutionModule and ResolverIncentiveModule
   - **Note:** Only used by these two modules, safe to extract
   - Location: `contracts/governance/SlowLaneQueueActivateUpgradeable.sol`

### Dependencies That Must Stay (Copy to New Repo)

6. **`IResolutionModule.sol`**
   - Core resolution module interface
   - **Action:** Copy to new repo (must match exactly)
   - Location: `contracts/interfaces/IResolutionModule.sol`

---

## Components to Remove from Main Repo

### Contracts

1. ✅ **Delete:** `contracts/modules/DecentralizedResolutionModule.sol`
2. ✅ **Delete:** `contracts/modules/ResolverIncentiveModule.sol`
3. ✅ **Delete:** `contracts/modules/PaymentCalculationLibraryV1.sol`
4. ✅ **Delete:** `contracts/interfaces/IPaymentCalculationLibrary.sol`
5. ✅ **Delete:** `contracts/governance/SlowLaneQueueActivateUpgradeable.sol`

### Tests

6. ✅ **Delete:** `test/hardhat/DecentralizedResolutionModule.test.ts`
7. ✅ **Delete:** `test/hardhat/ResolverIncentiveModule.test.ts` (if exists)
8. ✅ **Update:** `test/hardhat/EscalationFee.test.ts` - Remove DecentralizedResolutionModule-specific tests
9. ✅ **Update:** `test/hardhat/BaseEscrow.moduleValidation.test.ts` - Remove DecentralizedResolutionModule tests
10. ✅ **Update:** `test/hardhat/ModuleMetadata.test.ts` - Remove DecentralizedResolutionModule tests

### Deployment Scripts

11. ✅ **Update:** `deploy/60_protocol_governance.ts` - Remove `DecentralizedResolutionModule` from `contractsToGovern` array

### Documentation Files (Move or Archive)

12. ✅ **Move/Archive:** `docs/MODULE_DEVELOPER_ROLE_DESIGN.md`
13. ✅ **Move/Archive:** `docs/MODULE_DEVELOPER_ROLE_SUMMARY.md`
14. ✅ **Move/Archive:** `docs/MODULE_UPGRADE_IMPLEMENTATION_PLAN.md` (if DecentralizedResolutionModule-specific)
15. ✅ **Move/Archive:** `docs/plans/DISPUTE_RESOLUTION_IMPLEMENTATION_PLAN.md` (if DecentralizedResolutionModule-specific)
16. ✅ **Move/Archive:** `docs/plans/DECENTRALIZED_RESOLUTION_COMPLETION_PLAN.md` (if exists)

---

## Files to Update (Remove References)

### Core Contracts

1. **`contracts/BaseEscrow.sol`**
   - **Line ~969:** Remove or update comment referencing `DecentralizedResolutionModule.recordResolution()`
   - **Action:** Update `_recordResolutionOutcome()` comment to be generic (any resolution module)

### Documentation Files

2. **`docs/governance.md`**
   - **Remove:** Entire "Module Developer (ROLE_MODULE_DEVELOPER)" section (lines ~246-270)
   - **Update:** References to DecentralizedResolutionModule upgradeability
   - **Update:** Module upgrade lane section to remove DecentralizedResolutionModule-specific content

3. **`docs/GOVERNANCE_SURFACE_MAP.md`**
   - **Remove:** DecentralizedResolutionModule function mapping table (lines ~123-142)
   - **Remove:** Module Upgrade Lane section references to DecentralizedResolutionModule
   - **Remove:** ROLE_MODULE_DEVELOPER role references

4. **`docs/SECURITY_MODEL.md`**
   - **Update:** System Overview - Remove DecentralizedResolutionModule from component list
   - **Update:** Deployment Posture - Remove future enhancement note about DecentralizedResolutionModule
   - **Update:** Remove references to ROLE_MODULE_DEVELOPER
   - **Update:** Threat model - Remove upgrade/migration risks specific to DecentralizedResolutionModule

5. **`docs/TECHNICAL_OVERVIEW.md`**
   - **Update:** Remove DecentralizedResolutionModule references
   - **Update:** Module architecture section

6. **`docs/CONTRACTS_SUMMARY.md`**
   - **Remove:** DecentralizedResolutionModule section (lines ~63-72)

7. **`docs/MODULE_MAP.md`**
   - **Update:** Remove DecentralizedResolutionModule from IResolutionModule implementations table
   - **Update:** Note that DecentralizedResolutionModule is in separate repo

8. **`docs/_DOCUMENT_INDEX.md`**
   - **Update:** Remove links to DecentralizedResolutionModule-specific docs
   - **Update:** Add note about separate repository

9. **`docs/MAINNET_CHECKLIST_ASSESSMENT.md`**
   - **Update:** Remove references to DecentralizedResolutionModule complexity

10. **`docs/OUTSTANDING_ISSUES.md`**
    - **Update:** Remove any DecentralizedResolutionModule-specific issues

### Test Files

11. **`test/hardhat/EscalationFee.test.ts`**
    - **Review:** Remove or isolate DecentralizedResolutionModule-specific escalation tests
    - **Action:** Keep only DefaultResolutionModule tests if applicable

12. **`test/hardhat/BaseEscrow.moduleValidation.test.ts`**
    - **Update:** Remove DecentralizedResolutionModule validation tests

13. **`test/hardhat/ModuleMetadata.test.ts`**
    - **Update:** Remove DecentralizedResolutionModule metadata tests

### Deployment Scripts

14. **`deploy/60_protocol_governance.ts`**
    - **Update:** Remove `'DecentralizedResolutionModule'` from `contractsToGovern` array (line 38)

### Configuration Files

15. **`scripts/print-contract-sizes.ts`**
    - **Update:** Remove DecentralizedResolutionModule from size checks (if explicitly listed)

16. **`coverage.json`**
    - **Update:** Remove DecentralizedResolutionModule from coverage (if explicitly configured)

---

## Role Removal: ROLE_MODULE_DEVELOPER

### Where ROLE_MODULE_DEVELOPER is Defined

- **DecentralizedResolutionModule.sol** (line 33) - ✅ Will be removed
- **ResolverIncentiveModule.sol** (line 33) - ✅ Will be removed

### Where ROLE_MODULE_DEVELOPER is Referenced

1. **`docs/governance.md`** - Remove entire Module Developer section
2. **`docs/GOVERNANCE_SURFACE_MAP.md`** - Remove from role permissions matrix and function mappings
3. **`docs/SECURITY_MODEL.md`** - Remove from governance roles section
4. **`docs/MODULE_DEVELOPER_ROLE_DESIGN.md`** - Move to new repo
5. **`docs/MODULE_DEVELOPER_ROLE_SUMMARY.md`** - Move to new repo

**Result:** ROLE_MODULE_DEVELOPER will be completely removed from main repo.

---

## Dependencies Analysis

### What DecentralizedResolutionModule Depends On (Must Copy to New Repo)

1. **`IResolutionModule`** interface
   - **Action:** Copy to new repo
   - **Note:** Must match exactly to maintain compatibility

2. **OpenZeppelin Contracts:**
   - `@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol`
   - `@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol`
   - `@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol`
   - `@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol`
   - `@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol`
   - **Action:** Standard dependencies, available in new repo

3. **`SlowLaneQueueActivateUpgradeable`**
   - **Action:** Move to new repo (only used by extracted modules)

### What Depends on DecentralizedResolutionModule (Must Update)

1. **`BaseEscrow.sol`**
   - **Line ~969:** Comment references DecentralizedResolutionModule
   - **Action:** Make comment generic (any resolution module)

2. **Deployment Scripts**
   - **`deploy/60_protocol_governance.ts`**
   - **Action:** Remove from contractsToGovern array

3. **Documentation**
   - Multiple docs reference it
   - **Action:** Remove or update references

**No Core Contracts Depend on DecentralizedResolutionModule:**
- ✅ `BaseEscrow`, `EscrowVault`, `EscrowableERC20` use `IResolutionModule` interface only
- ✅ `DefaultResolutionModule` is independent
- ✅ No direct imports or dependencies

---

## Interface Compatibility

### IResolutionModule Interface

**Status:** ✅ **SAFE TO EXTRACT**

- Core contracts (`BaseEscrow`, `EscrowVault`, `EscrowableERC20`) use `IResolutionModule` interface
- They do NOT import `DecentralizedResolutionModule` directly
- Any module implementing `IResolutionModule` can be swapped in
- **Action:** Copy `IResolutionModule.sol` to new repo, ensure exact match

### Verification

```solidity
// BaseEscrow.sol uses interface only:
import "../interfaces/IResolutionModule.sol";

// No direct import of DecentralizedResolutionModule
// ✅ Safe to extract
```

---

## New Repository Structure (Recommended)

```
decentralized-resolution-module/
├── contracts/
│   ├── DecentralizedResolutionModule.sol
│   ├── ResolverIncentiveModule.sol
│   ├── PaymentCalculationLibraryV1.sol
│   ├── interfaces/
│   │   ├── IResolutionModule.sol (copied from main repo)
│   │   └── IPaymentCalculationLibrary.sol
│   └── governance/
│       └── SlowLaneQueueActivateUpgradeable.sol
├── test/
│   ├── DecentralizedResolutionModule.test.ts
│   └── ResolverIncentiveModule.test.ts
├── deploy/
│   └── (deployment scripts)
├── docs/
│   ├── MODULE_DEVELOPER_ROLE_DESIGN.md
│   ├── MODULE_DEVELOPER_ROLE_SUMMARY.md
│   └── (other module-specific docs)
└── README.md
```

---

## Step-by-Step Extraction Process

### Phase 1: Preparation

1. **Create new repository**
   - Initialize with Hardhat/Foundry setup
   - Copy `foundry.toml`, `hardhat.config.ts` structure
   - Set up dependencies (OpenZeppelin, etc.)

2. **Copy interface**
   - Copy `IResolutionModule.sol` to new repo
   - Verify exact match (checksum if possible)

3. **Document interface compatibility**
   - Create doc explaining interface requirements
   - Document that interface must match main repo exactly

### Phase 2: Move Contracts

4. **Move core contracts**
   - Move DecentralizedResolutionModule.sol
   - Move ResolverIncentiveModule.sol
   - Move PaymentCalculationLibraryV1.sol
   - Move IPaymentCalculationLibrary.sol
   - Move SlowLaneQueueActivateUpgradeable.sol

5. **Update imports**
   - Fix import paths in moved contracts
   - Ensure all dependencies resolve

6. **Verify compilation**
   - Compile in new repo
   - Fix any import/dependency issues

### Phase 3: Move Tests

7. **Move test files**
   - Move DecentralizedResolutionModule.test.ts
   - Move ResolverIncentiveModule.test.ts (if exists)
   - Update test imports and setup

8. **Create test helpers**
   - Copy/create test setup helpers
   - Ensure tests run in isolation

### Phase 4: Update Main Repo

9. **Delete contracts**
   - Delete all contracts listed in "Components to Remove"
   - Verify no broken imports

10. **Update BaseEscrow.sol**
    - Update `_recordResolutionOutcome()` comment
    - Make it generic (any resolution module)

11. **Update deployment scripts**
    - Remove DecentralizedResolutionModule from `deploy/60_protocol_governance.ts`

12. **Update documentation**
    - Remove/update all references
    - Add note about separate repository
    - Update MODULE_MAP.md

13. **Remove ROLE_MODULE_DEVELOPER references**
    - Remove from all docs
    - Update governance surface map

### Phase 5: Verification

14. **Compile main repo**
    - Verify no broken imports
    - Verify all tests pass (except removed ones)

15. **Run test suite**
    - Ensure DefaultResolutionModule tests still pass
    - Ensure core escrow functionality unaffected

16. **Update documentation index**
    - Remove links to extracted docs
    - Add note about separate repo

---

## Detailed File-by-File Changes

### Contracts to Delete

| File | Lines | Action | Notes |
|------|-------|--------|-------|
| `contracts/modules/DecentralizedResolutionModule.sol` | ~1963 | Delete | Main module |
| `contracts/modules/ResolverIncentiveModule.sol` | ~729 | Delete | Coupled with DecentralizedResolutionModule |
| `contracts/modules/PaymentCalculationLibraryV1.sol` | TBD | Delete | Used by ResolverIncentiveModule |
| `contracts/interfaces/IPaymentCalculationLibrary.sol` | TBD | Delete | Interface for payment library |
| `contracts/governance/SlowLaneQueueActivateUpgradeable.sol` | 163 | Delete | Only used by extracted modules |

### Contracts to Update

| File | Change | Line(s) | Details |
|------|--------|---------|---------|
| `contracts/BaseEscrow.sol` | Update comment | ~969 | Make `_recordResolutionOutcome()` comment generic |

### Tests to Delete

| File | Action | Notes |
|------|--------|-------|
| `test/hardhat/DecentralizedResolutionModule.test.ts` | Delete | Move to new repo |
| `test/hardhat/ResolverIncentiveModule.test.ts` | Delete | If exists, move to new repo |

### Tests to Update

| File | Change | Details |
|------|--------|---------|
| `test/hardhat/EscalationFee.test.ts` | Remove DecentralizedResolutionModule tests | Keep DefaultResolutionModule tests if any |
| `test/hardhat/BaseEscrow.moduleValidation.test.ts` | Remove DecentralizedResolutionModule validation | Keep DefaultResolutionModule validation |
| `test/hardhat/ModuleMetadata.test.ts` | Remove DecentralizedResolutionModule metadata tests (lines 40-44, 84+) | Keep other module metadata tests |
| `test/hardhat/MainnetReleaseSequence.test.ts` | Review and remove DecentralizedResolutionModule references | If any exist, remove or update |

### Deployment Scripts to Update

| File | Change | Line(s) | Details |
|------|--------|---------|---------|
| `deploy/60_protocol_governance.ts` | Remove from array | 38 | Remove `'DecentralizedResolutionModule'` from `contractsToGovern` |

### Documentation Files to Move/Archive

| File | Action | Notes |
|------|--------|-------|
| `docs/MODULE_DEVELOPER_ROLE_DESIGN.md` | Move to new repo | Module developer role design |
| `docs/MODULE_DEVELOPER_ROLE_SUMMARY.md` | Move to new repo | Quick reference |
| `docs/MODULE_UPGRADE_IMPLEMENTATION_PLAN.md` | Review & move if DecentralizedResolutionModule-specific | Check content |
| `docs/plans/DISPUTE_RESOLUTION_IMPLEMENTATION_PLAN.md` | Review & move if DecentralizedResolutionModule-specific | Check content |
| `docs/plans/DECENTRALIZED_RESOLUTION_COMPLETION_PLAN.md` | Move if exists | Check if file exists |

### Documentation Files to Update

| File | Section | Change |
|------|---------|--------|
| `docs/governance.md` | Module Developer section | Remove entire section (lines ~246-270) |
| `docs/governance.md` | Module upgrade references | Remove DecentralizedResolutionModule-specific content |
| `docs/GOVERNANCE_SURFACE_MAP.md` | DecentralizedResolutionModule table | Remove function mapping table |
| `docs/GOVERNANCE_SURFACE_MAP.md` | Module Upgrade Lane | Remove DecentralizedResolutionModule references |
| `docs/GOVERNANCE_SURFACE_MAP.md` | Role permissions matrix | Remove ROLE_MODULE_DEVELOPER |
| `docs/SECURITY_MODEL.md` | System Overview | Remove DecentralizedResolutionModule from component list |
| `docs/SECURITY_MODEL.md` | Deployment Posture | Remove future enhancement note |
| `docs/SECURITY_MODEL.md` | Governance roles | Remove ROLE_MODULE_DEVELOPER |
| `docs/TECHNICAL_OVERVIEW.md` | Module architecture | Remove DecentralizedResolutionModule references |
| `docs/CONTRACTS_SUMMARY.md` | Resolution Modules | Remove DecentralizedResolutionModule section |
| `docs/MODULE_MAP.md` | IResolutionModule implementations | Remove DecentralizedResolutionModule from table (line 42), add note about separate repo |
| `docs/plans/MAINNET_DEPLOYMENT_PLAN.md` | Module deployment section | Remove DecentralizedResolutionModule from optional modules list (line 56) |
| `docs/_DOCUMENT_INDEX.md` | Links | Remove DecentralizedResolutionModule-specific doc links |

---

## Interface Compatibility Guarantee

### Critical Requirement

**`IResolutionModule` interface must match exactly between repos.**

The main repo contracts use this interface to interact with resolution modules. Any module implementing this interface can be swapped in via governance.

### Verification Steps

1. Copy `IResolutionModule.sol` to new repo
2. Verify byte-for-byte match (or use checksum)
3. Document in both repos that interface must remain compatible
4. Add interface versioning if needed in future

### Interface Location

- **Main repo:** `contracts/interfaces/IResolutionModule.sol`
- **New repo:** `contracts/interfaces/IResolutionModule.sol` (copied)

---

## Testing Strategy After Extraction

### Main Repo Tests

- ✅ DefaultResolutionModule tests should continue to pass
- ✅ Core escrow functionality unaffected
- ✅ Module swapping tests (if any) should use DefaultResolutionModule only

### New Repo Tests

- ✅ DecentralizedResolutionModule tests in isolation
- ✅ ResolverIncentiveModule tests
- ✅ Integration tests with dummy escrow contracts
- ✅ Real incentives earned during testing (as per strategy)

---

## Governance Impact

### Module Swapping

**Before Extraction:**
- DecentralizedResolutionModule available for immediate swap
- Module developer role can upgrade it

**After Extraction:**
- DecentralizedResolutionModule must be deployed separately
- Swap via slow-lane governance (queue/activate)
- No module developer role in main repo
- Module can be tested and proven before swap

### Governance Surface Reduction

**Removed from Main Repo:**
- ROLE_MODULE_DEVELOPER role
- All DecentralizedResolutionModule governance functions
- Module developer upgrade functions
- ResolverIncentiveModule governance functions

**Remaining in Main Repo:**
- DefaultResolutionModule governance (simple, low risk)
- Core escrow governance (unchanged)
- Yield module governance (unchanged)

---

## Risk Reduction

### Complexity Reduction

- **Removed:** ~2700 lines of complex resolution logic
- **Removed:** Multi-level escalation system
- **Removed:** Resolver registry management
- **Removed:** Payment calculation complexity
- **Removed:** Module developer role complexity

### Security Surface Reduction

- **Removed:** UUPS upgradeable module in main repo
- **Removed:** Module developer role attack surface
- **Removed:** Complex resolver incentive logic
- **Removed:** Payment library upgrade mechanism

### Testing Simplification

- **Simplified:** Main repo tests focus on core escrow
- **Isolated:** DecentralizedResolutionModule can be tested independently
- **Proven:** Module must be proven before mainnet swap

---

## Post-Extraction State

### Main Repo Will Have

**Resolution Modules:**
- ✅ `DefaultResolutionModule` (simple, single resolver)
- ✅ `IResolutionModule` interface (for future module swaps)

**Core Contracts:**
- ✅ `BaseEscrow`, `EscrowVault`, `EscrowableERC20` (unchanged)
- ✅ `DefaultReleaseStrategy`
- ✅ `AaveYieldGenerationModule`
- ✅ `DefaultYieldDistributionModule`

**Governance:**
- ✅ Governor, TimelockController, Guardian (unchanged)
- ❌ No ROLE_MODULE_DEVELOPER
- ❌ No DecentralizedResolutionModule governance

### New Repo Will Have

**Resolution System:**
- ✅ `DecentralizedResolutionModule`
- ✅ `ResolverIncentiveModule`
- ✅ `PaymentCalculationLibraryV1`
- ✅ `IResolutionModule` (copied)
- ✅ `IPaymentCalculationLibrary`
- ✅ `SlowLaneQueueActivateUpgradeable`

**Governance:**
- ✅ ROLE_MODULE_DEVELOPER role
- ✅ Module upgrade mechanisms
- ✅ Resolver incentive governance

---

## Integration Path (Future)

### When DecentralizedResolutionModule is Ready

1. **Deploy to Base Sepolia**
   - Deploy DecentralizedResolutionModule from new repo
   - Test with dummy disputes
   - Verify real incentives work correctly

2. **Prove in Isolation**
   - Extensive testing with real incentives
   - Resolver network testing
   - Performance validation

3. **Governance Proposal**
   - Create proposal to swap DefaultResolutionModule → DecentralizedResolutionModule
   - Use slow-lane queue/activate pattern
   - ~9 days total delay (48h queue + 7d wait + 48h activate)

4. **Mainnet Swap**
   - Execute queue proposal
   - Wait 7 days
   - Execute activate proposal
   - New escrows use DecentralizedResolutionModule

### Key Point

**No code changes needed in main repo for swap.** The interface compatibility ensures any `IResolutionModule` implementation can be swapped in via governance.

---

## Checklist

### Pre-Extraction

- [ ] Create new repository structure
- [ ] Set up build system (Hardhat/Foundry)
- [ ] Copy `IResolutionModule` interface
- [ ] Verify interface compatibility plan

### Extraction

- [ ] Move all contracts to new repo
- [ ] Move all tests to new repo
- [ ] Fix imports in new repo
- [ ] Verify compilation in new repo
- [ ] Run tests in new repo

### Main Repo Cleanup

- [ ] Delete contracts from main repo
- [ ] Delete tests from main repo
- [ ] Update BaseEscrow.sol comment
- [ ] Update deployment scripts
- [ ] Remove ROLE_MODULE_DEVELOPER references
- [ ] Update all documentation
- [ ] Verify compilation in main repo
- [ ] Run test suite in main repo
- [ ] Update documentation index

### Verification

- [ ] Main repo compiles without errors
- [ ] Main repo tests pass (except removed ones)
- [ ] No broken imports
- [ ] Documentation is consistent
- [ ] Governance surface map updated
- [ ] Security model updated

---

## Estimated Impact

### Code Reduction

- **Contracts removed:** ~2700 lines
- **Tests removed:** ~500-1000 lines (estimate)
- **Documentation:** ~2000 lines to move/update
- **Total reduction:** ~5000+ lines

### Complexity Reduction

- **High complexity modules:** 2 removed (DecentralizedResolutionModule, ResolverIncentiveModule)
- **Governance roles:** 1 removed (ROLE_MODULE_DEVELOPER)
- **Upgrade mechanisms:** 1 removed (module developer upgrades)
- **Risk surface:** Significantly reduced

### Testing Simplification

- **Complex test suites:** 2 removed
- **Integration complexity:** Reduced
- **Main repo focus:** Core escrow functionality only

---

## Notes

- **Interface compatibility is critical** - must be maintained exactly
- **No breaking changes** to core escrow contracts
- **DefaultResolutionModule remains** as the simple resolution option
- **Future swap is governance-controlled** via slow-lane queue/activate
- **Module can be proven** before mainnet integration

---

**Status:** Ready for implementation  
**Priority:** High (simplifies main repo significantly)  
**Risk:** Low (interface-based, no direct dependencies)

