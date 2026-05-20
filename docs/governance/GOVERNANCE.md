# Protocol Governance

> **Scope:** This document describes the governance architecture of the Sew Protocol: the
> token, voting system, timelock, slow-lane delays, role structure, the governance surfaces
> available to the DAO, the emergency path, and the hard limits on governance power.
>
> **Sources:** `contracts/governance/GovGovernor.sol`,
> `contracts/admin/EscrowGovernanceTimelock.sol`,
> `contracts/governance/SlowLaneQueueActivate.sol`,
> `contracts/governance/EmergencyRecoveryProposal.sol`,
> `contracts/token/SewToken.sol`,
> `contracts/core/BaseEscrow.sol` (role constants, setters),
> `contracts/ops/GuardianOps.sol`,
> `contracts/core/ModuleSnapshotRegistry.sol`.

---

## 1. Overview

Sew Protocol governance operates across three layers of delay:

```
Token holders
    │
    │  vote (≥ proposal threshold to propose; ≥ absolute quorum to pass)
    ▼
GovGovernor (OpenZeppelin Governor)
    │
    │  on-chain vote, configurable voting delay + voting period
    ▼
TimelockController (48-hour minimum execution delay)
    │
    ├─► Direct setters on BaseEscrow (ROLE_TIMELOCK)
    │     ops contract upgrades, bond collector
    │
    └─► EscrowGovernanceTimelock / ModuleSnapshotRegistry  ← the "slow lane"
              │
              │  queue (7-day delay on top of timelock)
              ▼
          activateX()  ─►  BaseEscrow / ModuleSnapshotRegistry setters
                             fees, fee recipient, module defaults, timeout config
```

The minimum elapsed time from a governance proposal to a slow-lane module change taking
effect is approximately:

- Voting delay + voting period (typically 1–2 weeks)
- `+` TimelockController delay (48 hours)
- `+` Slow lane queue delay (7 days)

Any proposed change to a module default, fee, or fee recipient is therefore visible on-chain
for a minimum of 9+ days (plus voting) before it can affect any escrow contract's defaults.
And even after activation, the change only affects **new** escrows — existing escrows are
isolated by the `ModuleSnapshot` mechanism (§6).

---

## 2. The Sew governance token

**Contract:** `SewToken` (`contracts/token/SewToken.sol`)

`SewToken` is an ERC-20 fixed-supply token with the following properties:

| Property | Value |
|----------|-------|
| Standard | ERC-20 + ERC-20Votes + ERC-20Burnable + ERC-20Permit |
| Total supply | Fixed; 1,000,000,000 tokens minted at deployment |
| Minting | No mint function after deployment — supply is permanently fixed |
| Burning | `burn()` / `burnFrom()` available — used for resolver slashing |
| Voting snapshots | ERC-20Votes (`getPastVotes`, `getPastTotalSupply`) — historical state for governance |
| Delegation | Vote power must be delegated (to self or another address) to count toward quorum |
| Ownership | `Ownable2Step` — transferred from deployer → Safe multisig → Timelock during deployment hardening |

The fixed supply and absence of a mint function mean governance cannot inflate the token
supply. Burning is available precisely to support the resolver slashing path (see §5.3).

---

## 3. GovGovernor

**Contract:** `GovGovernor` (`contracts/governance/GovGovernor.sol`)  
**Base:** OpenZeppelin `Governor` + `GovernorSettings` + `GovernorCountingSimple` +
`GovernorVotes` + `GovernorTimelockControl`

### 3.1 Parameters

| Parameter | Launch value | Configurable via governance |
|-----------|-------------|----------------------------|
| Voting delay | 1 block | Yes (`GovernorSettings`) |
| Voting period | ~1 week (in blocks) | Yes (`GovernorSettings`) |
| Proposal threshold | 500,000 tokens (0.05% of supply) | Yes (`GovernorSettings`) |
| Quorum | 4,000,000 tokens (absolute) | Yes (`setAbsoluteQuorum`) |
| Timelock execution delay | 48 hours | Timelock contract |

### 3.2 Absolute quorum

Quorum is expressed as an absolute token count (`absoluteQuorum`) rather than a percentage
of circulating supply. This design choice removes ambiguity about what "circulating supply"
means at launch, where tokens are held in vesting contracts and the treasury.

`absoluteQuorum` can be changed by a governance proposal (executed via timelock); the
`setAbsoluteQuorum` function is only callable by the timelock address.

### 3.3 Non-circulating supply tracking

`GovGovernor` maintains a list of non-circulating addresses (vesting contracts, treasury,
etc.) and exposes `getCirculatingSupply(blockNumber)` for use by external APIs (CoinGecko,
CoinMarketCap). This tracking is informational only — it does not feed into quorum
calculation, which uses the absolute amount. The list is capped at
`MAX_NON_CIRCULATING_ADDRESSES = 100` to prevent DoS, and can only be modified via the
timelock.

### 3.4 Proposal lifecycle

```
propose()          ← requires ≥ proposalThreshold votes delegated to proposer
    │ voting delay elapses
castVote()         ← token holders vote FOR / AGAINST / ABSTAIN
    │ voting period elapses
    │ if FOR votes ≥ absoluteQuorum and FOR > AGAINST
queue()            ← schedules execution in TimelockController
    │ timelock delay elapses (≥ 48 hours)
execute()          ← calls target contracts
```

The proposer or the guardian (see §5) can cancel a pending or active proposal.

---

## 4. TimelockController

The `TimelockController` (OpenZeppelin) is the executor for all governor-approved proposals.
Its `minDelay` is 48 hours. Every setter that governance can invoke must pass through the
timelock — there is no direct governance→contract path that bypasses the delay.

The timelock holds `ROLE_TIMELOCK` on `BaseEscrow` and `EscrowGovernanceTimelock`.
`ROLE_TIMELOCK` gates the most sensitive direct-write operations on these contracts.

---

## 5. Role architecture

All access control in the protocol uses OpenZeppelin `AccessControl`. The three primary
roles on `BaseEscrow` are:

| Role | Held by | What it controls |
|------|---------|-----------------|
| `ROLE_TIMELOCK` | `TimelockController` | Ops contract upgrades (`setCreateOps`, `setSettlementOps`, `setBondCollector`); timed-action authorisation |
| `ROLE_ADMIN_CONTRACT` | `EscrowGovernanceTimelock` | Fee setters, resolution module setter, cancellation strategy setter, timeout config, rate-limit params — all after slow-lane delay |
| `ROLE_GUARDIAN` | Guardian multisig | Emergency Aave position unwind via `GuardianOps` |

In `EscrowGovernanceTimelock` and `ModuleSnapshotRegistry`, `ROLE_TIMELOCK` is held by the
`TimelockController`. In `GovGovernor`, `setAbsoluteQuorum` and the non-circulating address
management functions are restricted to the timelock address.

`ROLE_GUARDIAN` does not extend to protocol parameter changes. It is scoped exclusively to
emergency Aave position unwind and is exercised only when the escrow is paused (see §5.3).

### 5.1 Ops contracts (`ROLE_TIMELOCK`)

`BaseEscrow` delegates compute-intensive operations to external library-style contracts:
`CreateOps`, `SettlementOps`, `DisputeOps`, `YieldOps`, and `BondCollector`. These can be
upgraded via governance. The setters (`setCreateOps`, `setSettlementOps`, etc.) are gated
by `ROLE_TIMELOCK`, meaning they require a full governance vote + 48-hour timelock but do
not additionally require the 7-day slow-lane delay.

### 5.2 DRM admin (`ROLE_TIMELOCK` in DRM)

`DRMAdminFacet` uses its own `ROLE_TIMELOCK` role (held by the same `TimelockController`)
to gate resolver management, escalation configuration, and the DRM admin facet itself.
Most DRM configuration changes go through the 48-hour timelock; escalation config changes
(`queueEscalationConfig` / `activateEscalationConfig`) use an additional queue/activate
pattern within the DRM.

**Known limitation:** `setExternalResolver` in the DRM (which controls the Kleros escalation
target) is protected only by the 48-hour timelock. It does not go through the 7-day slow
lane. This is documented in the Kleros integration notes as an area for improvement in DR
v3.

### 5.3 Guardian role

`ROLE_GUARDIAN` is held by a multisig operated by the Sew team. Its scope is narrow:

- Call `GuardianOps.emergencyUnwindAavePosition()` — unwinds a specific Aave yield position
  back to the escrow contract, with proceeds always going to the escrow (never to the
  guardian).
- Cancel an in-flight governance proposal (jointly with the proposer's cancel right in
  `GovGovernor`).

The guardian **cannot**:

- Change any protocol parameter.
- Modify modules, fees, or resolver assignments.
- Execute unilateral recoveries without a DAO vote (see §7).

The guardian is constrained to unwind Aave positions only when the escrow contract's
records show the caller holds `ROLE_GUARDIAN`, and the operation is rate-limited within
`GuardianOps` to prevent abuse.

---

## 6. The slow lane (`EscrowGovernanceTimelock` + `SlowLaneQueueActivate`)

### 6.1 What the slow lane is

`EscrowGovernanceTimelock` is the intermediary between the `TimelockController` and
`BaseEscrow` for the subset of parameter changes that carry the highest escrow-user risk:
fees, fee recipient, resolution module, and timeout configuration.

`SlowLaneQueueActivate` provides the primitive: a `queue → wait 7 days → activate`
two-step pattern. Any change through this path requires two separate timelock-executed
transactions, separated by at least 7 days.

```
TimelockController
    │  (after 48h governance delay)
    ▼
EscrowGovernanceTimelock.queueX(escrowContract, newValue)
    │  PendingX stored with eta = now + 7 days
    │
    │  ← 7 days pass ─►
    │
TimelockController
    │  (another governance proposal + 48h)
    ▼
EscrowGovernanceTimelock.activateX(escrowContract)
    │  Checks eta passed; calls BaseEscrow setter
    ▼
BaseEscrow.setX(newValue)  ← takes effect for new escrows only
```

### 6.2 Slow-lane surfaces

The following changes require the full slow-lane process:

| Change | Contract | Maximum cap enforced |
|--------|----------|----------------------|
| Fee recipient address | `EscrowGovernanceTimelock` | — |
| Escrow fee (basis points) | `EscrowGovernanceTimelock` | 200 bps (2%) |
| Yield protocol fee (basis points) | `EscrowGovernanceTimelock` | 3,000 bps (30%) |
| Appeal bond protocol fee (basis points) | `EscrowGovernanceTimelock` | 3,000 bps (30%) |
| Default resolution module | `EscrowGovernanceTimelock` + `ModuleSnapshotRegistry` | — |
| Default release strategy | `ModuleSnapshotRegistry` | — |
| Default yield generation module | `ModuleSnapshotRegistry` | — |
| Default yield distribution module | `ModuleSnapshotRegistry` | — |

Fee caps are enforced at both queue time and activate time in `EscrowGovernanceTimelock`.
A governance proposal that attempts to queue a fee above the cap will revert.

### 6.3 Timeout configuration

`setTimeoutConfig` on `BaseEscrow` is gated by `ROLE_ADMIN_CONTRACT` (held by
`EscrowGovernanceTimelock`) and called directly via `EscrowGovernanceTimelock.setTimeoutConfig`
(ROLE_TIMELOCK, no additional slow-lane delay). Bounds are enforced:

| Parameter | Minimum | Maximum |
|-----------|---------|---------|
| `maxDisputeDuration` | 7 days | 365 days |
| `appealWindowDuration` | 1 day | 7 days |

### 6.4 Cancellation strategy

`setDefaultCancellationStrategy` is gated by `ROLE_ADMIN_CONTRACT` and is not subject to
the 7-day slow lane — it can be changed with a single timelock-executed transaction (48h
delay only). This is the only module type that bypasses the slow-lane queue.

---

## 7. Emergency governance path

**Contract:** `EmergencyRecoveryProposal` (`contracts/governance/EmergencyRecoveryProposal.sol`)

When an incident requires action beyond the guardian's narrow authority, the DAO has a
dedicated emergency recovery path:

### 7.1 Flow

```
1. Guardian detects incident; pauses the affected escrow contract
       (BaseEscrow pause mechanics; escrow must be paused before recovery can be proposed)

2. ROLE_PROPOSER (typically timelock) calls proposeRecovery(action, reason)
       - Reverts if escrow is NOT paused (safety check)
       - Creates RecoveryProposal with status PROPOSED

3. DAO votes on the recovery proposal via GovGovernor
       - Normal voting delay + voting period applies

4. On passage, ROLE_EXECUTOR calls approveRecovery(proposalId)
       - Sets status APPROVED, records approvedAt timestamp

5. 2-day mandatory delay elapses (hardcoded in EmergencyRecoveryProposal)

6. ROLE_EXECUTOR calls executeRecovery(proposalId)
       - Reverts if status is not APPROVED
       - Reverts if 2-day delay has not passed
       - Executes the selected RecoveryAction
       - Non-blocking: execution failures set status to FAILED, not the whole contract

7. Guardian or timelock unpauses the escrow contract
```

### 7.2 Recovery action types

| Action | Effect |
|--------|--------|
| `EMERGENCY_UNWIND_AAVE` | Unwind Aave yield positions via `GuardianOps` |
| `WITHDRAW_PAUSED_ESCROWS` | Enable fund withdrawals from paused escrows |
| `RESET_YIELD_MODULES` | Reset yield module state to safe defaults |
| `UPDATE_GUARDIAN_ADDRESS` | Replace the guardian address via DAO vote |

`UPDATE_GUARDIAN_ADDRESS` is the only path to replace the guardian without full contract
redeployment. It requires the full governance vote + 2-day recovery delay — the guardian
cannot appoint its own replacement.

### 7.3 What the emergency path cannot do

The emergency path operates within the same `ROLE_EXECUTOR` authority as normal governance.
It cannot bypass the timelock or override escrow snapshots. Its operations are constrained
to the four predefined `RecoveryAction` types; arbitrary calldata execution is not supported.

---

## 8. What governance can change

Summary of all governable parameters and their protection level:

| Parameter | Protection | Contract | Delay |
|-----------|-----------|---------|-------|
| Voting delay | Governance + timelock | `GovGovernor` (via `GovernorSettings`) | 48h |
| Voting period | Governance + timelock | `GovGovernor` | 48h |
| Proposal threshold | Governance + timelock | `GovGovernor` | 48h |
| Absolute quorum | Governance + timelock | `GovGovernor.setAbsoluteQuorum` | 48h |
| Non-circulating address list | Governance + timelock | `GovGovernor` | 48h |
| Ops contracts (CreateOps, SettlementOps, etc.) | Governance + timelock | `BaseEscrow` | 48h |
| Bond collector | Governance + timelock | `BaseEscrow` | 48h |
| Timeout configuration | Governance + timelock + admin contract | `BaseEscrow` | 48h |
| Rate-limit params (min dispute value, max per day, escalation cooldown) | Governance + timelock + admin contract | `BaseEscrow` | 48h |
| Escrow fee | Governance + timelock + slow lane | `EscrowGovernanceTimelock` | 48h + 7d |
| Yield protocol fee | Governance + timelock + slow lane | `EscrowGovernanceTimelock` | 48h + 7d |
| Appeal bond protocol fee | Governance + timelock + slow lane | `EscrowGovernanceTimelock` | 48h + 7d |
| Fee recipient address | Governance + timelock + slow lane | `EscrowGovernanceTimelock` | 48h + 7d |
| Default resolution module | Governance + timelock + slow lane | `EscrowGovernanceTimelock` + registry | 48h + 7d |
| Default release strategy | Governance + timelock + slow lane | `ModuleSnapshotRegistry` | 48h + 7d |
| Default yield modules | Governance + timelock + slow lane | `ModuleSnapshotRegistry` | 48h + 7d |
| Default cancellation strategy | Governance + timelock + admin contract | `BaseEscrow` | 48h |
| DRM resolver set (add/remove/weight) | Governance + timelock | `DRMAdminFacet` | 48h |
| DRM escalation config | Governance + timelock + DRM queue | `DRMAdminFacet` | 48h + DRM queue |
| DRM external resolver (Kleros target) | Governance + timelock | `DRMAdminFacet` | 48h only |
| Guardian address | Emergency path + 2d delay | `EmergencyRecoveryProposal` | voting + 2d |

---

## 9. What governance cannot change

**Existing escrow terms are immutable.** Once an escrow is created, its `ModuleSnapshot`
is frozen. No governance action can alter the modules, fees, or timing parameters that
apply to an active escrow. This is enforced structurally — the setters on `BaseEscrow`
update live state that is only read during snapshot construction, never after.

**Token supply is fixed.** There is no mint function in `SewToken`. Governance cannot
increase supply.

**Escrow principal cannot be redirected.** No governance path permits diverting an escrow's
principal to a different address than the original sender or recipient. The governance
setters on `BaseEscrow` cover fees, modules, and rate limits — not transfer beneficiaries.

**The timelock delay cannot be reduced to zero.** `TimelockController` enforces a hardcoded
`minDelay`. Reducing this to zero would require deploying a new timelock and re-wiring all
role grants — which itself requires a governance proposal through the existing timelock.

**The slow-lane delay cannot be shortened for a queued change.** `SlowLaneQueueActivate`
computes `eta = block.timestamp + SLOW_DELAY` at queue time. Activating before `eta` reverts
unconditionally. There is no override path.

---

## 10. Governance delay reference

| Action | Minimum time from proposal to effect |
|--------|--------------------------------------|
| Governance parameter change (voting params, quorum) | Voting period + 48h |
| Ops contract upgrade | Voting period + 48h |
| Fee or module default change (slow lane) | Voting period + 48h + 7d |
| Emergency recovery (when paused) | Voting period + 48h + 2d |
| Guardian replacement | Voting period + 48h + 2d |

All delays are enforced on-chain. Governance cannot accelerate them by proposing and voting
faster — the on-chain `eta` check is absolute.

---

## 11. Governance power distribution

The voting weight of each token holder is proportional to their delegated balance of
`SewToken` at the voting snapshot block. A token holder must explicitly delegate (to
themselves or another address) for their balance to count toward quorum.

Addresses on the non-circulating list (vesting, treasury) hold tokens that count toward
total supply but their voting power can only be exercised if the address has delegated. In
practice, locked vesting tokens and treasury tokens are typically not delegated, reducing
effective voting power concentration.

Quorum is absolute (currently 4,000,000 tokens). If total delegated-and-voted supply falls
below this threshold, a proposal fails regardless of how unanimous the votes cast are. This
provides a baseline participation requirement that cannot be satisfied by a small number of
colluding holders alone.
