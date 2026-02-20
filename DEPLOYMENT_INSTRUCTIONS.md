# Deployment & Verification Guide

## Quick Reference

| Aspect | Details |
|--------|---------|
| **Network** | Base Sepolia (ChainID: 84532) |
| **Status** | ✅ Fully Deployed & Tested |
| **Core Contracts** | 13 deployed & operational |
| **Yield Module** | AaveYieldModule integrated |
| **Last Updated** | Feb 20, 2026 |

---

## Step 1: Verify Deployment Status

### Check All Contracts Are Deployed

```bash
# View deployment manifest
cat deploy-registry/base-sepolia-v1-testnet.json | jq '.contracts | keys'

# Expected output: 13 core contracts + AaveYieldModule
```

### Verify Key Contract Addresses

```bash
# EscrowVault
cast code 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a --rpc-url https://sepolia.base.org | head -c 100
# Should show: 0x60806040... (contract bytecode exists)

# SewToken
cast code 0x62BD47154D0b5Fe435F220E1294405040102b2ba --rpc-url https://sepolia.base.org | head -c 100
# Should show: 0x60806040... (contract bytecode exists)

# AaveYieldModule
cast code 0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01 --rpc-url https://sepolia.base.org | head -c 100
# Should show: 0x60806040... (contract bytecode exists)
```

---

## Step 2: Run Validation Tests

### Phase 0: Health Check

```bash
pnpm hardhat run scripts/testnet/phase0-base-sepolia-health.ts --network baseSepolia
```

**Expected Output:**
```
✅ 1) Bytecode presence
✅ 2) Core wiring
✅ 3) Ops registration (ROLE_ESCROW_CONTRACT)
✅ 4) Slow-lane admin wiring (EscrowGovernanceTimelock)
✅ 5) Timelock wiring (minimum)
⏭️  6) Minimal E2E on fork (ERC20Mock) - skipped (single signer)
```

### Phase 1: Multi-Party Escrow Flows

```bash
pnpm hardhat run scripts/testnet/phase1-multi-party-escrow.ts --network baseSepolia
```

**Expected Output:**
```
TEST 1: Create → Release
✅ Escrow created
✅ Approved
✅ Released
✅ Seller received 100.0 SEW
✅ TEST PASSED

TEST 2: Create → Cancel
✅ Escrow created
✅ Approved
✅ Cancelled
✅ Buyer balance restored
✅ TEST PASSED
```

### Phase 2: Aave Yield Integration

```bash
pnpm hardhat run scripts/testnet/phase2-aave-yield-testing.ts --network baseSepolia
```

**Expected Output:**
```
📋 Configuration: (contract addresses shown)
✅ 1️⃣  Approving tokens
✅ 2️⃣  Creating escrow with Aave yield
   Workflow ID: (number)
   Amount after fee: 250.0 SEW
✅ 3️⃣  Escrow is now earning yield on Aave
✅ 4️⃣  Releasing escrow
   Recipient received: 250.0 SEW
   ℹ️  No yield yet (too short timeframe)
✅ PHASE 2 COMPLETE
```

---

## Step 3: Verify Contract Code on Chain

### Check EscrowVault Verification

```bash
# Visit BaseScan
https://sepolia.basescan.org/address/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a#code

# Expected: Source code visible (green checkmark for verified)
```

### Check AaveYieldModule Verification

```bash
# Visit BaseScan
https://sepolia.basescan.org/address/0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01#code

# Also verified on Sourcify:
https://repo.sourcify.dev/contracts/full_match/84532/0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01/
```

---

## Step 4: Check Contract State

### Verify Escrow Settings

```bash
# Check escrow fee (should be 0 on testnet)
cast call 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a "escrowFee()" \
  --rpc-url https://sepolia.base.org

# Check escrow count
cast call 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a "escrowCount()" \
  --rpc-url https://sepolia.base.org

# Check token balance of EscrowVault
cast call 0x62BD47154D0b5Fe435F220E1294405040102b2ba \
  "balanceOf(address)" 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a \
  --rpc-url https://sepolia.base.org
```

---

## Step 5: Create a Test Escrow

### Manual Escrow Creation

```bash
# Create a test script (e.g., test-escrow.ts)
import hre from 'hardhat';

async function main() {
  const [signer] = await hre.ethers.getSigners();
  
  const escrowVault = await hre.ethers.getContractAt(
    require('./deployments/baseSepolia/EscrowVault.json').abi,
    '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a',
    signer
  );
  
  const token = await hre.ethers.getContractAt(
    ['function approve(address,uint256) returns (bool)'],
    '0x62BD47154D0b5Fe435F220E1294405040102b2ba',
    signer
  );
  
  const amount = hre.ethers.parseEther('100');
  const recipient = '0xdddddddddddddddddddddddddddddddddddddddd';
  
  // Approve
  await token.approve(escrowVault.target, amount);
  
  // Create
  const tx = await escrowVault.createEscrow(
    token.target,
    recipient,
    amount,
    {
      customResolver: hre.ethers.ZeroAddress,
      releaseAddress: hre.ethers.ZeroAddress,
      yieldPreset: 0, // 0 = OFF, 1 = Aave
      autoReleaseTime: 0,
      autoCancelTime: 0
    }
  );
  
  const receipt = await tx.wait();
  console.log('Escrow created:', receipt?.transactionHash);
}

main();
```

Run it:
```bash
pnpm hardhat run test-escrow.ts --network baseSepolia
```

---

## Step 6: Verify Aave Integration

### Check Aave Yield is Available

```bash
pnpm hardhat run scripts/testnet/test-aave-yield.ts --network baseSepolia
```

**Expected Output:**
```
Testing Aave yield module availability...
Creating escrow with yieldPreset=1 (Aave)...
✅ Created escrow with Aave yield
✅ Confirmed - Aave yield module is available!
```

### Check Aave Pool Address

```bash
# Verify the pool is on-chain
cast code 0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27 \
  --rpc-url https://sepolia.base.org | head -c 100

# Should show: 0x60806040... (contract exists)
```

---

## Troubleshooting

### Issue: Escrow creation fails with InvalidAddress

**Cause:** Recipient same as sender  
**Fix:** Use different address for recipient

```bash
# ❌ FAILS
recipient = signer.address;  // Same as sender

# ✅ WORKS
recipient = '0xdddddddddddddddddddddddddddddddddddddddd';  // Different
```

### Issue: Contract not found on BaseScan

**Cause:** Contract address may be wrong  
**Fix:** Verify in deployment artifact

```bash
cat deployments/baseSepolia/EscrowVault.json | jq '.address'
# Copy this address to BaseScan
```

### Issue: Verification fails with "Constructor arguments mismatch"

**Cause:** Constructor arguments not matching deployed bytecode  
**Fix:** Use arguments stored in deployment file

```bash
cat deployments/baseSepolia/EscrowVault.json | jq '.args'
# Use these exact arguments for verification
```

### Issue: Aave yield showing 0 after release

**Cause:** Insufficient time for yield to accrue  
**Fix:** Use longer duration (Phase 4 tests 7-30 days)

---

## Production Deployment (When Ready)

### Before Mainnet Deployment

1. **Update Configuration**
   ```bash
   # Update hardhat.config.ts with mainnet RPC
   # Update config/chains.config.ts with mainnet Aave pool
   # Get mainnet Aave pool from: https://github.com/bgd-labs/aave-address-book
   ```

2. **Update Fee Configuration**
   ```bash
   # Set appropriate escrow fee basis points
   # Testnet uses 0 bps, production likely needs 25-50 bps
   ```

3. **Verify All Governance**
   ```bash
   # Ensure TimelockController is properly configured
   # Verify GovGovernor setup
   # Check role assignments
   ```

4. **Deploy to Mainnet**
   ```bash
   pnpm hardhat deploy --network base
   ```

5. **Verify on MainnetEtherscan**
   ```bash
   ETHERSCAN_API_KEY=<key> pnpm hardhat verify --network base <address> <args>
   ```

---

## Reference

| Document | Purpose |
|----------|---------|
| `DEPLOYMENT_CURRENT_STATUS.md` | Overall deployment status (START HERE) |
| `ESCROW_VALIDATION_ROOT_CAUSE.md` | Protocol constraint explanation |
| `TESTNET_VALIDATION_COMPLETE.md` | Comprehensive test results |
| `VERIFICATION_STATUS.md` | Contract verification details |
| `deploy-registry/base-sepolia-v1-testnet.json` | Machine-readable manifest |

---

## Support

- **Contract Addresses:** See `deploy-registry/base-sepolia-v1-testnet.json`
- **ABI Files:** `deployments/baseSepolia/*.json`
- **Test Scripts:** `scripts/testnet/*.ts`
- **Git History:** `git log --oneline` (full deployment trace)

---

**Status:** ✅ Ready for Testing & Production Deployment
