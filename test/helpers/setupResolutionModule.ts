/**
 * Test Helper: Setup Resolution Module
 * 
 * After Phase 7, all escrow creation requires a resolution module to be configured.
 * This helper sets up a default resolution module for testing.
 */

import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
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

  // Set default resolution module
  // Phase 8: EscrowVault now uses Slow lane (queue/activate) like EscrowableERC20
  if ("queueDefaultResolutionModule" in contract) {
    // EscrowableERC20 or EscrowVault (after Phase 8 fix) - uses 7-day delay
    await contract.connect(deployer).queueDefaultResolutionModule(await resolutionModule.getAddress());
    const [, eta, exists] = await contract.getPendingDefaultResolutionModule();
    if (!exists) {
      throw new Error("Failed to queue resolution module");
    }
    // Fast-forward time to allow activation (7 days = 604800 seconds)
    await time.increaseTo(Number(eta) + 1);
    await contract.connect(deployer).activateDefaultResolutionModule();
  } else if ("proposeResolutionModule" in contract) {
    // BaseEscrow pattern (two-step with delay) - uses resolutionModuleDelay (min 48 hours)
    // Set minimum delay for testing
    const MIN_DELAY = 48 * 60 * 60; // 48 hours
    try {
      await contract.connect(deployer).setResolutionModuleDelay(MIN_DELAY);
    } catch (error: any) {
      // If already set or fails, continue
    }
    await contract.connect(deployer).proposeResolutionModule(await resolutionModule.getAddress());
    const delay = await contract.disputeResolutionModuleDelay();
    const currentTime = await time.latest();
    await time.increaseTo(Number(currentTime) + Number(delay) + 1);
    await contract.connect(deployer).activateResolutionModule();
  } else {
    throw new Error("Contract does not have a method to set default resolution module.");
  }

  return resolutionModule as DefaultResolutionModule;
}

