/**
 * Test Helper: Setup Resolution Module
 *
 * After Phase 7, all escrow creation requires a resolution module to be configured.
 * This helper sets up a default resolution module for testing.
 */

import { ethers } from 'hardhat';
import { time } from '@nomicfoundation/hardhat-network-helpers';
import { EscrowableERC20, EscrowVault, DefaultResolutionModule } from '../../typechain-types';

export async function setupResolutionModule(
  contract: EscrowableERC20 | EscrowVault,
  deployer: any,
  resolverAddress?: string,
): Promise<DefaultResolutionModule> {
  // Get deployer address if not provided
  const deployerAddress = typeof deployer === 'string' ? deployer : await deployer.getAddress();

  // Use provided resolver or use deployer as resolver
  const resolver = resolverAddress || deployerAddress;

  // Deploy DefaultResolutionModule
  const ResolutionModuleFactory = await ethers.getContractFactory('DefaultResolutionModule');
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

  // Set default resolution module (Derived contract level)
  // Phase 8: EscrowVault now uses Slow lane (queue/activate) like EscrowableERC20
  // Updated: EscrowableERC20 now uses consolidated queueModule/activateModule
  if ('queueModule' in contract || 'queueDefaultResolutionModule' in contract) {
    // EscrowableERC20 uses consolidated functions, EscrowVault may still use old or new
    const moduleAddress = await resolutionModule.getAddress();
    let eta: bigint;
    let exists: boolean;
    
    if ('queueModule' in contract) {
      // New consolidated function (EscrowableERC20)
      await (contract as any)
        .connect(deployer)
        .queueModule(0, moduleAddress); // 0 = ModuleType.RESOLUTION
      const [, etaVal, existsVal] = await (contract as any).getPendingModule(0);
      eta = etaVal;
      exists = existsVal;
    } else {
      // Old function (EscrowVault or legacy)
      await (contract as any)
        .connect(deployer)
        .queueDefaultResolutionModule(moduleAddress);
      const [, etaVal, existsVal] = await (contract as any).getPendingDefaultResolutionModule();
      eta = etaVal;
      exists = existsVal;
    }
    
    if (!exists) {
      throw new Error('Failed to queue resolution module');
    }
    // Fast-forward time to allow activation (7 days = 604800 seconds)
    await time.increaseTo(Number(eta) + 1);
    
    if ('activateModule' in contract) {
      await (contract as any).connect(deployer).activateModule(0); // 0 = ModuleType.RESOLUTION
    } else {
      await (contract as any).connect(deployer).activateDefaultResolutionModule();
    }
  }

  // Set resolution module (BaseEscrow level) - now uses slow lane (7-day delay)
  if ('queueResolutionModule' in contract) {
    // BaseEscrow pattern (slow lane queue/activate) - uses 7-day delay
    await (contract as any)
      .connect(deployer)
      .queueResolutionModule(await resolutionModule.getAddress());
    const [, eta, exists] = await (contract as any).getPendingResolutionModule();
    if (!exists) {
      throw new Error('Failed to queue resolution module');
    }
    // Fast-forward time to allow activation (7 days = 604800 seconds)
    await time.increaseTo(Number(eta) + 1);
    await (contract as any).connect(deployer).activateResolutionModule();
  }

  // Ensure at least one was set
  if (!('queueModule' in contract) && !('queueDefaultResolutionModule' in contract) && !('queueResolutionModule' in contract)) {
    throw new Error('Contract does not have a method to set resolution module.');
  }

  return resolutionModule as DefaultResolutionModule;
}
