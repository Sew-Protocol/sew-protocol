/**
 * Deploy YieldOps and DisputeOps
 *
 * These are utility contracts required by the core escrow contracts.
 * - YieldOps: Handles yield withdrawal and distribution
 * - DisputeOps: Handles dispute escalation orchestration
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

  console.log(`\n📦 Deploying YieldOps and DisputeOps...`);

  // Deploy YieldOps
  console.log(`\n   Deploying YieldOps...`);
  const yieldOpsDeployment = await deploy('YieldOps', {
    contract: 'YieldOps',
    from: deployer,
    args: [deployer], // initialOwner
    log: true,
  });

  if (yieldOpsDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, yieldOpsDeployment.address);
    console.log(`   ✅ YieldOps deployed at: ${yieldOpsDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    // Wait for transaction confirmation before next deployment
    if (yieldOpsDeployment.receipt) {
      await yieldOpsDeployment.receipt.wait();
      await registerDeployment(hre, 'YieldOps', {
        address: yieldOpsDeployment.address,
        txHash: yieldOpsDeployment.receipt.hash,
        blockNumber: yieldOpsDeployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['core', 'yield'],
      });
    }
  } else {
    console.log(`   ✅ YieldOps already deployed at: ${yieldOpsDeployment.address}`);
  }

  // Deploy DisputeOps (no constructor)
  console.log(`\n   Deploying DisputeOps...`);
  const disputeOpsDeployment = await deploy('DisputeOps', {
    contract: 'DisputeOps',
    from: deployer,
    args: [],
    log: true,
  });

  if (disputeOpsDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, disputeOpsDeployment.address);
    console.log(`   ✅ DisputeOps deployed at: ${disputeOpsDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (disputeOpsDeployment.receipt) {
      await registerDeployment(hre, 'DisputeOps', {
        address: disputeOpsDeployment.address,
        txHash: disputeOpsDeployment.receipt.hash,
        blockNumber: disputeOpsDeployment.receipt.blockNumber,
        constructorArgs: [],
        tags: ['core', 'dispute'],
      });
    }
  } else {
    console.log(`   ✅ DisputeOps already deployed at: ${disputeOpsDeployment.address}`);
  }
};

export default func;
func.tags = ['core', 'yield-ops', 'dispute-ops'];
func.dependencies = [];
