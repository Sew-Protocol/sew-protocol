# Sew Protocol — Payment Flow Overview

*For review by payments counsel. Simplified for legal purposes; dispute resolution details are summarised.*

---

## What is SEW Protocol?

**Sew Protocol** is a smart contract system for on-chain escrow payments. Funds are locked on-chain until agreed conditions are met — neither party can unilaterally access funds mid-flow. It operates on Base (an Ethereum L2).

---

## Key Actors

| Actor | Role |
|---|---|
| **Sender** | Initiates the payment; funds the escrow |
| **Recipient** | Receives funds upon confirmed delivery |
| **Dispute Resolver** | Arbitrates disagreements (configurable per-escrow: custom address or protocol default) |
| **Protocol / Governance** | Collects fees; controls upgrades to shared modules |

---

## Payment States

```mermaid
stateDiagram-v2
    direction LR

    [*] --> PENDING : createEscrow()\nfunds locked

    PENDING --> RELEASED : sender releases\nor auto-release timer
    PENDING --> REFUNDED : mutual cancel\nor auto-cancel timer
    PENDING --> DISPUTED : either party\nraises dispute

    DISPUTED --> PENDING_SETTLEMENT : resolver decides\n(release or refund)
    DISPUTED --> REFUNDED : unresolved after 90 days\n(auto-cancel)

    PENDING_SETTLEMENT --> RELEASED : resolver said release\n(after 2-day appeal window)
    PENDING_SETTLEMENT --> REFUNDED : resolver said refund\n(after 2-day appeal window)

    RELEASED --> [*]
    REFUNDED --> [*]
```

---

## End-to-End Payment Flow

```mermaid
flowchart TD
    START([Sender initiates payment]) --> CREATE

    CREATE["<b>createEscrow()</b>\nSender deposits tokens\nProtocol fee deducted (0–2%)\nSettings locked permanently"]
    CREATE --> PENDING

    PENDING(["<b>PENDING</b>\nFunds locked in escrow\n(optionally earning yield on Aave)"])

    PENDING -->|"Sender calls release()"| REL_PATH
    PENDING -->|"Both parties agree to cancel"| REF_PATH
    PENDING -->|"Either party raises dispute"| DISPUTE

    REL_PATH["<b>PATH A — RELEASE</b>\nSender confirms delivery\nor auto-release timer fires"]
    REL_PATH --> RELEASED

    REF_PATH["<b>PATH B — CANCELLATION</b>\nMutual consent, or\nauto-cancel timer fires"]
    REF_PATH --> REFUNDED

    DISPUTE["<b>PATH C — DISPUTE</b>\nState: DISPUTED\nResolver reviews case"]
    DISPUTE --> RESOLUTION

    RESOLUTION["Resolver issues decision\n(release or refund)\n<i>2-day appeal window begins</i>"]
    RESOLUTION --> PENDING_SETTLE

    PENDING_SETTLE(["<b>PENDING SETTLEMENT</b>\nAppeal window (2 days)"])
    PENDING_SETTLE -->|"Appeal window expires\nResolver said: release"| RELEASED
    PENDING_SETTLE -->|"Appeal window expires\nResolver said: refund"| REFUNDED
    DISPUTE -->|"Unresolved after 90 days"| REFUNDED

    RELEASED(["<b>RELEASED ✓</b>\nFunds transferred to Recipient\n(principal + yield if applicable)"])
    REFUNDED(["<b>REFUNDED ✓</b>\nFunds returned to Sender\n(principal + yield if applicable)"])

    RELEASED --> PROTO_FEE_R["Protocol takes 30% of yield\n(if yield was enabled)"]
    REFUNDED --> PROTO_FEE_F["Protocol takes 30% of yield\n(if yield was enabled)"]

    style PENDING fill:#f5a623,color:#000
    style PENDING_SETTLE fill:#f5a623,color:#000
    style RELEASED fill:#27ae60,color:#fff
    style REFUNDED fill:#2980b9,color:#fff
    style DISPUTE fill:#e74c3c,color:#fff
    style PROTO_FEE_R fill:#8e44ad,color:#fff
    style PROTO_FEE_F fill:#8e44ad,color:#fff
```

---

## Fund Flow Summary

```
 Sender deposits:    [   AMOUNT   ]
                     [  fee (≤2%) ] ──► Protocol fee wallet
                     [ amountNet  ] ──► Held in escrow
                                              │
                              ┌───────────────┴────────────────┐
                              │  IF YIELD ENABLED (optional)   │
                              │  amountNet deposited to Aave   │
                              │  → interest accrues            │
                              └───────────────┬────────────────┘
                                              │
                              On finalization (release or refund):
                                              │
                         ┌────────────────────┴────────────────────┐
                         │                                         │
                  [RELEASED]                               [REFUNDED]
                         │                                         │
             Principal ──────────────────────────────► Recipient  │
             Yield net* ──────────────────────────────► Recipient  │
             Yield fee* (30%) ──────────────────────► Protocol     │
                                             Principal ──────────► Sender
                                             Yield net* ─────────► Sender
                                             Yield fee* (30%) ──► Protocol

             * only if yield was enabled on this escrow
```

---

## Key Protocol Parameters

| Parameter | Default | Notes |
|---|---|---|
| Escrow creation fee | ~0.2% (configurable 0–2%) | Deducted at creation |
| Yield protocol fee | 30% of yield generated | Only if yield enabled |
| Dispute appeal window | 2 days | After resolver decides, before settlement executes |
| Auto dispute cancellation | 90 days | If dispute unresolved, auto-refunds sender |
| Supported tokens | Any ERC20 | USDC, USDT, DAI, WETH, etc. |
| Yield source | Aave (optional) | Only for Aave-supported tokens |

---

## What is Immutable vs. Configurable

**Immutable per escrow (locked at creation):**
- Which token, amount, sender, recipient
- Which dispute resolver applies
- Whether yield is enabled and the yield fee rate
- Which release strategy and cancellation strategy apply

**Configurable by governance (affects only new escrows):**
- Default fee rates
- Default modules (yield, resolution, distribution)
- Protocol fee wallet address

**Governance changes never affect existing escrows.**

---

*This document is a simplified overview. The protocol is non-custodial; funds are held in audited smart contracts, not by any centralised party.*
