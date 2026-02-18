/**
 * Deploy L2AddressRegistry
 *
 * Central registry for multi-L2 contract addresses.
 * Enables cross-chain address discovery and version management.
 *
 * For testnet: Deploy on Base Sepolia to test the registry flow
 * For mainnet: Deploy on Ethereum as the canonical registry
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get, all } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);

  console.log(`\n📦 Deploying L2AddressRegistry...`);

  // For L2AddressRegistry, we need initial governors
  // On testnet, use deployer as sole governor
  // On mainnet, this would be a multi-sig
  const initialGovernors = [deployer];
  const requiredSignatures = 1; // Testnet: 1-of-1, Mainnet: would be 3-of-5 etc.

  const registryDeployment = await deploy('L2AddressRegistry', {
    contract: 'L2AddressRegistry',
    from: deployer,
    args: [initialGovernors, requiredSignatures],
    log: true,
  });

  if (registryDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, registryDeployment.address);
    console.log(`   ✅ L2AddressRegistry deployed at: ${registryDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (registryDeployment.receipt) {
      await registerDeployment(hre, 'L2AddressRegistry', {
        address: registryDeployment.address,
        txHash: registryDeployment.receipt.hash,
        blockNumber: registryDeployment.receipt.blockNumber,
        constructorArgs: [initialGovernors, requiredSignatures],
        tags: ['registry', 'multi-l2'],
      });
    }
  } else {
    console.log(`   ✅ L2AddressRegistry already deployed at: ${registryDeployment.address}`);
  }

  // Register contract types
  console.log(`\n   Registering contract types...`);
  const registry = await ethers.getContractAt('L2AddressRegistry', registryDeployment.address);

  const contractTypes = [
    'EscrowVault',
    'EscrowableERC20',
    'EscrowGovernanceTimelock',
    'YieldOps',
    'DisputeOps',
    'SettlementOps',
    'CreateOps',
    'BondCollector',
    'ModuleSnapshotRegistry',
    'AaveYieldModule',
    'DefaultResolutionModule',
    'DefaultReleaseStrategy',
    'GovGovernor',
    'TimelockController',
    'SewToken',
  ];

  for (const contractName of contractTypes) {
    try {
      const isRegistered = await registry.isRegisteredContract(contractName);
      if (!isRegistered) {
        console.log(`      Registering ${contractName}...`);
        const tx = await registry.registerContract(contractName);
        await tx.wait();
        console.log(`      ✅ ${contractName} registered`);
      } else {
        console.log(`      ✅ ${contractName} already registered`);
      }
    } catch (error: any) {
      console.log(`      ⚠️  Error registering ${contractName}: ${error.message}`);
    }
  }

  // Register this chain's addresses
  console.log(`\n   Registering chain addresses...`);
  const currentChainId = chainConfig.chainId;

  // Get all deployed contract addresses
  const allDeployments = await all();
  const contractsToRegister = [
    'EscrowVault',
    'EscrowableERC20',
    'EscrowGovernanceTimelock',
    'YieldOps',
    'DisputeOps',
    'SettlementOps',
    'CreateOps',
    'BondCollector',
    'ModuleSnapshotRegistry',
    'AaveYieldModule',
    'DefaultResolutionModule',
    'DefaultReleaseStrategy',
    'GovGovernor',
    'TimelockController',
    'SewToken',
  ];

  const version = 'v1.0.0-testnet'; // Testnet version tag

  for (const contractName of contractsToRegister) {
    const deployment = allDeployments[contractName];
    if (deployment) {
      try {
        console.log(`      Registering ${contractName}: ${deployment.address}`);
        const tx1 = await registry.registerAddress(
          currentChainId,
          contractName,
          version,
          deployment.address,
        );
        await tx1.wait();

        // Activate the version
        const tx2 = await registry.activateVersion(currentChainId, contractName, version);
        await tx2.wait();

        console.log(`      ✅ ${contractName} registered and activated`);
      } catch (error: any) {
        console.log(`      ⚠️  Error registering ${contractName}: ${error.message}`);
      }
    } else {
      console.log(`      ℹ️  ${contractName} not deployed, skipping`);
    }
  }

  console.log(`\n   ✅ L2AddressRegistry deployment complete`);
  console.log(`\n   Registry Info:`);
  console.log(`      Chain: ${chainConfig.name} (${currentChainId})`);
  console.log(`      Version: ${version}`);
  console.log(`      Governors: ${initialGovernors.length}`);
  console.log(`      Required Signatures: ${requiredSignatures}`);
};

export default func;
func.tags = ['registry', 'l2-address-registry', 'multi-l2'];
func.dependencies = [];
