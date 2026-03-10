/**
 * Deploy Cancellation Strategy Module
 *
 * Deploys:
 * - DefaultCancellationStrategy: Default mutual consent cancellation
 * - Sets default cancellation strategy on EscrowVault
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);

  console.log(`\n📦 Deploying Cancellation Strategy Module...`);

  // Get EscrowVault deployment
  const escrowVaultDeployment = await get('EscrowVault');
  console.log(`   EscrowVault: ${escrowVaultDeployment.address}`);

  // Deploy DefaultCancellationStrategy
  console.log(`\n   Deploying DefaultCancellationStrategy...`);
  const defaultCancellationStrategyDeployment = await deploy('DefaultCancellationStrategy', {
    contract: 'DefaultCancellationStrategy',
    from: deployer,
    args: [],
    log: true,
  });

  if (defaultCancellationStrategyDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, defaultCancellationStrategyDeployment.address);
    console.log(
      `   ✅ DefaultCancellationStrategy deployed at: ${defaultCancellationStrategyDeployment.address}`,
    );
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (defaultCancellationStrategyDeployment.receipt) {
      await registerDeployment(hre, 'DefaultCancellationStrategy', {
        address: defaultCancellationStrategyDeployment.address,
        txHash: defaultCancellationStrategyDeployment.receipt.hash,
        blockNumber: defaultCancellationStrategyDeployment.receipt.blockNumber,
        constructorArgs: [],
        tags: ['module', 'cancellation-strategy'],
      });
    }
  } else {
    console.log(
      `   ✅ DefaultCancellationStrategy already deployed at: ${defaultCancellationStrategyDeployment.address}`,
    );
  }

  // Set default cancellation strategy on EscrowVault
  console.log(`\n   Setting default cancellation strategy on EscrowVault...`);
  const escrowVaultContract = await ethers.getContractAt(
    'EscrowVault',
    escrowVaultDeployment.address,
  );

  try {
    const currentStrategy = await escrowVaultContract.defaultCancellationStrategy();
    if (
      currentStrategy.toLowerCase() !== defaultCancellationStrategyDeployment.address.toLowerCase()
    ) {
      const setStrategyTx = await escrowVaultContract.setDefaultCancellationStrategy(
        defaultCancellationStrategyDeployment.address,
      );
      await setStrategyTx.wait();
      console.log(`   ✅ Default cancellation strategy set on EscrowVault`);
    } else {
      console.log(`   ✅ Default cancellation strategy already set on EscrowVault`);
    }
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount')) {
      console.log(
        `   ℹ️  Deployer does not have permission to set cancellation strategy. Must be set via governance.`,
      );
    } else {
      throw error;
    }
  }

  console.log(`\n✅ Cancellation Strategy Module deployment complete!`);
};

export default func;
func.tags = ['module', 'cancellation-strategy'];
func.dependencies = ['core', 'escrow'];
