# Deployment Checklist: Post-Deploy Role Assignment

This document lists critical post-deployment steps that must be executed after deploying the protocol contracts.

## ⚠️ Critical: Always Execute After Deployment

### 1. Register Escrow Contracts with Ops Contracts

**Problem**: EscrowVault (and EscrowableERC20) must be registered with the remaining Ops contracts before it can be used. This requires calling `registerEscrowContract()` on each Ops contract that gates on `ROLE_ESCROW_CONTRACT`.

**Contracts Affected**:
- `YieldOps` - requires EscrowVault to have `ROLE_ESCROW_CONTRACT` (if used)
- `BondCollector` - requires EscrowVault to have `ROLE_ESCROW_CONTRACT` (if used)

**Not affected**: `EscrowCreationPolicy` is a shared, protocol-wide policy authority. It has no per-escrow registration and no `ROLE_ESCROW_CONTRACT` gate.

**How to Fix**:
```bash
# Option A: Via Timelock (production)
# Grant ROLE_TIMELOCK to the governance timelock, then batch registerEscrowContract calls.

# Option B: Direct grant (only if deployer has admin role)
# Edit deploy/60_protocol_governance.ts to include registerEscrowContract calls
```

---

### 2. Grant Guardian Role

**Problem**: Guardian multisig needs `ROLE_GUARDIAN` on certain contracts for emergency functions.

**Contracts Affected**:
- `EscrowVault` - ✅ Already granted in latest deployment
- `EscrowCreationPolicy` - Needs Timelock to grant (gates `pauseYieldDeposits`)
- `YieldOps` - Needs Timelock to grant

**How to Fix**:
```bash
# Check status
pnpm hardhat run --network baseSepolia scripts/testnet/guardian-status.ts

# Grant via timelock (production) or direct (if deployer has admin)
```

---

### 3. Verify Escrow Registration

**Check**:
```bash
pnpm hardhat run --network baseSepolia scripts/testnet/check-escrow-registration.ts
```

---

## Prevention: Deployment Script Fix

To prevent this in future deployments, `deploy/60_protocol_governance.ts` should:

1. Call `registerEscrowContract(EscrowVault)` on `YieldOps` and `BondCollector` after deploying EscrowVault
2. Grant Guardian roles in the same script
3. Include verification steps
