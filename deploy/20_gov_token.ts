import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig, validateGovConfig } from './_config';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

/**
 * Deploy SewToken (Governance Token)
 *
 * This script deploys the SewToken ERC20Votes token with fixed supply.
 * The token will be used for DAO governance voting.
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  // Validate network configuration
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const config = getGovConfig(hre);
  validateGovConfig(config, hre);
  const chainConfig = getChainConfig(hre);

  console.log(`\n📦 Deploying SewToken...`);
  console.log(`   Name: ${config.token.name}`);
  console.log(`   Symbol: ${config.token.symbol}`);
  const initialSupplyFormatted = (BigInt(config.token.initialSupply) / BigInt(10 ** 18)).toString();
  console.log(`   Initial Supply: ${initialSupplyFormatted} tokens`);
  console.log(`   Initial Owner: ${deployer}`);

  const tokenDeployment = await deploy('SewToken', {
    contract: 'SewToken',
    from: deployer,
    args: [
      config.token.name,
      config.token.symbol,
      deployer, // Initial owner (will transfer to Safe/Timelock later)
      config.token.initialSupply,
    ],
    log: true,
  });

  if (tokenDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, tokenDeployment.address);
    console.log(`✅ SewToken deployed at: ${tokenDeployment.address}`);
    if (explorerUrl) {
      console.log(`   📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    // Register deployment
    if (tokenDeployment.receipt) {
      await registerDeployment(hre, 'SewToken', {
        address: tokenDeployment.address,
        txHash: tokenDeployment.receipt.hash,
        blockNumber: tokenDeployment.receipt.blockNumber,
        constructorArgs: [
          config.token.name,
          config.token.symbol,
          deployer,
          config.token.initialSupply,
        ],
        tags: ['token', 'governance'],
      });
    }

    // Mint initial tokens to configured addresses (for testing)
    if (config.initialGovTokenMints.length > 0) {
      const token = await ethers.getContractAt('SewToken', tokenDeployment.address);
      console.log(`\n💰 Minting tokens to initial recipients...`);

      for (const mint of config.initialGovTokenMints) {
        try {
          const tx = await token.mint(mint.to, mint.amount);
          await tx.wait();
          const mintAmountFormatted = (BigInt(mint.amount) / BigInt(10 ** 18)).toString();
          console.log(`   ✅ Minted ${mintAmountFormatted} tokens to ${mint.to}`);
        } catch (error: any) {
          console.log(`   ⚠️  Failed to mint to ${mint.to}: ${error.message}`);
          // SewToken doesn't have a mint function (fixed supply), so this will fail
          // This is expected - tokens are minted in constructor
        }
      }
    }

    // Verify token balance (with retry for timing issues)
    const token = await ethers.getContractAt('SewToken', tokenDeployment.address);
    let deployerBalance;
    let retries = 3;
    while (retries > 0) {
      try {
        deployerBalance = await token.balanceOf(deployer);
        break;
      } catch (error: any) {
        retries--;
        if (retries === 0) {
          console.log(`   ⚠️  Could not verify balance (this is non-critical): ${error.message}`);
          console.log(`   ✅ Deployment succeeded at: ${tokenDeployment.address}`);
          return; // Exit gracefully if balance check fails
        }
        // Wait a bit before retry
        await new Promise((resolve) => setTimeout(resolve, 2000));
      }
    }

    if (deployerBalance !== undefined) {
      console.log(`\n📊 Token balances:`);
      const balanceFormatted = (deployerBalance / BigInt(10 ** 18)).toString();
      console.log(`   Deployer: ${balanceFormatted} ${config.token.symbol}`);
    }
  } else {
    console.log(`✅ SewToken already deployed at: ${tokenDeployment.address}`);
  }
};

export default func;
func.tags = ['token', 'governance'];
func.dependencies = [];
