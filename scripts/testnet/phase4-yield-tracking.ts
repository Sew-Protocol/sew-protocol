/**
 * Phase 4: Yield Tracking Script
 * ==============================
 * 
 * Monitors yield accumulation over time
 * Run this periodically to track yield generation
 */

import { ethers } from 'hardhat';
import { EscrowVault, AaveYieldModule } from '../typechain';
import * as fs from 'fs';
import * as path from 'path';

interface YieldSnapshot {
  timestamp: string;
  date: string;
  workflowId: string;
  principal: string;
  accrued: string;
  totalValue: string;
  yieldPercentage: number;
  txHash?: string;
}

const TRACKING_FILE = path.join(__dirname, '../../.phase4-yield-tracking.json');

async function loadTracking(): Promise<YieldSnapshot[]> {
  if (fs.existsSync(TRACKING_FILE)) {
    return JSON.parse(fs.readFileSync(TRACKING_FILE, 'utf-8'));
  }
  return [];
}

async function saveTracking(snapshots: YieldSnapshot[]): Promise<void> {
  fs.writeFileSync(TRACKING_FILE, JSON.stringify(snapshots, null, 2));
}

async function main() {
  const workflowIdStr = process.argv[2];

  if (!workflowIdStr) {
    console.log('Usage: pnpm hardhat run scripts/testnet/phase4-yield-tracking.ts --network baseSepolia <workflowId>');
    process.exit(1);
  }

  const workflowId = BigInt(workflowIdStr);
  const escrowVault = (await ethers.getContractAt('EscrowVault', process.env.ESCROW_VAULT_ADDRESS || '')) as EscrowVault;
  const aaveYieldModule = (await ethers.getContractAt('AaveYieldModule', process.env.AAVE_YIELD_MODULE_ADDRESS || '')) as AaveYieldModule;

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('              PHASE 4: YIELD TRACKING SNAPSHOT');
  console.log('════════════════════════════════════════════════════════════════\n');

  // Get current block for timestamp
  const block = await ethers.provider.getBlock('latest');
  if (!block) {
    console.log('❌ Could not get current block');
    process.exit(1);
  }

  const timestamp = new Date(block.timestamp * 1000).toISOString();
  const date = new Date(block.timestamp * 1000).toLocaleDateString('en-US', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  });

  console.log(`📅 Timestamp: ${timestamp}`);
  console.log(`   Block: ${block.number}`);
  console.log(`   Workflow ID: ${workflowId}\n`);

  // Get escrow info
  const escrowInfo = await escrowVault.getEscrowInfo(workflowId);
  console.log('📋 Escrow Info:');
  console.log(`   Token: ${escrowInfo.token}`);
  console.log(`   Amount: ${ethers.formatEther(escrowInfo.amount)} SEW`);
  console.log(`   Buyer: ${escrowInfo.buyer}`);
  console.log(`   Seller: ${escrowInfo.seller}`);
  console.log(`   Status: ${escrowInfo.status}\n`);

  // Get yield info
  console.log('⚡ Yield Tracking:');
  let principal = BigInt(0);
  let accrued = BigInt(0);

  try {
    const yieldInfo = await aaveYieldModule.getYieldInfo(workflowId);
    principal = yieldInfo.principal;
    accrued = yieldInfo.accrued;

    console.log(`   Principal: ${ethers.formatEther(principal)} SEW`);
    console.log(`   Accrued Yield: ${ethers.formatEther(accrued)} SEW`);

    const totalValue = principal + accrued;
    const yieldPercentage = principal > 0n ? Number((accrued * 10000n) / principal) / 100 : 0;

    console.log(`   Total Value: ${ethers.formatEther(totalValue)} SEW`);
    console.log(`   Yield %: ${yieldPercentage.toFixed(4)}%\n`);

    // Save snapshot
    const snapshot: YieldSnapshot = {
      timestamp,
      date,
      workflowId: workflowId.toString(),
      principal: ethers.formatEther(principal),
      accrued: ethers.formatEther(accrued),
      totalValue: ethers.formatEther(totalValue),
      yieldPercentage,
    };

    let snapshots = await loadTracking();
    snapshots.push(snapshot);
    await saveTracking(snapshots);

    // Print tracking history
    console.log('📊 Yield History:');
    console.log(`   Total snapshots: ${snapshots.length}`);

    if (snapshots.length > 1) {
      const first = snapshots[0];
      const last = snapshots[snapshots.length - 1];
      const firstAccrued = parseFloat(first.accrued);
      const lastAccrued = parseFloat(last.accrued);
      const accruedGrowth = lastAccrued - firstAccrued;

      console.log(`   First snapshot accrued: ${first.accrued} SEW (${first.date})`);
      console.log(`   Latest snapshot accrued: ${last.accrued} SEW (${last.date})`);
      console.log(`   Growth: ${accruedGrowth.toFixed(6)} SEW`);
      console.log(`   Snapshots: ${snapshots.length}`);

      // Calculate APY estimate
      if (snapshots.length >= 2) {
        const timeFirst = new Date(snapshots[0].timestamp).getTime();
        const timeLast = new Date(snapshots[snapshots.length - 1].timestamp).getTime();
        const daysElapsed = (timeLast - timeFirst) / (1000 * 60 * 60 * 24);

        if (daysElapsed > 0) {
          const principalAmount = parseFloat(snapshots[0].principal);
          const dailyYield = accruedGrowth / daysElapsed;
          const apy = (dailyYield / principalAmount) * 365 * 100;

          console.log(`   Days elapsed: ${daysElapsed.toFixed(2)}`);
          console.log(`   Estimated APY: ${apy.toFixed(2)}%\n`);
        }
      }
    }

    console.log('════════════════════════════════════════════════════════════════');
    console.log('✅ YIELD SNAPSHOT RECORDED');
    console.log('════════════════════════════════════════════════════════════════\n');
  } catch (error) {
    console.log(`   ❌ Error getting yield info: ${error}\n`);
    process.exit(1);
  }
}

main().catch(error => {
  console.error('Error:', error);
  process.exit(1);
});
