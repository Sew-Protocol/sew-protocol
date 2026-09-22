Target: 99% coverage — practical definition

To reach (and keep) 99%, you need to cover:

All public/external functions (success + key reverts)

All state transitions (PENDING→DISPUTED→(PENDING_SETTLEMENT)→RELEASED/REFUNDED/RESOLVED etc.)

All integration edges (module management, module registry, evidence module, yield ops, Aave adapter)

All “best-effort” paths (call failures, non-standard ERC20, fee-on-transfer, reverting token, reverting pool)

Test architecture (what to build)
1) Foundry suites (primary)

Create 5 focused suites:

EscrowLifecycle.t.sol (end-to-end happy paths + main state machine)

DisputeFlow.t.sol (raise dispute, resolver actions, pending settlement/appeal window)

YieldFlow.t.sol (yield presets, yieldOps integration, Aave adapter)

GovernanceAndModules.t.sol (ModuleRegistry + ModuleManagement + EscrowAdmin + wiring)

ERC20EdgeCases.t.sol (fee-on-transfer, non-standard, rebasing, revert, insufficient balance)

Plus:

Invariants.t.sol (Foundry invariant tests)

Fuzz_*.t.sol (targeted fuzz for amount/time/role bounds)

2) Hardhat tests (optional / minimal)

Only keep Hardhat where you need:

Frontend-compatible ABI expectations

Ethers.js integration style checks

Existing coverage pipeline if it’s already wired
But for 99%, Foundry coverage must be the source of truth.

Coverage map by contract (what to test)
Core escrow custody & state machine
BaseEscrow.sol (highest branch density)

Must cover:

Pause/unpause access control

Admin setters (fee recipient, fee bps, yield/bond protocol fee bps, resolution module, timeout config)

Ops wiring setters (CreateOps, SettlementOps, BondCollector, Aave library toggles if still present)

createEscrow:

normal ERC20 transfer

fee-on-transfer deficit branch

settings validation paths

yield enabled / disabled branches

module snapshot paths

Timed actions:

automateTimedActions returns false branches

auto release + auto cancel + pending settlement execution path

Cancel paths:

senderCancel / recipientCancel (wrong caller, wrong state)

confirm cancel when both agree

raiseDispute:

wrong state

non-participant

dispute init module call updates resolver

resolver callback call

incentive module hook success/fail telemetry

escalateDispute (if in scope for IEO):

escalation not allowed

bond query fail

msg.value validation branches (ETH vs ERC20 bond)

ERC20 bond pull + BondCollector path

refund excess ETH

Resolution:

_executeResolution authorization checks

settlementOps branches (execute now vs pending settlement)

pending settlement storage and later execution

finalize dispute call best-effort

Withdraw:

not finalized state revert

claimable balance 0 revert

success path resets mapping

Recovery:

recover success

recover branches from RecoveryLibrary (insufficient contract balance)

Key invariants to enforce:

totalHeldInEscrowPerToken[token] + totalFeesPerToken[token] <= IERC20(token).balanceOf(escrow)

Once escrowState is final, it never re-enters PENDING/DISPUTED

Claimable balances only increase when push transfer fails

EscrowVault.sol

Must cover:

Constructor checks (zero addresses, fee bounds)

releaseEscrowTransfer only sender + pending

Fee withdrawals:

no fees revert (if implemented)

success transfers to fee recipient

recoverERC20:

cannot recover escrowed funds or fees beyond available

success emits

Module management calls: queueModule, activateModule role checks

Module getter logic for each module type (snapshotted vs registry vs default fallback)

EscrowableERC20.sol

Treat as a “tokenized escrow” variant:

Mint/burn or transfer hooks (whatever escrowable means in your design)

Ensure it shares the same BaseEscrow behaviors

Any extra ERC20 compliance paths (allowances, transfers) if present

EscrowViewContract.sol

Coverage should be straightforward:

All view functions:

valid workflowId

invalid workflowId revert

verify it returns expected derived fields (resolver, modules, settings, pending settlement)

Ops contracts
CreateOps.sol

Compute creation with default settings

Validate fee calculation

Yield-enabled vs disabled

Any revert codes / validation codes

YieldOps.sol

handleYield:

module not set / not contract

gen module token unsupported

deposit/withdraw failures handled best-effort

distribution data derived correctly for each preset

protocol fee bps clamping / fee recipient missing branches

distributeWithdrawnYield:

distribution module call failure

partial distribution / return data malformed

Must include tests for:

YieldPreset.OFF

“split yield” presets

protocol fee collection event correctness

SettlementOps.sol

computeResolutionExecution: immediate vs pending settlement based on appeal window config

computePendingSettlementExecution: all revert reasons path coverage

computeTimedActions: actionType 0/1/2/3 paths

DisputeOps.sol

computeEscalation: allow/deny conditions

New resolver selection & level transitions

Ensure it matches your DisputeEscalationLibrary expectations

Governance / module plumbing
ModuleManagementContract.sol

queue/activate

time delays / SlowLane rules (if used)

Snapshot semantics (what gets used for existing workflows)

Role gating (timelock only)

EscrowAdminContract.sol

All admin setters

Role checks

“guard rails” (fee recipient required when fee > 0, bounds checks)

ModuleRegistry.sol

Register/unregister modules

Versioning/typing logic

“only owner/admin” access rules

Lookups: missing module branches

Resolution / release / distribution modules
DefaultResolutionModule.sol

getDisputeResolver path

initializeDispute path

isAuthorizedDisputeResolver path

finalizeDispute best-effort path

Edge: malformed escrowData, resolver unset

DefaultReleaseStrategy.sol

All release conditions

Timeout-based release/cancel if applicable

Ensure it’s used via module wiring tests

DefaultYieldDistributionModule.sol + TestYieldDistributionModule.sol

Each distribution preset (to sender, to recipient, split, custom)

Failure modes: revert on transfer, non-standard ERC20

Protocol fee integration if it applies here

AaveYieldGenerationModule.sol (adapter)

Even if you keep Aave logic isolated here, you must test:

deposit flow with MockAavePool

withdraw flow returning:

exact principal

principal (yield)

< principal (loss / principal shortfall handling)

Pool revert path: MockAavePoolReverting

aToken lookup correctness

Token support gating

Any internal accounting you maintain (shares, indexes)

DefaultYieldModule.sol

If it’s a non-Aave yield mock/module:

Basic deposit/withdraw hooks

Used for non-Aave coverage and deterministic tests

Evidence module (in scope for IEO?)
EvidenceModuleV1.sol

submit evidence

retrieve evidence

authorization rules

edge: workflow not exist / invalid state

Libraries (how to cover them properly)

Libraries don’t get “called” directly in tests, but you can still cover them by:

Driving call paths in the contracts that use them

Adding a small LibraryHarness.sol only for tests (internal methods exposed) when a library has complex branches that are hard to hit indirectly.

Prioritize harnesses for:

SettingsValidationLibrary (time bounds, presets, invalid combos)

StateManagementLibrary (every transition)

EscrowEncodingLibrary (encode/decode correctness)

YieldPresetLibrary (each preset branch)

DisputeInitializationLibrary (module call results & error branches)

RecoveryLibrary (available balance branches)

YieldDistributionLibrary (split math & fee math)

ResolutionTableLibrary (if has branchy table lookups)

The “99% plan” as a checklist you can execute
Phase 0 — Measurement baseline (1 hour)

Use Foundry coverage as truth:

forge coverage --report lcov

Generate HTML report (lcov -> genhtml)

Create a spreadsheet/markdown “coverage scoreboard”:

per contract: lines hit %, branches hit %, functions hit %

list top 20 uncovered line ranges

Phase 1 — Hit every external/public function once (fastest gains)

Write one test per function for the happy path.

Goal: 85–92% quickly

Phase 2 — Systematically cover revert branches (the push to 99%)

For each contract:

Add “revert matrix” tests:

wrong role

wrong state

invalid workflowId

invalid config inputs

external call failures (mock reverts / malformed return data)
This is what gets you from ~92% to ~99%.

Phase 3 — Edge token behaviors (coverage + real safety)

Use your mocks:

Fee-on-transfer: assert AccountingDeficit triggers

Non-standard ERC20: assert _tryTransfer handles no-bool returns

Reverting token: fallback to claimable balances & OperationFailure events

Rebasing token: ensure invariants don’t assume static balance

Phase 4 — Invariants / fuzz (keeps 99% from regressing)

Add invariants:

total accounting never exceeds actual balance

claimable balance conservation

state machine monotonicity
Add fuzz:

amount ranges (0, 1, max uint64, etc.)

time leaps around deadlines (appeal window boundaries)

role permutations

Test suite structure (recommended repo layout)
test/
  core/
    EscrowLifecycle.t.sol
    EscrowCancel.t.sol
    EscrowDispute.t.sol
    EscrowResolution.t.sol
    EscrowWithdraw.t.sol
    EscrowTimedActions.t.sol
    EscrowViews.t.sol
  yield/
    YieldOps.t.sol
    YieldPresets.t.sol
    AaveYieldGenerationModule.t.sol
    YieldFailureModes.t.sol
  governance/
    ModuleRegistry.t.sol
    ModuleManagement.t.sol
    EscrowAdminContract.t.sol
  libraries/
    SettingsValidationHarness.t.sol
    StateManagementHarness.t.sol
    YieldPresetHarness.t.sol
    RecoveryHarness.t.sol
  invariants/
    EscrowInvariants.t.sol

“Out of scope” handling (decentralized resolution)

Keep decentralised module contracts excluded from the 99% target for IEO by:

Separate test folder test/ddr/

Coverage filtering config (so your 99% KPI is for “IEO scope” contracts)

But still add a small smoke test that the interfaces compile and basic wiring doesn’t break.

Assumptions

You’re willing to treat Foundry coverage as the KPI source (Hardhat coverage can remain supplementary).

IEO scope excludes the decentralized dispute resolution module package (as you indicated).

You already have mocks deployed in tests and can extend them for malformed return data / partial failures.