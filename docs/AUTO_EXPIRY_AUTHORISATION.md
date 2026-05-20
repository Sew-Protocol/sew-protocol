# Auto-Expiry and Timed-Action Authorisation

> **Scope:** This document covers every time-based automated action in the Sew Protocol:
> how expiry timestamps are set, who is permitted to trigger them, how the protocol
> prevents unauthorised or premature execution, and how governance changes to timeout
> parameters are isolated from in-flight escrows.
>
> **Sources:** `contracts/core/BaseEscrow.sol` (`automateTimedActions`,
> `resolveDisputeByTimeout`, `executePendingSettlement`, `_authorizeTimedAction`,
> `_authorizeTimedActionAndSource`, `_applyEscrowSettings`, `_snapshotModulesForEscrow`,
> `setTimeoutConfig`), `contracts/ops/SettlementOps.sol` (`computeTimedActions`,
> `computePendingSettlementExecution`, `computeResolutionExecution`),
> `contracts/libraries/SettingsValidationLibrary.sol`,
> `contracts/types/EscrowTypes.sol` (`TimeoutConfig`, `EscrowSettings`,
> `ModuleSnapshot`, `EscrowTimeoutPolicySnapshot`, `ExecutionSource`, action constants).

---

## 1. Overview

Auto-expiry is the mechanism by which an escrow or dispute can settle automatically
after a defined period has elapsed, without requiring a manual decision from either
party. The protocol supports four time-bounded expiry paths:

| Expiry type | Trigger | Entry function | Outcome |
|-------------|---------|---------------|---------|
| Auto-release | `block.timestamp >= et.autoReleaseTime` | `automateTimedActions` | `PENDING → RELEASED` |
| Auto-cancel | `block.timestamp >= et.autoCancelTime` | `automateTimedActions` | `PENDING → REFUNDED` |
| Appeal window expiry | `block.timestamp >= pending.appealDeadline` | `automateTimedActions` / `executePendingSettlement` | `DISPUTED → RELEASED` or `REFUNDED` |
| Dispute timeout | `block.timestamp >= disputeRaisedTimestamp + maxDisputeDuration` | `resolveDisputeByTimeout` | `DISPUTED → REFUNDED` |

A fifth time-bound object — the **split proposal expiry** — is also tracked, but it
does not trigger an automated action: an expired proposal simply becomes unacceptable
(§8).

All four paths share a common authorisation model (§5) and all read from snapshotted
parameters that were fixed at escrow creation (§3), protecting existing escrows from
governance changes.

---

## 2. Timeout parameters

The four timeout durations are held in a single `TimeoutConfig` struct at the escrow
contract level:

```solidity
struct TimeoutConfig {
    uint256 defaultAutoReleaseDelay; // Seconds until auto-release (0 = disabled)
    uint256 defaultAutoCancelDelay;  // Seconds until auto-cancel  (0 = disabled)
    uint256 maxDisputeDuration;      // Max dispute lifetime       (0 = disabled)
    uint256 appealWindowDuration;    // Seconds for appeal window
}
```

`setTimeoutConfig(TimeoutConfig calldata config)` updates all four fields atomically.
It is gated to `ROLE_ADMIN_CONTRACT` (held by `EscrowGovernanceTimelock`), so any
change requires the full governance pipeline before it takes effect.

**Governance delay:** `ROLE_ADMIN_CONTRACT` operations pass through the 48-hour
`TimelockController`. Changes to `timeoutConfig` therefore have at minimum a 48-hour
visibility window before taking effect on any newly created escrow. Existing escrows
are unaffected — see §3.

---

## 3. Snapshot isolation

At escrow creation, all four timeout values from the live `timeoutConfig` are copied
into the per-escrow `ModuleSnapshot`:

```solidity
moduleSnapshots[workflowId] = ModuleSnapshot({
    ...
    defaultAutoReleaseDelay: timeoutConfig.defaultAutoReleaseDelay,
    defaultAutoCancelDelay:  timeoutConfig.defaultAutoCancelDelay,
    maxDisputeDuration:      timeoutConfig.maxDisputeDuration,
    appealWindowDuration:    timeoutConfig.appealWindowDuration
});
```

Two boolean policy flags are also derived and stored in a separate
`EscrowTimeoutPolicySnapshot`:

```solidity
timeoutPolicySnapshots[workflowId] = EscrowTimeoutPolicySnapshot({
    pendingAutoCancelEnabled: timeoutConfig.defaultAutoCancelDelay > 0,
    disputedTimeoutEnabled:   timeoutConfig.maxDisputeDuration > 0
});
```

From this point, `automateTimedActions` and `resolveDisputeByTimeout` both read
exclusively from these per-escrow snapshots — never from the live `timeoutConfig`:

```solidity
TimeoutConfig memory snappedTimeoutConfig = TimeoutConfig({
    defaultAutoReleaseDelay: snap.defaultAutoReleaseDelay,
    defaultAutoCancelDelay:  snap.defaultAutoCancelDelay,
    maxDisputeDuration:      snap.maxDisputeDuration,
    appealWindowDuration:    snap.appealWindowDuration
});
```

**Consequence:** Governance changes to `timeoutConfig` apply only to escrows created
after the change. They cannot accelerate or suppress the timeout behaviour of any
escrow already in flight.

---

## 4. Auto-time assignment at escrow creation

When an escrow is created, `_applyEscrowSettings` resolves the concrete Unix timestamps
for `autoReleaseTime` and `autoCancelTime` on the `EscrowTransfer` record:

```solidity
bool useDefaults = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);

uint256 relTime = settings.autoReleaseTime;
if (relTime == 0 && useDefaults && timeoutConfig.defaultAutoReleaseDelay > 0) {
    relTime = block.timestamp + timeoutConfig.defaultAutoReleaseDelay;
}
et.autoReleaseTime = uint64(relTime);

uint256 cancTime = settings.autoCancelTime;
if (cancTime == 0 && useDefaults && timeoutConfig.defaultAutoCancelDelay > 0) {
    cancTime = block.timestamp + timeoutConfig.defaultAutoCancelDelay;
}
et.autoCancelTime = uint64(cancTime);
```

**Default application rule:** If the creator provides neither an `autoReleaseTime` nor
an `autoCancelTime`, the contract applies the global defaults
(`defaultAutoReleaseDelay`, `defaultAutoCancelDelay`) as relative delays from
`block.timestamp`. Both are applied in this case. If the creator explicitly sets either
value, the defaults are not applied to either field (`useDefaults = false`).

### 4.1 Per-escrow overrides

The creator may supply custom timestamps in `EscrowSettings`:

```solidity
struct EscrowSettings {
    address customResolver;
    address releaseAddress;
    YieldPreset yieldPreset;
    uint256 autoReleaseTime; // Custom absolute timestamp (0 = use default)
    uint256 autoCancelTime;  // Custom absolute timestamp (0 = use default)
}
```

Custom values override the contract-level defaults entirely for that escrow. They are
validated before being stored (§4.2).

### 4.2 Validation constraints

`SettingsValidationLibrary.validateEscrowSettings` enforces the following rules before
an escrow is created:

**Mutual exclusion:**
```
autoReleaseTime != 0 && autoCancelTime != 0 → revert CannotSetBothAutoTimes
```
A single escrow cannot have both an auto-release and an auto-cancel deadline. Only one
direction of automatic settlement may be configured per escrow. This prevents an
ambiguous outcome (which one fires first?) and eliminates a race condition.

**Future-only:**
```
autoTime > 0 && autoTime <= block.timestamp → revert InvalidAutoTime(AUTO_TIME_IN_PAST)
```
An auto-time set in the past would be immediately triggerable, bypassing the intended
hold period.

**Maximum duration (absolute timestamp path):**
```
autoTime > block.timestamp + 365 days → revert AutoTimeExceedsMaxLimit
```
Per-escrow custom timestamps may not exceed one year from creation.

**Maximum duration (default delay path):**
```
defaultAutoReleaseDelay > 30 days → revert AutoTimeExceedsMaxLimit
defaultAutoCancelDelay  > 30 days → revert AutoTimeExceedsMaxLimit
```
Contract-level default delays are bounded at 30 days
(`SettingsValidationLibrary.MAX_AUTO_TIME_DAYS`). This is a tighter bound than the
one-year per-escrow limit — governance cannot set a 6-month default auto-release as
that would create very long-lived automatic obligations for every new escrow.

**uint64 fit:**
```
autoTime > type(uint64).max → revert InvalidAutoTime(AUTO_TIME_TOO_LARGE)
```
Belt-and-suspenders check that prevents timestamp overflow when stored as `uint64`.

---

## 5. Authorisation model

Every function that executes a timed action calls either `_authorizeTimedAction` or
`_authorizeTimedActionAndSource` before proceeding:

```solidity
function _authorizeTimedActionAndSource(
    EscrowTransfer storage et
) internal view returns (ExecutionSource source, address caller) {
    caller = _msgSender();
    if (caller == et.from || caller == et.to) {
        return (ExecutionSource.USER, caller);
    }
    if (!hasRole(ROLE_TIMELOCK, caller)) revert UnauthorizedTimedExecutor(caller);
    return (ExecutionSource.GOVERNANCE, caller);
}

function _authorizeTimedAction(EscrowTransfer storage et) internal view {
    address caller = _msgSender();
    if (caller == et.from || caller == et.to) return;
    if (!hasRole(ROLE_TIMELOCK, caller)) revert UnauthorizedTimedExecutor(caller);
}
```

Exactly three categories of caller are permitted:

| Caller | `ExecutionSource` | Permitted on |
|--------|------------------|-------------|
| `et.from` (escrow sender/buyer) | `USER` | All timed-action functions |
| `et.to` (escrow recipient/seller) | `USER` | All timed-action functions |
| `ROLE_TIMELOCK` holder | `GOVERNANCE` | All timed-action functions |

Any other address reverts with `UnauthorizedTimedExecutor(caller)`.

**No open-keeper path.** The `ExecutionSource` enum includes a `KEEPER` variant, but
the current authorisation logic does not grant keeper-level access to any external
address. Timed actions can only be triggered by an escrow participant or by the
governance timelock. This is a deliberate choice: a fully open keeper path would allow
any address to force-settle any escrow the moment a deadline passes, which could be
exploited in adversarial front-running scenarios.

**`ROLE_TIMELOCK` as automation agent.** The timelock holder may be configured to
include an automated keeper contract as a role member, subject to the standard
governance pipeline for role grants. This provides the functionality of a keeper
network without exposing it to arbitrary callers at the escrow contract level.

---

## 6. Timed action computation — `computeTimedActions`

`SettlementOps.computeTimedActions` is a pure compute function (no state writes) that
determines which action, if any, should fire for a given escrow at the current
`block.timestamp`. `automateTimedActions` calls it and applies the result.

**Priority order:**

```
1. Appeal window expiry (DISPUTED state)
2. Auto-release (PENDING state)
3. Auto-cancel (PENDING state)
4. None
```

```solidity
// Priority 1: pending settlement expiry
if (pending.exists
        && block.timestamp >= pending.appealDeadline
        && et.escrowState == EscrowState.DISPUTED) {
    return (ACTION_EXECUTE_PENDING, pending.isRelease);
}

// Only PENDING state below
if (et.escrowState != EscrowState.PENDING) return (ACTION_NONE, false);

// Priority 2: auto-release
if (et.autoReleaseTime > 0 && block.timestamp >= et.autoReleaseTime) {
    return (ACTION_AUTO_RELEASE, true);
}

// Priority 3: auto-cancel
if ((pendingAutoCancelEnabled || et.autoCancelTime > 0)
        && et.autoCancelTime > 0
        && block.timestamp >= et.autoCancelTime) {
    return (ACTION_AUTO_CANCEL, false);
}

return (ACTION_NONE, false);
```

**State gating:** Auto-release and auto-cancel are only checked when the escrow is in
`PENDING` state. An escrow that has already moved to `DISPUTED` cannot be auto-released
or auto-cancelled through this path; only the pending settlement or dispute timeout
paths apply.

**`pendingAutoCancelEnabled` flag:** Auto-cancel via `automateTimedActions` is
additionally gated on the snapshotted `pendingAutoCancelEnabled` flag (derived at
creation from `defaultAutoCancelDelay > 0`). If the escrow was created when auto-cancel
was globally disabled, the flag is `false` and the check short-circuits even if
`autoCancelTime` somehow ended up non-zero.

---

## 7. `automateTimedActions` execution flow

```solidity
function automateTimedActions(uint256 workflowId) external nonReentrant returns (bool) {
    _validateWorkflowId(workflowId);
    EscrowTransfer storage et = escrowTransfers[workflowId];
    (ExecutionSource source, address caller) = _authorizeTimedActionAndSource(et);  // auth
    ModuleSnapshot storage snap = moduleSnapshots[workflowId];

    // Build snapshotted timeout config (never reads live timeoutConfig)
    TimeoutConfig memory snappedTimeoutConfig = TimeoutConfig({
        defaultAutoReleaseDelay: snap.defaultAutoReleaseDelay,
        ...
    });

    EscrowTimeoutPolicySnapshot memory timeoutPolicy = timeoutPolicySnapshots[workflowId];
    (uint8 actionType, bool isRelease) = settlementOps.computeTimedActions(
        workflowId, et, pendingMem, snappedTimeoutConfig, timeoutPolicy.pendingAutoCancelEnabled
    );

    if (actionType == ACTION_NONE) return false;

    if (actionType == ACTION_EXECUTE_PENDING) {
        delete pendingSettlements[workflowId];
        _finalizeDisputeInModule(workflowId);
        if (isRelease) _releaseEscrowTransfer(workflowId);
        else           _cancelAndRefund(workflowId);
        emit PendingSettlementExecuted(workflowId, isRelease);
    } else if (actionType == ACTION_AUTO_RELEASE) {
        _releaseEscrowTransfer(workflowId);
    } else if (actionType == ACTION_AUTO_CANCEL) {
        _cancelAndRefund(workflowId);
    }

    emit TimedActionTriggered(workflowId, actionType, source, caller);
    return true;
}
```

`automateTimedActions` returns `false` (no revert) when no action is due. This allows
off-chain callers to poll without worrying about reverting transactions.

---

## 8. Dispute timeout — `resolveDisputeByTimeout`

`resolveDisputeByTimeout` is a specialised timed-action function that refunds the
sender when a dispute has been unresolved for longer than `snap.maxDisputeDuration`.

```solidity
function resolveDisputeByTimeout(uint256 workflowId) public nonReentrant {
    (ExecutionSource source, address caller) = _authorizeTimedActionAndSource(et); // same auth
    ...
    if (!timeoutPolicy.disputedTimeoutEnabled)
        revert ...;                          // disabled at creation
    if (et.escrowState != EscrowState.DISPUTED)
        revert ...;
    if (pendingSettlements[workflowId].exists)
        revert ...;                          // CRIT-3: cannot override a pending ruling
    if (ts == 0 || block.timestamp < ts + snap.maxDisputeDuration)
        revert ...;                          // deadline not yet reached

    _cancelAndRefund(workflowId);
}
```

**CRIT-3 guard.** The check `pendingSettlements[workflowId].exists` prevents the
dispute timeout from overriding a resolver's decision that is already in the appeal
window. If a resolver has already ruled and the decision is pending (waiting for the
appeal deadline to pass), the timeout path is blocked until the pending settlement is
either executed or superseded by an escalation. Without this guard, a slow-acting
keeper could accidentally refund the sender even though a resolver had already decided
to release to the recipient.

**Disabled-by-default.** `disputedTimeoutEnabled` is `false` when
`maxDisputeDuration == 0` at the time the escrow was created. Escrows created before
the governance configured a `maxDisputeDuration` are not subject to dispute timeout.

---

## 9. Appeal window expiry — `executePendingSettlement`

`executePendingSettlement` provides a direct (non-`automateTimedActions`) path for
executing a ruling after its appeal window has expired.

```solidity
function executePendingSettlement(uint256 workflowId) external nonReentrant {
    ...
    _authorizeTimedAction(et); // same auth: et.from, et.to, or ROLE_TIMELOCK

    (bool canExecute, bool isRelease) = settlementOps.computePendingSettlementExecution(
        workflowId, pendingMem, et.escrowState
    );
    if (!canExecute) {
        if (!pending.exists)                       revert NoPendingSettlement(...);
        if (block.timestamp < pending.appealDeadline) revert AppealWindowNotExpired(...);
        revert NotInDisputedState(...);
    }
    delete pendingSettlements[workflowId];
    _finalizeDisputeInModule(workflowId);
    if (isRelease) _releaseEscrowTransfer(workflowId);
    else           _cancelAndRefund(workflowId);
}
```

`computePendingSettlementExecution` requires all three conditions to be true:
1. `pending.exists` — a ruling is actually pending.
2. `block.timestamp >= pending.appealDeadline` — the appeal window has closed.
3. `et.escrowState == EscrowState.DISPUTED` — the escrow has not been escalated or
   otherwise resolved in the interim.

On failure the function reverts with a specific error naming which condition failed,
making it easy for callers to determine whether to retry.

---

## 10. Split proposal expiry

`SplitProposal.expiry` is a time-bound that does not trigger an automated action.
An expired proposal simply cannot be accepted:

```solidity
if (block.timestamp > proposal.expiry)
    revert SplitExpired(workflowId, proposal.expiry, uint64(block.timestamp));
```

Default expiry is 7 days from proposal time if the proposer supplies `expiry == 0`. A
custom expiry must be strictly in the future (`resolvedExpiry > block.timestamp`).
There is no authorisation gate on observing the expiry — it is enforced passively
inside `acceptSplit`. Expired proposals remain in storage until a new proposal is
created (which supersedes the old one) or `cancelSplit` is called.

---

## 11. Auditability — `TimedActionTriggered`

Every successful execution through `automateTimedActions` and `resolveDisputeByTimeout`
emits:

```solidity
event TimedActionTriggered(
    uint256 indexed workflowId,
    uint8 actionType,       // ACTION_AUTO_RELEASE=1, ACTION_AUTO_CANCEL=2, ACTION_EXECUTE_PENDING=3
    ExecutionSource source, // USER or GOVERNANCE
    address caller
);
```

This event records both what happened and who triggered it. The `ExecutionSource`
distinction between `USER` and `GOVERNANCE` allows off-chain tooling to differentiate
participant-initiated settlements from keeper/governance-initiated ones without needing
to inspect the transaction's `msg.sender`.

---

## 12. Parameter bounds summary

| Parameter | Minimum | Maximum | Applies to |
|-----------|--------|--------|-----------|
| `autoReleaseTime` / `autoCancelTime` (per-escrow) | `block.timestamp + 1s` | `block.timestamp + 365 days` | `EscrowSettings` at creation |
| `defaultAutoReleaseDelay` / `defaultAutoCancelDelay` | 0 (disabled) | 30 days | `TimeoutConfig` (governance-set default) |
| `maxDisputeDuration` | 0 (disabled) | no hard cap in `TimeoutConfig`; intent is 7–365 days per NatSpec | Per-escrow snapshot |
| `appealWindowDuration` | 0 | no hard cap in `TimeoutConfig`; intent is 1–7 days per NatSpec | Per-escrow snapshot |
| `SplitProposal.expiry` | `block.timestamp + 1s` | no contract-level cap | Per split proposal |

**Mutual exclusion:** `autoReleaseTime` and `autoCancelTime` cannot both be non-zero
on the same escrow.

**Zero means disabled:** A value of `0` for any timer field means that feature is
inactive for that escrow. No automatic action will ever fire on a `0` timestamp
(`autoReleaseTime == 0` is explicitly skipped in `computeTimedActions`).

---

## 9. Security Audit Findings (May 2026)

A security audit of the auto-expiry and timed-action subsystem was conducted
against commit `a34732a`. Three issues were found and fixed in commit `dfd4e0a`.

---

### Finding 1 — Appeal window not isolated from governance changes (HIGH)

**Location:** `BaseEscrow._executeResolution` / `SettlementOps.computeResolutionExecution`

**Description:**  
`_executeResolution` passed the live `timeoutConfig` storage variable into
`computeResolutionExecution`. The resolution module's `getAppealDeadlineAndRound`
fallback path inside `computeResolutionExecution` uses `timeoutConfig.appealWindowDuration`
when the module returns `appealDeadline == 0`. This means an admin could shorten
or extend the effective appeal window for any in-flight escrow by updating
`appealWindowDuration` after the escrow was created.

**Impact:**  
Retroactive reduction of the appeal window shortens the time a party has to
challenge a resolver ruling — a meaningful trust-model violation. Extension is
less critical but still inconsistent with the snapshot-isolation guarantee.

**Fix:**  
`_executeResolution` now builds a `TimeoutConfig` from `moduleSnapshots[workflowId]`
(the per-escrow snapshot taken at creation) before calling `computeResolutionExecution`,
mirroring the existing pattern in `automateTimedActions`.

---

### Finding 2 — Global defaults could set both auto-release and auto-cancel (MEDIUM)

**Location:** `BaseEscrow.setTimeoutConfig` / `BaseEscrow._applyEscrowSettings`

**Description:**  
`SettingsValidationLibrary.validateEscrowSettings` enforces that a caller cannot
set both `autoReleaseTime` and `autoCancelTime` on the same escrow. However,
`setTimeoutConfig` had no equivalent guard. If an admin set both
`defaultAutoReleaseDelay > 0` and `defaultAutoCancelDelay > 0`, any escrow
created with both per-escrow times as `0` would have both timers populated by
`_applyEscrowSettings` — violating the mutual-exclusion invariant.

**Impact:**  
`computeTimedActions` resolves the conflict by priority (auto-release wins), so
no funds are lost, but the escrow enters a state that the validation layer is
supposed to prevent. It also silently overrides the intended default behaviour.

**Fix:**  
`setTimeoutConfig` now reverts with `InvalidConfig(4, ...)` if both default
delays are non-zero, mirroring the per-escrow mutual-exclusion check.

---

### Finding 3 — No dedicated keeper role; automation required ROLE_TIMELOCK (MEDIUM)

**Location:** `BaseEscrow._authorizeTimedAction` / `BaseEscrow._authorizeTimedActionAndSource`

**Description:**  
Timed actions (auto-release, auto-cancel, appeal window expiry, dispute timeout)
could only be triggered by `et.from`, `et.to`, or an address holding
`ROLE_TIMELOCK`. `ROLE_TIMELOCK` also controls high-privilege ops-rewiring
functions (`setCreateOps`, `setSettlementOps`, `setBondCollector`). The
`ExecutionSource.KEEPER` enum variant existed but was unreachable — there was no
code path that would return it.

**Impact:**  
An automation bot could not trigger timed actions without being granted
`ROLE_TIMELOCK`, which is significantly over-privileged. Granting a keeper bot
timelock privileges would expose protocol ops rewiring to operational key compromise.

**Fix:**  
A dedicated `ROLE_KEEPER` constant (`keccak256('ROLE_KEEPER')`) has been added.
Both `_authorizeTimedAction` and `_authorizeTimedActionAndSource` now check for
`ROLE_KEEPER` (returning `ExecutionSource.KEEPER`) before falling back to
`ROLE_TIMELOCK`. Keepers can trigger expiry actions but cannot call any
`onlyRole(ROLE_TIMELOCK)` governance functions.

---

### Items checked and cleared

| Check | Result |
|-------|--------|
| Outsider bypass of timed-action auth | Not possible — callers not in `{from, to, KEEPER, TIMELOCK}` revert |
| CRIT-3 guard (pending ruling vs dispute timeout) | Present — `resolveDisputeByTimeout` checks `pendingSettlements[workflowId].exists` |
| Auto-release/auto-cancel gating to `PENDING` state | Confirmed — `computeTimedActions` returns `(0, false)` for non-`PENDING` state |
| Zero `maxDisputeDuration` bypass | Safe — `disputedTimeoutEnabled` flag prevents `resolveDisputeByTimeout` when `maxDisputeDuration == 0` |
| `uint64` cast overflow | Checked — `_applyEscrowSettings` reverts with `InvalidAutoTime` if value exceeds `type(uint64).max` |
