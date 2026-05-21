# Prepayments

> **Scope:** This document describes how Sew Protocol implements the prepayment pattern:
> a transaction where a buyer pays upfront and funds are held until the buyer confirms
> delivery. It explains the protocol mechanics that make this safe for both parties,
> the configurable parameters that adapt it to different commercial contexts, and the
> failure modes and their protections.
>
> **Sources:** `contracts/core/BaseEscrow.sol` (`createEscrow`, `release`, `raiseDispute`,
> `senderCancel`, `recipientCancel`, `automateTimedActions`),
> `contracts/ops/CreateOps.sol`, `contracts/ops/SettlementOps.sol`,
> `contracts/modules/DefaultReleaseStrategy.sol`,
> `contracts/modules/DefaultCancellationStrategy.sol`,
> `contracts/modules/BuyerOnlyCancellationStrategy.sol`,
> `contracts/types/EscrowTypes.sol` (`EscrowSettings`, `EscrowState`),
> `contracts/libraries/SettingsValidationLibrary.sol`.

---

## 1. What is a prepayment

In a conventional prepayment, a buyer transfers money to a seller before receiving
goods or services. The seller then fulfils the obligation. The buyer has no recourse if
the seller fails to deliver — the money is gone.

Sew Protocol implements a **conditional prepayment**: the buyer's funds are locked in
an on-chain escrow at the moment of payment. The seller can see the funds are committed
but cannot access them until the buyer approves delivery (or an agreed timer expires).
If delivery fails, the funds can be returned.

This preserves the seller's certainty that payment exists — funds are provably locked,
not just promised — while preserving the buyer's ability to withhold approval until
satisfied.

---

## 2. Actors and responsibilities

| Actor | Role in a prepayment |
|-------|---------------------|
| **Sender (`et.from`)** | The buyer. Deposits funds and holds the release key. |
| **Recipient (`et.to`)** | The seller. Fulfils the obligation; receives funds on approval. |
| **Dispute resolver** | Arbitrates if delivery is disputed. Assigned at creation from the resolution module or per-escrow `customResolver`. |
| **`releaseAddress`** | An optional third address — e.g. an oracle, a multisig, or a delivery confirmation service — that can trigger release in place of the buyer. |

---

## 3. The basic flow

```
Buyer                             Contract                       Seller
  │                                   │                             │
  │── createEscrow(token, seller,  ──►│                             │
  │       amount, settings)           │   Funds locked in PENDING   │
  │                                   │──────────────────────────►  │
  │                                   │   (seller can see commitment)│
  │                                   │                             │
  │   (seller delivers goods/service) │                             │
  │                                   │                             │
  │── release(workflowId) ───────────►│                             │
  │                                   │   State: PENDING → RELEASED │
  │                                   │──────────────────────────►  │
  │                                   │   Funds now claimable       │
  │                                   │                             │
  │                                   │◄── withdrawEscrow() ───────  │
```

1. **`createEscrow`** — buyer calls this. Tokens are pulled from the buyer
   immediately (`_pullTokens`). The protocol fee is deducted, and the remaining
   `amountAfterFee` is locked in the contract. The escrow enters `PENDING` state.
2. **Delivery window** — the seller performs their obligation. The funds are held;
   neither party can unilaterally move them during this period.
3. **`release`** — buyer confirms delivery. Funds become claimable by the seller.
4. **`withdrawEscrow`** — seller pulls their entitlement.

---

## 4. Configuration options at creation

All configuration is supplied via `EscrowSettings` at the time of `createEscrow` and
is immutable for that escrow once set. Governance changes to contract-level defaults do
not affect in-flight prepayments.

### 4.1 Delegated release address

```solidity
EscrowSettings {
    releaseAddress: 0xSomeOracleOrMultisig,
    ...
}
```

By default, only the buyer (`et.from`) can call `release`. Setting `releaseAddress`
grants an additional address the power to release. This is useful when:

- A **delivery oracle** or logistics platform confirms receipt and triggers release
  automatically.
- A **multisig** requires multiple signers to approve payment, not just the buyer's
  single EOA.
- A **backend escrow agent** (e.g., a marketplace smart contract) controls release on
  behalf of the buyer, governed by its own logic.

The `DefaultReleaseStrategy` allows release by the buyer OR the `releaseAddress`:

```solidity
if (caller == sender || (releaseAddress != address(0) && caller == releaseAddress)) {
    return (true, REASON_ALLOWED);
}
```

### 4.2 Auto-release timer

```solidity
EscrowSettings {
    autoReleaseTime: block.timestamp + 14 days,
    ...
}
```

If the buyer sets `autoReleaseTime`, the seller can trigger `automateTimedActions`
(or the buyer can) after that timestamp and receive payment automatically without
requiring the buyer to take action. This prevents a buyer from silently blocking payment
by doing nothing — a common failure mode in manual prepayment flows.

Auto-release is appropriate when:

- The prepayment is for a subscription or retainer where non-response implies acceptance.
- The buyer has a fixed review window (e.g., 14 days to inspect and reject; silence is
  approval).
- The service is intangible and non-delivery would be immediately obvious (e.g.,
  software API access).

**Constraint:** `autoReleaseTime` and `autoCancelTime` cannot both be set on the same
escrow. Only one automatic outcome may be configured.

### 4.3 Auto-cancel timer

```solidity
EscrowSettings {
    autoCancelTime: block.timestamp + 30 days,
    ...
}
```

If the buyer sets `autoCancelTime`, the escrow refunds the buyer automatically after
that timestamp if the buyer has not released. This is the buyer's protection against
a seller who takes payment but never delivers and never communicates.

Auto-cancel is appropriate when:

- The seller is expected to deliver within a known deadline (e.g., a project milestone).
- The buyer needs certainty that funds are not locked indefinitely if the seller
  disappears.
- The prepayment covers a specific time-boxed service.

### 4.4 Custom dispute resolver

```solidity
EscrowSettings {
    customResolver: 0xKnownMediatorOrArbitrationContract,
    ...
}
```

For high-value or specialist prepayments, the buyer and seller may agree upfront on
a specific resolver rather than using the protocol default. This could be:

- An industry-specific arbitration service.
- A shared escrow agent both parties already trust (e.g., their bank or broker).
- Kleros, wired directly as the per-escrow resolver for disputes that are expected to
  go to decentralised arbitration.

Once set at creation, the `customResolver` is immutable for that escrow. Governance
cannot override it.

### 4.5 Yield on held funds

```solidity
EscrowSettings {
    yieldPreset: YieldPreset.TO_SENDER,
    ...
}
```

While funds are locked, they can optionally earn yield via the Aave integration.
Setting `YieldPreset.TO_SENDER` credits any accrued yield to the buyer when the escrow
is settled, regardless of whether it settles as a release or refund. This means:

- The buyer is compensated for the opportunity cost of locking capital.
- The seller receives only the agreed principal — no yield is diverted to them under
  `TO_SENDER`.

Yield accrues passively; the buyer does not need to take any action during the lock
period to benefit.

---

## 5. Cancellation mechanics

### 5.1 Mutual cancellation (default)

With `DefaultCancellationStrategy`, both parties must consent to cancel:

1. Either party calls `senderCancel()` or `recipientCancel()`, which sets their
   `AGREE_TO_CANCEL` status flag.
2. When both flags are set, `_cancelAndRefund` executes automatically on the second
   call — no separate step required.

This protects the seller from a unilateral buyer withdrawal mid-delivery, and protects
the buyer from being forced to accept delivery they have not approved.

### 5.2 Buyer-only cancellation (`BuyerOnlyCancellationStrategy`)

If the escrow uses `BuyerOnlyCancellationStrategy`, the **recipient** (seller) can
cancel without the buyer's consent at any time. This is appropriate when:

- The seller decides they cannot fulfil the order (self-service cancellation).
- The platform needs to refund a buyer for a failed delivery without requiring the
  buyer to be online.

This strategy is misnamed relative to the "buyer/seller" framing above — the recipient
(`et.to`) in this contract is the seller in a prepayment, and the strategy grants the
seller unilateral cancel rights, not the buyer.

---

## 6. Dispute path

If the seller claims delivery but the buyer disagrees:

1. Either party calls `raiseDispute(workflowId)`. The escrow moves to `DISPUTED`.
   Funds remain locked.
2. The assigned resolver reviews evidence (provided off-chain or through an evidence
   module).
3. The resolver calls `releaseAsDisputeResolver` (funds go to seller) or
   `cancelAsDisputeResolver` (funds refunded to buyer).
4. If the resolution is non-final (escalation rounds remain), a `PendingSettlement` is
   created with an appeal window.
5. Either party may escalate during the appeal window, paying an appeal bond. Escalation
   advances to the next resolver level.
6. At the final round (e.g., Kleros), the decision executes immediately with no further
   appeal.

Anti-spam guards apply before a dispute can be raised:

- Escrow must meet the minimum value threshold (`minDisputeEscrowValue`).
- The sender's per-day dispute count must not exceed `maxDisputesPerSenderPerDay`.

---

## 7. Failure mode protections

| Failure mode | Protection mechanism |
|--------------|---------------------|
| Buyer pays and seller disappears | `autoCancelTime` refunds the buyer automatically after the deadline |
| Seller delivers but buyer withholds release indefinitely | `autoReleaseTime` releases funds automatically after the review period |
| Buyer and seller disagree on delivery quality | `raiseDispute` → resolver → escalation → Kleros |
| Seller delivers partial work; buyer wants partial payment | `proposeSplit` / `acceptSplit` — mutual agreement on any split of principal |
| Buyer loses access to their wallet | `releaseAddress` on a multisig or recovery agent can release |
| Resolver is slow or unresponsive | `resolveDisputeByTimeout` refunds buyer after `maxDisputeDuration` |
| Smart contract exploit captures yield module | `emergencyUnwind` via guardian returns principal to escrow; settlement proceeds with principal only |

---

## 8. Example configurations

The following configurations illustrate how `EscrowSettings` adapts to common prepayment
contexts. All values are illustrative.

### 8.1 Software project milestone (medium trust)

The buyer pays for a defined deliverable. The buyer has 30 days to review. If no action
is taken, payment releases automatically.

```solidity
EscrowSettings({
    customResolver: address(0),          // Use protocol default resolver
    releaseAddress: address(0),          // Only buyer can release
    yieldPreset: YieldPreset.TO_SENDER,  // Buyer earns yield during hold
    autoReleaseTime: block.timestamp + 30 days,
    autoCancelTime: 0                    // No auto-cancel (buyer has 30 days)
})
```

### 8.2 Physical goods with delivery oracle (high automation)

The buyer pays for goods. A logistics oracle confirms on-chain delivery and triggers
release. If the oracle does not confirm within 60 days, funds auto-cancel.

```solidity
EscrowSettings({
    customResolver: address(0xKlerosCourt),  // Kleros for delivery disputes
    releaseAddress: address(0xLogisticsOracle),
    yieldPreset: YieldPreset.OFF,
    autoReleaseTime: 0,
    autoCancelTime: block.timestamp + 60 days
})
```

### 8.3 Freelancer retainer (low trust, high buyer protection)

The buyer pre-funds a month of work. The seller can self-cancel if they need to. The
buyer has a 7-day review window after the month ends.

```solidity
EscrowSettings({
    customResolver: address(0xKnownFreelancePlatform),
    releaseAddress: address(0),
    yieldPreset: YieldPreset.TO_SENDER,
    autoReleaseTime: block.timestamp + 37 days,  // 30-day work + 7-day review
    autoCancelTime: 0
})
// Cancellation strategy: BuyerOnlyCancellationStrategy (seller can self-cancel)
```

### 8.4 B2B invoice with agreed terms (known counterparties)

Both parties have an existing relationship. Mutual cancellation is acceptable, and
the dispute resolver is a known commercial arbitrator they both agreed to in their
off-chain contract.

```solidity
EscrowSettings({
    customResolver: address(0xArbitrationService),
    releaseAddress: address(0xBuyersAccountingBot),
    yieldPreset: YieldPreset.TO_SENDER,
    autoReleaseTime: block.timestamp + 90 days,
    autoCancelTime: 0
})
// Cancellation strategy: DefaultCancellationStrategy (mutual consent required)
```

---

## 9. What the protocol does not enforce

Sew Protocol enforces fund custody, conditional release, and dispute escalation. It
does not enforce:

- **Delivery itself.** The protocol cannot verify that goods or services were actually
  delivered. The release key (buyer approval or `releaseAddress`) is the only on-chain
  signal of acceptance. Off-chain delivery verification, if needed, must be wired
  through the `releaseAddress` mechanism.
- **The content of the agreement.** What the seller is obligated to deliver is an
  off-chain matter. The escrow holds the funds and enforces the payment outcome; it does
  not interpret contract terms.
- **Identity or KYC.** Either party can be any address. Identity verification, if
  required, must be handled by the integrating application.
- **Partial milestone releases.** A single escrow has one principal amount. Multi-
  milestone projects require either multiple escrows (one per milestone) or use of the
  `proposeSplit` mechanism at the point of partial completion.

---

## Evidence

| Field | Value |
|---|---|
| **Contracts** | `sew-protocol` @ `62fce3a` |
| **Simulation** | `sew-simulation` @ `5b33486` |
| **Generated / reviewed** | 2026-05-21 |
| **Verification status** | Manually checked against `BaseEscrow.sol` prepayment and deposit flows. Prepayment accounting verified against `_updateEscrowBalance()` and underflow fix in `SECURITY_FIXES_COMPLETED.md`. Incentive distribution logic verified against `IncentiveModuleV1.sol`. Prepayment-under-dispute edge cases partially covered in deterministic scenarios — needs follow-up. |
