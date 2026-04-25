# Incentive System Documentation Index

This document provides an index of all documentation related to resolver incentives, payments, staking, and slashing.

---

## Core Documentation

### Fee-Based Payments (DR v1/v2)

1. **`docs/dispute-resolution/INCENTIVE_MODULE_REVIEW.md`**
   - Review of incentive module design and implementation
   - Covers V1 and V2 features
   - Payment calculation logic

2. **`docs/INCENTIVE_MODULE_V2_ISSUES.md`**
   - Issues and fixes for V2 incentive module
   - Appeal bond implementation details
   - Known limitations

3. **`docs/test/INCENTIVE_MODULE_TEST_PLAN.md`**
   - Comprehensive test plan for incentive modules
   - Unit test specifications
   - Integration test coverage
   - **Status**: Integration tests written, unit tests partially complete

4. **`docs/test/INCENTIVE_MODULE_TEST_IMPLEMENTATION_TASK.md`**
   - Task for implementing missing unit tests
   - **Status**: Ready for implementation
   - **Assigned**: Claude Haiku

5. **`docs/test/INCENTIVE_VERIFICATION_PLAN.md`**
   - Verification plan for incentive module correctness

---

### Staking (DR v3)

1. **`docs/dispute-resolution/DR_V3_TODO.md`**
   - DR v3 implementation status
   - Staking module status
   - Phase completion tracking

2. **`contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`**
   - Implementation with NatSpec comments
   - Mix enforcement (80/20 rule)
   - Unbonding delays

---

### Slashing (DR v3)

1. **`docs/dispute-resolution/DR_V3_TODO.md`**
   - Slashing module status
   - Penalty schedules
   - Implementation status

2. **`contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`**
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

2. **`docs/plans/DECENTRALIZED_RESOLUTION_COMPLETION_PLAN.md`**
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
- **Module**: `ResolverIncentiveModuleV1/V2`
- **Docs**: `INCENTIVE_MODULE_REVIEW.md`, `INCENTIVE_MODULE_V2_ISSUES.md`

### Staking
- **Currency**: USDC (80%) + SEW (20%)
- **Purpose**: Capital at risk, not payment
- **Module**: `ResolverStakingModuleV1`
- **Docs**: `DR_V3_TODO.md`, `RESOLVER_ECONOMICS.md`

### Slashing
- **Currency**: Same as staked (USDC + SEW)
- **Purpose**: Penalty for poor performance
- **Module**: `ResolverSlashingModuleV1`
- **Docs**: `DR_V3_TODO.md`, `RESOLVER_ECONOMICS.md`

---

## Status Summary

- ✅ **Fee-based payments**: Fully implemented and tested
- ✅ **Staking**: Implemented, needs more testing
- ⚠️ **Slashing**: Mostly implemented, some features stubbed
- ⚠️ **Tests**: Integration tests complete, some unit tests missing

---

**Last Updated**: 2026-04-25
