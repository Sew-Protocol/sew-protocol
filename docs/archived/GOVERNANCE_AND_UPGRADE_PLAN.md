# Governance & Upgrade Plan (March 1 Release → DAO-controlled upgrades later)

**Status**: Ready to execute  
**Goal**: Launch on **March 1** with the **current/simple dispute resolution**, while putting in place a governance + upgrade path so that **the DAO can later approve and activate a new dispute resolution implementation**, and **only new escrows created after activation** use it.

---

## Guiding principles

- **Ship on time**: keep dispute resolution simple at launch.
- **Progressive decentralisation**: start with a Safe (multisig) for operational safety; later migrate authority to Governor+Timelock.
- **Minimize blast radius**: upgrades should impact **new escrows only**, unless explicitly designed otherwise.
- **Tool compatibility**: Snapshot for signalling; OZ Governor + Timelock for binding execution; Safe as guardian/emergency.

---

## What is already implemented in contracts

### 1) Per-escrow resolver “pinning” (critical for safe upgrades)

- Each escrow stores `EscrowTransfer.disputeResolver` at creation time.
- All resolver actions (`resolverRelease`, `resolverCancel`, partials, `resolve`) authorize against that stored address.
- Result: changing a global resolver later **does not affect old escrows**.

### 2) Governance-controlled “resolution module” hook (affects only new escrows)

The escrow core contains a minimal, non-proxy “upgrade hook”:

- `dao`: optional DAO address that can share upgrade authority with owner
- `resolutionModule`: optional module used only for **new escrow creation**
- Two-step activation:
  - `proposeResolutionModule(newModule)`
  - `activateResolutionModule()` after `resolutionModuleDelay`

At escrow creation, if `resolutionModule != address(0)` the contract calls:

- `IResolutionModule(resolutionModule).getResolver(workflowId, escrowData)`

and pins the returned resolver into `EscrowTransfer.disputeResolver`.

**Important**: This is designed so the DAO can switch to a new resolver selection mechanism later **without migrating state** and **without changing the behavior of existing escrows**.

### 3) Default module provided

`DefaultResolutionModule` exists as an Ownable module that returns a stored `resolver` from `getResolver()` (no escalation, matches current “simple” behavior, but in a pluggable form).

---

## Recommended default stack (matches `DAO tooling notes.md`)

- **OpenZeppelin Governor + TimelockController**: binding onchain execution
- **Snapshot**: offchain signalling / temperature checks
- **Safe**: emergency / guardian + operational council
- **Optional Aragon UI later**: purely a UX layer if community wants it

---

## Phase 0 — March 1 Launch Setup (Safe-led governance)

### Objective
Launch with simple resolution, but with upgrade levers already wired so governance can later activate a new dispute system for new escrows.

### Recommended onchain roles (launch)

- **Owner**: Safe (multisig)
- **DAO hook (`dao`)**: either unset (`address(0)`) or set to the same Safe for now

### Required configuration steps (launch checklist)

1. **Set safe ownership**
   - Transfer ownership of deployed escrow contracts to the Safe.

2. **Set the default resolver**
   - Set `authorizedResolver` to the “current/simple” resolver address (EOA or contract).

3. **(Optional) Enable module path immediately**
   - Deploy `DefaultResolutionModule(owner=Safe, resolver=<simple-resolver>)`
   - Call `setResolutionModuleDelay(0)`
   - Call `proposeResolutionModule(moduleAddress)`
   - Call `activateResolutionModule()`

This keeps behavior identical but proves the upgrade pipeline works.

4. **Set emergency policy**
   - Keep `Pausable` powers with the Safe owner (or a dedicated guardian Safe).
   - Document what is considered a “pause-worthy” incident.

### What you can credibly say at launch

- Protocol launches with simple dispute resolution.
- Governance is already wired to approve and activate upgraded dispute resolution for **new escrows only**.
- Emergency controls exist via a named multisig and are intended to be reduced over time.

---

## Phase 1 — Post-launch: Introduce Governor + Timelock (binding execution)

### Objective
Move from Safe-led execution to DAO-led execution for governance actions (module activation, parameter changes), while keeping the Safe as an emergency guardian.

### Deploy

1. **Governance token voting power**
   - ERC20Votes (or your token wrapped into voting power), with delegation.

2. **TimelockController**
   - Set a conservative `minDelay` (e.g. 24–72 hours) depending on your risk tolerance.

3. **Governor**
   - Use OZ Governor modules (e.g. `GovernorVotes`, `GovernorTimelockControl`, quorum, proposal threshold).
   - Use Tally for UI, Snapshot for signalling.

### Wire roles

1. Set escrow `dao` to the **TimelockController address**
   - `setDao(timelockAddress)` (owner-only; execute via Safe)

2. Restrict execution paths
   - Ensure only Timelock can perform “DAO actions” (practically: set `dao = timelock` and transfer ownership to timelock OR keep owner as Safe but only use timelock for DAO actions).

**Recommended long-term**:
- Keep **owner** as Safe (guardian) for pausing only.
- Use **dao** (timelock) for module upgrades and other governance actions.

### “Delay knobs” guidance

You now have:
- Timelock `minDelay`
- `resolutionModuleDelay` inside escrow

Recommendation:
- Use Timelock `minDelay` as the *real* delay.
- Set `resolutionModuleDelay = 0` to avoid double delays and confusion.

---

## Phase 2 — Activating a NEW dispute resolution implementation (for new escrows)

### Objective
DAO approves a new dispute resolution implementation and activates it such that **new escrows pin the new resolver behavior**, while existing escrows remain pinned to their original disputeResolver.

### Pattern (recommended)

1. Deploy **new resolution module** (or a resolver router module)
   - The module chooses which resolver should be pinned per escrow.
   - It can encode complexity (resolver registry, escalation paths, kleros, rollout, etc.) without touching escrow storage.

2. DAO proposal includes:
   - `proposeResolutionModule(newModule)`
   - (optional) wait / timelock delay
   - `activateResolutionModule()`

3. From activation time onward:
   - Escrow creation pins resolver using the new module.
   - Only new escrows use the new dispute resolution system.

### Canary rollout (optional but strongly recommended)

Instead of a hard switch, deploy a “Router module” where `getResolver()` can:
- return v2 resolver only for allowlisted addresses
- and/or return v2 resolver for a percentage of escrows based on deterministic hash of workflowId
- allow per-escrow override for testing

This achieves safe gradual rollout **without upgrading escrow core**.

---

## Snapshot process (signalling) vs Governor process (binding)

### Snapshot (signalling)
Use Snapshot for:
- temperature checks (“should we adopt dispute v2?”)
- parameter selection
- community feedback

### Governor + Timelock (binding)
Use Governor proposals (executed by Timelock) for:
- activating a new resolution module
- changing governance parameters
- changing critical protocol configuration

---

## Safe as emergency guardian

Recommended guardian powers:
- pause/unpause (incident response)
- cancel queued timelock ops (if you grant it the canceller role in timelock)
- execute narrowly-scoped operational actions (documented)

Recommended restrictions:
- guardian should NOT be able to silently change dispute logic for existing escrows
- guardian actions should be publicly announced and logged

---

## Operational checklist

### Pre-March 1
- [ ] Deployed escrow contracts and verified bytecode
- [ ] Ownership transferred to Safe
- [ ] `authorizedResolver` set
- [ ] (Optional) resolution module activated with `DefaultResolutionModule`
- [ ] incident runbook + monitoring

### Post-launch (DAO bootstrap)
- [ ] Deploy governance token voting power (or configure)
- [ ] Deploy TimelockController
- [ ] Deploy Governor and connect to Timelock
- [ ] Set `dao = timelock`
- [ ] Set `resolutionModuleDelay = 0` (prefer timelock delay)
- [ ] Publish governance process docs (Snapshot → Governor proposal → Timelock execution)

### Future dispute upgrade
- [ ] Snapshot signalling vote
- [ ] Security review of new module
- [ ] Governor proposal to propose+activate module
- [ ] Gradual rollout if router module is used

---

## Decision points (confirm before mainnet)

1. **Who is owner at launch?**
   - Recommended: Safe

2. **Do we activate `resolutionModule` at launch?**
   - Recommended: yes, with `DefaultResolutionModule` to validate pipeline (behavior stays the same).

3. **Where is the enforced delay?**
   - Recommended: Timelock `minDelay` (set escrow `resolutionModuleDelay = 0` once timelock is live).



