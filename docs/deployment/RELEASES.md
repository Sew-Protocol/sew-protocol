# Protocol Releases

**Last Updated:** 2026-01-16  
**Purpose:** Track all protocol releases, their status, and deployment information

---

## Release Status Overview

| Release | Status | Networks | Activation Date | Notes |
|---------|--------|----------|----------------|-------|
| **IEO** | ✅ Ready | None (Base Sepolia planned) | TBD | Initial Exchange Offering - minimal surface area |
| **DR v1** | ✅ Implemented | None | TBD | Decentralize Decisions - ready for activation |
| **DR v2** | ✅ Implemented | None | TBD | Decentralize Incentives - ready for activation |
| **DR v3** | 🚧 Phase 1-3 Complete | None | TBD | Decentralize Capital - interfaces + staking + slashing complete |

---

## Release Definitions

### IEO (Initial Exchange Offering)

**Status:** ✅ Ready for deployment  
**Purpose:** Initial release with minimal surface area - governance only, centralized dispute resolution

**What's Included:**
- Core escrow contracts (BaseEscrow, EscrowVault, EscrowableERC20)
- DefaultResolutionModule (single trusted resolver)
- AaveYieldGenerationModule (optional yield)
- DefaultYieldDistributionModule
- DefaultReleaseStrategy
- Governance infrastructure (GovGovernor, TimelockController, SewToken)

**What's NOT Included:**
- DecentralizedResolutionModule
- Resolver incentives
- Resolver staking/slashing

**Deployment Guide:** [IEO Release Guide](./ieo/IEO_RELEASE_GUIDE.md)

---

### DR v1: Decentralize Decisions

**Status:** ✅ Complete and Production-Ready (47 tests passing)  
**Purpose:** Decentralize dispute resolution decision-making

**What's Decentralized:**
- ✅ Multiple independent resolvers (curated set)
- ✅ Round-robin selection from resolver pool
- ✅ Three-level escalation: Standard → Senior → External (Kleros)
- ✅ Category-based dispute routing
- ✅ Performance-based workload routing (EMA scoring)

**What's Centralized:**
- ❌ Incentives (optional fee share, no capital at risk)
- ❌ Capital (no resolver staking/slashing)

**Key Features:**
- Round-based dispute flow (k=0 resolver, k=1 senior, k=2 Kleros)
- EMA-based reputation scoring (0-1e6 fixed-point)
- Workload routing (performance determines assignment eligibility)
- Timeout handling with auto-reassignment
- Phase gate metrics (`getV1PhaseGateMetrics()`)

**Contracts:**
- `DecentralizedResolutionModule.sol`
- `ResolverIncentiveModuleV1.sol` (workload routing only)

**Activation Guide:** [DR v1 Activation Guide](./dr1/DR1_ACTIVATION.md)

**Phase Gate (IEO → DR v1):**
- ✅ Stable protocol operation on testnet
- ✅ No critical security issues
- ✅ Governance processes tested
- ✅ Emergency procedures validated

---

### DR v2: Decentralize Incentives

**Status:** ✅ Complete and Production-Ready (36 tests passing)  
**Purpose:** Decentralize incentives through appeal bonds

**What's Decentralized:**
- ✅ Decision-making (from DR v1)
- ✅ Incentives (appeal bonds, cost curves)
- ✅ Economic friction (increasing escalation costs)

**What's Centralized:**
- ❌ Capital (no resolver staking/slashing)

**Key Features:**
- **Appeal bonds** (users post bonds to escalate disputes)
- **Escalation cost curves** (linear, quadratic, geometric - quadratic recommended)
- **Bond refund** on successful appeal (decision changes)
- **Bond payment** to resolvers on failed appeal (decision upheld)
- **Anti-griefing measures** (minimum escrow value for escalation)
- **Observability metrics** (bonds posted/refunded/forfeited)

**Contracts:**
- `ResolverIncentiveModuleV2.sol` (appeal bonds)
- `EscalationCostLibrary.sol`
- `PaymentCalculationLibraryV1.sol`

**Activation Guide:** [DR v2 Activation Guide](./dr2/DR2_ACTIVATION.md)

**Phase Gate (DR v1 → DR v2):**
- ✅ Stable escalation rate (<20%) over N weeks
- ✅ Predictable response times (<3 days avg)
- ✅ Multiple operational resolvers (≥3 active)
- ✅ No evidence of systematic griefing

---

### DR v3: Decentralize Capital

**Status:** 🚧 Phase 1-3 Complete (230 tests passing)  
**Purpose:** Decentralize capital through resolver staking and slashing

**What's Decentralized (Target):**
- ✅ Decision-making (from DR v1)
- ✅ Incentives (from DR v2)
- 🚧 Capital (resolver staking/slashing - Phase 1-3 complete)

**What's Complete:**
- ✅ Phase 1: Interface boundaries (IStakingModule, ISlashingModule, NoOp implementations)
- ✅ Phase 2: Real staking (ResolverStakingModuleV1, BondValuationLibrary)
- ✅ Phase 3: Real slashing (ResolverSlashingModuleV1)

**What's Pending:**
- ⏸️ Phase 4-7: Full integration, testing, audit

**Key Features (Implemented):**
- **Resolver staking** (resolvers post bonds to participate)
- **Mixed bonds** (80% stablecoin, 20% SEW with 0.5 haircut)
- **Oracle-free valuation** (conservative $1/SEW assumption)
- **Delegation coverage** (M=3, U=0.5)
- **Unbonding delays** (14/21 days)
- **Objective slashing** (timeouts only, 2%/5%/10% penalties)
- **Waterfall ordering** (resolver → senior)
- **Circuit breakers** (mass unavailability)

**Contracts:**
- `ResolverStakingModuleV1.sol`
- `ResolverSlashingModuleV1.sol`
- `BondValuationLibrary.sol`
- `InsurancePoolVault.sol`

**Activation Guide:** [DR v3 Activation Guide](./dr3/DR3_ACTIVATION.md)

**Phase Gate (DR v2 → DR v3):**
- ⏸️ Appeal spam economically suppressed (cost > benefit)
- ⏸️ No viable "cheap griefing" strategy
- ⏸️ Stable appeal economics (20-40% reversal rate)
- ⏸️ Bond flows predictable

**Phase Gate (DR v3 → Mainnet):**
- ⏸️ Staking participation >80% of resolvers
- ⏸️ Slashing rate <5% per month
- ⏸️ Insurance pool solvent
- ⏸️ Security audit complete

---

## Network Status

### Base Sepolia (Testnet)

| Release | Status | Contracts | Deployment Date | Notes |
|---------|--------|-----------|----------------|-------|
| **IEO** | 🚧 Planned | Core + DefaultResolutionModule | TBD | Initial deployment target |
| **DR v1** | ⏸️ Not Deployed | - | - | Implemented, awaiting IEO stability |
| **DR v2** | ⏸️ Not Deployed | - | - | Implemented, awaiting DR v1 activation |
| **DR v3** | ⏸️ Not Deployed | - | - | Phase 1-3 complete, awaiting DR v2 activation |

**Deployment Status:**
- ⏸️ No deployments yet
- 🚧 IEO deployment planned for Base Sepolia
- 📋 See [IEO Release Guide](./ieo/IEO_RELEASE_GUIDE.md) for deployment steps

---

### Base Mainnet

| Release | Status | Contracts | Deployment Date | Notes |
|---------|--------|-----------|----------------|-------|
| **IEO** | ⏸️ Not Deployed | - | - | Pending testnet validation |
| **DR v1** | ⏸️ Not Deployed | - | - | Pending IEO stability on testnet |
| **DR v2** | ⏸️ Not Deployed | - | - | Pending DR v1 stability |
| **DR v3** | ⏸️ Not Deployed | - | - | Pending DR v2 stability + audit |

**Deployment Status:**
- ⏸️ No mainnet deployments
- 📋 Mainnet deployment requires:
  - ✅ Testnet validation
  - ✅ Security audits
  - ✅ Emergency drills
  - ✅ Governance approval

---

## Release Activation Sequence

### Current Sequence

```
IEO (Base Sepolia)
  ↓ [Testnet validation]
IEO (Base Mainnet)
  ↓ [Stability period]
DR v1 Activation (Base Sepolia)
  ↓ [Testnet validation]
DR v1 Activation (Base Mainnet)
  ↓ [Stability period]
DR v2 Activation (Base Sepolia)
  ↓ [Testnet validation]
DR v2 Activation (Base Mainnet)
  ↓ [Stability period]
DR v3 Activation (Base Sepolia)
  ↓ [Testnet validation]
DR v3 Activation (Base Mainnet)
```

### Activation Process

Each release activation follows this process:

1. **Deploy contracts** (if not already deployed)
2. **Queue module swap** (Slow lane, ~9 days)
3. **Activate module swap** (Slow lane, ~9 days)
4. **Monitor and validate** (stability period)
5. **Proceed to next release** (if phase gates met)

**See individual release guides for detailed steps.**

---

## Contract Inventory by Release

### IEO Contracts

**Core:**
- `BaseEscrow.sol`
- `EscrowVault.sol`
- `EscrowableERC20.sol`

**Modules:**
- `DefaultResolutionModule.sol`
- `DefaultReleaseStrategy.sol`
- `AaveYieldGenerationModule.sol`
- `DefaultYieldDistributionModule.sol`

**Governance:**
- `GovGovernor.sol`
- `SewToken.sol`
- `TimelockController.sol` (OpenZeppelin)

**Supporting:**
- `YieldOps.sol`
- `DisputeOps.sol`
- `SlowLaneQueueActivate.sol`

### DR v1 Contracts

**Additional Modules:**
- `DecentralizedResolutionModule.sol`
- `ResolverIncentiveModuleV1.sol`

**Supporting:**
- `ResolutionAnalytics.sol`
- `EscalationCostLibrary.sol` (basic)

### DR v2 Contracts

**Additional Modules:**
- `ResolverIncentiveModuleV2.sol` (replaces or augments V1)

**Supporting:**
- `PaymentCalculationLibraryV1.sol`
- `EscalationCostLibrary.sol` (enhanced)

### DR v3 Contracts

**Additional Modules:**
- `ResolverStakingModuleV1.sol`
- `ResolverSlashingModuleV1.sol`

**Supporting:**
- `BondValuationLibrary.sol`
- `InsurancePoolVault.sol`
- `IStakingModule.sol`
- `ISlashingModule.sol`

---

## Release Documentation

- **[IEO Release Guide](./ieo/IEO_RELEASE_GUIDE.md)** - Initial deployment guide
- **[DR v1 Activation Guide](./dr1/DR1_ACTIVATION.md)** - DR v1 activation steps
- **[DR v2 Activation Guide](./dr2/DR2_ACTIVATION.md)** - DR v2 activation steps
- **[DR v3 Activation Guide](./dr3/DR3_ACTIVATION.md)** - DR v3 activation steps

---

## Status Legend

- ✅ **Ready/Complete** - Implemented and ready for deployment/activation
- 🚧 **In Progress** - Partially implemented or being tested
- ⏸️ **Not Deployed** - Not yet deployed to network
- 📋 **Planned** - Planned but not yet started
- ❌ **Not Included** - Explicitly not part of this release

---

_Last Updated: 2026-01-16_
