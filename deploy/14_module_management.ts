/**
 * Deploy ModuleManagementContract
 *
 * This contract centralizes module management for escrow contracts.
 * It handles queue/activate pattern for default modules with slow lane activation.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);

  console.log(`\n📦 Deploying ModuleManagementContract...`);

  const moduleManagementDeployment = await deploy('ModuleManagementContract', {
    contract: 'ModuleManagementContract',
    from: deployer,
    args: [deployer], // initialAdmin
    log: true,
  });

  if (moduleManagementDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, moduleManagementDeployment.address);
    console.log(`   ✅ ModuleManagementContract deployed at: ${moduleManagementDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (moduleManagementDeployment.receipt) {
      await registerDeployment(hre, 'ModuleManagementContract', {
        address: moduleManagementDeployment.address,
        txHash: moduleManagementDeployment.receipt.hash,
        blockNumber: moduleManagementDeployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['core', 'module-management'],
      });
    }
  } else {
    console.log(`   ✅ ModuleManagementContract already deployed at: ${moduleManagementDeployment.address}`);
  }
};

export default func;
func.tags = ['core', 'module-management'];
func.dependencies = [];
