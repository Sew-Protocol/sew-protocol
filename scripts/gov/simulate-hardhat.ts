#!/usr/bin/env ts-node

/**
 * Simulate Proposal on Hardhat Fork
 * 
 * Forks a network (mainnet/testnet) and simulates executing a proposal.
 * Useful for testing proposals before submitting them on-chain.
 * 
 * Usage:
 *   pnpm ts-node scripts/gov/simulate-hardhat.ts governance/proposals/0001_set_token_cap.json --fork-url <RPC_URL>
 */

import { HardhatRuntimeEnvironment } from "hardhat/types";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { ProposalArtifact, ProposalCall, ExecutionResult } from "./types";
import { getDeployedAddress } from "./addresses";

interface SimulationConfig {
  forkUrl?: string;
  forkBlockNumber?: number;
  impersonateTimelock?: boolean;
  runChecks?: boolean;
}

async function loadProposal(proposalPath: string): Promise<ProposalArtifact> {
  const fullPath = path.resolve(proposalPath);
  
  if (!fs.existsSync(fullPath)) {
    throw new Error(`Proposal file not found: ${fullPath}`);
  }
  
  const content = fs.readFileSync(fullPath, "utf-8");
  return JSON.parse(content) as ProposalArtifact;
}

async function replacePlaceholders(
  hre: HardhatRuntimeEnvironment,
  calls: ProposalCall[]
): Promise<ProposalCall[]> {
  const resolvedCalls: ProposalCall[] = [];
  
  for (const call of calls) {
    const resolvedCall = { ...call };
    
    // Replace placeholder addresses
    if (call.target.startsWith("0xPLACEHOLDER_")) {
      const contractName = call.target.replace("0xPLACEHOLDER_", "");
      try {
        resolvedCall.target = await getDeployedAddress(hre, contractName);
        console.log(`   ✅ Resolved ${contractName} → ${resolvedCall.target}`);
      } catch (error) {
        throw new Error(
          `Cannot resolve placeholder ${call.target}. ` +
          `Contract ${contractName} not found in deployments. ` +
          `Either deploy the contract or update the proposal with actual addresses.`
        );
      }
    }
    
    // Replace placeholder addresses in args
    if (call.args) {
      resolvedCall.args = call.args.map((arg: any) => {
        if (typeof arg === "string" && arg.startsWith("0xPLACEHOLDER_")) {
          const contractName = arg.replace("0xPLACEHOLDER_", "");
          // We'll need to resolve this synchronously or handle it differently
          // For now, warn and keep placeholder
          console.warn(`   ⚠️  Placeholder in args: ${arg} (will need manual resolution)`);
          return arg;
        }
        return arg;
      });
    }
    
    resolvedCalls.push(resolvedCall);
  }
  
  return resolvedCalls;
}

async function executeCall(
  hre: HardhatRuntimeEnvironment,
  call: ProposalCall,
  executor: string
): Promise<ExecutionResult> {
  const contract = await hre.ethers.getContractAt(
    call.contractName || "Contract",
    call.target
  );
  
  const signer = await hre.ethers.getSigner(executor);
  const connectedContract = contract.connect(signer);
  
  try {
    // Impersonate executor if needed
    if (executor !== (await signer.getAddress())) {
      await hre.network.provider.send("hardhat_impersonateAccount", [executor]);
      await hre.network.provider.send("hardhat_setBalance", [
        executor,
        "0x1000000000000000000", // 1 ETH
      ]);
    }
    
    const executorSigner = await hre.ethers.getSigner(executor);
    const executorContract = contract.connect(executorSigner);
    
    // Execute the call
    const tx = await executorContract[call.functionName](
      ...call.args,
      { value: call.value || 0 }
    );
    
    const receipt = await tx.wait();
    
    return {
      success: true,
      txHash: receipt!.hash,
      gasUsed: receipt!.gasUsed,
      blockNumber: receipt!.blockNumber,
    };
  } catch (error: any) {
    return {
      success: false,
      error: error.message || String(error),
    };
  }
}

async function runPostChecks(
  hre: HardhatRuntimeEnvironment,
  calls: ProposalCall[]
): Promise<void> {
  console.log("\n🔍 Running post-execution checks...");
  
  for (const call of calls) {
    console.log(`\n   Checking: ${call.contractName}.${call.functionName}()`);
    
    try {
      const contract = await hre.ethers.getContractAt(
        call.contractName || "Contract",
        call.target
      );
      
      // Basic checks - verify contract is still callable
      // More specific checks can be added per proposal type
      const code = await hre.ethers.provider.getCode(call.target);
      if (code === "0x") {
        console.error(`   ❌ Contract ${call.target} has no code (may have been self-destructed)`);
      } else {
        console.log(`   ✅ Contract ${call.target} has code`);
      }
    } catch (error: any) {
      console.warn(`   ⚠️  Could not verify: ${error.message}`);
    }
  }
}

async function main() {
  const proposalPath = process.argv[2];
  const forkUrl = process.argv.find(arg => arg.startsWith("--fork-url="))?.split("=")[1];
  const forkBlock = process.argv.find(arg => arg.startsWith("--fork-block="))?.split("=")[1];
  const skipChecks = process.argv.includes("--skip-checks");
  
  if (!proposalPath) {
    console.error("Usage: pnpm ts-node scripts/gov/simulate-hardhat.ts <proposal-path> [--fork-url=<RPC_URL>] [--fork-block=<BLOCK>] [--skip-checks]");
    process.exit(1);
  }
  
  console.log(`\n🔬 Simulating proposal: ${proposalPath}`);
  
  // Load proposal
  const proposal = await loadProposal(proposalPath);
  console.log(`\n📋 Proposal: ${proposal.title}`);
  console.log(`   Lane: ${proposal.lane}`);
  console.log(`   Calls: ${proposal.calls.length}`);
  
  // Setup fork if URL provided
  if (forkUrl) {
    console.log(`\n🌐 Forking network from: ${forkUrl}`);
    if (forkBlock) {
      console.log(`   Block: ${forkBlock}`);
    }
    
    // Note: Hardhat forking is configured via hardhat.config.ts
    // This script assumes the network is already configured for forking
    console.log("   ⚠️  Ensure hardhat.config.ts has fork configuration for this network");
  }
  
  // Resolve placeholder addresses
  console.log("\n🔧 Resolving addresses...");
  const resolvedCalls = await replacePlaceholders(hre, proposal.calls);
  
  // Determine executor based on lane
  let executor: string;
  if (proposal.lane === "emergency") {
    // Emergency lane uses Guardian
    executor = process.env.GUARDIAN_ADDRESS || "0x0000000000000000000000000000000000000000";
    if (executor === "0x0000000000000000000000000000000000000000") {
      throw new Error("GUARDIAN_ADDRESS must be set for emergency lane proposals");
    }
  } else {
    // Standard and Slow lanes use Timelock
    try {
      executor = await getDeployedAddress(hre, "TimelockController", true);
      if (executor.startsWith("0xPLACEHOLDER_")) {
        executor = process.env.TIMELOCK_ADDRESS || executor;
        console.warn(`   ⚠️  Using placeholder Timelock: ${executor}`);
      }
    } catch (error) {
      executor = process.env.TIMELOCK_ADDRESS || "0x0000000000000000000000000000000000000000";
      if (executor === "0x0000000000000000000000000000000000000000") {
        throw new Error("TIMELOCK_ADDRESS must be set or TimelockController must be deployed");
      }
    }
  }
  
  console.log(`\n👤 Executor: ${executor}`);
  
  // Execute calls
  console.log("\n⚡ Executing proposal calls...");
  const results: ExecutionResult[] = [];
  
  for (let i = 0; i < resolvedCalls.length; i++) {
    const call = resolvedCalls[i];
    console.log(`\n   [${i + 1}/${resolvedCalls.length}] ${call.contractName}.${call.functionName}()`);
    if (call.description) {
      console.log(`      ${call.description}`);
    }
    
    const result = await executeCall(hre, call, executor);
    results.push(result);
    
    if (result.success) {
      console.log(`      ✅ Success: ${result.txHash}`);
      console.log(`         Gas: ${result.gasUsed?.toString()}`);
      console.log(`         Block: ${result.blockNumber}`);
    } else {
      console.error(`      ❌ Failed: ${result.error}`);
    }
  }
  
  // Run post-checks
  if (!skipChecks) {
    await runPostChecks(hre, resolvedCalls);
  }
  
  // Summary
  console.log("\n📊 Simulation Summary:");
  const successCount = results.filter(r => r.success).length;
  const failCount = results.filter(r => !r.success).length;
  console.log(`   ✅ Successful: ${successCount}`);
  console.log(`   ❌ Failed: ${failCount}`);
  
  if (failCount > 0) {
    console.log("\n⚠️  Some calls failed. Review errors above.");
    process.exit(1);
  } else {
    console.log("\n✅ All calls executed successfully!");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });


