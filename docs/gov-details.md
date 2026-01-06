read/review

Approach

Recommend a control model that best matches Ethereum-native expectations and your architecture (swappable modules + new-escrows-only).

Pick the safest default on (a) proxies vs no proxies, and (b) who can cancel timelock ops.

Deliver a ready-to-drop docs/governance.md that encodes your lanes, roles, permissions, and operational runbooks.

Recommendations
1) Proxies: avoid proxies for core; use module swaps + settings; optionally proxy only a single Settings hub

Recommendation: rely purely on module swaps + governed settings for the core path, and keep contracts non-upgradeable wherever possible.

Why this is the best fit for you

You already have modular interfaces and “new escrows only” semantics—this gives you most of the flexibility people use proxies for.

It’s easier to explain and audit: upgrades are “swap module address” (timelocked) rather than “replace arbitrary logic”.

It reduces “soft-rug” optics around token launches.

When a proxy is still reasonable

If you introduce a single EscrowSettings hub and you expect its schema to evolve, you may consider proxying only that hub (and even then, behind timelock + slow-lane). But start non-proxy if you can.

Net: Default = no proxies. Add one later only if you hit a real limitation.

2) Timelock canceller: Governor-only (guardian does not get CANCELLER_ROLE)

Recommendation: keep CANCELLER_ROLE Governor-only.

Why

Giving guardian the ability to cancel queued ops is often interpreted as “guardian can override governance.”

You already have strong emergency tools (pause, disable Aave, lower caps). Cancellation is power over governance intent, not just risk reduction.

If you ever want guardian cancel later

Add it only with strict constraints, e.g. guardian can cancel only ops touching an allowlisted set of selectors (pause/unpause excluded, module swaps, fee address changes, etc.), or require 2-of-2 (guardian + governor) by using a custom cancellation policy. But the clean launch stance is Governor-only.

docs/governance.md
# Governance & Upgrade Policy

This document defines the governance model, upgrade policy, and emergency controls for the protocol.

## Goals

- Ensure protocol changes are **transparent**, **reviewable**, and **delayed**.
- Ensure no admin (including governance) can rewrite the rules of an **in-flight escrow**.
- Preserve agility through **modular, swappable components** while keeping core invariants stable.
- Provide narrowly scoped emergency controls that can only **reduce risk**, not expand it.

---

## Key Guarantees

### New escrows only
Governance changes to defaults/modules apply to **new escrows only**.  
At escrow creation time, module choices are **snapshotted** into escrow state. Existing escrows continue using their original snapped modules/settings.

### No discretionary per-escrow intervention
No governance actor (DAO/timelock/guardian) may arbitrarily change the module selection or rules for a specific escrow after it is created.

### Time-delayed execution
All non-emergency changes execute through an onchain timelock.

---

## Governance Actors

### DAO (Governor)
- Onchain token governance that proposes and votes on protocol changes.
- If a proposal passes, it queues operations into the TimelockController.

### TimelockController
- The *only* executor of Standard and Slow changes.
- Global timelock delay: **48 hours**.

### Guardian Multisig
Emergency-only role with **risk-reduction** powers:
- can pause protocol operations
- can disable external yield deposits (e.g., Aave)
- can lower exposure caps (down-only)

Guardian **cannot**:
- unpause the protocol
- swap modules
- raise caps
- change fees or fee recipient
- cancel governance actions in the timelock

### Fee Recipient
- Can withdraw accrued protocol fees only.
- Has no governance authority.

---

## Governance Lanes

### Standard lane (Timelock: 48 hours)
**Purpose:** bounded parameter changes and operational configuration that cannot change the rules of existing escrows and cannot expand authority beyond predefined limits.

**Delay:** 48 hours (TimelockController)

**Examples:**
- default timeouts within bounds
- max attachments within bounds
- yield distribution defaults (bounded)
- enabling Aave (timelock-only)
- registering supported tokens (bounded)

### Slow lane (Queue + activate: 7 days, timelock-only)
**Purpose:** high-impact changes such as module swaps and fee recipient changes.

**Mechanism:** enforced at the application layer using a two-step pattern:
1) `queueX()` records a pending change with `eta = now + 7 days`
2) after the ETA, `activateX()` applies the change

Both `queueX()` and `activateX()` are timelock-only, meaning governance must:
- pass a proposal to queue (48h delay),
- wait 7 days,
- pass a proposal to activate (48h delay).

> Note: Under a single timelock, Slow lane takes ~9 days wall-clock (48h + 7d + 48h). This is intentional for safety.

### Emergency lane (Guardian: immediate)
**Purpose:** immediate risk reduction.

**Immediate actions:**
- `pause()`
- disable Aave deposits / external yield deposits
- lower exposure caps (down-only)

**Unpause:** timelock-only (Standard lane, 48h)

---

## TimelockController Roles (Hardened Posture)

- `PROPOSER_ROLE` → Governor
- `EXECUTOR_ROLE` → `address(0)` (anyone can execute after delay)
- `CANCELLER_ROLE` → Governor only
- `TIMELOCK_ADMIN_ROLE` → TimelockController itself (self-admin)

---

## Protocol Permissions (High Level)

### Timelock-only (Standard & Slow)
The following categories of changes are timelock-only:
- default parameter changes
- module default changes
- slow-lane queue/activate actions (module swaps, fee recipient, escalation config, etc.)
- unpause()

### Guardian-only (Emergency, down-only)
Guardian can:
- pause
- disable Aave/external yield deposits
- lower exposure caps

Guardian cannot:
- enable Aave
- increase caps
- change fee parameters
- swap modules
- unpause

---

## Slow-Lane Surfaces (7 days)

Slow-lane queue/activate MUST be used for:
- fee recipient changes
- fee bps changes
- default module swaps:
  - release strategy
  - resolution module (in addition to existing propose/activate)
  - yield generation module
  - yield distribution module
- Aave pool provider changes
- DAO address changes (if applicable)
- decentralized escalation configuration changes

Each slow-lane surface emits:
- `XQueued(oldValue, newValue, eta)`
- `XActivated(oldValue, newValue)`

---

## Bounds & Validation

All Standard-lane parameters are bounded onchain in `SettingsValidationLibrary`.

### Recommended bounds (v1)
- Default auto-cancel time: `0 .. 30 days`
- Default auto-release time: `0 .. 30 days`
- Max attachments: `0 .. 20`
- Fee bps: `0 .. 200` (Slow lane)
- Resolution module delay: `48 hours .. 30 days`
- Yield distribution recipients: `1 .. 10`
- Yield distribution sum: must equal `10_000 bps`

### Exposure caps (raw token units)
Exposure caps are stored per-token in smallest units. Deposits into external yield modules must enforce:
`exposure[token] + amount <= cap[token]` (if cap != 0).

Guardian may only lower caps:
- `newCap <= currentCap`

---

## Resolution Routing & Rollout

The protocol supports safe rollouts of new resolution mechanisms without per-escrow admin control.

### ResolutionRouter
- Implements `IResolutionModule`
- Routes deterministically using `hash(escrowId) % 10_000 < rolloutBps`
- `rolloutBps` is governed (timelock-only); guardian may reduce `rolloutBps` (down-only) if needed

### Snapshot rule
At escrow creation, the chosen resolution implementation is snapshotted into escrow state:
- `escrow.resolutionImpl = router.route(escrowId)`

Policy changes affect new escrows only.

---

## Deployment Runbook (Fresh Setup)

1) Deploy `GovToken` (ERC20Votes), mint/distribute, ensure delegation.
2) Deploy `TimelockController(minDelay=48h, proposers=[], executors=[0x0])`.
3) Deploy `Governor` wired to `GovToken` and `TimelockController`.
4) Grant timelock roles:
   - grant `PROPOSER_ROLE` to Governor
   - grant `CANCELLER_ROLE` to Governor
5) Revoke deployer timelock admin rights; ensure timelock is self-admin.
6) Transfer protocol authority to timelock:
   - `transferOwnership(timelock)` for Ownable contracts, OR
   - grant `ROLE_TIMELOCK` to timelock and remove deployer roles for AccessControl.
7) Grant guardian emergency role to multisig across governed modules/contracts.
8) Disable/remove any per-escrow override admin surfaces for mainnet.

---

## Operational Practices

- Publish proposals and queued operations in a public forum with:
  - rationale
  - diff summary
  - security considerations
  - links to audits/tests
- Treat Slow lane changes as “release events”:
  - storage and migration notes (if any)
  - staging/testnet rehearsal
  - clearly communicated ETA

---

## Security Notes

- Emergency controls are intentionally one-way until timelock unpauses.
- Guardian powers are restricted to risk reduction; they do not override governance intent.
- External integrations (e.g., Aave) must be protectable via caps and disable switches.

---

## Change Log
- Maintain a changelog of governance policy changes and parameter updates.

Assumptions

You’re comfortable with slow-lane being a two-step queue/activate mechanism under a single 48h timelock (safer, albeit slower).

You will remove or disable per-escrow override setters (15–18) for mainnet to preserve the “no discretionary intervention” guarantee.

Your escrow creation flow can snapshot module implementations (or be refactored to do so).

Next steps

I can generate a Hardhat deploy script outline (hardhat-deploy style) for GovToken + Governor + Timelock + role grants + ownership transfers.

I can produce a per-file patch checklist (BaseEscrow, EscrowableERC20, AaveYieldGenerationModule, Resolution modules) mapping each function to ROLE_TIMELOCK / ROLE_GUARDIAN plus queue/activate additions.

I can draft a Foundry test matrix for: timelock execution paths, slow-lane ETA enforcement, guardian down-only constraints, and new-escrows-only snapshot behavior.

What I need from you

Do you want EXECUTOR_ROLE to be open (address(0)) or restricted to a specific executor bot/multisig?

Do you want ResolutionRouter.rolloutBps changes to be Standard (48h, bounded) or Slow (queue/activate 7d)?

Suggested next step

Tell me “executor open/restricted” and “rollout Standard/Slow,” and I’ll output the deploy-script plan + exact per-contract patch list.
