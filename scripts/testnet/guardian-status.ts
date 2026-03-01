/**
 * Guardian Role Status Report
 *
 * Shows current status of guardian role across all contracts
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/guardian-status.ts
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia`);
  }

  const registry = JSON.parse(
    fs.readFileSync('./deploy-registry/base-sepolia-v1-testnet.json', 'utf-8'),
  );

  const guardianAddr =
    process.env.GUARDIAN_MULTISIG || '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC';
  const timelockAddr = registry.contracts.TimelockController.address;
  const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('           GUARDIAN ROLE STATUS REPORT');
  console.log('════════════════════════════════════════════════════════════════\n');
  console.log(`Guardian:  ${guardianAddr}`);
  console.log(`Timelock:  ${timelockAddr}\n`);

  const contracts = [
    { name: 'EscrowVault', address: registry.contracts.EscrowVault.address, needsTimelock: false },
    { name: 'CreateOps', address: registry.contracts.CreateOps.address, needsTimelock: true },
    { name: 'YieldOps', address: registry.contracts.YieldOps.address, needsTimelock: true },
    {
      name: 'SettlementOps',
      address: registry.contracts.SettlementOps.address,
      needsTimelock: false,
    },
    { name: 'DisputeOps', address: registry.contracts.DisputeOps.address, needsTimelock: false },
  ];

  let hasGuardian = 0;
  let needsTimelock = 0;

  for (const c of contracts) {
    try {
      const contract = await hre.ethers.getContractAt(c.name, c.address);

      let hasRole = false;
      let hasGuardianSupport = false;

      try {
        await contract.ROLE_GUARDIAN();
        hasGuardianSupport = true;
        hasRole = await contract.hasRole(ROLE_GUARDIAN, guardianAddr);
      } catch {
        // No guardian role support
      }

      const status = hasRole ? '✅ HAS ROLE' : hasGuardianSupport ? '❌ MISSING' : '⏭️  N/A';
      const note = hasRole ? '' : c.needsTimelock ? ' (needs Timelock)' : '';

      console.log(
        `${status} ${c.name}: ${hasRole ? 'Guardian can use emergency functions' : 'Guardian cannot act'}${note}`,
      );

      if (hasRole) hasGuardian++;
      if (c.needsTimelock && !hasRole) needsTimelock++;
    } catch (err: any) {
      console.log(`❌ ${c.name}: Error - ${err.message}`);
    }
  }

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('                     SUMMARY');
  console.log('════════════════════════════════════════════════════════════════\n');

  if (needsTimelock > 0) {
    console.log(`⚠️  ${needsTimelock} contract(s) need Timelock to grant guardian role`);
    console.log('\nTo fix, either:');
    console.log('1. Execute a Timelock proposal to grant ROLE_GUARDIAN');
    console.log('2. For testnet only: deployer renounces admin, grants role, reclaims admin');
    console.log('\nExample Timelock call:');
    console.log(`   grantRole(${ROLE_GUARDIAN}, ${guardianAddr})`);
    console.log(`   on: CreateOps, YieldOps\n`);
  } else {
    console.log('✅ Guardian role fully configured!\n');
  }
}

main().catch(console.error);
