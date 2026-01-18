# IEO Release Guide

**Release:** IEO (Initial Exchange Offering)  
**Status:** ✅ Ready for deployment  
**Target Network:** Base Sepolia (testnet)  
**Purpose:** Initial release with minimal surface area - governance only, centralized dispute resolution

---

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
- [ ] Base Sepolia RPC URL set (`BASE_SEPOLIA_RPC_URL`)
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
# Set network
export NETWORK=baseSepolia

# Verify RPC connectivity
pnpm hardhat console --network baseSepolia
```

### Step 2: Deploy Core Contracts

```bash
# Deploy core escrow contracts
pnpm hardhat deploy --network baseSepolia --tags core

# Verify deployments
pnpm hardhat export --network baseSepolia
```

**Expected Output:**
- `BaseEscrow` (implementation)
- `EscrowVault` (implementation)
- `EscrowableERC20` (implementation)

### Step 3: Deploy Governance Infrastructure

```bash
# Deploy governance token
pnpm hardhat deploy --network baseSepolia --tags governance

# Deploy timelock
pnpm hardhat deploy --network baseSepolia --tags timelock

# Deploy governor
pnpm hardhat deploy --network baseSepolia --tags governor
```

**Expected Output:**
- `SewToken` (ERC20 governance token)
- `TimelockController` (OpenZeppelin)
- `GovGovernor` (OpenZeppelin Governor)

### Step 4: Deploy IEO Modules

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

### Step 5: Wire Contracts

```bash
# Wire governance and modules
pnpm hardhat deploy --network baseSepolia --tags wiring

# Post-deployment checks
pnpm hardhat deploy --network baseSepolia --tags post
```

**Actions:**
- Set default resolution module in BaseEscrow
- Set default release strategy
- Set default yield modules (if enabled)
- Transfer admin roles to Timelock
- Transfer governance token to Governor

### Step 6: Verify Contracts

```bash
# Verify all contracts on block explorer
pnpm hardhat verify --network baseSepolia --list

# Or verify individually
pnpm hardhat verify --network baseSepolia <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

---

## Post-Deployment Configuration

### 1. Set Initial Resolver

```bash
# Via governance proposal
pnpm gov:build governance/payloads/set_initial_resolver.ts
pnpm gov:stage governance/proposals/set_initial_resolver.json --stage=propose --network baseSepolia
```

### 2. Configure Protocol Fees (if needed)

```bash
# Set escrow fee address
pnpm gov:build governance/payloads/0002_queue_fee_address.ts
pnpm gov:stage governance/proposals/0002_queue_fee_address.json --stage=propose --network baseSepolia
```

### 3. Register Tokens for Yield (if yield enabled)

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
  
  core: {
    baseEscrow: '0x...',
    escrowVault: '0x...',
    escrowableERC20: '0x...',
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

### 2. Governance Test

```bash
# Create and execute a test proposal
pnpm gov:build governance/payloads/0001_set_token_cap.ts
pnpm gov:sim governance/proposals/0001_set_token_cap.json --fork-url=$BASE_SEPOLIA_RPC
```

### 3. Escrow Creation Test

```typescript
// Create a test escrow
const escrowVault = await ethers.getContractAt('EscrowVault', DEPLOYED_ADDRESS);
await escrowVault.createEscrow(/* ... */);
```

### 4. Dispute Resolution Test

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

_Last Updated: 2026-01-16_
