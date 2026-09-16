/**
 * Register EscrowVault on EscrowCreationPolicy via Timelock
 *
 * Since EscrowCreationPolicy admin is Timelock, we need to execute via governance
 * For testnet, we can try calling directly if deployer has any access
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const [deployer] = await hre.ethers.getSigners();
  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const escrowVaultAddr = registry.contracts.EscrowVault.address;
  const creationPolicyAddr = registry.contracts.EscrowCreationPolicy.address;
  const timelockAddr = registry.contracts.TimelockController.address;

  const creationPolicy = await hre.ethers.getContractAt('EscrowCreationPolicy', creationPolicyAddr);

  console.log('\n=== Register EscrowVault on EscrowCreationPolicy ===');
  console.log('EscrowVault:', escrowVaultAddr);
  console.log('EscrowCreationPolicy:', creationPolicyAddr);
  console.log('Timelock:', timelockAddr);
  console.log('Deployer:', await deployer.getAddress());

  // Check if already registered
  const ROLE_ESCROW_CONTRACT = await creationPolicy.ROLE_ESCROW_CONTRACT();
  const alreadyRegistered = await creationPolicy.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr);
  console.log('Already registered?', alreadyRegistered);

  if (alreadyRegistered) {
    console.log('✅ EscrowVault already registered');
    return;
  }

  // Try calling via timelock (doesn't work - need proposer role)
  console.log('\n⚠️  Cannot register - requires Timelock execution');
  console.log('Options:');
  console.log('1. Execute Timelock proposal to call registerEscrowContract()');
  console.log('2. Deploy new instance with proper registration');
  console.log('3. For testnet: bypass via deployment script fix');
}

main().catch(console.error);
