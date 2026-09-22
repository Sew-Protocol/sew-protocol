# Incentive System Documentation Index

This document provides an index of all documentation related to resolver incentives, payments, staking, and slashing.

---

## Core Documentation

### Fee-Based Payments (DR v1/v2)

1. **`contracts/modules/decentralized-resolution-module/incentive/ResolverIncentiveModule.sol`**
   - Merged DR incentive module (V1 + V2): performance-based workload routing, EMA scoring, appeal bonds, escalation cost curves, bond distribution.
   - `ResolverIncentiveModuleV2BondLedger.sol` is the BondLedger-backed facade (unchanged).

2. **`docs/archived/INCENTIVE_MODULE_TEST_PLAN.md`**
   - Comprehensive test plan for the incentive module (legacy V1/V2 plan).
3. **`docs/archived/INCENTIVE_MODULE_TEST_IMPLEMENTATION_TASK.md`**
   - Task for implementing missing unit tests.
4. **`docs/archived/INCENTIVE_VERIFICATION_PLAN.md`**
   - Verification plan for incentive module correctness.
5. **`docs/archived/INCENTIVE_MODULE_REVIEW.md`** — archived review of the incentive module design/implementation.
6. **`docs/archived/INCENTIVE_MODULE_V2_ISSUES.md`** — archived V2 issues/fixes log (superseded by the merged module).

---

### Staking (DR v3)

1. **`docs/archived/DR_V3_TODO.md`** (archived) — historical DR v3 implementation status and phase tracking.

2. **`contracts/modules/decentralized-resolution-module/staking/ResolverStakingModule.sol`**
   - Implementation with NatSpec comments
   - Mix enforcement (80/20 rule)
   - Unbonding delays

---

### Slashing (DR v3)

1. **`docs/archived/DR_V3_TODO.md`** (archived) — historical DR v3 slashing status and penalty schedules.

2. **`contracts/modules/decentralized-resolution-module/slashing/ResolverSlashingModule.sol`**
   - Implementation with NatSpec comments
   - Penalty types and amounts
   - Waterfall logic

---

## Comparative Analysis & Benchmarks

1. **`docs/dispute-resolution/COMPARATIVE_ANALYSIS_DR_SYSTEMS.md`**
   - Architecture comparison: Sew vs UMA vs Kleros
   - Decision model, appeal mechanism, economic security, token design
   - Structural gaps vs design intent
   - Positioning summary and open design questions

2. **`docs/dispute-resolution/APPEAL_GAME_THEORY_BENCHMARKS.md`**
   - Formal theorems: rational escalation, griefing equilibrium, bribery resistance, EMA convergence, Schelling comparison
   - Public benchmark suite (BM-01 through BM-07) with runnable Python/Solidity specs
   - Parameter sensitivity table
   - **BM-03 currently FAILS** (bond distribution bug — fix in `finalizeDispute`)

---

## Economics Documentation

1. **`docs/dispute-resolution/RESOLVER_ECONOMICS.md`**
   - Overall economics design
   - Fee structures
   - Incentive mechanisms
   - Staking requirements

2. **`docs/dispute-resolution/RESOLVER_ECONOMICS_TODOS.md`**
   - TODO items for economics implementation
   - Missing features
   - Future enhancements

---

## Currency Management

1. **`docs/dispute-resolution/CURRENCY_MANAGEMENT.md`**
   - Comprehensive currency choice analysis
   - All currency types and restrictions
   - **UPDATED**: Now includes staking and slashing currencies

2. **`docs/dispute-resolution/ALL_INCENTIVES.md`**
   - **NEW**: Complete list of all incentive mechanisms
   - Distinctions between fee payments, staking, and slashing
   - Currency for each mechanism

3. **`docs/dispute-resolution/CURRENCY_SUMMARY.md`**
   - Quick reference for currency choices

---

## Implementation Plans

1. **`docs/dispute-resolution/APPEAL_BOND_TOKEN_WHITELIST_PLAN.md`**
   - Plan for multi-token appeal bond support
   - Governance-controlled whitelist

2. **`docs/archived/DECENTRALIZED_RESOLUTION_COMPLETION_PLAN.md`**
   - Overall DR implementation plan
   - Phase completion status

---

## Test Files

### Existing Tests

1. **`test/foundry/decentralized-resolution-module/IncentiveModuleIntegration.test.t.sol`**
   - ✅ Complete integration tests
   - Full escrow flow with incentives

2. **`test/foundry/decentralized-resolution-module/AppealBondRecording.unit.t.sol`**
   - ✅ Unit tests for bond recording

3. **`test/foundry/decentralized-resolution-module/AppealBondDistribution.unit.t.sol`**
   - ✅ Unit tests for bond distribution

4. **`test/foundry/decentralized-resolution-module/BondRounding.unit.t.sol`**
   - ✅ Rounding error tests

### Missing Tests

1. **`test/foundry/decentralized-resolution-module/IncentiveModuleHooks.unit.t.sol`**
   - ❌ Not created
   - Tests for `onDisputeOpened` hook

2. **`test/foundry/decentralized-resolution-module/DistributePaymentsInterface.unit.t.sol`**
   - ❌ Not created
   - Tests for `distributePayments` interface method

---

## Quick Reference

### Fee-Based Payments
- **Currency**: Same as escrow amount
- **Source**: Escrow fees, escalation fees, appeal bonds
- **Module**: `ResolverIncentiveModule`
- **Docs**: Archived: `INCENTIVE_MODULE_REVIEW.md`, `INCENTIVE_MODULE_V2_ISSUES.md`; current module: `incentive/ResolverIncentiveModule.sol`

### Staking
- **Currency**: USDC (80%) + SEW (20%)
- **Purpose**: Capital at risk, not payment
- **Module**: `ResolverStakingModule`
- **Docs**: Archived: `DR_V3_TODO.md`; current: `RESOLVER_ECONOMICS.md`

### Slashing
- **Currency**: Same as staked (USDC + SEW)
- **Purpose**: Penalty for poor performance
- **Module**: `ResolverSlashingModule`
- **Docs**: Archived: `DR_V3_TODO.md`; current: `RESOLVER_ECONOMICS.md`

---

## Status Summary

- ✅ **Fee-based payments**: Fully implemented and tested
- ✅ **Staking**: Implemented, needs more testing
- ⚠️ **Slashing**: Mostly implemented, some features stubbed
- ⚠️ **Tests**: Integration tests complete, some unit tests missing

---

**Last Updated**: 2026-04-25
