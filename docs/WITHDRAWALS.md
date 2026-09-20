# Withdrawals

> **Scope:** This document covers every withdrawal path in the Sew Protocol: how funds
> become claimable, how they are claimed, the balance-safety invariant that protects
> them, and the administrative recovery paths available for yield emergencies and
> insurance-pool disbursements.
>
> **Sources:** `contracts/core/BaseEscrow.sol` (`withdrawEscrow`, `claimBondProtocolFees`,
> `claimExcessEthRefund`, `_creditClaimable`, `_transferTokens`, `totalClaimableAssets`),
> `contracts/core/EscrowVault.sol` (`withdrawFees`),
> `contracts/modules/AaveYieldModule.sol` (`unwindToEscrow`, `emergencyUnwind`,
> `recoverTokens`, `recoverETH`),
> `contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV1.sol`
> (`claimPayment`),
> `contracts/modules/decentralized-resolution-module/ResolverIncentiveModuleV2.sol`
> (`claimBondRefund`),
> `contracts/modules/decentralized-resolution-module/InsurancePoolVault.sol`
> (`proposePayout`, `executePayout`, `withdraw`),
> `contracts/ops/GuardianOps.sol` (`emergencyUnwindAavePosition`).

---

## 1. The pull-only model

No function in Sew Protocol pushes tokens to an address automatically. Every settlement,
fee distribution, bond outcome, or yield allocation writes an entitlement to a claimable
ledger mapping. The recipient must initiate a separate transaction to pull their balance.

This design choice applies consistently across all fund types:

| Fund type | Claimable ledger | Claim function |
|-----------|-----------------|----------------|
| Escrow principal + yield | `claimableBalances[workflowId][address]` | `withdrawEscrow(workflowId)` |
| Bond protocol fees | `claimableBondProtocolFees[token][address]` | `claimBondProtocolFees(token, recipient)` |
| Excess ETH from bond posting | `claimableExcessEthRefunds[address]` | `claimExcessEthRefund()` |
| Resolver dispute payments | `claimablePayments[escrow][workflowId][address]` | `claimPayment(workflowId, escrow, token)` |
| Appeal bond refunds | `claimableBondRefunds[escrow][workflowId][address]` | `claimBondRefund(workflowId, escrow, token)` |
| Yield protocol fees | `totalFeesPerToken[token]` (EscrowVault) | `withdrawFees(token)` |

**Why pull-only?**

- Eliminates reentrancy risk during settlement — no outbound transfer occurs while state
  is being modified.
- Settlement succeeds even if the recipient is a contract that would revert on receive.
- Entitlement creation is atomic and auditable; fund delivery is a separate, idempotent
  operation.
- Failed transfers do not block other parties' claims.

---

## 2. Escrow principal withdrawal

```
Function: withdrawEscrow(workflowId)
Ledger: claimableBalances[workflowId][msg.sender]
Contract: BaseEscrow
```

`withdrawEscrow` is the primary withdrawal function for escrow participants (sender,
recipient, or split counterparty). It is available only after an escrow has reached a
terminal state.

**Pre-conditions:**

- `et.escrowState` must be `RELEASED`, `REFUNDED`, or `RESOLVED`. Any non-terminal state
  reverts with `TransferNotFinalized`.
- `claimableBalances[workflowId][msg.sender]` must be greater than zero; otherwise reverts
  with `NoClaimableBalance`.

**Execution:**

```solidity
uint256 amount = claimableBalances[workflowId][_msgSender()];
claimableBalances[workflowId][_msgSender()] = 0;   // effects first
totalClaimableAssets[token] -= amount;              // balance invariant
_transferTokens(token, _msgSender(), amount);       // interaction last
emit EscrowWithdrawn(workflowId, _msgSender(), token, amount);
```

The `totalClaimableAssets[token]` counter is decremented on every withdrawal and
incremented on every `_creditClaimable` call, keeping a running total of all outstanding
claimable amounts across all escrows for that token (see §6 for how this is used as a
balance invariant).

**What is credited:**

The credited amount depends on which settlement path executed:

| Settlement outcome | Amount credited | To |
|-------------------|----------------|----|
| Release | `amountAfterFee` + yield (if any) | `et.to` (recipient) |
| Refund | `amountAfterFee` + yield (if any) | `et.from` (sender) |
| Split | `buyerAmount` + proportional yield | `et.from` |
| Split | `sellerAmount` + proportional yield | `et.to` |

When a yield module is active, `_handleYieldModuleUnwind` is called before crediting.
If the unwind returns more than the original principal (because the module earned yield),
the full amount (principal + yield) is credited. The balance check in `_creditClaimable`
confirms the escrow contract holds the tokens before writing the entitlement:

```solidity
if (amount > principalExpected) {
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (bal < amount) revert EscrowInsufficientBalance();
}
```

---

## 3. Yield-related withdrawals

Yield accelerates to the escrow's settlement beneficiary through the normal `withdrawEscrow`
pull described in §2; separately, the protocol harvests a yield fee from the vault via
`withdrawFees`. There is no per-escrow yield claim and no separate yield ledger.

### 3.1 Yield to the settlement beneficiary — `withdrawEscrow`

When a yield module is active, `_handleYieldModuleUnwind` unwinds the position on settlement
and credits `principal + beneficiaryYield` to the single settlement beneficiary's
`claimableBalances[workflowId][address]`. The beneficiary pulls the full amount (principal +
yield) with `withdrawEscrow(workflowId)` exactly as described in §2 — no separate yield
claim function exists.

`beneficiaryYield = realizedYield − protocolFee` (see 3.2). The fee is carved out of yield
only, never out of principal.

### 3.2 Protocol yield fee — `EscrowVault.withdrawFees`

```
Function: withdrawFees(token)
Ledger: EscrowVault.totalFeesPerToken[token]
Caller: ROLE_FEE_RECIPIENT
```

During settlement, `_computeYieldProtocolFee` (in `EscrowSettlement`) applies the snapshotted
`yieldProtocolFeeBps` (max 3000 bps / 30%) to realized **positive** yield only and credits the
result to the pull-based `totalFeesPerToken[token]` bucket. No fee is taken when realized
yield is zero. The fee recipient pulls the accumulated balance with
`EscrowVault.withdrawFees(token)` (CEI-safe, `nonReentrant`):

- `ROLE_FEE_RECIPIENT` only.
- Fully pull-based — the vault never pushes fees to the treasury.
- The full `totalFeesPerToken[token]` bucket is transferred and zeroed atomically.

### 3.3 Bond protocol fees: `claimBondProtocolFees`

```
Function: claimBondProtocolFees(token, recipient)
Ledger: BaseEscrow.claimableBondProtocolFees[token][recipient]
Caller: Protocol fee address (must equal msg.sender)
```

When an appeal bond is processed during escalation, the protocol fee component
(`result.protocolFeeAmount`) is credited to `claimableBondProtocolFees[token][feeAddress]`
rather than being transferred directly. The fee address claims via
`claimBondProtocolFees`:

- `recipient` must equal `msg.sender` (cannot claim on behalf of another address).
- Supports both ERC20 tokens and native ETH (`token == address(0)`).
- CEI pattern: ledger zeroed before `safeTransfer` / `.call{value}`.
- On ETH transfer failure: state is restored and the call reverts (no silent loss).

---

## 4. Resolver withdrawals

### 4.1 Dispute payment: `claimPayment` (V1 incentive module)

```
Function: claimPayment(workflowId, escrowContract, token)
Ledger: ResolverIncentiveModuleV1.claimablePayments[escrow][workflowId][address]
Caller: Resolver who participated in the dispute
```

After a dispute is resolved and `calculatePayments` has been called by the resolution
module, each resolver's share is credited to `claimablePayments`. Resolvers claim via
`claimPayment`:

1. Verifies `paymentsCalculated[escrowContract][workflowId]` is true.
2. Verifies `token` matches the enforced single payout token for that dispute
   (`payoutToken[escrow][workflowId]`). This prevents a resolver from claiming in a
   different token than what was recorded.
3. Deletes `claimablePayments[...][msg.sender]` before transfer (CEI).
4. `safeTransfer` to the caller.

**Why single-token enforcement?** Payment sources (resolver fees, forfeited bonds) are
accumulated across multiple events during a dispute. Enforcing a single payout token
prevents inconsistencies if governance changes the fee token between dispute creation and
resolution.

### 4.2 Appeal bond refund: `claimBondRefund` (V2 incentive module)

```
Function: claimBondRefund(workflowId, escrowContract, token)
Ledger: ResolverIncentiveModuleV2.claimableBondRefunds[escrow][workflowId][address]
Caller: Party who posted the appeal bond
```

When an escalation succeeds (the resolution is reversed on appeal), the escalator's bond
is refunded rather than forfeited. The refund is not pushed directly because the
escalator may be a contract. Instead, `_refundBond` credits `claimableBondRefunds` and
the escalator calls `claimBondRefund`:

- Supports both ERC20 and native ETH bonds.
- ETH path: `.call{value: amount}("")` with explicit revert on failure.
- ERC20 path: `safeTransfer`.
- The bond record's `escalatedBy` field determines who receives the refund — not the
  depositor. This matters when the bond depositor is an intermediary (e.g., a
  `BondCollector` contract), but the user who triggered the escalation is the intended
  recipient.

---

## 5. Excess ETH refund: `claimExcessEthRefund`

```
Function: claimExcessEthRefund()
Ledger: BaseEscrow.claimableExcessEthRefunds[msg.sender]
Caller: Any user who posted an ETH bond with excess
```

When a user posts an ETH appeal bond and sends more ETH than `result.bondAmount`, the
excess is credited to `claimableExcessEthRefunds[msg.sender]`:

```solidity
if (result.bondToken == address(0) && msg.value > result.bondAmount) {
    claimableExcessEthRefunds[_msgSender()] += msg.value - result.bondAmount;
}
```

The user retrieves it via `claimExcessEthRefund()`:

- ETH `.call{value}` with state restore on failure.
- Reverts with `NoClaimableBondProtocolFee` (reusing error type) if balance is zero.

---

## 6. Balance safety invariant

`BaseEscrow` maintains a per-token accounting counter:

```solidity
mapping(address => uint256) public totalClaimableAssets;
```

- **Incremented** in `_creditClaimable` by `amount`.
- **Decremented** in `withdrawEscrow` by `amount`.

The intended invariant is:

```
IERC20(token).balanceOf(address(this)) >= totalClaimableAssets[token]
```

This ensures the contract can always honour all outstanding claimable entitlements. The
check is enforced at credit time in `_creditClaimable` when yield has been received (i.e.,
`amount > principalExpected` — the module reported more than was deposited):

```solidity
if (amount > principalExpected) {
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (bal < amount) revert EscrowInsufficientBalance();
}
```

For standard principal credits (no yield), the invariant is maintained structurally: the
principal was pulled from the creator at escrow creation and is held in the contract
throughout the escrow lifetime.

**Note:** `totalClaimableAssets` tracks principal and yield claimable at the `BaseEscrow`
level only. Resolver payments (`ResolverIncentiveModuleV1`), bond refunds
(`ResolverIncentiveModuleV2`), insurance pool balances (`InsurancePoolVault`), and yield
protocol fees (`EscrowVault.totalFeesPerToken` bucket) are each self-contained in their
own contracts with their own token balances.

---

## 7. Insurance pool withdrawals

The `InsurancePoolVault` holds slashed funds tagged by source (timeout, reversal, fraud).
Withdrawals from it are deliberately restricted and follow a two-step slow-lane process.

### 7.1 Proposed payout (normal path)

```
Functions: proposePayout(to, amount, workflowId, escrowContract, reason)
           executePayout(payoutId)
           cancelPayout(payoutId)
Required role: ROLE_TIMELOCK (for all three)
Delay: 7 days (SLOW_DELAY)
```

**Proposing:**

1. Verifies `sourceBalance.total >= amount`.
2. Creates a `PendingPayout{ to, amount, workflowId, reason, eta: now + 7 days }`.
3. Emits `InsurancePayoutProposed` — publicly observable before execution.

**Executing (after 7 days):**

1. Checks `block.timestamp >= payout.eta`.
2. Verifies funds are still sufficient.
3. Deletes the proposal (CEI), reduces `sourceBalance` proportionally across source tags,
   then transfers via `safeTransfer`.

**Cancelling:** The timelock may cancel any pending proposal before execution. No funds
move.

The 7-day slow lane gives the community and governance observers time to detect and veto
inappropriate payouts before they execute. `InsurancePoolVault` itself holds no veto
mechanism — it relies on the upstream governance timelock to block the `executePayout`
call if the community disagrees.

### 7.2 Direct withdrawal (emergency override — disabled by default)

```
Function: withdraw(to, amount, workflowId)
Required role: ROLE_TIMELOCK
Gate: withdrawalsEnabled == true
```

A direct, unlocked withdrawal path exists but is disabled at deployment
(`withdrawalsEnabled = false`). Enabling it requires a governance transaction
(`setWithdrawalsEnabled(true)`, also gated to `ROLE_TIMELOCK`). Even when enabled, it is
not subject to the 7-day delay — it is an emergency bypass intended for situations where
the slow-lane proposal mechanism is unavailable.

This path is intentionally narrow:

- Cannot be called without `ROLE_TIMELOCK`.
- Disabled by default; enabling it is a public, on-chain governance action.
- Proportional balance reduction across source tags is still applied.

---

## 8. Emergency recovery paths

### 8.1 Aave position unwind — `GuardianOps.emergencyUnwindAavePosition`

```
Caller: ROLE_GUARDIAN
Target: BaseEscrow + AaveYieldModule
```

If the `AaveYieldModule` becomes inaccessible or holds funds that cannot be unwound
through the normal `unwindToEscrow` / `emergencyUnwind` flow, the guardian can call
`emergencyUnwindAavePosition(...)`. This drives `IYieldModule.emergencyUnwind` (or
`emergencyUnwindForEscrow`) directly, bypassing the normal settlement flow.

The guardian cannot direct recovered funds — they are returned to the escrow contract for
normal claimable settlement. The guardian cannot divert them to an arbitrary address.
The function is rate-limited at the `GuardianOps` level to prevent abuse.

### 8.2 Module token recovery — `AaveYieldModule.recoverTokens` / `recoverETH`

```
Caller: ROLE_TIMELOCK (on AaveYieldModule)
```

As a last resort when an Aave position cannot be unwound normally (e.g. Aave withdraw is
unavailable), the timelock can recover stranded funds directly from the module:

- `recoverTokens(token, to, amount)` — recovers ERC-20 where `token` is registered in
  `recoverableAssets`.
- `recoverETH(to)` — recovers stranded native ETH.

Recovery is scoped: only the configured underlying tokens and their aTokens are registered
in `recoverableAssets`, so the module cannot be drained of assets it never held for an
escrow. This is a timelock-gated, guardian-protective last resort (not the normal path).
The settlement flow itself always attempts `unwindToEscrow` → `emergencyUnwind` and only
fails open with `YieldUnwindFailed` (in `EscrowYield`) if both are unavailable — manual
recovery is never the default.

---

## 9. Withdrawal path quick reference

| What is being withdrawn | Function | Contract | Who can call | Delay / gate |
|------------------------|----------|---------|-------------|-------------|
| Escrow principal + yield after settlement | `withdrawEscrow(workflowId)` | `BaseEscrow` | Entitled party | None — terminal state required |
| Bond protocol fees | `claimBondProtocolFees(token, recipient)` | `BaseEscrow` | Fee recipient | None |
| Excess ETH from bond posting | `claimExcessEthRefund()` | `BaseEscrow` | Bond poster | None |
| Resolver dispute payment | `claimPayment(workflowId, escrow, token)` | `ResolverIncentiveModuleV1` | Resolver | Payments must be calculated |
| Appeal bond refund (V2) | `claimBondRefund(workflowId, escrow, token)` | `ResolverIncentiveModuleV2` | Bond poster | Bond must be marked refundable |
| Yield protocol fee | `withdrawFees(token)` | `EscrowVault` | Fee recipient (`ROLE_FEE_RECIPIENT`) | None |
| Insurance payout (normal) | `proposePayout` → `executePayout` | `InsurancePoolVault` | `ROLE_TIMELOCK` | 7-day slow lane |
| Insurance payout (emergency) | `withdraw(to, amount, workflowId)` | `InsurancePoolVault` | `ROLE_TIMELOCK` | `withdrawalsEnabled` flag (off by default) |
| Stranded Aave yield | `emergencyUnwindAavePosition(...)` | `GuardianOps` | `ROLE_GUARDIAN` | Rate-limited; proceeds go to escrow |
| Stranded funds in Aave yield module | `recoverTokens(token, to, amount)` / `recoverETH(to)` | `AaveYieldModule` | `ROLE_TIMELOCK` | Scoped to `recoverableAssets`; last resort |

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against `AaveYieldModule.sol`, `EscrowVault.sol`, `withdrawFees()`, and Aave unwind paths. CEI ordering fix for `withdrawFees` verified against `SECURITY_FIXES_COMPLETED.md`. Aave slippage protection verified against `AaveYieldModule.sol`. Simulation does not yet cover Aave emergency unwind scenarios under stress — needs follow-up. |
