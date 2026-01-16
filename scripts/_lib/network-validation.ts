/**
 * Network Validation Utilities
 *
 * Validates network configuration and prevents deployment errors.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { getChainConfig, isMainnet } from '../../config/chains.config';

/**
 * Validate network configuration
 *
 * Checks:
 * - Chain ID matches expected value
 * - RPC endpoint is accessible
 * - Mainnet deployments require confirmation
 *
 * @param hre Hardhat runtime environment
 * @throws Error if validation fails
 */
export async function validateNetwork(
  hre: HardhatRuntimeEnvironment,
): Promise<void> {
  const chainConfig = getChainConfig(hre);
  const network = await hre.ethers.provider.getNetwork();

  // Validate chainId matches
  if (Number(network.chainId) !== chainConfig.chainId) {
    throw new Error(
      `Chain ID mismatch: RPC returned ${network.chainId}, ` +
        `but config expects ${chainConfig.chainId} for ${chainConfig.name}`,
    );
  }

  // Validate RPC endpoint (basic check)
  if (chainConfig.rpcUrl && !chainConfig.rpcUrl.includes('localhost')) {
    try {
      const blockNumber = await hre.ethers.provider.getBlockNumber();
      console.log(
        `✅ Network validated: ${chainConfig.displayName} (block ${blockNumber})`,
      );
    } catch (error) {
      throw new Error(
        `Failed to connect to RPC endpoint for ${chainConfig.displayName}: ${error}`,
      );
    }
  }

  // Warn if deploying to mainnet without confirmation
  if (chainConfig.networkType === 'mainnet' && chainConfig.deployment.confirmRequired) {
    if (process.env.DEPLOY_CONFIRM !== 'YES') {
      throw new Error(
        `Mainnet deployment requires DEPLOY_CONFIRM=YES. ` +
          `Current value: ${process.env.DEPLOY_CONFIRM || 'not set'}`,
      );
    }
  }
}

/**
 * Validate network before deployment
 *
 * Shorthand for validateNetwork with deployment-specific checks
 *
 * @param hre Hardhat runtime environment
 * @throws Error if validation fails
 */
export async function validateNetworkForDeployment(
  hre: HardhatRuntimeEnvironment,
): Promise<void> {
  await validateNetwork(hre);

  const chainConfig = getChainConfig(hre);

  // Additional deployment checks
  if (chainConfig.networkType === 'mainnet') {
    console.log(`⚠️  Deploying to MAINNET: ${chainConfig.displayName}`);
    console.log(`   Chain ID: ${chainConfig.chainId}`);
    console.log(`   Block Explorer: ${chainConfig.blockExplorer.url}`);
  } else if (chainConfig.networkType === 'testnet') {
    console.log(`📝 Deploying to TESTNET: ${chainConfig.displayName}`);
  } else {
    console.log(`🔧 Deploying to LOCAL: ${chainConfig.displayName}`);
  }
}
