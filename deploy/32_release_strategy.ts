/**
 * Deploy DefaultReleaseStrategy (release strategy module)
 *
 * Tag: release-strategy
 */
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);

  console.log(`\n📦 Deploying DefaultReleaseStrategy...`);

  const deployment = await deploy('DefaultReleaseStrategy', {
    contract: 'DefaultReleaseStrategy',
    from: deployer,
    args: [],
    log: true,
  });

  if (deployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, deployment.address);
    console.log(`   ✅ DefaultReleaseStrategy deployed at: ${deployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (deployment.receipt) {
      await registerDeployment(hre, 'DefaultReleaseStrategy', {
        address: deployment.address,
        txHash: deployment.receipt.hash,
        blockNumber: deployment.receipt.blockNumber,
        constructorArgs: [],
        tags: ['release-strategy'],
      });
    }
  } else {
    console.log(`   ✅ DefaultReleaseStrategy already deployed at: ${deployment.address}`);
  }
};

export default func;
func.tags = ['release-strategy'];
func.dependencies = [];

