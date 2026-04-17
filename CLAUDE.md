# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install
pnpm install

# Compile (runs both Hardhat and Foundry)
pnpm compile

# Run all tests
pnpm test

# Foundry tests only
pnpm test:foundry          # all tests, -vvv
pnpm test:foundry:core     # core contracts only (excludes disabled)
pnpm test:foundry:modules  # module-specific tests

# Single Foundry test file
forge test test/foundry/core/ReleaseStrategyWiring.t.sol -vvv

# Filter by test name
forge test --match-test "testFunctionName" -vvv
forge test --match-contract "ContractTest" --match-test "testName" -vvv

# Hardhat tests
pnpm test:hardhat

# Lint / format / typecheck
pnpm lint
pnpm format
pnpm typecheck

# Contract sizes (critical — some contracts near EIP-170 limit)
pnpm size
pnpm size:check

# Coverage
pnpm coverage
pnpm coverage:summary
```

## Architecture

### Core Contracts

**`BaseEscrow`** (`contracts/core/BaseEscrow.sol`) is the heart of the protocol. It implements the full escrow lifecycle and delegates computation to a set of stateless **Ops contracts** (CreateOps, YieldOps, DisputeOps, SettlementOps, GuardianOps). The pattern is: Ops contract computes the result (pure/view), BaseEscrow applies state changes. This exists to keep BaseEscrow under the EIP-170 bytecode limit given `via_ir=true, optimizer_runs=1`.

**`EscrowVault`** (`contracts/core/EscrowVault.sol`) is the concrete implementation. It holds ERC20 tokens and tracks per-token balances (`totalHeldInEscrowPerToken`, `totalFeesPerToken`, `totalClaimableAssets`).

**`CREATE2EscrowFactory`** (`contracts/core/CREATE2EscrowFactory.sol`) deploys vaults deterministically using CREATE2, ensuring the same address on every L2.

### State Machine

```
NONE → PENDING → RELEASED
              ↘ REFUNDED
              ↘ DISPUTED → PENDING_SETTLEMENT → RELEASED
                         ↘                    ↘ REFUNDED
                          REFUNDED (90-day auto-cancel)
```

State is stored in `EscrowTransfer.state`. Transitions always go through `BaseEscrow._updateEscrowState()`.

### Module System

Every escrow snapshots its active modules at creation via **`ModuleSnapshotRegistry`** (`contracts/core/ModuleSnapshotRegistry.sol`). This means governance module upgrades never affect live escrows — only new ones. Four module types are snapshotted per escrow:

| Type | Interface | Current Default |
|---|---|---|
| Resolution | `IResolutionModule` | `DefaultResolutionModule` |
| Yield Generation | `IYieldModule` | `DefaultYieldGenerationModule` (no-op) |
| Yield Distribution | `IYieldDistributionModule` | `DefaultYieldDistributionModule` |
| Release / Cancellation Strategy | `IReleaseStrategy`, `ICancellationStrategy` | `DefaultReleaseStrategy`, `DefaultCancellationStrategy` |

**`ModuleRegistry`** (`contracts/registry/ModuleRegistry.sol`) is the allowlist of approved modules. Only `ROLE_TIMELOCK` can add entries.

### Key Types

All shared structs and enums live in `contracts/types/`:

- **`EscrowTransfer`** — the single source of truth for a live escrow (token, from, to, amounts, state, resolver, timing)
- **`EscrowSettings`** — caller-supplied at creation; controls resolver override, yield preset, auto-release/cancel times
- **`EscrowState`** — `NONE | PENDING | RELEASED | REFUNDED | DISPUTED | RESOLVED`
- **`YieldPreset`** — `OFF | TO_SENDER | TO_RECIPIENT | SPLIT_50_50`

### Yield (Aave Integration)

`AaveYieldModule` deposits the escrowed principal into Aave on creation and withdraws on finalization. 30% of yield goes to the protocol fee wallet; 70% goes to `DefaultYieldDistributionModule` for distribution per the escrow's `YieldPreset`. Yield is opt-in per escrow — the default is `OFF`.

### Dispute Flow

1. Either party calls `raiseDispute()` → state: `PENDING → DISPUTED`
2. `DisputeOps` initialises the dispute in the resolution module; resolver address is captured in `EscrowTransfer.disputeResolver`
3. Resolver calls `releaseAsDisputeResolver()` or `cancelAsDisputeResolver()` → state: `DISPUTED → PENDING_SETTLEMENT`
4. A 2-day appeal window runs; anyone calls `executePendingSettlement()` after expiry → final state
5. If a dispute sits unresolved for 90 days, `autoCancelDisputedEscrow()` refunds the sender and emits `DisputeAutoCancelled`

#### Resolver authority model

`_isAuthorizedDisputeResolver` checks in this order:

1. **customResolver** (per-escrow, set at creation) — sole authority if set; governance cannot override
2. **`et.disputeResolver`** (captured at `raiseDispute`, updated by `escalateDispute`) — sole authority if set; the module-level resolver is intentionally NOT re-consulted during resolution to prevent governance from injecting a replacement resolver mid-dispute (governance sandwich, sew-simulation F3)
3. **Snapshotted module fallback** — only if no resolver was captured (not expected in normal operation)

Off-chain monitoring note: if a resolver refuses to act (e.g. fee below cost floor, capacity exhausted), the 90-day `autoCancelDisputedEscrow()` timeout fires and emits `DisputeAutoCancelled(workflowId, from, amt, FailureReason.TIMEOUT)`. These are economic/operational failures, not code bugs — the protocol cannot enforce resolver participation. See `sew-simulation` F7 (profit-threshold strike) and F10 (cascade escalation drain) for reproducible examples.

### Governance

Protocol parameters are controlled via a Governor + `EscrowGovernanceTimelock` (TimelockController). Changes only affect modules registered after the change; per-escrow snapshots are immutable. Access roles: `DEFAULT_ADMIN_ROLE`, `ROLE_TIMELOCK`, `ROLE_GUARDIAN`, `ROLE_ESCROW_CONTRACT`.

**Governance cannot rotate the resolver on an in-flight dispute.** `DefaultResolutionModule.setResolver()` changes who can be assigned as resolver on *new* disputes but has no effect on disputes already open (their resolver is locked in `et.disputeResolver`).

### Transfer Safety

All token movements use OpenZeppelin `SafeERC20`. Releases first attempt a push transfer; if that fails (e.g. recipient is a contract that reverts), the amount is recorded in `claimableBalances` and the recipient calls `withdrawEscrow()` to pull.

## Compiler Settings

Solidity `0.8.33`, EVM `cancun`, `via_ir = true`, `optimizer_runs = 1`. Both Foundry (`foundry.toml`) and Hardhat (`hardhat.config.ts`) must use identical settings. `via_ir` is mandatory — several contracts exceed the 24KB limit without it.

## Codacy

After editing any `.sol` or `.ts` file, run `codacy_cli_analyze` (Codacy MCP tool) on each modified file. After any `pnpm install` / dependency change, run `codacy_cli_analyze` with `tool: "trivy"` before continuing. See `.cursor/rules/codacy.mdc` for full rules.

## Test Layout

```
test/foundry/
  core/          # BaseEscrow, EscrowVault, state transitions, reentrancy
  modules/       # Yield, resolution, strategy tests
  ops/           # CreateOps, YieldOps, DisputeOps, SettlementOps
  registry/      # ModuleRegistry, ModuleSnapshotRegistry
  integration/   # Multi-escrow, cross-module workflows
  halmos/        # Symbolic execution (run with Halmos profile)
  adapters/      # External integrations (Aave, Safe)

test/hardhat/
  governance/    # Proposal, voting flows
  integration/   # Multi-L2 scenarios, fork tests
```

Tests use `ERC20Mock` from `contracts/mocks/` and shared setup via `TestConfig.sol`.
