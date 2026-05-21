# Sew Protocol — Protocol Overview

**Last Updated**: May 2026  
**Status**: Production (DR v3 complete)

---

## What Sew Protocol is

Sew Protocol is a decentralized escrow and dispute-resolution system built on Base (Ethereum
L2). It provides trustless conditional payments for physical and digital commerce: a buyer
locks funds on-chain at the moment of payment; the seller can see the commitment but cannot
access the funds until the buyer approves delivery — or an agreed timer expires. If delivery
fails, the buyer can raise a dispute.

The protocol does not require trust in the counterparty, in any intermediary, or in the
protocol team. Rules are locked at escrow creation and cannot be changed retroactively by
anyone, including governance.

---

## Core properties

| Property | Guarantee |
|---|---|
| **Non-custodial** | Funds are held by escrow contracts, never by the protocol team |
| **Immutable per-escrow rules** | Module configuration and fees are snapshotted at creation |
| **Pull-only settlement** | No function pushes tokens; recipients claim from a ledger |
| **Typed state machine** | Every state transition is explicit; invalid transitions revert |
| **Modular and upgradeable** | Modules swap via governance; upgrades only affect new escrows |
| **Adversarially tested** | Dispute behavior validated under 48+ deterministic scenarios and 147,500+ Monte Carlo trials |

---

## System overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Sew Protocol                                │
│                                                                     │
│  ┌─────────────────────┐         ┌──────────────────────────────┐  │
│  │   Core Escrow        │◄───────►│   Governance                 │  │
│  │   (Immutable)        │         │   Governor + Timelock + Safe  │  │
│  │                      │         └──────────────────────────────┘  │
│  │  EscrowVault         │                                            │
│  │  EscrowableERC20     │         ┌──────────────────────────────┐  │
│  │  BaseEscrow (base)   │         │   SEW Token                  │  │
│  └──────────┬───────────┘         │   ERC20Votes, fixed supply   │  │
│             │                     └──────────────────────────────┘  │
│             │ module interfaces                                      │
│   ┌─────────┼──────────────────────────────────────────────┐       │
│   │         │                                              │       │
│   ▼         ▼                    ▼              ▼          │       │
│  Resolution  Release/Cancel     Yield          Incentive   │       │
│  Module      Strategies         Modules        Module      │       │
│                                                            │       │
│   DefaultResolutionModule (IEO)                            │       │
│   DecentralizedResolutionModule (DR v1/v2/v3)              │       │
│     └─ ResolverIncentiveModuleV1  (DR v1)                  │       │
│     └─ ResolverIncentiveModuleV2  (DR v2)                  │       │
│     └─ ResolverIncentiveModuleV3  (DR v3) ✅               │       │
│     └─ KlerosArbitrableProxy      (L2 final escalation)    │       │
│                                                             │       │
│   AaveYieldModule                                           │       │
│   DefaultYieldDistributionModule                            │       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Escrow lifecycle

An escrow moves through an explicit state machine. States are defined in `EscrowTypes.sol`.

```
NONE
 │
 │  createEscrow()
 ▼
PENDING ─────── release() ────────────────────────────────────► RELEASED
   │
   │─── recipientCancel() / senderCancel() ──────────────────► REFUNDED
   │
   │─── proposeSplit() + acceptSplit() ──────────────────────► RESOLVED
   │
   │─── automateTimedActions() [auto-release] ───────────────► RELEASED
   │─── automateTimedActions() [auto-cancel] ────────────────► REFUNDED
   │
   │  raiseDispute()
   ▼
DISPUTED
   │
   │─── releaseAsDisputeResolver() [final] ──────────────────► RELEASED
   │─── cancelAsDisputeResolver()  [final] ──────────────────► REFUNDED
   │
   │─── executePendingSettlement() [split] ──────────────────► RESOLVED
   │
   │─── resolveDisputeByTimeout() ───────────────────────────► REFUNDED
   │
   │   (escalation within DISPUTED — see below)
```

`RELEASED`, `REFUNDED`, and `RESOLVED` are terminal: no further transitions are possible.

**Key rules:**
- Only the sender (`et.from`) can call `release()`.
- Either party can `raiseDispute()` while in `PENDING`.
- `recipientCancel()` permission is controlled by the cancellation strategy module.
- `automateTimedActions()` is callable by any keeper once the configured delay expires.
- All fund delivery is pull-only: settlement credits `claimableBalances[workflowId][address]`.

→ Full state machine reference: [`docs/STATE_MACHINE.md`](STATE_MACHINE.md)  
→ Settlement paths in detail: [`docs/SETTLEMENT.md`](SETTLEMENT.md)

---

## Dispute resolution

When a buyer raises a dispute, the resolution module determines how it is resolved. The
protocol ships two resolution modules.

### DefaultResolutionModule (IEO / initial launch)

A single trusted resolver is assigned per escrow at creation. The resolver calls
`releaseAsDisputeResolver()` or `cancelAsDisputeResolver()` to close the dispute. There
is no escalation path. This is the initial mainnet module — minimal attack surface, no
resolver capital at risk.

### DecentralizedResolutionModule (DR v1 → v2 → v3)

A multi-resolver, three-round escalation system with an external backstop at Kleros.

```
Round 0 — Standard resolver (round-robin from registered pool)
            Appeal window: 2 days after decision
               │  escalation bond required
               ▼
Round 1 — Senior resolver (DAO-appointed, higher accountability)
            Appeal window: 3 days after decision
               │  escalation bond required
               ▼
Round 2 — Kleros (ERC-792 external arbitration — final)
            No further escalation possible
```

**Escalation bonds** are posted by the party that appeals. If the new round confirms the
original decision, the appealing party forfeits the bond (which flows to the upheld
resolver). If the new round reverses the decision, the bond is refunded. This makes
frivolous appeals costly.

**Resolver assignment** is weighted round-robin from the registered standard resolver pool,
adjusted by EMA reputation score. Resolvers with lower performance scores receive fewer
assignments.

**Dispute timeout**: if no resolver acts within `maxDisputeDuration`, any keeper can call
`resolveDisputeByTimeout()` to auto-refund the sender.

→ Full DR architecture: [`docs/dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md`](dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md)  
→ Kleros integration: [`docs/guides/KLEROS_INTEGRATION_GUIDE.md`](guides/KLEROS_INTEGRATION_GUIDE.md)

---

## Dispute resolution versioning (DR v1 / v2 / v3)

The incentive layer is decentralized in three stages. Each stage is a separate
`ResolverIncentiveModule` contract, swapped in via governance. The core DRM state machine
is unchanged across versions.

| Version | What is decentralized | Resolver capital at risk |
|---|---|---|
| **DR v1** | Decisions — workload routing, EMA reputation scoring | ❌ No |
| **DR v2** | Incentives — user-posted appeal bonds, escalation cost curves | ❌ No (user bonds only) |
| **DR v3** ✅ | Capital — resolver staking, slashing, senior coverage, insurance pool | ✅ Yes |

### DR v3 specifics

- **Mixed bond enforcement**: resolver bonds must be ≥ 80% stable tokens / ≤ 20% SEW, with a 50% haircut on SEW value.
- **Capacity gating**: `maxEscrowPerL0Case = min($2,000, 4× effectiveBondUSD)`.
- **Slashing schedule**: missed-accept 0.25%, missed-resolve 2% (5% repeat), epoch caps of 20% / 10% per 7-day epoch.
- **Senior coverage**: senior resolvers back standard resolvers with declared coverage limits; slashing can propagate to seniors.
- **Slashed SEW is burned**: transferred to `0xdEaD` or burned directly when the token supports it.
- **Insurance pool**: funded by a portion of resolver fees; pays out to affected parties on resolver insolvency (7-day delay).

→ DR v3 parameters: [`docs/dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md`](dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md)  
→ Dispute economics: [`docs/dispute-resolution/DISPUTE_ECONOMICS.md`](dispute-resolution/DISPUTE_ECONOMICS.md)

---

## Module system

The protocol is built around six module axes, all independently configurable per deployment
and frozen per-escrow at creation.

| Module axis | Interface | Controls |
|---|---|---|
| Resolution | `IResolutionModule` | Who resolves disputes; how escalation works |
| Release strategy | `IReleaseStrategy` | Who can release the escrow and when |
| Cancellation strategy | `ICancellationStrategy` | Who can cancel the escrow and when |
| Yield generation | `IYieldGenerationModule` | Where idle funds are deployed (e.g. Aave) |
| Yield distribution | `IYieldDistributionModule` | How yield is split on settlement |
| Incentive | `IIncentiveModule` | Resolver performance tracking and bond logic |

**Snapshot isolation**: at escrow creation, `_snapshotModulesForEscrow(workflowId)` writes a
`ModuleSnapshot` struct capturing all module addresses and fee parameters. Every subsequent
operation reads from this snapshot. Governance changes to module defaults affect only new
escrows created after activation.

→ Module system in depth: [`docs/architecture/PROTOCOL_MODULARITY.md`](architecture/PROTOCOL_MODULARITY.md)

---

## Yield integration

Escrowed funds can be deployed to external yield protocols while locked. The reference
implementation uses Aave v3 on Base.

**Flow**:
1. Sender calls `createEscrow()` — funds are deposited into the yield module immediately.
2. Yield accrues in the background.
3. On settlement, `_handleYieldModuleUnwind()` withdraws principal + yield and credits the
   claimable ledger.

**Failure handling**: if `unwindToEscrow()` fails, `emergencyUnwind()` is tried. If both
fail, the escrow settles using the original principal — tokens remain in the yield module
and require admin recovery. This design ensures settlement is never blocked by yield module
failure.

**Yield distribution** is configurable per deployment: the default module splits yield
proportionally by time-weighted contribution.

→ Yield architecture: [`docs/architecture/ARCHITECTURE_YIELD_MODULES.md`](architecture/ARCHITECTURE_YIELD_MODULES.md)

---

## Governance model

### Roles

| Role | Holder | What they can do |
|---|---|---|
| `ROLE_GUARDIAN` | Safe multisig | Pause, reduce caps, disable features (down-only) |
| `ROLE_TIMELOCK` | TimelockController | Execute governance proposals after delay |
| Governor | GovGovernor (token-weighted) | Propose and vote on protocol changes |

### Governance lanes

All non-emergency changes pass through two delay layers stacked in series:

```
Governor vote passes
      │
      ▼  TimelockController
      │  minimum 48-hour delay (all operations)
      ▼
      │  SlowLaneQueueActivate  (for module swaps and high-risk params)
      │  additional 7-day delay
      ▼
Change takes effect — for new escrows only
```

**Emergency lane** (Guardian only, zero delay):
- Pause the protocol
- Reduce token caps
- Disable Aave yield

**Guarantees**:
- No governance action can change the rules of an existing escrow.
- `CANCELLER_ROLE` on TimelockController is Governor-only — Guardian cannot override governance intent.
- Emergency controls are strictly down-only.
- There is no "cancel queued change" shortcut; retreating from a change costs at least another full delay cycle (forward-only upgrades).

→ Governance surface map: [`docs/governance/GOVERNANCE_SURFACE_MAP.md`](governance/GOVERNANCE_SURFACE_MAP.md)  
→ Forward-only upgrades explained: [`docs/FORWARD_ONLY_UPGRADES.md`](FORWARD_ONLY_UPGRADES.md)

---

## SEW token

- **Type**: ERC20Votes with ERC20Burnable, fixed supply (1 billion tokens)
- **Governance**: used for onchain voting weight in GovGovernor
- **Economic role**: resolver bonds in DR v3 may include SEW (≤ 20% of bond, 50% haircut)
- **Slashing**: slashed SEW is burned — reducing circulating supply
- **No minting**: supply is fixed at deploy; no mint function exists post-launch

---

## Security model

### Core guarantees

- Core contracts (`BaseEscrow`, `EscrowVault`, `EscrowableERC20`) are **not upgradeable via proxy**. Protocol evolution happens through module swaps only.
- Invariant guards (`InvariantGuardInternal.sol`) enforce accounting properties on every state transition on-chain.
- Reentrancy protection on all external-facing functions.
- Pausable at the contract level (Guardian only).

### Adversarial validation (simulation)

The Sew simulator (`sew-simulation` repository) provides three layers of adversarial testing:

1. **Deterministic replay**: 48+ named scenarios replayed through the protocol kernel with 36 invariants checked after every step. Types: baseline, edge-case, stress, adversarial (profit-maximizer, forking-strategist, colluder).

2. **Monte Carlo simulation**: 147,500+ trials across 8 statistical phases (slashing delays, bond mechanics, detection, multi-epoch reputation, waterfall cascade, governance response time, appeals, market exit).

3. **Adversarial research**: 18+ falsifiable adversarial simulations — bribery markets, collusion rings, escalation traps, flash-loan stake inflation, liveness attacks, information cascades.

→ Robustness framework: [`../sew-simulation/docs/ROBUSTNESS_FRAMEWORK.md`](../../sew-simulation/docs/ROBUSTNESS_FRAMEWORK.md)  
→ Security model: [`docs/security/SECURITY_MODEL.md`](security/SECURITY_MODEL.md)  
→ Audit doc: [`docs/reviews/AUDIT.md`](reviews/AUDIT.md)

---

## Key time windows

The protocol uses time-bounded windows throughout. The most operationally significant:

| Window | Default | Configurable |
|---|---|---|
| Auto-release delay | per-escrow or global default | ✅ (≤ 30 days) |
| Auto-cancel delay | per-escrow or global default | ✅ (mutually exclusive with auto-release) |
| Max dispute duration | configurable per escrow | ✅ |
| DRM appeal window (round 0) | 2 days | ✅ (governance) |
| DRM appeal window (round 1) | 3 days | ✅ (governance) |
| DRM resolve deadline (round 0) | 24 hours | ✅ |
| DRM resolve deadline (round 2) | 7 days | ✅ |
| Governance timelock (standard) | 48 hours | ❌ |
| Governance slow lane | 7 days | ❌ |
| Insurance pool payout delay | 7 days | ❌ |

→ Complete window reference: [`docs/WINDOWS.md`](WINDOWS.md)

---

## Finality

Finality in Sew Protocol is two-phase:

1. **Outcome determination**: the state machine transitions to a terminal state
   (`RELEASED` / `REFUNDED` / `RESOLVED`) and the claimable ledger is credited.
2. **Fund delivery**: the beneficiary calls `withdrawEscrow(workflowId)` to pull their
   tokens. This is a separate, idempotent transaction.

**Partial finality** exists during the appeal window: `DISPUTED` state with
`pendingSettlements[workflowId].exists == true`. The outcome is determined but funds are
held pending the appeal window expiry.

Once a terminal state is reached, it is absorbing: no transition out is possible and no
function can alter the credited amount.

→ Finality reference: [`docs/FINALITY.md`](FINALITY.md)

---

## Deployment architecture

| Contract | Pattern | Upgrade path |
|---|---|---|
| `EscrowVault` | Immutable (no proxy) | Module swap via governance |
| `EscrowableERC20` | Factory + immutable | Module swap via governance |
| `BaseEscrow` | Abstract base | No upgrade; module swap |
| `DecentralizedResolutionModule` | Immutable | Deploy new version, swap via governance |
| `ResolverIncentiveModule*` | Immutable | Deploy new version, swap via governance |
| `GovGovernor` | Transparent proxy | Governance vote + timelock |
| `TimelockController` | OpenZeppelin standard | Governance vote |

Networks: **Base Mainnet** (production), **Base Sepolia** (testnet), **Hardhat** (local).

→ Deployment guide: [`docs/operations/DEPLOYMENT.md`](operations/DEPLOYMENT.md)  
→ Deployment releases: [`docs/deployment/RELEASES.md`](deployment/RELEASES.md)

---

## Document index

| Topic | Document |
|---|---|
| Architecture | [`docs/architecture/ARCHITECTURE_OVERVIEW.md`](architecture/ARCHITECTURE_OVERVIEW.md) |
| Technical contracts reference | [`docs/architecture/TECHNICAL_OVERVIEW.md`](architecture/TECHNICAL_OVERVIEW.md) |
| Modularity | [`docs/architecture/PROTOCOL_MODULARITY.md`](architecture/PROTOCOL_MODULARITY.md) |
| State machine | [`docs/STATE_MACHINE.md`](STATE_MACHINE.md) |
| Settlement paths | [`docs/SETTLEMENT.md`](SETTLEMENT.md) |
| Finality | [`docs/FINALITY.md`](FINALITY.md) |
| Withdrawals | [`docs/WITHDRAWALS.md`](WITHDRAWALS.md) |
| Time windows | [`docs/WINDOWS.md`](WINDOWS.md) |
| Prepayments | [`docs/PREPAYMENTS.md`](PREPAYMENTS.md) |
| Dispute resolution architecture | [`docs/dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md`](dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md) |
| Dispute economics | [`docs/dispute-resolution/DISPUTE_ECONOMICS.md`](dispute-resolution/DISPUTE_ECONOMICS.md) |
| DR v3 launch defaults | [`docs/dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md`](dispute-resolution/DR_V3_LAUNCH_SAFE_DEFAULTS.md) |
| Kleros integration | [`docs/guides/KLEROS_INTEGRATION_GUIDE.md`](guides/KLEROS_INTEGRATION_GUIDE.md) |
| Governance surface map | [`docs/governance/GOVERNANCE_SURFACE_MAP.md`](governance/GOVERNANCE_SURFACE_MAP.md) |
| Governance policy | [`docs/governance/governance.md`](governance/governance.md) |
| Forward-only upgrades | [`docs/FORWARD_ONLY_UPGRADES.md`](FORWARD_ONLY_UPGRADES.md) |
| Auto-expiry authorisation | [`docs/AUTO_EXPIRY_AUTHORISATION.md`](AUTO_EXPIRY_AUTHORISATION.md) |
| Security model | [`docs/security/SECURITY_MODEL.md`](security/SECURITY_MODEL.md) |
| Audit | [`docs/reviews/AUDIT.md`](reviews/AUDIT.md) |
| Robustness framework (simulation) | [`sew-simulation/docs/ROBUSTNESS_FRAMEWORK.md`](../../sew-simulation/docs/ROBUSTNESS_FRAMEWORK.md) |

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually reviewed for accuracy against contract source and subsystem documentation. High-level flow verified against `BaseEscrow.sol`, `EscrowFactory.sol`, DR v3 contracts, and governance configuration. Intended as the primary entry-point document for external reviewers. All referenced subsystem docs exist and are consistent with this overview. |
