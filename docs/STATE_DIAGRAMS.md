# Sew Protocol — State Diagrams

> Two Mermaid diagrams derived directly from the contract source.
>
> **Sources:**
> `contracts/types/EscrowTypes.sol` (state enum),
> `contracts/core/BaseEscrow.sol` (transitions and guards),
> `contracts/libraries/StateManagementLibrary.sol`,
> `contracts/ops/DisputeOps.sol`,
> `contracts/ops/SettlementOps.sol`,
> `contracts/modules/decentralized-resolution-module/DecentralizedResolutionModule.sol`,
> `contracts/arbitration/KlerosArbitrableProxy.sol`.
>
> For the full narrative reference see [`docs/STATE_MACHINE.md`](STATE_MACHINE.md) and
> [`docs/dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md`](dispute-resolution/DISPUTE_RESOLUTION_ARCHITECTURE.md).

---

## 1. Core escrow state machine

```mermaid
stateDiagram-v2
    direction TB

    [*] --> PENDING : createEscrow()\n─────────────────\nmoduleSnapshot written\nfees deducted\nautoReleaseTime / autoCancelTime set

    %%─────────────────────────────────────────
    %% PENDING outgoing edges
    %%─────────────────────────────────────────
    PENDING --> RELEASED   : release()\nor automateTimedActions() [autoReleaseTime met]
    PENDING --> REFUNDED   : senderCancel() / recipientCancel()\nor mutual cancel (both agree)\nor automateTimedActions() [autoCancelTime met]
    PENDING --> DISPUTED   : raiseDispute()\n[caller ∈ {sender, recipient}]
    PENDING --> RESOLVED   : acceptSplit()\n[mutual split accepted]

    %%─────────────────────────────────────────
    %% DISPUTED internal loop (escalation / reassignment)
    %%─────────────────────────────────────────
    DISPUTED --> DISPUTED  : escalateDispute() — round++ / new resolver assigned\nor resolver reassignment after timeout

    %%─────────────────────────────────────────
    %% DISPUTED → PendingSettlement sub-state
    %% (escrow stays DISPUTED while window is open)
    %%─────────────────────────────────────────
    state "DISPUTED" as DISPUTED {
        state "Awaiting resolver decision" as AwaitingDecision
        state "PendingSettlement\n(appeal window active)" as PendingSettlement

        AwaitingDecision --> PendingSettlement : releaseAsDisputeResolver()\nor cancelAsDisputeResolver()\n[appeal window > 0]
        PendingSettlement --> AwaitingDecision : escalateDispute()\n[losing party appeals\nbefore appeal deadline]
    }

    %%─────────────────────────────────────────
    %% DISPUTED → terminal (no appeal window)
    %%─────────────────────────────────────────
    DISPUTED --> RELEASED  : releaseAsDisputeResolver() [isFinalRound = true\nor appealWindowDuration = 0]
    DISPUTED --> REFUNDED  : cancelAsDisputeResolver() [isFinalRound = true\nor appealWindowDuration = 0]
    DISPUTED --> REFUNDED  : resolveDisputeByTimeout()\n[maxDisputeDuration exceeded\n& no pending ruling]

    %%─────────────────────────────────────────
    %% PendingSettlement → terminal (appeal window expires)
    %%─────────────────────────────────────────
    DISPUTED --> RELEASED  : executePendingSettlement() / automateTimedActions()\n[block.timestamp ≥ appealDeadline, isRelease = true]
    DISPUTED --> REFUNDED  : executePendingSettlement() / automateTimedActions()\n[block.timestamp ≥ appealDeadline, isRelease = false]

    %%─────────────────────────────────────────
    %% DISPUTED → RESOLVED (mutual split during dispute)
    %%─────────────────────────────────────────
    DISPUTED --> RESOLVED  : acceptSplit()\n[mutual split accepted\nduring dispute]

    %%─────────────────────────────────────────
    %% Terminal states
    %%─────────────────────────────────────────
    RELEASED --> [*]
    REFUNDED --> [*]
    RESOLVED --> [*]

    %%─────────────────────────────────────────
    %% Notes on terminal states
    %%─────────────────────────────────────────
    note right of RELEASED
        Funds credited to recipient.
        withdrawEscrow() required to pull.
        No further transitions possible.
    end note

    note right of REFUNDED
        Funds returned to sender.
        withdrawEscrow() required to pull.
        No further transitions possible.
    end note

    note right of RESOLVED
        Mutual split settlement.
        Both parties receive agreed share.
        Originates from PENDING or DISPUTED.
    end note
```

### Transition authority

| Transition | Who may trigger |
|---|---|
| `NONE → PENDING` | Any address (pays into escrow) |
| `PENDING → RELEASED` | Recipient (via release strategy); or `sender`/`recipient`/`KEEPER`/`TIMELOCK` for timed auto-release |
| `PENDING → REFUNDED` | Sender (unilateral, if strategy permits); Recipient (unilateral); or both consent (mutual cancel); or `sender`/`recipient`/`KEEPER`/`TIMELOCK` for timed auto-cancel |
| `PENDING → DISPUTED` | Sender or recipient only |
| `PENDING/DISPUTED → RESOLVED` | Counterparty to whoever called `proposeSplit()` |
| `DISPUTED → RELEASED/REFUNDED` (immediate) | Authorised resolver (snapshotted at dispute open) |
| `DISPUTED → RELEASED/REFUNDED` (after window) | `sender`/`recipient`/`KEEPER`/`TIMELOCK` |
| `DISPUTED → REFUNDED` (timeout) | `sender`/`recipient`/`KEEPER`/`TIMELOCK` |

**Resolver authority is locked at dispute open.** The resolver recorded in
`et.disputeResolver` at `raiseDispute()` is the only address that may submit a ruling
for that escrow — module or governance changes after that point have no effect.

---

## 2. Dispute escalation and appeals

```mermaid
stateDiagram-v2
    direction TB

    [*] --> DisputeOpen : raiseDispute()\n[escrow enters DISPUTED]\n─────────────────\nEvidence module activated\nIncentive module notified

    %%─────────────────────────────────────────
    %% ROUND 0 — Standard resolver
    %%─────────────────────────────────────────
    DisputeOpen --> R0_Assigned : initializeDispute()\nRound 0 — standard resolver\nweighted round-robin selection\n(filtered by capacity & EMA score)

    R0_Assigned --> R0_Decided : resolver calls\nreleaseAsDisputeResolver()\nor cancelAsDisputeResolver()\n[within accept + resolve deadlines]

    R0_Assigned --> R0_Timeout : deadline missed\n─────────────────\nSlash: 0.25% bond (missed-accept)\nor 2% bond (missed-resolve)
    R0_Timeout --> R0_Assigned : reassignResolver()\n[new resolver from pool]

    %%─────────────────────────────────────────
    %% Round 0 → appeal window
    %%─────────────────────────────────────────
    state "R0_AppealWindow" as R0_AW {
        state "PendingSettlement\nappealDeadline = now + appealWindowDuration" as R0_PS
        [*] --> R0_PS
    }
    R0_Decided --> R0_AW : ruling recorded\nappeal window opens

    R0_AW --> Finalized        : automateTimedActions() / executePendingSettlement()\n[block.timestamp ≥ appealDeadline]\n[no appeal filed]

    R0_AW --> R1_Assigned      : escalateDispute()\n[losing party only, within window]\n[bond posted: escalation cost curve]\n─────────────────\nRound 1 — senior resolver appointed

    %%─────────────────────────────────────────
    %% ROUND 1 — Senior resolver
    %%─────────────────────────────────────────
    R1_Assigned --> R1_Decided : senior resolver\nsubmits ruling

    R1_Assigned --> R1_Timeout : deadline missed\n─────────────────\nSlash: 5% bond (repeat offense)\nSenior resolver frozen
    R1_Timeout --> R1_Assigned : reassignResolver()\n[new senior from pool]

    %%─────────────────────────────────────────
    %% Round 1 → appeal window
    %%─────────────────────────────────────────
    state "R1_AppealWindow" as R1_AW {
        state "PendingSettlement\nappealDeadline = now + appealWindowDuration" as R1_PS
        [*] --> R1_PS
    }
    R1_Decided --> R1_AW : ruling recorded\nappeal window opens

    R1_AW --> Finalized        : executePendingSettlement()\n[no appeal filed]

    R1_AW --> KlerosArbitrableProxy : escalateDispute()\n[losing party only, within window]\n[bond posted: escalation cost curve]\n─────────────────\nRound 2 — Kleros arbitration\nKlerosArbitrableProxy.createDispute()

    %%─────────────────────────────────────────
    %% ROUND 2 — Kleros (terminal round)
    %%─────────────────────────────────────────
    KlerosArbitrableProxy --> KlerosRuling : rule(disputeId, outcome)\n[Kleros arbitrator callback]\n─────────────────\nisFinalRound = true\ncanEscalate() = false

    KlerosRuling --> Finalized : finalizeDispute()\nImmediate settlement\n(no appeal window at round 2)

    %%─────────────────────────────────────────
    %% Dispute timeout backstop (any round)
    %%─────────────────────────────────────────
    DisputeOpen --> Finalized  : resolveDisputeByTimeout()\n[maxDisputeDuration exceeded\n& no pending ruling]\n─────────────────\nOutcome: REFUNDED to sender

    %%─────────────────────────────────────────
    %% Mutual split override (any round)
    %%─────────────────────────────────────────
    DisputeOpen --> Finalized  : acceptSplit()\n[mutual settlement\nduring any dispute round]\n─────────────────\nOutcome: RESOLVED (split)

    %%─────────────────────────────────────────
    %% Finalization
    %%─────────────────────────────────────────
    Finalized --> [*] : → RELEASED  if ruling = release\n→ REFUNDED  if ruling = cancel\n→ RESOLVED  if mutual split\n─────────────────\nAppeal bonds distributed:\nupheld → forfeited to resolver\noverturned → refunded to depositor\nSlashed SEW burned to 0xdEaD
```

### Escalation bond outcomes

When an appeal bond is forfeited or refunded at finalization:

| Outcome | Bond fate |
|---|---|
| Round `n` decision **upheld** (escalation was wrong) | Bond forfeited → distributed to the resolver whose decision was validated at round `n−1` |
| Round `n` decision **overturned** (escalation was correct) | Bond refunded → returned to the depositor |

A `bondRefundedAtRound[n]` flag is stored per dispute for auditability.

### Slashing schedule

| Offense | Slash rate | Epoch cap |
|---|---|---|
| Missed accept | 0.25% of bond | 20% per 7-day epoch |
| Missed resolve (first) | 2% of bond | 20% per 7-day epoch |
| Missed resolve (repeat) | 5% of bond | 10% per 7-day epoch |
| Per-slash absolute maximum | 50% of bond | — |

Slashed SEW is burned. Double-slashing for the same offense is prevented by
`AlreadySlashedForWorkflow` check.

### Escalation cost curve (default: quadratic)

```
cost(k) = baseCost + stepSize × k²
          where k = escalation count (0-indexed)
```

Each successive appeal is more expensive than the last. A party repeatedly
appealing correct decisions will exhaust their bond balance faster than they
can win.

### canEscalate() contract

`KlerosArbitrableProxy.canEscalate()` always returns `(false, _, _)`. Round 2 is
structurally terminal: no further appeal path exists within the protocol.
