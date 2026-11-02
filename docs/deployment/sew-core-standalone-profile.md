# Standalone Sew core deployment profile

Status: **candidate topology selected; an in-tree package/release boundary is
established, but the source is not yet independently buildable and live
execution is not qualified**. This document records the minimum candidate
graph for `protocol-deployments`. It does not authorize signing or
broadcasting.

## Selected operations and topology

The v1 core is an ERC-20 escrow with participant release, bilateral
cancellation, one resolver dispute, timeout refund, pull settlement, and
guardian intake pause. Appeals, Kleros, split settlement, partial release,
yield, staking/slashing, DR3, EAE, PRF, pro-rata, and multi-L2 are excluded.

Use `SewCoreVault` with `DefaultResolutionModule` as the default resolver
through `ModuleSnapshotRegistry`. Queue both the default release strategy and
the default resolution module and wait the registry's seven-day slow lane
before activation. Leave the direct vault resolution fallback unset. This
makes new escrow module snapshots point at the active, observable registry
defaults. Bilateral cancellation is native to the vault; no cancellation
strategy is deployed or registered.

## Minimum artifact and deployment graph

All identities are fully qualified names from the pinned `@sew/deployables`
manifest. The bundle contains 13 artifacts. Eight are library/dependency
artifacts and five application/authority artifacts.

| Order | Logical artifact | FQN | Constructor bindings / dependencies |
|---:|---|---|---|
| 0 | `TimelockController` (local rehearsal only) | `node_modules/@openzeppelin/contracts/governance/TimelockController.sol:TimelockController` | Local rehearsal deploys a fixture. Base Sepolia reuses the Governor-linked controller `0xD62A6C62233357B6681F9410218FE53BA931fDD1`; do not deploy a replacement. |
| 1 | `SettingsValidationLibrary` | `contracts/libraries/SettingsValidationLibrary.sol:SettingsValidationLibrary` | none |
| 2 | `EscrowCreationLogic` | `contracts/libraries/EscrowCreationLogic.sol:EscrowCreationLogic` | linked `SettingsValidationLibrary` |
| 3 | `EscrowDisputeLogic` | `contracts/libraries/EscrowDisputeLogic.sol:EscrowDisputeLogic` | none |
| 4 | `EscrowSettlementLogic` | `contracts/libraries/EscrowSettlementLogic.sol:EscrowSettlementLogic` | none |
| 5 | `DisputeInitializationLibrary` | `contracts/libraries/DisputeInitializationLibrary.sol:DisputeInitializationLibrary` | none |
| 6 | `DisputeRaiseLibrary` | `contracts/libraries/DisputeRaiseLibrary.sol:DisputeRaiseLibrary` | none |
| 7 | `StateManagementLibrary` | `contracts/libraries/StateManagementLibrary.sol:StateManagementLibrary` | none |
| 8 | `ModuleSnapshotRegistry` | `contracts/core/ModuleSnapshotRegistry.sol:ModuleSnapshotRegistry` | `initialAdmin = TimelockController` |
| 9 | `EscrowCreationPolicy` | `contracts/core/EscrowCreationPolicy.sol:EscrowCreationPolicy` | `initialOwner = TimelockController` |
| 10 | `DefaultResolutionModule` | `contracts/modules/DefaultResolutionModule.sol:DefaultResolutionModule` | `initialOwner = TimelockController`, `initialResolver = approved resolver` |
| 11 | `DefaultReleaseStrategy` | `contracts/modules/DefaultReleaseStrategy.sol:DefaultReleaseStrategy` | none |
| 12 | `SewCoreVault` | `contracts/core/SewCoreVault.sol:SewCoreVault` | `escrowFeeBps`, nonzero `feeAddress`, `moduleManagementAddress = ModuleSnapshotRegistry`; links `DisputeInitializationLibrary`, `DisputeRaiseLibrary`, `EscrowCreationLogic`, `EscrowDisputeLogic`, `EscrowSettlementLogic`, `StateManagementLibrary` |

The seven-library closure is transitive: `EscrowCreationLogic` also links
`SettingsValidationLibrary`. `EscrowVaultAccountingLibrary` is not part of
this profile. No other contracts are needed to perform the selected flows.

## Operation-to-contract closure

| Operation | Required call path and preconditions | Evidence required |
|---|---|---|
| Create/fund | non-deployer ERC-20 holder → `SewCoreVault.createEscrow` → `EscrowCreationPolicy`, active registry release/resolution snapshots, token `transferFrom` | escrow fields, module snapshot addresses, vault custody and accounting liabilities |
| Release | participant → `SewCoreVault.release` → snapshotted `DefaultReleaseStrategy` → pull claim | terminal state, recipient claim, fee and held-liability deltas; recipient withdrawal |
| Cancel/refund | recipient and sender → native bilateral cancellation → pull refund claim | both approvals, refunded state, refund liability and actual transfer |
| Open dispute | participant → `raiseDispute` → snapshotted `DefaultResolutionModule` | resolver address and dispute state readback |
| Resolve/settle | snapshotted resolver → resolver release/cancel entrypoint → settlement accounting → pull claim | unauthorized resolver rejection, correct terminal state and party claim, module state |
| Timeout | participant or keeper → timeout resolution after configured maximum duration | elapsed-time precondition, refund state and claim; no deployer required |
| Pause/recover | guardian pauses intake; Timelock alone unpauses and governs settings | guardian can pause but cannot configure/resolve/withdraw; Timelock action succeeds |

## Initial configuration commitment

These are expected *configured deployment values*, not assumptions that the
Solidity defaults are correct. The operator must put chosen values and their
hash into the deployment plan before execution. Any unresolved address or
value keeps the plan blocked.

| Setting | Candidate initial value | On-chain observation |
|---|---:|---|
| Escrow fee | `0` bps proposed | `escrowFee()` |
| Fee recipient | approved nonzero address | `escrowFeeAddress()` |
| Yield protocol fee | `0` | `yieldProtocolFeeBps()` |
| Appeal bond fee | `0` | `appealBondProtocolFeeBps()` |
| Default auto-release | `0` (disabled) | first `timeoutConfig` field |
| Default auto-cancel | `0` (disabled) | second `timeoutConfig` field |
| Maximum dispute duration | `90 days` | third `timeoutConfig` field |
| Appeal window | `0` (appeals excluded) | fourth `timeoutConfig` field |
| Minimum dispute amount | `1` token base unit in the source test candidate; operator approval required because this is a dust-level threshold | `minDisputeEscrowValue()` |
| Daily dispute limit | `10` per sender per day in the source test candidate; operator approval required | `maxDisputesPerSenderPerDay()` |
| Creation policy | deployed `EscrowCreationPolicy` | `creationPolicy()` and policy flags |
| Release module | `DefaultReleaseStrategy`, after slow lane | registry default and active module snapshot |
| Resolution module | `DefaultResolutionModule`, after slow lane | registry default, escrow snapshot and `resolver()` |
| Cancellation module | zero; native bilateral cancellation | registry default cancellation strategy is zero |
| Yield | disabled; vault rejects non-OFF preset | creation rejects non-OFF; registry yield defaults are zero |
| Pause | unpaused | `paused()` |

The `SewCoreVault` constructor initializes fee and timeout values, while
creation policy, module activation, role grants, dispute minimum/rate limit,
and final role revocation are bootstrap operations. A candidate run currently
uses a 100 bps source-test fixture to exercise nonzero fee conservation; this
is not the proposed initial fee. The test fixture explicitly sets the dispute
minimum to one token base unit and the rate limit to ten; these values remain
unapproved for any external deployment.

## Authority and bootstrap requirements

| Authority | Required final capability | Forbidden capability |
|---|---|---|
| Timelock | vault `DEFAULT_ADMIN_ROLE`, `ROLE_TIMELOCK`, `ROLE_ADMIN_CONTRACT`; registry admin/timelock; policy owner/admin; resolution module owner/admin; schedule/execute governance actions | none within selected governance scope |
| Governance proposer | propose/schedule a permitted Timelock operation | direct vault configuration |
| Governance executor | execute an operation after the selected delay; may be open execution only if explicitly selected | bypass of Timelock delay |
| Guardian | `ROLE_GUARDIAN` pause authority | configuration, unpause, resolver change, fee withdrawal, protected custody |
| Resolver | resolve only disputes assigned to that resolver snapshot | configuration, unrelated disputes, custody withdrawal |
| Fee recipient | withdraw accrued protocol fees | role administration or escrow configuration |
| Deployer | temporary bootstrap role only | any protected authority after handoff |

Bootstrap actions must be declared, journaled, and read back in order. On
Base Sepolia, bind the existing Governor-linked Timelock and Sew Token as
external dependencies; the local rehearsal may deploy its own Timelock fixture.
The selected Base Sepolia governance addresses are `GovGovernor`
`0xa9d598AE5b185dd249A1E4b64c32f18f4500d2fA`, token
`0x62BD47154D0b5Fe435F220E1294405040102b2ba`, and Timelock
`0xD62A6C62233357B6681F9410218FE53BA931fDD1`. The Timelock has a 48-hour
delay, Governor proposer/canceller roles, self-admin, and open execution. The
token observation recorded zero delegated votes. A pinned local Base Sepolia
fork rehearsal subsequently demonstrated proposal, quorum vote, Governor
queueing and Timelock execution after simulated self-delegation; public votes
remain zero unless a public delegation is authorized. The existing Timelock
runtime differs from the pinned Sew bundle artifact. The deployment engine
supports an explicit runtime hash pin, but the Sew-specific Base Sepolia
environment still needs to bind it and assert the live interface and roles.

1. For Base Sepolia, verify the existing Timelock's runtime hash, chain ID,
   delay, roles and Governor/token getter linkage; do not deploy a new
   Timelock. Deploy linked libraries, registry, policy, resolver module,
   release strategy, and vault; verify each successful canonical receipt and
   runtime hash before consuming its address as a binding. For local rehearsal,
   deploy the isolated Timelock fixture.
2. Install creation policy; register the vault; set dispute minimum/rate
   limit; grant Timelock, guardian and fee-recipient roles; verify each state.
3. Queue release and resolution modules; remain partial for the full delay;
   activate each only after its ETA and verify active defaults.
4. Use the successor Timelock to schedule and execute a permitted settings
   change. Verify the canonical successful receipts, calldata, caller roles,
   and resulting setting.
5. Only after all successor authority and reachability assertions pass, remove
   deployer `DEFAULT_ADMIN_ROLE`, `ROLE_TIMELOCK`, and every other role. Verify
   their absence and prove the deployer cannot reconfigure, resolve, withdraw
   protected funds, or bypass governance.
6. Mark bootstrap complete only when all receipts remain canonical, every
   asserted state is observed, modules are active, and the handoff operational
   path succeeds. An interrupted sequence remains partial and resumes by
   reconciling current chain state before each action.

## External dependency register

| Dependency | Classification | Required qualification |
|---|---|---|
| Base Sepolia ERC-20 test asset | external contract, not deployed by this package | use the operator-approved USDC test asset; independently refresh chain ID, code/runtime identity, decimals, pause/proxy implementation, balances and allowances immediately before run; establish exact-transfer behavior for deposit and withdrawal (fee-on-transfer/rebasing assets are unsupported) |
| Governance proposer/executor identities | external signers/contracts | approve identities, threshold and actual post-handoff schedule/execute reachability |
| Guardian, resolver, fee recipient | external identities | approve distinct roles and verify intended permissions on-chain |
| Base Sepolia EVM code-size behavior | network rule | linked vault runtime must fit active rule; latest source candidate build is 23,586 bytes versus observed 24,576-byte EIP-170 limit, but live network acceptance remains unverified |

## Artifact identity and current qualification status

The latest local source build uses solc `0.8.37+commit.f401782d`, EVM
`osaka`, optimizer 200 and `viaIR=true`; `SewCoreVault` runtime is 23,586
bytes and initcode is 24,317 bytes. The 13-artifact export passes manifest,
FQN, link-reference, bytecode-hash and deterministic re-export checks.
Focused Sew tests have passed (10 profile tests, plus 63 legacy extension
tests). The existing `@sew/deployables@0.1.2` bundle is pinned to clean source
revision `17bf2f0693367bfa3909a5aa186f4e806a76a5ea`. The deployment repository
records generic engine local and fork rehearsals for this bundle; the forked
executor used local chain ID 31337, so it does not qualify Base Sepolia
governance behavior. A separate pinned governance fork rehearsal at chain ID
84532 passed the Governor proposal/vote/queue/Timelock execution path after
simulated self-delegation. No Base Sepolia transaction has been signed or
broadcast.

### In-tree package extraction status

The workspace package `packages/sew-core` now owns the Sew-core deployable
allowlist, scope documentation entrypoint, and package commands. Its source
root still points at the monorepo `contracts/` tree, and its Foundry build uses
the root project configuration; this is a source boundary, not yet an
independently buildable source package.

The 13 artifact roots import 51 local Solidity files and 22 OpenZeppelin
sources. `SewCoreVault` inherits `BaseEscrow`, whose source imports appeal,
yield, Kleros and incentive components shared with the full protocol. Several
of the allowlisted libraries and default modules are also used by full-protocol
contracts. The next extraction step is to define a shared escrow-kernel
workspace dependency, then move Sew-owned contracts and focused tests into
`packages/sew-core` while retaining one canonical copy of shared source.

### Generic deployment-engine integration blocker

The current plan API is named and validated as a PRF successor plan, not a
reusable standalone Sew plan: its schema requires PRF unit fields,
`validatePlanAgainstUnits` rejects selecting `sew-protocol`, and both resolve
and deploy CLIs demand PRF initial-input approval whenever `--plan` is used.
The existing local Sew rehearsal script calls the generic deploy function but
performs bootstrap via its own direct send helper, so it does not get the
generic bootstrap attempt journal/recovery guarantees. Do not copy those
execution helpers into Sew-specific code.

The remaining shared correction is a profile-aware general deployment-plan
schema: preserve the PRF-specific unit/root/approval checks only for the PRF
plan identity, allow a Sew-only plan with generic `deploy` and
`external-preflight` stages, and require PRF approvals only when the selected
plan includes PRF units/contracts. Then integrate the Sew plan with the generic
deployment ledger, stage outputs, constructor/library bindings, bootstrap
journal, external-contract verification and manifest generation. The external
runtime-hash pin capability exists in the deployment repository, but the Sew
environment and plan have not yet been wired to it. Add independent checks
that a Sew-only plan resolves without PRF inputs while PRF plans still fail
closed without their approvals.

The deployment checkout's full suite currently has missing error-code
coverage for transaction replacement branches; Anvil-dependent engine tests
also cannot start in this sandbox, and two tests require write access to the
repository root for temporary fixtures. These are engine/rehearsal blockers,
not failures of the Sew Solidity profile tests.
