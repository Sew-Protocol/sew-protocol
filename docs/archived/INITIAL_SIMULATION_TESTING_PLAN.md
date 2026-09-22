# Initial Simulation Testing Plan (Base Sepolia)

**Scope:** Base Sepolia (chainId 84532)  
**Release focus:** IEO release first (core modules), then Aave modules, then decentralized dispute resolution staged **DR1 → DR2 → DR3**.  
**Goal:** Establish a practical, repeatable simulation regimen that (a) stress-tests dispute resolution robustness and (b) exercises deployed contracts under realistic interaction patterns.

---

## Why “simulation” (vs just unit tests)

Unit tests prove local correctness for known cases. Simulation testing is about:

- **Adversarial sequencing**: unexpected but valid interleavings and timing.
- **Economic robustness**: bond/fee/timeouts staying safe across parameter ranges.
- **Deployed wiring confidence**: the real deployed addresses and roles behave as assumed.
- **Operational reality**: keeper-like calls, retries, gas spikes, partial outages.

This plan is deliberately staged so you get high-signal results quickly, then add complexity.

---

## Testing pillars

### A) Dispute resolution robustness
Target: **no safety failures**, **bounded griefing**, **liveness under honest assumptions**, and **economically unattractive attacks**.

Core invariants (assert in fuzz/simulation runs):

- **Funds safety**: no theft, no double-withdraw, no negative accounting.
- **Single-finality**: each workflow reaches one terminal outcome (released/refunded/resolved) and cannot oscillate.
- **Permission boundaries**: only intended roles can perform privileged actions (timelock/guardian/admin-contract).
- **Liveness**: honest participants can complete flows within configured timeouts under realistic delays.
- **Bounded griefing**: attackers cannot induce unbounded cost or permanent locks beyond configured caps.
- **Economic bounds**: modeled attacker profit is ≤ 0 under assumed parameters.

### B) Deployed contract “real world” interactions
Target: verify the deployed system wiring, roles, and state-machine behavior under realistic user/keeper patterns.

Approach:

- **Fork-based interaction testing** pinned to the deployed block.
- **Scenario journeys** (end-to-end sequences) with “chaos knobs” (delays, retries, gas spikes).
- **Coverage metrics**: state coverage + event coverage + revert reason frequencies.

---

## Phase 0 — Deployment health + fork smoke (Base Sepolia)

**Goal:** “What’s deployed is real and callable” + minimal E2E lifecycle confidence.

### 0.1 What Phase 0 checks

- **Bytecode presence**
  - Every `deployments/baseSepolia/*.json` address has non-empty code on the fork.

- **Core wiring**
  - `EscrowVault` points to the expected:
    - `YieldOps`, `DisputeOps`, `CreateOps`, `SettlementOps`, `BondCollector`
    - `ModuleManagementContract`

- **Ops registration**
  - Ops contracts grant `ROLE_ESCROW_CONTRACT` to `EscrowVault`:
    - `CreateOps`, `SettlementOps`, `DisputeOps`, `YieldOps`, `BondCollector`

- **Governance wiring (minimum)**
  - `TimelockController` is wired to `GovGovernor` as proposer/canceller.

- **Role surface sanity (minimum)**
  - Where supported, `TimelockController` has `ROLE_TIMELOCK` and `DEFAULT_ADMIN_ROLE`.
  - Where supported, `GuardianSafe` has `ROLE_GUARDIAN`.
  - `EscrowAdminContract` has `ROLE_ADMIN_CONTRACT` on `EscrowVault` (required for slow-lane config).

### 0.2 Minimal Phase 0 E2E (runs entirely on fork)

The fork smoke should cover:

- **Escrow create → release**
- **Escrow create → 2-party cancel → refund**
- **Dispute open → resolve (as customResolver) → execute pending settlement**

Notes:

- This can run without requiring a real token on Base Sepolia by deploying a local `ERC20Mock` on the fork.
- The dispute path must advance time to pass the appeal window (or use a module/config that allows immediate execution).

### 0.3 Success criteria

- All deployment/wiring checks pass.
- E2E flows complete without unexpected reverts or stuck state.
- Script exits non-zero on any failure, so it can be used in CI.


### 0.4 How to run (recommended)

Foundry fork runner (preferred for Phase 0):

```bash
RPC_BASE_SEPOLIA="https://..." ./scripts/testnet/phase0-base-sepolia-health-foundry.sh
```

Optional:

- Pin a fork block:

```bash
RPC_BASE_SEPOLIA="https://..." FORK_BLOCK_NUMBER=12345678 ./scripts/testnet/phase0-base-sepolia-health-foundry.sh
```

- Enforce governance wiring as **hard failures** (instead of warnings):

```bash
RPC_BASE_SEPOLIA="https://..." PHASE0_STRICT_GOVERNANCE=1 ./scripts/testnet/phase0-base-sepolia-health-foundry.sh
```

### 0.5 Post-release fork regression (run after every Base Sepolia release)

**Goal:** After publishing a release to Base Sepolia, run fork-based tests pinned to a block *after* the release to validate deployed wiring + EscrowVault flows.

Prereq:

- Ensure `deployments/baseSepolia/*.json` and `deploy-registry/chain-84532.json` reflect the released addresses.
- Pick a block number **at or after** the release (e.g. the block containing the final deploy/wiring tx).

Run the post-release fork regression:

```bash
RPC_BASE_SEPOLIA="https://..." FORK_BLOCK_NUMBER=<BLOCK_AFTER_RELEASE> \
  ./scripts/testnet/phase0-base-sepolia-health-foundry.sh

RPC_BASE_SEPOLIA="https://..." FORK_BLOCK_NUMBER=<BLOCK_AFTER_RELEASE> \
  ./scripts/testnet/phase1-core-base-sepolia-sim-foundry.sh
```

Optional (DR staged fork suite):

```bash
RPC_BASE_SEPOLIA="https://..." FORK_BLOCK_NUMBER=<BLOCK_AFTER_RELEASE> \
  ./scripts/testnet/phase3-dr-staged-base-sepolia-sim-foundry.sh
```

---

## Phase 1 — Core modules: scenario simulations (IEO scope)

**Goal:** exercise core modules under realistic multi-actor behavior and operational variance.

### Phase 1 status in this repo (current)

There are now **two** testnet-oriented runners:

- **Stress (push/pull safe) release loop**:

```bash
BUYER_PRIVATE_KEY=0x... SELLER_ADDRESS=0x... ESCROW_TOKEN=0x... ESCROW_AMOUNT=100 NUM_TRANSFERS=25 DELAY_SECONDS=5 \
  ./scripts/testnet/stress-release-after-delay.sh
```

- **Phase 1 journeys (cancel + dispute cancel/release)**:

```bash
BUYER_PRIVATE_KEY=0x... SELLER_PRIVATE_KEY=0x... RESOLVER_PRIVATE_KEY=0x... ESCROW_TOKEN=0x... ESCROW_AMOUNT=100 \
  ./scripts/testnet/phase1-usdc-journeys.sh
```

**Important wiring dependency (Base Sepolia):** as of the latest inspection, both:

- `EscrowVault.disputeResolutionModule == address(0)`
- ModuleManagement default RESOLUTION module == `address(0)`

So “default resolver” flows are not yet available until a resolution module is deployed and set.

Inspect:

```bash
./scripts/testnet/inspect-resolution-module.sh
```

Fix (testnet convenience):

- Deploy and **immediately set** `DefaultResolutionModule` (bypasses slow lane, testnet-only):

```bash
DEPLOYER_PRIVATE_KEY=0x... INITIAL_RESOLVER=0x... ./scripts/testnet/deploy-default-resolution-module-and-set-immediate.sh
```

Production-like fix:

- Deploy and **queue** via slow lane, then activate after ETA:

```bash
DEPLOYER_PRIVATE_KEY=0x... INITIAL_RESOLVER=0x... ./scripts/testnet/deploy-default-resolution-module-and-queue.sh
# after ETA:
DEPLOYER_PRIVATE_KEY=0x... ./scripts/testnet/activate-resolution-module.sh
```

### 1.1 Deterministic “journeys” on fork

Create 10–20 scripts covering:

- Create/fund escrows under different settings (auto times on/off, yield preset off).
- Release/cancel/dispute flows with retries and delayed calls.
- Concurrent escrows (N users, shared ops, interleavings).

Chaos knobs:

- Random delays between steps, random gas price bumps.
- Forced failures (underpriced tx, revert/retry sequences).
- Keeper downtime windows (no ops calls for X blocks).

### 1.2 Stateful fuzz + invariants (local + fork replay)

Run state-machine fuzzing focusing on:

- Escrow state transitions and “only one terminal state”.
- Permission boundaries (timelock/guardian/admin contract).
- Non-blocking yield paths (even with yield preset OFF, validate the “yield not set” paths don’t brick state).

Outputs:

- invariant violation minimal reproducer sequences
- revert reason histograms

---

## Testnet deployed-contract validation (Base Sepolia): what’s left + highest priority

### Highest priority (blocking)

1) **Resolution module wiring**
- Deploy a `DefaultResolutionModule` and set it as `EscrowVault.disputeResolutionModule` (or set ModuleManagement default RESOLUTION).
- Without this, “default resolver” behavior is undefined and dispute flows require `customResolver`.

2) **Dispute finalization timing**
- Confirm which resolution module is active and whether dispute outcomes execute immediately or become a `PendingSettlement` requiring
  `executePendingSettlement()` after the appeal window.
- For testnet testing, either:
  - accept the wait (slow), or
  - use the “immediate set” script to wire a module + test using `customResolver` paths.

### Next priority (core correctness)

3) **Escrow status correctness at each step**

We have started checking this in `phase1-usdc-journeys.ts` (e.g., `PENDING` after create, `REFUNDED` after 2-party cancel,
`DISPUTED` after `raiseDispute`). The remaining “must-have” status assertions for testnet deployed contracts:

- **Create**
  - `escrowState == PENDING`
  - `senderStatus == NONE`, `recipientStatus == NONE`
- **Release (no dispute)**
  - `escrowState == RELEASED`
  - delivery happened (either ERC20 push transfer OR `claimableBalances + withdrawEscrow`)
- **2-party cancel**
  - after one party cancels: still `PENDING`, status flags reflect who cancelled
  - after both cancel: `escrowState == REFUNDED`
- **Raise dispute**
  - `escrowState == DISPUTED`
  - `senderStatus` or `recipientStatus` reflects who raised dispute
- **Resolve dispute**
  - If immediate execution: terminal state (`RELEASED` or `REFUNDED`)
  - If appeal window enforced: `pendingSettlements[workflowId].exists == true` and `escrowState == DISPUTED`
- **Execute pending settlement**
  - `pendingSettlements[workflowId].exists == false`
  - `escrowState` becomes terminal (`RELEASED` or `REFUNDED`)

4) **Role/permissions surface on testnet**
- Ensure only `disputeResolver` can call resolver actions.
- Ensure only buyer/seller can cancel/raise dispute.

### Lower priority (but valuable)

5) **Event completeness**
- Confirm expected events are emitted for:
  - `EscrowCreated`, `EscrowStateChanged`
  - `CancelRequested`, `CancelConfirmed`
  - `DisputeOpened`, `EscrowResolved`, `PendingSettlementSet`, `PendingSettlementExecuted`
  - `EscrowTransferAutoResult` (push vs pull vs automation)


## Phase 2 — Add Aave modules

**Goal:** validate yield flows and Aave failure modes without harming principal safety.

### Phase 2 status in this repo (current)

The current Aave yield generation module (`AaveYieldGenerationModule`) calls the pool from the module context, which means:

- **Strict pool semantics (Aave-like)**: `supply()` pulls from `msg.sender` (the module), so deposits will revert unless the module holds funds + has allowance.
- The Phase 2 tests therefore include **two pool models**:
  - a strict model to demonstrate the integration constraint (expected revert)
  - a simulated model to exercise module accounting/caps/yield end-to-end

Run:

```bash
./scripts/testnet/phase2-aave-modules-sim-foundry.sh
```

Key scenario set:

- deposit/withdraw cycles across time (interest accrual)
- partial liquidity / revert paths
- yield distribution failure handling

Key invariants:

- **Principal safety**: principal is never diluted by yield math/rounding.
- **No wrong-party yield**: yield distribution respects preset or module settings.
- **External revert safety**: Aave errors don’t brick escrow flows.

---

## Phase 3 — Decentralized dispute resolution staged: DR1 → DR2 → DR3

This phase is intentionally incremental: expand the adversary model and simulation harness without rewriting tests.

### Phase 3 status in this repo (current)

There is a **Base Sepolia fork** Foundry suite that exercises DR1 → DR2 → DR3 end-to-end against the deployed `EscrowVault`,
using a locally-deployed `DecentralizedResolutionModule` (plus incentive/staking/slashing modules as needed for each stage).

Run:

```bash
RPC_BASE_SEPOLIA="https://..." ./scripts/testnet/phase3-dr-staged-base-sepolia-sim-foundry.sh
```

Notes:

- The `DecentralizedResolutionModule.getRequiredAppealBond()` currently **enforces the bond token to match the escrow token** (ERC20),
  so DR2 uses the protocol `BondCollector` path (not `msg.value`).
- The fork suite sets `EscrowVault`’s resolution module **directly as `EscrowAdminContract`** for test stability, because Base Sepolia
  may not have `ROLE_TIMELOCK` fully wired on `EscrowAdminContract` yet.

### DR1 (first): deterministic rules + bonds/timeouts

What to test:

- timing games (last-moment actions)
- griefing attempts (delay/cost amplification)
- bond sizing via parameter sweeps (attacker EV ≤ 0)

How:

- stateful fuzzing over `openDispute / respond / timeout / resolve / withdraw`
- parameter sweeps over bonds/fees/timeouts

### DR2: decentralized participation (quorum/voting)

What to test:

- offline/abstention and liveness
- collusion threshold sensitivity
- bribery-like payoff modeling (simplified is fine initially)

How:

- agent-based simulation on top of the same action API (agents choose vote/participation)

### DR3: MEV-ish stress + governance interactions

What to test:

- front-run/back-run around resolution/finalization and payouts
- many concurrent disputes and resolver overload
- governance parameter updates mid-flight (timelock prevents instant capture)

How:

- concurrent runs (N escrows, M disputes), randomized interleavings
- “budgeted attacker” search for max-profit strategies

---

## Operational outputs to capture (all phases)

- **State coverage**: visited every state + transition at least once
- **Event coverage**: saw every critical event at least once
- **Revert histograms**: most common revert reasons under stress
- **Time-to-finality distribution**: median/p95 for each workflow class
- **Attacker ROI** (DR phases): success rate, cost, profit distribution

