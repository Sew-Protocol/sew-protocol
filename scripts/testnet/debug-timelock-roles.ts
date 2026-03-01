/**
 * Debug: Check TimelockController roles
 */

import hre from 'hardhat';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const timelockAddr = registry.contracts.TimelockController.address;
  const timelock = await hre.ethers.getContractAt('TimelockController', timelockAddr);

  const deployerAddr = await deployer.getAddress();

  console.log('Deployer:', deployerAddr);
  console.log('Timelock:', timelockAddr);

  // Get role hashes
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();
  const DEFAULT_ADMIN_ROLE = await timelock.DEFAULT_ADMIN_ROLE();

  console.log('\n=== Roles ===');
  console.log('PROPOSER_ROLE:', PROPOSER_ROLE);
  console.log('EXECUTOR_ROLE:', EXECUTOR_ROLE);
  console.log('DEFAULT_ADMIN_ROLE:', DEFAULT_ADMIN_ROLE);

  console.log('\n=== Role Checks ===');
  console.log('Deployer is PROPOSER?', await timelock.hasRole(PROPOSER_ROLE, deployerAddr));
  console.log('Deployer is EXECUTOR?', await timelock.hasRole(EXECUTOR_ROLE, deployerAddr));
  console.log('Deployer is ADMIN?', await timelock.hasRole(DEFAULT_ADMIN_ROLE, deployerAddr));

  // Check proposers
  const proposerCount = await timelock.getRoleMemberCount(PROPOSER_ROLE);
  console.log('\nProposers:', proposerCount.toString());
  for (let i = 0; i < Math.min(Number(proposerCount), 5); i++) {
    const member = await timelock.getRoleMember(PROPOSER_ROLE, i);
    console.log(`  Proposer ${i}:`, member);
  }
}

main().catch(console.error);
