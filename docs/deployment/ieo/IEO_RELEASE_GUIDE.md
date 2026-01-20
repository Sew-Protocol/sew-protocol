# IEO Release Guide

**Release:** IEO (Initial Exchange Offering)  
**Status:** ✅ Ready for deployment  
**Target Network:** Base Sepolia (testnet)  
**Purpose:** Initial release with minimal surface area - governance only, centralized dispute resolution

---

## Current status (recommended path)

For the current Base Sepolia integration-test rollout (separate `SEPOLIA_DEPLOY_KEY`, `SOLC_RUNS=200`, fee override knobs, deployed address table, etc.), use:

- `docs/deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md`

This document remains as a higher-level IEO release checklist and “fresh deployment” reference.

## Overview

The IEO release is the initial deployment of the Sew Protocol escrow system. It includes:

- **Core escrow contracts** (immutable)
- **Default resolution module** (single trusted resolver)
- **Optional yield generation** (Aave integration)
- **Governance infrastructure** (OpenZeppelin Governor + Timelock)

This release provides a **minimal, secure foundation** for the protocol with centralized dispute resolution. Future releases (DR v1, v2, v3) will progressively decentralize dispute resolution.

---

## Pre-Deployment Checklist

### Prerequisites

- [ ] Environment variables configured (`.env` file)
- [ ] Base Sepolia RPC URL set (`RPC_BASE_SEPOLIA`)
- [ ] Deployer account funded with ETH for gas
- [ ] Aave Pool Addresses Provider address (Base Sepolia)
- [ ] Safe multisig address (for initial admin)
- [ ] Governance token parameters decided (name, symbol, cap)

### Security Checklist

- [ ] All contracts audited or reviewed
- [ ] Emergency procedures documented
- [ ] Governance runbooks tested
- [ ] Deployment scripts reviewed
- [ ] No critical security issues open

### Testing Checklist

- [ ] All tests passing (`pnpm test`)
- [ ] Testnet fork tests passing
- [ ] Deployment scripts tested on local network
- [ ] Governance flows tested
- [ ] Emergency procedures tested

---

## Deployment Steps

### Step 1: Environment Setup

```bash
# Verify RPC connectivity
pnpm hardhat console --network baseSepolia
```

### Step 2: Deploy Ops Contracts

```bash
# Deploy ops contracts (required before core escrow contracts)
pnpm hardhat deploy --network baseSepolia --tags yield-ops,dispute-ops,settlement-ops,create-ops,bond-collector

# Verify deployments
pnpm hardhat export --network baseSepolia
```

**Expected Output:**
- `YieldOps` (Yield withdrawal and distribution)
- `DisputeOps` (Dispute escalation orchestration)
- `SettlementOps` (Settlement execution operations)
- `CreateOps` (Escrow creation validation and computation)
- `BondCollector` (Escalation bond collection)

**Note**: These contracts are deployed with the deployer as `initialOwner`. Admin roles will be transferred to TimelockController in Step 5.

### Step 3: Deploy Module Management

```bash
# Deploy module management contract
pnpm hardhat deploy --network baseSepolia --tags module-management
```

**Expected Output:**
- `ModuleManagementContract` (Centralized module management)

### Step 4: Deploy Core Escrow Contracts

```bash
# Keep bytecode under 24KB (EIP-170) for Base Sepolia deployments
export SOLC_RUNS=200

# Deploy core escrow contracts
pnpm hardhat deploy --network baseSepolia --tags escrow

# Verify deployments
pnpm hardhat export --network baseSepolia
```

**Expected Output:**
- `EscrowVault` (Main escrow contract for ERC20 tokens)
- `EscrowableERC20` (Optional - ERC20 token with built-in escrow, set `DEPLOY_ESCROWABLE_ERC20=true`)

**Actions performed automatically**:
- Registers EscrowVault with all 5 ops contracts (CreateOps, SettlementOps, DisputeOps, YieldOps, BondCollector)
- Sets ops contracts in EscrowVault using `setCreateOps()`, `setSettlementOps()`, `setBondCollector()` (these setters are Timelock-gated; scripts are written to be safe on reruns)
- Registers EscrowableERC20 with all ops contracts (if deployed)
- Sets ops contracts in EscrowableERC20 (if deployed)

### Step 5: Deploy Governance Infrastructure

```bash
# Deploy all governance contracts
pnpm hardhat deploy --network baseSepolia --tags governance
```

**Expected Output:**
- `SewToken` (ERC20 governance token)
- `TimelockController` (OpenZeppelin)
- `GovGovernor` (OpenZeppelin Governor)

**Actions performed automatically**:
- Grants roles to TimelockController and Guardian multisig
- Transfers DEFAULT_ADMIN_ROLE from deployer to TimelockController for all contracts:
  - EscrowVault
  - EscrowableERC20
  - All ops contracts (CreateOps, SettlementOps, DisputeOps, YieldOps, BondCollector)
  - ModuleManagementContract
  - AaveYieldGenerationModule (if deployed)
  - DefaultResolutionModule (if deployed)

### Step 6: Deploy IEO Modules

```bash
# Deploy default resolution module
pnpm hardhat deploy --network baseSepolia --tags default-resolution

# Deploy release strategy
pnpm hardhat deploy --network baseSepolia --tags release-strategy

# Deploy yield modules (optional)
pnpm hardhat deploy --network baseSepolia --tags yield-modules
```

**Expected Output:**
- `DefaultResolutionModule`
- `DefaultReleaseStrategy`
- `AaveYieldGenerationModule` (if yield enabled)
- `DefaultYieldDistributionModule`

### Step 7: Wire Contracts (Optional)

```bash
# Wire governance and modules (if needed)
pnpm hardhat deploy --network baseSepolia --tags wiring

# Post-deployment checks
pnpm hardhat deploy --network baseSepolia --tags post
```

**Actions:**
- Set default resolution module in EscrowVault (via EscrowAdminContract)
- Set default release strategy (via ModuleManagementContract)
- Set default yield modules (if enabled)
- Transfer governance token to Governor (if needed)

**Note**: Most wiring is now handled automatically:
- ✅ Ops contracts are registered with escrow contracts (Step 4)
- ✅ Ops contracts are set in escrow contracts (Step 4)
- ✅ Admin roles are transferred to TimelockController (Step 5)

### Step 8: Verify Contracts

```bash
# Verify all contracts on block explorer
pnpm hardhat verify --network baseSepolia --list

# Or verify individually
pnpm hardhat verify --network baseSepolia <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

---

## Post-Deployment Configuration

### 1. Verify Ops Contract Registration

```bash
# Verify EscrowVault is registered with all ops contracts
# This should have been done automatically in Step 4
# Check via:
pnpm hardhat run scripts/verify-ops-registration.ts --network baseSepolia
```

**Verification Checklist**:
- [ ] EscrowVault registered with CreateOps
- [ ] EscrowVault registered with SettlementOps
- [ ] EscrowVault registered with DisputeOps
- [ ] EscrowVault registered with YieldOps
- [ ] EscrowVault registered with BondCollector
- [ ] CreateOps set in EscrowVault
- [ ] SettlementOps set in EscrowVault
- [ ] BondCollector set in EscrowVault

### 2. Verify Role Transfers

```bash
# Verify TimelockController has DEFAULT_ADMIN_ROLE on all contracts
pnpm hardhat run scripts/verify-roles.ts --network baseSepolia
```

**Verification Checklist**:
- [ ] TimelockController has DEFAULT_ADMIN_ROLE on EscrowVault
- [ ] TimelockController has DEFAULT_ADMIN_ROLE on all ops contracts
- [ ] TimelockController has DEFAULT_ADMIN_ROLE on ModuleManagementContract
- [ ] Deployer does NOT have DEFAULT_ADMIN_ROLE (revoked)

### 3. Set Initial Resolver

```bash
# Via governance proposal
pnpm gov:build governance/payloads/set_initial_resolver.ts
pnpm gov:stage governance/proposals/set_initial_resolver.json --stage=propose --network baseSepolia
```

### 4. Configure Protocol Fees (if needed)

```bash
# Set escrow fee address
pnpm gov:build governance/payloads/0002_queue_fee_address.ts
pnpm gov:stage governance/proposals/0002_queue_fee_address.json --stage=propose --network baseSepolia
```

### 5. Register Tokens for Yield (if yield enabled)

```bash
# Register USDC for Aave yield
# Via governance proposal or direct call (if authorized)
```

---

## Deployment Artifacts

After deployment, record the following:

### Contract Addresses

```typescript
// Base Sepolia IEO Deployment
const IEO_DEPLOYMENT = {
  network: 'baseSepolia',
  chainId: 84532,
  deployedAt: '2026-01-XX',
  deployer: '0x...',
  
  ops: {
    yieldOps: '0x...',
    disputeOps: '0x...',
    settlementOps: '0x...',
    createOps: '0x...',
    bondCollector: '0x...',
  },
  moduleManagement: {
    moduleManagementContract: '0x...',
  },
  core: {
    escrowVault: '0x...',
    escrowableERC20: '0x...', // Optional
  },
  
  governance: {
    sewToken: '0x...',
    timelock: '0x...',
    governor: '0x...',
  },
  
  modules: {
    defaultResolution: '0x...',
    defaultRelease: '0x...',
    aaveYield: '0x...',
    defaultYieldDistribution: '0x...',
  },
};
```

### Transaction Hashes

Record all deployment transaction hashes for audit trail.

### Verification Status

- [ ] All contracts verified on Basescan
- [ ] Contract source code matches deployment
- [ ] Constructor arguments verified

---

## Validation Steps

### 1. Contract Verification

```bash
# Check all contracts are verified
pnpm hardhat verify --network baseSepolia --list
```

### 2. Ops Contract Registration Test

```typescript
// Verify EscrowVault can call CreateOps
const createOps = await ethers.getContractAt('CreateOps', CREATE_OPS_ADDRESS);
const escrowVault = await ethers.getContractAt('EscrowVault', ESCROW_VAULT_ADDRESS);

// This should succeed (EscrowVault has ROLE_ESCROW_CONTRACT)
const result = await createOps.computeEscrowCreation(/* ... */);
```

### 3. Governance Test

```bash
# Create and execute a test proposal
pnpm gov:build governance/payloads/0001_set_token_cap.ts
pnpm gov:sim governance/proposals/0001_set_token_cap.json --fork-url=$BASE_SEPOLIA_RPC
```

### 4. Escrow Creation Test

```typescript
// Create a test escrow
const escrowVault = await ethers.getContractAt('EscrowVault', DEPLOYED_ADDRESS);
await escrowVault.createEscrow(/* ... */);
```

### 4b. Smoke test script (recommended)

Run the Base Sepolia smoke tests (create escrow → release; create escrow → both parties cancel → refund):

```bash
chmod +x scripts/testnet/smoke-escrow.sh
./scripts/testnet/smoke-escrow.sh
```

Optional env vars:
- `SELLER_PRIVATE_KEY=0x...` (recommended, second funded EOA to test true 2-party cancel)
- `BUYER_PRIVATE_KEY=0x...`
- `ESCROW_TOKEN=0x...` (defaults to deployed `SewToken`)
- `ESCROW_AMOUNT=1`

### 5. Dispute Resolution Test

```typescript
// Raise a test dispute
await escrowVault.raiseDispute(escrowId, /* ... */);

// Resolve via default resolver
const resolver = await ethers.getSigner(RESOLVER_ADDRESS);
await escrowVault.connect(resolver).resolveDispute(escrowId, /* ... */);
```

---

## Known Limitations

### IEO Release Limitations

1. **Centralized Resolution**: Single trusted resolver (no decentralization)
2. **No Incentives**: Resolvers have no economic incentives
3. **No Staking**: Resolvers have no capital at risk
4. **Limited Scalability**: Single resolver may become bottleneck

### These are addressed in:
- **DR v1**: Decentralizes decision-making
- **DR v2**: Adds economic incentives
- **DR v3**: Adds resolver capital at risk

---

## Rollback Plan

If critical issues are discovered:

1. **Pause Protocol** (if Guardian role available):
   ```bash
   pnpm gov:emergency pause --contract EscrowVault --network baseSepolia
   ```

2. **Disable Yield** (if yield enabled):
   ```bash
   pnpm gov:emergency disable-yield --network baseSepolia
   ```

3. **Document Issues**: Record all issues and resolutions

4. **Fix and Redeploy**: Address issues and redeploy if needed

---

## Next Steps

After successful IEO deployment:

1. **Monitor** protocol operation for stability period
2. **Validate** all functionality works as expected
3. **Document** any issues or improvements needed
4. **Prepare** DR v1 activation (when ready)

**See:** [DR v1 Activation Guide](../dr1/DR1_ACTIVATION.md)

---

## Support

For issues during deployment:

- Check [Emergency Runbook](../../governance/runbooks/emergency.md)
- Review [Deployment Troubleshooting](./DEPLOYMENT_TROUBLESHOOTING.md)
- Contact deployment team

---

_Last Updated: 2026-01-27_  
**Changes**: Added ops contracts deployment, registration steps, and role transfer verification
