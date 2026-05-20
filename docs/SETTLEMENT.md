# Settlement

> **Scope:** This document describes every settlement path available in the Sew Protocol
> escrow system: voluntary release, cancellation, mutual split, dispute resolution,
> appeal-window enforcement, timed automation, and dispute timeout. It also covers the
> pull-only fund delivery model, yield unwind mechanics, and the `SettlementOps`
> compute/apply separation pattern.
>
> **Sources:** `contracts/core/BaseEscrow.sol` (`release`, `recipientCancel`, `senderCancel`,
> `proposeSplit`, `acceptSplit`, `releaseAsDisputeResolver`, `cancelAsDisputeResolver`,
> `executePendingSettlement`, `automateTimedActions`, `resolveDisputeByTimeout`,
> `_releaseEscrowTransfer`, `_cancelAndRefund`, `_finalizeClaimableSettlement`,
> `_creditClaimable`, `_handleYieldModuleUnwind`),
> `contracts/ops/SettlementOps.sol`,
> `contracts/ops/YieldOps.sol`,
> `contracts/types/EscrowTypes.sol` (`EscrowState`, `PendingSettlement`, `SplitProposal`),
> `contracts/types/YieldPresets.sol`.

---

## 1. Overview

Settlement is the act of closing an escrow and making funds claimable by the appropriate
party. Every settlement path ends in one of three terminal states:

| State | Funds go to | Transition from |
|-------|------------|----------------|
| `RELEASED` | Recipient (`et.to`) | `PENDING` |
| `REFUNDED` | Sender (`et.from`) | `PENDING` or `DISPUTED` |
| `RESOLVED` | Split between both parties | `PENDING` or `DISPUTED` |

`RELEASED`, `REFUNDED`, and `RESOLVED` are terminal: no further state transitions are
possible. All fund delivery is **pull-only** — settlement credits a claimable ledger rather
than pushing tokens. The beneficiary must call `claimFunds(workflowId)` to receive their
tokens.

---

## 2. State machine

```
NONE
  │
  │  createEscrow()
  ▼
PENDING ─────────────────────────────────────────────────────────────────────┐
  │                                                                          │
  │  release()                    → RELEASED                                │
  │  recipientCancel() / senderCancel()  → REFUNDED                         │
  │  proposeSplit() + acceptSplit()      → RESOLVED                         │
  │  automateTimedActions() [auto-release] → RELEASED                       │
  │  automateTimedActions() [auto-cancel]  → REFUNDED                       │
  │                                                                          │
  │  raiseDispute()                                                          │
  ▼                                                                          │
DISPUTED                                                                     │
  │                                                                          │
  │  releaseAsDisputeResolver() [final round]    → RELEASED (immediate)     │
  │  cancelAsDisputeResolver()  [final round]    → REFUNDED (immediate)     │
  │                                                                          │
  │  releaseAsDisputeResolver() [non-final round]                            │
  │  cancelAsDisputeResolver()  [non-final round]                            │
  │          → PendingSettlement set (appeal window active)                  │
  │                                                                          │
  │  executePendingSettlement() [after appeal window expires]                │
  │  automateTimedActions()     [after appeal window expires]                │
  │          → RELEASED or REFUNDED                                          │
  │                                                                          │
  │  proposeSplit() + acceptSplit()  → RESOLVED                              │
  │  resolveDisputeByTimeout()       → REFUNDED (after maxDisputeDuration)   │
  └─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Settlement paths

### 3.1 Voluntary release — `PENDING → RELEASED`

```
Caller: et.from (buyer/sender), or a delegated releaseAddress
Function: release(workflowId)
```

1. Verifies escrow is in `PENDING` state.
2. Encodes `escrowData` in canonical format (`abi.encode(token, from, to, amountAfterFee, releaseAddress)`).
3. Calls `IReleaseStrategy.canRelease(workflowId, escrow, caller, escrowData)` from the
   snapshot.
4. If allowed, calls `_releaseEscrowTransfer(workflowId)`.

If the release strategy address is zero (not configured), the call reverts with
`ReleaseStrategyNotSet` — it does not silently bypass the policy.

**Why the release strategy is consulted:** `release()` is callable even when the contract
is paused (for user-initiated releases), so the strategy is the gating mechanism rather
than a simple access check.

---

### 3.2 Cancellation — `PENDING → REFUNDED`

```
Callers: et.to (recipientCancel) or et.from (senderCancel)
Functions: recipientCancel(workflowId), senderCancel(workflowId)
```

Both functions follow the same flow:

1. Verify the caller is the correct party and the escrow is `PENDING`.
2. If a cancellation strategy is configured (from the snapshot), call:
   - `canCancel(workflowId, caller, et)` — reverts with `NotAuthorizedToCancelYet` if false.
   - `canCancelUnilaterally(workflowId, caller, et)` — if true, cancel immediately.
   - `onCancelAttempt(workflowId, caller, true)` — notification hook.
3. If the strategy does not permit unilateral cancellation, set the caller's status flag
   (`SenderStatus.AGREE_TO_CANCEL` or `RecipientStatus.AGREE_TO_CANCEL`). If both parties
   have consented, `_cancelAndRefund` executes.

**Mutual consent path:** Both parties must call their respective cancel function within the
same escrow lifetime. There is no expiry on pending consent; once both flags are set,
cancellation executes on the second call.

---

### 3.3 Mutual split settlement — `PENDING` or `DISPUTED → RESOLVED`

```
Functions: proposeSplit(workflowId, buyerAmount, sellerAmount, expiry)
           acceptSplit(workflowId)
           cancelSplit(workflowId)
```

A split allows the two parties to agree on a custom division of the escrow principal rather
than a binary release/refund. It is available from both `PENDING` and `DISPUTED` states.

**Proposing a split:**

- Either party (`et.from` or `et.to`) may propose.
- `buyerAmount + sellerAmount` must equal `et.amountAfterFee` exactly (no rounding, no
  partial).
- A new proposal supersedes any existing one for the same escrow.
- Default expiry: 7 days from proposal time. Custom expiry must be in the future.
- **Blocked** if a `PendingSettlement` already exists (i.e., a resolver has already
  decided and the appeal window is active). This prevents the split from interfering with
  an in-progress appeal.

**Accepting a split:**

- Only the counterparty (the non-proposer participant) may accept.
- Must be called before the proposal expiry.
- If the escrow is `DISPUTED`, the active dispute is closed by mutual agreement before
  settlement (`_closeDisputeByMutualAgreement`).
- State transitions to `RESOLVED`.
- Principal is split per the agreed amounts. Yield (if any) is split proportionally:
  `yieldToBuyer = yieldOut × buyerAmount / principal`.
- Both amounts are credited as claimable (pull-only).
- CEI ordering: the proposal is deleted before any state changes.

**Cancelling a split:**

- Only the proposer or the guardian (`ROLE_GUARDIAN`) may cancel an active proposal.

---

### 3.4 Dispute resolution — `DISPUTED → RELEASED/REFUNDED` or `PendingSettlement`

```
Callers: Authorized dispute resolver (per-escrow or module)
Functions: releaseAsDisputeResolver(workflowId, resolutionHash)
           cancelAsDisputeResolver(workflowId, resolutionHash)
```

Both functions call `_executeResolution(workflowId, isRelease, resolutionHash)`:

1. Verifies caller is authorized: checks per-escrow `customResolver` first; if not set,
   calls `IResolutionModule.isAuthorizedDisputeResolver` / `getDisputeResolver`.
2. Verifies escrow is `DISPUTED`.
3. Records the resolution outcome in the resolution module.
4. Calls `SettlementOps.computeResolutionExecution(resolutionModule, workflowId, isRelease, timeoutConfig)` to get:
   - `shouldExecute` — true if this is the final round (no appeal window).
   - `appealDeadline` — the timestamp after which the decision becomes final.
   - `isFinalRound` — whether the module considers this the last possible appeal.

**If `shouldExecute` is true (final round):**  
Execute immediately (`_releaseEscrowTransfer` or `_cancelAndRefund`). No appeal window.

**If `shouldExecute` is false (non-final round):**  
Store a `PendingSettlement{ exists: true, isRelease, appealDeadline, resolutionHash }`.
The decision is *pending*, not executed. Emit `PendingSettlementSet`.

The `resolutionHash` provides an on-chain fingerprint of the resolution decision data,
enabling off-chain verification of what was decided and when.

---

### 3.5 Appeal window enforcement — `DISPUTED → RELEASED/REFUNDED`

```
Functions: executePendingSettlement(workflowId)
           automateTimedActions(workflowId)
```

When a non-final round decision is recorded, it enters the `PendingSettlement` state. The
decision becomes executable only after `pending.appealDeadline` has passed and the escrow
is still `DISPUTED` (i.e., not yet escalated).

`executePendingSettlement`:

1. Calls `SettlementOps.computePendingSettlementExecution(workflowId, pending, escrowState)`.
2. Reverts if: no pending settlement exists, appeal window has not expired, or escrow is
   no longer `DISPUTED`.
3. On success: deletes `pendingSettlements[workflowId]`, calls `finalizeDispute` on the
   resolution module, then executes `_releaseEscrowTransfer` or `_cancelAndRefund`.

`automateTimedActions` also handles pending settlement execution: it computes the action
type via `SettlementOps.computeTimedActions` and calls the same finalisation path.

**Who can trigger execution:** Any of the following — `et.from`, `et.to`, or a
`ROLE_TIMELOCK` caller (keeper/governance). This is enforced by `_authorizeTimedAction`.

---

### 3.6 Timed automation — auto-release and auto-cancel

```
Function: automateTimedActions(workflowId)
```

`automateTimedActions` handles three automated settlement scenarios:

| Action | Trigger | State requirement | Result |
|--------|---------|------------------|--------|
| Auto-release | `block.timestamp >= et.autoReleaseTime` | `PENDING` | `RELEASED` |
| Auto-cancel | `block.timestamp >= et.autoCancelTime` | `PENDING` | `REFUNDED` |
| Pending settlement | `block.timestamp >= pending.appealDeadline` | `DISPUTED` | `RELEASED` or `REFUNDED` |

Timing parameters (`autoReleaseTime`, `autoCancelTime`) are determined at escrow creation
from either the per-escrow `EscrowSettings` override or the contract-level defaults from
the `ModuleSnapshot`. Because they are snapshotted, governance cannot change them for
existing escrows.

The function reads `snappedTimeoutConfig` from the snapshot (not live state) to maintain
isolation:

```solidity
TimeoutConfig memory snappedTimeoutConfig = TimeoutConfig({
    defaultAutoReleaseDelay: snap.defaultAutoReleaseDelay,
    ...
});
```

---

### 3.7 Dispute timeout — `DISPUTED → REFUNDED`

```
Functions: resolveDisputeByTimeout(workflowId)
           autoCancelDisputedEscrow(workflowId)  ← alias
```

If a dispute remains unresolved for longer than `snap.maxDisputeDuration` (snapshotted at
creation), any party or keeper may call `resolveDisputeByTimeout` to force-close it as a
refund.

Pre-conditions enforced:

- `timeoutPolicy.disputedTimeoutEnabled` must be true (from the timeout policy snapshot).
- Escrow must be `DISPUTED`.
- **No** `PendingSettlement` may exist — a resolver's pending decision cannot be overridden
  by the timeout path (CRIT-3 safety check).
- `block.timestamp >= disputeRaisedTimestamp[workflowId] + snap.maxDisputeDuration`.

On success: `_cancelAndRefund(workflowId)` executes, refunding the sender. Emits
`DisputeAutoCancelled` with `FailureReason.TIMEOUT`.

---

## 4. Pull-only fund delivery

**All settlement is pull-only.** No settlement path sends tokens directly to the
beneficiary. Instead, all paths call `_creditClaimable(workflowId, recipient, token, amount, principal)`,
which increments `claimableBalances[workflowId][recipient]`.

The beneficiary calls `claimFunds(workflowId)` to pull their credited balance:

```solidity
uint256 amount = claimableBalances[workflowId][_msgSender()];
// zero-then-transfer (CEI pattern)
claimableBalances[workflowId][_msgSender()] = 0;
IERC20(token).safeTransfer(_msgSender(), amount);
```

**Why pull-only?**

- Eliminates re-entrancy risk on the settlement path — no outbound transfer during state
  transition.
- Allows settlement to succeed even if the recipient's address cannot receive tokens
  directly (e.g., a contract without a fallback).
- Separates the state transition (atomic, permissioned) from the fund transfer
  (user-initiated, replayable on failure).
- Protocol fee credits and excess ETH refunds use the same pattern
  (`claimBondProtocolFees`, `claimExcessEthRefund`).

---

## 5. Yield unwind on settlement

Whenever any settlement path reaches `_finalizeClaimableSettlement` or
`_releaseEscrowTransfer`, it calls `_handleYieldModuleUnwind(workflowId, token, amount)`.

**Yield unwind flow:**

1. If `snap.yieldGenerationModule` is set, call
   `YieldOps.handleYield(genModule, ..., workflowId, token, amount, ...)`.
2. `YieldOps.handleYield` calls `IYieldGenerationModule.withdrawWithYield(workflowId, token, amount, escrow)`.
3. The module returns `(success, actualAmountWithdrawn, yieldGenerated)`.
4. If withdrawal succeeds and `actualAmountWithdrawn > amount`, the difference is yield.
5. Withdrawn funds are credited to `claimableEscrowYield[token][escrowContract]` in `YieldOps`
   (pull-first hardening — no automatic forwarding back to the escrow).
6. The escrow calls `YieldOps.claimEscrowYield(token, amount)` to pull back the funds.

**Yield distribution:**

After the principal and yield are received, `YieldOps.distributeWithdrawnYield` handles
the yield split:

1. If a protocol fee is configured (`yieldProtocolFeeBps > 0`), compute
   `protocolFeeAmount = yieldAmount × feeBps / 10,000` and credit it to
   `claimableProtocolFees[token][feeRecipient]` (pull-only).
2. The remaining yield is passed to `IYieldDistributionModule.distributeYield(...)` for
   allocation per the `YieldPreset` configured at escrow creation.

**Current yield presets:**

| Preset | Distribution |
|--------|-------------|
| `OFF` | No yield; default when `yieldGenerationModule` is a no-op |
| `TO_SENDER` | 100% of yield credited to sender (`et.from`) |

Yield distribution is wrapped in `try/catch`. If the distribution module reverts, the yield
is deferred to `claimableEscrowYield` rather than blocking the settlement.

**Emergency fallback:** If `withdrawWithYield` itself fails, `BaseEscrow` attempts
`IYieldModule.emergencyUnwind(workflowId, token, yieldPrincipal)` as a last resort. If
both fail, settlement proceeds with the original principal only (yield is written off for
that escrow).

---

## 6. The `SettlementOps` compute/apply pattern

`SettlementOps` is an externally deployed compute-only contract. Its functions return
results; they do not write to `BaseEscrow` state.

```
BaseEscrow                                  SettlementOps
    │                                           │
    │──computeResolutionExecution(...)──────────►│ (view)
    │◄──────────────────────────────── Result ──│
    │  Apply: set PendingSettlement or execute   │
    │                                           │
    │──computePendingSettlementExecution(...)───►│ (view)
    │◄─────────────────────────── (canExecute) ─│
    │  Apply: delete pending, execute transfer   │
    │                                           │
    │──computeTimedActions(...)─────────────────►│ (view)
    │◄──────────────────── (actionType, isRelease)│
    │  Apply: execute release or cancel          │
```

This separation keeps `SettlementOps` stateless and upgradeable independently of
`BaseEscrow`. Upgrading `SettlementOps` (via `setSettlementOps`, gated by `ROLE_TIMELOCK`)
changes computation logic without touching escrow state or in-flight pending settlements.

`SettlementOps.computeResolutionExecution` uses `staticcall` to query
`IResolutionModule.getAppealDeadlineAndRound`, so it cannot modify module state. If the
module does not implement that function, it falls back to the global `appealWindowDuration`
from `timeoutConfig`.

---

## 7. Anti-spam guards on dispute raising

Before a dispute can be raised (which puts an escrow into `DISPUTED` state, the precondition
for dispute-based settlement paths), two rate-limiting checks are enforced:

**Minimum escrow value:**
```solidity
if (minValue > 0 && et.amountAfterFee < minValue) {
    revert DisputeAmountBelowMinimum(workflowId, et.amountAfterFee, minValue);
}
```
Dust escrows below `minDisputeEscrowValue` cannot enter dispute. Configurable by governance
via `ROLE_ADMIN_CONTRACT`.

**Per-sender rate limit:**
```solidity
// Rolling 24-hour window per sender
if (block.timestamp >= windowStart + 1 days) { reset window; count = 1; }
else { count++; require count <= maxPerDay; }
```
A single sender cannot raise more than `maxDisputesPerSenderPerDay` disputes in a 24-hour
window. Configurable by governance. Rate-limit state is not snapshotted — it lives at the
escrow-contract level.

---

## 8. CEI pattern and reentrancy protection

All externally callable settlement functions are marked `nonReentrant`. Within each
function, the checks-effects-interactions (CEI) ordering is consistently applied:

1. **Checks** — validate caller, state, and preconditions (all reverts happen here).
2. **Effects** — delete proposals/pending settlements, transition `escrowState`, emit events.
3. **Interactions** — credit claimable balances, call module hooks, handle yield.

Token transfers never occur during state transitions. The one external interaction in each
settlement path is the module notification (e.g., `finalizeDispute`), which is wrapped in
`try/catch` to prevent a malicious or broken module from blocking finality.

---

## 9. Settlement path quick reference

| Path | Entry function | From state | To state | Who can call |
|------|---------------|-----------|---------|-------------|
| Voluntary release | `release()` | `PENDING` | `RELEASED` | `et.from`, `releaseAddress` |
| Recipient cancel | `recipientCancel()` | `PENDING` | `REFUNDED` | `et.to` |
| Sender cancel | `senderCancel()` | `PENDING` | `REFUNDED` | `et.from` |
| Mutual split | `proposeSplit()` + `acceptSplit()` | `PENDING` or `DISPUTED` | `RESOLVED` | Both parties |
| Resolver release | `releaseAsDisputeResolver()` | `DISPUTED` | `RELEASED` (final) or `PendingSettlement` | Authorized resolver |
| Resolver cancel | `cancelAsDisputeResolver()` | `DISPUTED` | `REFUNDED` (final) or `PendingSettlement` | Authorized resolver |
| Execute pending settlement | `executePendingSettlement()` | `DISPUTED` + `PendingSettlement` | `RELEASED` or `REFUNDED` | Either party, `ROLE_TIMELOCK` |
| Timed automation | `automateTimedActions()` | `PENDING` or `DISPUTED` | `RELEASED` or `REFUNDED` | Either party, `ROLE_TIMELOCK` |
| Dispute timeout | `resolveDisputeByTimeout()` | `DISPUTED` | `REFUNDED` | Either party, `ROLE_TIMELOCK` |
