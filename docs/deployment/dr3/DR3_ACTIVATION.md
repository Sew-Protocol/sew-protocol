# DR v3 Activation Guide

**Release:** DR v3 (Decentralize Capital)  
**Status:** 🚧 Phase 1-3 Complete, Full Activation Pending  
**Prerequisites:** DR v2 stable on target network + Security audit  
**Purpose:** Activate resolver staking and slashing

---

## Overview

DR v3 adds resolver capital at risk by introducing:

- **Resolver staking** (resolvers post bonds to participate)
- **Mixed bonds** (80% stablecoin, 20% SEW with 0.5 haircut)
- **Oracle-free valuation** (conservative $1/SEW assumption)
- **Objective slashing** (timeouts only, 2%/5%/10% penalties)
- **Waterfall ordering** (resolver → senior)
- **Circuit breakers** (mass unavailability)

**Key Change:** Swaps `StakingModuleNoOp` and `SlashingModuleNoOp` for `ResolverStakingModuleV1` and `ResolverSlashingModuleV1` via Slow lane governance.

---

## Pre-Activation Checklist

### Prerequisites

- [ ] DR v2 deployed and stable on target network
- [ ] DR v2 phase gate metrics met:
  - ✅ Appeal spam economically suppressed
  - ✅ No viable "cheap griefing" strategy
  - ✅ Stable appeal economics (20-40% reversal rate)
  - ✅ Bond flows predictable
- [ ] Security audit complete for DR v3
- [ ] No critical issues with DR v2

### DR v3 Readiness

- [ ] `ResolverStakingModuleV1` deployed (or deployment script ready)
- [ ] `ResolverSlashingModuleV1` deployed (or deployment script ready)
- [ ] `BondValuationLibrary` deployed (or deployment script ready)
- [ ] `InsurancePoolVault` deployed (or deployment script ready)
- [ ] Staking parameters decided:
  - Minimum bond amount
  - Bond composition (80/20 rule)
  - Unbonding delays (14/21 days)
- [ ] Slashing parameters decided:
  - Slashing penalties (2%, 5%, 10%)
  - Timeout thresholds
  - Circuit breaker thresholds
- [ ] All DR v3 tests passing

### Governance Readiness

- [ ] Governance proposal prepared
- [ ] Community review completed
- [ ] Economic parameters reviewed
- [ ] Security audit reviewed
- [ ] Rollback plan prepared

---

## Activation Steps

### Step 1: Deploy DR v3 Contracts

```bash
# Deploy DR v3 modules
pnpm hardhat deploy --network baseSepolia --tags dr-v3

# Verify deployments
pnpm hardhat export --network baseSepolia
```

**Expected Output:**
- `ResolverStakingModuleV1` (immutable)
- `ResolverSlashingModuleV1` (immutable)
- `BondValuationLibrary` (immutable)
- `InsurancePoolVault` (immutable)

### Step 2: Configure DR v3 Modules

```bash
# Configure staking parameters
# Via governance proposal

# Configure slashing parameters
# Via governance proposal
```

**Configuration Required:**

**Staking:**
- Minimum bond amount (in effective USD)
- Bond composition requirements (80% stable, 20% SEW)
- Unbonding delays (14 days standard, 21 days senior)
- Delegation parameters (M=3, U=0.5)

**Slashing:**
- Timeout thresholds
- Slashing penalties (2%, 5%, 10%)
- Circuit breaker thresholds
- Freeze period (7 days)

### Step 3: Update DecentralizedResolutionModule

```bash
# Update DR module to use ResolverStakingModuleV1 and ResolverSlashingModuleV1
# Via governance proposal
```

**Note:** This may require deploying a new version of `DecentralizedResolutionModule` that integrates staking and slashing modules.

### Step 4: Queue Module Swap (Slow Lane)

```bash
# Build governance proposal
pnpm gov:build governance/payloads/queue_dr_v3.ts

# Stage proposal
pnpm gov:stage governance/proposals/queue_dr_v3.json --stage=propose --network baseSepolia
```

**Timeline:** ~48 hours (Standard lane delay)

**What Happens:**
- New staking and slashing modules are queued
- ETA set to `block.timestamp + 7 days`

### Step 5: Wait for Delay

**Delay Period:** 7 days (enforced onchain)

During this period:
- Monitor DR v2 operation
- Review staking/slashing parameters
- Prepare activation proposal
- Communicate with community
- Ensure resolvers are ready to stake

### Step 6: Activate Module Swap (Slow Lane)

```bash
# Build activation proposal
pnpm gov:build governance/payloads/activate_dr_v3.ts

# Stage proposal (after ETA has passed)
pnpm gov:stage governance/proposals/activate_dr_v3.json --stage=propose --network baseSepolia
```

**Timeline:** ~48 hours (Standard lane delay)

**What Happens:**
- New staking and slashing modules are activated
- New escrows will use DR v3 (with staking/slashing)
- Existing escrows continue using DR v2 (snapshot protection)

**Total Time:** ~9 days wall-clock (48h queue + 7d wait + 48h activate)

---

## Post-Activation Validation

### 1. Verify Module Swap

```typescript
const drModule = await ethers.getContractAt('DecentralizedResolutionModule', DR_MODULE_ADDRESS);
const stakingModule = await drModule.stakingModule();
const slashingModule = await drModule.slashingModule();
expect(stakingModule).to.equal(DR_V3_STAKING_MODULE_ADDRESS);
expect(slashingModule).to.equal(DR_V3_SLASHING_MODULE_ADDRESS);
```

### 2. Test Resolver Staking

```typescript
// Resolver stakes bonds
const resolver = await ethers.getSigner(RESOLVER_ADDRESS);
const minBond = await stakingModule.getMinimumBond();
await stableToken.approve(stakingModule.address, minBond * 0.8n);
await sewToken.approve(stakingModule.address, minBond * 0.2n);
await stakingModule.connect(resolver).stake(/* ... */);

// Verify staking
const stake = await stakingModule.getStake(resolver.address);
expect(stake.effectiveBondUSD).to.be.gte(minBond);
```

### 3. Test Dispute Resolution with Staking

```typescript
// Create escrow and raise dispute
const escrowId = /* ... */;
await escrowVault.raiseDispute(escrowId, /* ... */);

// Verify resolver is staked
const resolver = await drModule.getResolver(escrowId, /* ... */);
const stake = await stakingModule.getStake(resolver);
expect(stake.effectiveBondUSD).to.be.gt(0);
```

### 4. Test Slashing (Timeout)

```typescript
// Simulate timeout
await time.increase(TIMEOUT_PERIOD + 1);

// Trigger slashing
await slashingModule.slashResolver(resolver.address, /* timeout reason */);

// Verify slash
const stake = await stakingModule.getStake(resolver.address);
expect(stake.slashedAmount).to.be.gt(0);
```

### 5. Monitor Phase Gate Metrics

```typescript
// Check DR v3 phase gate metrics
const metrics = await drModule.getV3PhaseGateMetrics();
console.log('Staking participation:', metrics.stakingParticipation);
console.log('Slashing rate:', metrics.slashingRate);
console.log('Insurance pool balance:', metrics.insurancePoolBalance);
```

**Target Metrics:**
- Staking participation > 80% of resolvers
- Slashing rate < 5% per month
- Insurance pool solvent
- No critical issues

---

## Rollback Plan

If critical issues are discovered:

1. **Pause Protocol** (if Guardian role available):
   ```bash
   pnpm gov:emergency pause --contract EscrowVault --network baseSepolia
   ```

2. **Swap Back to NoOp Modules** (if needed):
   - Queue swap back to `StakingModuleNoOp` and `SlashingModuleNoOp` (Slow lane)
   - Wait 7 days
   - Activate swap

3. **Emergency Unstaking** (if needed):
   - Allow resolvers to unstake immediately (via governance)
   - Process unbonding requests

4. **Note:** Existing escrows are protected by snapshots - they continue using their original modules

---

## Known Limitations

### DR v3 Limitations

1. **Capital at Risk**: Resolvers now have capital at risk (by design)
2. **Slashing Risk**: Resolvers can be slashed for timeouts (by design)
3. **Unbonding Delays**: Resolvers must wait 14-21 days to unstake

### These are design features, not limitations:
- Capital at risk creates strong incentive alignment
- Slashing ensures accountability
- Unbonding delays prevent rapid exit during disputes

---

## Support

For issues during activation:

- Check [Emergency Runbook](../../governance/runbooks/emergency.md)
- Review [Slow Changes Runbook](../../governance/runbooks/slow-changes.md)
- Contact deployment team

---

_Last Updated: 2026-01-16_
