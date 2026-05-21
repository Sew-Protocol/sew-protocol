# Third-Party Appeal Bonds

**Status:** Simulation-modeled (Phase L); contract infrastructure partially in place; `challengeResolution()` entry point pending implementation.

---

## 1. Overview

Standard dispute escalation in Sew Protocol is restricted to the losing party — only the party who received an unfavourable decision may appeal it to the next round. This is intentional: it prevents winners from reopening settled disputes and ensures escalation costs fall on the party that disagrees with the outcome.

Third-party appeal bonds extend this model. A separate entry point, `challengeResolution`, allows **any address** — not just a dispute participant — to challenge a provisional decision by posting a bond. The challenger is unrelated to the escrow; they are acting as a watchdog or a sponsor.

The two paths are structurally identical from the protocol's perspective: both post a bond, escalate to the next round, and subject the bond to the same outcome-conditional distribution. The difference is who can act.

---

## 2. How it works

### 2.1 Triggering conditions

`challengeResolution(workflowId)` may be called by any address when all of the following hold:

- The dispute is in state `DISPUTED`.
- A provisional decision exists — a `PendingSettlement` record is present.
- The appeal window is still open (`block.timestamp < appealDeadline`).
- The dispute has not yet reached the final round (`MAX_ROUND`).
- The caller's per-address cooldown has elapsed (1-day minimum between challenges from the same address).

### 2.2 Bond requirement

The challenge bond is sized as a fraction of the escrow amount:

```
challengeBond = escrowAmountAfterFee × challengeBondBps / 10,000
```

`challengeBondBps` is a governance-controlled parameter in the module snapshot. It is distinct from the standard escalation cost curve — challenge bonds can be calibrated independently to price out spam without deterring legitimate watchdog activity.

A per-address bond multiplier applies when the same address has previously challenged:

```
effectiveBond = challengeBond × (1.0 + 0.1 × priorChallengesThisWindow)
```

This scales challenge cost for repeat callers without affecting first-time challengers.

### 2.3 What happens on escalation

When `challengeResolution` succeeds:

1. The pending settlement is cleared.
2. The dispute level increments (`currentLevel + 1`).
3. A new resolver is assigned at the higher level.
4. The challenger's bond is recorded in `bondDepositorAtRound` — attributed to the challenger's address, not to either dispute party.
5. The new resolver proceeds as normal.

The challenger is tracked in `challengers[workflowId][level]`. At finalisation, the bond is distributed based on the next round's outcome.

### 2.4 Bond outcome on finalisation

| Outcome | What happens to the challenge bond |
|---|---|
| Challenge succeeds (decision overturned at next round) | Bond refunded to challenger + bounty paid from resolver slash proceeds |
| Challenge fails (original decision upheld) | Bond forfeited to the resolver whose decision was upheld |

The bounty is a fraction of the slashed resolver's funds (`challengeBountyBps`), split equally from the insurance and protocol shares of the slash distribution. If reversal slashing is disabled (current DR v3 default), no bounty is paid — the bond refund alone is the reward.

This structure means a successful challenge is not merely risk-neutral for the challenger. If reversal slashing is active, a correct challenge generates a net positive return: bond back plus a share of the resolver's penalty.

---

## 3. Contract infrastructure

The contract layer already separates `depositor` from `escalatedBy` in `AppealBondRecord` (`ResolverIncentiveModuleV2`):

```solidity
struct AppealBondRecord {
    address depositor;    // Who funded the bond — refund goes here
    address escalatedBy;  // Who triggered the escalation
    uint256 amount;
    address token;
    ...
}
```

For standard escalation, `depositor == escalatedBy`. For third-party challenges, `depositor` is the challenger and `escalatedBy` records the triggering address (which may also be the challenger, or a relayer acting on their behalf).

`BondCollector.collectBond` already accepts both parameters and passes them through to `recordAppealBond`. The accounting correctly routes refunds to `depositor`, not `escalatedBy`.

**What is not yet implemented:** A standalone `challengeResolution(workflowId)` function in `BaseEscrow` that opens this path to addresses other than the losing party. The current `escalateDispute` validates the caller against the escrow's `from`/`to` addresses before proceeding.

---

## 4. Anti-abuse safeguards

Third-party challenges introduce a griefing surface: a malicious actor could repeatedly challenge correct decisions to delay settlement, even while losing their bond each time. Three layers mitigate this:

**Bond forfeiture.** Each failed challenge costs the challenger the full bond amount, which flows to the resolver whose decision was upheld. The challenger receives nothing.

**Per-address cooldown.** A minimum 1-day window between challenges from the same address prevents rapid-fire griefing. The cooldown is checked against `lastEscalationBlockTimePerAddr[caller]`.

**Bond scaling.** Each successive challenge from the same address within the rolling window scales the required bond by 1.1×. A challenger who has escalated 3 times in the window must post 1.3× the base challenge bond. This compounds cost for systematic griefing while leaving one-off legitimate challenges unaffected.

Together these ensure that griefing via third-party challenges requires sustained capital expenditure, with all forfeited bonds flowing to honest resolvers.

---

## 5. Benefits

### 5.1 Access to justice

The standard model has a structural weakness: if the losing party cannot afford the appeal bond — or if they are operating under financial duress — the incorrect decision stands unchallenged regardless of its merit. Third-party bonds break this dependency. A party who believes a decision is wrong but cannot self-fund the escalation can be sponsored by:

- A platform operator acting to protect their users.
- An insurance contract that has underwritten the dispute outcome.
- A legal aid or arbitration watchdog service.
- A DAO or community treasury acting in the public interest.
- Any participant who simply observed an incorrect decision and wants to correct it.

The bond economics make this rational: the sponsor risks the bond, but recovers it (plus bounty, when slashing is active) if they were right.

### 5.2 Resolver accountability amplification

Appointed resolvers currently face accountability through two channels: reputation scoring (EMA-based) and, in DR v3, bond slashing for reversal. Both require escalation to occur. If the losing party is dissuaded from escalating — by cost, by coordination failure, or by adversarial pressure — accountability cannot be enforced.

Third-party challenges mean resolvers cannot rely on the losing party's inability or unwillingness to escalate. Any observer can enforce accountability. A resolver who repeatedly issues biased decisions faces escalation risk from the broader ecosystem, not just from the parties directly harmed.

This is particularly important in adversarial scenarios. Simulation scenario S42 (`resolver-buyer-bribery-loop`) demonstrates: a buyer and resolver collude; the buyer is happy with the (incorrect) outcome and will not escalate; the seller is the harmed party but may not have the resources or coordination to act. A third-party challenger observing the bribery pattern can trigger escalation, reverse the decision, and recover their bond from the resolver's slash proceeds.

### 5.3 Watchers and protocol integrity

The third-party challenge mechanism creates a natural niche for protocol-integrity watchers — participants with no stake in any individual escrow, but with an interest in the health of the resolver pool overall. Such watchers can:

- Monitor the on-chain decision log for statistically anomalous reversal patterns.
- Identify resolvers operating below acceptable quality thresholds.
- Post challenges on specific decisions to generate a reversal signal, even when the direct parties have moved on.

This is structurally similar to the role of liquidation bots in lending protocols: no direct stake in any single position, but a profitable and valuable role in maintaining system-level health.

### 5.4 Platform and insurance integration

Platforms built on Sew Protocol (marketplaces, escrow-as-a-service providers, B2B settlement rails) can embed third-party challenge logic directly into their service contracts:

- A smart contract can automatically challenge any dispute outcome that diverges from an off-chain signal (e.g., a delivery oracle, a reputation system, a signed statement from a logistics provider).
- An insurance contract covering escrow outcomes can automatically contest decisions that would trigger a payout, routing the challenge through the dispute pipeline rather than requiring manual intervention.
- A platform governance module can fund challenges as a service to users without requiring users to hold or approve bond tokens themselves.

These integrations are possible precisely because `challengeResolution` does not require the caller to be a party to the escrow. The challenge interface is public and permissionless.

---

## 6. Simulation coverage

The `challenge-resolution` function is implemented in `protocols/sew/resolution.clj` and tested under the following deterministic scenarios:

| Scenario | What is validated |
|---|---|
| `s41-dr3-reversal-slash-disabled` | Third-party challenger triggers escalation; L1 reverses L0; reversal-slash path fires correctly with `slash-bps = 0` |
| `s42-resolver-buyer-bribery-loop` | Seller challenges a bribe-biased L0 decision; L1 honest reversal; funds correctly released to seller |

The `challenge-window-duration`, `challenge-bond-bps`, and `challenge-bounty-bps` parameters are part of the protocol snapshot (`types/make-protocol-params`) and are exercised across fixture suites.

---

## 7. Implementation status and open items

| Item | Status |
|---|---|
| `depositor`/`escalatedBy` separation in `ResolverIncentiveModuleV2` | Implemented |
| `BondCollector.collectBond` supporting distinct depositor | Implemented |
| Simulation model (`challenge-resolution` in `resolution.clj`) | Implemented (Phase L) |
| `challengeResolution(workflowId)` entry point in `BaseEscrow` | **Not yet implemented** |
| Caller validation bypass for third-party callers in `DisputeOps` | **Not yet implemented** |
| Per-address cooldown enforcement on `challengeResolution` path | Simulation only |
| Bounty distribution when reversal slashing is active | Simulation only |
| Governance parameter exposure for `challengeBondBps`, `challengeBountyBps` | **Not yet implemented** |

The primary contract change required is a new `challengeResolution(uint256 workflowId)` function in `BaseEscrow` that:
1. Does not validate the caller against `et.from` / `et.to`.
2. Enforces the per-address cooldown from `lastEscalationTimestamp`.
3. Computes the challenge bond via `EscalationCostLibrary` using `challengeBondBps`.
4. Calls `BondCollector.collectBond` with `depositor = msg.sender`, `escalatedBy = msg.sender`.
5. Proceeds through the existing escalation pipeline.

No changes to `ResolverIncentiveModuleV2`, `BondCollector`, or `PaymentCalculationLibraryV1` are required — the accounting layer already handles a third-party depositor correctly.

---

## Evidence

| | |
|---|---|
| **Contracts** | `sew-protocol` @ `e4504e4` |
| **Simulation** | `sew-simulation` @ `9648743` |
| **Reviewed** | 2026-05-21 |
| **Verification status** | Contract infrastructure claims verified against `ResolverIncentiveModuleV2.sol`, `BondCollector.sol`, `BaseEscrow.sol`. Simulation mechanics verified against `protocols/sew/resolution.clj`, `protocols/sew/accounting.clj`, `economics/payoffs.clj`, and scenarios S41, S42. `challengeResolution()` contract entry point does not yet exist — implementation pending. |
