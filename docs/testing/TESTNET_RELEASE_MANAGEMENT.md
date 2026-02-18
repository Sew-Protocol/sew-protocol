Testnet Deployment & Upgrade Guide (Mature Ethereum Release Management)
-----------------------------------------------------------------------

### 1) Goals of a testnet release (decide before you deploy)

Every testnet deployment should have an explicit purpose, because purpose determines risk tolerance, key policy, and "done" criteria.

**Common purposes**

1.  **Dev integration**: unblock frontend/wallet integration, basic flows, rapid iteration.

2.  **Internal staging**: realistic end-to-end rehearsals (ops, monitoring, upgrades, incidents).

3.  **Public testnet / partner sandbox**: stable addresses, docs, faucet guidance, support expectations.

4.  **Audit rehearsal ("audit-ready testnet")**: deployment mirrors intended mainnet architecture; changes become controlled.

**Rule:** if the purpose is (3) or (4), treat the deployment like a production artifact (even if funds are "worthless").

* * * * *

### 2) Release tiers and code readiness criteria

Use these tiers across **protocol core + modules + token + DAO + wallet**.

#### Tier A --- Dev Testnet (fast iteration)

**When to deploy**

-   You need contract addresses for UI integration.

-   You expect breaking changes.

**Code state**

-   Tests passing for touched areas (unit + minimal integration).

-   No known critical vulnerabilities in modified logic (basic internal review).

-   Can use simpler admin controls temporarily.

**Not required**

-   Full invariants, formal threat model updates, full monitoring.

**Expectation**

-   Addresses can change frequently; docs can be lightweight.

* * * * *

#### Tier B --- Internal Staging Testnet (ops rehearsal)

**When to deploy**

-   You're testing the full system: deploy scripts, permissions, upgrade paths, monitoring, incident playbooks.

**Code state**

-   Comprehensive unit + integration tests passing.

-   Static analysis clean (Slither baseline, obvious issues resolved).

-   Key flows have property/invariant tests (escrow lifecycle, yield in/out, dispute paths, emergency unwind).

-   Clear upgrade plan (what is upgradeable, what is immutable, what breaks storage).

**Expectation**

-   Addresses should remain stable for a sprint/release cycle.

* * * * *

#### Tier C --- Public Testnet Release (external users/partners)

**When to deploy**

-   You want third parties to build against it or you're doing structured testing.

**Code state**

-   Everything in Tier B, plus:

-   Frozen external interfaces (ABI stability) or versioned endpoints.

-   Event schema reviewed (indexing compatibility).

-   Rate-limited or protected admin endpoints and role assignments finalized.

-   Documented known issues + compatibility notes.

**Expectation**

-   You own support/uptime expectations (even informally).

* * * * *

#### Tier D --- Audit-Ready Testnet (pre-audit or audit mirror)

**When to deploy**

-   You're about to audit, in audit, or validating an audit fix set.

-   You want a "dress rehearsal" for mainnet.

**Code state**

-   Feature freeze except audit fixes.

-   Full threat model, trust assumptions, and emergency procedures updated.

-   Deterministic builds: pinned compiler settings, exact dependency locks.

-   Deployment scripts are final-form (same upgrade pattern as mainnet).

-   Strict role separation + timelock/guardian flows rehearsed on-chain.

**Expectation**

-   Testnet state should be long-lived and reproducible.

* * * * *

### 3) Pre-deploy checklist (contracts)

Applies to **core protocol, yield modules, dispute modules, token, DAO**.

#### A. Engineering readiness

-   ✅ All tests green; include fork tests where relevant (yield protocols, ERC-4626 behavior).

-   ✅ Storage layout reviewed for upgradeables (diff tool + explicit storage gaps).

-   ✅ Reentrancy/authorization surfaces reviewed (especially: escrow release/cancel/dispute, module callbacks, token approvals).

-   ✅ Gas sanity: critical paths measured (create escrow, release, dispute, emergency unwind).

-   ✅ Events: emitted on all state transitions you want indexed.

#### B. Security readiness (testnet-appropriate)

-   ✅ "Assume public adversary" if public testnet: no privileged shortcuts that allow fund capture, griefing, or infinite minting unless clearly isolated.

-   ✅ Pausing semantics are intentional (what must remain unpausable: settlement/recovery paths).

-   ✅ Emergency workflows tested: pause, module disable, unwind/detach, role rotation.

#### C. Deployment readiness

-   ✅ Deterministic config files checked in (network params, addresses, roles, fee params, timelock delays).

-   ✅ Deployment scripts support:

    -   idempotency (safe re-run),

    -   explicit confirmations of addresses/bytecode hashes,

    -   exporting artifacts (addresses + ABI + build info).

-   ✅ Verification plan: block explorer verify + publish metadata.

* * * * *

### 4) Upgrade checklist (when deploying an upgrade)

Upgrades are where most "testnet drift" becomes dangerous. Treat upgrades as a first-class product.

#### A. Upgrade design constraints

-   **State compatibility**: storage layout diff approved.

-   **Access control**: upgrade authority requires the intended governance path (even on testnet for Tier C/D).

-   **Rollback / escape hatch**: defined process if upgrade breaks (pause + revert upgrade if possible; or deploy new instance + migrate strategy).

#### B. Upgrade rehearsal

-   Dry-run on a fresh forked state (or a staging testnet deployment) with:

    -   upgrade transaction,

    -   post-upgrade initialization,

    -   smoke test suite (create/release/cancel/dispute/yield deposit-withdraw/unwind).

#### C. Post-upgrade validation

-   Compare pre vs post invariants:

    -   balances conservation,

    -   escrow state transitions monotonic,

    -   yield share accounting doesn't drift,

    -   dispute bond accounting correct,

    -   role permissions unchanged unless intended.

* * * * *

### 5) Ongoing responsibilities for deployed testnet contracts

If you deploy Tier B/C/D, you are implicitly signing up for ops work.

**Minimum responsibilities**

-   **Monitoring**

    -   Watch critical events (escrow created/released/cancelled, dispute raised/escalated/resolved, module deposits/withdrawals, emergency actions).

    -   Alert on reverts/spikes (e.g., repeated failure in withdraw/unwind).

-   **Support**

    -   A single canonical "status + known issues" page.

    -   Clear channel for bug reports (even if it's just GitHub issues).

-   **Housekeeping**

    -   Rotate keys if leaked.

    -   Deprecate old deployments with on-chain flags (where possible) + docs that shout "deprecated".

**For yield modules**

-   Expect upstream protocol changes or rate model weirdness on testnets.

-   Maintain a "supported assets + supported pools" list per network.

**For dispute systems**

-   Periodically ensure resolvers can still operate (RPC reliability, bond token availability, faucet availability).

-   Run adversarial drills (spam disputes, grief attempts, edge-case timing).

* * * * *

### 6) Documentation you must keep (per deployment)

Keep these as versioned artifacts in-repo (and optionally mirrored on the website).

#### A. Deployment manifest (per network, per release)

-   Release name / tag (e.g., `testnet-public-v0.7.3`)

-   Chain ID, RPC assumptions

-   Commit hash + build info hash

-   Contract list with addresses:

    -   Core protocol contracts

    -   Each module (yield, resolution)

    -   Token(s)

    -   DAO/governance contracts

-   Proxy/admin addresses and implementation addresses (if upgradeable)

-   Parameterization snapshot:

    -   fees, caps, timeouts, dispute windows, bond params, timelock delays

-   Role assignments snapshot:

    -   guardian, timelock, multisig, module manager, minter, pauser, etc.

-   Verification links (explorer verify status)

#### B. "How to use this testnet" page

-   Faucet guidance, supported tokens, example flows

-   Known limitations

-   Deprecation policy

#### C. Upgrade log

-   Date, reason, transactions, diffs, and what tests were run

-   Any migrations or manual interventions

#### D. Runbooks (ops)

-   Pause/unpause

-   Disable module / emergency unwind

-   Rotate roles / rotate keys

-   Incident checklist

* * * * *

### 7) Key & role policy (deploy keys vs operational keys)

Testnet is where teams accidentally train bad habits. Use testnet to practice production-grade separation, with pragmatic shortcuts only for Tier A.

#### A. Key types (recommended)

1.  **Deployer key**

    -   Only used to deploy contracts.

    -   Should not retain long-lived privileged roles after deployment.

2.  **Upgrade authority**

    -   For proxies / upgradeable contracts (multisig or timelock executor).

3.  **Guardian / emergency**

    -   Pause + emergency unwind actions.

4.  **Governance / timelock proposer-executor**

    -   For DAO-controlled parameter changes.

5.  **Module operator keys** (if any operational actions exist)

6.  **Automation keys**

    -   If you run bots/keepers (prefer restricted roles and rate limits).

#### B. Role assignment rules

-   **Never** leave deployer as admin/owner in Tier B/C/D.

-   For Tier C/D:

    -   Upgrades go through **timelock** (even if short delay) + a guardian pause.

    -   Guardian cannot redirect funds; emergency actions must be "return to escrow/vault only" style.

-   Keep roles minimal:

    -   Split "pause" from "upgrade" from "parameter changes" where possible.

#### C. Do you reuse the same keys across testnet deployments?

Use this rule of thumb:

-   **Tier A (dev):** reuse is fine, but still keep a clean boundary between deployer and admin where possible.

-   **Tier B (internal staging):** reuse within the staging environment is acceptable, but rotate if:

    -   someone leaves the team,

    -   key touched a compromised machine,

    -   you change custody method (moving to multisig/HSM).

-   **Tier C/D (public/audit-ready):** prefer **a stable governance identity** (multisig/timelock) but rotate **hot/deployer/automation keys** per release or per quarter.

**Practical best practice**

-   Keep **one stable multisig** identity per environment (e.g., `Testnet Guardian Multisig`, `Testnet Timelock Admin`) so external integrators don't chase a moving target.

-   Use **new deployer keys per major release line** (or per network) to reduce blast radius.

-   Automation keys are always treated as hot and rotated regularly.

* * * * *

### 8) Multi-system coordination: protocol + modules + token + DAO + wallet

Your deployments are only "real" when the whole stack agrees.

#### A. Version matrix (must exist)

Create a small matrix mapping:

-   Wallet version → Protocol release → Module versions → Token/DAO addresses

This prevents "wallet points to old escrow vault" or "module interface mismatch".

#### B. Backward compatibility policy

Define what you guarantee:

-   Wallet supports last N protocol minor versions (or only latest).

-   Modules are versioned and discoverable on-chain (registry) or in config.

-   ABI changes require a new major release and new addresses (or explicit adapter layer).

#### C. Environment configuration

-   Wallet should load network config from a signed/verified manifest (or shipped config) to avoid malicious RPC/config injection.

-   Maintain a single canonical config source in-repo that produces:

    -   wallet config,

    -   website "addresses" page,

    -   deployment manifest.

* * * * *

### 9) A simple, repeatable process (the runbook)

Here's a mature flow you can repeat every time.

1.  **Open a Release Candidate**

    -   Pick tier, goals, and freeze scope.

2.  **Cut a release branch + tag**

    -   Lock dependencies, compile settings, and config.

3.  **Run the release checklist**

    -   Tests, analysis, storage layout, rehearsal.

4.  **Deploy to staging testnet**

    -   Validate end-to-end, run smoke suite.

5.  **Promote to public/audit-ready**

    -   Deploy with production-like roles and timelock flows.

6.  **Publish artifacts**

    -   Manifest, addresses page, verification, upgrade log entry.

7.  **Operate**

    -   Monitoring, incident drills, scheduled key review/rotation.

8.  **Deprecate intentionally**

    -   Mark old deployments deprecated and update wallet/website pointers.
