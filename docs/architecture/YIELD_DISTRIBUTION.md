# Yield Distribution

This document describes who receives yield when escrows are released or refunded.

## Overview

When an escrow closes (released, refunded, or settled through dispute/Kleros), any yield
generated on the escrowed funds is unwound from the Aave yield module and distributed according
to the following process, all handled by **escrow core** (no separate distribution module):

1. **Unwind**: `_handleYieldModuleUnwind` calls the module's `unwindToEscrow` (falling back to
   `emergencyUnwind`) which returns `(principalOut, yieldOut)` and transfers the recovered funds
   back to the escrow.
2. **Protocol Fee Deduction**: A configurable percentage of the *realized positive yield*
   (`yieldProtocolFeeBps`, snapshotted at escrow creation) is collected as a protocol fee. Fees
   are credited to the pull-based `totalFeesPerToken` bucket (withdrawn by the fee recipient via
   `withdrawFees`), never via an external treasury call in the settlement path.
3. **Beneficiary Yield**: The remaining yield follows the escrow **beneficiary** — the party
   entitled to the principal on settlement (recipient `et.to` on release, sender `et.from` on
   cancel/refund, or the party ruled in favor of after a dispute/Kleros ruling).

## Accounting model

```text
P = principal deposited
R = assets recovered from Aave
Y = max(R - P, 0)                 realized positive yield
F = floor(Y * yieldProtocolFeeBps / 10_000)   protocol yield fee
B = Y - F                         beneficiary yield
conservation: R = P + B + F       (only F is floored)
```

- The fee is applied only to **realized positive yield**. If `R <= P`, `Y = 0` and `F = 0` — a
  loss never becomes a fee obligation and principal is never fee-bearing.
- The fee rate is the **snapshotted** `moduleSnapshots[workflowId].yieldProtocolFeeBps`; a later
  governance change only affects new escrows.
- On normal unwind the module classifies `principalOut`/`yieldOut`; core splits realized yield
  between the fee and the beneficiary. The full recovered amount `R = P + B + F` is credited to
  the beneficiary's claimable balance (fee reclassified into `feesCollected`).

### Example (straight release)

`P = 100`, `R = 110` → `Y = 10`. With `yieldProtocolFeeBps = 1000` (10%):
`F = 1`, `B = 9`. The beneficiary can claim `P + B = 109`; the protocol fee of `1` is claimable
by the fee recipient via `withdrawFees`. Conservation: `110 = 100 + 9 + 1`.

## When escrow is released

- **Principal**: 100% → recipient (`et.to`), delivered via claimable balance.
- **Yield**: after the protocol fee, the rest follows the recipient (`et.to`).

## When escrow is refunded / cancelled

- **Principal**: 100% → sender (`et.from`), delivered via claimable balance.
- **Yield**: after the protocol fee, the rest follows the sender (`et.from`).

## Dispute / split settlements

- **Split settlement**: the unwound yield is charged the protocol fee first, then split
  **pro-rata** to the principal split between buyer and seller, so conservation holds exactly.
- **Dispute / Kleros ruling**: the prevailing party's disposition wins; the yield follows the
  final beneficiary. Yield keeps accruing while the dispute/appeal is outstanding.

## Emergency recovery treatment (policy)

The emergency/recovery unwind path (`emergencyUnwind` / `emergencyUnwindForEscrow`) returns an
**undifferentiated** recovered amount. Core does not reclassify it and does **not** subject it to
the protocol yield fee. This is accepted policy: recovery is a privileged incident-remediation
path, not a revenue path. `PartialRecoveryNotAllowed` rejects recovered amounts below principal;
a full recovered amount (`>= principal`) is routed to the beneficiary with zero fee.

## Code locations

- **Unwind orchestration**: `contracts/core/EscrowYield.sol::_handleYieldModuleUnwind`
- **Fee computation**: `contracts/core/EscrowSettlement.sol::_computeYieldProtocolFee` / `_finalizeClaimableSettlement` / `_acceptSplitProposal`
- **Fee storage & withdrawal**: `contracts/core/EscrowVault.sol` (`_recordFee`, `withdrawFees`)
- **Module (gross yield)**: `contracts/modules/AaveYieldModule.sol` (`unwindToEscrow`, `emergencyUnwind`)
- **Interface/policy**: `contracts/interfaces/IYieldModule.sol`

## Summary table

| Scenario | Protocol Fee | Beneficiary Yield | Principal |
|----------|-------------|-------------------|-----------|
| **Escrow Released** | `F` → `totalFeesPerToken` (fee recipient) | `B` → Recipient (`et.to`) | 100% → Recipient |
| **Escrow Refunded** | `F` → `totalFeesPerToken` (fee recipient) | `B` → Sender (`et.from`) | 100% → Sender |
| **Dispute/Kleros** | `F` → `totalFeesPerToken` (fee recipient) | `B` → prevailing beneficiary | 100% → prevailing party |
| **Emergency recovery** | 0 (fee-exempt by policy) | recovered routed to escrow owner | recovered `>= P` |

There is no `DefaultYieldDistributionModule` / `YieldOps` / `distributeYield` — that architecture
was removed in favour of the simple `AaveYieldModule` adapter with distribution owned by escrow core.
