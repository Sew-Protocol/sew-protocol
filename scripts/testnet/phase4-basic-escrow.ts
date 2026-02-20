/**
 * Phase 4: Create Basic Escrow (no yield) to test functionality
 * Then we'll enable yield once we understand the integration
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('       PHASE 4: BASIC ESCROW CREATION (No Yield - Debug Mode)');
  console.log('════════════════════════════════════════════════════════════════\n');

  // Load contracts
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));

  const escrowVaultAddr = registry.contracts.EscrowVault.address;
  const sewTokenAddr = registry.contracts.SewToken.address;

  const escrowVault = await ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const sewToken = await ethers.getContractAt('SewToken', sewTokenAddr);

  const deployerAddr = await deployer.getAddress();

  console.log('📋 Configuration:');
  console.log(`   Escrow Amount: 100 SEW (reduced for testing)`);
  console.log(`   EscrowVault: ${escrowVaultAddr}`);
  console.log(`   SewToken: ${sewTokenAddr}`);
  console.log(`   Account: ${deployerAddr}\n`);

  // Step 1: Check balance
  console.log('📦 STEP 1: Checking Token Balance');
  const amount = ethers.parseEther('100');
  const balance = await sewToken.balanceOf(deployerAddr);
  console.log(`   Balance: ${ethers.formatEther(balance)} SEW`);

  if (balance < amount) {
    console.log(`   ❌ Insufficient balance\n`);
    process.exit(1);
  }
  console.log('   ✅ Sufficient balance\n');

  // Step 2: Approve
  console.log('📦 STEP 2: Approving Tokens');
  const approveTx = await sewToken.approve(escrowVaultAddr, amount);
  const approveRcpt = await approveTx.wait();
  console.log(`   ✅ TX: ${approveRcpt?.transactionHash}\n`);

  // Step 3: Create escrow WITHOUT yield
  console.log('🏦 STEP 3: Creating Escrow (Yield: OFF)');
  const escrowSettings = {
    customResolver: ethers.ZeroAddress,
    releaseAddress: ethers.ZeroAddress, // No special release authorization
    yieldPreset: 0, // OFF
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };

  const createTx = await escrowVault.connect(deployer).createEscrow(
    sewTokenAddr,
    deployerAddr,
    amount,
    escrowSettings
  );

  const createRcpt = await createTx.wait();
  console.log(`   ✅ TX: ${createRcpt?.transactionHash}`);

  // Get workflow ID from event
  let workflowId: bigint | null = null;
  if (createRcpt?.logs) {
    for (const log of createRcpt.logs) {
      try {
        const parsed = escrowVault.interface.parseLog(log);
        if (parsed?.name === 'EscrowCreated') {
          workflowId = parsed.args[0] as bigint;
          break;
        }
      } catch {}
    }
  }

  if (!workflowId) {
    console.log('   ❌ Could not find EscrowCreated event\n');
    process.exit(1);
  }

  console.log(`   Workflow ID: ${workflowId}\n`);

  // Step 4: Verify escrow was created
  console.log('🔍 STEP 4: Verifying Escrow');
  const escrowInfo = await escrowVault.getEscrowInfo(workflowId);
  console.log(`   Token: ${escrowInfo.token}`);
  console.log(`   Amount: ${ethers.formatEther(escrowInfo.amount)} SEW`);
  console.log(`   Buyer (from): ${escrowInfo.buyer}`);
  console.log(`   Seller (to): ${escrowInfo.seller}`);
  console.log(`   Status: ${escrowInfo.status}`);
  console.log(`   Yield Preset: ${escrowInfo.yieldPreset}\n`);

  console.log('════════════════════════════════════════════════════════════════');
  console.log('✅ PHASE 4 BASIC SETUP COMPLETE');
  console.log('════════════════════════════════════════════════════════════════\n');

  console.log('📊 Escrow Created Successfully');
  console.log(`   Workflow ID: ${workflowId}`);
  console.log(`   Amount: 100 SEW`);
  console.log(`   Yield: OFF (for baseline testing)`);
  console.log(`   Next: Will modify to enable yield once pool integration is verified\n`);

  return workflowId.toString();
}

main()
  .then(workflowId => {
    console.log(`ℹ️  To test yield, run:`);
    console.log(`   pnpm hardhat run scripts/testnet/phase4-yield-tracking.ts --network baseSepolia ${workflowId}\n`);
  })
  .catch(error => {
    console.error('Error:', error);
    process.exit(1);
  });
