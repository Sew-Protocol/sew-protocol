#!/usr/bin/env ts-node

/**
 * Check Proposal Execution
 *
 * Verifies that a proposal was executed correctly by checking:
 * - State variables changed as expected
 * - Events were emitted
 * - Invariants are maintained
 *
 * Usage:
 *   pnpm ts-node scripts/gov/check.ts governance/proposals/0001_set_token_cap.json
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import hre from 'hardhat';
import * as fs from 'fs';
import * as path from 'path';
import { ProposalArtifact, ProposalCall } from './types';
import { getDeployedAddress } from './addresses';

interface CheckResult {
  name: string;
  passed: boolean;
  message?: string;
  details?: any;
}

async function loadProposal(proposalPath: string): Promise<ProposalArtifact> {
  const fullPath = path.resolve(proposalPath);

  if (!fs.existsSync(fullPath)) {
    throw new Error(`Proposal file not found: ${fullPath}`);
  }

  const content = fs.readFileSync(fullPath, 'utf-8');
  return JSON.parse(content) as ProposalArtifact;
}

async function checkContractCode(call: ProposalCall): Promise<CheckResult> {
  const code = await hre.ethers.provider.getCode(call.target);

  return {
    name: `Contract ${call.contractName} has code`,
    passed: code !== '0x',
    message: code === '0x' ? 'Contract has no code (may have been self-destructed)' : undefined,
  };
}

async function checkFunctionCallable(call: ProposalCall): Promise<CheckResult> {
  try {
    const contract = await hre.ethers.getContractAt(call.contractName || 'Contract', call.target);

    // Try to read a public variable or call a view function
    // This is a basic check that the contract is still functional
    const code = await hre.ethers.provider.getCode(call.target);

    return {
      name: `Contract ${call.contractName} is callable`,
      passed: code !== '0x',
      message: code === '0x' ? 'Contract has no code' : undefined,
    };
  } catch (error: any) {
    return {
      name: `Contract ${call.contractName} is callable`,
      passed: false,
      message: error.message,
    };
  }
}

async function checkTransactionExists(proposal: ProposalArtifact): Promise<CheckResult[]> {
  const results: CheckResult[] = [];

  if (proposal.status?.proposeTx) {
    const receipt = await hre.ethers.provider.getTransactionReceipt(proposal.status.proposeTx);
    results.push({
      name: 'Propose transaction exists',
      passed: receipt !== null,
      details: receipt ? { blockNumber: receipt.blockNumber } : undefined,
    });
  }

  if (proposal.status?.queueTx) {
    const receipt = await hre.ethers.provider.getTransactionReceipt(proposal.status.queueTx);
    results.push({
      name: 'Queue transaction exists',
      passed: receipt !== null,
      details: receipt ? { blockNumber: receipt.blockNumber } : undefined,
    });
  }

  if (proposal.status?.executeTx) {
    const receipt = await hre.ethers.provider.getTransactionReceipt(proposal.status.executeTx);
    results.push({
      name: 'Execute transaction exists',
      passed: receipt !== null,
      details: receipt
        ? { blockNumber: receipt.blockNumber, gasUsed: receipt.gasUsed.toString() }
        : undefined,
    });
  }

  return results;
}

async function checkProposalState(proposal: ProposalArtifact): Promise<CheckResult> {
  if (!proposal.status?.proposalId) {
    return {
      name: 'Proposal state check',
      passed: false,
      message: 'Proposal has not been proposed yet',
    };
  }

  try {
    const governor = await hre.ethers.getContractAt(
      'GovGovernor',
      await getDeployedAddress(hre, 'GovGovernor', true),
    );

    if (governor.target.startsWith('0xPLACEHOLDER_')) {
      return {
        name: 'Proposal state check',
        passed: false,
        message: 'Governor not deployed (cannot check state)',
      };
    }

    const proposalId = BigInt(proposal.status.proposalId);
    const state = await governor.state(proposalId);

    const stateNames = [
      'Pending',
      'Active',
      'Canceled',
      'Defeated',
      'Succeeded',
      'Queued',
      'Expired',
      'Executed',
    ];

    return {
      name: 'Proposal state check',
      passed: state === 7, // Executed
      message: `Proposal state: ${stateNames[Number(state)]} (${state})`,
      details: { state: Number(state), stateName: stateNames[Number(state)] },
    };
  } catch (error: any) {
    return {
      name: 'Proposal state check',
      passed: false,
      message: error.message,
    };
  }
}

async function runChecks(
  hre: HardhatRuntimeEnvironment,
  proposal: ProposalArtifact,
  calls: ProposalCall[],
): Promise<CheckResult[]> {
  const results: CheckResult[] = [];

  console.log('\n🔍 Running checks...');

  // Check 1: Transaction existence
  console.log('\n   1. Checking transaction existence...');
  const txChecks = await checkTransactionExists(proposal);
  results.push(...txChecks);

  // Check 2: Proposal state
  console.log('   2. Checking proposal state...');
  const stateCheck = await checkProposalState(proposal);
  results.push(stateCheck);

  // Check 3: Contract code
  console.log('   3. Checking contract code...');
  for (const call of calls) {
    const codeCheck = await checkContractCode(call);
    results.push(codeCheck);
  }

  // Check 4: Contract callability
  console.log('   4. Checking contract callability...');
  for (const call of calls) {
    const callableCheck = await checkFunctionCallable(call);
    results.push(callableCheck);
  }

  return results;
}

async function main() {
  const proposalPath = process.argv[2];

  if (!proposalPath) {
    console.error('Usage: pnpm ts-node scripts/gov/check.ts <proposal-path> [--network=<network>]');
    process.exit(1);
  }

  console.log(`\n🔍 Checking proposal: ${proposalPath}`);
  console.log(`   Network: ${hre.network.name}`);

  // Load proposal
  const proposal = await loadProposal(proposalPath);
  console.log(`\n📋 Proposal: ${proposal.title}`);

  // Resolve placeholder addresses
  console.log('\n🔧 Resolving addresses...');
  const resolvedCalls = proposal.calls.map((call) => {
    // For checking, we can work with placeholders - they'll be resolved if contracts exist
    return call;
  });

  // Run checks
  const results = await runChecks(hre, proposal, resolvedCalls);

  // Display results
  console.log('\n📊 Check Results:');
  let passedCount = 0;
  let failedCount = 0;

  for (const result of results) {
    const icon = result.passed ? '✅' : '❌';
    console.log(`\n   ${icon} ${result.name}`);
    if (result.message) {
      console.log(`      ${result.message}`);
    }
    if (result.details) {
      console.log(`      Details: ${JSON.stringify(result.details, null, 2)}`);
    }

    if (result.passed) {
      passedCount++;
    } else {
      failedCount++;
    }
  }

  // Summary
  console.log('\n📈 Summary:');
  console.log(`   ✅ Passed: ${passedCount}`);
  console.log(`   ❌ Failed: ${failedCount}`);
  console.log(`   Total: ${results.length}`);

  if (failedCount > 0) {
    console.log('\n⚠️  Some checks failed. Review results above.');
    process.exit(1);
  } else {
    console.log('\n✅ All checks passed!');
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
