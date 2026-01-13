DR v3 --- Capital decentralisation (staking + slashing + delegation + fraud lane)
===============================================================================

You've done the correct thing by shipping v1/v2 with heavy tests/invariants and deferring bonds. Now v3 introduces adversarial pressure because resolver capital is at risk. The goal is to add it **without turning the core dispute module into a constantly-changing surface**.

v3 objectives
-------------

1.  **Two-tier staking**: resolver bond (deductible) + senior bond (insurance)

2.  **Capital-weighted delegation**: senior can only appoint/cover what they can underwrite

3.  **Objective slashing**: mechanical, contract-executed triggers (no DAO discretion)

4.  **Fraud lane**: DAO-governed process, but slashing execution remains mechanical

5.  **Slow reputation + workload weighting**: starve bad actors before nuking them

* * * * *

1) Module composition for v3 (stable core, flexible edges, maximum testability)
===============================================================================

Stable core (should remain mostly unchanged)
--------------------------------------------

### A) `DecentralizedResolutionModule` (core dispute state machine)

Keeps:

-   dispute lifecycle, rounds, deadlines

-   resolver selection hook

-   escalation flow

-   finalisation and calls into IncentiveModule

Adds only:

-   calls to `IStakingModule` / `ISlashingModule` hooks at specific lifecycle points

-   (optional) "commitments" needed for objective slashing (e.g., accept/submit deadlines)

**Key principle:** v3 logic should be *plugged in*, not embedded.

Capital layer (new in v3)
-------------------------

### B) `ResolverStakingModule` (stateful)

Responsibilities:

-   track bonds: resolverBond, seniorBond

-   track delegation relationships: `appointedBy[resolver] = senior`

-   exposure accounting + reserved coverage

-   stake top-ups and withdrawals (with exit delays)

### C) `SlashingModule` (stateful + deterministic rules)

Responsibilities:

-   implement slash schedule and ceilings

-   slash ordering: resolver first, then senior

-   enforce epoch loss caps and freeze logic

-   execute slashes based on objective proofs from core state

### D) `DelegationPolicyLibrary` (pure)

Responsibilities:

-   compute required coverage for appointments

-   compute max appointments / max throughput allowed given senior bond

-   compute liability ceilings

### E) `FraudModule` (stateful, committee/quorum-based trigger)

Responsibilities:

-   committee management (set by DAO)

-   evidence submission windows

-   quorum verification

-   on success: call `SlashingModule.slashFraud(resolver)` and ban

DAO does not slash directly: it only configures/appoints committee and parameters.

Incentives/reputation layer (extend, but keep changeable)
---------------------------------------------------------

### F) `ResolverIncentiveModule` (existing)

-   Extend to incorporate staking multipliers later if desired, but keep payment calc pure

-   Keep `PaymentCalculationLibrary` pure and separately upgradeable

### G) `ResolutionAnalytics` (existing)

-   Add v3 metrics: slash events, bond sufficiency, delegation health

-   Keep scoring slow; avoid per-case overreaction

* * * * *

2) v3 mechanics (implementation-grade)
======================================

2.1 Two-tier staking structure (deductible + insurance)
-------------------------------------------------------

### State

-   `resolverBond[resolver]`

-   `seniorBond[senior]`

-   `appointedBy[resolver] => senior`

-   `isSenior[addr]`

-   `active[addr]`

-   `frozenUntil[addr]` (optional)

### Slash ordering (must be deterministic)

When slashable event occurs for resolver `r`:

1.  `slashFromResolver = min(resolverBond[r], penalty)`

2.  `remaining = penalty - slashFromResolver`

3.  If `appointedBy[r] = s` and remaining > 0:

    -   `slashFromSenior = min(availableSeniorCoverage(s), remaining)`

4.  If remaining still > 0:

    -   freeze resolver + senior coverage and reduce workload to 0 until topped up

**Why:** avoids cascading insolvency while still creating responsibility.

* * * * *

2.2 Capital-weighted delegation (prevents sockpuppet appointments)
------------------------------------------------------------------

### The delegation bond rule

For each senior `s`, define:

-   `reservedCoverage[s]`

-   `requiredCoverage[s] = Σ coverage(resolver_i)` over resolvers appointed by `s`

Coverage can be:

-   `coverage(resolver) = baseCoverage + m * resolverBond[resolver]`\
    or, simpler:

-   `coverage(resolver) = resolverBond[resolver] * m`

Then enforce:

-   On appointment: `seniorBond[s] - reservedCoverage[s] >= coverage(newResolver)`

-   Update `reservedCoverage[s] += coverage(newResolver)`

### Quantified liability ceilings

Define:

-   `maxLossPerEpochSenior`

-   `maxLossPerResolverPerEpoch`

-   `maxLossPerDisputeType`

Enforce in `SlashingModule`:

-   slashes beyond caps turn into **freeze + workload 0** instead of additional slashing

-   caps reset per epoch

**This directly stops:** "I appoint 100 sockpuppets" and "senior insolvency cascade".

* * * * *

2.3 Objective slashing triggers (no DAO opinions)
-------------------------------------------------

### Allowed triggers (mechanical)

-   **Missed deadlines**:

    -   assigned but not accepted by `t_accept`

    -   accepted but no decision by `t_resolve`

-   **Unresponsive**:

    -   no on-chain action by resolver in required window

-   **Escalation outcomes**:

    -   decision reversed at next round (use sparingly; scaled, not harsh)

-   **On-chain contradictions** (optional):

    -   if you implement a commit step (accept/commit/submit), contradictions become provable

### Suggested penalty schedule

-   Timeout accept: small % of resolver bond

-   Timeout resolve: medium % + freeze window

-   Reversal: small % scaled by repeated reversals (EMA-based)

-   Fraud: 100% slash + ban

**Important:** reversal slashing must be mild and statistically-based; otherwise honest disagreement becomes punished and you centralise behaviour.

* * * * *

2.4 Slow reputation + workload as first response
------------------------------------------------

Even in v3, do not jump to slashing for everything.

Use:

-   EMA score

-   epoch aggregates

-   long half-life decay

Then:

-   `WorkloadWeight = f(score, stakeSufficiency, timeoutRate, availability)`

Bad actors lose income first.\
Slashing is for objective failures and proven fraud.

* * * * *

2.5 Fraud lane (DAO-governed, contract-executed)
------------------------------------------------

### Process

1.  DAO appoints committee addresses + sets quorum threshold

2.  Committee submits `FraudVerdict(resolver, evidenceHash, signature)`

3.  Contract verifies quorum and time window

4.  `SlashingModule.slashFraud(resolver)` + ban + optional senior penalty

DAO never touches funds; it configures who can attest.

* * * * *

3) Attack vectors + v3-specific countermeasures (concrete)
==========================================================

3.1 Griefing
------------

**Attack:** spam disputes / tie up resolution to pressure resolvers.

**Stops in v3:**

-   Workload weighting + availability gating (spam routes to resilient capacity)

-   Minimum dispute fee / escrow thresholds (if applicable)

-   Timeouts auto-progress; resolvers penalised for non-action, not users

**Implementation:**

-   keep forceProgress callable

-   enforce tight resolver SLAs with penalties

* * * * *

3.2 Appeal spam
---------------

You deferred escalation bonds to v2 (and already built v2). Great.\
In v3, appeal spam is additionally deterred because:

-   a resolver can't be cheaply targeted for bond drain (bonds paid by parties)

-   workload routing can avoid known spammers (optional policy)

* * * * *

3.3 Bribery
-----------

**Stops:**

-   random assignment

-   senior backing with exposure (bribing a sockpuppet now costs senior)

-   fraud lane (if evidence exists)

-   mild reversal penalties + slow reputation decay

Optional upgrade later:

-   committee-of-3 for senior round, but only if needed.

* * * * *

3.4 Latency games
-----------------

**Stops:**

-   accept/resolve deadlines

-   automatic reassignment

-   mechanical penalties + freeze windows

-   heartbeat requirement for eligibility (optional)

* * * * *

3.5 Senior-resolver insolvency
------------------------------

**Stops:**

-   requiredCoverage and reservedCoverage enforcement

-   epoch loss caps

-   freeze instead of unlimited cascading slashes

-   appointment throttling based on bond sufficiency
