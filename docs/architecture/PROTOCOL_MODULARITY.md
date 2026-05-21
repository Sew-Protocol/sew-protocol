# Protocol Modularity

> **Scope:** This document describes the module system architecture of the Sew Protocol
> escrow contracts. It covers the six module types, their interfaces, current implementations,
> the snapshot isolation model, governance lifecycle, per-escrow overrides, and the conventions
> an implementer must follow to write a conformant module.
>
> **Sources:** `contracts/interfaces/I*.sol`, `contracts/shared/interfaces/I*.sol`,
> `contracts/core/ModuleSnapshotRegistry.sol`, `contracts/core/BaseEscrow.sol`
> (`ModuleType` enum, `ModuleSnapshot`, `_snapshotModulesForEscrow`, `EscrowSettings`),
> `contracts/types/EscrowTypes.sol` (`ModuleSnapshot`, `EscrowSettings`),
> `contracts/governance/SlowLaneQueueActivate.sol`,
> `contracts/modules/` (concrete implementations).

---

## 1. Overview

The Sew Protocol escrow system is built around six orthogonal module axes. Each axis is
independently configurable and replaceable. The core `BaseEscrow` contract contains no
dispute resolution logic, no yield strategy, no cancellation rules, and no release policy
itself — all of that is delegated to pluggable modules via well-defined interfaces.

```
BaseEscrow
├── Resolution module     IResolutionModule    — who resolves disputes, how escalation works
├── Release strategy      IReleaseStrategy     — who can release the escrow and when
├── Cancellation strategy ICancellationStrategy — who can cancel the escrow and when
├── Yield generation      IYieldGenerationModule — where idle funds are deployed
├── Yield distribution    IYieldDistributionModule — how yield is allocated on settlement
└── Incentive module      IIncentiveModule     — resolver performance tracking and bond logic
```

Every module is a deployed Solidity contract with a standardised interface. The escrow
contracts communicate with modules exclusively through these interfaces, which makes it
possible to:

- Replace any module via governance without redeploying the escrow contract.
- Run different module combinations on different escrow contracts in the same deployment.
- Extend the protocol (new yield source, new dispute process, new release rule) by deploying
  a new contract and wiring it in — without touching any existing escrow code.
- Audit each module in isolation, since the interface is a clean boundary.

---

## 2. Module snapshot isolation

The most important property of the module system is **creation-time freeze**. When an escrow
is created, `BaseEscrow._snapshotModulesForEscrow(workflowId)` writes a `ModuleSnapshot` that
captures the addresses of every module and the values of every fee parameter:

```solidity
// types/EscrowTypes.sol
struct ModuleSnapshot {
    address resolutionModule;
    address releaseStrategy;
    address cancellationStrategy;
    address yieldGenerationModule;
    address yieldDistributionModule;
    address incentiveModule;
    uint256 yieldProtocolFeeBps;
    uint256 appealBondProtocolFeeBps;
    uint256 escrowFeeBps;
    uint256 defaultAutoReleaseDelay;
    uint256 defaultAutoCancelDelay;
    uint256 maxDisputeDuration;
    uint256 appealWindowDuration;
}
```

This struct is written once in `moduleSnapshots[workflowId]` and is never modified for the
life of the escrow. Every subsequent operation — release, dispute, escalation, yield
withdrawal, bond calculation — reads from this snapshot, not from the current global defaults.

**Consequence:** Governance can swap any module for a new version at any time. That change
affects only new escrows created after the activation. All existing escrows continue to run
on the module configuration they were created under, indefinitely. There is no migration step
and no retroactive effect.

---

## 3. The six module types

### 3.1 Resolution module (`IResolutionModule`)

**What it controls:** The entire dispute lifecycle — who is authorised to resolve a dispute,
how disputes are routed through escalation rounds, when escalation is allowed, and how
finality is reached.

**Interface summary:**

| Function | Called when |
|----------|-------------|
| `initializeDispute(workflowId, escrow, resolver, categoryKey)` | A dispute is opened via `raiseDispute()` |
| `isAuthorizedDisputeResolver(workflowId, escrow, resolver, data)` | A resolver attempts to settle |
| `getDisputeResolver(workflowId, escrow, data)` | BaseEscrow needs to identify the assigned resolver |
| `canEscalate(workflowId, escrow, currentLevel, data)` | A party attempts to escalate |
| `executeEscalation(workflowId, escrow, data)` | Escalation is executed |
| `getRequiredAppealBond(workflowId, escrow, level, data)` | Bond amount is queried before escalation |
| `recordResolution(workflowId, escrow, resolver, outcome, time)` | A resolution decision is recorded |
| `getDecisionAtRound(workflowId, escrow, round)` | The decision at a prior round is queried |
| `getAppealDeadlineAndRound(workflowId, escrow)` | Appeal window state is queried |
| `recordReversal(workflowId, escrow, priorRound)` | A prior decision is reversed by escalation |
| `finalizeDispute(workflowId, escrow)` | The dispute appeal window has closed |

**Current implementations:**

| Contract | Behaviour |
|----------|-----------|
| `DefaultResolutionModule` | Single resolver, no escalation. Governance sets one `resolver` address; all disputes go to that address. Module version `1.0.0`. |
| `DecentralizedResolutionModule` (DRM) | Three-round pipeline (round-robin pool → senior resolver → Kleros). Full escalation cost curves, EMA-based resolver scoring, appeal windows, incentive hooks. The primary production module. |
| `KlerosArbitrableProxy` | Implements `IResolutionModule` as the terminal round-2 adapter. Assigned as `externalResolver` in the DRM. |

**How it is read from the snapshot:** `moduleSnapshots[workflowId].resolutionModule`.

---

### 3.2 Release strategy (`IReleaseStrategy`)

**What it controls:** Whether a given caller is permitted to release (settle in favour of
the recipient) an escrow in `PENDING` state. The core contract calls `canRelease()` and
enforces the answer; the strategy itself has no ability to transfer funds.

**Interface summary:**

| Function | Called when |
|----------|-------------|
| `canRelease(workflowId, escrow, caller, escrowData)` | `BaseEscrow.release()` is called |
| `executeRelease(workflowId, escrow, escrowData)` | Reserved for v2; current implementations revert |
| `moduleName() / strategyName()` | Introspection |

`escrowData` is encoded as `abi.encode(token, sender, recipient, amountAfterFee, releaseAddress)`.
The `releaseAddress` field (from `EscrowSettings`) allows the escrow creator to designate a
delegated release address distinct from the sender.

**Current implementations:**

| Contract | Who can release |
|----------|----------------|
| `DefaultReleaseStrategy` | The original sender (`et.from`) or a delegated `releaseAddress` set in `EscrowSettings`. This is the default. Module name `DefaultBuyerRelease`, version `1.0.0`. |

**How it is read from the snapshot:** `moduleSnapshots[workflowId].releaseStrategy`.

---

### 3.3 Cancellation strategy (`ICancellationStrategy`)

**What it controls:** Whether a given caller is permitted to cancel (settle in favour of
the sender) an escrow before it reaches dispute. Two separate permissions are queried:
`canCancel()` (can the caller cancel at all?) and `canCancelUnilaterally()` (can they do
so without the other party's consent?).

The strategy also receives a notification hook `onCancelAttempt()` that allows stateful
strategies to track pending cancel requests — for example, a two-party mutual-agreement
strategy that only cancels when both parties have signalled intent.

**Interface summary:**

| Function | Called when |
|----------|-------------|
| `canCancel(workflowId, caller, et)` | `recipientCancel()` or `senderCancel()` is called |
| `canCancelUnilaterally(workflowId, caller, et)` | Determining whether immediate cancellation is permitted |
| `onCancelAttempt(workflowId, caller, isSuccess)` | Before executing any cancellation |

Note: `ICancellationStrategy` does not extend `IERC165`. The `et` parameter is the full
`EscrowTransfer` struct, giving the strategy access to all escrow metadata.

**Current implementations:**

| Contract | Who can cancel |
|----------|---------------|
| `DefaultCancellationStrategy` | Both parties; unilateral cancel only after `autoCancelTime` has elapsed. Mutual agreement available any time. |
| `BuyerOnlyCancellationStrategy` | Recipient (`et.to`) only, unilaterally, at any time. Useful for buyer-protection scenarios. |

**How it is read from the snapshot:** `moduleSnapshots[workflowId].cancellationStrategy`.

---

### 3.4 Yield generation module (`IYieldGenerationModule`)

**What it controls:** Where idle escrow funds are deployed to earn yield during the escrow
lifetime. The module receives funds from the escrow at creation (or at activation), deploys
them to an external protocol, tracks the position, and returns principal + yield on
withdrawal.

**Interface summary:**

| Function | Called when |
|----------|-------------|
| `depositForYield(workflowId, token, amount, escrow)` | Yield is activated on an escrow |
| `withdrawWithYield(workflowId, token, original, escrow)` | The escrow is being settled (release/cancel/resolve) |
| `calculateYield(workflowId, token, escrow)` | Current accrued yield is queried |
| `getPosition(workflowId, token, escrow)` | Full position data is queried |
| `isTokenSupported(token)` | Checking before activating yield |
| `getApprovalTarget(token)` | Queried so escrow can pre-approve the module's spending pool |
| `getAavePoolAddress() / getATokenAddress(token)` | Optional; used by library pattern for Aave integration |

**Current implementations:**

| Contract | Yield source |
|----------|-------------|
| `DefaultYieldGenerationModule` | No-op; returns principal unchanged. Used when yield is disabled. |
| `AaveYieldModule` | Aave V3 supply/withdraw via `IAavePool`. Tracks scaled aToken balances per `(escrow, workflowId)`. Includes emergency recovery path. |

**Exclusivity constraint:** Each yield generation module may be assigned to at most one
escrow contract. `ModuleSnapshotRegistry.queueModule()` reverts with
`YieldModuleAlreadyAssigned` if a module address is already mapped to a different escrow.
This prevents cross-contamination of position state.

**How it is read from the snapshot:** `moduleSnapshots[workflowId].yieldGenerationModule`.

---

### 3.5 Yield distribution module (`IYieldDistributionModule`)

**What it controls:** How accrued yield is split between parties on settlement. The
generation and distribution concerns are deliberately separated: one module earns the
yield; a different module decides who receives it.

**Interface summary:**

| Function | Called when |
|----------|-------------|
| `distributeYield(workflowId, escrow, token, yieldAmount, distributionData)` | Settlement executes with non-zero yield |

`distributionData` encodes the distribution configuration (recipients and percentages) as
determined by the `YieldPreset` selected in `EscrowSettings` at creation time. The preset
is resolved to concrete distribution data by the core before calling the module, so the
module itself is stateless with respect to individual escrow configurations.

**Current implementations:**

| Contract | Distribution logic |
|----------|-------------------|
| `DefaultYieldDistributionModule` | Interprets the encoded `distributionData` and transfers yield portions to the specified recipients. |

**How it is read from the snapshot:** `moduleSnapshots[workflowId].yieldDistributionModule`.

---

### 3.6 Incentive module (`IIncentiveModule`)

**What it controls:** Resolver performance tracking, appeal bond receipt, bond distribution
on finality, and (in DR v3) resolver staking and slashing. The incentive module is a lifecycle
hook system — it does not make decisions, but it is notified at every significant event and
can accumulate state for bond/reward calculations.

**Interface summary (lifecycle hooks):**

| Hook | Triggered by |
|------|-------------|
| `onDisputeOpened(workflowId, escrow, token, amount, fee, round)` | `raiseDispute()` |
| `onResolverAssigned(workflowId, escrow, resolver, round)` | Initial assignment or escalation |
| `onDecisionSubmitted(workflowId, escrow, resolver, round, decision, responseTime)` | A resolver calls `releaseAsDisputeResolver` or `cancelAsDisputeResolver` |
| `onEscalated(workflowId, escrow, fromRound, toRound, escalatedBy)` | `escalateDispute()` |
| `onAppealBondDeposited(workflowId, escrow, depositor, token, amount, round)` | Appeal bond is posted |
| `onDisputeFinalized(workflowId, escrow, finalRound, finalDecision)` | `finalizeDispute()` |
| `onResolverTimeout(workflowId, escrow, resolver, round)` | Liveness timeout triggers |

**Current implementations:**

| Contract | Version | Behaviour |
|----------|---------|-----------|
| `ResolverIncentiveModuleV1` | DR v1 | Performance tracking only. EMA quality score per resolver. No bonds. |
| `ResolverIncentiveModuleV2` | DR v2 | V1 features plus appeal bond receipt, bond distribution to prior-round resolvers on finality, escalation cost curves. |
| `SlashingModuleNoOp` | — | Satisfies `ISlashingModule`; all functions are no-ops. |
| `StakingModuleNoOp` | — | Satisfies `IStakingModule`; all functions are no-ops. Used until DR v3 staking is live. |

The incentive module address is not stored directly in `ModuleSnapshotRegistry`. It is
retrieved at snapshot time via `ModuleSnapshotLibrary.getIncentiveModule(resModule)`, which
reads the incentive module address from the resolution module itself. This means the
incentive module is coupled to the resolution module: a resolution module upgrade can
bring a new incentive module with it.

**How it is read from the snapshot:** `moduleSnapshots[workflowId].incentiveModule`.

---

## 4. Per-escrow module overrides (`EscrowSettings`)

While modules are configured at the escrow-contract level and applied to all escrows by
default, individual escrow creators can override two aspects at creation time via
`EscrowSettings`:

```solidity
// types/EscrowTypes.sol
struct EscrowSettings {
    address customResolver;   // Override the module's resolver selection (address(0) = use module default)
    address releaseAddress;   // Delegated release address (address(0) = sender only)
    YieldPreset yieldPreset;  // Yield distribution preset (OFF, TO_SENDER, TO_RECIPIENT, SPLIT, ...)
    uint256 autoReleaseTime;  // Custom auto-release timeout (0 = use contract default)
    uint256 autoCancelTime;   // Custom auto-cancel timeout (0 = use contract default)
}
```

`customResolver` is particularly important for the resolution module interaction: when set
to a non-zero address, the escrow's `_isAuthorizedDisputeResolver` logic routes resolver
lookups to the custom address instead of consulting the resolution module. This assignment
is immutable for the lifetime of the escrow — governance or module-level resolver rotations
cannot override a per-escrow custom resolver once it is set:

```solidity
// BaseEscrow.sol
// Governance or module-level resolver changes must NOT override this per-escrow choice.
EscrowSettings memory settings = escrowSettings[workflowId];
if (settings.customResolver != address(0)) {
    // use settings.customResolver directly — module is not consulted
}
```

`releaseAddress` is passed into `escrowData` on every call to `IReleaseStrategy.canRelease`,
giving the release strategy the opportunity to honour it.

---

## 5. Module registry and governance lifecycle

### 5.1 `ModuleSnapshotRegistry`

`ModuleSnapshotRegistry` is the single source of truth for current default modules per
escrow contract. It holds a `ModuleState` per registered escrow:

```solidity
struct ModuleState {
    IReleaseStrategy            defaultReleaseStrategy;
    ICancellationStrategy       defaultCancellationStrategy;
    IYieldGenerationModule      defaultYieldGenerationModule;
    IYieldDistributionModule    defaultYieldDistributionModule;
    IResolutionModule           defaultResolutionModule;
    mapping(ModuleType => PendingAddress) pendingModules;
}
```

`ICancellationStrategy` does not have a slow-lane queue; it is set directly via
`setDefaultCancellationStrategy(escrow, strategy)` (gated by `ROLE_TIMELOCK`). All other
module types go through the queue/activate pattern.

### 5.2 Queue/activate pattern (slow lane)

Changes to `RESOLUTION`, `RELEASE`, `YIELD_GEN`, and `YIELD_DIST` module defaults require
two on-chain transactions separated by a mandatory 7-day delay:

```
ROLE_TIMELOCK calls queueModule(escrow, moduleType, newAddress)
    → Stores pending.value = newAddress
    → Stores pending.eta = block.timestamp + 7 days
    → Emits e.g. DefaultResolutionModuleQueued(escrow, old, new, eta)

         ← 7 days pass (enforced on-chain) →

ROLE_TIMELOCK calls activateModule(escrow, moduleType)
    → Reverts if pending.eta not reached
    → Sets new default module
    → Emits e.g. DefaultResolutionModuleActivated(escrow, old, new)
```

`ROLE_TIMELOCK` is held by the `TimelockController` (48-hour execution delay). Combined
with the 7-day slow lane, the minimum time from governance proposal to module activation
is approximately 9+ days (plus the governance voting period).

### 5.3 Yield module exclusivity

A yield generation or distribution module may be assigned to at most one escrow contract.
`queueModule()` enforces this:

```solidity
address currentEscrow = yieldGenerationModuleToEscrow[module];
if (currentEscrow != address(0) && currentEscrow != escrowContract) {
    revert YieldModuleAlreadyAssigned(module, currentEscrow, escrowContract);
}
```

This prevents two escrow contracts from sharing yield position state in the same module
instance, which would corrupt per-escrow accounting.

### 5.4 Escrow registration

Before any module can be managed for an escrow contract, that contract must be registered:

```solidity
ModuleSnapshotRegistry.registerEscrowContract(address escrow)  // onlyRole(ROLE_TIMELOCK)
```

This grants `ROLE_ESCROW_CONTRACT` to the escrow contract address, which is required before
`queueModule` or `activateModule` will execute.

---

## 6. Interface compliance conventions

All module interfaces follow a set of shared conventions:

**ERC-165 support.** All module interfaces except `ICancellationStrategy` extend `IERC165`.
Implementations must override `supportsInterface()` to return `true` for the module's
interface type ID. BaseEscrow and the DRM use `staticcall` with ERC-165 checks to verify
that a module supports the expected interface before use.

**`moduleName()` and `moduleVersion()`.**  Every module interface requires these two
`pure` functions. `moduleVersion()` must follow semantic versioning (`MAJOR.MINOR.PATCH`);
a major version increment signals breaking interface changes.

**No state side effects in view functions.** Functions called via `staticcall` (e.g.,
`canRelease`, `canEscalate`, `isAuthorizedDisputeResolver`, `getDisputeResolver`) must
be pure or view. They must not revert due to missing state — they should return a
`(false, reason)` tuple or equivalent rather than reverting on a missing record.

**`try/catch` wrapping.** BaseEscrow and the DRM wrap most module calls in `try/catch`.
A module that reverts unexpectedly on a lifecycle hook will not prevent the escrow
operation from completing; the failure is emitted as an event (e.g.,
`IncentiveModuleCallFailed`). Modules should not rely on revert-to-block behaviour.

---

## 7. Deployed module inventory

| Module | Type | Interface | Contract | Version |
|--------|------|-----------|----------|---------|
| `DefaultBuyerRelease` | Release strategy | `IReleaseStrategy` | `DefaultReleaseStrategy` | 1.0.0 |
| `DefaultCancellationStrategy` | Cancellation strategy | `ICancellationStrategy` | `DefaultCancellationStrategy` | — |
| `BuyerOnlyCancellationStrategy` | Cancellation strategy | `ICancellationStrategy` | `BuyerOnlyCancellationStrategy` | — |
| `DefaultResolutionModule` | Resolution | `IResolutionModule` | `DefaultResolutionModule` | 1.0.0 |
| `DecentralizedResolutionModule` | Resolution | `IResolutionModule` | `DecentralizedResolutionModule` | — |
| `KlerosArbitrableProxy` | Resolution (terminal) | `IResolutionModule` + `IArbitrable` | `KlerosArbitrableProxy` | 1.0.0 |
| `DefaultYieldGenerationModule` | Yield generation (no-op) | `IYieldGenerationModule` | `DefaultYieldGenerationModule` | — |
| `AaveYieldModule` | Yield generation | `IYieldModule` (extends `IYieldGenerationModule`) | `AaveYieldModule` | — |
| `DefaultYieldDistributionModule` | Yield distribution | `IYieldDistributionModule` | `DefaultYieldDistributionModule` | — |
| `ResolverIncentiveModuleV1` | Incentive | `IIncentiveModule` | `ResolverIncentiveModuleV1` | DR v1 |
| `ResolverIncentiveModuleV2` | Incentive (bonds) | `IIncentiveModule` | `ResolverIncentiveModuleV2` | DR v2 |
| `SlashingModuleNoOp` | Slashing (stub) | `ISlashingModule` | `SlashingModuleNoOp` | — |
| `StakingModuleNoOp` | Staking (stub) | `IStakingModule` | `StakingModuleNoOp` | — |

---

## 8. Writing a new module

### 8.1 Implementing the interface

Choose the appropriate interface from `contracts/interfaces/` or
`contracts/shared/interfaces/`. Implement every function — including those your module does
not actively use. For no-op functions, return a safe default rather than reverting: for
example, `initializeDispute` can be an empty function body; `canEscalate` should return
`(false, address(0), 0)` if escalation is not supported.

Implement `moduleName()` and `moduleVersion()` as `pure` functions. Implement
`supportsInterface()` if the interface extends `IERC165`.

### 8.2 Handling the `escrowData` encoding

Most module functions receive `escrowData` as a `bytes calldata` parameter. The canonical
encoding is:

```solidity
abi.encode(token, from, to, amountAfterFee, releaseAddress)
```

produced by `EscrowEncodingLibrary.encodeEscrowTransferData`. Do not assume a different
encoding unless you control both the encoding and decoding sides.

### 8.3 Avoiding revert-based blocking

Because BaseEscrow wraps most module calls in `try/catch`, a module that reverts will not
break the escrow operation — but it will silently fail. Design module state to be resilient
to out-of-order or duplicate calls. Do not assume any specific call ordering beyond what
the interface documentation guarantees.

### 8.4 Governance wiring

After deployment:

1. Call `ModuleSnapshotRegistry.queueModule(escrowContract, moduleType, newAddress)` —
   requires `ROLE_TIMELOCK`.
2. Wait 7 days for the slow lane ETA to pass.
3. Call `ModuleSnapshotRegistry.activateModule(escrowContract, moduleType)` —
   requires `ROLE_TIMELOCK`.

New escrows created after activation will use your module. Existing escrows are unaffected.

For resolution modules that include an incentive sub-module, the incentive module address
must be readable via `ModuleSnapshotLibrary.getIncentiveModule(resModule)`. Implement the
`getIncentiveModule()` view function on your resolution module to return the incentive
module address, or return `address(0)` if no incentive module is attached.

### 8.5 Testing checklist

Before submitting a new module for governance activation:

- [ ] All interface functions implemented (no accidentally missing overrides).
- [ ] `supportsInterface` returns `true` for the module's interface type ID.
- [ ] No-op functions return safe defaults (not reverts).
- [ ] `moduleName()` and `moduleVersion()` return non-empty strings.
- [ ] Module handles the case where `workflowId` has no associated state (first call).
- [ ] Module handles duplicate calls to lifecycle hooks (idempotent where appropriate).
- [ ] `escrowData` decoding matches `EscrowEncodingLibrary.encodeEscrowTransferData`.
- [ ] For yield modules: position accounting is self-consistent across deposit/withdraw cycles.
- [ ] For yield modules: `isTokenSupported` returns `false` for unsupported tokens.
- [ ] Module does not assume a specific call to `initializeDispute` before other hooks.

---

## 9. Module interaction diagram

```
Escrow creation
  │
  └─► _snapshotModulesForEscrow()
        Reads: defaultReleaseStrategy
               defaultCancellationStrategy
               defaultYieldGenerationModule
               defaultYieldDistributionModule
               defaultResolutionModule  → getIncentiveModule() → incentiveModule
               yieldProtocolFeeBps, appealBondProtocolFeeBps, escrowFeeBps
               timeoutConfig (delays, durations)
        Writes: moduleSnapshots[workflowId]  ← immutable from this point

Pending → Released
  ├─► IReleaseStrategy.canRelease()      ← reads snap.releaseStrategy
  └─► IYieldGenerationModule.withdrawWithYield()  ← reads snap.yieldGenerationModule
      IYieldDistributionModule.distributeYield()  ← reads snap.yieldDistributionModule

Pending → Disputed
  └─► IResolutionModule.initializeDispute()  ← reads snap.resolutionModule
      IIncentiveModule.onDisputeOpened()     ← reads snap.incentiveModule

Disputed → escalated
  ├─► IResolutionModule.canEscalate()
  ├─► IResolutionModule.getRequiredAppealBond()
  ├─► IResolutionModule.executeEscalation()
  └─► IIncentiveModule.onEscalated()

Disputed → Resolved (resolver settles)
  ├─► IResolutionModule.isAuthorizedDisputeResolver()
  ├─► IResolutionModule.recordResolution()
  └─► IIncentiveModule.onDecisionSubmitted()

Resolved → finalized (appeal window closed)
  ├─► IResolutionModule.finalizeDispute()
  └─► IIncentiveModule.onDisputeFinalized()

Pending/Disputed → Cancelled
  ├─► ICancellationStrategy.canCancel()
  ├─► ICancellationStrategy.canCancelUnilaterally()
  └─► ICancellationStrategy.onCancelAttempt()
```

---

## 10. What modularity does not cover

The module system is specifically for the six axes described above. The following are
**not** modular in the current architecture:

**The state machine itself.** `EscrowState` transitions (`PENDING → DISPUTED`, `DISPUTED →
RESOLVED`, etc.) are hardcoded in `BaseEscrow`. The state machine is not pluggable.

**Fee accounting.** `escrowFeeBps`, `yieldProtocolFeeBps`, and `appealBondProtocolFeeBps`
are parameters in `ModuleSnapshot` but the accounting logic that applies them is in
`BaseEscrow` and library contracts. They are configurable but not replaceable.

**Token handling.** ERC-20 and native token support is built into `BaseEscrow`. There is
no pluggable token module.

**The ops contracts (`DisputeOps`, `YieldOps`, `SettlementOps`, `CreateOps`).** These are
external library-style contracts used by `BaseEscrow` for compute-intensive operations.
They are upgradeable via governance (`setDisputeOps`, `setYieldOps`, etc.) but they are
not module interfaces — they contain logic that belongs to the core, not to a pluggable
extension point.

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against `ModuleSnapshotRegistry.sol`, `BaseEscrow.sol` snapshot isolation, and slow-lane activation flow. Module snapshot field list verified against `EscrowTypes.sol`. Simulation covers snapshot isolation via scenarios S26 (governance sandwich) and S01–S10 lifecycle. Full cross-module interaction coverage not yet simulation-backed — needs follow-up. |
