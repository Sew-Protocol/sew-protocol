# FailureReason wiring plan (consistency + rollout)

**Status:** Draft plan  
**Scope:** `FailureReason` (event reason codes), and how it fits with existing revert/custom-error handling.

---

## 1) What “failure handling” means in this repo today

This codebase uses **two distinct failure channels** intentionally:

1. **Blocking failures (reverts / custom errors)**
   - Used when the user or caller expects a strong guarantee: authorization, invalid state, insufficient balance, invalid config, etc.
   - Example: `withdrawEscrow()` reverts if there is no claimable balance; state transitions revert when invalid.

2. **Non-blocking failures (events with reason codes)**
   - Used when the protocol chooses **best-effort** behavior and must not brick the primary flow.
   - Today this is mainly:
     - Yield deposit/withdraw (best-effort; failure should not block escrow lifecycle)
     - Optional incentive module hooks
     - Auto-transfer push attempts that can fall back to pull model

**Key principle:** `FailureReason` is **not** a replacement for custom errors.  
It is a telemetry/UX aid for *non-blocking paths* where the contract continues safely.

---

## 2) Current on-chain patterns that matter for FailureReason

### 2.1 Pull model is “success path” fallback

In `BaseEscrow`, the protocol already uses a **pull fallback** when a push transfer fails:
- push attempt fails
- claimable balance is credited
- event emitted

This is consistent with adding a `PUSH_FAILED_FALLBACK_TO_PULL` reason code, and it should become the default code for that pattern.

### 2.2 Yield lifecycle is best-effort

Create-time deposit and settlement-time withdrawal are executed via low-level calls and/or module interfaces.
Failures currently emit `YieldHandlingFailed(...)` but do not revert the escrow.

**Correctness requirement:** the yield path must be *non-reverting end-to-end*.  
That means:
- no `abi.decode(...)` that can revert on malformed return data
- no assumptions that `ret.length > 0` implies a decodable struct
- yield module upgrades / ABI drift must not brick release/refund/cancel flows

This matches the intended meaning of:
- `DEPOSIT_FAILED`
- `WITHDRAWAL_FAILED`
- `LESS_THAN_PRINCIPAL`

### 2.3 Optional modules should not break core escrow flows

The incentive module hook failures emit `IncentiveModuleCallFailed(...)` and are ignored.
This is consistent with `CALL_FAILED` / `MALFORMED_RETURN_DATA` codes.

---

## 3) The FailureReason enum: what it should represent

The enum should map to **observable outcomes** that the frontend/indexers can display, and that operators can alert on.

Recommended semantic split:

- **Call outcome**
  - `CALL_FAILED`: low-level call reverted / returned `success=false`.
  - `MALFORMED_RETURN_DATA`: call succeeded but data cannot be decoded / missing expected return values.

- **Module wiring**
  - `MODULE_NOT_SET`: module address is `address(0)` when needed for the attempted operation.
  - `MODULE_NOT_CONTRACT`: module address is nonzero but has `code.length == 0`.

- **Transfers/accounting**
  - `CONTRACT_INSUFFICIENT_BALANCE`: pre-check failed (contract did not have funds to push).
  - `TRANSFER_FAILED`: transfer/call attempt failed (and we did NOT successfully complete the intended push).
  - `PUSH_FAILED_FALLBACK_TO_PULL`: push failed, but we safely credited pull balance.

- **Yield**
  - `DEPOSIT_FAILED`: deposit attempt failed (or data malformed).
  - `WITHDRAWAL_FAILED`: withdrawal attempt failed (or data malformed).
  - `LESS_THAN_PRINCIPAL`: withdrawal returned < principal (clamped or handled).

- **Timeout**
  - If timeouts are part of telemetry (they already emit a timeout-coded event), keep `TIMEOUT` (appended-only policy).

---

## 4) Consistency check vs existing errors & flows

### 4.1 Blocking errors (custom errors) are already consistent

Core user-facing actions generally revert with custom errors:
- invalid workflow/state → `TransferNotPending`, `TransferNotInDispute`, etc.
- permission failures → `NotSender`, `NotRecipient`, `NotAuthorizedResolver`, etc.
- invalid config for critical wiring → `ZeroCreateOps`, `ZeroSettlementOps`, `ZeroBondCollector`, etc.

✅ No changes needed for these to “use FailureReason”. They should remain custom errors.

### 4.2 Non-blocking paths need more precise FailureReason mapping

Right now some places collapse multiple root causes into a single code.

**Examples of improvements:**
- Yield withdrawal needs to distinguish:
  - `!ok` → `CALL_FAILED`
  - `ok && ret malformed/too short/wrong ABI` → `MALFORMED_RETURN_DATA`
  - `ok && decodeable but value < principal` → `LESS_THAN_PRINCIPAL`
  - **And critically:** it must never revert if `ret` is malformed (yield is optional).

- Auto push failure fallback currently emits `TRANSFER_FAILED` even though it *did* recover by switching to pull.
  - Better:
    - when claimable balance is credited: emit `PUSH_FAILED_FALLBACK_TO_PULL`

- Incentive module hook failure currently uses only `CALL_FAILED`.
  - Better:
    - `callSuccess=false` → `CALL_FAILED`
    - `callSuccess=true` but `ret` malformed (if relevant) → `MALFORMED_RETURN_DATA`
  - If there is no decode step (fire-and-forget), `MALFORMED_RETURN_DATA` may be irrelevant; keep `CALL_FAILED`.

---

## 5) Recommended wiring changes (by urgency)

### P0 (Urgent: before public testnet addresses circulate)

Goal: ensure **stable numeric mapping** + no misleading codes + no “optional path can revert” hazards.

- **Freeze enum order**
  - Confirm “append-only” policy is followed.
  - Add/keep `TIMEOUT` only if it’s needed for existing timeout telemetry.

- **Fix misleading fallback code**
  - When push fails but claimable is credited, emit `PUSH_FAILED_FALLBACK_TO_PULL` (not `TRANSFER_FAILED`).

- **Make yield “non-critical” truly non-reverting**
  - Replace any “decode can revert” pattern with decode-safe handling:
    - `!ok` → emit `CALL_FAILED`, return principal
    - `ok` but `ret` too short / malformed → emit `MALFORMED_RETURN_DATA`, return principal
    - only decode fixed-width primitives or guard struct decode with strict length checks
  - Prefer “primitive return” from `YieldOps.handleYield` (`uint256 actualAmount` + optional `uint256 feeAmount`) so callers can decode safely.

- **Split call-failed vs malformed-return everywhere it matters**
  - Any place doing `if (!ok || ret.length == 0)` should emit:
    - `CALL_FAILED` when `!ok`
    - `MALFORMED_RETURN_DATA` when `ok && ret invalid`

- **Bond / ETH invariants (audit-grade clarity)**
  - If bond token is ERC20: require `msg.value == 0` (no silent ETH left behind).
  - If bond token is ETH: require `msg.value >= bondAmount` and explicitly refund excess.

- **Avoid “unbonded escalation” edge cases**
  - If escalation requires a bond, do not treat “bond query failed” as “bond not required”.
  - Pick and document one of:
    - **strict**: bond query failure reverts (safer default)
    - **best-effort**: emit a dedicated failure event (at minimum) and continue only if bond is truly optional

Acceptance:
- Events emitted match “what happened” (transfer failed but pull succeeded ≠ transfer failed).
- Off-chain dashboards don’t over-alert on normal recoveries.
- Yield handling cannot brick escrow execution due to decode/ABI drift.
- Escalation bond payment rules are unambiguous for integrators.

### P1 (High priority: next iteration)

Goal: improve module-wiring observability without changing core behavior.

- Before any optional module call, classify:
  - `MODULE_NOT_SET` / `MODULE_NOT_CONTRACT` / attempt call.
- Emit telemetry events when an operation was skipped due to module wiring (optional).

Acceptance:
- Frontend can explain “yield skipped because module not configured” vs “yield deposit reverted”.

### P2 (Medium priority: unify telemetry surface)

Goal: one consistent event surface for operational failures.

- Consider consolidating failure events into a single event shape (or a small set):
  - `OperationFailed(uint8 op, uint8 reason, bytes4 selector, address module, uint256 workflowId, ...)`
  - Keep existing events if ABI stability is a priority; otherwise consolidate before mainnet.

Acceptance:
- Indexers have one pipeline for errors.

---

## 6) Testing / verification plan

### Foundry/Hardhat tests should assert reason codes

Add/extend tests for:
- **Push fallback path**
  - Ensure claimable balance is credited
  - Ensure event reason is `PUSH_FAILED_FALLBACK_TO_PULL`

- **Yield withdraw call failure**
  - Mock module reverts → expect `CALL_FAILED` (or `WITHDRAWAL_FAILED` depending on final mapping)

- **Yield withdraw malformed return**
  - Mock module returns success with empty/short bytes → expect `MALFORMED_RETURN_DATA`

- **Bond msg.value invariants**
  - ERC20 bond + nonzero `msg.value` should revert
  - ETH bond + insufficient `msg.value` should revert with an explicit error
  - ETH bond + excess `msg.value` should refund excess

- **Timeout**
  - Ensure timeout events emit the correct `TIMEOUT` code (and that enum is append-only).

---

## 7) Rollout / coordination notes

- **Breaking implications**
  - Changing enum order is a breaking change for any off-chain consumer decoding numeric reason codes.
  - Therefore: treat `FailureReason` as **ABI-like** for telemetry. Append-only.

- **Urgency**
  - Do P0 before:
    - public testnet deployments are shared widely
    - dashboards/analytics/partners hardcode reason code meanings

- **Migration strategy**
  - Prefer adding new values and adjusting emit sites over reordering.
  - If you need a “timeout” value but didn’t plan it initially, append it and document its numeric value.

