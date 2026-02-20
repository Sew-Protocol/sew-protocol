/**
 * Phase 4: Yield Generation Testing
 * Validates yield generation over time using AaveYieldModule
 */

import { ethers } from 'hardhat';
import * as fs from 'fs';

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('         PHASE 4: YIELD GENERATION TESTING (AaveYieldModule)');
  console.log('════════════════════════════════════════════════════════════════\n');

  // Use deployment registry to get addresses
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));

  const escrowVaultAddr = registry.contracts.EscrowVault.address;
  const aaveYieldModuleAddr = registry.contracts.AaveYieldModule.address;
  const sewTokenAddr = registry.contracts.SewToken.address;

  if (!escrowVaultAddr || !aaveYieldModuleAddr || !sewTokenAddr) {
    console.log('❌ Could not load contract addresses from registry');
    process.exit(1);
  }

  // Load contracts
  const escrowVault = await ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const aaveYieldModule = await ethers.getContractAt('AaveYieldModule', aaveYieldModuleAddr);
  const sewToken = await ethers.getContractAt('SewToken', sewTokenAddr);

  const deployerAddr = await deployer.getAddress();
  // Use deployer as both buyer and seller for this test
  const buyerAddr = deployerAddr;
  const sellerAddr = deployerAddr;

  console.log('📋 Configuration:');
  console.log(`   Escrow Amount: 500 SEW`);
  console.log(`   Monitoring Period: 7 days`);
  console.log(`   EscrowVault: ${escrowVaultAddr}`);
  console.log(`   AaveYieldModule: ${aaveYieldModuleAddr}`);
  console.log(`   SewToken: ${sewTokenAddr}`);
  console.log(`   Buyer (Deployer): ${buyerAddr}`);
  console.log(`   Seller (Deployer): ${sellerAddr}\n`);

  // Step 1: Prepare tokens
  console.log('📦 STEP 1: Preparing Tokens');
  console.log('   ─────────────────────────────────');

  const amount = ethers.parseEther('500');
  const buyerBalance = await sewToken.balanceOf(buyerAddr);
  console.log(`   Buyer current balance: ${ethers.formatEther(buyerBalance)} SEW`);

  if (buyerBalance < amount) {
    console.log(`   ⚠️  Insufficient balance. Need 500 SEW\n`);
    process.exit(1);
  }

  // Step 2: Approve tokens
  console.log('📦 STEP 2: Approving Tokens for EscrowVault');
  console.log('   ─────────────────────────────────');

  const approveTx = await sewToken.connect(deployer).approve(escrowVaultAddr, amount);
  const approveReceipt = await approveTx.wait();
  console.log(`   ✅ Approval TX: ${approveReceipt?.transactionHash}`);
  console.log(`   Amount approved: 500 SEW\n`);

  // Step 3: Create escrow with yield enabled
  console.log('🏦 STEP 3: Creating Escrow with Yield Enabled');
  console.log('   ─────────────────────────────────');

  const autoReleaseTime = Math.floor(Date.now() / 1000) + 86400 * 7; // 7 days
  const autoCancelTime = 0; // No auto-cancel

  const escrowSettings = {
    customResolver: ethers.ZeroAddress,
    releaseAddress: sellerAddr,
    yieldPreset: 1, // TO_SENDER - yield goes to buyer
    autoReleaseTime,
    autoCancelTime,
  };

  console.log(`   Yield Preset: 1 (TO_SENDER - yield to buyer)`);
  console.log(`   Seller (Recipient): ${sellerAddr}`);
  console.log(`   Auto-Release Time: ${new Date(autoReleaseTime * 1000).toISOString()}`);

  const createTx = await escrowVault.connect(deployer).createEscrow(
    sewTokenAddr,
    sellerAddr,
    amount,
    escrowSettings
  );

  const createReceipt = await createTx.wait();
  console.log(`   ✅ Creation TX: ${createReceipt?.transactionHash}`);

  // Get workflow ID from event
  const createEvent = createReceipt?.logs
    .map(log => {
      try {
        return escrowVault.interface.parseLog(log);
      } catch {
        return null;
      }
    })
    .find(event => event?.name === 'EscrowCreated');

  if (!createEvent) {
    console.log('   ❌ Could not find EscrowCreated event');
    process.exit(1);
  }

  const workflowId = createEvent.args[0];
  console.log(`   Workflow ID: ${workflowId}`);
  console.log(`   Escrow Amount: 500 SEW\n`);

  // Step 4: Verify escrow state
  console.log('🔍 STEP 4: Verifying Initial Escrow State');
  console.log('   ─────────────────────────────────');

  const escrowInfo = await escrowVault.getEscrowInfo(workflowId);
  console.log(`   Token: ${escrowInfo.token}`);
  console.log(`   Amount: ${ethers.formatEther(escrowInfo.amount)} SEW`);
  console.log(`   Buyer: ${escrowInfo.buyer}`);
  console.log(`   Seller: ${escrowInfo.seller}`);
  console.log(`   Yield Preset: ${escrowInfo.yieldPreset}`);
  console.log(`   Status: ${escrowInfo.status}\n`);

  // Step 5: Check yield initialization
  console.log('⚡ STEP 5: Checking Yield Initialization');
  console.log('   ─────────────────────────────────');

  try {
    const yieldInfo = await aaveYieldModule.getYieldInfo(workflowId);
    console.log(`   Yield Info initialized: ✅`);
    console.log(`   Principal: ${ethers.formatEther(yieldInfo.principal)} SEW`);
    console.log(`   Accrued: ${ethers.formatEther(yieldInfo.accrued)} SEW`);
  } catch (error) {
    console.log(`   Yield Info: ${error}`);
  }

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('✅ PHASE 4 SETUP COMPLETE');
  console.log('════════════════════════════════════════════════════════════════');
  console.log(`\n📊 YIELD MONITORING IN PROGRESS`);
  console.log(`   Workflow ID: ${workflowId}`);
  console.log(`   Initial Amount: 500 SEW`);
  console.log(`   Monitoring Duration: 7 days`);
  console.log(`   Network: Base Sepolia (84532)`);
  console.log('\n📝 Next Steps:');
  console.log(`   1. Run yield tracking periodically:`);
  console.log(`      pnpm hardhat run scripts/testnet/phase4-yield-tracking.ts --network baseSepolia ${workflowId}`);
  console.log(`   2. Monitor yield accumulation over 7 days`);
  console.log(`   3. Document daily yield increases`);
  console.log(`   4. Test withdrawal flows (principal + yield)`);
  console.log(`   5. Create Phase 4 results documentation`);
  console.log('\n');
}

main().catch(error => {
  console.error('Error:', error);
  process.exit(1);
});
