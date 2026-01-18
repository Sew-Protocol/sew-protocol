# DR v1 Activation Guide

**Release:** DR v1 (Decentralize Decisions)  
**Status:** ✅ Ready for activation  
**Prerequisites:** IEO deployed and stable on target network  
**Purpose:** Activate decentralized dispute resolution with multiple resolvers

---

## Overview

DR v1 decentralizes dispute resolution decision-making by introducing:

- Multiple independent resolvers (curated set)
- Round-robin selection from resolver pool
- Three-level escalation: Standard → Senior → External (Kleros)
- Category-based dispute routing
- Performance-based workload routing (EMA scoring)

**Key Change:** Swaps `DefaultResolutionModule` for `DecentralizedResolutionModule` via Slow lane governance.

---

## Pre-Activation Checklist

### Prerequisites

- [ ] IEO deployed and stable on target network
- [ ] IEO operation validated (no critical issues)
- [ ] Governance processes tested and working
- [ ] Emergency procedures validated
- [ ] Resolver candidates identified and vetted

### DR v1 Readiness

- [ ] `DecentralizedResolutionModule` deployed (or deployment script ready)
- [ ] `ResolverIncentiveModuleV1` deployed (or deployment script ready)
- [ ] Resolver registry prepared (list of approved resolvers)
- [ ] Kleros integration configured (if using external escalation)
- [ ] All DR v1 tests passing

### Governance Readiness

- [ ] Governance proposal prepared
- [ ] Community review completed
- [ ] Timelock delay understood (~9 days total)
- [ ] Rollback plan prepared

---

## Activation Steps

### Step 1: Deploy DR v1 Contracts

```bash
# Deploy DecentralizedResolutionModule
pnpm hardhat deploy --network baseSepolia --tags dr-v1

# Verify deployments
pnpm hardhat export --network baseSepolia
```

**Expected Output:**
- `DecentralizedResolutionModule` (immutable)
- `ResolverIncentiveModuleV1` (immutable)

### Step 2: Configure DR v1 Module

```bash
# Register approved resolvers
# Via governance proposal or direct call (if authorized)

# Configure escalation parameters
# Via governance proposal
```

**Configuration Required:**
- Approved resolver addresses
- Approved senior resolver addresses
- Escalation configuration (rounds, timeouts)
- Category mappings (if using category-based routing)

### Step 3: Queue Module Swap (Slow Lane)

```bash
# Build governance proposal
pnpm gov:build governance/payloads/queue_dr_v1.ts

# Stage proposal
pnpm gov:stage governance/proposals/queue_dr_v1.json --stage=propose --network baseSepolia
```

**Timeline:** ~48 hours (Standard lane delay)

**What Happens:**
- `BaseEscrow.queueResolutionModule(newDRModuleAddress)` is queued
- ETA set to `block.timestamp + 7 days`

### Step 4: Wait for Delay

**Delay Period:** 7 days (enforced onchain)

During this period:
- Monitor protocol operation
- Review activation plan
- Prepare activation proposal
- Communicate with community

### Step 5: Activate Module Swap (Slow Lane)

```bash
# Build activation proposal
pnpm gov:build governance/payloads/activate_dr_v1.ts

# Stage proposal (after ETA has passed)
pnpm gov:stage governance/proposals/activate_dr_v1.json --stage=propose --network baseSepolia
```

**Timeline:** ~48 hours (Standard lane delay)

**What Happens:**
- `BaseEscrow.activateResolutionModule()` is executed
- `resolutionModule` now points to `DecentralizedResolutionModule`
- New escrows will use DR v1
- Existing escrows continue using `DefaultResolutionModule` (snapshot protection)

**Total Time:** ~9 days wall-clock (48h queue + 7d wait + 48h activate)

---

## Post-Activation Validation

### 1. Verify Module Swap

```typescript
const baseEscrow = await ethers.getContractAt('BaseEscrow', BASE_ESCROW_ADDRESS);
const currentModule = await baseEscrow.resolutionModule();
expect(currentModule).to.equal(DR_V1_MODULE_ADDRESS);
```

### 2. Test New Escrow Creation

```typescript
// Create new escrow (should use DR v1)
const escrowVault = await ethers.getContractAt('EscrowVault', ESCROW_VAULT_ADDRESS);
const tx = await escrowVault.createEscrow(/* ... */);
const receipt = await tx.wait();

// Verify escrow uses DR v1 module
const escrowId = /* extract from receipt */;
const escrow = await escrowVault.escrowTransfers(escrowId);
expect(escrow.snapshotResolutionModule).to.equal(DR_V1_MODULE_ADDRESS);
```

### 3. Test Dispute Resolution

```typescript
// Raise dispute
await escrowVault.raiseDispute(escrowId, /* ... */);

// Verify resolver assignment (should use round-robin)
const resolver = await drModule.getResolver(escrowId, /* ... */);
expect(resolver).to.be.oneOf(APPROVED_RESOLVERS);
```

### 4. Monitor Phase Gate Metrics

```typescript
// Check DR v1 phase gate metrics
const metrics = await drModule.getV1PhaseGateMetrics();
console.log('Escalation rate:', metrics.escalationRate);
console.log('Avg response time:', metrics.avgResponseTime);
console.log('Active resolvers:', metrics.activeResolverCount);
```

**Target Metrics:**
- Escalation rate < 20%
- Avg response time < 3 days
- Active resolvers ≥ 3

---

## Rollback Plan

If critical issues are discovered:

1. **Pause Protocol** (if Guardian role available):
   ```bash
   pnpm gov:emergency pause --contract EscrowVault --network baseSepolia
   ```

2. **Swap Back to DefaultResolutionModule** (if needed):
   - Queue swap back to `DefaultResolutionModule` (Slow lane)
   - Wait 7 days
   - Activate swap

3. **Note:** Existing escrows are protected by snapshots - they continue using their original module

---

## Phase Gate: DR v1 → DR v2

Before activating DR v2, ensure:

- ✅ Stable escalation rate (<20%) over N weeks
- ✅ Predictable response times (<3 days avg)
- ✅ Multiple operational resolvers (≥3 active)
- ✅ No critical issues with DR v1
- ✅ Community confidence in DR v1

**See:** [DR v2 Activation Guide](../dr2/DR2_ACTIVATION.md)

---

## Known Limitations

### DR v1 Limitations

1. **No Economic Incentives**: Resolvers have no financial incentives (addressed in DR v2)
2. **No Capital at Risk**: Resolvers cannot lose money (addressed in DR v3)
3. **Soft Incentives Only**: Workload-to-zero for low performers

### These are addressed in:
- **DR v2**: Adds appeal bonds and economic incentives
- **DR v3**: Adds resolver staking and slashing

---

## Support

For issues during activation:

- Check [Emergency Runbook](../../governance/runbooks/emergency.md)
- Review [Slow Changes Runbook](../../governance/runbooks/slow-changes.md)
- Contact deployment team

---

_Last Updated: 2026-01-16_
