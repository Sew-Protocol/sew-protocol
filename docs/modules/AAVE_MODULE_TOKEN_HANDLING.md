# AaveYieldModule — Token Handling, Accounting & Recovery

**Last updated**: 2026-09-21
**Contract**: `contracts/modules/AaveYieldModule.sol` (implements `IYieldModule` v2.5)
**Old references superseded**: this replaces the earlier `AaveYieldGenerationModule` /
`depositForYield` / `EscrowableERC20` token-handling note. The old ERC-4626-style vault
module, generalized YieldOps, and the separate distribution module were removed in favour
of a single simple adapter module. Distribution policy lives in core (`EscrowYield` /
`EscrowSettlement`), not in the module.

## Overview

`AaveYieldModule` is a **pull-based adapter** between the escrow vault and Aave V3. It has a
single, narrow responsibility:

1. Pull the accepted principal from the approved escrow.
2. Supply it to Aave V3 (`aavePool.supply`).
3. Track the position by `(escrow, escrowId)` using **scaled aToken shares**.
4. On unwind, redeem through `aavePool.withdraw` and return funds **only** to the escrow owner.

The escrow core is responsible for **who** gets principal, how yield is split, and how the
protocol yield fee is routed. The module never sends funds to arbitrary recipients and never
classifies principal vs yield.

## Fund-flow / custody chain

```text
Escrow --approve--> AaveYieldModule --supply--> Aave pool (pulls from module)
Aave pool --withdraw--> AaveYieldModule --transfer--> Escrow
Escrow --withdrawEscrow--> beneficiary
```

- **Deposit (pull):** `EscrowVault._depositForYield` grants an allowance to the module; the
  module pulls the exact requested amount via `safeTransferFrom`. Aave then pulls from the
  module when `aavePool.supply` is called.
- **Withdraw (push to escrow):** the module redeems via `aavePool.withdraw` and transfers the
  recovered amount back to the escrow owner.
- **Distribution (pull from escrow):** the beneficiary claims through the existing
  `withdrawEscrow` settlement path.

There is no two-transaction "send then initialize" protocol, and the module never treats an
unrelated pre-existing balance as a new deposit.

## Position accounting (scaled shares)

A position stores:

```solidity
struct YieldPosition {
    address token;
    uint256 principalDeposited; // accepted amount actually moved into Aave (INVARIANT 4)
    uint256 aTokenShares;       // index-independent scaled aToken delta at deposit
    address aToken;             // aToken the position was created with (immutable per position)
}
```

- `initializeYield` snapshots `scaledBalanceOf(this)` **before** and **after** `supply` and
  records the delta as `aTokenShares`. Because `scaledBalanceOf` is index-independent, the
  recorded share is not inflated by yield accrued before the deposit.
- At unwind, the shares are converted to current underlying **exactly once**:
  `shares * getReserveNormalizedIncome(token) / 1e27`. This avoids double-counting the Aave
  liquidity index that a rebased `balanceOf` snapshot would introduce.
- `principalDeposited` is derived from a **module-balance delta across the supply call**
  (`balanceAfterPull - balanceAfterSupply`), not from `received - balanceOf(this)`. This makes
  the figure robust to a stray/donated pre-existing module balance, which cancels out on both
  sides of the supply call. A second initialization for the same `(escrow, escrowId)` is
  rejected (`PositionAlreadyExists`) so a position can never be silently overwritten/orphaned.

## Yield fee accounting (core, snapshotted)

The module returns gross yield; core applies the protocol yield fee. The model:

```text
P = principal deposited
R = assets recovered from Aave
Y = max(R - P, 0)                 realized positive yield
F = floor(Y * feeBps / 10_000)    protocol yield fee
B = Y - F                         beneficiary yield
conservation: R = P + B + F       (only F is floored)
```

- The rate is the **snapshotted** `moduleSnapshots[workflowId].yieldProtocolFeeBps`
  (captured at escrow creation), so a later governance change only affects new escrows.
- Fees are **never charged against principal**. If `R <= P`, `Y = 0` and `F = 0`; a loss never
  becomes a fee obligation.
- Fees are credited to the **pull-based** `totalFeesPerToken` bucket via `_recordFee`
  (reclassifying part of `yieldInBalance` into `feesCollected`), withdrawn by the fee recipient
  through `EscrowVault.withdrawFees` — there is no external treasury call in the settlement path.
- The position is deleted on unwind, so the same yield cannot be realized/charged twice.

## Emergency recovery & fee treatment (policy)

The emergency path (`emergencyUnwind`, `emergencyUnwindForEscrow`, `_emergencyUnwind`) calls
the **same** `aavePool.withdraw` path as a normal unwind — it is operator/escrow-triggered
**initiation** with proceeds forced to the escrow owner, **not** an independent Aave exit that
bypasses Aave-level failures (pause / no liquidity / pool malfunction).

**Fee exemption (accepted policy):** the emergency API returns an **undifferentiated recovered
amount**; core does not reclassify it into principal vs yield and therefore does not subject it
to the protocol yield fee (`_handleYieldModuleUnwind` returns `(recovered, 0)` on emergency
success). This is deliberately asymmetric with the normal unwind path:

- Normal successful unwind classifies principal/yield and applies the snapshotted yield fee.
- Emergency/recovery unwind restores recovered assets to the escrow **without** a yield fee.

Recovery operators are privileged incident actors; choosing the recovery path may waive
protocol yield fees. This is documented as policy in `IYieldModule.emergencyUnwind` and
`EscrowYield._handleYieldModuleUnwind`. Recovery is a down-only remediation path, not a
revenue path.

**Partial recovery is rejected:** if `recovered < recorded principal`, `_handleYieldModuleUnwind`
reverts `PartialRecoveryNotAllowed` and the settlement rolls back atomically. If **both** unwind
paths fail (normal + emergency), the escrow completes a claimable-only settlement
(`YieldUnwindFailed` emitted, linkage cleared) so the escrow is not permanently frozen; the
beneficiary claims later when assets are recovered into the vault.

## Governance (slow-lane asymmetry)

All authority changes are `onlyRole(ROLE_TIMELOCK)`. Risk-increasing changes go through the
7-day slow-lane queue→activate cycle; risk-reducing changes are fast:

| Operation | Class | Mechanism |
|---|---|---|
| `queueApproveEscrow` / `activateApproveEscrow` | Risk-increasing (new capital entry) | Slow lane |
| `queueConfigureToken` / `activateConfigureToken` | Risk-increasing (new asset) | Slow lane |
| `queueConfigureTokenCap` / `activateConfigureTokenCap` | Risk-increasing (raise cap) | Slow lane |
| `revokeEscrow` | Risk-reducing | Fast |
| `disableToken` | Risk-reducing | Fast |
| `lowerTokenCap` | Risk-reducing | Fast |
| `setRecoveryOperator` | Fast (constrained operator) | Fast |
| `configureMinDeposit` | Fast | Fast |
| `recoverTokens` / `recoverETH` | Incident recovery (timelock) | Timelock + whitelist |

**Asymmetric revocation semantics (finding #3):** revoking an escrow or disabling a token
stops **new exposure only**. Existing positions remain closable by their owning escrow (normal
and emergency unwind) and remain recoverable by an authorized recovery operator, because each
position records its own `aToken` and approval only gates new deposits.

## Immutable Aave pool

The Aave pool reference is **immutable** (`aavePool`, no setter). Migration model if ever
required:

```text
deploy replacement module -> approve/configure it -> switch new escrows to it
-> unwind old positions from the old module
```

Existing positions are safe because each records its own `aToken`; `tokenToAToken` only gates
new deposits.

## Exposure caps

Per-token total deposited cap (`depositCapByToken`, 0 = unlimited) with live aggregation in
`totalDepositedByToken`. Deposits that would exceed the cap revert; unwinds always reduce
exposure, so lowering a cap never strands existing funds. `canHandle` mirrors the cheap
deterministic admissibility checks (`ZERO_AMOUNT`, `TOKEN_NOT_CONFIGURED`, `BELOW_MIN_DEPOSIT`,
`CAP_EXCEEDED`) so it never reports a deposit as supported that `initializeYield` would reject.

## Consensus invariant checks

- `principalExpected` must equal the module's recorded `principalDeposited`
  (`PrincipalMismatch`) — a cross-component integrity check against re-deposit overwrite or
  mis-recording.
- CEI ordering: the position is deleted and exposure reduced **before** the external Aave
  withdraw/transfer, so a reentrancy attempt cannot observe a live position mid-unwind (a
  reverting external call restores the deleted state).
- Only escrow owner / authorized recovery operator can unwind; funds always return to the
  escrow owner, never to the caller.

## Related

- Interface & policy: `contracts/interfaces/IYieldModule.sol`
- Core orchestration: `contracts/core/EscrowYield.sol`
- Fee computation: `contracts/core/EscrowSettlement.sol` (`_computeYieldProtocolFee`)
- Fee storage/withdrawal: `contracts/core/EscrowVault.sol` (`_recordFee`, `withdrawFees`)
- End-to-end coverage: `test/foundry/modules/AaveEscrowE2E.t.sol`,
  `test/foundry/modules/AaveYieldEscrowAppealE2E.t.sol`,
  `test/foundry/modules/YieldUnwindFailedE2E.t.sol`
