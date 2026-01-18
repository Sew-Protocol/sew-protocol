# DR v2 Activation Guide

**Release:** DR v2 (Decentralize Incentives)  
**Status:** ✅ Ready for activation  
**Prerequisites:** DR v1 stable on target network  
**Purpose:** Activate economic incentives through appeal bonds

---

## Overview

DR v2 adds economic incentives to dispute resolution by introducing:

- **Appeal bonds** (users post bonds to escalate disputes)
- **Escalation cost curves** (linear, quadratic, geometric)
- **Bond refund** on successful appeal (decision changes)
- **Bond payment** to resolvers on failed appeal (decision upheld)
- **Anti-griefing measures** (minimum escrow value for escalation)

**Key Change:** Swaps `ResolverIncentiveModuleV1` for `ResolverIncentiveModuleV2` via Slow lane governance.

---

## Pre-Activation Checklist

### Prerequisites

- [ ] DR v1 deployed and stable on target network
- [ ] DR v1 phase gate metrics met:
  - ✅ Escalation rate < 20%
  - ✅ Avg response time < 3 days
  - ✅ Active resolvers ≥ 3
- [ ] No critical issues with DR v1
- [ ] Community confidence in DR v1

### DR v2 Readiness

- [ ] `ResolverIncentiveModuleV2` deployed (or deployment script ready)
- [ ] Escalation cost curve parameters decided
- [ ] Minimum escrow value for escalation decided
- [ ] All DR v2 tests passing

### Governance Readiness

- [ ] Governance proposal prepared
- [ ] Community review completed
- [ ] Economic parameters reviewed
- [ ] Rollback plan prepared

---

## Activation Steps

### Step 1: Deploy DR v2 Contracts

```bash
# Deploy ResolverIncentiveModuleV2
pnpm hardhat deploy --network baseSepolia --tags dr-v2

# Verify deployments
pnpm hardhat export --network baseSepolia
```

**Expected Output:**
- `ResolverIncentiveModuleV2` (immutable)
- `PaymentCalculationLibraryV1` (if not already deployed)
- `EscalationCostLibrary` (enhanced version)

### Step 2: Configure DR v2 Module

```bash
# Configure escalation cost curve
# Via governance proposal

# Set minimum escrow value for escalation
# Via governance proposal
```

**Configuration Required:**
- Escalation cost curve type (linear, quadratic, geometric)
- Base cost for escalation
- Step size for cost curve
- Minimum escrow value for escalation

**Recommended:**
- Cost curve: **Quadratic** (`bond(k) = baseCost + stepSize × k²`)
- Base cost: 100 tokens (adjust based on network)
- Step size: 50 tokens (adjust based on network)
- Minimum escrow: 500 tokens (adjust based on network)

### Step 3: Update DecentralizedResolutionModule

```bash
# Update DR module to use ResolverIncentiveModuleV2
# Via governance proposal (if module supports swapping incentive modules)
```

**Note:** If `DecentralizedResolutionModule` doesn't support swapping incentive modules, you may need to deploy a new version that uses V2.

### Step 4: Queue Module Swap (Slow Lane)

```bash
# Build governance proposal
pnpm gov:build governance/payloads/queue_dr_v2.ts

# Stage proposal
pnpm gov:stage governance/proposals/queue_dr_v2.json --stage=propose --network baseSepolia
```

**Timeline:** ~48 hours (Standard lane delay)

**What Happens:**
- New incentive module is queued
- ETA set to `block.timestamp + 7 days`

### Step 5: Wait for Delay

**Delay Period:** 7 days (enforced onchain)

During this period:
- Monitor DR v1 operation
- Review economic parameters
- Prepare activation proposal
- Communicate with community

### Step 6: Activate Module Swap (Slow Lane)

```bash
# Build activation proposal
pnpm gov:build governance/payloads/activate_dr_v2.ts

# Stage proposal (after ETA has passed)
pnpm gov:stage governance/proposals/activate_dr_v2.json --stage=propose --network baseSepolia
```

**Timeline:** ~48 hours (Standard lane delay)

**What Happens:**
- New incentive module is activated
- New escrows will use DR v2 incentives
- Existing escrows continue using DR v1 (snapshot protection)

**Total Time:** ~9 days wall-clock (48h queue + 7d wait + 48h activate)

---

## Post-Activation Validation

### 1. Verify Module Swap

```typescript
const drModule = await ethers.getContractAt('DecentralizedResolutionModule', DR_MODULE_ADDRESS);
const incentiveModule = await drModule.incentiveModule();
expect(incentiveModule).to.equal(DR_V2_INCENTIVE_MODULE_ADDRESS);
```

### 2. Test Appeal Bond Flow

```typescript
// Create escrow and raise dispute
const escrowId = /* ... */;
await escrowVault.raiseDispute(escrowId, /* ... */);

// Resolver resolves dispute
await drModule.connect(resolver).resolveDispute(escrowId, /* ... */);

// User appeals (should require bond)
const appealBond = await drModule.canEscalate(escrowId, 0, /* ... */);
expect(appealBond.allowed).to.be.true;
expect(appealBond.escalationFee).to.be.gt(0);

// Post bond and escalate
await token.approve(drModule.address, appealBond.escalationFee);
await drModule.executeEscalation(escrowId, /* ... */);
```

### 3. Test Bond Refund (Successful Appeal)

```typescript
// If appeal succeeds (decision changes), bond should be refunded
const bondRefunded = await incentiveModule.getBondRefunded(escrowId);
expect(bondRefunded).to.be.true;
```

### 4. Test Bond Payment (Failed Appeal)

```typescript
// If appeal fails (decision upheld), bond should be paid to resolver
const bondPaid = await incentiveModule.getBondPaid(escrowId, resolver.address);
expect(bondPaid).to.be.gt(0);
```

### 5. Monitor Economic Metrics

```typescript
// Check appeal bond metrics
const metrics = await incentiveModule.getAppealMetrics();
console.log('Bonds posted:', metrics.bondsPosted);
console.log('Bonds refunded:', metrics.bondsRefunded);
console.log('Bonds forfeited:', metrics.bondsForfeited);
console.log('Appeal success rate:', metrics.appealSuccessRate);
```

**Target Metrics:**
- Appeal spam economically suppressed (cost > benefit)
- No viable "cheap griefing" strategy
- Stable appeal economics (20-40% reversal rate)
- Bond flows predictable

---

## Rollback Plan

If critical issues are discovered:

1. **Pause Protocol** (if Guardian role available):
   ```bash
   pnpm gov:emergency pause --contract EscrowVault --network baseSepolia
   ```

2. **Swap Back to ResolverIncentiveModuleV1** (if needed):
   - Queue swap back to V1 (Slow lane)
   - Wait 7 days
   - Activate swap

3. **Note:** Existing escrows are protected by snapshots - they continue using their original incentive module

---

## Phase Gate: DR v2 → DR v3

Before activating DR v3, ensure:

- ✅ Appeal spam economically suppressed (cost > benefit)
- ✅ No viable "cheap griefing" strategy
- ✅ Stable appeal economics (20-40% reversal rate)
- ✅ Bond flows predictable
- ✅ No critical issues with DR v2
- ✅ Security audit complete (for DR v3)

**See:** [DR v3 Activation Guide](../dr3/DR3_ACTIVATION.md)

---

## Known Limitations

### DR v2 Limitations

1. **No Resolver Capital at Risk**: Resolvers still cannot lose money (addressed in DR v3)
2. **User Bonds Only**: Only users post bonds, not resolvers

### This is addressed in:
- **DR v3**: Adds resolver staking and slashing

---

## Support

For issues during activation:

- Check [Emergency Runbook](../../governance/runbooks/emergency.md)
- Review [Slow Changes Runbook](../../governance/runbooks/slow-changes.md)
- Contact deployment team

---

_Last Updated: 2026-01-16_
