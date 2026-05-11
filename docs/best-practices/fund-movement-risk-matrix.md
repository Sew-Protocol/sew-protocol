# Fund Movement Risk Matrix (Autopush Hardening)

## Scope

This matrix tracks high-value movement paths in the SEW Solidity contracts and maps each path to:

- movement mode (push vs pull)
- control layer(s)
- expected failure behavior
- current test coverage

The objective is to keep settlement and payout flows aligned with pull-first risk reduction.

---

## Legend

- **Movement mode**
  - **Pull**: beneficiary explicitly claims/withdraws
  - **Push**: contract sends assets during state transition
- **Risk tier**
  - **High**: direct user-funds movement or governance-drain path
  - **Medium**: bounded fee or module-forwarding path
  - **Low**: internal accounting or non-user-critical movement

---

## Matrix

| Path | Contract / Function | Movement Mode | Risk | Controls | Failure Behavior | Test Coverage |
|---|---|---:|---:|---|---|---|
| Manual release settlement | `BaseEscrow.release()` + entitlement creation | Pull | High | Claimable ledger (`claimableBalances`), nonReentrant, explicit `withdrawEscrow` | Settlement creates entitlement, no direct recipient payout | `AutoTransfer.t.sol::test_release_creates_claimable_not_direct_transfer` |
| Manual cancel/refund settlement | `BaseEscrow.senderCancel/recipientCancel` | Pull | High | Claimable ledger, explicit user withdraw path | No direct refund push during transition | `AutoTransfer.t.sol::test_cancel_creates_claimable_not_direct_transfer` |
| Timed auto-release | `BaseEscrow.automateTimedActions` | Pull | High | Permissionless execution; deterministic deadline/state gating; claimable entitlement only; idempotent semantics expected | No direct payout transfer in timed transition | `AutoTransfer.t.sol::test_timed_auto_release_creates_claimable_not_direct_transfer` |
| Timed auto-cancel | `BaseEscrow.automateTimedActions` | Pull | High | Permissionless execution; deterministic deadline/state gating; claimable entitlement only; idempotent semantics expected | No direct refund transfer in timed transition | `AutoTransfer.t.sol::test_timed_auto_cancel_creates_claimable_not_direct_transfer` |
| Protocol fee claims (bond) | `BaseEscrow.claimBondProtocolFees` | Pull | Medium | Claimable fee ledger + explicit claim + transfer-last pattern | Failed transfer reverts and restores claimable balance | Covered in core fee scenario/hardening suites |
| Excess ETH refund claims | `BaseEscrow.claimExcessEthRefund` | Pull | Medium | Claimable refund ledger + explicit claim | Failed transfer restores claimable amount and reverts | Covered in core escrow fee/refund flows |
| Yield protocol fee delivery | `YieldOps.withdrawClaimableProtocolFee` | Pull | Medium | Claimable fee mapping per recipient | Explicit withdraw required; no auto-delivery | `YieldWithdrawalNonBlocking` + yield coverage suites |
| Escrow yield delivery | `YieldOps.claimEscrowYield` | Pull | Medium | Escrow-scoped claimable mapping + role gating | No recipient push fallback | `YieldWithdrawalNonBlocking` + yield validation suites |
| Appeal bond refund to escalator | `ResolverIncentiveModuleV2.claimBondRefund` | Pull | Medium | Claimable bond refunds mapping, nonReentrant | Refund claimed explicitly; no direct forced push on distribution | DR module incentive tests |
| Bond collection ETH fee forwarding | `BondCollector._collectETHBond` | Push | Medium | Fee amount bounded by BPS; role-gated caller; timelock recovery for residual ETH | Returns `false` on fee transfer fail or module call fail | `BondCollector.t.sol` (`feeTransferFails`, `moduleCallFails`) |
| Bond collector excess ETH custody | `BondCollector.collectBond` (msg.value > bond) | Custody (residual) | Medium | Timelock-only `recoverNativeETH` | Excess stays in collector until recovered by timelock | `BondCollector.t.sol::test_collectBond_ETH_excessValue_recoverable_onlyByTimelock` |
| Insurance payout (slow lane) | `InsurancePoolVault.proposePayout/executePayout` | Push | High | `ROLE_TIMELOCK`, 7-day delay, source-balance checks | Execute blocked before delay; only timelock can execute | `InsurancePoolVaultHardening.t.sol::test_executePayout_requiresSlowDelay_thenSucceeds` |
| Insurance break-glass direct withdraw | `InsurancePoolVault.withdraw` | Push | High | Disabled by default, `ROLE_TIMELOCK`, explicit enable toggle | Reverts while disabled | `InsurancePoolVaultHardening.t.sol::test_withdraw_breakGlass_disabledByDefault` |
| Insurance withdraw toggle | `InsurancePoolVault.setWithdrawalsEnabled` | Governance control | High | Timelock-only | Unauthorized caller reverts | `InsurancePoolVaultHardening.t.sol::test_setWithdrawalsEnabled_onlyTimelock` |

---

## Residual Risks and Policy Notes

1. **Bounded push islands remain** (BondCollector fee forwarding, insurance payout execution).
   - These are governance- or role-gated and tested, but still merit monitoring alerts.

2. **Excess ETH custody in BondCollector** is intentional and now explicitly tested.
   - Operationally, timelock should periodically sweep residual ETH.

3. **Break-glass insurance withdraw** is intentionally available.
   - Keep disabled by default; use slow-lane payout path as standard operating mode.

4. **Permissionless timed actions are acceptable only with strict gates**.
   - Main residual risks are griefing/order/finality boundaries, not direct fund-drain (given pull-only settlement).

---

## Permissionless Timed-Action Invariants (Must Hold)

| Invariant | Requirement |
|---|---|
| Deadline-gated | Cannot execute before escrow-stored deadline; caller cannot supply/override timeout inputs |
| State-gated | Action only valid from intended escrow states |
| Rights-safe | Cannot bypass valid dispute/challenge/cancel windows |
| Pull-only | Timed actions create claimables; do not push participant funds |
| Idempotent | Repeated execution cannot duplicate claimables or terminal transitions |
| Non-blocking | Invalid/stale timed action reverts or no-ops without partial accounting mutation |
| Bounded gas | No unbounded iteration over user-controlled sets in a single action |

### Boundary cases to verify explicitly

- `block.timestamp == deadline`
- `block.timestamp > deadline`
- dispute-opening boundary vs auto-finalization boundary
- paused/escalated/finality-buffer states where timed actions must be blocked

---

## Recommended Monitoring Signals

- `WithdrawalsEnabled(true)` event emitted in `InsurancePoolVault`
- Any `InsurancePayoutExecuted` event with `payoutId = 0` (direct withdraw path)
- Non-zero `BondCollector` native balance over time (unswept excess ETH)
- Repeated `collectBond` false outcomes for ETH fee forwarding/module call
