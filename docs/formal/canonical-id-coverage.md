+# Canonical Invariant Coverage Matrix (Simulator → Solidity Formal Checks)
+
+This document maps `resolver-sim.protocols.sew.invariants/canonical-ids` to current Solidity formal verification artifacts.
+
+## Scope
+
+- **Spec source (authoritative):**
+  `sew-simulation/src/resolver_sim/protocols/sew/invariants.clj`
+- **Foundry lane:**
+  `test/foundry/invariants/*`
+- **Halmos lane:**
+  `test/foundry/halmos/HalmosEscrowProperties.t.sol`
+
+---
+
+## Status legend
+
+- `covered`: explicit invariant/property exists in Foundry and/or Halmos
+- `partial`: adjacent checks exist, but parity is not complete yet
+- `deferred`: cannot be faithfully proven at this layer yet (or needs cross-module harness)
+
+---
+
+## Coverage table
+
+| canonical-id | status | verification lane | artifact(s) | notes |
+|---|---|---|---|---|
+| `:solvency` | covered | Foundry + Halmos | `StateInvariants.invariant_solvency`, `check_solvency_after_create` | Balance must cover held+fees |
+| `:fees-non-negative` | partial | Foundry | `StateInvariants.invariant_fees_monotone` | Monotone implies non-negative under normal initial conditions |
+| `:held-non-negative` | partial | Foundry | `invariant_solvency` (indirect) | Add explicit held-per-token non-neg assertion |
+| `:all-status-combinations-valid` | partial | Halmos | `check_released_state_absorbing` | Need full state-combination sweep |
+| `:pending-settlement-consistent` | partial | Foundry + Halmos | `EscrowInvariantHandler` paths + `check_appeal_window_enforced` | Add direct “pending only in disputed path” assertion |
+| `:dispute-timestamp-consistent` | deferred | Halmos (future) | — | Requires exposing timestamp internals consistently |
+| `:dispute-level-bounded` | deferred | Foundry/Halmos (future) | — | Escalation depth checks exist in DR module tests; unify into parity harness |
+| `:slash-status-consistent` | partial | Foundry | `decentralized-resolution-module/*` | Exists in module tests; not yet mapped in one parity file |
+| `:appeal-bond-conserved` | partial | Foundry | `AppealBondDistribution*.t.sol` | Needs canonical-id parity assertion naming |
+| `:appeal-bond-custody-consistent` | partial | Foundry | `AppealBondRecording.unit.t.sol` | Same as above |
+| `:no-auto-fraud-execute` | partial | Foundry | slashing module invariants/unit tests | Consolidate into canonical parity gate |
+| `:bond-liquidity` | partial | Foundry | staking/slashing invariant tests | Add explicit canonical-id mapping assertion |
+| `:bond-slash-bounded` | partial | Foundry | slashing invariants | Needs parity alias in matrix gate |
+| `:fee-cap` | partial | Foundry | accounting/fee scenario tests | Add direct invariant naming |
+| `:no-stale-automatable-escrows` | partial | Foundry | `automateTimedActions` handler paths | Add explicit post-automation invariant assertion |
+| `:conservation-of-funds` | partial | Foundry + Halmos | accounting invariants + solvency checks | Add exact deposited=held+released+refunded parity assertion |
+| `:dispute-resolution-path` | deferred | Halmos (future) | — | Structural liveness beyond bounded state safety |
+| `:slash-distribution-consistent` | partial | Foundry | appeal/slash distribution tests | Map into parity suite |
+| `:resolver-bond-mix-valid` | partial | Foundry | `StakingModuleInvariants.t.sol` | Already tested, not yet in canonical parity gate |
+| `:senior-coverage-not-exceeded` | partial | Foundry | staking invariants | Same as above |
+| `:resolver-not-frozen-on-assign` | partial | Foundry | slashing invariants | Same as above |
+| `:slash-epoch-cap-respected` | partial | Foundry | slashing invariants | Same as above |
+| `:reversal-slash-disabled` | partial | Foundry | slashing invariants | Same as above |
+| `:resolver-capacity` | partial | Foundry | dispute capacity tests | Requires canonical-id parity naming |
+| `:yield-position-consistency` | deferred | Foundry/Halmos (future) | — | Yield module variants and mocks need dedicated harness |
+| `:yield-exposure` | deferred | Foundry/Halmos (future) | — | Same as above |
+| `:terminal-states-unchanged` | covered | Foundry + Halmos | `invariant_terminal_states_absorbing`, `check_released_state_absorbing` | |
+| `:time-non-decreasing` | deferred | Foundry/Halmos (future) | — | Test VM time control is external; modeled as harness condition |
+| `:time-no-action-after-finality` | partial | Halmos | `check_released_state_absorbing` | Expand to all finality-gated actions |
+| `:finalization-accounting-correct` | partial | Foundry | accounting invariants | Needs transition delta assertion parity |
+| `:escalation-level-monotonic` | deferred | Foundry/Halmos (future) | — | Needs explicit escalation-state harness |
+| `:no-withdrawal-during-dispute` | partial | Foundry | `BondWithdrawalGuard.t.sol` | Resolver-stake scope present; unify in parity gate |
+| `:time-lock-integrity` | deferred | Halmos (future) | — | Requires same-block escalation modeling in bounded run |
+| `:token-tax-reconciliation` | deferred | Foundry/Halmos (future) | — | Needs fee-on-transfer token symbolic harness |
+| `:fees-monotone` | covered | Foundry + Halmos | `invariant_fees_monotone`, `check_fees_monotone_after_create` | |
+| `:single-resolution-payout-consistent` | partial | Foundry | core/dispute tests | Add explicit parity assertion |
+| `:fraud-slash-executions-accounted` | partial | Foundry | slashing/accounting tests | Map into canonical parity gate |
+
+---
+
+## Immediate G01 closure plan (execution order)
+
+1. Promote all `partial` rows to canonical parity assertions (either in `test/foundry/invariants/*` or in dedicated DR-module parity tests).
+2. Add a `formal-smoke` CI lane:
+   - Foundry invariants (`test/foundry/invariants/*`)
+   - Halmos bounded checks on selected `check_*` functions.
+3. Track `deferred` rows with explicit prerequisites (state exposure, symbolic harness constraints, or multi-module setup).
