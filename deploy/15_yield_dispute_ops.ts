/**
 * Deploy Ops Contracts
 *
 * These are utility contracts required by the core escrow contracts.
 * - YieldOps: Handles yield withdrawal and distribution
 * - DisputeOps: Handles dispute escalation orchestration
 * - SettlementOps: Handles settlement execution operations
 * - CreateOps: Handles escrow creation validation and computation
 * - BondCollector: Handles escalation bond collection
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

  console.log(`\n📦 Deploying Ops Contracts...`);

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

  // Deploy DisputeOps
  console.log(`\n   Deploying DisputeOps...`);
  const disputeOpsDeployment = await deploy('DisputeOps', {
    contract: 'DisputeOps',
    from: deployer,
    args: [deployer], // initialOwner
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
        constructorArgs: [deployer],
        tags: ['core', 'dispute'],
      });
    }
  } else {
    console.log(`   ✅ DisputeOps already deployed at: ${disputeOpsDeployment.address}`);
  }

  // Deploy SettlementOps
  console.log(`\n   Deploying SettlementOps...`);
  const settlementOpsDeployment = await deploy('SettlementOps', {
    contract: 'SettlementOps',
    from: deployer,
    args: [deployer], // initialOwner
    log: true,
  });

  if (settlementOpsDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, settlementOpsDeployment.address);
    console.log(`   ✅ SettlementOps deployed at: ${settlementOpsDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (settlementOpsDeployment.receipt) {
      await registerDeployment(hre, 'SettlementOps', {
        address: settlementOpsDeployment.address,
        txHash: settlementOpsDeployment.receipt.hash,
        blockNumber: settlementOpsDeployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['core', 'settlement'],
      });
    }
  } else {
    console.log(`   ✅ SettlementOps already deployed at: ${settlementOpsDeployment.address}`);
  }

  // Deploy CreateOps
  console.log(`\n   Deploying CreateOps...`);
  const createOpsDeployment = await deploy('CreateOps', {
    contract: 'CreateOps',
    from: deployer,
    args: [deployer], // initialOwner
    log: true,
  });

  if (createOpsDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, createOpsDeployment.address);
    console.log(`   ✅ CreateOps deployed at: ${createOpsDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (createOpsDeployment.receipt) {
      await registerDeployment(hre, 'CreateOps', {
        address: createOpsDeployment.address,
        txHash: createOpsDeployment.receipt.hash,
        blockNumber: createOpsDeployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['core', 'create'],
      });
    }
  } else {
    console.log(`   ✅ CreateOps already deployed at: ${createOpsDeployment.address}`);
  }

  // Deploy BondCollector
  console.log(`\n   Deploying BondCollector...`);
  const bondCollectorDeployment = await deploy('BondCollector', {
    contract: 'BondCollector',
    from: deployer,
    args: [deployer], // initialOwner
    log: true,
  });

  if (bondCollectorDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, bondCollectorDeployment.address);
    console.log(`   ✅ BondCollector deployed at: ${bondCollectorDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (bondCollectorDeployment.receipt) {
      await registerDeployment(hre, 'BondCollector', {
        address: bondCollectorDeployment.address,
        txHash: bondCollectorDeployment.receipt.hash,
        blockNumber: bondCollectorDeployment.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['core', 'bond'],
      });
    }
  } else {
    console.log(`   ✅ BondCollector already deployed at: ${bondCollectorDeployment.address}`);
  }
};

export default func;
func.tags = ['core', 'yield-ops', 'dispute-ops', 'settlement-ops', 'create-ops', 'bond-collector'];
func.dependencies = [];
