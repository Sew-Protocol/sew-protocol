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

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
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

  const escrowVaultDeployment = await get('EscrowVault');
  const moduleRegistryDeployment = await get('ModuleSnapshotRegistry');
  const moduleRegistry = await ethers.getContractAt('ModuleSnapshotRegistry', moduleRegistryDeployment.address);
  const currentStrategy = await moduleRegistry.getDefaultReleaseStrategy(escrowVaultDeployment.address);
  const timelockRole = await moduleRegistry.ROLE_TIMELOCK();
  const canConfigure = await moduleRegistry.hasRole(timelockRole, deployer);

  if (currentStrategy.toLowerCase() !== deployment.address.toLowerCase()) {
    // BaseEscrow.ModuleType.RELEASE = 1.
    const moduleType = 1;
    if (!canConfigure) {
      console.log(`   ℹ️  Deployer lacks registry timelock permission; governance must wire the strategy.`);
      return;
    }

    const pending = await moduleRegistry.getPendingModule(escrowVaultDeployment.address, moduleType);
    if (!pending[2] || pending[0].toLowerCase() !== deployment.address.toLowerCase()) {
      console.log(`   Queuing DefaultReleaseStrategy for EscrowVault...`);
      const queueTx = await moduleRegistry.queueModule(escrowVaultDeployment.address, moduleType, deployment.address);
      await queueTx.wait();
    } else {
      console.log(`   ✅ DefaultReleaseStrategy already queued for EscrowVault`);
    }

    if (hre.network.name === 'hardhat' || hre.network.name === 'localhost') {
      console.log(`   Activating DefaultReleaseStrategy (local)...`);
      const activateTx = await moduleRegistry.activateModule(escrowVaultDeployment.address, moduleType);
      await activateTx.wait();
    } else {
      console.log(`   Queued. Governance must activate after the timelock delay.`);
    }
  } else {
    console.log(`   ✅ DefaultReleaseStrategy already active on EscrowVault`);
  }
};

export default func;
func.tags = ['release-strategy', 'module'];
func.dependencies = ['core', 'escrow'];
