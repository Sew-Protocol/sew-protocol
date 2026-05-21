# Governance Constraints

> **Scope:** This document enumerates what governance **cannot** do, what is permanently
> frozen, and what numerical bounds are enforced by the contracts. It is a constraints
> reference, not a description of how governance works.
>
> For the full governance model, lanes, roles, and operational runbooks see
> [`docs/governance/governance.md`](governance/governance.md) and
> [`docs/governance/GOVERNANCE_SURFACE_MAP.md`](governance/GOVERNANCE_SURFACE_MAP.md).

---

## 1. Constraints on existing escrows

These are **absolute**: no governance actor, role, or mechanism can do any of the following
to an escrow that has already been created.

| Prohibited action | Enforcement |
|---|---|
| Change the resolution module address | `snapshotResolutionModule` written once at creation; no setter exists |
| Change the release strategy address | `snapshotReleaseStrategy` written once at creation; no setter exists |
| Change the yield generation module address | `snapshotYieldGenerationModule` written once at creation; no setter exists |
| Change the yield distribution module address | `snapshotYieldDistributionModule` written once at creation; no setter exists |
| Change `autoReleaseTime` or `autoCancelTime` | Written at creation; only the resolution module may alter them as part of dispute resolution |
| Change the dispute resolver address | `disputeResolver` written at creation; no post-creation setter |
| Change yield distribution recipients or percentages | Determined by the snapshotted module; no setter exists |
| Change the escrow fee that was deducted at creation | Fee is collected at creation time; historical escrows are unaffected by fee changes |
| Delete or replace an `EscrowTransfer` struct | `workflowId` is permanent; only state transitions (e.g. `PENDING → RELEASED`) are permitted |
| Override module logic for a specific escrow | `setAuthorizedResolver()` always reverts; per-escrow admin override functions were removed in Phase 5 |

**Summary:** governance changes to default modules or parameters affect only escrows created
*after* the change activates. No function mutates `EscrowTransfer` state for an existing
escrow.

---

## 2. Guardian constraints (down-only)

The Guardian multisig has emergency powers limited strictly to risk *reduction*. It cannot
expand protocol capabilities.

**Guardian can:**
- `pause()` — halt all escrow operations
- `guardianDisableAave()` — disable external yield deposits
- `guardianLowerTokenCap(token, newCap)` — lower a per-token exposure cap (`newCap <= currentCap`)
- `guardianLowerGlobalCap(token, newCap)` — lower the global exposure cap (`newCap <= currentCap`)

**Guardian cannot:**
- `unpause()` — requires Timelock (Standard lane, 48h)
- Resume yield deposits — `resumeYieldDeposits()` is Timelock-only
- Enable Aave after disabling it — Guardian has no enable function
- Raise a cap — both cap-setter functions enforce `newCap <= currentCap`
- Change fees or fee recipient — no Guardian-accessible fee setter exists
- Swap modules — all module swaps require Timelock and Slow lane
- Register escrow contracts with ops contracts — requires Timelock
- Cancel governance actions in the Timelock — `CANCELLER_ROLE` is Governor-only

---

## 3. Timelock / Governor constraints

**TimelockController cannot:**
- Execute emergency-lane functions — those are `onlyRole(ROLE_GUARDIAN)`; the Timelock does not hold `ROLE_GUARDIAN`
- Bypass the 48-hour minimum delay — `TimelockController.minDelay` is a hard lower bound

**Governor cannot:**
- Execute proposals without passing through TimelockController — the Governor is
  `GovernorTimelockControl`; all execution paths go through the Timelock
- Propose with fewer than 10,000,000 SEW (1% of supply) held by the proposer (proposal threshold)
- Execute without reaching quorum (4,000,000 SEW absolute quorum)

**No actor can:**
- Cancel a queued Timelock operation except the Governor — Guardian does not hold `CANCELLER_ROLE`
- Change the DAO address after deployment — `queueDao()` / `activateDao()` were removed; the DAO address is set in the constructor and is immutable

---

## 4. Parameter bounds

Every governance-settable parameter has a hard numerical bound enforced by the contract.
Transactions outside these bounds revert.

### BaseEscrow

| Parameter | Function | Bound |
|---|---|---|
| Default auto-cancel delay | `setDefaultAutoCancelTime` | `0 ≤ value ≤ 30 days` |
| Default auto-release delay | `setDefaultAutoReleaseTime` | `0 ≤ value ≤ 30 days` |
| Auto-cancel and auto-release simultaneously | `setTimeoutConfig` | Both non-zero simultaneously is rejected (`InvalidConfig`) |
| Max attachments per escrow | `setMaxAttachments` | `0 ≤ value ≤ 20` |
| Escrow fee | `queueEscrowFee` | `0 ≤ fee ≤ 200 bps (2%)` |
| Yield protocol fee | `queueYieldProtocolFeeBps` | `0 ≤ fee ≤ 3000 bps (30%)` |
| Appeal bond protocol fee | `queueAppealBondProtocolFeeBps` | `0 ≤ fee ≤ 3000 bps (30%)` |
| Yield distribution recipients | `setDefaultYieldDistribution` | `1–10 recipients; weights must sum to exactly 10,000 bps` |

### AaveYieldModule

| Parameter | Function | Bound |
|---|---|---|
| Per-token exposure cap | `setTokenCap` | `0 ≤ cap ≤ type(uint128).max` |
| Global exposure cap | `setGlobalCap` | `0 ≤ cap ≤ type(uint128).max` |
| Guardian lower-token cap | `guardianLowerTokenCap` | `newCap ≤ currentCap` (strictly down-only) |
| Guardian lower-global cap | `guardianLowerGlobalCap` | `newCap ≤ currentCap` (strictly down-only) |

### DecentralizedResolutionModule

| Parameter | Function | Bound |
|---|---|---|
| Dispute timeout | `setDisputeTimeout` | `0 < timeout ≤ 365 days` |

---

## 5. Minimum delay constraints

No governance change can take effect before its mandatory delay expires. These delays are
enforced by the contracts, not by policy.

| Path | Minimum wall-clock time |
|---|---|
| Any governance action (all lanes) | 48 hours (Timelock `minDelay`) |
| Module swap, fee change, fee recipient change | ~9 days (48h Timelock queue + 7d Slow lane + 48h Timelock activate) |
| Emergency action (Guardian) | 0 hours — but restricted to down-only actions (§2) |
| Unpause after emergency pause | 48 hours minimum (Standard lane) |

The Slow lane's 7-day delay is enforced by `SlowLaneQueueActivate`: `activateX()` reverts
unless `block.timestamp >= eta` where `eta = queueTime + 7 days`. There is no skip or
override path.

---

## 6. Upgrade constraints

| Constraint | Detail |
|---|---|
| Core contracts are not upgradeable via proxy | `BaseEscrow`, `EscrowVault`, `EscrowableERC20` are immutable; no `upgradeTo` function exists |
| Modules are immutable | Upgrades require deploying a new contract and swapping via governance; no in-place upgrade |
| Module swaps affect new escrows only | Activated module defaults do not touch existing `ModuleSnapshot` records |
| No retroactive fee changes | Fee parameters are snapshotted at creation; changing fees affects only future escrows |
| Forward-only | There is no "cancel queued slow-lane change" mechanism; reversing a change costs another full delay cycle (≥ 9 days for slow-lane items) |

---

## 7. Role isolation constraints

| Constraint | Enforcement |
|---|---|
| Guardian cannot execute Timelock actions | Guardian lacks `PROPOSER_ROLE` and `EXECUTOR_ROLE` on TimelockController |
| Timelock cannot execute Guardian actions | TimelockController lacks `ROLE_GUARDIAN` on escrow contracts |
| Fee recipient has no governance authority | `escrowFeeAddress` can only withdraw accrued fees; it holds no access control role |
| `DEFAULT_ADMIN_ROLE` is transferred to Timelock after deployment | No EOA retains admin authority post-deployment |
| Open execution on Timelock | `EXECUTOR_ROLE` is `address(0)` — anyone may execute after the delay, preventing governance deadlock |

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `1c5d47b` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against contract source; governance parameter bounds cross-referenced against `GOVERNANCE_SURFACE_MAP.md` and role constants in `BaseEscrow.sol` / `EscrowAdminContract.sol`. No automated coverage of all constraint paths yet — needs follow-up with formal verification or invariant tests. |

---

## Related documents

- [`docs/governance/governance.md`](governance/governance.md) — full governance model and operational runbooks
- [`docs/governance/GOVERNANCE_SURFACE_MAP.md`](governance/GOVERNANCE_SURFACE_MAP.md) — complete function-by-function mapping with roles, lanes, delays, and bounds
- [`docs/FORWARD_ONLY_UPGRADES.md`](FORWARD_ONLY_UPGRADES.md) — forward-only upgrade mechanism in detail
- [`docs/architecture/PROTOCOL_MODULARITY.md`](architecture/PROTOCOL_MODULARITY.md) — snapshot isolation model
