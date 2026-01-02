#!/usr/bin/env ts-node

/**
 * Build Proposal Artifact
 * 
 * Builds a proposal artifact from a payload builder script.
 * 
 * Usage:
 *   pnpm ts-node scripts/gov/build-proposal.ts governance/payloads/0001_set_token_cap.ts
 */

import { HardhatRuntimeEnvironment } from "hardhat/types";
import hre from "hardhat";
import * as fs from "fs";
import * as path from "path";
import { ProposalArtifact, PayloadBuilder } from "./types";
import { validateDeployments } from "./addresses";

async function main() {
  const payloadPath = process.argv[2];
  
  if (!payloadPath) {
    console.error("Usage: pnpm ts-node scripts/gov/build-proposal.ts <payload-path>");
    process.exit(1);
  }
  
  const fullPath = path.resolve(payloadPath);
  
  if (!fs.existsSync(fullPath)) {
    console.error(`Payload file not found: ${fullPath}`);
    process.exit(1);
  }
  
  console.log(`\n📦 Building proposal from: ${payloadPath}`);
  
  // Load payload builder
  // Use relative path from script directory for ts-node compatibility
  const scriptDir = path.dirname(__filename);
  const projectRoot = path.resolve(scriptDir, "../..");
  const relativePath = path.relative(projectRoot, fullPath);
  const importPath = relativePath.replace(/\\/g, "/").replace(/\.ts$/, "");
  
  const payloadModule = await import(`../../${importPath}`);
  const buildPayload: PayloadBuilder = payloadModule.default || payloadModule.buildPayload;
  
  if (!buildPayload || typeof buildPayload !== "function") {
    console.error("Payload file must export a default function or buildPayload function");
    process.exit(1);
  }
  
  // Get proposal metadata from payload
  const metadata = payloadModule.metadata || {};
  const proposalId = metadata.id || path.basename(payloadPath, ".ts");
  const title = metadata.title || proposalId;
  const description = metadata.description || "";
  const lane = metadata.lane || "standard";
  
  // Validate required deployments (skip on local hardhat if not deployed)
  const requiredContracts = metadata.requiredContracts || [];
  if (requiredContracts.length > 0 && hre.network.name !== "hardhat") {
    await validateDeployments(hre, requiredContracts);
  } else if (requiredContracts.length > 0 && hre.network.name === "hardhat") {
    console.log("   ⚠️  Skipping deployment validation on local hardhat network");
  }
  
  // Build proposal calls
  console.log("   Building proposal calls...");
  const calls = await buildPayload(hre, metadata.config);
  
  if (calls.length === 0) {
    console.error("Payload builder returned no calls");
    process.exit(1);
  }
  
  console.log(`   ✅ Generated ${calls.length} call(s)`);
  
  // Create proposal artifact
  const artifact: ProposalArtifact = {
    id: proposalId,
    title,
    description,
    lane,
    calls,
    metadata: {
      author: metadata.author || "unknown",
      created: new Date().toISOString(),
      network: hre.network.name,
      references: metadata.references || [],
    },
  };
  
  // Save artifact
  const proposalsDir = path.join(process.cwd(), "governance", "proposals");
  if (!fs.existsSync(proposalsDir)) {
    fs.mkdirSync(proposalsDir, { recursive: true });
  }
  
  const artifactPath = path.join(proposalsDir, `${proposalId}.json`);
  
  // Custom replacer to handle BigInt serialization
  const replacer = (key: string, value: any) => {
    if (typeof value === "bigint") {
      return value.toString();
    }
    return value;
  };
  
  fs.writeFileSync(artifactPath, JSON.stringify(artifact, replacer, 2));
  
  console.log(`\n✅ Proposal artifact saved to: ${artifactPath}`);
  console.log(`\n📋 Proposal Summary:`);
  console.log(`   ID: ${proposalId}`);
  console.log(`   Title: ${title}`);
  console.log(`   Lane: ${lane}`);
  console.log(`   Calls: ${calls.length}`);
  console.log(`   Network: ${hre.network.name}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

