/**
 * Address Loading Utilities
 *
 * Loads deployed contract addresses from hardhat-deploy artifacts.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeploymentsExtension } from 'hardhat-deploy/types';

/**
 * Get deployed contract address by name
 * @param allowPlaceholder If true, returns placeholder address when not deployed (for offline proposal building)
 */
export async function getDeployedAddress(
  hre: HardhatRuntimeEnvironment,
  contractName: string,
  allowPlaceholder: boolean = false,
): Promise<string> {
  try {
    const deployment = await hre.deployments.get(contractName);
    if (!deployment || !deployment.address) {
      throw new Error(`Contract ${contractName} not found in deployments`);
    }
    return deployment.address;
  } catch (error) {
    if (allowPlaceholder) {
      // Return a placeholder address for offline proposal building
      // This will need to be replaced with actual address before execution
      return `0xPLACEHOLDER_${contractName.toUpperCase()}`;
    }
    throw error;
  }
}

/**
 * Get multiple deployed contract addresses
 */
export async function getDeployedAddresses(
  hre: HardhatRuntimeEnvironment,
  contractNames: string[],
): Promise<Record<string, string>> {
  const addresses: Record<string, string> = {};
  for (const name of contractNames) {
    addresses[name] = await getDeployedAddress(hre, name);
  }
  return addresses;
}

/**
 * Get all deployed contracts for a network
 */
export async function getAllDeployedAddresses(
  hre: HardhatRuntimeEnvironment,
): Promise<Record<string, string>> {
  const allDeployments = await hre.deployments.all();
  const addresses: Record<string, string> = {};

  for (const [name, deployment] of Object.entries(allDeployments)) {
    if (deployment.address) {
      addresses[name] = deployment.address;
    }
  }

  return addresses;
}

/**
 * Validate that required contracts are deployed
 */
export async function validateDeployments(
  hre: HardhatRuntimeEnvironment,
  required: string[],
): Promise<void> {
  const missing: string[] = [];

  for (const name of required) {
    try {
      await hre.deployments.get(name);
    } catch (error) {
      missing.push(name);
    }
  }

  if (missing.length > 0) {
    throw new Error(
      `Missing required deployments: ${missing.join(', ')}\n` +
        `Run 'hardhat deploy' first to deploy contracts.`,
    );
  }
}
