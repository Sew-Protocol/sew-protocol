# Current Technical Overview

**Last Updated**: May 2026  
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
- **Compiler Settings**: Optimizer enabled, via-IR enabled, optimized for contract size

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
  
- `ResolverIncentiveModuleV3` (DR v3) - ✅ Complete
  - All DR v2 features
  - Resolver staking with mixed bond enforcement (≥80% stable / ≤20% SEW, 50% SEW haircut)
  - Objective slashing schedule with epoch caps and freeze durations
  - Senior resolver coverage and delegation
  - Slashed SEW handled as burned

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
| **DR v3** | ✅ Complete | Decentralize capital (staking, slashing, senior backing) | Capital | Resolver capital at risk |

---

## Current Status

- **Solidity Version**: 0.8.33
- **EVM Version**: Cancun (supports `mcopy` instruction)
- **Compiler Settings**: Optimizer enabled, via-IR enabled, optimized for contract size
- **Contract Size**: Actively managed (via-IR, library extraction)
- **Testing**: Comprehensive test suite (Hardhat + Foundry)
- **Documentation**: Extensive documentation in `docs/` directory

---

## Production Safety

- All upgrades gated behind Safe + Timelock
- Storage layout checks required on upgrades
- Upgrade authority never on EOA
- Emergency pause capability (Guardian only)
- Comprehensive governance tooling for safe operations

---

_For a complete documentation map, see [`docs/INDEX.md`](../INDEX.md) and the reference index in [`docs/reference/_DOCUMENT_INDEX.md`](../reference/_DOCUMENT_INDEX.md)._


---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually reviewed and updated to reflect DR v3 implementation. Technical details (compiler version, `via_ir` rationale, role table, module snapshot model) verified against `foundry.toml` and contract source. Accurate as of `sew-protocol @ 62fce3a`. |
