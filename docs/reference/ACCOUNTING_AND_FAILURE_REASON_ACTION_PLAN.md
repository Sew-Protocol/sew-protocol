# Accounting + FailureReason action plan

**Purpose:** track *concrete* engineering actions from the recent investigations:
- `FailureReason.CONTRACT_INSUFFICIENT_BALANCE` is defined but not wired
- “insufficient balance” can mean multiple distinct things (contract solvency vs user balance vs push transfer failure)
- internal accounting (`totalHeldInEscrowPerToken`, `totalFeesPerToken`) does **not** currently protect claimables from `recoverERC20`

This doc is an actionable follow-up to:
- `docs/reference/FAILURE_REASON_USAGE_MATRIX.md`

---

## What we verified (current behavior)

### A) `FailureReason.CONTRACT_INSUFFICIENT_BALANCE`
- **Defined** in `contracts/core/BaseEscrow.sol` enum.
- **Not emitted anywhere** (no `EscrowTransferAutoResult` / `OperationFailure` using it).

### B) Current “insufficient balance” surfaces through multiple channels

| Scenario | Where it happens | Current behavior | Why this matters |
|---|---|---|---|
| Contract can’t pay fees | `EscrowVault.withdrawFees(token)` | **Reverts** `InsufficientContractBalance(token, required, available)` | Blocking admin path; no telemetry event survives revert |
| Push transfer fails (any reason) | `BaseEscrow._attemptAutoTransfer` | **Fallback to claimable**, emits reason `PUSH_FAILED_FALLBACK_TO_PULL` | Telemetry exists, but root cause not distinguished |
| Contract is truly insolvent for a workflow/token | `withdrawEscrow(workflowId)` after claimable set | **Reverts** on token transfer | This is the “locked funds” case |
| User doesn’t have balance / allowance | `createEscrow` → token `transferFrom` | **Reverts** (token error / generic revert) | Poor UX; no stable protocol-level reason today |

### C) Accounting signals present but unused
- `error AccountingDeficit(address token, uint256 deficit);` exists in `BaseEscrow.sol` but is **never used**.

### D) Critical accounting gap: claimables aren’t protected from recovery
`EscrowVault.recoverERC20()` protects only:
- `totalHeldInEscrowPerToken[token]`
- `totalFeesPerToken[token]`

It does **not** protect tokens that are owed via the pull model:
- `claimableBalances[workflowId][recipient]`

So a sequence like:
1) push transfer fails → `claimableBalances += amount`
2) governance calls `recoverERC20(token, recipient, amount)` while those tokens are still held

…can remove tokens that are owed to users, causing `withdrawEscrow()` to revert later.

---

## Should we add `ACCOUNT_INSUFFICIENT_BALANCE` / `USER_INSUFFICIENT_BALANCE`?

### Recommendation (short)
- **Do not** add “user insufficient balance” to `FailureReason` (telemetry) because it’s a **blocking** failure (tx reverts). Telemetry events don’t survive reverts.
- Instead, add **explicit custom errors** / preflight checks (optional) so the revert is stable and indexers can classify it.

### How to represent “user insufficient balance” properly
There are two useful “preflight” checks at escrow creation:
- `IERC20(token).allowance(from, escrow) < amount` → **User allowance insufficient**
- `IERC20(token).balanceOf(from) < amount` → **User balance insufficient**

**Caveat:** this adds gas and assumes the token behaves like a standard ERC20 (most do). For non-standard tokens, the check can itself revert.

---

## Action items (grouped by release timing)

### Immediate (today / no on-chain upgrade required)

1) **Document reality for indexers/partners**
- In `FAILURE_REASON_USAGE_MATRIX.md`, treat:
  - `InsufficientContractBalance(...)` revert as the canonical fee-withdraw “insufficient” signal.
  - `EscrowTransferAutoResult(reason=PUSH_FAILED_FALLBACK_TO_PULL)` as “push failed but pull path credited”.

2) **Operational guardrail**
- Add an explicit warning in testnet docs: avoid fee-on-transfer / deflationary tokens unless we intentionally support them.

3) **Monitoring query to detect deficits off-chain**
- Recommend indexers compute:
  - `IERC20(token).balanceOf(EscrowVault)` vs `totalHeldInEscrowPerToken[token] + totalFeesPerToken[token]`
  - and alert if `balance < protected` (this is an “accounting deficit”).

### Next testnet release (small code changes; high ROI)

1) **Wire `FailureReason.CONTRACT_INSUFFICIENT_BALANCE` in `_attemptAutoTransfer`**
- Before attempting `_tryTransfer`, check:
  - `IERC20(token).balanceOf(address(this)) < amount`
- If insufficient:
  - emit `EscrowTransferAutoResult(..., success=false, reason=CONTRACT_INSUFFICIENT_BALANCE)`
  - emit `OperationFailure(op=4, ... reason=CONTRACT_INSUFFICIENT_BALANCE)`
  - then credit `claimableBalances` (or decide to revert; see Post-IEO policy)

2) **Optional: wire `FailureReason.TRANSFER_FAILED`**
- Distinguish:
  - `CONTRACT_INSUFFICIENT_BALANCE` (precheck failed)
  - `TRANSFER_FAILED` (transfer attempt reverted/returned false)
  - `PUSH_FAILED_FALLBACK_TO_PULL` can remain as the “we recovered” signal, but it’s currently used as the only one.

3) **Add a fork-only regression test**
- Add a fork test that forces a deficit and asserts:
  - correct reason code(s) emitted
  - claimable credited
  - withdraw behavior is as expected

### Post-IEO release (fix “locked claimable” class + token policy)

1) **Protect claimables in `recoverERC20`**
Choose one:
- **A (preferred): track per-token claimables**
  - Add `totalClaimablePerToken[token]`
  - Increment when claimable is credited
  - Decrement when `withdrawEscrow` succeeds
  - Include in `recoverERC20` protected calculation:
    - `protected = held + fees + claimable`
- **B: disallow `recoverERC20` for tokens with any open claimables**
  - On-chain enumeration is hard (claimables are per workflow+recipient), so this is less practical without new tracking.

2) **Use / expose `AccountingDeficit`**
- Add a view helper (or event) to surface:
  - `deficit = max(0, (held + fees + claimable) - balanceOf(vault))`
- Use `AccountingDeficit(token, deficit)` in **admin operations** (e.g., block fee withdrawal/recovery if deficit exists), or emit telemetry.

3) **Token policy decision**
- Either:
  - **Reject deflationary/fee-on-transfer tokens** at creation by measuring actual received amount and reverting if it doesn’t match expectations, OR
  - **Support them intentionally** by using actual received amount as principal (significant accounting + event semantic changes).

### Wait for DR1 release (telemetry consolidation / ABI discipline)

1) **Treat `FailureReason` as ABI-like**
- Append-only
- document numeric values
- ensure dashboards don’t break across releases

2) **Consolidate operational failure reporting**
- Provide a single “reason taxonomy” that applies to:
  - escrow delivery (push/pull)
  - yield
  - incentives/bonds
  - DR module hooks

---

## Quick code pointers (for implementers)

- `FailureReason` enum: `contracts/core/BaseEscrow.sol`
- Claimable credit: `_attemptAutoTransfer` in `BaseEscrow.sol`
- Fee insufficiency revert: `EscrowVault.withdrawFees(token)`
- Recovery protection gap: `EscrowVault.recoverERC20(token, recipient, amount)` (does not protect claimables)
- Unused error: `AccountingDeficit` defined in `BaseEscrow.sol` but never thrown

