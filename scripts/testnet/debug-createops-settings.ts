/**
 * Debug: Check EscrowCreationPolicy registration and role
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') throw new Error('Run with baseSepolia');

  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const escrowVaultAddr = registry.contracts.EscrowVault.address;
  const creationPolicyAddr = registry.contracts.EscrowCreationPolicy.address;

  const escrowVault = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const creationPolicy = await hre.ethers.getContractAt('EscrowCreationPolicy', creationPolicyAddr);

  // Check EscrowCreationPolicy has escrow registered
  console.log('=== EscrowCreationPolicy State ===');

  const ROLE_ESCROW_CONTRACT = await creationPolicy.ROLE_ESCROW_CONTRACT();
  console.log('ROLE_ESCROW_CONTRACT:', ROLE_ESCROW_CONTRACT);
  console.log(
    'EscrowVault has role?',
    await creationPolicy.hasRole(ROLE_ESCROW_CONTRACT, escrowVaultAddr),
  );

  // Check yieldDepositsPaused
  console.log('yieldDepositsPaused?', await creationPolicy.yieldDepositsPaused());

  // Try a dry-run call to computeEscrowCreation
  console.log('\n=== Test computeEscrowCreation ===');

  const settings = {
    customResolver: ethers.ZeroAddress,
    releaseAddress: ethers.ZeroAddress,
    yieldPreset: 0,
    autoReleaseTime: 0n,
    autoCancelTime: 0n,
  };

  try {
    const result = await creationPolicy.computeEscrowCreation.staticCall(
      registry.contracts.SewToken.address, // token
      '0x936bC18f88f43c49d2291010Fc2E566Fd9afD8e5', // to
      '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC', // from
      ethers.parseEther('100'), // amount
      settings,
      100, // escrowFee (1%)
      0, // workflowId
      registry.contracts.ModuleSnapshotRegistry.address, // resolutionModule
    );
    console.log('✅ computeEscrowCreation succeeded');
    console.log('Result:', {
      fee: result.fee,
      amountAfterFee: result.amountAfterFee,
      resolver: result.resolver,
      yieldEnabled: result.yieldEnabled,
      shouldDepositYield: result.shouldDepositYield,
    });
  } catch (err: any) {
    console.log('❌ computeEscrowCreation failed:', err.message);
  }
}

main().catch(console.error);
