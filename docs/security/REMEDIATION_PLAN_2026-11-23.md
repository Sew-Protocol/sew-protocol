# Smart contract review remediation plan

**Date:** 2026-11-23
**Scope:** Findings F-01 through F-17 in the source review supplied on 2026-11-23.
**Status:** Remediation implemented and CI-qualified on the recorded source revision; independent security acceptance remains pending.

## Current evidence

The latest successful source revision is `ad0aadcb2001b40081ed1286c4e405eb1b26f1e0`.
CI and CodeQL passed. The full run passed 1,540 Foundry tests, failed 0, and
skipped 12 across 150 suites. The Sew Core source boundary, 13-test profile,
artifact validation, integrity checks, determinism checks, and runtime/initcode
size gates also passed. The Sew Core export contains 13 artifacts at bundle root
`56370b6e2cfdb6fb682c0213cede8eeaa944fd6d47f1acc7ba8165fd2c880bab`.

The SewCoreVault runtime is 24,357 bytes, 219 bytes below EIP-170; its initcode
is 25,172 bytes, below the EIP-3860 limit. Sew Core artifact qualification now
enforces both limits for every allow-listed artifact. The legacy full-protocol
size report still identifies four non-Sew-Core contracts over EIP-170; they are
outside this standalone Sew Core deployment graph and remain excluded from its
allowlist.

For F-05, failed settlement preserves the escrow's yield linkage and creates no
claim. Full operator recovery creates a workflow-keyed receipt, which settlement
consumes once. Partial recovery reverts atomically and preserves the Aave
position. The shared-vault regression passed: two escrows using the same vault
and token cannot use one another's recovery or claims.

| Gate | Current state |
|---|---|
| Focused regressions for affected findings | Affected suites pass; F-05 shared-vault recovery isolation regression passes locally and in CI |
| Full Foundry suite | CI passed on `ad0aadcb`: 1,540 passed, 0 failed, 12 skipped (1,552 total) |
| Invariant directory | Passed; 12 invariants/test cases at 256 runs and 128,000 handler calls each |
| Sew Core package build and profile tests | Passed; runtime is 24,357 bytes (219-byte margin), initcode is 25,172 bytes (23,980-byte margin) |
| Runtime and initcode limits | Hard-gated for all 13 Sew Core artifacts; CI passed on `ad0aadcb` |
| TypeScript, CodeQL, artifact export, validation, and determinism | Passed on `ad0aadcb`; clean-source bundle root recorded above |
| Independent review of exact source revision and bundle root | Pending |
| Public deployment authorization | Not implied by source remediation |

## Release boundary

Treat the reviewed `main` source and any modified working copy as separate candidates. Do not describe an artifact as remediated until its exact source revision and artifact bundle have passed the gates below. Existing deployments and pinned artifacts are unchanged by source fixes. Do not use DR v3, affected factories, or yield-backed settlement routes for real-value custody until their relevant P0 gates pass.

## Order of work

### P0 — Prevent unsupported custody and capital claims

1. **F-04/F-05, yield settlement:** distinguish recovered assets from unresolved recovery obligations. A settlement must not create ordinary withdrawable claims above the assets actually recovered. If unwind fails, preserve the escrow's yield-position linkage and leave the workflow recoverable; do not fabricate principal. Test short recovery and double-failure with multiple escrows sharing a vault, including conservation of each workflow's backed claims.
2. **F-09, vindication accounting:** keep USD-denominated restoration receivables separate from token-denominated, custody-backed stake. Define a funded redemption path only if the protocol identifies and funds the liable treasury. Test 6- and 18-decimal tokens, partial/full restoration, mixed bonds, and competing withdrawals.
3. **F-13, assigned resolver capital:** make assignment, escalation/replacement, and finalization use one keyed staking lifecycle. Lock the required exposure atomically on assignment, transfer the lock on resolver replacement, and unlock once at terminal completion. Fail the dispute transition if staking hooks fail. Test overlapping workflow IDs in separate escrow contracts, and prove active exposure cannot be unstaked.
4. **F-01, factories:** deploy through each factory in tests and prove the selected admin receives the intended roles and token supply, while the factory retains neither. Keep factory routes disabled in deployment profiles until constructor/API migration and downstream callers are qualified.
5. **F-12, slash appeals:** an unresolved appeal blocks slash execution after the original contest deadline. Each appeal records a fixed seven-day governance resolution deadline; if governance does not decide in time, anyone can expire it in the resolver's favor, cancel the slash, clear pending-slash accounting, and return the appeal bond. Test pending, upheld, rejected, deadline boundary, and expired appeal states. The timeout is governance-configurable but cannot be set to zero; changes affect new appeals only.

**P0 exit:** all backed-claim, custody, authority, and stake invariants pass focused and multi-escrow adversarial tests. No affected route may be included in an executable deployment profile before then.

### P1 — Make lifecycle authority and protective rights consistent

6. **F-02, pause:** specify pause semantics across creation, dispute opening, appeal submission, settlement, timeout, withdrawal, and deadline accounting. Guardian pause should stop new exposure while preserving the agreed protective actions for existing users. If appeal deadlines pause, define how they resume. Test every lifecycle action in both paused and unpaused states.
7. **F-03, absent module snapshots:** snapshot initialization must distinguish “snapshotted absent” from “not snapshotted.” After creation, an absent module remains absent even if registry defaults change. Test present and absent snapshots against later registry updates.
8. **F-06/F-10, resolver identity:** use one authenticated active assignment. On initial policy selection and timeout replacement, atomically synchronize the escrow's settlement authority with the DRM's current resolver; reject old resolvers and verify the replacement can settle. Add explicit-policy tests where the selected policy's resolver differs from the global default.
9. **F-07, external arbitration timeout:** ordinary automation and resolver `forceProgress` cannot supersede committed Kleros arbitration. A committed case may be closed only by the Timelock after one full snapshotted dispute-duration from the handoff; that path refunds the sender and clears local authority so a late ruling cannot settle. Test both the blocked ordinary timeout and the governed expiry path.
10. **F-08, reversal slash identity:** key slash references by `(escrowContract, workflowId, round)` throughout and validate the referenced slash identity before restoration. Test two vaults with the same workflow ID and independent vindication.
11. **F-11, dispute initialization:** fail dispute opening when a registered module's required initializer rejects. Compatibility with modules that intentionally have no initializer must be explicit and tested separately.

**P1 exit:** one authoritative resolver and module assignment per workflow, with no timeout or pause path bypassing the state machine. All transitions are atomic across escrow and modules.

### P2 — Reconcile liabilities, recovery claims, and evidence semantics

12. **F-14, slash distribution:** account for each stable-token allocation as a transfer or an explicitly recorded, funded liability. Reconcile insurance, protocol, and retained reserves through subsequent withdrawals.
13. **F-15, emergency withdrawal:** remove the unsupported operation from the staking interface and implementation. Do not present an unconditional revert as a recovery path.
14. **F-16, resolution evidence:** preserve `resolutionHash` as non-binding metadata unless a decision-admission proof is implemented. Ensure events, interfaces, and application docs say that it identifies supplied evidence but does not verify decision validity.
15. **F-17, CI and qualification:** run gating CI on `main` as well as pull requests; make TypeScript typechecking a gating check. Keep Foundry tests, fuzz/invariant suites, size checks, package qualification, deployment-artifact commitments, and deployables determinism in the source-bound gate.
16. Document the policy and eventual disposition for forfeited appeal-bond reserves; reconcile all fee, bond, slash, and recovery liabilities in end-to-end tests.

**P2 exit:** every reported balance reconciles to custody or a separately identified funded liability; CI evidence is tied to the exact source revision and artifact root.

## Execution and release gates

1. Reproduce each finding against the candidate revision and retain a minimal failing regression test before changing behavior.
2. Implement one finding group at a time. Keep policy changes separate from mechanical fixes where possible, and record any approved policy choice in the relevant specification.
3. Run targeted tests for each group, then the full Foundry suite, fuzz/invariant suites, build/type checks, package qualification, bytecode-size checks, and deployable export/validation/determinism checks.
4. Review storage layout, ABI, runtime bytecode, and deployment graph changes. Pin a new artifact candidate; do not silently reuse an earlier qualification or deployment approval.
5. Obtain independent review of the exact source revision and bundle root. Only then reconsider deployment readiness.

## Decisions required before implementation can be accepted

- Whether the DR v3 quarter-exposure lock formula and stable-token-only normalization are acceptable for production, including mixed-token bonds. Current implementation rejects unsupported exposure tokens.
- The final pause/deadline semantics for appeals and disputes.
- Whether factories remain supported deployment paths or are removed from supported interfaces.
- The authority and eventual funding source for vindication receivables; receivables are currently non-redeemable and excluded from stake.
- Whether seven days is the desired production appeal-resolution timeout. Current implementation uses this safe default and permits Timelock governance to change it for future appeals.

Until those choices are reflected in specifications and tests, affected capabilities should remain excluded from a public deployment profile.
