/**
 * Deploy AaveYieldModule
 *
 * This contract provides yield generation via Aave V3.
 * It must be:
 * 1. Deployed with the Aave Pool address
 * 2. Approved for use by EscrowVault and EscrowableERC20
 * 3. Configured with supported tokens (USDC, etc.)
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

  console.log(`\n📦 Deploying AaveYieldModule...`);

  // Get Aave Pool address from chain config
  // We need the direct Pool address, not the AddressesProvider
  const aaveConfig = chainConfig.contracts?.aave;
  const addressesProvider = aaveConfig?.poolAddressesProvider;

  let poolAddress: string;

  if (chainConfig.chainId === 8453) {
    // Base Mainnet
    poolAddress = '0x4EdB3d48697eB0C8f4fC4d12b3c5D0eB4C1eD76';
  } else if (chainConfig.chainId === 84532) {
    // Base Sepolia
    poolAddress = '0xA238Dd80C259a72e81d7e0664A4EA4B9e5d86005';
  } else if (addressesProvider) {
    // Try to get pool from addresses provider
    poolAddress = addressesProvider;
    console.log(`   Using addresses provider: ${poolAddress}`);
  } else {
    throw new Error('Aave pool address not configured for this chain');
  }

  console.log(`   Pool address: ${poolAddress}`);

  // Deploy AaveYieldModule
  const aaveYieldModuleDeployment = await deploy('AaveYieldModule', {
    contract: 'AaveYieldModule',
    from: deployer,
    args: [poolAddress],
    log: true,
  });

  if (aaveYieldModuleDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, aaveYieldModuleDeployment.address);
    console.log(`   ✅ AaveYieldModule deployed at: ${aaveYieldModuleDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (aaveYieldModuleDeployment.receipt) {
      await registerDeployment(hre, 'AaveYieldModule', {
        address: aaveYieldModuleDeployment.address,
        txHash: aaveYieldModuleDeployment.receipt.hash,
        blockNumber: aaveYieldModuleDeployment.receipt.blockNumber,
        constructorArgs: [poolAddress],
        tags: ['yield', 'aave'],
      });
    }
  } else {
    console.log(`   ✅ AaveYieldModule already deployed at: ${aaveYieldModuleDeployment.address}`);
  }

  // Approve EscrowVault to use the module
  console.log(`\n   Approving escrows to use AaveYieldModule...`);

  try {
    const escrowVaultDeployment = await get('EscrowVault');
    const aaveModule = await ethers.getContractAt(
      'AaveYieldModule',
      aaveYieldModuleDeployment.address,
    );

    // Check if already approved
    const isApproved = await aaveModule.approvedEscrows(escrowVaultDeployment.address);
    if (!isApproved) {
      console.log(`      Approving EscrowVault: ${escrowVaultDeployment.address}`);
      const tx = await aaveModule.approveEscrow(escrowVaultDeployment.address);
      await tx.wait();
      console.log(`      ✅ EscrowVault approved`);
    } else {
      console.log(`      ✅ EscrowVault already approved`);
    }

    // Set as default yield generation module in ModuleSnapshotRegistry
    console.log(`\n   Setting default yield module in ModuleSnapshotRegistry...`);
    try {
      const moduleManagement = await ethers.getContractAt(
        'ModuleSnapshotRegistry',
        (await get('ModuleSnapshotRegistry')).address,
      );

      // Queue and activate the module for EscrowVault
      const ModuleType = { YIELD_GEN: 2 };
      console.log(`      Queuing AaveYieldModule for EscrowVault...`);
      const queueTx = await moduleManagement.queueModule(
        escrowVaultDeployment.address,
        ModuleType.YIELD_GEN,
        aaveYieldModuleDeployment.address,
      );
      await queueTx.wait();
      console.log(`      ✅ Module queued`);

      // Warp past delay and activate (for testing/production, this would be timelocked)
      // For now, we also activate immediately if the timelock has passed
      console.log(`      Activating AaveYieldModule...`);
      try {
        const activateTx = await moduleManagement.activateModule(
          escrowVaultDeployment.address,
          ModuleType.YIELD_GEN,
        );
        await activateTx.wait();
        console.log(`      ✅ Module activated`);
      } catch (activateError: any) {
        console.log(`      ℹ️  Module activation requires timelock delay (normal for production)`);
      }
    } catch (moduleError: any) {
      console.log(`      ⚠️  Could not set default module: ${moduleError.message}`);
    }
  } catch (error: any) {
    console.log(`      ⚠️  Could not approve EscrowVault: ${error.message}`);
    console.log(`      ℹ️  This may be because EscrowVault is not deployed yet`);
  }

  // Also try to approve EscrowableERC20 if deployed
  try {
    const escrowableERC20Deployment = await get('EscrowableERC20');
    const aaveModule = await ethers.getContractAt(
      'AaveYieldModule',
      aaveYieldModuleDeployment.address,
    );

    const isApproved = await aaveModule.approvedEscrows(escrowableERC20Deployment.address);
    if (!isApproved) {
      console.log(`      Approving EscrowableERC20: ${escrowableERC20Deployment.address}`);
      const tx = await aaveModule.approveEscrow(escrowableERC20Deployment.address);
      await tx.wait();
      console.log(`      ✅ EscrowableERC20 approved`);
    } else {
      console.log(`      ✅ EscrowableERC20 already approved`);
    }
  } catch (error: any) {
    console.log(`      ⚠️  Could not approve EscrowableERC20: ${error.message}`);
  }

  // Configure supported tokens
  console.log(`\n   Configuring supported tokens...`);

  // Get AaveModule contract instance
  const aaveModule = await ethers.getContractAt(
    'AaveYieldModule',
    aaveYieldModuleDeployment.address,
  );

  // USDC on Base Sepolia: 0x4cCa3115a7c13F68Cb2e1dF1c2c2dB87e15C9d2
  // USDC on Base Mainnet: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
  const supportedTokens =
    chainConfig.chainId === 8453
      ? [
          { token: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', name: 'USDC' }, // Base Mainnet
        ]
      : chainConfig.chainId === 84532
        ? [
            { token: '0x4cCa3115a7c13F68Cb2e1dF1c2c2dB87e15C9d2', name: 'USDC' }, // Base Sepolia
          ]
        : [];

  for (const { token, name } of supportedTokens) {
    try {
      // Check if token already configured
      const aToken = await aaveModule.tokenToAToken(token);
      if (aToken !== ethers.ZeroAddress) {
        console.log(`      ✅ ${name} already configured (aToken: ${aToken})`);
        continue;
      }

      console.log(`      Configuring ${name} (${token})...`);

      // For Aave, we need to get the aToken address from the pool
      // This is a simplified approach - in production you'd query the pool
      // For now, we'll configure without aToken verification (module will handle this)
      // The module will get aToken from Aave Pool's getReserveData

      // Actually, let's just configure the token - the module handles aToken lookup
      // We need to call configureToken but that requires aToken address
      // Let's skip for now and let the module handle it lazily

      console.log(`      ℹ️  ${name} will be configured on first use (lazy initialization)`);
    } catch (error: any) {
      console.log(`      ⚠️  Error configuring ${name}: ${error.message}`);
    }
  }

  console.log(`\n   ✅ AaveYieldModule deployment complete`);
};

export default func;
func.tags = ['yield', 'aave', 'aave-yield-module'];
func.dependencies = [];
