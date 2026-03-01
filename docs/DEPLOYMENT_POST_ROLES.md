# Deployment Checklist: Post-Deploy Role Assignment

This document lists critical post-deployment steps that must be executed after deploying the protocol contracts.

## ⚠️ Critical: Always Execute After Deployment

### 1. Register Escrow Contracts with Ops Contracts

**Problem**: EscrowVault must registered with Create beOps (and other Ops contracts) before it can be used. This requires calling `registerEscrowContract()` on each Ops contract.

**Contracts Affected**:
- `CreateOps` - requires EscrowVault to have `ROLE_ESCROW_CONTRACT`
- `YieldOps` - requires EscrowVault to have `ROLE_ESCROW_CONTRACT` (if used)
- `SettlementOps` - requires EscrowVault to have `ROLE_ESCROW_CONTRACT` (if used)
- `DisputeOps` - requires EscrowVault to have `ROLE_ESCROW_CONTRACT` (if used)

**How to Fix**:
```bash
# Option A: Via Timelock (production)
pnpm hardhat run --network baseSepolia scripts/testnet/timelock-register-escrow.ts

# Option B: Direct grant (only if deployer has admin role)
# Edit deploy/60_protocol_governance.ts to include registerEscrowContract calls
```

**Script Location**: `scripts/testnet/timelock-register-escrow.ts`

---

### 2. Grant Guardian Role

**Problem**: Guardian multisig needs `ROLE_GUARDIAN` on certain contracts for emergency functions.

**Contracts Affected**:
- `EscrowVault` - ✅ Already granted in latest deployment
- `CreateOps` - Needs Timelock to grant
- `YieldOps` - Needs Timelock to grant

**How to Fix**:
```bash
# Check status
pnpm hardhat run --network baseSepolia scripts/testnet/guardian-status.ts

# Grant via timelock (production) or direct (if deployer has admin)
```

---

### 3. Verify CreateOps Registration

**Check**:
```bash
pnpm hardhat run --network baseSepolia scripts/testnet/check-escrow-registration.ts
```

---

## Current Testnet Status

| Item | Status | Notes |
|------|--------|-------|
| EscrowVault → CreateOps | ❌ Not registered | Timelock scheduled, waiting for 48h |
| Guardian → EscrowVault | ✅ Granted | |
| Guardian → CreateOps | ❌ Missing | Needs Timelock |
| Guardian → YieldOps | ❌ Missing | Needs Timelock |

---

## Timelock Execution

The registration was scheduled with a 48-hour delay. 

**Ready to execute**: ~March 3, 2026 15:32 UTC

```bash
# When ready, execute with:
pnpm hardhat run --network baseSepolia scripts/testnet/check-timelock-ready.ts
```

---

## Prevention: Deployment Script Fix

To prevent this in future deployments, update `deploy/60_protocol_governance.ts` to:

1. Call `CreateOps.registerEscrowContract(EscrowVault)` after deploying EscrowVault
2. Grant Guardian roles in the same script
3. Include verification steps

Example addition to `60_protocol_governance.ts`:
```typescript
// After granting roles, also register escrow contracts
const createOps = await ethers.getContractAt('CreateOps', (await get('CreateOps')).address);
const escrowVaultAddr = (await get('EscrowVault')).address;

// Register escrow contract
try {
  const tx = await createOps.registerEscrowContract(escrowVaultAddr);
  await tx.wait();
  console.log('✅ EscrowVault registered with CreateOps');
} catch (e) {
  console.log('⚠️  Could not register (may need timelock):', e);
}
```
