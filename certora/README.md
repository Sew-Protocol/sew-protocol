# Certora Formal Verification — SEW Protocol

This directory contains Certora CVL 2.x specifications for `EscrowVault`.  They form
the highest-assurance layer of the SEW protocol safety programme, above Monte Carlo
simulation, the Clojure contract model, Foundry invariant tests, and Halmos symbolic
execution.

---

## What Is Being Proved

Five invariants are specified, each with a precise correspondence across the three
verification layers:

| # | Property | CVL form | Clojure (invariants.clj) | Halmos check |
|---|----------|----------|--------------------------|--------------|
| 1 | **Solvency** | `invariant` | `inv/solvency?` | `check_solvency_after_create` |
| 2 | **Fee monotonicity** | `rule` | `inv/fees-monotone?` | `check_fees_monotone_after_create` |
| 3 | **State irreversibility** | `rule` | `inv/state-irreversible?` | `check_released_state_absorbing` |
| 4 | **Resolver exclusivity** | `rule` × 2 | `auth/authorized-resolver?` | `check_custom_resolver_exclusivity` |
| 5 | **Appeal window** | `rule` | `inv/appeal-window-enforced?` | `check_appeal_window_enforced` |

A sixth supplementary rule (**principal conservation**) checks that
`totalHeldInEscrowPerToken[token] ≤ vault.balanceOf(token)` independently of fee
accounting, isolating `BalanceUpdateLibrary` bugs.

### What each invariant proves

**1. Solvency** (`invariant solvency`):  
For every ERC-20 token `t`:
```
totalHeldInEscrowPerToken[t] + totalFeesPerToken[t] ≤ IERC20(t).balanceOf(vault)
```
The vault can always honour every outstanding liability.  This is an `invariant` (not a
`rule`) so Certora also verifies it holds in the empty initial state.

**2. Fee monotonicity** (`rule feesMonotone`):  
`totalFeesPerToken[t]` never decreases except through `withdrawFees(address)`.  Prevents
fee drain by any user-callable function.

**3. Terminal state absorbing** (`rule terminalStateAbsorbing`):  
Once an escrow reaches `RELEASED` (2), `REFUNDED` (3), or `RESOLVED` (5), no function
can change its state.  Prevents double-release, double-refund, and re-opening of
finalized escrows.

**4. Custom resolver exclusivity** (`rule resolverExclusivityOnRelease` / `…OnCancel`):  
When `escrowSettings[id].customResolver ≠ address(0)`, only that address may succeed in
calling `releaseAsDisputeResolver` or `cancelAsDisputeResolver`.  A module-level or
governance resolver cannot override the per-escrow choice.

**5. Appeal window enforcement** (`rule appealWindowEnforced`):  
`executePendingSettlement` must revert when `block.timestamp < pendingSettlement.appealDeadline`.
Protects the losing party's right to appeal before the settlement is finalized.

---

## Directory Structure

```
certora/
├── confs/
│   └── escrow_vault.conf       ← certoraRun configuration
├── harness/
│   └── EscrowVaultHarness.sol  ← view-helper harness (not deployed)
├── specs/
│   └── EscrowInvariants.spec   ← CVL 2.x specification
└── README.md                   ← this file
```

---

## Prerequisites

1. **Certora Prover API key** — obtain from https://www.certora.com/  
   Set it as an environment variable:
   ```bash
   export CERTORAKEY=<your-key>
   ```

2. **certoraRun CLI** — install with pip:
   ```bash
   pip install certora-cli
   certoraRun --version   # confirm ≥ 7.x
   ```

3. **Node modules** (for OpenZeppelin imports):
   ```bash
   cd sew-protocol && npm install
   ```

---

## Running the Specs

```bash
cd sew-protocol
certoraRun certora/confs/escrow_vault.conf
```

The prover uploads the contracts, runs the SMT solvers in Certora's cloud, and returns
a URL to the results dashboard.  Expected output on a clean run:

```
[✓] solvency
[✓] feesMonotone
[✓] terminalStateAbsorbing
[✓] resolverExclusivityOnRelease
[✓] resolverExclusivityOnCancel
[✓] appealWindowEnforced
[✓] principalConservation
```

### Running individual rules

```bash
certoraRun certora/confs/escrow_vault.conf \
  --rule solvency
```

---

## Relationship to Other Assurance Layers

```
Monte Carlo (sew-simulation)
    └── 10 000 trials × 9 game-theory scenarios
    └── 99% confidence bond adequacy

Clojure contract model (sew-simulation/src/resolver_sim/contract_model/)
    └── Pure-function mirror of state machine
    └── test.check property tests (1000 random op sequences each)

Foundry invariant tests (test/foundry/invariants/)
    └── Handler-based invariant fuzzing with corpus
    └── 5 invariants × handler functions

Halmos symbolic execution (test/foundry/halmos/)
    └── 5 check_* property tests — 5/5 PASS
    └── SMT-bounded path exploration (loop 3)

Certora formal verification  ← THIS LAYER
    └── Unbounded proof over all reachable states
    └── Sound under NONDET module summaries
```

The key difference between Halmos and Certora:

| | Halmos | Certora |
|---|---|---|
| Approach | Bounded symbolic execution | Unbounded SMT proof |
| Loop depth | Bounded (loop_iter=3) | Unbounded (up to solver limits) |
| External calls | Concrete mock contracts | NONDET summarization |
| Verdict | "No violation found in bounded paths" | "No violation in any reachable state" |
| Tool | Open-source, runs locally | Commercial, cloud-based |

---

## Known Limitations and Modelling Choices

### NONDET module summaries
Resolution modules (`IResolutionModule`), release strategies (`IReleaseStrategy`), and
cancellation strategies (`ICancellationStrategy`) are summarized as `NONDET`.  The prover
considers all possible return values, which is **sound** for these invariants: if they
hold for every possible module response, they hold universally.

Implication: a malicious module that re-enters the vault is not modelled here.  A
reentrancy spec would require a `hook`-based ghost and a separate rule.

### ERC-20 DISPATCHER
Token behaviour uses `DISPATCHER(true)`, meaning the prover considers any ERC-20-compatible
implementation.  Fee-on-transfer or rebasing tokens may violate the solvency invariant;
the spec correctly surfaces this as a counter-example.

### Loop unrolling
`loop_iter: 3` in the conf file.  The prover unrolls loops up to depth 3 and treats
deeper iterations as `HAVOC`.  Increasing `loop_iter` gives stronger assurance but
increases solver time.

### Harness correctness
`EscrowVaultHarness.sol` adds pure view projections only; it introduces no new storage,
no new logic, and no new state transitions.  Each helper is a single-line storage read.

---

## Mapping to Solidity Error Codes

The spec verifies `lastReverted` patterns without prescribing which specific error is
thrown.  The corresponding Solidity errors are:

| Rule | Expected revert |
|---|---|
| `appealWindowEnforced` | `AppealWindowNotExpired(workflowId, deadline, now)` |
| `resolverExclusivityOnRelease` | `NotAuthorizedResolver(caller, customResolver)` |
| `resolverExclusivityOnCancel` | `NotAuthorizedResolver(caller, customResolver)` |
| `terminalStateAbsorbing` | various (TransferNotPending, TransferNotInDispute, …) |
