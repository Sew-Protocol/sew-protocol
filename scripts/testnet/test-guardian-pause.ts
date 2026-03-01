/**
 * Test Guardian Multisig - pauseYieldDeposits
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/test-guardian-pause.ts
 *
 * Requires GUARDIAN_PRIVATE_KEY env var (or will skip)
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

function optionalWallet(pkEnv: string | undefined, provider: any): any {
  if (!pkEnv || pkEnv.trim().length === 0) return null;
  return new ethers.Wallet(pkEnv, provider);
}

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia`);
  }

  const provider = hre.ethers.provider;
  const guardian = optionalWallet(process.env.GUARDIAN_PRIVATE_KEY, provider);

  if (!guardian) {
    console.log('\n⚠️  GUARDIAN_PRIVATE_KEY not set - skipping guardian test');
    console.log('Set GUARDIAN_PRIVATE_KEY to test guardian functions\n');
    return;
  }

  // Load contracts
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));

  const createOpsAddr = registry.contracts.CreateOps.address;
  const createOps = await hre.ethers.getContractAt('CreateOps', createOpsAddr);

  const guardianAddr = await guardian.getAddress();

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('       GUARDIAN TEST: pauseYieldDeposits()');
  console.log('════════════════════════════════════════════════════════════════\n');

  console.log('📋 Configuration:');
  console.log(`   Guardian: ${guardianAddr}`);
  console.log(`   CreateOps: ${createOpsAddr}\n`);

  // Check current pause state
  const isPausedBefore = await createOps.yieldDepositsPaused();
  console.log(`📊 State Before: yieldDepositsPaused = ${isPausedBefore}\n`);

  if (isPausedBefore) {
    console.log('⚠️  Yield deposits already paused. Skipping pause test.');
  } else {
    // Test: Guardian pauses yield deposits
    console.log('🔐 TEST: Guardian calls pauseYieldDeposits()');

    try {
      const tx = await createOps
        .connect(guardian)
        .pauseYieldDeposits('Test pause from guardian multisig');
      const rcpt = await tx.wait();
      console.log(`   ✅ Transaction: ${rcpt?.transactionHash}`);
    } catch (err: any) {
      console.log(`   ❌ FAILED: ${err.message}`);
      return;
    }

    // Verify state changed
    const isPausedAfter = await createOps.yieldDepositsPaused();
    console.log(`📊 State After: yieldDepositsPaused = ${isPausedAfter}\n`);

    if (!isPausedAfter) {
      console.log('❌ TEST FAILED: State did not change to paused');
      return;
    }

    console.log('✅ GUARDIAN TEST PASSED: pauseYieldDeposits() works!\n');
  }

  // Note: Resume requires ROLE_TIMELOCK, not guardian
  console.log('📝 Note: Resume requires ROLE_TIMELOCK (guardian is down-only)\n');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
