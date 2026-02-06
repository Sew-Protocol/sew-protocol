import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { ethers } from 'hardhat';

/**
 * Deployment script for CREATE2EscrowFactory and MultiL2ViewAggregator
 * Phase 1: Prerequisites - Multi-L2 Support
 *
 * This deployment enables deterministic contract deployment across multiple L2s.
 *
 * Usage:
 * - Single chain: npx hardhat deploy --tags create2
 * - Multi-chain: Deploy on each chain with same salt to get same addresses
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  console.log('\n=== Deploying CREATE2 Factory ===');

  // Deploy CREATE2EscrowFactory
  const factoryDeployment = await deploy('CREATE2EscrowFactory', {
    from: deployer,
    log: true,
    args: [],
  });

  console.log(`✓ CREATE2EscrowFactory deployed to: ${factoryDeployment.address}`);

  // Deploy MultiL2ViewAggregator (requires EscrowVault to be already deployed)
  const escrowVault = await deployments.getOrNull('EscrowVault');
  if (!escrowVault) {
    console.log('⚠ EscrowVault not found - skipping MultiL2ViewAggregator deployment');
    console.log('  Deploy EscrowVault first, then run this script again');
    return;
  }

  const aggregatorDeployment = await deploy('MultiL2ViewAggregator', {
    from: deployer,
    log: true,
    args: [escrowVault.address],
  });

  console.log(`✓ MultiL2ViewAggregator deployed to: ${aggregatorDeployment.address}`);
  console.log(`✓ Aggregator connected to EscrowVault at: ${escrowVault.address}`);

  console.log('\n=== Deployment Summary ===');
  console.log(`Network: ${hre.network.name}`);
  console.log(`Deployer: ${deployer}`);
  console.log(`\nDeployed Contracts:`);
  console.log(`  CREATE2EscrowFactory:    ${factoryDeployment.address}`);
  console.log(`  MultiL2ViewAggregator:   ${aggregatorDeployment.address}`);
  console.log(`\nNext Steps:`);
  console.log(`  1. Test deterministic deployment`);
  console.log(`  2. Deploy on other L2s with same salt`);
  console.log(`  3. Verify same addresses on all chains`);
  console.log(`  4. Register addresses in L2AddressRegistry`);
};

export default func;
func.tags = ['create2'];
func.dependencies = ['vault'];
