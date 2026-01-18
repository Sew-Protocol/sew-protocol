# Base Sepolia Deployment Guide

**Network:** Base Sepolia (Testnet)  
**Chain ID:** 84532  
**Status:** Ready for deployment  
**Date:** 2026-01-16

---

## Pre-Deployment Checklist

### Required Environment Variables

Set the following environment variables in your `.env` file:

```bash
# Network Configuration (already set)
RPC_BASE_SEPOLIA=https://sepolia.base.org
PRIVATE_KEY=your_deployer_private_key

# Optional: Block Explorer API Key (for verification)
BASESCAN_API_KEY=your_basescan_api_key

# Safe Multisig Configuration
SAFE_OWNER_1=0x...  # First Safe owner address
SAFE_OWNER_2=0x...  # Second Safe owner address
SAFE_OWNER_3=0x...  # Third Safe owner address (minimum 3 required)
SAFE_OWNER_4=0x...  # Optional: Fourth owner
SAFE_OWNER_5=0x...  # Optional: Fifth owner
SAFE_THRESHOLD=3    # Number of signatures required (default: 3)

# Guardian Configuration
GUARDIAN_MULTISIG=0x...  # Guardian multisig address (can be same as Safe)

# Fee Recipient
FEE_RECIPIENT=0x...  # Address to receive protocol fees (can be same as Guardian)

# Optional: Governance Configuration
GOVERNANCE_TOKEN_NAME=Sew Token
GOVERNANCE_TOKEN_SYMBOL=SEW
GOVERNANCE_TOKEN_SUPPLY=1000000000000000000000000000  # 1B tokens in wei
PROPOSAL_THRESHOLD=10000000000000000000000000  # 10M tokens in wei
ABSOLUTE_QUORUM=4000000000000000000000000  # 4M tokens in wei (absolute quorum)
TIMELOCK_DELAY=172800  # 48 hours in seconds
VOTING_DELAY=1  # 1 block
VOTING_PERIOD=45818  # ~1 week @ 13s/block
```

### Testnet Setup (Simplified)

For testnet deployment, you can use the deployer address for Safe and Guardian (not recommended for mainnet):

```bash
# Get your deployer address
DEPLOYER=$(pnpm hardhat run scripts/get-deployer-address.ts --network baseSepolia 2>/dev/null || echo "0x...")

# For testnet, you can use deployer address multiple times
SAFE_OWNER_1=$DEPLOYER
SAFE_OWNER_2=$DEPLOYER
SAFE_OWNER_3=$DEPLOYER
SAFE_THRESHOLD=1  # Only need 1 signature since all owners are same
GUARDIAN_MULTISIG=$DEPLOYER
FEE_RECIPIENT=$DEPLOYER
```

**⚠️ Warning:** Using the same address for all Safe owners is only for testnet testing. For production, use proper multisigs with multiple distinct owners.

---

## Deployment Steps

### Step 1: Verify Environment Variables

```bash
# Check RPC connectivity
pnpm hardhat console --network baseSepolia

# In console:
# const provider = ethers.provider;
# const blockNumber = await provider.getBlockNumber();
# console.log('Current block:', blockNumber);
```

### Step 2: Deploy Ops Contracts

```bash
# Deploy ops contracts (required before core escrow contracts)
pnpm hardhat deploy --network baseSepolia --tags yield-ops,dispute-ops,settlement-ops,create-ops,bond-collector
```

This deploys:
- **YieldOps** (Yield withdrawal and distribution)
- **DisputeOps** (Dispute escalation orchestration)
- **SettlementOps** (Settlement execution operations)
- **CreateOps** (Escrow creation validation and computation)
- **BondCollector** (Escalation bond collection)

**Note**: These contracts are deployed with the deployer as `initialOwner`. Roles will be transferred to TimelockController in Step 4.

### Step 3: Deploy Module Management

```bash
# Deploy module management contract
pnpm hardhat deploy --network baseSepolia --tags module-management
```

This deploys:
- **ModuleManagementContract** (Centralized module management for escrow contracts)

### Step 4: Deploy Governance Infrastructure

```bash
# Deploy all governance contracts
pnpm hardhat deploy --network baseSepolia --tags governance
```

This deploys:
- **Safe Multisig** (placeholder if @safe-global/safe-contracts not installed)
- **SewToken** (Governance token)
- **TimelockController** (48h delay)
- **GovGovernor** (OpenZeppelin Governor)
- **Timelock Wiring** (Connects Governor to Timelock)
- **Protocol Governance** (Grants roles and transfers admin roles to TimelockController)

### Step 5: Deploy Core Escrow Contracts

```bash
# Deploy core escrow contracts
pnpm hardhat deploy --network baseSepolia --tags escrow
```

This deploys:
- **EscrowVault** (Main escrow contract for ERC20 tokens)
- **EscrowableERC20** (Optional - ERC20 token with built-in escrow)

**Actions performed automatically**:
- Registers EscrowVault with all ops contracts (CreateOps, SettlementOps, DisputeOps, YieldOps, BondCollector)
- Sets ops contracts in EscrowVault (if deployer has ROLE_ADMIN_CONTRACT)
- Registers EscrowableERC20 with all ops contracts (if deployed)
- Sets ops contracts in EscrowableERC20 (if deployed)

### Step 6: Verify Deployment

```bash
# Export deployment artifacts
pnpm export --network baseSepolia

# View deployment registry
pnpm ts-node scripts/query-deployments.ts chain 84532
```

### Step 7: Verify Contracts on Basescan (Optional)

```bash
# Verify all contracts
pnpm hardhat verify --network baseSepolia --list

# Or verify individually
pnpm hardhat verify --network baseSepolia <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

---

## Deployment Artifacts

After deployment, record the contract addresses:

### Governance Contracts

- **SewToken**: `0x...`
- **TimelockController**: `0x...`
- **GovGovernor**: `0x...`
- **Safe Multisig**: `0x...` (or placeholder)

### Network Information

- **Network**: Base Sepolia
- **Chain ID**: 84532
- **Deployer**: `0x...`
- **Deployment Date**: `YYYY-MM-DD`
- **Transaction Hashes**: [list]

---

## Post-Deployment Configuration

After deployment, you may need to:

1. **Deploy Safe Manually** (if placeholder was used):
   - Go to https://app.safe.global/
   - Deploy Safe with your configured owners
   - Update deployment ledger with Safe address

2. **Transfer Admin Roles** (handled by deployment scripts):
   - Ops contracts: Admin roles transferred to TimelockController in `deploy/15_yield_dispute_ops.ts`
   - Core contracts: Admin roles transferred to TimelockController in `deploy/60_protocol_governance.ts`
   - Verify roles were transferred correctly:
     ```bash
     # Check that TimelockController has DEFAULT_ADMIN_ROLE on all contracts
     pnpm hardhat run scripts/verify-roles.ts --network baseSepolia
     ```

3. **Verify Ops Contract Registration**:
   - Verify EscrowVault is registered with all ops contracts
   - Verify ops contracts are set in EscrowVault
   - Check that EscrowVault can call ops contract functions

4. **Verify Governance Setup**:
   - Check Governor is connected to Timelock
   - Verify Guardian role is set correctly
   - Verify TimelockController has DEFAULT_ADMIN_ROLE on all contracts
   - Test a governance proposal (optional)

---

## Troubleshooting

### Error: "Invalid Safe configuration: 0 owners but threshold is 3"

**Solution:** Set `SAFE_OWNER_1`, `SAFE_OWNER_2`, `SAFE_OWNER_3` environment variables.

For testnet testing, you can use:
```bash
export SAFE_OWNER_1=$DEPLOYER
export SAFE_OWNER_2=$DEPLOYER
export SAFE_OWNER_3=$DEPLOYER
export SAFE_THRESHOLD=1
```

### Error: "Missing GUARDIAN_MULTISIG environment variable"

**Solution:** Set `GUARDIAN_MULTISIG` environment variable. For testnet, can use deployer address.

### Error: "Missing FEE_RECIPIENT environment variable"

**Solution:** Set `FEE_RECIPIENT` environment variable. For testnet, can use deployer address.

---

## Next Steps

After successful deployment:

1. **Verify all contracts** on Basescan
2. **Test governance flows** (create a test proposal)
3. **Deploy IEO contracts** (core escrow contracts and modules)
4. **Configure initial parameters** via governance

**See:** [IEO Release Guide](./ieo/IEO_RELEASE_GUIDE.md)

---

_Last Updated: 2026-01-27_  
**Changes**: Added ops contracts deployment, module management, and role transfer steps
