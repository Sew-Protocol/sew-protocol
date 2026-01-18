/**
 * Verify all deployed contracts on Base Sepolia
 *
 * Usage:
 *   pnpm ts-node scripts/verify-base-sepolia.ts
 *
 * Requirements:
 *   - BASESCAN_API_KEY must be set in .env
 *   - Contracts must be deployed on Base Sepolia
 */

import { run, network } from 'hardhat';

const CONTRACTS = [
  {
    name: 'SewToken',
    address: '0xDb48E8b489179Bf395f74c80f09b40406f5c95A5',
    constructorArgs: [
      'Sew Token',
      'SEW',
      '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC',
      '1000000000000000000000000000',
    ],
  },
  {
    name: 'TimelockController',
    address: '0xCbFD33Aa839F32aA0B953048185bE010090317Bc',
    constructorArgs: [
      172800, // minDelay (48 hours in seconds)
      [], // proposers (empty array)
      ['0x0000000000000000000000000000000000000000'], // executors (address(0))
      '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC', // admin
    ],
  },
  {
    name: 'GovGovernor',
    address: '0x6F08207ac3309D6B90271B8db250b86796F21985',
    constructorArgs: [
      '0xDb48E8b489179Bf395f74c80f09b40406f5c95A5', // token
      '0xCbFD33Aa839F32aA0B953048185bE010090317Bc', // timelock
      1, // votingDelayBlocks
      45818, // votingPeriodBlocks
      '500000000000000000000000', // proposalThresholdTokens (500k tokens)
      4, // quorumNumerator (4%)
    ],
  },
];

async function main() {
  const targetNetwork = 'baseSepolia';
  
  // Override network if not already set
  if (network.name !== targetNetwork) {
    console.log(`⚠️  Network is set to "${network.name}", but we need "${targetNetwork}"`);
    console.log(`   Run with: pnpm hardhat run scripts/verify-base-sepolia.ts --network ${targetNetwork}\n`);
    process.exit(1);
  }
  
  console.log(`\n🔍 Verifying contracts on ${targetNetwork}...\n`);

  // Check if API key is set
  if (!process.env.BASESCAN_API_KEY && !process.env.ETHERSCAN_API_KEY) {
    console.error('❌ Error: BASESCAN_API_KEY or ETHERSCAN_API_KEY must be set in .env');
    console.error('\nTo get a Basescan API key:');
    console.error('1. Go to https://basescan.org/apis');
    console.error('2. Create an account or log in');
    console.error('3. Create a new API key');
    console.error('4. Add to .env: BASESCAN_API_KEY=your_api_key_here\n');
    process.exit(1);
  }

  let successCount = 0;
  let failCount = 0;

  for (const contract of CONTRACTS) {
    console.log(`\n📋 Verifying ${contract.name}...`);
    console.log(`   Address: ${contract.address}`);
    console.log(`   Constructor Args: ${JSON.stringify(contract.constructorArgs, null, 2)}`);

    try {
      await run('verify:verify', {
        address: contract.address,
        constructorArguments: contract.constructorArgs,
      });

      console.log(`   ✅ ${contract.name} verified successfully!`);
      console.log(`   📊 View on Basescan: https://sepolia.basescan.org/address/${contract.address}#code`);
      successCount++;
    } catch (error: any) {
      if (error.message?.includes('Already Verified')) {
        console.log(`   ℹ️  ${contract.name} is already verified`);
        successCount++;
      } else {
        console.error(`   ❌ Failed to verify ${contract.name}:`);
        console.error(`      ${error.message}`);
        failCount++;
      }
    }
  }

  console.log(`\n📊 Verification Summary:`);
  console.log(`   ✅ Successfully verified: ${successCount}`);
  console.log(`   ❌ Failed: ${failCount}`);
  console.log(`   📋 Total: ${CONTRACTS.length}\n`);

  if (failCount > 0) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
