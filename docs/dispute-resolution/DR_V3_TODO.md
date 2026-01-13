4) v3 TODO list (high signal, implementation sequence)
======================================================

v3.0 Interfaces and boundaries (keep core stable)
-------------------------------------------------

-   Define `IStakingModule`:

    -   `onAssign(workflowId, round, resolver)`

    -   `onDecision(workflowId, round, resolver, decision)`

    -   `onTimeout(workflowId, round, resolver, timeoutType)`

    -   getters: `isEligible(resolver, round)`

-   Define `ISlashingModule`:

    -   `slashTimeout(resolver, severity)`

    -   `slashReversal(resolver, severity)`

    -   `slashFraud(resolver)`

    -   `applyFreeze(resolver, until)`

-   Update `DecentralizedResolutionModule` to call hooks only (no embedded staking logic)

v3.1 Staking + registry integration
-----------------------------------

-   Implement `ResolverStakingModule`:

    -   deposit/withdraw with exit delays

    -   track resolver/senior bonds

    -   track appointment relationships

    -   enforce appointment coverage

-   Update resolver selection to require:

    -   `stakingModule.isEligible(resolver, round)` AND `workloadWeight > 0`

v3.2 Deterministic slashing rules
---------------------------------

-   Implement `SlashingModule` with:

    -   penalty table (bps)

    -   epoch caps

    -   slash ordering (resolver then senior)

    -   freeze logic when funds insufficient

-   Add invariant tests:

    -   cannot slash more than bond

    -   sum of slashes accounted (no phantom loss)

    -   caps enforced per epoch

    -   freeze triggers when insufficient

v3.3 Fraud lane module
----------------------

-   Implement `FraudModule`:

    -   committee set by governance

    -   quorum verification

    -   evidence hash and challenge window

    -   on success calls `SlashingModule.slashFraud(resolver)` and bans

-   Tests:

    -   quorum required

    -   replay protection

    -   ban prevents eligibility

v3.4 Scoring and workload weighting updates
-------------------------------------------

-   Extend `ResolutionAnalytics` for v3:

    -   track slashes, freezes, coverage health

-   Update `WorkloadWeight` to incorporate:

    -   stake sufficiency

    -   freeze status

    -   sustained performance score
