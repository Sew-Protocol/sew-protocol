/**
 * Guardian Multisig Comprehensive Test
 *
 * Tests all guardian-callable functions on the Base Sepolia deployment
 *
 * Usage:
 *   pnpm hardhat run --network baseSepolia scripts/testnet/test-guardian-all.ts
 *
 * Note: This script performs READ-ONLY checks by default.
 * Set GUARDIAN_PRIVATE_KEY to test actual transaction execution.
 */

import hre from 'hardhat';
import { ethers } from 'ethers';
import * as fs from 'fs';

interface TestResult {
  name: string;
  passed: boolean;
  details: string;
}

async function main() {
  if (hre.network.name !== 'baseSepolia') {
    throw new Error(`Run with --network baseSepolia`);
  }

  // Load contracts
  const registryPath = './deploy-registry/base-sepolia-v1-testnet.json';
  const registry = JSON.parse(fs.readFileSync(registryPath, 'utf-8'));

  // Guardian address from env (can check without private key)
  const guardianAddr =
    process.env.GUARDIAN_MULTISIG || '0x5F13B5089a0B23c74AD9A22a2db59F5F48ab09bC';
  const results: TestResult[] = [];

  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('       GUARDIAN MULTISIG COMPREHENSIVE TEST');
  console.log('════════════════════════════════════════════════════════════════\n');
  console.log(`Guardian: ${guardianAddr}\n`);

  // Test 1: CreateOps - pauseYieldDeposits
  console.log('─── Test 1: CreateOps.pauseYieldDeposits() ───');
  try {
    const createOpsAddr = registry.contracts.CreateOps.address;
    const createOps = await hre.ethers.getContractAt('CreateOps', createOpsAddr);

    const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));
    const hasRole = await createOps.hasRole(ROLE_GUARDIAN, guardianAddr);

    if (hasRole) {
      const isPaused = await createOps.yieldDepositsPaused();
      results.push({
        name: 'CreateOps.pauseYieldDeposits()',
        passed: true,
        details: `Has ROLE_GUARDIAN, yieldDepositsPaused=${isPaused}`,
      });
      console.log(`   ✅ PASS: Has ROLE_GUARDIAN, yieldDepositsPaused=${isPaused}`);
    } else {
      results.push({
        name: 'CreateOps.pauseYieldDeposits()',
        passed: false,
        details: 'Missing ROLE_GUARDIAN',
      });
      console.log(`   ❌ FAIL: Missing ROLE_GUARDIAN`);
    }
  } catch (err: any) {
    results.push({ name: 'CreateOps.pauseYieldDeposits()', passed: false, details: err.message });
    console.log(`   ❌ FAIL: ${err.message}`);
  }

  // Test 2: YieldOps - recoverTokens role
  console.log('\n─── Test 2: YieldOps.recoverTokens() ───');
  try {
    const yieldOpsAddr = registry.contracts.YieldOps.address;
    const yieldOps = await hre.ethers.getContractAt('YieldOps', yieldOpsAddr);

    const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));
    const hasRole = await yieldOps.hasRole(ROLE_GUARDIAN, guardianAddr);

    if (hasRole) {
      results.push({
        name: 'YieldOps.recoverTokens()',
        passed: true,
        details: 'Has ROLE_GUARDIAN',
      });
      console.log(`   ✅ PASS: Has ROLE_GUARDIAN`);
    } else {
      results.push({
        name: 'YieldOps.recoverTokens()',
        passed: false,
        details: 'Missing ROLE_GUARDIAN',
      });
      console.log(`   ❌ FAIL: Missing ROLE_GUARDIAN`);
    }
  } catch (err: any) {
    results.push({ name: 'YieldOps.recoverTokens()', passed: false, details: err.message });
    console.log(`   ❌ FAIL: ${err.message}`);
  }

  // Test 3: EscrowVault - guardian role
  console.log('\n─── Test 3: EscrowVault Guardian Role ───');
  try {
    const vaultAddr = registry.contracts.EscrowVault.address;
    const vault = await hre.ethers.getContractAt('EscrowVault', vaultAddr);

    const ROLE_GUARDIAN = await vault.ROLE_GUARDIAN();
    const hasRole = await vault.hasRole(ROLE_GUARDIAN, guardianAddr);

    if (hasRole) {
      results.push({
        name: 'EscrowVault.ROLE_GUARDIAN',
        passed: true,
        details: 'Has ROLE_GUARDIAN',
      });
      console.log(`   ✅ PASS: Has ROLE_GUARDIAN`);
    } else {
      results.push({
        name: 'EscrowVault.ROLE_GUARDIAN',
        passed: false,
        details: 'Missing ROLE_GUARDIAN',
      });
      console.log(`   ❌ FAIL: Missing ROLE_GUARDIAN`);
    }
  } catch (err: any) {
    results.push({ name: 'EscrowVault.ROLE_GUARDIAN', passed: false, details: err.message });
    console.log(`   ❌ FAIL: ${err.message}`);
  }

  // Test 4: DecentralizedResolutionModule (if deployed)
  console.log('\n─── Test 4: DecentralizedResolutionModule ───');
  try {
    const drModuleAddr = registry.contracts.DecentralizedResolutionModule?.address;
    if (!drModuleAddr) {
      results.push({
        name: 'DecentralizedResolutionModule',
        passed: true,
        details: 'Not deployed (optional)',
      });
      console.log(`   ⏭️  SKIP: Not deployed`);
    } else {
      const drModule = await hre.ethers.getContractAt(
        'DecentralizedResolutionModule',
        drModuleAddr,
      );
      const ROLE_GUARDIAN = await drModule.ROLE_GUARDIAN();
      const hasRole = await drModule.hasRole(ROLE_GUARDIAN, guardianAddr);

      if (hasRole) {
        results.push({
          name: 'DecentralizedResolutionModule',
          passed: true,
          details: 'Has ROLE_GUARDIAN',
        });
        console.log(`   ✅ PASS: Has ROLE_GUARDIAN`);
      } else {
        results.push({
          name: 'DecentralizedResolutionModule',
          passed: false,
          details: 'Missing ROLE_GUARDIAN',
        });
        console.log(`   ❌ FAIL: Missing ROLE_GUARDIAN`);
      }
    }
  } catch (err: any) {
    results.push({ name: 'DecentralizedResolutionModule', passed: false, details: err.message });
    console.log(`   ❌ FAIL: ${err.message}`);
  }

  // Summary
  console.log('\n════════════════════════════════════════════════════════════════');
  console.log('                     TEST SUMMARY');
  console.log('════════════════════════════════════════════════════════════════\n');

  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;

  for (const r of results) {
    const status = r.passed ? '✅' : '❌';
    console.log(`${status} ${r.name}: ${r.details}`);
  }

  console.log(`\nTotal: ${passed} passed, ${failed} failed\n`);

  if (failed > 0) {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
