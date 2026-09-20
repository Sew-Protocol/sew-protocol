/**
 * Test Guardian Multisig - YieldOps.recoverTokens()
 *
 * NOTE: The YieldOps contract has been removed from the protocol. This guardian
 * recovery test is no longer applicable. Kept as a stub so the run target still
 * resolves, and so operators don't attempt to reach a removed contract.
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/test-guardian-recover.ts
 */

import hre from 'hardhat';
import { ethers } from 'ethers';

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia`);
  }

  const provider = hre.ethers.provider;
  void provider;

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('       GUARDIAN TEST: recoverTokens()');
  console.log('════════════════════════════════════════════════════════════════\n');

  console.log('⏭️  SKIP: YieldOps.recoverTokens() test is no longer applicable.');
  console.log('   The YieldOps contract has been removed from the protocol.');
  console.log('   Guardian-controlled token recovery is now handled directly');
  console.log('   on the remaining contracts that still support ROLE_GUARDIAN.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
