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

-   Add / verify `Dispute` struct includes:

    -   `round` (uint)

    -   `status` (Open, Resolved, Escalated, Final)

    -   `currentResolverSet`

    -   `decision[round]`

    -   `appealDeadline[round]`

    -   `appealBond[round]`

-   Store resolver set per round so that appeal bonds can be paid to the correct prior resolvers.

-   Emit events for:

    -   `DisputeOpened`

    -   `DecisionSubmitted`

    -   `AppealOpened`

    -   `AppealBondPosted`

    -   `AppealResolved`

    -   `DisputeFinalised`

* * * * *

🧠 DR v1 --- Decentralise decisions (no resolver capital)
-------------------------------------------------------

### Resolver selection & routing

-   Implement resolver pool with:

    -   `active` flag

    -   `availability` flag

    -   `performanceScore`

-   Implement **random selection from suitable resolvers** per dispute round.

-   Exclude resolvers whose workload weight is zero.

* * * * *

### Performance tracking (EMA-based)

-   Add `ResolverStats`:

    -   `emaScore`

    -   `casesHandled`

    -   `timeouts`

    -   `reversals`

    -   `lastActive`

-   Implement EMA update:

    `score_new = score_old * (1 - α) + outcome * α`

-   Define `outcome`:

    -   1.0 for upheld decision

    -   <1.0 for reversed on escalation

    -   0 for timeout / no response

* * * * *

### Workload as incentive

-   Implement `WorkloadWeight(resolver)`:

    `f(emaScore, availability, recentTimeoutRate)`

-   Resolver selection must be weighted by `WorkloadWeight`.

-   If score < threshold → weight becomes 0 (resolver receives no new cases).

* * * * *

### Timeouts & reassignment

-   Define per-round:

    -   `t_accept`

    -   `t_resolve`

-   If resolver fails to accept → auto-reassign + record penalty.

-   If resolver fails to resolve → auto-reassign + record penalty.

-   Repeated failures push EMA down and thus workload to zero.

* * * * *

### Escalation flow (without bonds)

-   Implement:

    -   escalation to next round

    -   resolver reassignment

    -   Kleros escalation option (if enabled)

-   Ensure escalation does not move money yet.

* * * * *

### DR v1 exit metrics (for governance)

-   Track:

    -   appeal rate per dispute

    -   timeout rate

    -   average resolution time

-   Expose read-only views for governance dashboards.

* * * * *

💰 DR v2 --- Decentralise incentives (appeal bonds, no resolver staking)
----------------------------------------------------------------------

### Appeal bond plumbing

-   Add function `appealBondForRound(uint k)` using quadratic curve:

    `base + step * k^2`

-   Store `appealBond[k]` per dispute.

-   Require bond to be paid to open round `k+1`.

* * * * *

### Bond custody & accounting

-   On appeal:

    -   Escalator pays `appealBond[k+1]`

    -   Funds held in dispute escrow

* * * * *

### Bond payout rules

-   When round `k+1` resolves:

    -   If `decision[k+1] != decision[k]` → refund bond to escalator

    -   Else → pay bond to `resolverSet[k]` (prior round)

-   Emit `AppealBondPaid(resolvers[], amount)` or `AppealBondRefunded(user, amount)`

* * * * *

### Increasing delays

-   Add:

    `t_resolve[k] = baseResolve + k * resolveStep
    t_appeal[k]  = baseAppeal  + k * appealStep`

-   Enforce these windows on-chain.

* * * * *

### Anti-griefing rules

-   Add `maxRounds` cap.

-   Require minimum escrow value to allow k ≥ 2 (optional but recommended).

-   Forfeit bond if escalator does not submit required data/signature in next round.

* * * * *

### Reporting & observability

-   Expose:

    -   total bonds posted

    -   bonds forfeited

    -   bonds refunded

    -   escalation depth histogram

-   These metrics become governance signals for v3 readiness.

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
