/**
 * Test Helper: Setup Resolution Module
 * 
 * After Phase 7, all escrow creation requires a resolution module to be configured.
 * This helper sets up a default resolution module for testing.
 */

import { ethers } from "hardhat";
import { 
  EscrowableERC20,
  EscrowVault,
  DefaultResolutionModule
} from "../../typechain-types";

export async function setupResolutionModule(
  contract: EscrowableERC20 | EscrowVault,
  deployer: any,
  resolverAddress?: string
): Promise<DefaultResolutionModule> {
  // Get deployer address if not provided
  const deployerAddress = typeof deployer === 'string' ? deployer : await deployer.getAddress();
  
  // Use provided resolver or use deployer as resolver
  const resolver = resolverAddress || deployerAddress;

  // Deploy DefaultResolutionModule
  const ResolutionModuleFactory = await ethers.getContractFactory("DefaultResolutionModule");
  const resolutionModule = await ResolutionModuleFactory.deploy(deployerAddress, resolver);
  await resolutionModule.waitForDeployment();

  // Grant ROLE_TIMELOCK to deployer if not already granted
  const ROLE_TIMELOCK = await contract.ROLE_TIMELOCK();
  const hasRole = await contract.hasRole(ROLE_TIMELOCK, deployerAddress);
  if (!hasRole) {
    const DEFAULT_ADMIN_ROLE = await contract.DEFAULT_ADMIN_ROLE();
    const hasAdmin = await contract.hasRole(DEFAULT_ADMIN_ROLE, deployerAddress);
    if (hasAdmin) {
      await contract.grantRole(ROLE_TIMELOCK, deployerAddress);
    }
  }

  // Set resolution module delay to 0 for testing (instant activation)
  try {
    await contract.connect(deployer).setResolutionModuleDelay(0);
  } catch (error: any) {
    // If already set or fails, continue
  }

  // Set default resolution module
  // Phase 8: EscrowVault now uses Slow lane (queue/activate) like EscrowableERC20
  if ("queueDefaultResolutionModule" in contract) {
    // EscrowableERC20 or EscrowVault (after Phase 8 fix)
    await contract.connect(deployer).queueDefaultResolutionModule(await resolutionModule.getAddress());
    const [, eta] = await contract.getPendingDefaultResolutionModule();
    // Fast-forward time to allow activation
    const { ethers } = await import("hardhat");
    await ethers.provider.send("evm_setNextBlockTimestamp", [Number(eta) + 1]);
    await ethers.provider.send("evm_mine", []);
    await contract.connect(deployer).activateDefaultResolutionModule();
  } else if ("proposeResolutionModule" in contract) {
    // BaseEscrow pattern (two-step with delay)
    await contract.connect(deployer).proposeResolutionModule(await resolutionModule.getAddress());
    await contract.connect(deployer).activateResolutionModule();
  } else {
    throw new Error("Contract does not have a method to set default resolution module.");
  }

  return resolutionModule as DefaultResolutionModule;
}

