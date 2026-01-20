# Release Organization Proposal

**Date:** 2026-01-16  
**Purpose:** Organize contracts and documentation for clarity across releases (IEO, DR v1, DR v2, DR v3)  
**Status:** 📋 Proposal

---

## Executive Summary

This proposal organizes the codebase to clearly show:
- **What's live** on each network
- **What's implemented but not activated**
- **What's planned** for future releases

The organization separates contracts by release while maintaining clear references and avoiding duplication.

---

## Proposed Directory Structure

### Contracts Organization

```
contracts/
├── core/                          # Core escrow contracts (immutable, all releases)
│   ├── BaseEscrow.sol
│   ├── EscrowVault.sol
│   └── EscrowableERC20.sol
│
├── releases/                      # Release-specific contracts
│   ├── ieo/                       # IEO (Initial Exchange Offering) - LIVE
│   │   ├── modules/
│   │   │   └── DefaultResolutionModule.sol
│   │   ├── yield/
│   │   │   ├── AaveYieldGenerationModule.sol
│   │   │   └── DefaultYieldDistributionModule.sol
│   │   └── release/
│   │       └── DefaultReleaseStrategy.sol
│   │
│   ├── dr1/                       # DR v1: Decentralize Decisions - IMPLEMENTED, NOT ACTIVATED
│   │   └── DecentralizedResolutionModule.sol → symlink to ../decentralized-resolution-module/
│   │
│   ├── dr2/                       # DR v2: Decentralize Incentives - IMPLEMENTED, NOT ACTIVATED
│   │   └── ResolverIncentiveModuleV2.sol → symlink to ../decentralized-resolution-module/
│   │
│   └── dr3/                       # DR v3: Decentralize Capital - IMPLEMENTED, NOT ACTIVATED
│       ├── ResolverStakingModuleV1.sol → symlink to ../decentralized-resolution-module/
│       └── ResolverSlashingModuleV1.sol → symlink to ../decentralized-resolution-module/
│
├── decentralized-resolution-module/  # DR module package (source of truth)
│   ├── DecentralizedResolutionModule.sol
│   ├── ResolverIncentiveModuleV1.sol
│   ├── ResolverIncentiveModuleV2.sol
│   ├── ResolverStakingModuleV1.sol
│   ├── ResolverSlashingModuleV1.sol
│   └── [supporting contracts]
│
├── shared/                        # Shared contracts (all releases)
│   ├── governance/
│   │   └── SlowLaneQueueActivate.sol
│   └── interfaces/
│       └── [shared interfaces]
│
├── governance/                    # Governance contracts (all releases)
│   ├── GovGovernor.sol
│   └── SewToken.sol
│
└── [other shared contracts]
```

### Governance Organization

```
governance/
├── releases/                      # Release-specific governance
│   ├── ieo/                       # IEO governance payloads
│   │   ├── payloads/
│   │   │   ├── 0001_set_token_cap.ts
│   │   │   └── 0002_queue_fee_address.ts
│   │   └── runbooks/
│   │       └── initial-deployment.md
│   │
│   ├── dr1/                       # DR v1 activation payloads
│   │   ├── payloads/
│   │   │   └── activate_dr_v1.ts
│   │   └── runbooks/
│   │       └── dr1-activation.md
│   │
│   ├── dr2/                       # DR v2 activation payloads
│   │   ├── payloads/
│   │   │   └── activate_dr_v2.ts
│   │   └── runbooks/
│   │       └── dr2-activation.md
│   │
│   └── dr3/                       # DR v3 activation payloads
│       ├── payloads/
│       │   └── activate_dr_v3.ts
│       └── runbooks/
│           └── dr3-activation.md
│
├── runbooks/                      # Shared runbooks (all releases)
│   ├── emergency.md
│   ├── recovery.md
│   ├── standard-changes.md
│   └── slow-changes.md
│
└── payloads/                      # Current/active payloads (symlinks or references)
    └── [symlinks to active release payloads]
```

### Deployment Scripts Organization

```
deploy/
├── releases/                      # Release-specific deployments
│   ├── ieo/                       # IEO deployment
│   │   ├── 00_core.ts
│   │   ├── 10_governance.ts
│   │   ├── 20_modules.ts
│   │   └── 90_post.ts
│   │
│   ├── dr1/                       # DR v1 deployment (when activated)
│   │   └── deploy_dr_v1.ts
│   │
│   ├── dr2/                       # DR v2 deployment (when activated)
│   │   └── deploy_dr_v2.ts
│   │
│   └── dr3/                       # DR v3 deployment (when activated)
│       └── deploy_dr_v3.ts
│
└── [shared deployment utilities]
```

---

## Alternative: Flat Structure with Release Tags

**Alternative Approach** (Simpler, no symlinks):

```
contracts/
├── core/                          # Core contracts (all releases)
├── modules/                       # All modules (tagged by release)
│   ├── ieo/
│   │   └── DefaultResolutionModule.sol
│   ├── dr1/
│   │   └── DecentralizedResolutionModule.sol
│   └── dr2/
│       └── ResolverIncentiveModuleV2.sol
│
└── decentralized-resolution-module/  # DR module package
    └── [all DR contracts]
```

**Pros:**
- No symlinks needed
- Clear separation
- Easy to find release-specific code

**Cons:**
- Potential duplication if contracts are shared
- Harder to see what's actually in each release

---

## Recommended Approach: Hybrid

**Best of both worlds:**

1. **Keep source contracts in their current locations** (no duplication)
2. **Use release directories for organization and documentation**
3. **Use symlinks or import aliases** to reference contracts
4. **Create release manifests** that list what's included

### Structure:

```
contracts/
├── core/                          # Core (all releases)
├── modules/                       # Modules (organized by type)
│   ├── resolution/
│   │   ├── DefaultResolutionModule.sol (IEO)
│   │   └── DecentralizedResolutionModule.sol (DR v1-v3)
│   └── yield/
│       └── AaveYieldGenerationModule.sol (IEO)
│
├── decentralized-resolution-module/  # DR package (source)
│   └── [all DR contracts]
│
└── releases/                      # Release manifests (documentation)
    ├── ieo/
    │   ├── MANIFEST.md            # Lists contracts in IEO
    │   └── contracts.txt          # Contract paths
    ├── dr1/
    │   ├── MANIFEST.md
    │   └── contracts.txt
    ├── dr2/
    │   ├── MANIFEST.md
    │   └── contracts.txt
    └── dr3/
        ├── MANIFEST.md
        └── contracts.txt
```

---

## Documentation Organization

```
docs/
├── deployment/
│   ├── RELEASES.md                # Master release index
│   ├── RELEASE_ORGANIZATION_PROPOSAL.md (this file)
│   │
│   ├── ieo/                       # IEO release docs
│   │   ├── IEO_RELEASE_GUIDE.md
│   │   ├── IEO_DEPLOYMENT.md
│   │   └── IEO_CONTRACTS.md
│   │
│   ├── dr1/                       # DR v1 release docs
│   │   ├── DR1_RELEASE_GUIDE.md
│   │   ├── DR1_ACTIVATION.md
│   │   └── DR1_CONTRACTS.md
│   │
│   ├── dr2/                       # DR v2 release docs
│   │   ├── DR2_RELEASE_GUIDE.md
│   │   ├── DR2_ACTIVATION.md
│   │   └── DR2_CONTRACTS.md
│   │
│   └── dr3/                       # DR v3 release docs
│       ├── DR3_RELEASE_GUIDE.md
│       ├── DR3_ACTIVATION.md
│       └── DR3_CONTRACTS.md
│
└── [other docs]
```

---

## Release Status Tracking

### RELEASES.md Structure

```markdown
# Protocol Releases

## Release Status Overview

| Release | Status | Networks | Activation Date | Notes |
|---------|--------|----------|----------------|-------|
| IEO | ✅ Live | Base Sepolia (testnet) | TBD | Initial release |
| DR v1 | ✅ Implemented | None | TBD | Ready for activation |
| DR v2 | ✅ Implemented | None | TBD | Ready for activation |
| DR v3 | 🚧 Phase 1-3 Complete | None | TBD | Interfaces + Staking + Slashing complete |

## Network Status

### Base Sepolia (Testnet)

| Release | Status | Contracts | Notes |
|---------|--------|-----------|-------|
| IEO | 🚧 Planned | Core + DefaultResolutionModule | Deployment pending |
| DR v1 | ⏸️ Not Deployed | - | Implemented, awaiting activation |
| DR v2 | ⏸️ Not Deployed | - | Implemented, awaiting activation |
| DR v3 | ⏸️ Not Deployed | - | Phase 1-3 complete, not activated |

### Base Mainnet

| Release | Status | Contracts | Notes |
|---------|--------|-----------|-------|
| IEO | ⏸️ Not Deployed | - | Pending testnet validation |
| DR v1 | ⏸️ Not Deployed | - | Pending IEO stability |
| DR v2 | ⏸️ Not Deployed | - | Pending DR v1 stability |
| DR v3 | ⏸️ Not Deployed | - | Pending DR v2 stability |
```

---

## Implementation Plan

### Phase 1: Documentation (Immediate)

1. ✅ Create `docs/deployment/RELEASES.md` - Master release index
2. ✅ Create `docs/deployment/ieo/IEO_RELEASE_GUIDE.md` - IEO deployment guide
3. ✅ Create release manifests for each release
4. ✅ Document what's live, what's implemented, what's planned

### Phase 2: Contract Organization (Optional)

1. Create `contracts/releases/` directory structure
2. Add release manifests (contract lists)
3. Consider symlinks if needed

### Phase 3: Governance Organization (Optional)

1. Organize governance payloads by release
2. Create release-specific runbooks
3. Update payload references

---

## Recommendation

**Start with documentation only** (Phase 1):

1. **Clear documentation** is more important than directory reorganization
2. **Release manifests** (lists of contracts) are easier to maintain than symlinks
3. **Keep current contract structure** (it's already organized by type)
4. **Add release documentation** to clarify what's in each release

**Benefits:**
- ✅ No code changes needed
- ✅ Clear release tracking
- ✅ Easy to maintain
- ✅ Can reorganize later if needed

**If reorganization is needed later:**
- Use release manifests to guide reorganization
- Consider symlinks only if contracts are truly shared
- Keep source of truth in one location

---

## Next Steps

1. **Review this proposal**
2. **Create RELEASES.md** with current status
3. **Create IEO release guide** for Base Sepolia deployment
4. **Create release manifests** for each release
5. **Update deployment scripts** with release tags/comments

---

_Status: Awaiting Review_
