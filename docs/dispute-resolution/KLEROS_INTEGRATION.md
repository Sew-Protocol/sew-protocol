# Kleros Integration

> **Scope:** This document describes how Sew Protocol integrates Kleros as the final
> escalation layer (round 2) of its Decentralized Resolution Module (DRM). It is grounded
> entirely in the deployed contract source. Claims about behaviour are traceable to specific
> functions and line numbers.
>
> **Sources:** `contracts/arbitration/KlerosArbitrableProxy.sol`,
> `contracts/arbitration/IArbitrator.sol`, `contracts/arbitration/IArbitrable.sol`,
> `contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol`,
> `contracts/modules/decentralized-resolution-module/DRMAdminFacet.sol`,
> `contracts/modules/decentralized-resolution-module/DRMStorageBase.sol`,
> `contracts/ops/DisputeOps.sol`, `contracts/core/BaseEscrow.sol`.

---

## 1. Role of Kleros in the Sew Protocol

Kleros serves as the **terminal escalation layer** — round 2 — of Sew's three-round dispute
resolution pipeline. It is not the default resolver; it is reached only after two prior rounds
of appointed professional resolution have been exhausted and at least one party has exercised
their right to escalate.

Kleros's position is structural, not optional: when `externalResolver` is set to a deployed
`KlerosArbitrableProxy`, escalating past round 1 unconditionally routes the dispute to Kleros
decentralised arbitration. Once Kleros issues a ruling, no further escalation is possible.

```
Round 0 (standard resolver)   ← resolveDeadlines[0] = 24h
    │  losing party escalates (+ bond in DR v2)
    ▼
Round 1 (senior resolver)     ← resolveDeadlines[1] = 48h
    │  losing party escalates (+ bond in DR v2)
    ▼
Round 2 (Kleros)              ← resolveDeadlines[2] = 7 days
    │  canEscalate() = false — this is the terminal round
    ▼
  Final ruling propagated to BaseEscrow
```

`MAX_ROUND = 2` is a constant in `DRMStorageBase.sol`. Round indices are 0-based; Kleros is
always at the maximum index.

---

## 2. The `KlerosArbitrableProxy` contract

`contracts/arbitration/KlerosArbitrableProxy.sol` is the adapter between Sew's escrow
infrastructure and the Kleros arbitration protocol. It implements two interfaces simultaneously:

| Interface | Direction | Purpose |
|-----------|-----------|---------|
| `IResolutionModule` | Inbound from BaseEscrow | Allows BaseEscrow to treat Kleros like any other resolution module |
| `IArbitrable` (ERC-792) | Inbound from Kleros | Allows Kleros to deliver rulings by calling `rule()` |

This dual interface means Sew's escrow contracts never need to know they are talking to Kleros
specifically — they interact through the standard `IResolutionModule` interface, and Kleros
interacts through the standard ERC-792 `IArbitrable` interface.

### 2.1 State kept by the proxy

```solidity
// dispute ID translation (add-1 trick to distinguish "no dispute" from ID 0)
mapping(address escrow => mapping(uint256 workflowId => uint256)) workflowToKlerosDispute;
mapping(uint256 klerosDisputeId => uint256) klerosDisputeToWorkflow;
mapping(uint256 klerosDisputeId => address) klerosDisputeToEscrow;

// full dispute record per escrow+workflow
mapping(address escrow => mapping(uint256 workflowId => DisputeMetadata)) disputes;
```

`DisputeMetadata` holds: `arbitrable`, `klerosDisputeId`, `choices`, `extraData`, `resolved`,
`ruling`, `from`, `to`, `amount`.

---

## 3. End-to-end flow: dispute escalated to Kleros

### Step 1 — Escalation eligibility check (DisputeOps)

The losing party calls `BaseEscrow.escalateDispute(workflowId)` (payable). `DisputeOps`
validates:

- The dispute is currently at round 1 (the Kleros-eligible round is `currentLevel + 1 = 2`).
- The caller is the correct losing party (`RELEASE` decision → only sender can appeal; `CANCEL`
  decision → only recipient can appeal).
- `DRM.canEscalate(workflowId, escrow, 1, escrowData)` returns `(true, KlerosProxy, 0)`.
  The DRM returns the `externalResolver` address for round 2; for round 2, `escalationFee`
  from the DRM is always 0 (Kleros fees are paid separately as ETH to the proxy).
- If DR v2 is active: the required appeal bond amount and token are computed and the caller
  must supply the bond.

### Step 2 — Bond handling (DR v2 only)

If `incentiveModule != address(0)` (DR v2), the caller pays an appeal bond before escalation
executes. The bond is recorded in the `IncentiveModule` against the caller at round level 2.
In DR v1 (incentiveModule not set), bonds are not required.

### Step 3 — Module state updated (DRM `executeEscalation`)

`BaseEscrow` calls `DRM.executeEscalation(workflowId, escrow, escrowData)`. Inside the DRM:

```solidity
} else if (toRound == 2) {
    nextRes = externalResolver;   // = KlerosArbitrableProxy address
}
dm.currentRound = 2;
dm.resolverAtRound[2] = nextRes;
dm.resolveBy = block.timestamp + resolveDeadlines[2];  // +7 days
```

`BaseEscrow` then sets `et.disputeResolver = KlerosArbitrableProxy`.

### Step 4 — Kleros dispute creation

With `disputeResolver = KlerosArbitrableProxy` and the escrow contract holding
`ROLE_ESCROW_CONTRACT` on the proxy (granted via `registerEscrowContract`), the escrow calls:

```solidity
KlerosArbitrableProxy.createDispute(
    workflowId,
    escrowContract,
    choices,        // typically 2: release or cancel
    extraData,      // Kleros court + juror count configuration
    escrowData      // encoded (token, from, to, amount, releaseAddress)
)
```

The proxy forwards this to the Kleros `IArbitrator`:

```solidity
uint256 cost = arbitrator.arbitrationCost(extraData);
require(msg.value >= cost, 'Insufficient arbitration fee');
klerosDisputeId = arbitrator.createDispute{value: cost}(choices, extraData);
```

Any excess ETH beyond `arbitrationCost` is refunded to the calling escrow contract immediately.

**Access control note:** `createDispute` is guarded by `ROLE_ESCROW_CONTRACT`. It will revert
for any caller that is not a registered escrow contract. This prevents third parties from
supplying fabricated `escrowData` to corrupt the Kleros evidence record for a real
`workflowId`. End-user dispute initiation routes through `BaseEscrow.raiseDispute`, which
then calls through the resolution module.

### Step 5 — Evidence submission (optional, anytime before ruling)

Any address — sender, recipient, or third party — can call:

```solidity
KlerosArbitrableProxy.submitEvidence(workflowId, escrowContract, evidence)
```

`evidence` is a URI string (typically an IPFS CID pointing to a JSON evidence document).
This emits `EvidenceSubmitted(workflowId, klerosDisputeId, submitter, evidence)` which Kleros
court frontends index to display evidence to jurors. There is no on-chain validation of
evidence content; any well-formed string is accepted.

Submission reverts if:
- No Kleros dispute exists for the `(escrowContract, workflowId)` pair.
- The dispute has already been marked `resolved`.

### Step 6 — Kleros jurors deliberate

Kleros jurors deliberate off-chain using Kleros's court UI. The dispute follows standard
Kleros court mechanics: jurors are drawn proportionally to staked PNK, deliberation and
appeal windows are governed by the Kleros court configuration encoded in `extraData`, and
any Kleros-level appeals (before Kleros delivers a final ruling) are handled entirely within
Kleros's own protocol. Sew has no visibility into intermediate Kleros appeal rounds.

### Step 7 — Ruling delivered (`rule()`)

When Kleros delivers a final ruling, it calls:

```solidity
KlerosArbitrableProxy.rule(uint256 _disputeID, uint256 _ruling)
```

Only the registered `arbitrator` address may call `rule()`. The function:

1. Looks up `klerosDisputeToEscrow[_disputeID]` to find the escrow contract.
2. Looks up `klerosDisputeToWorkflow[_disputeID]` to find the `workflowId`.
3. Sets `dispute.resolved = true` and `dispute.ruling = _ruling`.
4. Emits `Ruling(arbitrator, _disputeID, _ruling)` (ERC-792) and `RulingExecuted(...)`.
5. Calls `_propagateRuling(workflowId, escrowContract, _ruling)` immediately.

### Step 8 — Ruling propagation to BaseEscrow (`_propagateRuling`)

```solidity
function _propagateRuling(uint256 workflowId, address escrowContract, uint256 ruling) internal {
    if (ruling == 0) return;  // Refused to rule — requires manual intervention

    bytes32 resolutionHash = keccak256(abi.encodePacked('KlerosRuling', ruling, block.timestamp));
    if (ruling == 1) {
        try IBaseEscrowSettlement(escrowContract).releaseAsDisputeResolver(workflowId, resolutionHash) ...
    } else if (ruling == 2) {
        try IBaseEscrowSettlement(escrowContract).cancelAsDisputeResolver(workflowId, resolutionHash) ...
    }
}
```

`releaseAsDisputeResolver` or `cancelAsDisputeResolver` on BaseEscrow checks
`_isAuthorizedDisputeResolver` — which calls `IResolutionModule.isAuthorizedDisputeResolver`.
The proxy's implementation of this returns `(true, 2)` for `disputeResolver == address(this)`,
so the settlement is accepted.

The propagation uses a `try/catch`. If settlement reverts (e.g., because the escrow has
already been settled by timeout), the `SettlementPropagated(workflowId, escrow, isRelease, false)`
event is emitted but no error is raised.

---

## 4. Ruling semantics

| `_ruling` | Meaning | Effect |
|-----------|---------|--------|
| `0` | Kleros refused to rule | No automatic settlement. Requires manual intervention or a `resolveDisputeByTimeout` call. |
| `1` | Release to recipient | `releaseAsDisputeResolver` called on escrow. Funds go to `et.to`. |
| `2` | Cancel to sender | `cancelAsDisputeResolver` called on escrow. Funds returned to `et.from`. |

These match the `ResolutionOutcome` enum (`NONE=0, RELEASE=1, CANCEL=2`) used throughout the DRM.

---

## 5. Finality

Kleros is the terminal round. The proxy's `IResolutionModule` implementations explicitly enforce
this:

```solidity
// canEscalate — called before any escalation attempt
function canEscalate(...) external pure override returns (bool, address, uint256) {
    return (false, address(0), 0);  // no further escalation
}

// getAppealDeadlineAndRound — signals final round to callers
function getAppealDeadlineAndRound(...) external pure override
    returns (uint256 appealDeadline, uint8 currentRound, bool isFinalRound)
{
    return (0, 2, true);
}

// executeEscalation — hard revert
function executeEscalation(...) external pure override returns (bool, address, uint8) {
    revert('No escalation from Kleros');
}
```

Once a Kleros ruling is recorded in `DisputeMetadata.resolved = true`, no subsequent call to
`submitEvidence` will be accepted, and no re-escalation is possible.

---

## 6. Propagation liveness fallback

If the automatic propagation in `rule()` fails (for example, if the Kleros arbitrator
implementation calls `rule()` before the escrow contract is ready, or if the first attempt
reverts), anyone can call:

```solidity
KlerosArbitrableProxy.propagateRuling(uint256 workflowId, address escrowContract)
```

This function:
1. If `!dispute.resolved`: checks `arbitrator.disputeStatus(klerosDisputeId)`. If `Solved`,
   reads the ruling from `arbitrator.currentRuling(klerosDisputeId)` and marks the dispute
   resolved locally before propagating.
2. If already `dispute.resolved`: re-propagates the stored ruling.
3. Reverts with `'Not yet resolved by Kleros'` if status is not `Solved`.

This covers the case where Kleros has delivered a ruling but `rule()` has not yet been called
(possible in some non-standard arbitrator implementations).

---

## 7. Access control

| Role | Granted to | Controls |
|------|-----------|----------|
| `DEFAULT_ADMIN_ROLE` | Deployer (transferred to TimelockController post-deployment) | Role management |
| `ROLE_TIMELOCK` | `TimelockController` | `registerEscrowContract`, `updateArbitrator` (if implemented) |
| `ROLE_ESCROW_CONTRACT` | Each registered BaseEscrow contract | `createDispute` |
| *(arbitrator address)* | Kleros `IArbitrator` contract | `rule()` — enforced via `require(_msgSender() == address(arbitrator))` |

No end-user, resolver, or governance actor can call `rule()` — it is strictly gated to the
Kleros arbitrator address set at construction time.

No end-user can call `createDispute` — it is strictly gated to registered escrow contracts.
Anyone can call `submitEvidence` and `propagateRuling`.

---

## 8. Governance: assigning Kleros as the external resolver

Kleros is assigned to round 2 by setting `externalResolver` in the DRM to the
`KlerosArbitrableProxy` address:

```solidity
// DRMAdminFacet.sol
function setExternalResolver(address resolver) external onlyRole(ROLE_TIMELOCK) {
    if (resolver == address(0)) revert ZeroAddress('resolver');
    address old = externalResolver;
    externalResolver = resolver;
    escalationConfig[2].enabled = true;
    escalationConfig[2].resolver = resolver;
    emit ExternalResolverUpdated(old, resolver);
}
```

This function is callable only by `ROLE_TIMELOCK` (the TimelockController, with a 48-hour
minimum delay). Changing `externalResolver` does not go through the 7-day slow lane — it
takes effect immediately after the 48-hour timelock window passes.

The implication: **a change to `externalResolver` affects all new round-2 escalations after
the timelock delay** but does not alter the resolver of any escrow already in round 2.
Escrows in round 2 have their DRM state `dm.resolverAtRound[2]` already set; the global
`externalResolver` variable is only read during `executeEscalation`, before that state is
written.

Additionally, because round-2 assignment is gated by `escalationConfig[2].enabled`:

```solidity
if (toRound > MAX_ROUND || !escalationConfig[toRound].enabled) return (false, ...);
```

Kleros escalation can be disabled by deploying a governance action that calls
`setExternalResolver` to a new address and then re-enables it, or by directly disabling
`escalationConfig[2]` (if such a function is exposed). If `externalResolver` is
`address(0)` or the config is disabled, round-1 escalation attempts to round 2 will fail
with `EscalationNotAllowed`.

---

## 9. Arbitration fee

Kleros charges an arbitration fee in ETH at the time the dispute is created:

```solidity
uint256 cost = arbitrator.arbitrationCost(extraData);
require(msg.value >= cost, 'Insufficient arbitration fee');
klerosDisputeId = arbitrator.createDispute{value: cost}(choices, extraData);
```

`extraData` encodes the Kleros court ID and the minimum number of jurors. `arbitrationCost`
is a view function on the Kleros arbitrator; its value depends on court configuration and
can change between when a party decides to escalate and when the transaction is mined.

Any ETH supplied above `cost` is refunded to the calling escrow contract:

```solidity
if (msg.value > cost) {
    (bool success, ) = payable(_msgSender()).call{value: msg.value - cost}('');
    require(success, 'Refund failed');
}
```

The ETH payment for arbitration is separate from any Sew-protocol appeal bond (DR v2). A
party escalating to round 2 may need to supply both:
- The Sew appeal bond (in the escrow's ERC-20 token, if DR v2 is active).
- The Kleros arbitration fee (in ETH).

In DR v1 (no incentive module), only the Kleros ETH fee is required.

---

## 10. DR version roadmap and Kleros's role in each

The DRM implements a three-phase rollout. Kleros's role at round 2 is present in all three
versions but with increasing economic depth:

| Version | Kleros role | Bond requirement |
|---------|-------------|-----------------|
| **DR v1** — Decentralise decisions | Kleros is the final backstop resolver. No user capital at risk via Sew bonds. | None. ETH arbitration fee to Kleros only. |
| **DR v2** — Decentralise incentives | Kleros remains the final resolver. User appeal bonds introduced at rounds 1 and 2. | Bond required in escrow token before escalating to round 2. |
| **DR v3** — Decentralise capital | Resolver bonds + slashing + senior backing pool added at rounds 0 and 1. Kleros role unchanged. | Round-2 bond + resolver bonds at lower rounds. |

In all versions, Kleros is the authority of last resort. The escalating economic structure
below it (bonds, slashing, insurance) is entirely within Sew's own contracts; Kleros sees
only the binary dispute with two ruling choices.

---

## 11. Timing parameters

| Parameter | Value | Contract |
|-----------|-------|---------|
| `resolveDeadlines[2]` | 7 days | `DecentralizedResolutionModule` constructor |
| `appealWindows[2]` | 0 | No Sew-level appeal window at round 2 — Kleros is final |
| Kleros internal appeal window | Court-configured | Kleros protocol; encoded in `extraData` |
| `DEFAULT_DISPUTE_TIMEOUT` | 7 days | `DRMStorageBase.sol` — liveness fallback for unresolved disputes |

The absence of a Sew-level `appealWindows[2]` means `finalizeDispute` can execute as soon as
Kleros delivers a ruling and the propagation succeeds. There is no additional waiting period
imposed by Sew after the Kleros ruling is received.

---

## 12. Key invariants

These properties are structurally enforced by the contract code:

| Property | How enforced |
|----------|-------------|
| Kleros is the terminal round | `canEscalate()` always returns `(false, address(0), 0)`; `executeEscalation()` always reverts |
| No re-submission of an existing dispute | `require(workflowToKlerosDispute[...][workflowId] == 0, 'Dispute already exists')` |
| Only Kleros arbitrator can deliver rulings | `require(_msgSender() == address(arbitrator))` in `rule()` |
| Only registered escrow contracts can create disputes | `ROLE_ESCROW_CONTRACT` check in `createDispute` |
| Fabricated escrowData is impossible | `escrowData` is supplied only by the calling escrow contract, which holds it for the workflow |
| A resolved dispute cannot receive evidence | `require(!dispute.resolved, 'Dispute already resolved')` in `submitEvidence` |
| Ruling 0 has no automatic effect | `if (ruling == 0) return;` in `_propagateRuling` |
| Excess ETH is refunded on dispute creation | Refund via `call{value: msg.value - cost}` with `require(success)` |

---

## 13. Known limitations and open design questions

**Ruling 0 (refused to rule) has no automated recovery path.** If Kleros declines to rule,
`_propagateRuling` returns immediately without settling the escrow. The escrow will remain
in `DISPUTED` state until `resolveDisputeByTimeout` becomes available (after `maxDisputeDuration`
has elapsed from the dispute open time) or a governance-level manual intervention. This is not
a bug; it reflects that Kleros's "refused to rule" is itself a meaningful signal (undecidable
dispute), but callers should be aware of the liveness implication.

**`externalResolver` change is not slow-laned.** Unlike module swaps (which go through the
7-day `SlowLaneQueueActivate`), `setExternalResolver` in `DRMAdminFacet` is protected only
by the 48-hour timelock. A governance compromise could redirect round-2 escalations to a
malicious resolver within ~48 hours. The `ModuleSnapshot` escrow isolation means only new
round-2 escalations (not existing ones) would be affected.

**`extraData` is caller-supplied.** The court ID and juror count embedded in `extraData` are
set by whoever triggers round-2 escalation. The Sew protocol does not enforce a specific
Kleros court. In production, callers should use a known, audited court configuration.

**Evidence is unvalidated.** `submitEvidence` accepts any string. Off-chain Kleros court UI
renders evidence identified by the URI. Malformed or misleading evidence URIs cannot be
blocked on-chain.

**Kleros-level appeal rounds are opaque to Sew.** While Kleros internally supports multiple
appeal rounds (jury doubling), Sew receives only the terminal Kleros ruling. Intermediate
Kleros appeal dynamics, timing, and costs are not visible to Sew contracts.

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `644c37d` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against `KlerosArbitrableProxy.sol`, `DRMAdminFacet.sol`, `IArbitrator.sol`, and the DR v3 round-2 integration paths in `BaseEscrow.sol`. Kleros `rule()` callback flow and fee handling verified against contract source. Open items: liveness bounds under Kleros congestion not yet simulation-backed; `extraData` court-ID enforcement not yet implemented on-chain (needs follow-up). |
