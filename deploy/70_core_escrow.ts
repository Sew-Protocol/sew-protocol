/**
 * Deploy Core Escrow Contracts
 *
 * Deploys:
 * - EscrowVault: Main escrow contract for ERC20 tokens
 * - EscrowableERC20: ERC20 token with built-in escrow functionality
 *
 * These contracts require YieldOps and DisputeOps to be deployed first.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig } from './_config';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';
import { isZeroAddress } from '../scripts/_lib/addresses';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();
  const config = getGovConfig(hre);
  const chainConfig = getChainConfig(hre);

  console.log(`\n📦 Deploying Core Escrow Contracts...`);

  // Get dependencies
  const yieldOpsDeployment = await get('YieldOps');
  const disputeOpsDeployment = await get('DisputeOps');

  // Get fee configuration from environment or use defaults
  const escrowFeeBps = parseInt(process.env.ESCROW_FEE_BPS || '0', 10); // 0% default (0-10000 bps)
  const escrowFee = (escrowFeeBps * 10000) / 10000; // Convert to fee denominator (10000 = 100%)
  const feeRecipient = config.feeRecipient || deployer;

  if (isZeroAddress(feeRecipient)) {
    throw new Error('Fee recipient cannot be zero address. Set FEE_RECIPIENT in .env');
  }

  console.log(`\n   Configuration:`);
  console.log(`      Escrow Fee: ${escrowFeeBps} bps (${(escrowFeeBps / 100).toFixed(2)}%)`);
  console.log(`      Fee Recipient: ${feeRecipient}`);
  console.log(`      YieldOps: ${yieldOpsDeployment.address}`);
  console.log(`      DisputeOps: ${disputeOpsDeployment.address}`);

  // Deploy EscrowVault
  console.log(`\n   Deploying EscrowVault...`);
  const escrowVaultDeployment = await deploy('EscrowVault', {
    contract: 'EscrowVault',
    from: deployer,
    args: [
      escrowFee, // fee (in fee denominator units, 10000 = 100%)
      feeRecipient, // feeAddress
      yieldOpsDeployment.address, // yieldOps
      disputeOpsDeployment.address, // disputeOps
    ],
    log: true,
  });

  if (escrowVaultDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, escrowVaultDeployment.address);
    console.log(`   ✅ EscrowVault deployed at: ${escrowVaultDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (escrowVaultDeployment.receipt) {
      await registerDeployment(hre, 'EscrowVault', {
        address: escrowVaultDeployment.address,
        txHash: escrowVaultDeployment.receipt.hash,
        blockNumber: escrowVaultDeployment.receipt.blockNumber,
        constructorArgs: [
          escrowFee,
          feeRecipient,
          yieldOpsDeployment.address,
          disputeOpsDeployment.address,
        ],
        tags: ['core', 'escrow'],
      });
    }
  } else {
    console.log(`   ✅ EscrowVault already deployed at: ${escrowVaultDeployment.address}`);
  }

  // Deploy EscrowableERC20 (optional - only if needed)
  const deployEscrowableERC20 = process.env.DEPLOY_ESCROWABLE_ERC20 === 'true';
  if (deployEscrowableERC20) {
    const tokenName = process.env.ESCROWABLE_TOKEN_NAME || 'Escrowable Token';
    const tokenSymbol = process.env.ESCROWABLE_TOKEN_SYMBOL || 'ESCROW';

    console.log(`\n   Deploying EscrowableERC20...`);
    console.log(`      Name: ${tokenName}`);
    console.log(`      Symbol: ${tokenSymbol}`);

    const escrowableERC20Deployment = await deploy('EscrowableERC20', {
      contract: 'EscrowableERC20',
      from: deployer,
      args: [
        tokenName, // name
        tokenSymbol, // symbol
        escrowFee, // fee
        feeRecipient, // feeAddress
        yieldOpsDeployment.address, // yieldOps
        disputeOpsDeployment.address, // disputeOps
      ],
      log: true,
    });

    if (escrowableERC20Deployment.newlyDeployed) {
      const explorerUrl = getBlockExplorerUrl(hre, escrowableERC20Deployment.address);
      console.log(`   ✅ EscrowableERC20 deployed at: ${escrowableERC20Deployment.address}`);
      if (explorerUrl) {
        console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
      }

      if (escrowableERC20Deployment.receipt) {
        await registerDeployment(hre, 'EscrowableERC20', {
          address: escrowableERC20Deployment.address,
          txHash: escrowableERC20Deployment.receipt.hash,
          blockNumber: escrowableERC20Deployment.receipt.blockNumber,
          constructorArgs: [
            tokenName,
            tokenSymbol,
            escrowFee,
            feeRecipient,
            yieldOpsDeployment.address,
            disputeOpsDeployment.address,
          ],
          tags: ['core', 'escrow', 'token'],
        });
      }
    } else {
      console.log(`   ✅ EscrowableERC20 already deployed at: ${escrowableERC20Deployment.address}`);
    }
  } else {
    console.log(`\n   ℹ️  EscrowableERC20 deployment skipped (set DEPLOY_ESCROWABLE_ERC20=true to deploy)`);
  }
};

export default func;
func.tags = ['core', 'escrow'];
func.dependencies = ['yield-ops', 'dispute-ops'];
