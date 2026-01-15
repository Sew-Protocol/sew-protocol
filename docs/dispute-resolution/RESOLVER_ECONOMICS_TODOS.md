DR v1 & DR v2 --- Engineering TODOs
=================================

*(Derived from `RESOLVER_ECONOMICS_2026.md`)*

> Scope:
>
> -   DR v1 = decentralise decisions, no resolver capital at risk
>
>
> -   DR v2 = decentralise incentives via appeal bonds + fee curves
>
>
> -   DR v3 (staking, slashing, delegation) is explicitly **out of scope**

* * * * *

🧩 Shared foundations (must exist before v1)
--------------------------------------------

### Core dispute state

-   ✅ `DisputeMetadata` struct includes:

    -   ✅ `currentRound` (uint8) - per-round tracking

    -   ✅ `status` (Open, Decided, Escalated, Final)

    -   ✅ `resolverAtRound[3]` - resolver set per round

    -   ✅ `decisionAtRound[3]` - decision per round

    -   ✅ `appealDeadline[3]` - appeal deadline per round

    -   ✅ `bondAmountAtRound[3]` - bond storage per round (DR v2 fields exist)

-   ✅ Resolver set stored per round (`resolverAtRound[3]`) so appeal bonds can be paid to correct prior resolvers.

-   Events:

    -   ✅ `DisputeOpened` (BaseEscrow)

    -   ✅ `DecisionSubmitted` (DecentralizedResolutionModule)

    -   ⚠️ `DisputeEscalatedToRound` (exists, but no `AppealOpened` event)

    -   ⚠️ `AppealBondRequired` (exists, but `AppealBondPosted` not emitted)

    -   ❌ `AppealResolved` (not emitted)

    -   ⚠️ `DisputeFinalised` (status exists, but event not emitted)

* * * * *

🧠 DR v1 --- Decentralise decisions (no resolver capital)
-------------------------------------------------------

### Resolver selection & routing

-   ✅ Resolver pool implemented with:

    -   ✅ `resolverActive` flag

    -   ✅ `resolverCapacity.acceptsNewDisputes` flag

    -   ✅ `resolverStats.emaScore` as performance score

-   ✅ **Category-based round-robin selection** per dispute round (uses `escrowCategory[workflowId]`).

-   ✅ Excludes resolvers whose workload weight is zero (via `calculateWorkloadWeight`).

* * * * *

### Performance tracking (EMA-based)

-   ✅ `ResolverStats` includes:

    -   ✅ `emaScore` (0-1e6 fixed point)

    -   ✅ `casesDecided` (cases handled)

    -   ✅ `timeoutsAccept` + `timeoutsResolve` (timeouts)

    -   ✅ `reversals`

    -   ✅ `lastActive` (via `resolverLastActive` mapping)

-   ✅ EMA update implemented:

    `score_new = score_old * (1 - α) + outcome * α` (in `ResolutionAnalytics.updateEMAScore`)

-   ✅ Outcome defined:

    -   1.0 (EMA_PRECISION) for upheld decision

    -   0.5 (EMA_PRECISION / 2) for reversed on escalation

    -   0 for timeout / no response

* * * * *

### Workload as incentive

-   ✅ `calculateWorkloadWeight(resolver)` implemented:

    `f(emaScore, assignmentWeight, minScoreThreshold)` (in `ResolutionAnalytics`)

-   ✅ Resolver selection weighted by workload weight (in `selectResolverRoundRobin`).

-   ✅ If score < threshold → weight becomes 0 (resolver receives no new cases).

* * * * *

### Timeouts & reassignment

-   ✅ Per-round `resolveDeadlines[3]` defined: `[3 days, 5 days, 7 days]`

-   ⚠️ `t_accept` not separately defined (resolvers are pre-assigned)

-   ✅ Resolver fails to resolve → auto-reassign via `forceProgress()` + record penalty.

-   ✅ Repeated failures push EMA down (via `recordTimeout`) and thus workload to zero.

* * * * *

### Escalation flow (with bonds - note: bonds enabled in DR v1)

-   ✅ Escalation to next round implemented (`executeEscalation`)

-   ✅ Resolver reassignment implemented (category-based round-robin per round)

-   ✅ Kleros escalation option (if enabled via `escalationConfig[2].enabled`)

-   ⚠️ Bonds are enabled in DR v1 (via `escalationCostConfig.enabled = true`), but collection/storage not yet implemented in BaseEscrow

* * * * *

### DR v1 exit metrics (for governance)

-   ✅ Tracked:

    -   ✅ Escalation rate (via `getV1PhaseGateMetrics`)

    -   ✅ Timeout rate (via resolver stats)

    -   ✅ Average resolution time (via `getAverageResolutionTime`)

-   ✅ Read-only views exposed for governance dashboards (`getV1PhaseGateMetrics`, `getAverageResolutionTime`, `getDisputeResolverStats`).

* * * * *

💰 DR v2 --- Decentralise incentives (appeal bonds, no resolver staking)
----------------------------------------------------------------------

### Appeal bond plumbing

-   ✅ `getRequiredAppealBond(uint k)` function exists (calculates bond using quadratic curve via `EscalationCostLibrary`)

-   ✅ Bond storage fields exist: `bondAmountAtRound[3]` in `DisputeMetadata`

-   ⚠️ Bond collection not yet implemented in `BaseEscrow.escalateDispute()` (still uses old fee collection)

* * * * *

### Bond custody & accounting

-   ⚠️ On appeal:

    -   ⚠️ Bond amount calculated but not collected/stored in BaseEscrow

    -   ⚠️ `ResolverIncentiveModuleV2` exists with `recordAppealBond`, `handleBondRefund`, `handleBondPayout`, but not integrated

* * * * *

### Bond payout rules

-   ⚠️ When round resolves:

    -   ⚠️ `ResolverIncentiveModuleV2` has `handleBondRefund` and `handleBondPayout` but not integrated

    -   ⚠️ Events exist: `AppealBondRefunded`, `AppealBondPaidToResolvers` (in ResolverIncentiveModuleV2)

* * * * *

### Increasing delays

-   ⚠️ Fixed arrays `resolveDeadlines[3]` and `appealWindows[3]` exist (not calculated with steps)

    -   Current: `[3 days, 5 days, 7 days]` and `[2 days, 3 days, 0]`

    -   TODO: Change to `baseResolve + k * resolveStep` and `baseAppeal + k * appealStep`

-   ⚠️ Enforced on-chain (via `resolveBy` timestamp).

* * * * *

### Anti-griefing rules

-   ✅ `MAX_ROUND = 2` cap exists.

-   ✅ `minEscrowValueForEscalation` exists (currently 0 by default).

-   ⚠️ Bond forfeiture logic exists in `ResolverIncentiveModuleV2.handleBondForfeit` but not integrated.

* * * * *

### Reporting & observability

-   ⚠️ Exposed in `ResolverIncentiveModuleV2` (not integrated):

    -   ✅ `totalBondsPosted`

    -   ✅ `totalBondsForfeited`

    -   ✅ `totalBondsRefunded`

    -   ✅ `escalationDepthHistogram`

-   ⚠️ These metrics exist but module not integrated into resolution flow.

* * * * *

🚫 Explicitly out of scope (v3 only)
------------------------------------

Do **not** implement yet:

-   Resolver staking

-   Slashing

-   Senior backing

-   Fraud committees

-   Delegation coverage

Interfaces for these may exist but must be inactive.

* * * * *

Why this sequencing is safe (from `RESOLVER_ECONOMICS_2026.md`)
---------------------------------------------------------------

-   DR v1 gives you decentralised decision-making with almost no financial attack surface.

-   DR v2 introduces economic friction for users (escalation bonds) but keeps resolvers non-adversarial.

-   Only after real-world griefing and appeal patterns are known do you introduce slashing and capital risk.

* * * * *

## Implementation Status Summary

### ✅ Completed (DR v1)

- Core dispute state structure
- Resolver selection & routing (category-based round-robin)
- Performance tracking (EMA-based)
- Workload weighting
- Timeouts & reassignment
- Escalation flow
- DR v1 exit metrics

### ⚠️ Partially Complete (DR v2)

- Bond calculation (implemented)
- Bond storage fields (exist but not populated)
- Bond collection (not implemented in BaseEscrow)
- Bond payout logic (exists in ResolverIncentiveModuleV2 but not integrated)

### ❌ Not Implemented

- Increasing delays (fixed arrays instead of calculated)
- Bond integration (ResolverIncentiveModuleV2 not integrated)
- Some events (AppealOpened, AppealBondPosted, AppealResolved, DisputeFinalised)
