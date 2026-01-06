#!/usr/bin/env ts-node

/**
 * Stage Proposal on Testnet/Mainnet
 * 
 * Proposes, queues, and executes a proposal on a live network.
 * Supports different stages: propose, queue, execute.
 * 
 * Usage:
 *   pnpm ts-node scripts/gov/stage.ts governance/proposals/0001_set_token_cap.json --stage propose --network baseSepolia
 *   pnpm ts-node scripts/gov/stage.ts governance/proposals/0001_set_token_cap.json --stage queue --network baseSepolia
 *   pnpm ts-node scripts/gov/stage.ts governance/proposals/0001_set_token_cap.json --stage execute --network baseSepolia
 */

import { HardhatRuntimeEnvironment } from "hardhat/types";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { ProposalArtifact, ProposalCall } from "./types";
import { getDeployedAddress } from "./addresses";

type Stage = "propose" | "queue" | "execute" | "all";

async function loadProposal(proposalPath: string): Promise<ProposalArtifact> {
  const fullPath = path.resolve(proposalPath);
  
  if (!fs.existsSync(fullPath)) {
    throw new Error(`Proposal file not found: ${fullPath}`);
  }
  
  const content = fs.readFileSync(fullPath, "utf-8");
  return JSON.parse(content) as ProposalArtifact;
}

async function saveProposal(proposal: ProposalArtifact): Promise<void> {
  const proposalsDir = path.join(process.cwd(), "governance", "proposals");
  const artifactPath = path.join(proposalsDir, `${proposal.id}.json`);
  fs.writeFileSync(artifactPath, JSON.stringify(proposal, null, 2));
}

async function replacePlaceholders(
  hre: HardhatRuntimeEnvironment,
  calls: ProposalCall[]
): Promise<ProposalCall[]> {
  const resolvedCalls: ProposalCall[] = [];
  
  for (const call of calls) {
    const resolvedCall = { ...call };
    
    if (call.target.startsWith("0xPLACEHOLDER_")) {
      const contractName = call.target.replace("0xPLACEHOLDER_", "");
      resolvedCall.target = await getDeployedAddress(hre, contractName);
    }
    
    // Replace placeholders in args
    if (call.args) {
      resolvedCall.args = await Promise.all(
        call.args.map(async (arg: any) => {
          if (typeof arg === "string" && arg.startsWith("0xPLACEHOLDER_")) {
            const contractName = arg.replace("0xPLACEHOLDER_", "");
            return await getDeployedAddress(hre, contractName);
          }
          return arg;
        })
      );
    }
    
    resolvedCalls.push(resolvedCall);
  }
  
  return resolvedCalls;
}

async function propose(
  hre: HardhatRuntimeEnvironment,
  proposal: ProposalArtifact,
  calls: ProposalCall[]
): Promise<string> {
  const governor = await hre.ethers.getContractAt(
    "GovGovernor",
    await getDeployedAddress(hre, "GovGovernor")
  );
  
  const [deployer] = await hre.ethers.getSigners();
  
  // Prepare proposal data
  const targets = calls.map(c => c.target);
  const values = calls.map(c => BigInt(c.value || "0"));
  const calldatas = await Promise.all(
    calls.map(async (c) => {
      const contract = await hre.ethers.getContractAt(
        c.contractName || "Contract",
        c.target
      );
      return contract.interface.encodeFunctionData(c.functionName, c.args || []);
    })
  );
  
  // Create proposal
  console.log("   📝 Creating proposal...");
  const tx = await governor.propose(targets, values, calldatas, proposal.description);
  const receipt = await tx.wait();
  
  // Extract proposal ID from event
  const proposalId = await governor.hashProposal(targets, values, calldatas, hre.ethers.id(proposal.description));
  
  console.log(`   ✅ Proposal created: ${proposalId.toString()}`);
  console.log(`      TX: ${receipt!.hash}`);
  
  // Update proposal artifact
  proposal.status = {
    ...proposal.status,
    proposalId: proposalId.toString(),
    proposeTx: receipt!.hash,
    state: "pending",
    proposedAt: new Date().toISOString(),
  };
  
  await saveProposal(proposal);
  
  return proposalId.toString();
}

async function queue(
  hre: HardhatRuntimeEnvironment,
  proposal: ProposalArtifact,
  calls: ProposalCall[]
): Promise<void> {
  const governor = await hre.ethers.getContractAt(
    "GovGovernor",
    await getDeployedAddress(hre, "GovGovernor")
  );
  
  if (!proposal.status?.proposalId) {
    throw new Error("Proposal must be proposed first. Run with --stage propose");
  }
  
  const proposalId = BigInt(proposal.status.proposalId);
  
  // Check proposal state
  const state = await governor.state(proposalId);
  console.log(`   📊 Proposal state: ${state}`);
  
  if (state !== 4) { // Succeeded
    throw new Error(`Proposal state is ${state}, expected 4 (Succeeded). Proposal may need voting first.`);
  }
  
  // Prepare queue data
  const targets = calls.map(c => c.target);
  const values = calls.map(c => BigInt(c.value || "0"));
  const calldatas = await Promise.all(
    calls.map(async (c) => {
      const contract = await hre.ethers.getContractAt(
        c.contractName || "Contract",
        c.target
      );
      return contract.interface.encodeFunctionData(c.functionName, c.args || []);
    })
  );
  const descriptionHash = hre.ethers.id(proposal.description);
  
  // Queue proposal
  console.log("   ⏳ Queuing proposal to Timelock...");
  const tx = await governor.queue(targets, values, calldatas, descriptionHash);
  const receipt = await tx.wait();
  
  console.log(`   ✅ Proposal queued`);
  console.log(`      TX: ${receipt!.hash}`);
  
  // Get execution ETA from Timelock
  const timelock = await hre.ethers.getContractAt(
    "TimelockController",
    await getDeployedAddress(hre, "TimelockController")
  );
  const minDelay = await timelock.getMinDelay();
  const eta = BigInt(Math.floor(Date.now() / 1000)) + minDelay;
  
  console.log(`   ⏰ Execution ETA: ${new Date(Number(eta) * 1000).toISOString()}`);
  
  // Update proposal artifact
  proposal.status = {
    ...proposal.status,
    queueTx: receipt!.hash,
    state: "queued",
    queuedAt: new Date().toISOString(),
  };
  
  await saveProposal(proposal);
}

async function execute(
  hre: HardhatRuntimeEnvironment,
  proposal: ProposalArtifact,
  calls: ProposalCall[]
): Promise<void> {
  const governor = await hre.ethers.getContractAt(
    "GovGovernor",
    await getDeployedAddress(hre, "GovGovernor")
  );
  
  if (!proposal.status?.proposalId) {
    throw new Error("Proposal must be proposed and queued first");
  }
  
  const proposalId = BigInt(proposal.status.proposalId);
  
  // Check proposal state
  const state = await governor.state(proposalId);
  console.log(`   📊 Proposal state: ${state}`);
  
  if (state !== 5) { // Queued
    throw new Error(`Proposal state is ${state}, expected 5 (Queued). Proposal may not be ready for execution.`);
  }
  
  // Prepare execute data
  const targets = calls.map(c => c.target);
  const values = calls.map(c => BigInt(c.value || "0"));
  const calldatas = await Promise.all(
    calls.map(async (c) => {
      const contract = await hre.ethers.getContractAt(
        c.contractName || "Contract",
        c.target
      );
      return contract.interface.encodeFunctionData(c.functionName, c.args || []);
    })
  );
  const descriptionHash = hre.ethers.id(proposal.description);
  
  // Execute proposal
  console.log("   ⚡ Executing proposal...");
  const tx = await governor.execute(targets, values, calldatas, descriptionHash);
  const receipt = await tx.wait();
  
  console.log(`   ✅ Proposal executed`);
  console.log(`      TX: ${receipt!.hash}`);
  console.log(`      Gas: ${receipt!.gasUsed.toString()}`);
  
  // Update proposal artifact
  proposal.status = {
    ...proposal.status,
    executeTx: receipt!.hash,
    state: "executed",
    executedAt: new Date().toISOString(),
  };
  
  await saveProposal(proposal);
}

async function main() {
  const proposalPath = process.argv[2];
  const stageArg = process.argv.find(arg => arg.startsWith("--stage="))?.split("=")[1] || "all";
  const stage = stageArg as Stage;
  
  if (!proposalPath) {
    console.error("Usage: pnpm ts-node scripts/gov/stage.ts <proposal-path> [--stage=propose|queue|execute|all] [--network=<network>]");
    process.exit(1);
  }
  
  console.log(`\n🚀 Staging proposal: ${proposalPath}`);
  console.log(`   Network: ${hre.network.name}`);
  console.log(`   Stage: ${stage}`);
  
  // Load proposal
  const proposal = await loadProposal(proposalPath);
  console.log(`\n📋 Proposal: ${proposal.title}`);
  console.log(`   Lane: ${proposal.lane}`);
  
  // Resolve placeholder addresses
  console.log("\n🔧 Resolving addresses...");
  const resolvedCalls = await replacePlaceholders(hre, proposal.calls);
  console.log(`   ✅ Resolved ${resolvedCalls.length} call(s)`);
  
  // Execute stages
  if (stage === "propose" || stage === "all") {
    console.log("\n📝 Stage 1: Propose");
    await propose(hre, proposal, resolvedCalls);
  }
  
  if (stage === "queue" || stage === "all") {
    console.log("\n⏳ Stage 2: Queue");
    await queue(hre, proposal, resolvedCalls);
  }
  
  if (stage === "execute" || stage === "all") {
    console.log("\n⚡ Stage 3: Execute");
    await execute(hre, proposal, resolvedCalls);
  }
  
  console.log("\n✅ Staging complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });




