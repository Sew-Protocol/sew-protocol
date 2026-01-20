# FailureReason usage matrix (current reality vs intended telemetry)

**Scope:** `contracts/core/BaseEscrow.sol` `FailureReason` enum + related “insufficient balance / transfer failed” behaviors.  
**Audience:** protocol devs + indexer/backend consumers who need consistent operational signals.  
**Status:** snapshot of **current code behavior** (not aspirational), with staged recommendations.

---

## Key clarification (answering the question directly)

**Yes**: the current on-chain behavior is generally *safe* (no silent loss from protocol perspective) because many paths either revert or fall back to the pull model.  
**Also yes**: `FailureReason.CONTRACT_INSUFFICIENT_BALANCE` is **currently not emitted/used** anywhere; “insufficient balance” surfaces via **custom error reverts** (e.g. `InsufficientContractBalance`) or as a generic **push-failed fallback** reason.

---

## FailureReason enum (as defined)

From `contracts/core/BaseEscrow.sol`:

- `CALL_FAILED`
- `MALFORMED_RETURN_DATA`
- `MODULE_NOT_SET`
- `MODULE_NOT_CONTRACT`
- `CONTRACT_INSUFFICIENT_BALANCE` (**defined, but currently unused**)
- `TRANSFER_FAILED` (**defined, but currently unused as a reason code**)
- `PUSH_FAILED_FALLBACK_TO_PULL`
- `DEPOSIT_FAILED`
- `WITHDRAWAL_FAILED`
- `LESS_THAN_PRINCIPAL`
- `TIMEOUT`

---

## Usage matrix (where we emit FailureReason vs where we don’t)

### Legend

- **Blocking**: function reverts (custom error). No `FailureReason` is emitted because the tx fails.
- **Best-effort**: function continues; emits events (`OperationFailure`, `YieldHandlingFailed`, etc.) with a numeric `reasonCode` tied to `FailureReason`.

### Table

| Failure / trigger | Surface / where it happens | Blocking or best-effort? | Current user-visible behavior | Current telemetry signal | Uses `FailureReason`? | Notes / mismatch |
|---|---|---|---|---|---|---|
| **Withdraw fees when `feeAmount == 0`** | `EscrowVault.withdrawFees(token)` | Blocking | Reverts `NoFeesToWithdraw(token, 0)` | none (tx reverts) | **No** | Not a telemetry path; indexers must infer via revert. |
| **Withdraw fees when `balance < feeAmount`** | `EscrowVault.withdrawFees(token)` | Blocking | Reverts `InsufficientContractBalance(token, required, available)` | none (tx reverts) | **No** | This is the “insufficient balance” case for fees; it does **not** use `FailureReason.CONTRACT_INSUFFICIENT_BALANCE`. |
| **Withdraw fees when caller lacks `ROLE_FEE_RECIPIENT`** | `EscrowVault.withdrawFees(token)` | Blocking | Reverts (AccessControl) | none (tx reverts) | **No** | Intentional: permission failure should revert. |
| **Push transfer fails during finalization** (release/refund) | `BaseEscrow._attemptAutoTransfer()` | Best-effort | Escrow finalizes; funds become claimable (pull) | `ClaimableBalanceSet`, `EscrowTransferAutoResult(success=false, reason=PUSH_FAILED_FALLBACK_TO_PULL)`, `OperationFailure(op=4, reason=PUSH_FAILED_FALLBACK_TO_PULL)` | **Yes** (`PUSH_FAILED_FALLBACK_TO_PULL`) | This reason covers **all** push failures (token revert, non-standard return, insufficient balance, etc.). No differentiation today. |
| **True contract balance deficit** (e.g., fee-on-transfer token) | `withdrawEscrow()` after claimable is set but vault lacks actual tokens | Blocking (at withdraw time) | `withdrawEscrow()` reverts (token transfer fails / insufficient balance) | none (tx reverts) | **No** | You may see claimable set successfully, but later withdraw can revert because the vault is insolvent for that token/workflow. This is not represented by `FailureReason.CONTRACT_INSUFFICIENT_BALANCE` today. |
| **Yield deposit fails** | create-time yield deposit path in `BaseEscrow.createEscrow()` | Best-effort | Escrow creation succeeds; yield is simply not deposited | `YieldHandlingFailed(reason=DEPOSIT_FAILED)` + `OperationFailure(op=1, reason=DEPOSIT_FAILED)` | **Yes** (`DEPOSIT_FAILED`) | Code intentionally keeps yield optional. |
| **Yield module missing / not contract** (when yield is enabled for escrow) | `_handleYieldAndGetActualAmount()` | Best-effort | Release/refund proceeds using principal | `YieldHandlingFailed(reason=MODULE_NOT_SET / MODULE_NOT_CONTRACT)` + `OperationFailure(op=2, reason=...)` | **Yes** | Correctly uses module wiring reasons. |
| **Yield withdraw call fails** | `_handleYieldAndGetActualAmount()` | Best-effort | Release/refund proceeds using principal | `YieldHandlingFailed(reason=WITHDRAWAL_FAILED)` + `OperationFailure(op=2, reason=CALL_FAILED)` | **Partially** | Mixed: `YieldHandlingFailed` uses `WITHDRAWAL_FAILED`, while `OperationFailure` uses `CALL_FAILED`. That’s not “wrong” but is inconsistent for simple dashboards. |
| **Yield withdraw return malformed** | `_handleYieldAndGetActualAmount()` | Best-effort | Release/refund proceeds using principal | `YieldHandlingFailed(reason=WITHDRAWAL_FAILED)` + `OperationFailure(op=2, reason=MALFORMED_RETURN_DATA)` | **Partially** | Similar split: “withdrawal failed” vs “malformed return”. |
| **Yield withdraw returns < principal** | `_handleYieldAndGetActualAmount()` | Best-effort | Release/refund proceeds, clamps to principal | `YieldHandlingFailed(reason=LESS_THAN_PRINCIPAL)` + `OperationFailure(op=2, reason=LESS_THAN_PRINCIPAL)` | **Yes** | This is a clean use of reason codes. |
| **Incentive module hook fails** | `BaseEscrow.raiseDispute()` incentive hook | Best-effort | Dispute opening succeeds | `IncentiveModuleCallFailed(reason=CALL_FAILED)` + `OperationFailure(op=3, reason=CALL_FAILED)` | **Yes** (`CALL_FAILED`) | No decoding occurs; “malformed return” not applicable. |
| **Dispute timeout auto-cancel** | `BaseEscrow.autoCancelDisputedEscrow()` | Best-effort (for caller) | Cancels + refunds; marks RESOLVED | `DisputeAutoCancelled(reason=TIMEOUT)` | **Yes** (`TIMEOUT`) | Timeout has a dedicated event; `FailureReason` here is more of a stable code than a “failure”. |

---

## Recommendations (staged)

### Immediate (no protocol changes; clarify + operationalize)

- **Document reality for integrators/indexers**:
  - “Insufficient contract balance” is currently represented by:
    - **revert** `InsufficientContractBalance(...)` on `withdrawFees()`, and
    - **revert** (token transfer failure) on `withdrawEscrow()` in deficit scenarios
    - **NOT** by `FailureReason.CONTRACT_INSUFFICIENT_BALANCE`.
- **Treat `EscrowTransferAutoResult(success=false, reason=PUSH_FAILED_FALLBACK_TO_PULL)` as the canonical signal** of “push delivery failed but escrow still finalized safely via pull”.
- **Operational warning** (for testnet simulation): if you use deflationary/fee-on-transfer tokens, you can create **claimable balances that cannot be withdrawn** (protocol insolvency for that token).

### Next testnet release (small, targeted telemetry improvements)

- **Wire up `CONTRACT_INSUFFICIENT_BALANCE` in `_attemptAutoTransfer`**:
  - Pre-check `IERC20(token).balanceOf(address(this)) < amount` before attempting the low-level transfer.
  - If insufficient:
    - set `claimableBalances` (same as today),
    - emit `EscrowTransferAutoResult(..., reason=CONTRACT_INSUFFICIENT_BALANCE)`,
    - emit `OperationFailure(..., reason=CONTRACT_INSUFFICIENT_BALANCE)`.
  - Keep `PUSH_FAILED_FALLBACK_TO_PULL` for “transfer attempt failed for other reasons”.
- **Align reason codes between `YieldHandlingFailed` and `OperationFailure`** (pick one mapping for dashboards):
  - either make both emit the specific underlying reason (`CALL_FAILED` / `MALFORMED_RETURN_DATA`), or
  - keep `YieldHandlingFailed` at the semantic level but document it as “category”, not “root cause”.

### Post-IEO release (behavioral policy on unsupported tokens)

- Decide and enforce one of:
  - **Reject fee-on-transfer/deflationary tokens** at `createEscrow` (detect by measuring vault balance delta during `_pullTokens`), or
  - **Support them explicitly** by using the **actual received amount** as the escrow principal (requires careful accounting + event semantics).
- Add a **solvency/deficit observability primitive** for ops (e.g., per-token “protected balance vs actual balance” view) so operators can detect deficits without provoking reverts.

### Wait for DR1 release (telemetry consolidation / rollout discipline)

- Treat `FailureReason` as **ABI-like** for analytics:
  - append-only, documented numeric values, and stable semantics.
- Consolidate failure telemetry across:
  - release/refund delivery,
  - settlement execution,
  - DR module hooks / callbacks,
  - bond collection paths,
  so DR1 dashboards can show “why a workflow is stuck or degraded” with one consistent pipeline.

---

## Notes specific to the recent Base Sepolia observations

- Your Base Sepolia deployment has `EscrowVault.escrowFee == 0`, so “fee-based deficit” scenarios won’t naturally occur unless there are historical fees and the vault becomes insolvent for that token.
- The fee-on-transfer test scenario is a valid way to reproduce a real deficit, and it illustrates why a distinct `CONTRACT_INSUFFICIENT_BALANCE` reason would be useful (today it appears as generic push-failed fallback + later withdraw revert).

