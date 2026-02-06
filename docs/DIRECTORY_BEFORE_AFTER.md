# Directory Reorganization: Before & After Visual

## Current Structure (Before)

```
contracts/
├── CreateOps.sol                       ← singleton (ops)
├── YieldOps.sol                        ← singleton (ops)
├── DisputeOps.sol                      ← singleton (ops)
├── SettlementOps.sol                   ← singleton (ops)
├── ops/
│   └── GuardianOps.sol                 ← singleton (ops)
├── core/
│   ├── BaseEscrow.sol                  ← MULTI-INSTANCE (base)
│   ├── EscrowVault.sol                 ← MULTI-INSTANCE
│   ├── EscrowableERC20.sol             ← MULTI-INSTANCE
│   ├── ModuleManagementContract.sol    ← singleton (management)
│   ├── BondCollector.sol               ← singleton (management)
│   ├── EscrowAdminContract.sol         ← singleton (management)
│   ├── EscrowViewContract.sol          ← singleton (views)
│   └── modules/
│       └── DefaultResolutionModule.sol ← singleton (module)
├── modules/
│   ├── AaveYieldGenerationModule.sol   ← singleton (module)
│   ├── DefaultYieldModule.sol          ← singleton (module)
│   ├── DefaultYieldDistributionModule.sol ← singleton (module)
│   ├── DefaultReleaseStrategy.sol      ← singleton (module)
│   ├── TestYieldDistributionModule.sol ← test module
│   └── decentralized-resolution-module/
│       ├── DecentralizedResolutionModule.sol
│       ├── ResolverIncentiveModuleV1.sol
│       └── ...
├── libraries/                          ← shared utilities
├── interfaces/                         ← shared interfaces
├── governance/                         ← governance contracts
├── token/                              ← token contracts
├── admin/                              ← legacy admin
├── arbitration/                        ← external integration
├── evidence-module/                    ← domain-specific
├── registry/                           ← domain-specific
├── mocks/                              ← test mocks
├── types/                              ← shared types
└── shared/                             ← shared utilities

PROBLEM:
❌ Singletons mixed with multi-instance in contracts/core/
❌ Ops scattered (4 in root, 1 in ops/)
❌ Modules scattered (some in modules/, one in core/modules/)
❌ Not clear which contracts are deployed once vs multiple times
❌ Auditors have to read code to understand deployment model
```

---

## Proposed Structure (After)

```
contracts/
├── infrastructure/                     ← NEW: All singletons here
│   ├── ops/                            ← All ops together
│   │   ├── CreateOps.sol               ✓ singleton
│   │   ├── YieldOps.sol                ✓ singleton
│   │   ├── DisputeOps.sol              ✓ singleton
│   │   ├── SettlementOps.sol           ✓ singleton
│   │   └── GuardianOps.sol             ✓ singleton
│   ├── management/                     ← All management together
│   │   ├── ModuleManagementContract.sol ✓ singleton
│   │   ├── BondCollector.sol           ✓ singleton
│   │   └── EscrowAdminContract.sol     ✓ singleton
│   └── views/                          ← All views together
│       └── EscrowViewContract.sol      ✓ singleton
│
├── escrow/                             ← NEW: All escrow contracts here
│   ├── BaseEscrow.sol                  ✓ MULTI-INSTANCE (base)
│   ├── EscrowVault.sol                 ✓ MULTI-INSTANCE
│   └── EscrowableERC20.sol             ✓ MULTI-INSTANCE
│
├── modules/                            ← REORGANIZED: Better structure
│   ├── yield/                          ← NEW: Yield modules together
│   │   ├── AaveYieldGenerationModule.sol    ✓ singleton
│   │   ├── DefaultYieldModule.sol           ✓ singleton
│   │   ├── DefaultYieldDistributionModule.sol ✓ singleton
│   │   └── TestYieldDistributionModule.sol  ✓ test module
│   ├── resolution/                     ← NEW: Resolution modules together
│   │   ├── DefaultResolutionModule.sol      ✓ singleton
│   │   └── DefaultReleaseStrategy.sol       ✓ singleton
│   └── decentralized-resolution/       ← RENAMED: Better naming
│       ├── DecentralizedResolutionModule.sol
│       ├── ResolverIncentiveModuleV1.sol
│       └── ...
│
├── libraries/                          ← NO CHANGE
├── interfaces/                         ← NO CHANGE
├── governance/                         ← NO CHANGE
├── token/                              ← NO CHANGE
├── admin/                              ← NO CHANGE
├── arbitration/                        ← NO CHANGE
├── evidence-module/                    ← NO CHANGE
├── registry/                           ← NO CHANGE
├── mocks/                              ← NO CHANGE
├── types/                              ← NO CHANGE
└── shared/                             ← NO CHANGE

BENEFITS:
✅ Clear: infrastructure/ = deploy once
✅ Clear: escrow/ = deploy per type
✅ All ops together in one place
✅ All management contracts together
✅ Modules grouped by domain (yield, resolution, DR)
✅ Auditors immediately understand deployment model
✅ Developers know where to find things
```

---

## Key Moves Summary

### Singleton Infrastructure (12 contracts moved)

```
BEFORE                                    AFTER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
contracts/CreateOps.sol          →  infrastructure/ops/CreateOps.sol
contracts/YieldOps.sol           →  infrastructure/ops/YieldOps.sol
contracts/DisputeOps.sol         →  infrastructure/ops/DisputeOps.sol
contracts/SettlementOps.sol      →  infrastructure/ops/SettlementOps.sol
contracts/ops/GuardianOps.sol    →  infrastructure/ops/GuardianOps.sol

core/ModuleManagementContract.sol →  infrastructure/management/ModuleManagementContract.sol
core/BondCollector.sol            →  infrastructure/management/BondCollector.sol
core/EscrowAdminContract.sol      →  infrastructure/management/EscrowAdminContract.sol

core/EscrowViewContract.sol       →  infrastructure/views/EscrowViewContract.sol
```

### Multi-Instance Escrow (3 contracts moved)

```
BEFORE                            AFTER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
core/BaseEscrow.sol        →  escrow/BaseEscrow.sol
core/EscrowVault.sol       →  escrow/EscrowVault.sol
core/EscrowableERC20.sol   →  escrow/EscrowableERC20.sol
```

### Module Reorganization (8+ contracts moved/renamed)

```
BEFORE                                          AFTER
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
modules/AaveYieldGenerationModule.sol     →  modules/yield/AaveYieldGenerationModule.sol
modules/DefaultYieldModule.sol            →  modules/yield/DefaultYieldModule.sol
modules/DefaultYieldDistributionModule.sol →  modules/yield/DefaultYieldDistributionModule.sol
modules/TestYieldDistributionModule.sol   →  modules/yield/TestYieldDistributionModule.sol

core/modules/DefaultResolutionModule.sol  →  modules/resolution/DefaultResolutionModule.sol
modules/DefaultReleaseStrategy.sol        →  modules/resolution/DefaultReleaseStrategy.sol

modules/decentralized-resolution-module/  →  modules/decentralized-resolution/
  (all files within directory)
```

---

## Deployment Model Clarity

### Before (Unclear)
```
Auditor looks at contracts/core/:
- BaseEscrow.sol (multi-instance? singleton? unclear)
- EscrowVault.sol (multi-instance? singleton? unclear)
- ModuleManagementContract.sol (multi-instance? singleton? unclear)
- BondCollector.sol (multi-instance? singleton? unclear)

❌ Must read code to understand deployment model
❌ Must trace dependencies to understand relationships
❌ High cognitive load
```

### After (Clear)
```
Auditor looks at directory structure:

infrastructure/
  ✓ All contracts here are singletons (deploy once)
  ✓ Shared by all escrow types
  ✓ Clear purpose: ops, management, views

escrow/
  ✓ All contracts here are multi-instance (deploy per type)
  ✓ Base + implementations clearly grouped
  ✓ Clear purpose: escrow contract types

modules/
  ✓ Modules grouped by domain
  ✓ yield/ = yield-related modules
  ✓ resolution/ = resolution-related modules
  ✓ Clear purpose: pluggable modules

✅ Immediate understanding from directory structure
✅ No need to read code to understand deployment
✅ Low cognitive load
```

---

## Import Path Changes

### Examples

**Before:**
```solidity
import './contracts/core/BaseEscrow.sol';
import './contracts/CreateOps.sol';
import './contracts/core/ModuleManagementContract.sol';
import './contracts/modules/AaveYieldGenerationModule.sol';
```

**After:**
```solidity
import './contracts/escrow/BaseEscrow.sol';
import './contracts/infrastructure/ops/CreateOps.sol';
import './contracts/infrastructure/management/ModuleManagementContract.sol';
import './contracts/modules/yield/AaveYieldGenerationModule.sol';
```

**Or with remappings:**
```solidity
import '@escrow/BaseEscrow.sol';
import '@infrastructure/ops/CreateOps.sol';
import '@infrastructure/management/ModuleManagementContract.sol';
import '@modules/yield/AaveYieldGenerationModule.sol';
```

---

## File Count Summary

| Category | Files Moved | New Directories |
|----------|-------------|-----------------|
| Infrastructure (Ops) | 5 | infrastructure/ops/ |
| Infrastructure (Management) | 3 | infrastructure/management/ |
| Infrastructure (Views) | 1 | infrastructure/views/ |
| Escrow Contracts | 3 | escrow/ |
| Module Reorganization | 8+ | modules/yield/, modules/resolution/ |
| **TOTAL** | **20+** | **6** |

---

## Risk Mitigation

### Testing Strategy

```
After each batch:
1. Compile: forge build && npm run compile
2. Test: forge test && npm test
3. Check: grep for old imports
4. Verify: manual inspection of moved files

Full verification:
1. All tests passing (currently 25 Aave tests + existing)
2. No compilation errors
3. No broken imports
4. Documentation updated
```

### Rollback Strategy

```
Git tracks all moves, so rollback is simple:
git reset --hard HEAD  (before commit)
git revert <commit>    (after commit)
```

---

## Timeline: 4 Hours

```
Phase 1: Create directories              5 min
Phase 2a: Move escrow contracts         30 min
Phase 2b: Update imports (escrow)       30 min
Phase 2c: Test                          10 min
Phase 2d: Move ops contracts            20 min
Phase 2e: Update imports (ops)          30 min
Phase 2f: Test                          10 min
Phase 2g: Move management               15 min
Phase 2h: Update imports (mgmt)         20 min
Phase 2i: Test                          10 min
Phase 2j: Module reorganization         20 min
Phase 2k: Update imports (modules)      20 min
Phase 2l: Test                          10 min
Phase 3: Final verification             20 min
Phase 4: Documentation                  30 min
────────────────────────────────────────────────
TOTAL:                                  ~4 hours
```

---

## Decision Matrix

| Option | Clarity | Disruption | Time | Recommended |
|--------|---------|------------|------|-------------|
| Full Reorganization | ⭐⭐⭐⭐⭐ | Medium | 4 hours | ✅ **YES** |
| Partial (README only) | ⭐⭐ | None | 30 min | ⚠️ Temporary |
| Do Nothing | ⭐ | None | 0 min | ❌ No |

**Recommendation:** Full reorganization for maximum long-term value

