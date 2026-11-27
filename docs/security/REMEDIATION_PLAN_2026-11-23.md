# Smart contract review remediation plan

**Date:** 2026-11-23
**Scope:** Findings F-01 through F-17 in the source review supplied on 2026-11-23.
**Status:** Remediation implemented and CI-qualified on the recorded source revision; independent security acceptance remains pending.

> **Qualification update (2026-11-27):** P0-A and the listed profile-specific
> remediations are committed and pushed. CI and CodeQL pass on source revision
> `69ac7c7bbd809b26cf973fb9f1ed82ef7e8850bf`. The full-appeal 20-artifact bundle
> root is `2dd69b86427e65549ed51c7e02165832eb18f6e7ea254e48a1db9641b8085fe4`.
> Independent security acceptance and chain-specific deployment qualification
> remain pending.

> **Scope update (2026-11-25):** The F-01–F-17 qualification does not accept the full
> Sew Protocol or full-appeal, DR v3, staking/slashing, or yield-enabled profiles.
> A subsequent review identified additional authorization and accounting issues;
> these are tracked separately below as P0-A and profile-specific follow-ups.

## Current evidence

On `69ac7c7bbd809b26cf973fb9f1ed82ef7e8850bf`, GitHub CI and CodeQL passed.
CI passed lint, TypeScript, Hardhat/Forge compilation, the full Foundry suite,
Sew Core scoped qualification, full-appeal artifact qualification, contract
size checks, deployable export/validation, and deployable integrity and
determinism checks. The full-appeal 20-artifact profile
(`@sew/deployables@0.2.0`) reproduced bundle root
`2dd69b86427e65549ed51c7e02165832eb18f6e7ea254e48a1db9641b8085fe4` from that
clean source revision, using solc `0.8.37+commit.f401782d`, Osaka EVM, 200
optimizer runs, and `viaIR`. This is source/artifact qualification evidence,
not independent security acceptance or deployment approval.

The earlier F-01–F-17 qualification baseline was source revision
`ad0aadcb2001b40081ed1286c4e405eb1b26f1e0`.
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
| Full Foundry suite | CI passed on `69ac7c7b`; prior local run on the remediation code: 1,581 passed, 0 failed, 11 skipped (1,592 total) |
| Invariant directory | Passed; 12 invariants/test cases at 256 runs and 128,000 handler calls each |
| Sew Core package build and profile tests | Passed; runtime is 24,357 bytes (219-byte margin), initcode is 25,172 bytes (23,980-byte margin) |
| Runtime and initcode limits | Hard-gated for all 13 Sew Core artifacts; CI passed on `69ac7c7b` |
| TypeScript, CodeQL, artifact export, validation, and determinism | Passed on `69ac7c7b`; full-appeal root recorded above |
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

## Implemented policy defaults and remaining qualification limits

The implementation now has explicit conservative defaults for the policy
questions raised in the review:

- **DR v3 case collateral:** lock 25% of normalized stable-token exposure for
  the specific `(escrowContract, workflowId, resolver)` assignment. Only the
  configured stable token is accepted for this USD-normalized calculation;
  other tokens and tokens with more than 18 decimals are rejected. Assignment
  slashes can consume free stake and then only the corresponding workflow lock,
  preserving other assignments. Mixed-token exposure remains unsupported until
  an explicit valuation and liquidation policy is specified and reviewed.
- **Guardian pause:** pause stops new escrow intake only. Existing dispute,
  appeal, settlement, claim, and withdrawal operations remain available, and
  their deadlines continue to elapse. Only the governance timelock can unpause;
  there is no automatic expiry. See `docs/security/SECURITY_MODEL.md`.
- **Factories:** both factories remain supported. They accept explicit initial
  authority/recipient inputs and hand off roles and supply atomically; factory
  integration tests assert the factory retains neither.
- **Vindication:** restored amounts are USD-denominated, non-redeemable
  receivables excluded from stake and withdrawable balances. No redemption
  path exists until a treasury source and funded settlement policy are
  specified; do not represent a receivable as recovered collateral.
- **Slash appeals:** the default governance resolution window is seven days.
  Timelock changes affect new appeals only; an unresolved appeal expires in the
  resolver's favor, cancels the slash, and returns its appeal bond.

These code-level defaults do not independently authorize real-value DR v3 or
full-appeal use. Mixed-token valuation, a funded vindication-receivable policy,
exact production parameters, and independent profile qualification remain
separate gates.

## Follow-up security work identified after F-17

The source review of revision `ad0aadcb2001b40081ed1286c4e405eb1b26f1e0`
identified the following additional issues. The current source tree still contains
the relevant code paths; CI success on that revision does not close properties
that its tests do not assert. This section is a remediation plan, not an
independent security acceptance.

### P0-A — Authenticated dispute and bond transitions

**Code status: remediated** in commits `18c0afade80e6df86fc9f16e39d274e7bd94776f`
and `9290e814f8463207516b5a44271aedd36b74ac49`; current source and artifact
candidate: `69ac7c7bbd809b26cf973fb9f1ed82ef7e8850bf`. The first commit adds
the authorization and lifecycle guards; the second hardens the same DRM,
incentive, and slashing paths. CI and CodeQL passed on the current candidate.
This is code-remediation status, not independent security acceptance.

The full-appeal profile remains blocked pending independent review and the
multi-escrow/shared-ledger adversarial acceptance test below.

1. **Escalation authority:** remove public transition authority from
   `executeEscalation()` and `executeEscalationWithQuote()`. Keep quote functions
   public and read-only. Bind execution to the registered calling escrow and
   verify the quote root and current workflow state at execution.
2. **Per-escrow authorization:** for every DRM and incentive state-changing
   operation that accepts `escrowContract`, require `escrowContract == msg.sender`
   when called by an escrow, or authenticate the resolution module and verify
   that it acts on a registered escrow's current workflow. A caller being
   registered must not grant authority to mutate another escrow's state.
3. **Assignment-scoped capacity:** replace resolver-only decrement operations
   with a single-use record keyed by `(escrowContract, workflowId)` that stores
   its assigned round and resolver. Reject duplicate assignment and release;
   capacity counters change only through these keyed transitions. Implemented
   and covered by focused capacity tests.
4. **Authenticated bond disposition:** refunds, forfeitures, and resolver
   payouts must derive from a one-time DRM decision transition for that exact
   escrow/workflow/round. Do not accept caller-supplied `outcomeFlipped` or
   arbitrary escrow identity as sufficient proof of disposition.
5. **Decision finality:** only the resolver assigned to the current round may
   submit its decision, exactly once. Reject a second decision, stale-round
   decision, or any decision after terminal finalization. Bond settlement must
   consume that same authenticated decision record.

**Required invariant:** no caller may alter another escrow's dispute, resolver
assignment, appeal state, capacity, or bonded entitlement merely because that
caller is registered with a shared module.

**Acceptance evidence:**

- Focused access-control tests for every state-changing DRM and incentive entry
  point, including the two public escalation entry points.
- Two independently registered escrow contracts sharing one DRM and one
  BondLedger, with adversarial cross-escrow attempts at escalation, decision,
  capacity release, appeal state mutation, and bond disposition.
- Tests proving public quote access cannot mutate state; assignments, decisions,
  capacity releases, and bond settlement are workflow-bound and single-use.
- Tests proving only the assigned resolver can decide once per round and that
  final state cannot be overwritten.
- Passing CI on the exact amended source revision, an independently reviewed
  full-appeal artifact bundle/root, and a separate deployment qualification for
  that profile. Sew Core's existing qualification does not substitute for these
  gates.

**Remaining acceptance gap:** current tests cover cross-escrow spoofing with a
registered test-contract stand-in and bond-ledger behavior in differential
stacks. I did not find a single adversarial regression with two separately
deployed escrow vaults sharing the same DRM and BondLedger. Add that test before
calling the P0-A acceptance evidence complete. Independent security review of
the exact source revision and artifact root also remains pending.

### Finality → bond → slashing lifecycle review (2026-11-27)

The current transition sequence is:

1. Escalation authenticates the calling escrow, checks the current appeal quote,
   advances the workflow round, transfers capacity/stake assignment, reopens
   the decision state, and records the next resolver.
2. `recordResolution` authenticates the escrow and assigned resolver, permits
   one decision in the open round, and moves the round to `Decided`. On a higher
   round it derives whether the outcome flipped from the stored prior decision
   and settles that round's appeal bond through the DRM-only incentive adapter.
   A bond-settlement failure reverts the decision transition atomically.
3. A changed higher-round decision invokes the reversal-slashing hook in the same
   transaction. At the default zero penalty, the hook is now a no-op and the
   decision/bond transition proceeds. If governance enables reversal slashing,
   the slash executes immediately although the new round may still be appealed.
   A later vindication records a USD receivable and marks the slash
   `REVERSED_WITH_CREDIT`; it does not restore funded stake.
4. After the appeal window (or at the final round), `finalizeDispute` releases
   the active resolver assignment, finalizes staking, sets DRM status to `Final`,
   and calls incentive finalization to forfeit any still-pending appeal bonds.
   These required hooks are in one EVM transaction: a revert rolls the entire
   finalization back.
5. A pending timeout/fraud slash follows a separate slash lifecycle: appeal
   submission blocks execution; governance may resolve it, or expiry cancels
   the slash in the resolver's favor. Rejected appeals leave a pending slash
   eligible for execution after the contest window.

The state machine has atomic decision-to-bond settlement and finalization-to-
cleanup, but the review found a DR v3 liveness defect at the reversal-slash
boundary: `recordResolution` calls `slashForReversal` whenever a later decision
changes the prior outcome, while `ResolverSlashingModule.slashForReversal`
reverts when `reversalSlashBps == 0` (the default). With the slashing module
wired in and reversal slashing disabled, a valid changed decision therefore
reverts atomically, including its appeal-bond settlement. Fix this by making
the DRM skip the slash call when the configured penalty is zero, or by making
the module return a no-op result for the disabled policy; add an integration
test proving the changed decision and bond disposition succeed at zero bps.

Separate DR v3 gates remain: the vindication receivable has no funded
redemption path and must not count as stake or withdrawable collateral;
mixed-token exposure is unsupported. If reversal slashing is enabled, immediate
slashes make that receivable path operationally relevant when a later round
vindicates a resolver. Keep DR v3 economic reliance blocked until the liveness
defect, funding policy, mixed-token policy, and independent qualification are
resolved.

### Profile-specific follow-up gates

These issues should remain distinct from P0-A and from the standalone Sew Core
release boundary.

| Profile | Required work before qualification |
|---|---|
| Full appeal | P0-A code remediation and artifact qualification are complete on `69ac7c7b`; independent security review and any target-network deployment qualification remain pending. The 11 skipped-test identities/reasons are recorded below; none is a P0-A acceptance test. |
| DR v3 staking/slashing | Role revocation on module rotation, slashable locked-stake treatment, funded vindication accounting, and the single-use stake lifecycle have code changes and regression coverage. Mixed-token valuation and liquidation policy remain unsupported; keep mixed-token DR v3 disabled until those policies are specified and independently qualified. |
| Yield-backed settlement | Exact approvals and residual allowance clearing, shared-vault isolation, per-workflow recovery, and shortfall conservation are implemented and tested. Add adversarial qualification for compromised or replaced yield modules before enabling this profile. |
| Incentive accounting | Per-workflow payout policy snapshots and atomic required finalization hooks are implemented and covered by the passing full suite; retain this evidence in any future profile artifact qualification. |

### Independent review follow-up (SA-02 through SA-06)

The retained `sew-full-appeal` candidate remains unchanged. The following
source and documentation updates create a new candidate and do not alter its
recorded bundle root.

| Finding | Current disposition |
|---|---|
| SA-02 — incentive module rotation during active appeals | Remediated in candidate `ae3d6f20` plus the current continuation: `setIncentiveModule` rejects a changed address while `activeDisputeCount != 0`. Focused test proves it is allowed again after terminal finalization. |
| SA-03 — staking module rotation during active assignments | Remediated with the same active-dispute guard. Focused test proves rotation is blocked while assigned and allowed after finalization. The separate shared-ledger adversarial case now uses two actual escrow instances. |
| SA-04 — profile dependency boundary | Documented and represented in `config/sew-full-appeal-capabilities.json`; qualification checks the allowlist exclusions and records exact post-deployment assertions. Deployment-runner consumption of those assertions remains required before activation. |
| SA-05 — canonical source repository | Export provenance now names `Sew-Protocol/sew-protocol`, and Full Appeal qualification asserts it. Existing reviewed bundle manifests remain unchanged. New-candidate CI has not yet run. |
| SA-06 — independent Solidity build | A separate CI job now checks out the exact source in a fresh job, rebuilds with pinned Foundry, exports the bundle, and compares the full bundle root to the primary job's artifact. This gate is implemented but awaits a passing CI run on the new candidate. |

The Full Appeal qualification now hard-fails on any allowlisted artifact over
EIP-170. The retained candidate's measured oversized runtimes are
`EscrowVault` (37,764 bytes), `DecentralizedResolutionModule` (37,116 bytes),
and `ResolverIncentiveModuleV2BondLedger` (27,097 bytes). FASA-04 refactoring
of those three contracts remains incomplete; FASA-05's size gate is implemented
and will reject this baseline until each runtime is at most 24,576 bytes.

The zero-penalty reversal-slashing path now returns a no-op rather than reverting.
The focused slashing regression and the two-escrow/shared-DRM/shared-BondLedger
adversarial test pass. The Full Appeal bundle's prior root remains unchanged;
the new candidate has a different source revision and must receive its own
artifact root and CI/security review.

Focused Foundry regressions pass for module rotation (2/2), disabled reversal
slashing (1/1), and two deployed escrows sharing one DRM and BondLedger (1/1).
These focused results do not replace the full Foundry suite, new-candidate CI,
independent security review, or runtime assertion checks against deployed
contracts.

### P0-A and profile remediation evidence

The following remediations are committed and pushed; the exact source revision
and artifact qualification evidence are recorded here:

- P0-A escalation, escrow identity, resolver decision finality, bond disposition,
  and assignment-scoped capacity protections have been implemented or tightened.
- Profile-specific updates address stale staking roles, funded vindication
  accounting, locked-stake slash semantics, exact yield allowances, payout
  policy snapshots, and incentive finalization consistency.
- The full local Foundry run passed: 150 suites, 1,581 passed, 0 failed, and 11
  skipped (1,592 total), on the committed code revision including the final
  stale-assignment consistency check.
- The exact tested code revision is `9290e814f8463207516b5a44271aedd36b74ac49`.
- On the pushed source revision `3a192922b64a167eabcf1e27cd198922784b3078`,
  the full-appeal allowlist (`@sew/deployables@0.2.0`) was built from a clean
  checkout, exported twice, and validated. Both 20-artifact exports produced
  bundle root
  `e77639a6d390dfdc2ed8b1de42d5d64f12e87f776e853e4836e10c298fe28795` with
  solc `0.8.37+commit.f401782d`, Osaka EVM, 200 optimizer runs, and `viaIR`.
  This establishes reproducible local bundle identity, not independent
  security review, network-specific size acceptance, or deployment readiness.
- Commit `b6cf7017767f0ac7e7df89e4f3ad0e2c7f1f6229` adds the source-bound
  full-appeal CI qualification gate. Its CI run (`45888237415`) and CodeQL run
  (`45888237309`) both passed. The 20-artifact full-appeal root for this exact
  source is `4a12afdd99f3cbecac4e3aeb3ca563348eb9ffc971f653b2ba1c520e756caf8f`.
- The 11 skipped tests and reasons were: `Phase0BaseSepoliaForkTest.setUp`
  (deployment artifact unavailable); `Phase1CoreJourneysBaseSepoliaForkTest.setUp`
  (deployment artifact unavailable); `SecurityAttackSimBaseSepoliaForkTest.setUp`
  (Base Sepolia artifacts unavailable); `AaveYieldModuleForkTest.setUp`,
  `AaveYieldModuleForkTestExpanded.setUp`, and
  `AaveYieldModuleForkTestPinned.setUp` (Aave pool has no code without the Base
  Sepolia fork); `AaveYieldModuleMainnetForkTest.setUp` (Aave pool has no code
  without the Base mainnet fork); `EmergencyRecoveryProposalTest.setUp`,
  `PauseLocking.setUp`, and `EscrowLifecycleTest.test_PauseUnpause_AccessControl`
  (pause tests disabled by `RUN_PAUSE_TESTS=false`); and
  `EscrowVaultAccountingTest.test_recovery_accounting` (placeholder test).
  None is a P0-A acceptance test, but the fork-dependent behaviors remain
  unqualified against live network state.
- The focused dispute-capacity suite passed 14/14. Source-boundary generation
  and checking, direct TypeScript typechecking, and the standalone Sew Core
  size build also passed. SewCoreVault remains 24,357 runtime bytes, 219 below
  EIP-170.
- The full-protocol `forge build --sizes` remains blocked by oversized
  non-Sew-Core contracts; this does not affect the separate Sew Core package
  size gate. Independent review and chain-specific deployment qualification
  remain outstanding.

The full-suite result, exact skipped identities and reasons, package size,
source revisions, and artifact roots are recorded above. Any test required for
a P0 acceptance claim must not be skipped.

The standalone Sew Core candidate remains limited to its pinned 13-artifact
bundle and supported deployment graph. Its 219-byte runtime margin is small:
any Solidity change requires a new size check, artifact root, and qualification.
Do not infer full-protocol readiness from its tests or bundle.
