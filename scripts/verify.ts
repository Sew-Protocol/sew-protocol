/**
 * Contract verification on testnet/mainnet.
 * 
 * This script is a wrapper to verify a single contract at a given address.
 * For comprehensive verification of all deployed contracts, use:
 *   npx hardhat run scripts/verify-base-sepolia.ts --network baseSepolia
 * 
 * To verify a single contract, set CONTRACT_ADDRESS env var:
 *   CONTRACT_ADDRESS=0x... npx hardhat run scripts/verify.ts --network baseSepolia
 */

import { run, network } from 'hardhat';
import { requireConfirmForMainnetLike } from '../hardhat.config';

async function main() {
  requireConfirmForMainnetLike(network.name);

  const addr = process.env.CONTRACT_ADDRESS;
  if (!addr) {
    console.log('❌ Missing CONTRACT_ADDRESS env var');
    console.log('');
    console.log('Usage:');
    console.log('  Single contract:  CONTRACT_ADDRESS=0x... npx hardhat run scripts/verify.ts --network baseSepolia');
    console.log('  All contracts:    npx hardhat run scripts/verify-base-sepolia.ts --network baseSepolia');
    process.exit(1);
  }

  console.log(`Verifying contract at ${addr} on ${network.name}...`);
  
  try {
    await run('verify:verify', {
      address: addr,
      constructorArguments: [],
    });
    console.log(`✅ Verified contract at ${addr} on ${network.name}`);
  } catch (err: any) {
    if (err.message?.includes('Already Verified')) {
      console.log(`ℹ️  Contract at ${addr} is already verified on ${network.name}`);
    } else {
      throw err;
    }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
