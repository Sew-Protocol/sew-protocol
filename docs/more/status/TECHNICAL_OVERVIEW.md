# Current Technical Overview

**Last Updated**: January 2026
**Project**: Escrow Protocol with Dispute Resolution

---

## Project Purpose

A decentralized escrow protocol built on Base (Ethereum L2) that enables secure, multi-token escrow transactions with built-in dispute resolution, yield generation, and onchain governance. The protocol supports both standalone escrow vaults (multi-token) and escrow-enabled ERC20 tokens.

---

## Technology Stack

### Development Framework

- **Hardhat** (v2.28.2) - Primary development environment with TypeScript
- **Foundry** (Forge) - Additional testing framework for Solidity
- **hardhat-deploy** (v0.12.0) - Deployment orchestration with script ordering and tags
- **TypeScript** (v5.9.3) - Type-safe development

### Smart Contract Infrastructure

- **Solidity** v0.8.33 with Cancun EVM
- **OpenZeppelin Contracts** v5.4.0 (upgradeable patterns)
- **Proxy Patterns**: Transparent Proxy (default) or UUPS (configurable via `PROXY_KIND`)
- **Compiler Settings**: Optimizer enabled (50,000 runs), via-IR enabled, optimized for contract size

### Testing & Quality

- **Hardhat Tests**: TypeScript-based integration tests
- **Foundry Tests**: Solidity-based unit and fuzz tests
- **TypeChain**: TypeScript bindings generation
- **Slither**: Static analysis (configured)

### Package Management

- **pnpm** - Fast, disk-efficient package manager
- **Monorepo structure** with workspace support

---

## Architecture

### Core Contracts

**BaseEscrow.sol** - Abstract base contract providing:

- Multi-token escrow support (ERC20)
- Dispute resolution system with escalation
- Fee management and tracking
- Module integration (resolution, yield generation, yield distribution)

**EscrowVault.sol** - Multi-token escrow vault:

- Supports any ERC20 token
- Per-token fee tracking
- Batch operations
- Aave yield generation integration

**EscrowableERC20.sol** - ERC20 token with built-in escrow:

- Standard ERC20 functionality
- Built-in `createEscrow()` function (primary function name)
- Factory pattern deployment
- Single-token escrow (token is both payment and escrow medium)

### Modular System

**Resolution Modules**:

- `DefaultResolutionModule` - Simple single-resolver system (initial mainnet release / IEO)
  - Single trusted resolver per escrow
  - Governance-controlled resolver updates
  - Suitable for initial launch and simple disputes
  
- `DecentralizedResolutionModule` - Advanced multi-resolver system (DR v1/v2/v3, post-IEO)
  - **Status**: ✅ Complete and production-ready
  - **Location**: Separate package (`contracts/decentralized-resolution-module/`)
  - **Not included in initial mainnet release** - will be deployed and swapped in via Slow lane governance (~9 days)
  - Multi-resolver registry with round-robin selection
  - Three-level escalation: Standard → Senior → External (Kleros)
  - Category-based dispute routing
  - Phase gate metrics for upgrade readiness

**Incentive Modules** (Swappable via Governance):

- `ResolverIncentiveModuleV1` (DR v1) - ✅ Complete
  - Workload routing only (performance-based assignment)
  - EMA-based reputation scoring
  - No resolver capital at risk
  - Fee tracking and payment distribution
  
- `ResolverIncentiveModuleV2` (DR v2) - ✅ Complete
  - All DR v1 features
  - Appeal bonds (users post bonds to escalate)
  - Escalation cost curves (linear, quadratic, geometric)
  - Bond refund/payment logic
  - Observability metrics
  
- `ResolverIncentiveModuleV3` (DR v3) - 🚧 Planned
  - All DR v2 features
  - Resolver staking integration
  - Slashing integration
  - Fraud lane integration

**Module Governance**: All modules use the same governance pattern: module swaps via Slow lane (queue + activate, ~9 days total). Modules are immutable - upgrades are performed by deploying a new version and swapping via governance. Both queue and activate operations require Timelock execution (ROLE_TIMELOCK).

**Yield Modules**:

- `AaveYieldGenerationModule` - Generates yield on escrowed funds via Aave
- `DefaultYieldDistributionModule` - Configurable yield distribution to recipients

**Payment Calculation**:

- `PaymentCalculationLibraryV1` - Weighted payment calculation (pluggable, swappable via Slow lane)

### Design Principles

1. **Modular Architecture**: Pluggable modules for resolution, yield, and distribution
2. **Snapshot Semantics**: Module selections locked at escrow creation (cannot be changed)
3. **Governance-Controlled**: All upgrades and parameter changes go through onchain governance
4. **Size Optimization**: via-IR compilation, library extraction, careful state management
5. **Staged Rollout**: Dispute resolution decentralization introduced gradually (DR v1 → v2 → v3)
6. **Risk Mitigation**: Each release stage mitigates specific risks before introducing new attack surfaces

---

## Governance Model

### Structure

- **OpenZeppelin Governor** - Proposal creation and voting
- **TimelockController** - Time-delayed execution (48h standard, 7-day slow lane)
- **Safe Multisig** - Upgrade authority (production deployments)
- **Guardian Role** - Emergency controls (pause, reduce caps, disable features)

### Governance Lanes

1. **Emergency Lane** (0h delay, Guardian only):
   - Pause protocol
   - Reduce token caps
   - Disable features

2. **Standard Lane** (48h delay, Timelock):
   - Module upgrades
   - Parameter changes
   - Unpause protocol

3. **Slow Lane** (7-day delay, Timelock):
   - Payment calculation library upgrades
   - Critical parameter changes
   - High-risk modifications

### Key Guarantees

- **No in-flight escrow modification**: Governance cannot change rules for existing escrows
- **Snapshot at creation**: Module addresses and settings locked per escrow
- **Time-delayed execution**: All non-emergency changes require timelock
- **Down-only emergency controls**: Guardian can only reduce risk, not expand it

---

## Deployment Architecture

### Deployment Flow

1. `00_impl.ts` - Deploy implementation contracts
2. `11_proxy.ts` - Deploy proxy contracts + run initializers
3. `10_safe.ts` - Deploy Safe multisig (production)
4. `20_gov_token.ts` - Deploy governance token (SEW)
5. `30_timelock.ts` - Deploy TimelockController
6. `40_governor.ts` - Deploy Governor contract
7. `50_timelock_wiring.ts` - Wire timelock to governor
8. `60_protocol_governance.ts` - Configure protocol governance roles
9. `90_post.ts` - Post-deployment sanity checks

### Networks

- **Hardhat** (local development, chainId: 31337)
- **Base Sepolia** (testnet, chainId: 84532)
- **Base Mainnet** (production, chainId: 8453)
- **Ethereum Mainnet** (chainId: 1)

### Deployment Artifacts

- Timestamped deployment ledger: `deploy-ledger/<network>/<stamp>/`
- TypeChain bindings: `typechain-types/`
- Hardhat artifacts: `artifacts/`
- Foundry artifacts: `out/`

---

## Development Tooling

### Governance Scripts

- `pnpm gov:build` - Build governance proposals
- `pnpm gov:sim` - Simulate proposals on forked network
- `pnpm gov:stage` - Stage proposals (propose, queue, execute)
- `pnpm gov:check` - Check proposal execution status
- `pnpm gov:emergency` - Emergency actions (Guardian only)
- `pnpm gov:surface:check` - Verify governance surface mapping

### Development Commands

- `pnpm test` - Run all tests (Hardhat + Foundry)
- `pnpm compile` - Compile contracts (Hardhat + Foundry)
- `pnpm deploy` - Deploy to network
- `pnpm size` - Print contract sizes
- `pnpm verify` - Verify contracts on block explorer

### Code Quality

- **ESLint** - TypeScript linting
- **Prettier** - Code formatting
- **TypeScript** - Type checking (`pnpm typecheck`)

---

## Key Features

1. **Multi-Token Support**: Escrow any ERC20 token
2. **Dispute Resolution**: Configurable resolution modules with escalation paths
3. **Yield Generation**: Optional Aave integration for earning on escrowed funds
4. **Resolver Incentives**: Automatic payment distribution to dispute resolvers
5. **Governance**: Full onchain governance with timelock and emergency controls
6. **Immutable Core**: Core contracts are immutable (no proxies). Protocol evolution via module swaps.
7. **Modular**: Pluggable modules for resolution, yield, and distribution
8. **Snapshot Semantics**: Escrow rules locked at creation time
9. **Unified Module Governance**: All modules use Slow lane swap pattern (immutable modules, ~9 days)

---

## Dispute Resolution Staged Rollout (DR v1 / DR v2 / DR v3)

The protocol uses a **staged rollout approach** for decentralized dispute resolution, following the principle: **"Decentralise decisions first, decentralise incentives second, decentralise capital last."** This minimizes risk by introducing adversarial pressure gradually, only after each phase proves stable.

### Release Strategy Overview

| Phase | Status | Description | Decentralization Level | Risk Mitigation |
|-------|--------|-------------|----------------------|-----------------|
| **IEO** | ✅ Ready | Centralized resolution (DefaultResolutionModule) | Governance only | Minimal surface area |
| **DR v1** | ✅ Complete | Decentralize decisions (workload routing, EMA scoring) | Decision-making | No resolver capital at risk |
| **DR v2** | ✅ Complete | Decentralize incentives (appeal bonds, cost curves) | Incentives | Users post bonds (not resolvers) |
| **DR v3** | 🚧 Phase 1 | Decentralize capital (staking, slashing, fraud lane) | Capital | Resolver capital at risk |

### DR v1: Decentralize Decisions ✅

**Status:** ✅ Complete and Production-Ready  
**Test Coverage:** 47 tests (33 unit + 7 invariant + 7 fuzz)  
**Implementation Date:** 2026-01-13

**What's Decentralized:**
- ✅ Decision-making (multiple independent resolvers)
- ✅ Resolver selection (round-robin from curated set)
- ✅ Escalation paths (3-level: standard → senior → external)
- ✅ Performance-based workload routing

**What's Centralized:**
- ❌ Incentives (optional fee share, no capital at risk)
- ❌ Capital (no resolver staking/slashing)

**Key Features:**
- Round-based dispute flow (k=0 resolver, k=1 senior, k=2 Kleros)
- EMA-based reputation scoring (0-1e6 fixed-point)
- Workload routing (performance determines assignment eligibility)
- Timeout handling with auto-reassignment
- Phase gate metrics (`getV1PhaseGateMetrics()`)

**Risk Mitigation:**
- **No Resolver Capital at Risk**: Resolvers cannot lose money (no staking/slashing)
- **Soft Incentives**: Workload-to-zero (low performers gated out) rather than capital loss
- **Mechanical Enforcement**: Timeout handling is automatic, not governance-dependent
- **Gradual Decentralization**: Multiple resolvers with fair distribution (round-robin)

**Phase Gate (DR v1 → DR v2):**
- ✅ Stable escalation rate (<20%)
- ✅ Predictable response times (<3 days avg)
- ✅ Multiple operational resolvers (≥3 active)
- ✅ No evidence of systematic griefing
- ✅ Incident runbooks tested

### DR v2: Decentralize Incentives ✅

**Status:** ✅ Complete and Production-Ready  
**Test Coverage:** 36 tests (23 unit + 7 invariant + 6 fuzz)  
**Implementation Date:** 2026-01-13

**What's Decentralized:**
- ✅ Decision-making (from DR v1)
- ✅ Incentives (appeal bonds, cost curves)
- ✅ Economic friction (increasing escalation costs)

**What's Centralized:**
- ❌ Capital (no resolver staking/slashing)

**Key Features:**
- Appeal bonds (users post bonds to escalate)
- Escalation cost curves (linear, quadratic, geometric - quadratic recommended)
- Bond refund on successful appeal (decision changes)
- Bond payment to resolvers on failed appeal (decision upheld)
- Anti-griefing measures (minimum escrow value for escalation)
- Observability metrics (bonds posted/refunded/forfeited)

**Economics:**
- **Quadratic Cost Curve** (recommended): `bond(k) = baseCost + stepSize × k²`
  - Round 0→1: 100 tokens (first appeal)
  - Round 1→2: 150 tokens (to Kleros)
- **Incentive Alignment**: Resolvers earn bonds when appeals fail (decision upheld)
- **Spam Prevention**: Increasing costs discourage frivolous escalations

**Risk Mitigation:**
- **No Resolver Capital at Risk**: Resolvers still cannot lose money
- **User Bonds Only**: Users post bonds to escalate (not resolvers)
- **Economic Friction**: Increasing costs prevent griefing and strategic escalation
- **Refund Mechanism**: Successful appeals return bonds to users
- **Resolver Incentives**: Failed appeals pay bonds to resolvers (incentivizes correct decisions)

**Phase Gate (DR v2 → DR v3):**
- ✅ Appeal spam economically suppressed (cost > benefit)
- ✅ No viable "cheap griefing" strategy
- ✅ Clear evidence bonds reduce low-quality escalations
- ✅ Stable appeal economics (20-40% reversal rate)
- ✅ Bond flows predictable (not excessive refunds/forfeitures)

### DR v3: Decentralize Capital 🚧

**Status:** 🚧 Phase 1 Complete (Interfaces + No-Ops)  
**Test Coverage:** 20 integration tests  
**Implementation Date:** 2026-01-13 (Phase 1 only)

**What's Decentralized (Target):**
- ✅ Decision-making (from DR v1)
- ✅ Incentives (from DR v2)
- 🚧 Capital (resolver staking/slashing - Phase 2-7 pending)

**Key Features (Planned):**
- Resolver staking (resolvers post bonds to participate)
- Slashing (objective penalties for timeouts, provable non-response)
- Senior backing (delegation/underwriting for new resolvers)
- Fraud lane (investigation + execution path)
- Insurance pool (economic safety net)

**Risk Mitigation (Planned):**
- **Resolver Capital at Risk**: Resolvers stake capital, creating strong incentive alignment
- **Objective Slashing**: Only contract-executed penalties (timeouts, provable non-response)
- **Gradual Introduction**: Only after DR v1/v2 behavior is known
- **Economic Safety**: Insurance pool and circuit breakers

**Phase Gate (DR v3 → Mainnet):**
- ⏸️ Staking participation >80% of resolvers
- ⏸️ Slashing rate <5% per month
- ⏸️ Insurance pool solvent
- ⏸️ No circuit breaker triggers
- ⏸️ Security audit complete

**Current Status:**
- ✅ Interfaces defined (`IStakingModule`, `ISlashingModule`)
- ✅ No-op implementations (backward compatible)
- ✅ Integration architecture complete
- ⏸️ Real implementation deferred until v1/v2 phase gates met

### Migration Path

**IEO Launch:**
- `DefaultResolutionModule` - Simple single-resolver
- No dispute resolution complexity
- Minimal surface area

**DR v1 Launch (Post-IEO):**
- Deploy `DecentralizedResolutionModule` + `ResolverIncentiveModuleV1`
- Swap via Slow lane governance (~9 days)
- Applies to new escrows only

**DR v2 Launch (After DR v1 Phase Gates):**
- Swap `ResolverIncentiveModuleV1` → `ResolverIncentiveModuleV2`
- Same `DecentralizedResolutionModule` (no change)
- Applies to new escrows only

**DR v3 Launch (After DR v2 Phase Gates):**
- Swap `ResolverIncentiveModuleV2` → `ResolverIncentiveModuleV3`
- Deploy `ResolverStakingModuleV1` + `ResolverSlashingModuleV1`
- Swap via Slow lane governance
- Applies to new escrows only

### Pass Gates for Next Release

**DR v1 → DR v2:**
1. ✅ Stable escalation rate (<20%) over N weeks
2. ✅ Predictable response times (<3 days avg)
3. ✅ Multiple operational resolvers (≥3 active)
4. ✅ No evidence of systematic griefing
5. ✅ Incident runbooks tested (timeouts, unresponsive resolvers)

**DR v2 → DR v3:**
1. ✅ Appeal spam economically suppressed (cost > benefit)
2. ✅ No viable "cheap griefing" strategy
3. ✅ Stable appeal economics (20-40% reversal rate)
4. ✅ Bond flows predictable
5. ✅ Kleros escalation rate <5% (system self-resolves)

**DR v3 → Mainnet:**
1. ⏸️ Staking participation >80% of resolvers
2. ⏸️ Slashing rate <5% per month
3. ⏸️ Insurance pool solvent
4. ⏸️ Security audit complete
5. ⏸️ No circuit breaker triggers

### How Releases Mitigate Risk

**DR v1 Mitigates:**
- Single point of failure (multiple resolvers)
- Resolver bias (round-robin fair distribution)
- Resolver unresponsiveness (auto-reassignment on timeout)
- Low-quality resolvers (workload routing gates them out)

**DR v2 Mitigates:**
- Appeal spam (economic friction via increasing costs)
- Frivolous escalations (bonds create cost > benefit)
- Resolver collusion risk (bonds paid to resolvers, not protocol)
- Strategic gaming (quadratic curve makes deep escalation expensive)

**DR v3 Mitigates (Planned):**
- Resolver misbehavior (capital at risk via slashing)
- Poor decision quality (stakes create strong incentive alignment)
- Resolver exit (insurance pool provides safety net)
- Economic attacks (circuit breakers and caps)

---

## Current Status

- **Solidity Version**: 0.8.33
- **EVM Version**: Cancun (supports `mcopy` instruction)
- **Compiler Settings**: Optimizer enabled (1000 runs - aligned with Foundry), via-IR enabled, optimized for contract size
- **Contract Size**: Actively managed (via-IR, library extraction)
- **Testing**: Comprehensive test suite (Hardhat + Foundry)
  - **DR v1**: 47 tests ✅
  - **DR v2**: 36 tests ✅
  - **DR v3**: 20 tests (Phase 1) 🚧
- **Documentation**: Extensive documentation in `docs/` directory
- **Dispute Resolution**: DR v1 and DR v2 complete and ready for testnet deployment

---

## Production Safety

- All upgrades gated behind Safe + Timelock
- Storage layout checks required on upgrades
- Upgrade authority never on EOA
- Emergency pause capability (Guardian only)
- Comprehensive governance tooling for safe operations

---

_For detailed documentation, see the [Document Index](_DOCUMENT_INDEX.md)_
