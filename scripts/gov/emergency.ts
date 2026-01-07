#!/usr/bin/env ts-node

/**
 * Emergency Actions
 * 
 * Guardian emergency actions (down-only controls):
 * - pause: Pause the protocol
 * - disable-aave: Disable Aave yield generation
 * - lower-cap: Lower a token cap or global cap
 * 
 * Usage:
 *   pnpm ts-node scripts/gov/emergency.ts pause --contract EscrowableERC20 --network baseMainnet
 *   pnpm ts-node scripts/gov/emergency.ts disable-aave --network baseMainnet
 *   pnpm ts-node scripts/gov/emergency.ts lower-cap --token 0x... --new-cap 5000000 --network baseMainnet
 */

import { HardhatRuntimeEnvironment } from "hardhat/types";
import hre from "hardhat";
import { getDeployedAddress } from "./addresses";

type EmergencyAction = "pause" | "disable-aave" | "lower-cap" | "lower-global-cap";

async function pauseProtocol(contractName: string): Promise<void> {
  const contractAddress = await getDeployedAddress(hre, contractName);
  const contract = await hre.ethers.getContractAt(contractName, contractAddress);
  
  const [guardian] = await hre.ethers.getSigners();
  const guardianAddress = process.env.GUARDIAN_ADDRESS || guardian.address;
  
  console.log(`\n⏸️  Pausing ${contractName}...`);
  console.log(`   Contract: ${contractAddress}`);
  console.log(`   Guardian: ${guardianAddress}`);
  
  // Verify guardian has ROLE_GUARDIAN
  const ROLE_GUARDIAN = await contract.ROLE_GUARDIAN();
  const hasRole = await contract.hasRole(ROLE_GUARDIAN, guardianAddress);
  
  if (!hasRole) {
    throw new Error(`Guardian ${guardianAddress} does not have ROLE_GUARDIAN`);
  }
  
  const guardianSigner = await hre.ethers.getSigner(guardianAddress);
  const connectedContract = contract.connect(guardianSigner);
  
  const tx = await connectedContract.pause();
  console.log(`   TX: ${tx.hash}`);
  
  const receipt = await tx.wait();
  console.log(`   ✅ Protocol paused`);
  console.log(`      Block: ${receipt!.blockNumber}`);
  console.log(`      Gas: ${receipt!.gasUsed.toString()}`);
}

async function disableAave(): Promise<void> {
  const aaveModule = await getDeployedAddress(hre, "AaveYieldGenerationModule");
  const contract = await hre.ethers.getContractAt("AaveYieldGenerationModule", aaveModule);
  
  const [guardian] = await hre.ethers.getSigners();
  const guardianAddress = process.env.GUARDIAN_ADDRESS || guardian.address;
  
  console.log(`\n🚫 Disabling Aave yield generation...`);
  console.log(`   Module: ${aaveModule}`);
  console.log(`   Guardian: ${guardianAddress}`);
  
  // Verify guardian has ROLE_GUARDIAN
  const ROLE_GUARDIAN = await contract.ROLE_GUARDIAN();
  const hasRole = await contract.hasRole(ROLE_GUARDIAN, guardianAddress);
  
  if (!hasRole) {
    throw new Error(`Guardian ${guardianAddress} does not have ROLE_GUARDIAN`);
  }
  
  const guardianSigner = await hre.ethers.getSigner(guardianAddress);
  const connectedContract = contract.connect(guardianSigner);
  
  const tx = await connectedContract.guardianDisableAave();
  console.log(`   TX: ${tx.hash}`);
  
  const receipt = await tx.wait();
  console.log(`   ✅ Aave disabled`);
  console.log(`      Block: ${receipt!.blockNumber}`);
  console.log(`      Gas: ${receipt!.gasUsed.toString()}`);
}

async function lowerTokenCap(tokenAddress: string, newCap: string): Promise<void> {
  const aaveModule = await getDeployedAddress(hre, "AaveYieldGenerationModule");
  const contract = await hre.ethers.getContractAt("AaveYieldGenerationModule", aaveModule);
  
  const [guardian] = await hre.ethers.getSigners();
  const guardianAddress = process.env.GUARDIAN_ADDRESS || guardian.address;
  
  // Get current cap
  const currentCap = await contract.tokenCap(tokenAddress);
  
  console.log(`\n📉 Lowering token cap...`);
  console.log(`   Token: ${tokenAddress}`);
  console.log(`   Current cap: ${currentCap.toString()}`);
  console.log(`   New cap: ${newCap}`);
  console.log(`   Guardian: ${guardianAddress}`);
  
  // Verify new cap is lower
  const newCapBigInt = BigInt(newCap);
  if (newCapBigInt > currentCap) {
    throw new Error(`New cap (${newCap}) must be <= current cap (${currentCap.toString()})`);
  }
  
  // Verify guardian has ROLE_GUARDIAN
  const ROLE_GUARDIAN = await contract.ROLE_GUARDIAN();
  const hasRole = await contract.hasRole(ROLE_GUARDIAN, guardianAddress);
  
  if (!hasRole) {
    throw new Error(`Guardian ${guardianAddress} does not have ROLE_GUARDIAN`);
  }
  
  const guardianSigner = await hre.ethers.getSigner(guardianAddress);
  const connectedContract = contract.connect(guardianSigner);
  
  const tx = await connectedContract.guardianLowerTokenCap(tokenAddress, newCapBigInt);
  console.log(`   TX: ${tx.hash}`);
  
  const receipt = await tx.wait();
  console.log(`   ✅ Token cap lowered`);
  console.log(`      Block: ${receipt!.blockNumber}`);
  console.log(`      Gas: ${receipt!.gasUsed.toString()}`);
}

async function lowerGlobalCap(newCap: string): Promise<void> {
  const aaveModule = await getDeployedAddress(hre, "AaveYieldGenerationModule");
  const contract = await hre.ethers.getContractAt("AaveYieldGenerationModule", aaveModule);
  
  const [guardian] = await hre.ethers.getSigners();
  const guardianAddress = process.env.GUARDIAN_ADDRESS || guardian.address;
  
  // Get current cap
  const currentCap = await contract.globalCap();
  
  console.log(`\n📉 Lowering global cap...`);
  console.log(`   Current cap: ${currentCap.toString()}`);
  console.log(`   New cap: ${newCap}`);
  console.log(`   Guardian: ${guardianAddress}`);
  
  // Verify new cap is lower
  const newCapBigInt = BigInt(newCap);
  if (newCapBigInt > currentCap) {
    throw new Error(`New cap (${newCap}) must be <= current cap (${currentCap.toString()})`);
  }
  
  // Verify guardian has ROLE_GUARDIAN
  const ROLE_GUARDIAN = await contract.ROLE_GUARDIAN();
  const hasRole = await contract.hasRole(ROLE_GUARDIAN, guardianAddress);
  
  if (!hasRole) {
    throw new Error(`Guardian ${guardianAddress} does not have ROLE_GUARDIAN`);
  }
  
  const guardianSigner = await hre.ethers.getSigner(guardianAddress);
  const connectedContract = contract.connect(guardianSigner);
  
  const tx = await connectedContract.guardianLowerGlobalCap(newCapBigInt);
  console.log(`   TX: ${tx.hash}`);
  
  const receipt = await tx.wait();
  console.log(`   ✅ Global cap lowered`);
  console.log(`      Block: ${receipt!.blockNumber}`);
  console.log(`      Gas: ${receipt!.gasUsed.toString()}`);
}

async function main() {
  const action = process.argv[2] as EmergencyAction;
  const contractName = process.argv.find(arg => arg.startsWith("--contract="))?.split("=")[1];
  const tokenAddress = process.argv.find(arg => arg.startsWith("--token="))?.split("=")[1];
  const newCap = process.argv.find(arg => arg.startsWith("--new-cap="))?.split("=")[1];
  
  if (!action) {
    console.error(`
Usage: pnpm ts-node scripts/gov/emergency.ts <action> [options] [--network=<network>]

Actions:
  pause              Pause the protocol
  disable-aave       Disable Aave yield generation
  lower-cap          Lower a token cap
  lower-global-cap   Lower the global cap

Options:
  --contract=<name>  Contract name for pause (EscrowableERC20 or EscrowVault)
  --token=<address>  Token address for lower-cap
  --new-cap=<amount> New cap amount (in wei)

Examples:
  pnpm ts-node scripts/gov/emergency.ts pause --contract EscrowableERC20
  pnpm ts-node scripts/gov/emergency.ts disable-aave
  pnpm ts-node scripts/gov/emergency.ts lower-cap --token 0x... --new-cap 5000000000000
    `);
    process.exit(1);
  }
  
  console.log(`\n🚨 Emergency Action: ${action}`);
  console.log(`   Network: ${hre.network.name}`);
  
  // Verify GUARDIAN_ADDRESS is set
  if (!process.env.GUARDIAN_ADDRESS) {
    console.warn("   ⚠️  GUARDIAN_ADDRESS not set, using first signer");
  }
  
  try {
    switch (action) {
      case "pause":
        if (!contractName) {
          throw new Error("--contract=<name> required for pause action");
        }
        await pauseProtocol(contractName);
        break;
        
      case "disable-aave":
        await disableAave();
        break;
        
      case "lower-cap":
        if (!tokenAddress || !newCap) {
          throw new Error("--token=<address> and --new-cap=<amount> required for lower-cap action");
        }
        await lowerTokenCap(tokenAddress, newCap);
        break;
        
      case "lower-global-cap":
        if (!newCap) {
          throw new Error("--new-cap=<amount> required for lower-global-cap action");
        }
        await lowerGlobalCap(newCap);
        break;
        
      default:
        throw new Error(`Unknown action: ${action}`);
    }
    
    console.log("\n✅ Emergency action completed successfully!");
  } catch (error: any) {
    console.error(`\n❌ Error: ${error.message}`);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });





