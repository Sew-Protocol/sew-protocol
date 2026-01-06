# Extraction Approach Analysis: Monorepo vs Separate Repos

**Date:** 2026-01-06  
**Purpose:** Analyze the most effective approach for extracting DecentralizedResolutionModule  
**Considerations:** Cursor effectiveness, clarity, ease of development and testing

---

## Current State

### Repository Structure
- **Single repository** with flat structure
- **Hybrid build system:** Hardhat (TypeScript) + Foundry (Solidity)
- **Package manager:** pnpm (workspace support exists but minimal)
- **Shared dependencies:**
  - `contracts/interfaces/IResolutionModule.sol` (used by both core and DecentralizedResolutionModule)
  - `contracts/governance/SlowLaneQueueActivateUpgradeable.sol` (used by DecentralizedResolutionModule and ResolverIncentiveModule)
  - OpenZeppelin contracts (shared)
  - Shared test utilities and helpers

### Current Import Patterns
```solidity
// DecentralizedResolutionModule.sol
import "../interfaces/IResolutionModule.sol";
import "../governance/SlowLaneQueueActivateUpgradeable.sol";
import "./ResolverIncentiveModule.sol";
```

### Dependencies
- **DecentralizedResolutionModule depends on:**
  - `IResolutionModule` interface (shared with core)
  - `SlowLaneQueueActivateUpgradeable` (only used by extracted modules)
  - `ResolverIncentiveModule` (extracted together)
  - OpenZeppelin upgradeable contracts

- **Core contracts depend on:**
  - `IResolutionModule` interface (not implementation)
  - No direct dependency on DecentralizedResolutionModule

---

## Option 1: Separate Repositories

### Structure
```
hardhat-deploy-hybrid/          (main repo)
├── contracts/
│   ├── BaseEscrow.sol
│   ├── EscrowVault.sol
│   ├── EscrowableERC20.sol
│   ├── interfaces/
│   │   └── IResolutionModule.sol
│   └── modules/
│       └── DefaultResolutionModule.sol

decentralized-resolution-module/  (new repo)
├── contracts/
│   ├── DecentralizedResolutionModule.sol
│   ├── ResolverIncentiveModule.sol
│   ├── PaymentCalculationLibraryV1.sol
│   ├── interfaces/
│   │   ├── IResolutionModule.sol (copied)
│   │   └── IPaymentCalculationLibrary.sol
│   └── governance/
│       └── SlowLaneQueueActivateUpgradeable.sol
```

### Pros
✅ **Complete isolation** - Clear boundaries, no accidental coupling  
✅ **Independent versioning** - Each repo can version independently  
✅ **Separate CI/CD** - Different deployment pipelines  
✅ **Clear ownership** - Different teams can own different repos  
✅ **Reduced main repo complexity** - Main repo stays focused on core escrow  
✅ **Independent release cycles** - Module can iterate without affecting main repo

### Cons
❌ **Interface synchronization** - Must manually keep `IResolutionModule` in sync  
❌ **Duplicate dependencies** - OpenZeppelin, build configs duplicated  
❌ **Harder cross-repo refactoring** - Changes to interface require coordination  
❌ **More complex testing** - Integration tests require both repos  
❌ **Cursor limitations** - Can't see both codebases simultaneously easily  
❌ **Deployment complexity** - Need to coordinate deployments  
❌ **Documentation split** - Related docs in different places

### Cursor Perspective
- **Code navigation:** Limited - can only see one repo at a time
- **Refactoring:** Difficult - interface changes require manual sync
- **Code understanding:** Fragmented - can't see full context
- **Search:** Limited - must search each repo separately
- **AI assistance:** Less effective - can't understand full system context

---

## Option 2: Monorepo with Packages (Recommended)

### Structure
```
hardhat-deploy-hybrid/
├── packages/
│   ├── core/
│   │   ├── contracts/
│   │   │   ├── BaseEscrow.sol
│   │   │   ├── EscrowVault.sol
│   │   │   ├── EscrowableERC20.sol
│   │   │   ├── interfaces/
│   │   │   │   └── IResolutionModule.sol
│   │   │   └── modules/
│   │   │       └── DefaultResolutionModule.sol
│   │   ├── test/
│   │   ├── deploy/
│   │   ├── package.json
│   │   └── hardhat.config.ts
│   │
│   └── decentralized-resolution-module/
│       ├── contracts/
│       │   ├── DecentralizedResolutionModule.sol
│       │   ├── ResolverIncentiveModule.sol
│       │   ├── PaymentCalculationLibraryV1.sol
│       │   ├── interfaces/
│       │   │   └── IPaymentCalculationLibrary.sol
│       │   └── governance/
│       │       └── SlowLaneQueueActivateUpgradeable.sol
│       ├── test/
│       ├── package.json
│       └── hardhat.config.ts
│
├── packages/
│   └── shared/
│       ├── contracts/
│       │   ├── interfaces/
│       │   │   └── IResolutionModule.sol
│       │   └── governance/
│       │       └── SlowLaneQueueActivateUpgradeable.sol
│       └── package.json
│
├── pnpm-workspace.yaml
├── package.json (root)
└── hardhat.config.ts (root, if needed)
```

### Alternative: Simpler Package Structure
```
hardhat-deploy-hybrid/
├── packages/
│   ├── core/
│   │   ├── contracts/
│   │   │   ├── BaseEscrow.sol
│   │   │   ├── EscrowVault.sol
│   │   │   ├── EscrowableERC20.sol
│   │   │   └── modules/
│   │   │       └── DefaultResolutionModule.sol
│   │   └── package.json
│   │
│   └── decentralized-resolution-module/
│       ├── contracts/
│       │   ├── DecentralizedResolutionModule.sol
│       │   ├── ResolverIncentiveModule.sol
│       │   └── ...
│       └── package.json
│
├── contracts/  (shared - at root level)
│   ├── interfaces/
│   │   └── IResolutionModule.sol
│   └── governance/
│       └── SlowLaneQueueActivateUpgradeable.sol
│
└── pnpm-workspace.yaml
```

### Pros
✅ **Single source of truth** - `IResolutionModule` defined once, used by both  
✅ **Cursor effectiveness** - Can see entire codebase, better context understanding  
✅ **Easy refactoring** - Changes to shared interfaces automatically propagate  
✅ **Unified testing** - Can test integration easily, shared test utilities  
✅ **Single build system** - One command to build/test everything  
✅ **Shared dependencies** - OpenZeppelin, configs defined once  
✅ **Better code navigation** - Jump between packages seamlessly  
✅ **Type safety** - TypeScript can understand cross-package dependencies  
✅ **Documentation co-location** - Related docs in same repo  
✅ **Deployment coordination** - Easier to coordinate deployments  
✅ **Version management** - Can use workspace protocol for internal deps

### Cons
⚠️ **Package boundaries** - Must be disciplined about imports (enforced via package.json)  
⚠️ **Slightly more complex** - Need to understand monorepo structure  
⚠️ **Build coordination** - Need to ensure build order (solved by pnpm workspaces)

### Cursor Perspective
- **Code navigation:** Excellent - can see all packages, jump between them
- **Refactoring:** Excellent - changes propagate automatically, AI understands full context
- **Code understanding:** Complete - sees entire system, better suggestions
- **Search:** Comprehensive - searches across all packages
- **AI assistance:** Highly effective - understands relationships, can suggest cross-package improvements

---

## Option 3: Hybrid Approach (Packages with Shared Contracts)

### Structure
```
hardhat-deploy-hybrid/
├── packages/
│   ├── core/
│   │   └── contracts/...
│   │
│   └── decentralized-resolution-module/
│       └── contracts/...
│
├── contracts/  (shared at root)
│   ├── interfaces/
│   │   └── IResolutionModule.sol
│   └── governance/
│       ├── SlowLaneQueueActivateUpgradeable.sol
│       └── SlowLaneQueueActivate.sol
│
└── test/  (shared at root)
    └── helpers/
```

### Pros
✅ **Clear separation** - Packages are independent  
✅ **Shared contracts** - Interfaces and governance at root level  
✅ **Simple imports** - Packages import from root `contracts/`  
✅ **Cursor friendly** - Can see everything, clear structure

### Cons
⚠️ **Root-level contracts** - Some shared code not in packages  
⚠️ **Import paths** - Need to configure remappings/paths correctly

---

## Detailed Comparison

### Development Experience

| Aspect | Separate Repos | Monorepo Packages | Hybrid |
|--------|---------------|-------------------|--------|
| **Setup complexity** | Medium (2 repos) | Low (1 repo, pnpm workspaces) | Low |
| **Build/test commands** | `cd repo1 && pnpm test` | `pnpm test` (runs all) | `pnpm test` |
| **Dependency management** | Manual sync | Automatic (workspace protocol) | Automatic |
| **Interface changes** | Manual copy | Automatic propagation | Automatic |
| **Cross-package refactoring** | Difficult | Easy | Easy |

### Cursor/AI Effectiveness

| Aspect | Separate Repos | Monorepo Packages | Hybrid |
|--------|---------------|-------------------|--------|
| **Context understanding** | Limited (one repo) | Full (all packages) | Full |
| **Code navigation** | Limited | Excellent | Excellent |
| **Refactoring suggestions** | Limited | Excellent | Excellent |
| **Search across codebase** | Manual (2 searches) | Automatic (all packages) | Automatic |
| **Understanding relationships** | Difficult | Easy | Easy |

### Testing

| Aspect | Separate Repos | Monorepo Packages | Hybrid |
|--------|---------------|-------------------|--------|
| **Unit tests** | Easy (isolated) | Easy (isolated) | Easy |
| **Integration tests** | Complex (need both repos) | Easy (all in one repo) | Easy |
| **Shared test utilities** | Duplicate or external | Single source | Single source |
| **Test coverage** | Separate reports | Unified or separate | Unified or separate |

### Clarity

| Aspect | Separate Repos | Monorepo Packages | Hybrid |
|--------|---------------|-------------------|--------|
| **Package boundaries** | Very clear (different repos) | Clear (package.json) | Clear |
| **Dependencies** | Hidden (manual sync) | Explicit (package.json) | Explicit |
| **Ownership** | Very clear | Clear (package ownership) | Clear |
| **Documentation** | Split | Co-located | Co-located |

### Maintenance

| Aspect | Separate Repos | Monorepo Packages | Hybrid |
|--------|---------------|-------------------|--------|
| **Interface sync** | Manual (error-prone) | Automatic | Automatic |
| **Version management** | Independent | Workspace protocol | Workspace protocol |
| **CI/CD** | Separate pipelines | Unified or separate | Unified or separate |
| **Deployment** | Coordinated manually | Easier coordination | Easier coordination |

---

## Recommendation: Monorepo with Packages (Option 2)

### Why This Approach?

1. **Cursor/AI Effectiveness** ⭐⭐⭐⭐⭐
   - Cursor can see entire codebase
   - Better context for AI suggestions
   - Easier refactoring across packages
   - Better code navigation

2. **Development Experience** ⭐⭐⭐⭐⭐
   - Single command to test/build everything
   - Shared dependencies (OpenZeppelin, configs)
   - Easy cross-package refactoring
   - Type safety across packages

3. **Clarity** ⭐⭐⭐⭐
   - Clear package boundaries via `package.json`
   - Explicit dependencies
   - Single source of truth for interfaces
   - Co-located documentation

4. **Testing** ⭐⭐⭐⭐⭐
   - Easy integration testing
   - Shared test utilities
   - Can test packages in isolation or together

### Implementation Strategy

#### Phase 1: Setup Monorepo Structure
```bash
# Create package structure
mkdir -p packages/core/contracts
mkdir -p packages/decentralized-resolution-module/contracts
mkdir -p packages/shared/contracts/interfaces
mkdir -p packages/shared/contracts/governance

# Move contracts
mv contracts/BaseEscrow.sol packages/core/contracts/
mv contracts/EscrowVault.sol packages/core/contracts/
mv contracts/EscrowableERC20.sol packages/core/contracts/
mv contracts/modules/DefaultResolutionModule.sol packages/core/contracts/modules/

mv contracts/modules/DecentralizedResolutionModule.sol packages/decentralized-resolution-module/contracts/
mv contracts/modules/ResolverIncentiveModule.sol packages/decentralized-resolution-module/contracts/
mv contracts/modules/PaymentCalculationLibraryV1.sol packages/decentralized-resolution-module/contracts/

mv contracts/interfaces/IResolutionModule.sol packages/shared/contracts/interfaces/
mv contracts/governance/SlowLaneQueueActivateUpgradeable.sol packages/shared/contracts/governance/
```

#### Phase 2: Configure pnpm Workspaces
```yaml
# pnpm-workspace.yaml
packages:
  - 'packages/*'
```

#### Phase 3: Package.json Configuration
```json
// packages/core/package.json
{
  "name": "@escrow/core",
  "version": "1.0.0",
  "dependencies": {
    "@escrow/shared": "workspace:*"
  }
}

// packages/decentralized-resolution-module/package.json
{
  "name": "@escrow/decentralized-resolution-module",
  "version": "1.0.0",
  "dependencies": {
    "@escrow/shared": "workspace:*"
  }
}

// packages/shared/package.json
{
  "name": "@escrow/shared",
  "version": "1.0.0"
}
```

#### Phase 4: Update Import Paths
```solidity
// packages/core/contracts/BaseEscrow.sol
import "@escrow/shared/contracts/interfaces/IResolutionModule.sol";

// packages/decentralized-resolution-module/contracts/DecentralizedResolutionModule.sol
import "@escrow/shared/contracts/interfaces/IResolutionModule.sol";
import "@escrow/shared/contracts/governance/SlowLaneQueueActivateUpgradeable.sol";
```

#### Phase 5: Configure Remappings (Foundry)
```toml
# foundry.toml (root or per package)
remappings = [
  "@escrow/shared/=packages/shared/contracts/",
  "@escrow/core/=packages/core/contracts/",
  "@escrow/decentralized-resolution-module/=packages/decentralized-resolution-module/contracts/",
  "@openzeppelin/=node_modules/@openzeppelin/"
]
```

#### Phase 6: Update Hardhat Config
```typescript
// Can use path aliases or keep relative imports
// Or configure Hardhat to understand workspace structure
```

---

## Alternative: Simpler Structure (Recommended for Start)

If the full package structure feels too complex initially, start with:

```
hardhat-deploy-hybrid/
├── contracts/
│   ├── core/              (new)
│   │   ├── BaseEscrow.sol
│   │   ├── EscrowVault.sol
│   │   └── EscrowableERC20.sol
│   │
│   ├── decentralized-resolution-module/  (new)
│   │   ├── DecentralizedResolutionModule.sol
│   │   ├── ResolverIncentiveModule.sol
│   │   └── PaymentCalculationLibraryV1.sol
│   │
│   ├── interfaces/        (shared)
│   │   └── IResolutionModule.sol
│   │
│   └── governance/         (shared)
│       └── SlowLaneQueueActivateUpgradeable.sol
```

**Benefits:**
- Simpler migration (just reorganize folders)
- No package.json complexity
- Still clear separation
- Cursor can see everything
- Easy to evolve into packages later if needed

**Trade-off:**
- Less explicit boundaries (but clearer folder structure)
- No workspace protocol (but can add later)

---

## Decision Matrix

| Criteria | Weight | Separate Repos | Monorepo Packages | Simple Folders |
|----------|--------|----------------|-------------------|----------------|
| **Cursor/AI effectiveness** | High | 2/5 | 5/5 | 4/5 |
| **Development ease** | High | 3/5 | 5/5 | 4/5 |
| **Clarity** | Medium | 5/5 | 4/5 | 4/5 |
| **Testing** | High | 3/5 | 5/5 | 4/5 |
| **Maintenance** | Medium | 3/5 | 5/5 | 4/5 |
| **Migration effort** | Low | 3/5 | 2/5 | 5/5 |
| **Total** | | **19/30** | **26/30** | **25/30** |

---

## Final Recommendation

**Start with Simple Folder Structure**, then evolve to **Monorepo Packages** if needed.

### Phase 1: Simple Reorganization (Immediate)
- Move contracts into `contracts/core/` and `contracts/decentralized-resolution-module/`
- Keep shared interfaces/governance at `contracts/interfaces/` and `contracts/governance/`
- Update import paths
- **Benefit:** Immediate clarity, minimal migration effort, Cursor-friendly

### Phase 2: Evolve to Packages (If Needed)
- If boundaries become unclear or dependencies complex
- Convert to pnpm workspace packages
- Add explicit package.json dependencies
- **Benefit:** More explicit boundaries, better tooling support

### Why Not Separate Repos?
- **Cursor limitations** outweigh benefits
- **Interface sync** is error-prone
- **Development friction** is higher
- **Testing complexity** increases

---

## Implementation Checklist

### Simple Folder Structure Approach
- [ ] Create `contracts/core/` directory
- [ ] Create `contracts/decentralized-resolution-module/` directory
- [ ] Move core contracts to `contracts/core/`
- [ ] Move DecentralizedResolutionModule to `contracts/decentralized-resolution-module/`
- [ ] Update all import paths
- [ ] Update Foundry remappings
- [ ] Update Hardhat config (if needed)
- [ ] Update deployment scripts
- [ ] Update test imports
- [ ] Verify compilation
- [ ] Run tests

### Package Structure Approach (If Chosen)
- [ ] Create `packages/` directory structure
- [ ] Set up pnpm workspaces
- [ ] Create package.json files
- [ ] Move contracts to packages
- [ ] Create shared package
- [ ] Update import paths
- [ ] Configure remappings
- [ ] Update build scripts
- [ ] Update CI/CD
- [ ] Verify compilation
- [ ] Run tests

---

## Conclusion

**Recommended Approach:** Start with **simple folder reorganization** (`contracts/core/` and `contracts/decentralized-resolution-module/`), then evolve to **monorepo packages** if boundaries need to be more explicit.

This provides:
- ✅ Immediate clarity and separation
- ✅ Cursor-friendly (can see everything)
- ✅ Easy migration path
- ✅ Can evolve to packages later if needed
- ✅ Minimal complexity upfront

**Avoid separate repos** unless there's a strong reason (different teams, different release cycles, different ownership) - the Cursor/AI effectiveness loss is significant.

