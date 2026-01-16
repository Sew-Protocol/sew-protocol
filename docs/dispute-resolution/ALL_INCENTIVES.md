# All Resolver Incentive Mechanisms

This document lists all incentive mechanisms for resolvers in the escrow system, their currencies, and how they work.

## Overview

The system has **three distinct incentive mechanisms** that operate independently:

1. **Fee-Based Payments** (DR v1/v2) - Payment for work done
2. **Staking Rewards** (DR v3) - Capital at risk, not payments
3. **Slashing Penalties** (DR v3) - Penalties for poor performance

---

## 1. Fee-Based Payments (ResolverIncentiveModuleV1/V2)

### Purpose
Payment to resolvers for their work in resolving disputes.

### Currency
- **Same token as escrow amount** (enforced)
- If escrow is in USDC, payments are in USDC
- If escrow is in ETH, payments are in ETH
- If escrow is in DAI, payments are in DAI

### Sources
1. **Escrow Fees**: Percentage of escrow amount (governance-controlled)
2. **Escalation Fees**: Legacy fees for escalation (deprecated, replaced by bonds)
3. **Appeal Bond Distributions**: When appeal fails, bond is paid to prior round's resolvers

### Distribution
- Weighted by escalation level (level 0 = 1x, level 1 = 1.5x, level 2 = 2x)
- Configurable resolver share percentage (governance-controlled)
- Payments calculated via `PaymentCalculationLibraryV1`
- Claimable via `claimPayment(workflowId, token)`

### Code References
- `ResolverIncentiveModuleV1.sol` - V1 implementation
- `ResolverIncentiveModuleV2.sol` - V2 adds appeal bonds
- `PaymentCalculationLibraryV1.sol` - Payment calculation logic
- `BaseEscrow.sol:749` - Records escrow fees with token

### Key Functions
- `recordEscrowFee(workflowId, token, amount)` - Record escrow fee
- `recordEscalationFee(workflowId, token, amount)` - Record escalation fee (legacy)
- `recordAppealBond(...)` - Record appeal bond (V2 only)
- `distributeAppealBond(...)` - Distribute bond to resolvers or refund
- `getClaimablePayment(workflowId, resolver)` - Get claimable amount
- `claimPayment(workflowId, token)` - Claim payment

---

## 2. Staking Rewards (ResolverStakingModuleV1)

### Purpose
Capital at risk mechanism - resolvers stake tokens to participate. This is **NOT a payment mechanism**, but rather a requirement for participation.

### Currency
- **Stablecoin (USDC)**: Primary staking token (80% minimum)
- **SEW Token**: Protocol token (20% maximum, 50% haircut)
- **Mix Required**: 80% stable / 20% SEW minimum

### How It Works
- Resolvers must stake tokens to be eligible for work
- Staked tokens are locked (unbonding delays: 14 days for resolvers, 21 days for seniors)
- Staking provides coverage for disputes (M=3x multiplier, U=50% utilization)
- Senior resolvers provide coverage for junior resolvers

### Not Payments
- Staking is **capital at risk**, not payment for work
- Stakers don't receive rewards for staking (unlike typical staking)
- Staking is a requirement, not an incentive
- Slashing can reduce staked amounts

### Code References
- `ResolverStakingModuleV1.sol` - Staking implementation
- `IStakingModule.sol` - Staking interface
- `BondValuationLibrary.sol` - Bond valuation logic

### Key Functions
- `stake(uint256 stableAmount, uint256 sewAmount)` - Stake tokens
- `unstake(uint256 stableAmount, uint256 sewAmount)` - Request unstaking
- `withdraw()` - Withdraw after unbonding delay
- `getEffectiveBond(address resolver)` - Get effective bond value
- `getAvailableCoverage(address senior)` - Get available coverage

---

## 3. Slashing Penalties (ResolverSlashingModuleV1)

### Purpose
Penalties for poor performance or misconduct.

### Currency
- **Same as staked tokens**: Slashes from staked stablecoin and SEW tokens
- Slashed tokens go to insurance pool and protocol treasury

### Penalty Types (v3 objective slashing schedule)
1. **Missed Accept**: 0.25% penalty (PENALTY_MISSED_ACCEPT = 25 bps)
2. **Missed Resolve**: 2% penalty (PENALTY_MISSED_RESOLVE = 200 bps) + 72h freeze
3. **Repeated Missed Resolve** (same epoch): 5% penalty (PENALTY_REPEAT_RESOLVE = 500 bps) + 7d freeze
4. **Reversal on escalation**: 0 bps initially (disabled - use reputation/workload only)

### Distribution
- Resolver bond exhausted first
- Then senior coverage (waterfall)
- Portions go to:
  - Insurance pool
  - Counter-party (not implemented, set to 0)
  - Slash proposer (not implemented, set to 0)
  - Protocol treasury (not implemented, stays in contract)

### Code References
- `ResolverSlashingModuleV1.sol` - Slashing implementation
- `ISlashingModule.sol` - Slashing interface
- `InsurancePoolVault.sol` - Insurance pool for slashed funds

### Key Functions
- `slashForTimeout(...)` - Slash for timeout
- `slashForReversal(...)` - Slash for reversal (not implemented, reverts)
- `slashForFraud(...)` - Slash for fraud (requires TIMELOCK, supports evidence)
- `getSlashAmount(...)` - Calculate slash amount
- `appealSlash(slashId)` - Appeal a slash

---

## Currency Summary Table

| Incentive Type | Currency | Source | Purpose | Payment? |
|---------------|----------|--------|---------|----------|
| **Fee-Based Payments** | Same as escrow | Escrow fees, escalation fees, appeal bonds | Payment for work | ✅ Yes |
| **Staking** | USDC (80%) + SEW (20%) | Resolver deposits | Capital at risk requirement | ❌ No (requirement) |
| **Slashing** | Same as staked | Staked tokens | Penalty for poor performance | ❌ No (penalty) |

---

## Important Distinctions

### Fee-Based Payments vs Staking

- **Fee-based payments** are **rewards** for work done, paid in the same token as the escrow
- **Staking** is **capital at risk**, not a payment mechanism
- These are **completely independent** systems
- Fee payments can be in any token (matches escrow)
- Staking is always in USDC + SEW (fixed mix)

### Staking vs Slashing

- **Staking** is what resolvers deposit to participate
- **Slashing** is what gets taken away for poor performance
- Slashing reduces staked amounts
- Slashed tokens go to insurance pool, not back to resolvers

---

## Documentation References

### Fee-Based Payments
- `docs/dispute-resolution/INCENTIVE_MODULE_REVIEW.md`
- `docs/dispute-resolution/RESOLVER_ECONOMICS.md`
- `docs/test/INCENTIVE_MODULE_TEST_PLAN.md`
- `docs/INCENTIVE_MODULE_V2_ISSUES.md`

### Staking
- `docs/dispute-resolution/DR_V3_TODO.md`
- `docs/dispute-resolution/RESOLVER_ECONOMICS.md`
- `contracts/decentralized-resolution-module/ResolverStakingModuleV1.sol`

### Slashing
- `docs/dispute-resolution/DR_V3_TODO.md`
- `docs/dispute-resolution/RESOLVER_ECONOMICS.md`
- `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`

---

## Implementation Status

### Fee-Based Payments
- ✅ **V1**: Complete (escrow fees, escalation fees)
- ✅ **V2**: Complete (adds appeal bonds)
- ✅ **Integration**: Complete in BaseEscrow

### Staking
- ✅ **V1**: Complete (ResolverStakingModuleV1)
- ✅ **Integration**: Complete in DecentralizedResolutionModule
- ⚠️ **Delegation**: Implemented but not fully tested

### Slashing
- ✅ **V1**: Mostly complete (ResolverSlashingModuleV1)
- ⚠️ **Fraud Slashing**: Implemented but requires TIMELOCK
- ❌ **Counter-party Compensation**: Not implemented (set to 0)
- ❌ **Treasury Integration**: Not implemented (funds stay in contract)
