# Time Windows in the Sew Protocol

> **Scope:** A complete reference for every time-bounded window in the Sew Protocol:
> appeal windows, resolution deadlines, auto-expiry timers, split proposal expiry,
> rate-limit windows, governance timelock delays, slashing windows, and insurance pool
> delays. For each window this document covers: what it is, where it is set, how long
> it lasts, who it protects, and what happens when it expires.
>
> **Sources:** `contracts/core/BaseEscrow.sol`, `contracts/ops/SettlementOps.sol`,
> `contracts/libraries/SettingsValidationLibrary.sol`,
> `contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol`,
> `contracts/modules/decentralized-resolution-module/DRMStorageBase.sol`,
> `contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol`,
> `contracts/modules/decentralized-resolution-module/ResolverSlashingModuleV1.sol`,
> `contracts/modules/decentralized-resolution-module/InsurancePoolVault.sol`.

---

## Quick Reference

| Window | Default | Configurable | Snapshot-isolated | Protects |
|--------|---------|-------------|-------------------|---------|
| Auto-release | 0 (disabled) | Yes — per-escrow or global default | Yes | Recipient |
| Auto-cancel | 0 (disabled) | Yes — per-escrow or global default | Yes | Sender |
| Dispute timeout (`maxDisputeDuration`) | 0 (disabled) | Yes — global default | Yes | Sender |
| Appeal window — fallback | 0 (disabled) | Yes — global `appealWindowDuration` | Yes | Both parties |
| Appeal window — DRM round 0 | 2 days | Yes — governance (`ROLE_TIMELOCK`) | No (module-level) | Both parties |
| Appeal window — DRM round 1 | 3 days | Yes — governance | No | Both parties |
| DRM resolve deadline — round 0 | 24 hours | Yes — governance | No | Both parties |
| DRM resolve deadline — round 1 | 48 hours | Yes — governance | No | Both parties |
| DRM resolve deadline — round 2 | 7 days | Yes — governance | No | Both parties |
| DRM total dispute timeout | 7 days | Yes — governance (1–365 days) | No | Sender |
| Split proposal expiry | 7 days | Yes — per proposal | No | Counterparty |
| Dispute rate-limit window | 1 day | Fixed | No | Network |
| Escalation reset window | 30 days | Fixed | No | Network |
| Slash appeal window | 3 days | Yes — governance | No | Resolver |
| Slash contest window (timeout) | 24 hours | Fixed | No | Resolver |
| Slash epoch | 7 days | Fixed | No | Protocol |
| Slash period | 30 days | Fixed | No | Protocol |
| Freeze duration | 7 days | Fixed | No | Protocol |
| Circuit breaker cooldown | 1 hour | Fixed | No | Protocol |
| Insurance payout delay | 7 days | Fixed | No | Pool |
| DRM governance timelock | 7 days | Fixed | No | Users |

---

## 1. Auto-Release Window

**What it is:** A timestamp after which the escrow automatically releases funds to
the recipient without requiring explicit consent from the sender.

**Where set:** `et.autoReleaseTime` — written by `_applyEscrowSettings` at escrow
creation.

**How long:** Set by one of two mechanisms:
- **Per-escrow:** Caller provides an explicit `autoReleaseTime` timestamp in
  `EscrowSettings`. Validation: must be in the future and ≤ 1 year from now.
- **Global default:** If both per-escrow times are zero and
  `timeoutConfig.defaultAutoReleaseDelay > 0`, the release time is set to
  `block.timestamp + defaultAutoReleaseDelay`. Maximum: 30 days.

**Snapshot-isolated:** Yes — the effective release time is written to
`et.autoReleaseTime` at creation. Governance changes to `defaultAutoReleaseDelay`
do not affect in-flight escrows.

**Mutual exclusion:** `autoReleaseTime` and `autoCancelTime` cannot both be
non-zero on the same escrow.

**What triggers it:** `automateTimedActions()` checks
`et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime` → transition
`PENDING → RELEASED`.

**Who can trigger it:** `et.from`, `et.to`, `ROLE_KEEPER`, or `ROLE_TIMELOCK`.

**What if it expires and nobody triggers it:** The escrow remains `PENDING`
indefinitely. The window creates an entitlement for the keeper/participant to act;
it does not act automatically without a call.

---

## 2. Auto-Cancel Window

**What it is:** A timestamp after which the escrow automatically refunds funds to
the sender without requiring consent from the recipient.

**Where set:** `et.autoCancelTime` — written by `_applyEscrowSettings` at creation.

**How long:** Same dual mechanism as auto-release:
- Per-escrow explicit timestamp (≤ 1 year from now).
- Global default: `block.timestamp + defaultAutoCancelDelay` (maximum 30 days).

**Snapshot-isolated:** Yes.

**Mutual exclusion:** Cannot coexist with `autoReleaseTime > 0`.

**What triggers it:** `automateTimedActions()` checks
`et.autoCancelTime > 0 && block.timestamp >= et.autoCancelTime` → transition
`PENDING → REFUNDED`.

**Who can trigger it:** Same as auto-release.

**Priority:** Auto-release is checked before auto-cancel in `computeTimedActions`.
If `autoReleaseTime` is also due (which cannot happen due to mutual exclusion), it
would win. In practice this guard is redundant but explicit.

---

## 3. Dispute Timeout (`maxDisputeDuration`)

**What it is:** A maximum permitted duration for an unresolved dispute. If the
resolver fails to submit a ruling within this window, the sender can reclaim their
funds.

**Where set:** `snap.maxDisputeDuration` — snapshotted from
`timeoutConfig.maxDisputeDuration` at escrow creation.

**How long:** No hard upper bound in `TimeoutConfig`; NatSpec intent is 7–365
days. Must be non-zero to be active. Disabled (`disputedTimeoutEnabled = false`)
when set to 0.

**Snapshot-isolated:** Yes.

**Guard:** `resolveDisputeByTimeout` checks:
1. `timeoutPolicy.disputedTimeoutEnabled == true`
2. State is `DISPUTED`
3. No pending resolver ruling (`pendingSettlements[workflowId].exists == false`) — CRIT-3
4. `block.timestamp >= disputeRaisedTimestamp[workflowId] + snap.maxDisputeDuration`

**Outcome on expiry:** `DISPUTED → REFUNDED` (sender receives funds back).

**Who can trigger it:** `et.from`, `et.to`, `ROLE_KEEPER`, or `ROLE_TIMELOCK` via
`resolveDisputeByTimeout()` (also aliased as `autoCancelDisputedEscrow()`).

---

## 4. Appeal Window (Escrow Layer)

**What it is:** A cooling-off period after a resolver submits a ruling during which
the ruling can be challenged via escalation or overridden by a mutual split. The
ruling cannot be executed until this window expires.

**Where set:** Stored in `pendingSettlements[workflowId].appealDeadline`.

**How the deadline is determined:**

```
1. Query resolution module: getAppealDeadlineAndRound(workflowId, escrowAddress)
   → returns (appealDeadline, currentRound, isFinalRound)

2. If isFinalRound = true → no appeal window; execute immediately (shouldExecute = true)

3. If module returns appealDeadline > 0 → use that value

4. If module returns appealDeadline = 0 (but not final round) →
   fallback: appealDeadline = block.timestamp + snap.appealWindowDuration

5. If fallback appealWindowDuration = 0 → execute immediately (shouldExecute = true)
```

**Snapshot-isolated:** Yes — `_executeResolution` uses the snapshotted
`appealWindowDuration` from `moduleSnapshots[workflowId]`, not the live
`timeoutConfig`. (Fixed in audit commit `dfd4e0a`.)

**What can happen during the window:**
- Ruling sits in `pendingSettlements`; escrow remains `DISPUTED`
- `escalateDispute()` → clears the pending ruling, escalates to next level
- `acceptSplit()` → clears the pending ruling, transitions to `RESOLVED`
- After expiry: `executePendingSettlement()` or `automateTimedActions()` executes
  the ruling

**What the window protects:** Both parties' right to challenge a ruling before it
becomes final.

---

## 5. Appeal Windows — Decentralized Resolution Module (DRM)

The DRM maintains its own per-round appeal windows, independent of the escrow
layer fallback. These are the primary source of appeal deadlines when the DRM is
the configured resolution module.

### Round structure

The DRM supports up to `MAX_ROUND = 2` (three rounds: 0, 1, 2).

| Round | Default appeal window | Default resolve deadline |
|-------|-----------------------|--------------------------|
| 0 (initial) | **2 days** | 24 hours |
| 1 (first appeal) | **3 days** | 48 hours |
| 2 (final) | **0** (no appeal window) | 7 days |

Round 2 is the final round (`isFinalRound = true`). Its appeal window is
intentionally 0 — execution is immediate upon ruling.

### How the appeal deadline is set

When a resolver submits a decision, `recordResolution` in the DRM writes:

```solidity
dm.appealDeadline[currentRound] = block.timestamp + appealWindows[currentRound];
```

This deadline is what `getAppealDeadlineAndRound` returns to the escrow layer.

### Configurability

Appeal windows and resolve deadlines are governance-controlled via
`DRMAdminFacet.setRoundConfig(roundResolveDeadlines, roundAppealWindows)`,
callable only by `ROLE_TIMELOCK`. Changes take effect for new disputes but do
not affect disputes already in progress (the deadline is set at ruling time).

**Not snapshot-isolated at the escrow level:** The DRM's `appealWindows` array is
live state in the module. However, once a ruling is recorded and
`dm.appealDeadline[round]` is written, that specific deadline is fixed for that
dispute.

---

## 6. Resolver Resolution Deadline (`resolveBy`)

**What it is:** A deadline by which the assigned resolver must submit a ruling for
the current dispute round. Missed deadlines can trigger slashing.

**Where set:** `dm.resolveBy` in `DisputeMetadata`, written when a resolver is
assigned to a round.

**Defaults:**
| Round | Default |
|-------|---------|
| 0 | 24 hours |
| 1 | 48 hours |
| 2 | 7 days |

**What happens on expiry:** The dispute timeout function in the DRM
(`autoCancelByDisputeTimeout`) becomes callable:

```solidity
if (block.timestamp < dm.resolveBy) revert DisputeNotTimedOut(workflowId, dm.resolveBy);
```

This triggers the DRM-level resolution timeout, which in turn calls back into
`BaseEscrow.resolveDisputeByTimeout`.

**Missed resolve penalty:** `ResolverSlashingModuleV1` tracks missed resolution
deadlines. A `TIMEOUT_RESOLVE` slash is proposed if a resolver fails to submit
within `resolveBy`. The slash is 200 bps (2%) of the resolver's stake by default.

---

## 7. DRM Total Dispute Timeout

**What it is:** A backstop maximum duration for any dispute regardless of round.
If a dispute has been open longer than this, the DRM allows timeout resolution
irrespective of `resolveBy`.

**Where set:** `disputeTimeout` in DRM storage.

**Default:** 7 days.

**Bounds:** 1 second to 365 days (`MAX_DISPUTE_TIMEOUT`), governance-controlled
via `DRMAdminFacet.setDisputeTimeout(t)`.

---

## 8. Split Proposal Expiry

**What it is:** A deadline after which an unaccepted split proposal lapses. An
expired proposal cannot be accepted.

**Where set:** `splitProposals[workflowId].expiry`.

**How long:** The proposer can specify any future timestamp.
Default (if `expiry = 0` is passed): `block.timestamp + 7 days`.

**What happens on expiry:** `acceptSplit` reverts with
`SplitExpired(workflowId, expiry, currentTime)`. The expired proposal is deleted
on the next `proposeSplit` call for the same escrow.

**Not snapshot-isolated:** This is a live negotiation artifact, not a protocol
policy parameter.

**Interaction with appeal window:** A split can supersede a pending resolver ruling
at any time during the appeal window — the split proposal expiry is the only time
guard on this path.

---

## 9. Dispute Rate-Limit Window

**What it is:** A rolling 1-day window used to enforce
`maxDisputesPerSenderPerDay`. Each sender has at most this many disputes per
24-hour period.

**Where set:** `senderDisputeWindowStart[raiser]` — set to `block.timestamp`
when the window resets; `senderDisputeCount[raiser]` tracks count within the
window.

**How long:** 1 day (fixed).

**Reset:** When `block.timestamp >= windowStart + 1 days`, the counter resets to
1 and the window restarts.

**Governance:** `maxDisputesPerSenderPerDay` is set by `ROLE_ADMIN_CONTRACT` via
`setMaxDisputesPerSenderPerDay`. A value of 0 disables the limit.

---

## 10. Escalation Reset Window

**What it is:** A window used to track per-sender escalation count for bond
scaling. If a sender escalates more than once within 30 days, each subsequent
escalation requires a larger bond (10% increase per escalation).

**How long:** 30 days (fixed).

**Reset:** When `block.timestamp >= lastEscalationTimestamp + 30 days`, the
escalation count resets to 1.

**Effect:** `result.bondAmount *= (100 + 10 × (escCount - 1)) / 100`.
A sender who escalates twice in 30 days pays 110% of the base bond on the second
escalation.

---

## 11. Escalation Cooldown

**What it is:** A mandatory waiting period between escalations by the same sender.
Prevents rapid serial escalations.

**Where set:** `escalationCooldown` — governance-controlled
(`ROLE_ADMIN_CONTRACT`).

**Default:** 0 (disabled).

**Effect:** If `block.timestamp < lastEscalationTimestamp + cooldown`, reverts
with `EscalationCooldownActive(sender, availableAt)`.

---

## 12. Slash Appeal Window

**What it is:** A period during which a resolver may appeal a proposed slash
against their stake.

**Where set:** `slashEvent.appealDeadline = block.timestamp + slashConfig.appealWindow`.

**Default:** 3 days.

**Configurable:** Yes — governance via `SlashConfig.appealWindow`.

**What happens in-window:** The resolver calls `appealSlash()` (requires an appeal
bond if `slashConfig.appealBond > 0`). A successful appeal cancels the slash.

**What happens after expiry:** `executeSlash()` becomes callable by
`ROLE_RESOLUTION_MODULE`. The slash is applied to the resolver's stake.

---

## 13. Slash Contest Window (Timeout Resolves)

**What it is:** A shorter window specifically for automated `TIMEOUT_RESOLVE`
slashes. A resolver who missed their `resolveBy` deadline may contest the
automated slash within this window.

**Duration:** 24 hours (fixed constant `TIMEOUT_RESOLVE_CONTEST_WINDOW`).

**Behaviour:** During this window, `executeSlash()` reverts. After expiry,
execution proceeds normally.

---

## 14. Slash Epoch and Slash Period

**Epoch length:** 7 days. Used for per-epoch slash count tracking. If the epoch
has changed since the last slash event, the epoch count resets.

**Slash period:** 30 days. The `MAX_SLASH_PER_PERIOD` cap (100% of stake)
accumulates over this period. Prevents a resolver from being fully slashed multiple
times in a single month.

**Freeze duration:** 7 days. A resolver frozen due to repeated severe events within
an epoch remains frozen for 7 days.

**Circuit breaker cooldown:** 1 hour. After the circuit breaker activates (too many
concurrent slashes), it cannot be deactivated for 1 hour.

---

## 15. Insurance Pool Payout Delay

**What it is:** A mandatory waiting period between a payout proposal and its
execution in the `InsurancePoolVault`. Provides a challenge window for governance
to review large disbursements.

**Duration:** 7 days (`SLOW_DELAY` constant in `InsurancePoolVault`).

**Mechanism:**
1. `proposePayout(recipient, amount)` — records the proposal with
   `eta = block.timestamp + SLOW_DELAY`
2. `executePayout(payoutId)` — callable only after `eta` has passed

**Who controls it:** `ROLE_TIMELOCK` for both propose and execute.

---

## 16. DRM Governance Timelock (Module Configuration)

**What it is:** A mandatory delay before governance changes to DRM escalation
configuration take effect. Prevents immediate reconfiguration of dispute rules
mid-operation.

**Duration:** 7 days (`SLOW_DELAY` in `DRMAdminFacet`).

**Applies to:**
- `queueEscalationConfig` → pending config stored with `eta = now + 7 days`
- Escalation cost configuration changes
- Other queued DRM governance parameters

Changes can be queued but not executed until the timelock expires.

---

## 17. Window Interaction Map

The diagram below shows how windows interact for a fully disputed escrow going
through two rounds of the DRM.

```
t=0     Dispute raised
        │
        ├─► [Resolve deadline R0: 24h]
        │     Resolver submits ruling at some t < t+24h
        │
        ├─► [Appeal window R0: 2 days from ruling]
        │     Either party may escalate or propose split
        │     ─ Escalate → clears pending ruling → assigns R1 resolver
        │
t+24h   ├─► [Resolve deadline R1: 48h from escalation]
        │     R1 resolver submits ruling
        │
        ├─► [Appeal window R1: 3 days from R1 ruling]
        │     Either party may escalate to R2 or propose split
        │     ─ Escalate → clears pending ruling → assigns R2 resolver (FINAL)
        │
t+?     ├─► [Resolve deadline R2: 7 days from escalation]
        │     R2 resolver submits ruling
        │     isFinalRound = true → no appeal window → IMMEDIATE execution
        │
        └─► RELEASED or REFUNDED (true finality)

        Parallel:
        [Dispute timeout: maxDisputeDuration from t=0]
           └─► if no ruling at all → REFUNDED via resolveDisputeByTimeout()
```

---

## 18. Window Bounds Summary

| Window | Min | Max | Source |
|--------|-----|-----|--------|
| `autoReleaseTime` (per-escrow) | Must be future | `now + 365 days` | `SettingsValidationLibrary` |
| `autoCancelTime` (per-escrow) | Must be future | `now + 365 days` | `SettingsValidationLibrary` |
| `defaultAutoReleaseDelay` (global) | 0 (disabled) | 30 days | `SettingsValidationLibrary` |
| `defaultAutoCancelDelay` (global) | 0 (disabled) | 30 days | `SettingsValidationLibrary` |
| `maxDisputeDuration` (global) | 0 (disabled) | No hard cap | `TimeoutConfig` |
| `appealWindowDuration` (global fallback) | 0 (disabled) | No hard cap | `TimeoutConfig` |
| DRM resolve deadline (per round) | 1 second | 365 days | `DRMAdminFacet` |
| DRM appeal window (per round) | 0 | No hard cap | `DRMAdminFacet` |
| DRM total dispute timeout | 1 second | 365 days | `DRMAdminFacet` |
| Split proposal expiry | Must be future | No cap | Per proposal |
| Slash appeal window | No min | No max | `SlashConfig` |

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against `appealWindowDuration`, `maxDisputeDuration`, `defaultAutoReleaseDelay`, and `defaultAutoCancelDelay` parameter handling in `EscrowAdminContract.sol` and `ModuleSnapshotRegistry.sol`. Window enforcement verified against `automateTimedActions()` and `executePendingSettlement()`. Deterministic scenarios cover window boundary conditions. Parameter sweep coverage of edge-case window configurations is partial — needs follow-up. |
