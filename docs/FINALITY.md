# Finality in the Sew Protocol

> **Scope:** This document defines what finality means in the Sew Protocol, how it is
> reached, and — critically — what constitutes *partial finality*: states in which the
> escrow outcome is determined but fund delivery is not yet complete.
>
> **Sources:** `contracts/core/BaseEscrow.sol`, `contracts/libraries/StateManagementLibrary.sol`,
> `contracts/types/EscrowTypes.sol`, `contracts/ops/SettlementOps.sol`.

---

## 1. Definition of Finality

An escrow reaches **finality** when its `EscrowState` transitions to one of the three
terminal states:

| Terminal state | Meaning | Beneficiary |
|---|---|---|
| `RELEASED` | Funds go to recipient (`et.to`) | Recipient |
| `REFUNDED` | Funds return to sender (`et.from`) | Sender |
| `RESOLVED` | Funds split between both parties | Both parties |

Once any terminal state is reached:

- No further transition is possible — the state machine is permanently closed
- No dispute can be raised
- No cancellation, release, or re-resolution can be initiated
- The module snapshot and resolver assignment are no longer operative
- Governance changes have no effect on this escrow

Finality is **outcome finality**: it determines who receives the funds. It does not
mean the funds have been physically transferred. See [Section 3](#3-two-phase-settlement-outcome-vs-delivery)
for the distinction.

---

## 2. Paths to Finality

### 2.1 Uncontested release

`PENDING → RELEASED`

The recipient (or a party authorised by the release strategy) calls `release()`.
The release strategy may enforce conditions (e.g., buyer-only, signature required).
This is the happy path for completed transfers.

### 2.2 Mutual cancellation

`PENDING → REFUNDED`

Both `et.from` and `et.to` call their respective cancel functions
(`senderCancel`, `recipientCancel`). The second confirmation triggers
`_cancelAndRefund`. If the configured cancellation strategy permits unilateral
cancellation, either party may cancel without consent from the other.

### 2.3 Timed auto-release or auto-cancel

`PENDING → RELEASED` or `PENDING → REFUNDED`

If `autoReleaseTime` or `autoCancelTime` is set and the timestamp has passed,
`automateTimedActions()` executes the action without requiring both parties to act.

### 2.4 Resolver ruling (immediate)

`DISPUTED → RELEASED` or `DISPUTED → REFUNDED`

When a resolver calls `releaseAsDisputeResolver` or `cancelAsDisputeResolver` and
the resolution module signals `isFinalRound = true`, execution is immediate.
The escrow transitions to `RELEASED` or `REFUNDED` in the same transaction.

### 2.5 Resolver ruling (after appeal window)

`DISPUTED → RELEASED` or `DISPUTED → REFUNDED`

When the ruling is not a final round, a `PendingSettlement` is recorded and the
escrow remains in `DISPUTED`. After the appeal window (`appealDeadline`) expires,
`executePendingSettlement()` or `automateTimedActions()` executes the ruling.

This path passes through **partial finality** — see [Section 4](#4-partial-finality).

### 2.6 Dispute timeout

`DISPUTED → REFUNDED`

If `maxDisputeDuration` has elapsed and no resolver has submitted a ruling,
`resolveDisputeByTimeout()` cancels the escrow, returning funds to the sender.
Requires `disputedTimeoutEnabled = true` in the timeout policy snapshot.

### 2.7 Mutual split settlement

`PENDING → RESOLVED` or `DISPUTED → RESOLVED`

Either party proposes a split (`proposeSplit`). The counterparty accepts
(`acceptSplit`). Both receive their agreed shares. Available in either `PENDING`
or `DISPUTED`. If a pending resolver ruling exists, the split is blocked until
the ruling is cleared (the appeal period has not yet expired) or the split
supersedes it (the appeal window is used as leverage to negotiate).

---

## 3. Two-Phase Settlement: Outcome vs Delivery

The Sew Protocol separates **outcome determination** from **fund delivery**.
These are distinct events.

### Phase 1 — Outcome determination (state transition)

The escrow state changes to `RELEASED`, `REFUNDED`, or `RESOLVED`.
At this point `_creditClaimable` is called: a `claimableBalances[workflowId][recipient]`
entry is created and `totalClaimableAssets[token]` is incremented.

No tokens move in this phase. The escrow balance accounting is updated
(`escrowBalances[token]` is decremented), but the funds remain in the contract.

### Phase 2 — Fund delivery (withdrawal)

The beneficiary calls `withdrawEscrow(workflowId)` to pull their funds.

```solidity
// withdrawEscrow requires terminal state
if (et.escrowState != EscrowState.RESOLVED &&
    et.escrowState != EscrowState.RELEASED &&
    et.escrowState != EscrowState.REFUNDED) {
    revert TransferNotFinalized(workflowId, et.escrowState);
}
```

Only then are tokens transferred to the beneficiary via `_transferTokens`.

**Why pull-only?** The pull model eliminates reentrancy risk from push-to-many
patterns. In a `RESOLVED` split, both beneficiaries have independent claims — the
seller's failure to withdraw (or a revert on their address) cannot block the
buyer's withdrawal, and vice versa.

---

## 4. Partial Finality

**Partial finality** is the condition in which the outcome of an escrow has been
determined but is not yet irrevocable. The escrow is still in `DISPUTED` but a
decision has been recorded.

This applies specifically to the **appeal window sub-state**.

### 4.1 What creates partial finality

When a resolver submits a ruling (`releaseAsDisputeResolver` or
`cancelAsDisputeResolver`) and the resolution module indicates the round is *not*
final (`isFinalRound = false`):

1. The outcome (`isRelease: true/false`) is recorded in
   `pendingSettlements[workflowId]`
2. An `appealDeadline` timestamp is set (from the module's
   `getAppealDeadlineAndRound`, or the snapshotted `appealWindowDuration` as
   fallback)
3. `EscrowResolved` is emitted (recording the resolver's decision)
4. `PendingSettlementSet` is emitted (recording entry into partial finality)
5. The escrow *remains in* `DISPUTED`

The ruling is **determined** (outcome is known) but **not irrevocable** (appeal
is still possible).

### 4.2 What can happen during partial finality

| Action | Effect |
|--------|--------|
| **Wait for appeal deadline** | After `appealDeadline`, ruling becomes executable |
| `executePendingSettlement()` | Executes the ruling → true finality |
| `automateTimedActions()` | Same as above (timed path) |
| `escalateDispute()` | Cancels the pending ruling; escalates to next level; partial finality resets |
| `acceptSplit()` | Clears the pending ruling; split supersedes resolver decision → RESOLVED |

Notably: during partial finality, the **escrow is still in `DISPUTED`** and the
resolver's decision can still be overturned by escalation or mutual agreement.
Once the appeal window expires and the ruling executes, finality becomes
irrevocable.

### 4.3 Events sequence for partial finality

```
EscrowResolved(workflowId, resolver, resolutionHash)
PendingSettlementSet(workflowId, isRelease, appealDeadline)

  ... [appeal window] ...

PendingSettlementExecuted(workflowId, isRelease)
EscrowStateChanged(workflowId, DISPUTED, RELEASED | REFUNDED)
ClaimableBalanceSet(workflowId, beneficiary, token, amount)
```

If escalation supersedes the ruling:

```
EscrowResolved(workflowId, resolver, resolutionHash)
PendingSettlementSet(workflowId, isRelease, appealDeadline)

PendingSettlementCancelled(workflowId)   ← ruling cleared
DisputeEscalated(workflowId, ...)        ← escalation begins
```

If mutual split supersedes the ruling:

```
PendingSettlementCancelled(workflowId)   ← ruling cleared
SplitAccepted(workflowId, accepter, ...)
EscrowStateChanged(workflowId, DISPUTED, RESOLVED)
```

### 4.4 Partial finality is not visible in EscrowState

A key operational note: there is no `APPEAL_WINDOW` enum value in `EscrowState`.
The partial finality condition is only observable by checking:

```solidity
et.escrowState == EscrowState.DISPUTED &&
pendingSettlements[workflowId].exists == true
```

The `ActionableStatus` enum in `EscrowTypes.sol` provides the wallet-facing
representation:

```solidity
APPEAL_WINDOW   // Resolved, awaiting appeal expiry
APPEAL_READY    // Appeal window met, call executePendingSettlement()
```

These are computed off-chain and are not stored on-chain.

---

## 5. Finality and Yield

When an escrow is financed through a yield module (`v25YieldModules[workflowId]`
is set), finality triggers a yield unwind before crediting claimable balances.

The unwind sequence:

1. `_handleYieldModuleUnwind` calls `IYieldModule.unwindToEscrow`
2. On failure, `emergencyUnwind` is attempted
3. On full recovery, funds are credited including any yield earned
4. On partial recovery, `PartialRecoveryNotAllowed` is reverted — the escrow
   does not settle with partial principal

**Edge case — dual unwind failure:**

If both `unwindToEscrow` and `emergencyUnwind` fail entirely, the protocol does
not freeze the escrow. Instead:

- `YieldUnwindFailed` is emitted
- Settlement proceeds using the original principal
- The claimable entitlement is created for the beneficiary
- The escrow reaches true finality (state transitions to terminal)
- Tokens remain stranded in the yield module; admin recovery is required separately

This means finality is preserved even if yield recovery fails. The beneficiary
can withdraw their principal. Yield tokens require admin recovery via
`GuardianOps.emergencyUnwindAavePosition` or equivalent.

### Yield in split settlements

For `RESOLVED` (split) settlements with yield:

```
yieldToBuyer  = yieldOut × buyerAmount / principal
yieldToSeller = yieldOut - yieldToBuyer
```

Yield is distributed proportionally to the agreed split ratio.

---

## 6. Finality and the Resolution Module

When any terminal transition occurs in a disputed escrow, `_finalizeDisputeInModule`
is called. This:

1. Calls `finalizeDispute(workflowId)` on the resolution module (fire-and-forget;
   failure is ignored — the escrow finalises regardless)
2. Calls the module's resolver capacity decrement (also fire-and-forget), freeing
   the resolver's concurrent-dispute slot

This ensures the resolution module's internal state is cleaned up, but it is not
a dependency for finality. The escrow is final regardless of whether the module
acknowledges it.

---

## 7. Finality and Escalation

Escalation (`escalateDispute`) does **not** produce finality. It:

- Clears any pending ruling (`PendingSettlementCancelled`)
- Assigns a new resolver at the next level
- Keeps the escrow in `DISPUTED`

Escalation resets the dispute to an earlier sub-state (no ruling in flight).
True finality is only reached when the new resolver submits a ruling and the
appeal window expires (or `isFinalRound = true`), or via timeout, or via
mutual split.

---

## 8. Accounting Invariants at Finality

At the moment of state transition to a terminal state, the following invariants hold:

| Invariant | Expression |
|---|---|
| Escrow balance decremented | `escrowBalances[token] -= amountAfterFee` |
| Claimable balance created | `claimableBalances[workflowId][beneficiary] += amount` |
| Global claimable counter updated | `totalClaimableAssets[token] += amount` |
| No token transfer yet | Tokens remain in contract until `withdrawEscrow` |
| Contract balance covers all claimable | `balanceOf(token) >= totalClaimableAssets[token]` |

The last invariant is the core balance safety invariant. `_creditClaimable`
performs an explicit balance check when yield causes `amount > principalExpected`,
ensuring the contract holds what it promises before recording the entitlement.

---

## 9. Summary: Finality Taxonomy

| Condition | EscrowState | `pendingSettlements.exists` | Irrevocable? | Claimable? |
|---|---|---|---|---|
| Active | `PENDING` | — | No | No |
| In dispute, no ruling | `DISPUTED` | `false` | No | No |
| **Partial finality** | `DISPUTED` | `true` | No — appeal possible | No |
| **True finality** | `RELEASED` / `REFUNDED` / `RESOLVED` | `false` | **Yes** | **Yes** |
| Funds withdrawn | `RELEASED` / `REFUNDED` / `RESOLVED` | `false` | Yes | No (claimed) |
