# Contract Verification Documentation

**Last Updated:** 2026-01-06  
**Purpose:** Step-by-step guide for verifying deployed contracts on block explorers

---

## Overview

Contract verification is essential for transparency and security. This document provides procedures for verifying all deployed contracts on Basescan (Base block explorer).

**Current Status:** ⚠️ **Partial** - Verification script exists but only handles example contract

---

## Verification Script

**Location:** `scripts/verify.ts`

**Current Implementation:**
- Only handles `UpgradeableBox` example contract
- Requires `ADDR_UPGRADEABLE_BOX` environment variable

**Needs Enhancement:**
- Support for all production contracts
- Automatic contract detection from deployment ledger
- Batch verification support

---

## Contracts to Verify

### Core Contracts

1. **BaseEscrow** (if deployed separately)
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** None (abstract contract, not deployed directly)

2. **EscrowVault**
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** `(uint256 escrowFee, address escrowFeeAddress)`

3. **EscrowableERC20**
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** `(string name, string symbol, uint256 escrowFee, address escrowFeeAddress)`

### Modules

4. **DefaultResolutionModule**
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** `(address initialOwner, address initialResolver)`

5. **AaveYieldGenerationModule**
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** `(address initialOwner, address aavePoolAddress, address aTokenAddress)`

6. **DefaultYieldDistributionModule**
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** `(address initialOwner)`

### Libraries

7. **SettingsValidationLibrary**
   - **Type:** Library (no constructor)
   - **Note:** Libraries don't need constructor args

8. **EscrowEncodingLibrary**
   - **Type:** Library (no constructor)

9. **ResolverLogicLibrary**
   - **Type:** Library (no constructor)

10. **RecoveryLibrary**
    - **Type:** Library (no constructor)

11. **ModuleProposalLibrary**
    - **Type:** Library (no constructor)

12. **YieldHandlingLibrary**
    - **Type:** Library (no constructor)

13. **ResolverActionLibrary**
    - **Type:** Library (no constructor)

14. **StateManagementLibrary**
    - **Type:** Library (no constructor)

15. **DisputeInitializationLibrary**
    - **Type:** Library (no constructor)

16. **ModuleManagementLibrary**
    - **Type:** Library (no constructor)

17. **EscrowCreationLibrary**
    - **Type:** Library (no constructor)

### Governance

18. **GovGovernor**
   - **Type:** Implementation contract (immutable)
   - **Constructor Args:** `(address token, address timelock, ...)`

19. **TimelockController**
   - **Type:** OpenZeppelin contract
   - **Constructor Args:** `(uint256 minDelay, address[] proposers, address[] executors, address admin)`

---

## Verification Methods

### Method 1: Hardhat Verify Plugin

**Tool:** `@nomicfoundation/hardhat-verify`

**Basic Command:**
```bash
npx hardhat verify --network baseMainnet <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

**Example:**
```bash
npx hardhat verify --network baseMainnet \
  0x1234...5678 \
  "100" \
  "0xabcd...ef01"
```

### Method 2: Enhanced Verification Script

**Location:** `scripts/verify.ts` (needs enhancement)

**Current Usage:**
```bash
ADDR_UPGRADEABLE_BOX=0x1234... pnpm verify
```

**Proposed Enhancement:**
```bash
pnpm verify --contract EscrowVault --network baseMainnet
pnpm verify --contract EscrowableERC20 --network baseMainnet
pnpm verify --all --network baseMainnet
```

### Method 3: Basescan Web Interface

1. Navigate to contract address on Basescan
2. Click "Contract" tab
3. Click "Verify and Publish"
4. Select verification method:
   - **Via Standard JSON Input** (recommended)
   - Via flattened source code
   - Via Sourcify
5. Upload contract source and metadata
6. Enter constructor arguments
7. Submit for verification

---

## Step-by-Step Verification Procedures

### Procedure 1: Verify EscrowVault

**Prerequisites:**
- Contract deployed address
- Constructor arguments used during deployment
- Network (Base mainnet or Base Sepolia)

**Steps:**

1. **Get Deployment Information**
   ```bash
   # From deployment ledger
   cat deploy-ledger/baseMainnet/<timestamp>/deployments.json | jq '.EscrowVault'
   ```

2. **Extract Constructor Arguments**
   - Escrow fee: `[VALUE]` (e.g., 100 = 1%)
   - Fee address: `[ADDRESS]`

3. **Verify Contract**
   ```bash
   npx hardhat verify --network baseMainnet \
    <ESCROW_VAULT_ADDRESS> \
    <ESCROW_FEE> \
    <FEE_ADDRESS>
   ```

4. **Verify on Basescan**
   - Navigate to contract address
   - Verify source code matches
   - Verify constructor arguments

**Expected Output:**
```
Successfully verified contract EscrowVault at 0x...
```

---

### Procedure 2: Verify EscrowableERC20

**Steps:**

1. **Get Deployment Information**
   ```bash
   cat deploy-ledger/baseMainnet/<timestamp>/deployments.json | jq '.EscrowableERC20'
   ```

2. **Extract Constructor Arguments**
   - Name: `[STRING]`
   - Symbol: `[STRING]`
   - Escrow fee: `[VALUE]`
   - Fee address: `[ADDRESS]`

3. **Verify Contract**
   ```bash
   npx hardhat verify --network baseMainnet \
    <ESCROWABLE_ERC20_ADDRESS> \
    "<TOKEN_NAME>" \
    "<TOKEN_SYMBOL>" \
    <ESCROW_FEE> \
    <FEE_ADDRESS>
   ```

---

### Procedure 3: Verify Libraries

**Note:** Libraries don't have constructor arguments, but may need linking information.

**Steps:**

1. **Get Library Address**
   ```bash
   cat deploy-ledger/baseMainnet/<timestamp>/deployments.json | jq '.SettingsValidationLibrary'
   ```

2. **Verify Library**
   ```bash
   npx hardhat verify --network baseMainnet <LIBRARY_ADDRESS>
   ```

**Note:** If library is linked into contracts, verification may require linked contract addresses.

---

### Procedure 4: Verify Governance Contracts

**GovGovernor:**

```bash
npx hardhat verify --network baseMainnet \
  <GOVERNOR_ADDRESS> \
  <TOKEN_ADDRESS> \
  <TIMELOCK_ADDRESS> \
  <VOTING_DELAY> \
  <VOTING_PERIOD> \
  <PROPOSAL_THRESHOLD> \
  <QUORUM_NUMERATOR>
```

**TimelockController:**

```bash
npx hardhat verify --network baseMainnet \
  <TIMELOCK_ADDRESS> \
  <MIN_DELAY> \
  "<PROPOSERS_ARRAY>" \
  "<EXECUTORS_ARRAY>" \
  <ADMIN_ADDRESS>
```

---

## Enhanced Verification Script

### Proposed Enhancement

**File:** `scripts/verify.ts`

**Features:**
- Read deployment ledger automatically
- Extract constructor arguments from deployment
- Support for all contract types
- Batch verification
- Error handling and retries

**Example Implementation:**

```typescript
import { run, network } from 'hardhat';
import { readFileSync } from 'fs';
import { join } from 'path';

async function main() {
  const contractName = process.argv[2] || 'all';
  const networkName = network.name;
  
  // Read deployment ledger
  const ledgerPath = `deploy-ledger/${networkName}/latest/deployments.json`;
  const deployments = JSON.parse(readFileSync(ledgerPath, 'utf-8'));
  
  if (contractName === 'all') {
    // Verify all contracts
    for (const [name, info] of Object.entries(deployments)) {
      await verifyContract(name, info);
    }
  } else {
    // Verify specific contract
    const info = deployments[contractName];
    if (!info) throw new Error(`Contract ${contractName} not found`);
    await verifyContract(contractName, info);
  }
}

async function verifyContract(name: string, info: any) {
  try {
    await run('verify:verify', {
      address: info.address,
      constructorArguments: info.args || [],
    });
    console.log(`✅ Verified ${name} at ${info.address}`);
  } catch (error) {
    console.error(`❌ Failed to verify ${name}:`, error);
  }
}

main().catch(console.error);
```

---

## Verification Checklist

### Pre-Verification

- [ ] All contracts deployed successfully
- [ ] Deployment addresses documented
- [ ] Constructor arguments documented
- [ ] Network confirmed (mainnet vs testnet)

### During Verification

- [ ] Verify core contracts (EscrowVault, EscrowableERC20)
- [ ] Verify modules (DefaultResolutionModule, AaveYieldGenerationModule)
- [ ] Verify libraries (all 10+ libraries)
- [ ] Verify governance contracts (Governor, TimelockController)
- [ ] Document verification transaction hashes

### Post-Verification

- [ ] All contracts verified on Basescan
- [ ] Source code matches deployed bytecode
- [ ] Constructor arguments correct
- [ ] Verification documented in deployment docs
- [ ] Links to verified contracts added to documentation

---

## Common Issues

### Issue 1: Constructor Arguments Mismatch

**Symptom:** Verification fails with "constructor arguments mismatch"

**Solution:**
- Double-check constructor arguments
- Ensure argument types match (string vs bytes, etc.)
- Use ABI encoding if needed

### Issue 2: Library Linking

**Symptom:** Verification fails for contracts using libraries

**Solution:**
- Verify libraries first
- Include library addresses in verification
- Use `--libraries` flag if needed

### Issue 3: Compiler Version Mismatch

**Symptom:** Verification fails with compiler version error

**Solution:**
- Ensure local compiler version matches deployment
- Check `hardhat.config.ts` for compiler settings
- Use `--compiler-version` flag if needed

### Issue 4: Optimization Settings

**Symptom:** Bytecode doesn't match

**Solution:**
- Ensure optimizer settings match (runs, viaIR)
- Check `hardhat.config.ts` for optimizer config
- Use `--optimizer-runs` flag if needed

---

## Verification for Different Networks

### Base Mainnet

```bash
npx hardhat verify --network baseMainnet <ADDRESS> <ARGS>
```

### Base Sepolia

```bash
npx hardhat verify --network baseSepolia <ADDRESS> <ARGS>
```

### Local/Hardhat

Verification not needed for local networks.

---

## Automated Verification

### CI/CD Integration

**Proposed:** Add verification step to CI/CD pipeline after deployment

```yaml
- name: Verify Contracts
  run: |
    pnpm verify --all --network ${{ env.NETWORK }}
  env:
    ETHERSCAN_API_KEY: ${{ secrets.ETHERSCAN_API_KEY }}
```

**Note:** Requires Etherscan API key for Basescan.

---

## Verification Status Tracking

**Document:** `docs/DEPLOYMENT_VERIFICATION_STATUS.md` (to be created)

**Track:**
- Contract address
- Verification status (✅ Verified / ❌ Not Verified)
- Verification transaction hash
- Verification date
- Network

---

## Related Documents

- [`docs/plans/MAINNET_DEPLOYMENT_PLAN.md`](./plans/MAINNET_DEPLOYMENT_PLAN.md) - Deployment plan
- [`scripts/verify.ts`](../scripts/verify.ts) - Verification script
- [`hardhat.config.ts`](../hardhat.config.ts) - Hardhat configuration

---

**Note:** This document should be updated as verification procedures are refined and automated.


