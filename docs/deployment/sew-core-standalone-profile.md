# Standalone Sew core deployment profile

Status: **candidate topology and in-tree source boundary are established; the
package build and focused profile tests pass. The root production build and
selected integration tests pass, but full-protocol qualification and live
execution remain incomplete**. This document records the minimum candidate
graph for `protocol-deployments`. It does not authorize signing or
broadcasting.

## Selected operations and topology

The v1 core is a single-token ERC-20 escrow with participant release, bilateral
cancellation, one default resolver dispute, timeout refund, pull settlement, and
guardian intake pause. A pause stops new escrow creation but leaves disputes on
existing escrows, settlement, claims, and withdrawals available. Appeals, Kleros, split settlement, partial release,
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
| 0 | `TimelockController` (local rehearsal only) | `../../node_modules/@openzeppelin/contracts/governance/TimelockController.sol:TimelockController` | Local package build resolves the fixture from the workspace root. Base Sepolia reuses the Governor-linked controller `0xD62A6C62233357B6681F9410218FE53BA931fDD1`; do not deploy a replacement. |
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
| 12 | `SewCoreVault` | `contracts/core/SewCoreVault.sol:SewCoreVault` | `escrowFeeBps`, nonzero `feeAddress`, `moduleManagementAddress = ModuleSnapshotRegistry`, immutable `supportedToken`; links `DisputeInitializationLibrary`, `DisputeRaiseLibrary`, `EscrowCreationLogic`, `EscrowDisputeLogic`, `EscrowSettlementLogic`, `StateManagementLibrary` |

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
| Base Sepolia EVM code-size behavior | network rule | the current unqualified working-copy build is 24,357 bytes against the 24,576-byte EIP-170 limit (219-byte margin); live network acceptance remains unverified |

## Artifact identity and current qualification status

The prior pinned 0.1.2 qualification used solc `0.8.37+commit.f401782d`, EVM
`osaka`, optimizer 200 and `viaIR=true`; its recorded `SewCoreVault` runtime is
23,586 bytes and initcode is 24,317 bytes. The current remediation working copy
uses the package Foundry profile with optimizer 1 and `viaIR=true`; its measured
runtime is 24,357 bytes and initcode is 25,172 bytes. The lower optimizer run
count favors deployment size and may increase execution gas; gas impact has not
been measured. This dirty candidate has not been exported, deterministically
reproduced, or independently qualified. The pinned 0.1.2 bundle and moved 0.1.3
candidate both passed their historical manifest, link-reference, bytecode-hash,
and deterministic re-export checks. The migration comparison shows all 13 ABIs and
metadata-stripped runtime code unchanged; the four stateful deployment
contracts have matching storage layouts. Full bytecode hashes differ where
source/remapping metadata changed, and the local Timelock fixture FQN now uses
a workspace-relative dependency path. The 0.1.3 candidate remains unqualified.
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
allowlist, focused profile test, and the canonical 51-file Solidity source
closure used by its 13 artifact roots. Full-protocol sources and tests import
those package sources; Sew-core sources do not import from the root
`contracts/` tree. No `escrow-kernel` package was introduced. The root Foundry
project remains the full-protocol integration authority, while the package has
its own Foundry configuration for a scoped build and profile test.

The generated consumer inventory is
`packages/sew-core/source-boundary.json`. It records remaining full-protocol
consumers and is regenerated by the package `source:inventory` command. The
pinned Sew-core 0.1.2 ABI and creation/runtime bytecode hashes are captured in
`packages/sew-core/deployment-baseline-0.1.2.json`. Source relocation changes
source identity and may change bytecode metadata. The moved package is a new
candidate: it must pass standalone and root integration builds/tests, and its
ABI, selectors/events/errors, storage layout, creation/runtime bytecode,
compiler settings, remappings, and deterministic deployable export are
compared in the retained migration snapshots. The 0.1.2 deployment bundle has
not been replaced or requalified. The migration run exposed a pre-existing
cheatcode-ordering bug in `DirectResolutionConfigSelectionIntegrationTest`,
which also failed at the pinned 0.1.2 source revision. The test setup was
corrected without changing contract behavior; all six tests in that suite now
pass. The root core suite passed 613 tests (three skipped). The complete root
Foundry suite has now passed end to end: 1,540 passed, zero failed, and 11
skipped across 150 suites, including the long invariant workloads.

### Shared deployment-engine qualification

The deployment engine now accepts a standalone Sew plan through the shared
plan schema and resolver. PRF initial-input approvals are required only for
plans that select PRF units or contracts. Qualification confirmed that the
Sew plan resolves without PRF inputs and that a PRF plan still fails closed
when its approvals are missing.

The pinned `@sew/deployables` 0.1.2 profile was rehearsed through the normal
deployment CLI, durable deployment record, bootstrap journal, linked library
bindings, and manifest generation on an isolated Anvil chain with the normal
EIP-170 size limit. The run verified 14 deployments, 49 bootstrap actions and
31 final assertions, with one local slow-lane time advance and zero public
network transactions. Evidence is retained in
`protocol-deployments/config/sew-core/observations/engine-rehearsal-20261116.json`.
The deployment repository's full suite passed 477 tests with five skipped;
its opt-in PRF adapter integration suite passed all five tests.

This qualifies the generic local execution path, not Base Sepolia deployment.
The Base Sepolia profile still needs an executable plan that models the
existing Governor-linked Timelock and Sew Token as external contracts,
including the observed Timelock runtime hash and live ABI/role assertions.
Then the exact plan must pass a pinned Base Sepolia fork rehearsal with the
existing governance handoff. Base Sepolia signer keys and an RPC provider
credential were exposed during local inspection and must be rotated before
any signing. Governance
delegate choice, guardian/resolver/fee-recipient assignments, dispute bounds,
fresh asset and governance observations, and independent review also remain
launch gates. The deployment profile remains blocked and the 0.1.2 bundle has
not been replaced or requalified.
