# Directory Reorganization Proposal: Singleton vs Multi-Instance Clarity

**Date:** 2026-02-04  
**Goal:** Reorganize contracts for auditor clarity - distinguish singletons from multi-instance  
**Principle:** Minimize disruption while maximizing clarity

---

## Current Problem

Auditors need to quickly understand:
1. Which contracts are deployed ONCE (singletons, shared infrastructure)
2. Which contracts are deployed MULTIPLE times (per escrow type)
3. What depends on what

Current structure mixes these concepts in `contracts/core/`:
- `BaseEscrow.sol` (multi-instance base)
- `EscrowVault.sol` (multi-instance)
- `EscrowableERC20.sol` (multi-instance)
- `ModuleManagementContract.sol` (singleton)
- `BondCollector.sol` (singleton)
- `EscrowAdminContract.sol` (singleton)
- `EscrowViewContract.sol` (singleton)

---

## Proposed Structure

```
contracts/
  ├── infrastructure/          ← NEW: Singleton contracts (deploy once)
  │   ├── ops/
  │   │   ├── CreateOps.sol
  │   │   ├── YieldOps.sol
  │   │   ├── DisputeOps.sol
  │   │   ├── SettlementOps.sol
  │   │   └── GuardianOps.sol
  │   ├── management/
  │   │   ├── ModuleManagementContract.sol
  │   │   ├── BondCollector.sol
  │   │   └── EscrowAdminContract.sol
  │   └── views/
  │       └── EscrowViewContract.sol
  │
  ├── escrow/                  ← NEW: Multi-instance escrow contracts
  │   ├── BaseEscrow.sol        (abstract base)
  │   ├── EscrowVault.sol       (vault implementation)
  │   └── EscrowableERC20.sol   (ERC20 implementation)
  │
  ├── modules/                  ← EXISTING: Module contracts
  │   ├── yield/                ← NEW SUBDIRECTORY
  │   │   ├── AaveYieldGenerationModule.sol  (singleton)
  │   │   ├── DefaultYieldModule.sol          (singleton)
  │   │   └── DefaultYieldDistributionModule.sol (singleton)
  │   ├── resolution/           ← NEW SUBDIRECTORY
  │   │   ├── DefaultResolutionModule.sol     (singleton)
  │   │   └── DefaultReleaseStrategy.sol      (singleton)
  │   └── decentralized-resolution/  ← MOVE FROM ROOT
  │       ├── DecentralizedResolutionModule.sol
  │       ├── ResolverIncentiveModuleV1.sol
  │       ├── ResolverStakingModuleV1.sol
  │       └── ...
  │
  ├── libraries/               ← EXISTING: No changes
  │   └── (all library files)
  │
  ├── interfaces/              ← EXISTING: No changes
  │   └── (all interface files)
  │
  ├── governance/              ← EXISTING: No changes
  │   └── (governance contracts)
  │
  ├── token/                   ← EXISTING: No changes
  │   └── SewToken.sol
  │
  ├── admin/                   ← EXISTING: No changes (legacy admin)
  ├── arbitration/             ← EXISTING: No changes
  ├── evidence-module/         ← EXISTING: No changes
  ├── registry/                ← EXISTING: No changes
  ├── mocks/                   ← EXISTING: No changes
  ├── types/                   ← EXISTING: No changes
  └── shared/                  ← EXISTING: No changes
```

---

## Key Changes

### 1. Create `contracts/infrastructure/` ✅

**Purpose:** Singleton contracts deployed once, shared by all escrows

**Move:**
```
FROM: contracts/
  CreateOps.sol         → infrastructure/ops/CreateOps.sol
  YieldOps.sol          → infrastructure/ops/YieldOps.sol
  DisputeOps.sol        → infrastructure/ops/DisputeOps.sol
  SettlementOps.sol     → infrastructure/ops/SettlementOps.sol
  ops/GuardianOps.sol   → infrastructure/ops/GuardianOps.sol

FROM: contracts/core/
  ModuleManagementContract.sol → infrastructure/management/ModuleManagementContract.sol
  BondCollector.sol            → infrastructure/management/BondCollector.sol
  EscrowAdminContract.sol      → infrastructure/management/EscrowAdminContract.sol
  EscrowViewContract.sol       → infrastructure/views/EscrowViewContract.sol
```

**Rationale:**
- Clear separation: "infrastructure" = deploy once
- Grouped by function (ops, management, views)
- Auditors immediately know these are singletons

---

### 2. Create `contracts/escrow/` ✅

**Purpose:** Multi-instance escrow contracts (deploy per type)

**Move:**
```
FROM: contracts/core/
  BaseEscrow.sol        → escrow/BaseEscrow.sol
  EscrowVault.sol       → escrow/EscrowVault.sol
  EscrowableERC20.sol   → escrow/EscrowableERC20.sol
```

**Rationale:**
- Clear separation: "escrow" = deploy multiple times
- All escrow implementations in one place
- Auditors immediately know these are multi-instance

---

### 3. Reorganize `contracts/modules/` ✅

**Purpose:** Better organization of module types

**Changes:**
```
CREATE: modules/yield/
  Move: AaveYieldGenerationModule.sol     → modules/yield/
  Move: DefaultYieldModule.sol            → modules/yield/
  Move: DefaultYieldDistributionModule.sol → modules/yield/
  Keep: TestYieldDistributionModule.sol   → modules/yield/ (or test/)

CREATE: modules/resolution/
  Move: DefaultResolutionModule.sol       → modules/resolution/ (from core/modules/)
  Move: DefaultReleaseStrategy.sol        → modules/resolution/

MOVE: contracts/modules/decentralized-resolution-module/
  → modules/decentralized-resolution/
  (All DR module files move here)
```

**Rationale:**
- Modules grouped by type (yield, resolution, DR)
- Clear domain separation
- All modules under one parent directory

---

### 4. Keep Everything Else As-Is ✅

**No changes to:**
- `libraries/` - No change needed
- `interfaces/` - No change needed
- `governance/` - Separate concern
- `token/` - Separate concern
- `admin/` - Legacy, may be deprecated
- `arbitration/` - External integration
- `evidence-module/` - Domain-specific (evidence)
- `registry/` - Domain-specific (registry)
- `mocks/` - Test infrastructure
- `types/` - Shared types
- `shared/` - Shared utilities

---

## Benefits

### For Auditors ✅

1. **Immediate Clarity:**
   ```
   infrastructure/ = Deploy once (12 contracts)
   escrow/        = Deploy per type (3 files: 1 base + 2 implementations)
   modules/       = Mixed (mostly singletons with registration)
   ```

2. **Deployment Model Visible:**
   - See `infrastructure/` → know these are shared singletons
   - See `escrow/` → know these are per-type deployments
   - See base + implementations together

3. **Dependency Tracking:**
   ```
   escrow/EscrowVault.sol
     ↓ depends on
   infrastructure/ops/*.sol
   infrastructure/management/*.sol
   modules/yield/*.sol
   ```

### For Developers ✅

1. **Clear Organization:**
   - Want to add a new escrow type? Look in `escrow/`
   - Want to modify ops logic? Look in `infrastructure/ops/`
   - Want to add a yield module? Look in `modules/yield/`

2. **Reduced Confusion:**
   - No more "where does this go?"
   - Clear patterns for new contracts

3. **Better Discoverability:**
   - Related contracts grouped together
   - Domain separation clear

---

## Migration Plan

### Phase 1: Create New Directories ✅
```bash
mkdir -p contracts/infrastructure/ops
mkdir -p contracts/infrastructure/management
mkdir -p contracts/infrastructure/views
mkdir -p contracts/escrow
mkdir -p contracts/modules/yield
mkdir -p contracts/modules/resolution
```

### Phase 2: Move Files (Grouped by Risk) ✅

**Batch 1: Escrow Contracts (Highest Risk - Many Dependencies)**
```bash
git mv contracts/core/BaseEscrow.sol contracts/escrow/
git mv contracts/core/EscrowVault.sol contracts/escrow/
git mv contracts/core/EscrowableERC20.sol contracts/escrow/
```

**Batch 2: Ops Contracts (Medium Risk - Many Imports)**
```bash
git mv contracts/CreateOps.sol contracts/infrastructure/ops/
git mv contracts/YieldOps.sol contracts/infrastructure/ops/
git mv contracts/DisputeOps.sol contracts/infrastructure/ops/
git mv contracts/SettlementOps.sol contracts/infrastructure/ops/
git mv contracts/ops/GuardianOps.sol contracts/infrastructure/ops/
```

**Batch 3: Management Contracts (Low Risk)**
```bash
git mv contracts/core/ModuleManagementContract.sol contracts/infrastructure/management/
git mv contracts/core/BondCollector.sol contracts/infrastructure/management/
git mv contracts/core/EscrowAdminContract.sol contracts/infrastructure/management/
git mv contracts/core/EscrowViewContract.sol contracts/infrastructure/views/
```

**Batch 4: Module Reorganization (Low Risk)**
```bash
git mv contracts/modules/AaveYieldGenerationModule.sol contracts/modules/yield/
git mv contracts/modules/DefaultYieldModule.sol contracts/modules/yield/
git mv contracts/modules/DefaultYieldDistributionModule.sol contracts/modules/yield/
git mv contracts/modules/TestYieldDistributionModule.sol contracts/modules/yield/
git mv contracts/core/modules/DefaultResolutionModule.sol contracts/modules/resolution/
git mv contracts/modules/DefaultReleaseStrategy.sol contracts/modules/resolution/
git mv contracts/modules/decentralized-resolution-module contracts/modules/decentralized-resolution
```

### Phase 3: Update Imports ✅

**Automated with sed/script:**
```bash
# Update all imports
find contracts/ test/ deploy/ -name "*.sol" -o -name "*.ts" | while read file; do
  sed -i 's|contracts/core/BaseEscrow.sol|contracts/escrow/BaseEscrow.sol|g' "$file"
  sed -i 's|contracts/core/EscrowVault.sol|contracts/escrow/EscrowVault.sol|g' "$file"
  # ... (full list in implementation)
done
```

### Phase 4: Update Hardhat Config ✅

**Update `hardhat.config.ts`:**
```typescript
// Add remappings
remappings: [
  '@escrow/=contracts/escrow/',
  '@infrastructure/=contracts/infrastructure/',
  '@modules/=contracts/modules/',
  // ... existing remappings
]
```

### Phase 5: Verify ✅

```bash
# Compile
forge build
npm run compile

# Test
forge test
npm test

# Check imports
grep -r "contracts/core/BaseEscrow" contracts/ test/ deploy/
# Should return nothing if migration complete
```

---

## Risk Assessment

### Low Risk ✅

1. **Module Reorganization:**
   - Files mostly self-contained
   - Few cross-dependencies
   - Easy to test

2. **Management Contracts:**
   - Well-defined interfaces
   - Clear import paths

### Medium Risk ⚠️

1. **Ops Contracts:**
   - Used by many other contracts
   - Need to update many imports
   - Extensive testing required

### Higher Risk 🔴

1. **Escrow Contracts:**
   - Core functionality
   - Many dependencies and dependents
   - BaseEscrow is abstract base for Vault and ERC20
   - Test suite comprehensive

**Mitigation:**
- Test after each batch
- Verify compilation after each move
- Run full test suite after each phase

---

## Timeline

| Phase | Task | Time | Risk |
|-------|------|------|------|
| 1 | Create directories | 5 min | 🟢 None |
| 2a | Move escrow contracts | 30 min | 🔴 High |
| 2b | Update imports (batch 1) | 30 min | 🔴 High |
| 2c | Test (batch 1) | 10 min | - |
| 2d | Move ops contracts | 20 min | ⚠️ Med |
| 2e | Update imports (batch 2) | 30 min | ⚠️ Med |
| 2f | Test (batch 2) | 10 min | - |
| 2g | Move management contracts | 15 min | �� Low |
| 2h | Update imports (batch 3) | 20 min | 🟢 Low |
| 2i | Test (batch 3) | 10 min | - |
| 2j | Reorganize modules | 20 min | 🟢 Low |
| 2k | Update imports (batch 4) | 20 min | 🟢 Low |
| 2l | Test (batch 4) | 10 min | - |
| 3 | Final verification | 20 min | - |
| 4 | Documentation update | 30 min | - |
| **TOTAL** | | **~4 hours** | |

---

## Rollback Plan

If issues arise:
```bash
# We're using git mv, so rollback is:
git reset --hard HEAD

# Or if committed:
git revert <commit-hash>
```

---

## Documentation Updates Needed

1. **README.md** - Update architecture section
2. **docs/architecture/** - Update all architecture docs
3. **DEPLOYMENT.md** - Update deployment guide
4. **Session docs** - Update singleton vs multi-instance diagrams

---

## Alternative: Minimal Disruption Option

If full reorganization is too disruptive, minimal option:

**Just create two README files:**
```
contracts/ARCHITECTURE.md:
  - List all singletons with locations
  - List all multi-instance with locations
  - Explain deployment model

contracts/core/README.md:
  - Explain what's in core/
  - Mark which are singletons vs multi-instance
```

**Effort:** 30 minutes  
**Risk:** None  
**Benefit:** Partial clarity, zero code changes

---

## Recommendation

**Proceed with full reorganization:**

✅ **Pros:**
- Maximum clarity for auditors
- Better long-term maintainability
- Clear patterns for future development
- Industry standard structure

⚠️ **Cons:**
- 4 hours of work
- Need to update imports
- Risk of breaking something (mitigated by testing)

**Decision:** Full reorganization provides the most value and clarity. The time investment is justified by the long-term benefits, especially for security audits.

---

## Next Steps

1. ✅ Create feature branch: `feat/directory-reorganization`
2. ✅ Execute Phase 1-5 as outlined
3. ✅ Full test suite verification
4. ✅ Update documentation
5. ✅ PR for review
6. ✅ Merge to main

---

**Status:** 📋 PROPOSAL READY FOR APPROVAL
