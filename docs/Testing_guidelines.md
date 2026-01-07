Short testing best-practice guide (Hardhat + Forge)
1) When to write tests in Hardhat vs Forge

Default rule of thumb

Forge for contract correctness (Solidity-level invariants, fuzzing, edge cases, gas-sensitive behavior).

Hardhat for system behavior (multi-contract integrations, scripts, deployment/upgrade flows, off-chain assumptions, role/governance wiring).

Write it in Forge when…

You’re testing pure contract logic (math, state machines, accounting).

You want fuzzing / property tests (e.g., “escrow can never get stuck beyond timeout”, “sum of balances conserved”, “no unauthorized state transition”).

You need fast iteration on tricky corner cases.

You’re testing revert reasons / custom errors precisely.

You want gas assertions (or at least tracking) and deterministic EVM-level behavior.

Write it in Hardhat when…

You need end-to-end flows that mirror how users/ops interact:

deployment + initialization ordering

governance lane changes / timelock flows

module swaps / upgrades (especially if you have proxy patterns)

You’re validating event correctness as consumed by off-chain indexers/UI.

You’re testing JS/TS tooling integration (Ethers/Viem calls, typed wrappers, scripts).

You want cross-tool parity checks (e.g., same scenario executed via scripts used in production ops).

Avoid duplication: the “one canonical home” rule

Each behavior should have one canonical test home:

If it’s an invariant/accounting rule → canonical in Forge; Hardhat may only do a smoke integration.

If it’s an operational flow (deploy/upgrade/governance) → canonical in Hardhat; Forge may only test the underlying contract invariants.

How to decide quickly
Ask: “If this fails in production, would I debug Solidity first or ops/scripts first?”

Solidity first → Forge

Ops/scripts first → Hardhat

2) Coverage reporting that stays useful (even with tool limits)

You’ve got two issues:

Hardhat coverage under-reports because it ignores Forge tests.

Forge coverage fails because contracts are too large.

So the goal becomes: truthful coverage reporting, not “one magic percentage”.

Recommended approach: publish coverage as two numbers + a mapping

Coverage A (Hardhat): what your TS integration tests cover.

Coverage B (Forge, best-effort): what Solidity tests cover (even if full coverage can’t run today).

A Coverage Map that lists critical behaviors and which suite covers them.

This avoids a false sense of security when one tool can’t measure everything.

Useful coverage artifacts to produce

Per-contract/function “tested-by” map (manual or generated):

Contract → key behaviors → Forge test files and/or Hardhat test files.

Critical path coverage report (not code coverage):

Escrow lifecycle: create → fund → release/cancel → dispute → resolve → timeout path.

Access control: who can call what, and when.

Upgrade/module swap: what can change, who can change it, and safety rails.

Branch/edge-case matrix:

For each state machine, list state transitions and invalid transitions.

When Forge coverage fails due to size

Treat this as a tooling constraint, not a testing constraint. Practical mitigations:

Prefer behavior coverage (checklists + mapping + invariants) over chasing a single %.

Keep Forge for fuzz/invariant tests, which are often more valuable than line coverage anyway.

If possible in your codebase, consider splitting large contracts (or moving libraries out) primarily for maintainability; coverage then becomes a bonus.

“Audit-friendly” coverage presentation

In your repo/docs, add a short TESTING.md section like:

What is tested in Forge vs Hardhat

How to run each suite

Known limitations (e.g., forge coverage disabled due to size)

The coverage map / checklist

Auditors care more about demonstrated properties + scenario completeness than a single coverage number.

3) Audit-ready testing checklist (end-state gate)

Use this as a pre-audit “definition of done”.

A. Core correctness (must-have)

 State machine completeness: every valid transition has a test; every invalid transition reverts.

 Access control: every privileged function has:

positive test (authorized)

negative test (unauthorized)

 Accounting invariants:

balances conserved (where applicable)

no double-withdraw / double-release

fee calculations correct at boundaries (0, 1 wei, max, rounding edges)

 Timeout / stuck-funds prevention:

prove funds cannot be locked indefinitely

verify the “escape hatch” path behaves as intended under failure scenarios

B. Adversarial behavior (strongly recommended)

 Fuzz tests for core flows (amounts, ordering, actor permutations).

 Invariants (Forge) run in CI with a reasonable iteration budget.

 Reentrancy & callback scenarios:

if external calls exist, test malicious receiver patterns (or assert none exist)

 DoS vectors:

large arrays / iteration limits / griefing

revert-on-transfer patterns if you interact with ERC20/ETH transfers

C. Integration & ops readiness

 Deployment tests:

correct init params

ownership/roles assigned correctly

cannot re-initialize

 Upgrade/module swap tests (if applicable):

authorized-only upgrade/swap

upgrade emits expected events

storage layout assumptions validated (where relevant)

rollback / safety checks (if used)

 Event correctness:

events emitted for all user-visible state changes

indexed topics match what off-chain consumers expect

D. Token/asset interaction safety

 ERC20 edge cases:

non-standard return values (if you support them)

fee-on-transfer tokens (explicitly supported or explicitly rejected)

decimals assumptions (never assume 18 unless enforced)

 ETH handling (if any):

receive/fallback behavior tested

refund paths correct

E. CI discipline (audit signal)

 CI runs: lint + typecheck + Hardhat tests + Forge tests (+ invariants) on every PR.

 Deterministic test runs (pinned compiler versions, pinned forks, fixed seeds where needed).

 Clear failure output and minimal flaky tests.