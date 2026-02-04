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
  const settlementOpsDeployment = await get('SettlementOps');
  const createOpsDeployment = await get('CreateOps');
  const bondCollectorDeployment = await get('BondCollector');
  const moduleManagementDeployment = await get('ModuleSnapshotRegistry');
  const escrowAdminDeployment = await get('EscrowGovernanceTimelock');

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
  console.log(`      SettlementOps: ${settlementOpsDeployment.address}`);
  console.log(`      CreateOps: ${createOpsDeployment.address}`);
  console.log(`      BondCollector: ${bondCollectorDeployment.address}`);
  console.log(`      ModuleManagement: ${moduleManagementDeployment.address}`);
  console.log(`      EscrowGovernanceTimelock: ${escrowAdminDeployment.address}`);

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
      moduleManagementDeployment.address, // moduleManagement
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
          moduleManagementDeployment.address,
        ],
        tags: ['core', 'escrow'],
      });
    }
  } else {
    console.log(`   ✅ EscrowVault already deployed at: ${escrowVaultDeployment.address}`);
  }

  // Register EscrowVault with all ops contracts
  console.log(`\n   Registering EscrowVault with ops contracts...`);
  const escrowVaultContract = await ethers.getContractAt('EscrowVault', escrowVaultDeployment.address);
  
  // Get ops contracts
  const createOpsContract = await ethers.getContractAt('CreateOps', createOpsDeployment.address);
  const settlementOpsContract = await ethers.getContractAt('SettlementOps', settlementOpsDeployment.address);
  const disputeOpsContract = await ethers.getContractAt('DisputeOps', disputeOpsDeployment.address);
  const yieldOpsContract = await ethers.getContractAt('YieldOps', yieldOpsDeployment.address);
  const bondCollectorContract = await ethers.getContractAt('BondCollector', bondCollectorDeployment.address);

  // Register with CreateOps
  try {
    const createOpsTx = await createOpsContract.registerEscrowContract(escrowVaultDeployment.address);
    await createOpsTx.wait();
    console.log(`   ✅ Registered EscrowVault with CreateOps`);
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
      console.log(`   ℹ️  EscrowVault already registered with CreateOps`);
    } else {
      throw error;
    }
  }

  // Register with SettlementOps
  try {
    const settlementOpsTx = await settlementOpsContract.registerEscrowContract(escrowVaultDeployment.address);
    await settlementOpsTx.wait();
    console.log(`   ✅ Registered EscrowVault with SettlementOps`);
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
      console.log(`   ℹ️  EscrowVault already registered with SettlementOps`);
    } else {
      throw error;
    }
  }

  // Register with DisputeOps
  try {
    const disputeOpsTx = await disputeOpsContract.registerEscrowContract(escrowVaultDeployment.address);
    await disputeOpsTx.wait();
    console.log(`   ✅ Registered EscrowVault with DisputeOps`);
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
      console.log(`   ℹ️  EscrowVault already registered with DisputeOps`);
    } else {
      throw error;
    }
  }

  // Register with YieldOps
  try {
    const yieldOpsTx = await yieldOpsContract.registerEscrowContract(escrowVaultDeployment.address);
    await yieldOpsTx.wait();
    console.log(`   ✅ Registered EscrowVault with YieldOps`);
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
      console.log(`   ℹ️  EscrowVault already registered with YieldOps`);
    } else {
      throw error;
    }
  }

  // Register with BondCollector
  try {
    const bondCollectorTx = await bondCollectorContract.registerEscrowContract(escrowVaultDeployment.address);
    await bondCollectorTx.wait();
    console.log(`   ✅ Registered EscrowVault with BondCollector`);
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
      console.log(`   ℹ️  EscrowVault already registered with BondCollector`);
    } else {
      throw error;
    }
  }

  // Grant EscrowGovernanceTimelock the minimal admin role on EscrowVault (for slow-lane apply).
  console.log(`\n   Granting ROLE_ADMIN_CONTRACT to EscrowGovernanceTimelock...`);
  try {
    const ADMIN_CONTRACT_ROLE = await escrowVaultContract.ROLE_ADMIN_CONTRACT();
    const hasRole = await escrowVaultContract.hasRole(ADMIN_CONTRACT_ROLE, escrowAdminDeployment.address);
    if (!hasRole) {
      const grantTx = await escrowVaultContract.grantRole(ADMIN_CONTRACT_ROLE, escrowAdminDeployment.address);
      await grantTx.wait();
      console.log(`   ✅ ROLE_ADMIN_CONTRACT granted to EscrowGovernanceTimelock`);
    } else {
      console.log(`   ✅ EscrowGovernanceTimelock already has ROLE_ADMIN_CONTRACT`);
    }
  } catch (error: any) {
    console.log(`   ⚠️  Could not grant ROLE_ADMIN_CONTRACT (non-fatal): ${error.message}`);
  }

  // Set ops contracts in EscrowVault (governance-controlled wiring).
  console.log(`\n   Setting ops contracts in EscrowVault...`);
  try {
    // NOTE: Make wiring idempotent. Only send txs if the value differs.
    const currentCreateOps = await escrowVaultContract.createOps();
    if (currentCreateOps.toLowerCase() !== createOpsDeployment.address.toLowerCase()) {
      const setCreateOpsTx = await escrowVaultContract.setCreateOps(createOpsDeployment.address);
      await setCreateOpsTx.wait();
      console.log(`   ✅ Set CreateOps in EscrowVault`);
    } else {
      console.log(`   ✅ CreateOps already set in EscrowVault`);
    }

    const currentSettlementOps = await escrowVaultContract.settlementOps();
    if (currentSettlementOps.toLowerCase() !== settlementOpsDeployment.address.toLowerCase()) {
      const setSettlementOpsTx = await escrowVaultContract.setSettlementOps(settlementOpsDeployment.address);
      await setSettlementOpsTx.wait();
      console.log(`   ✅ Set SettlementOps in EscrowVault`);
    } else {
      console.log(`   ✅ SettlementOps already set in EscrowVault`);
    }

    const currentBondCollector = await escrowVaultContract.bondCollector();
    if (currentBondCollector.toLowerCase() !== bondCollectorDeployment.address.toLowerCase()) {
      const setBondCollectorTx = await escrowVaultContract.setBondCollector(bondCollectorDeployment.address);
      await setBondCollectorTx.wait();
      console.log(`   ✅ Set BondCollector in EscrowVault`);
    } else {
      console.log(`   ✅ BondCollector already set in EscrowVault`);
    }
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount')) {
      console.log(`   ℹ️  Deployer does not have permission to set ops contracts.`);
    } else {
      throw error;
    }
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
        moduleManagementDeployment.address, // moduleManagement
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
            moduleManagementDeployment.address,
          ],
          tags: ['core', 'escrow', 'token'],
        });
      }
    } else {
      console.log(`   ✅ EscrowableERC20 already deployed at: ${escrowableERC20Deployment.address}`);
    }

    // Register EscrowableERC20 with all ops contracts
    console.log(`\n   Registering EscrowableERC20 with ops contracts...`);
    const escrowableERC20Contract = await ethers.getContractAt('EscrowableERC20', escrowableERC20Deployment.address);

    // Register with CreateOps
    try {
      const createOpsTx = await createOpsContract.registerEscrowContract(escrowableERC20Deployment.address);
      await createOpsTx.wait();
      console.log(`   ✅ Registered EscrowableERC20 with CreateOps`);
    } catch (error: any) {
      if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
        console.log(`   ℹ️  EscrowableERC20 already registered with CreateOps`);
      } else {
        throw error;
      }
    }

    // Register with SettlementOps
    try {
      const settlementOpsTx = await settlementOpsContract.registerEscrowContract(escrowableERC20Deployment.address);
      await settlementOpsTx.wait();
      console.log(`   ✅ Registered EscrowableERC20 with SettlementOps`);
    } catch (error: any) {
      if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
        console.log(`   ℹ️  EscrowableERC20 already registered with SettlementOps`);
      } else {
        throw error;
      }
    }

    // Register with DisputeOps
    try {
      const disputeOpsTx = await disputeOpsContract.registerEscrowContract(escrowableERC20Deployment.address);
      await disputeOpsTx.wait();
      console.log(`   ✅ Registered EscrowableERC20 with DisputeOps`);
    } catch (error: any) {
      if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
        console.log(`   ℹ️  EscrowableERC20 already registered with DisputeOps`);
      } else {
        throw error;
      }
    }

    // Register with YieldOps
    try {
      const yieldOpsTx = await yieldOpsContract.registerEscrowContract(escrowableERC20Deployment.address);
      await yieldOpsTx.wait();
      console.log(`   ✅ Registered EscrowableERC20 with YieldOps`);
    } catch (error: any) {
      if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
        console.log(`   ℹ️  EscrowableERC20 already registered with YieldOps`);
      } else {
        throw error;
      }
    }

    // Register with BondCollector
    try {
      const bondCollectorTx = await bondCollectorContract.registerEscrowContract(escrowableERC20Deployment.address);
      await bondCollectorTx.wait();
      console.log(`   ✅ Registered EscrowableERC20 with BondCollector`);
    } catch (error: any) {
      if (error.message?.includes('AccessControlUnauthorizedAccount') || error.message?.includes('already has role')) {
        console.log(`   ℹ️  EscrowableERC20 already registered with BondCollector`);
      } else {
        throw error;
      }
    }

    // Set ops contracts in EscrowableERC20 (via admin contract or directly if deployer has role)
    console.log(`\n   Setting ops contracts in EscrowableERC20...`);
    try {
      // Check if deployer has ROLE_ADMIN_CONTRACT
      const ADMIN_CONTRACT_ROLE = await escrowableERC20Contract.ROLE_ADMIN_CONTRACT();
      const hasAdminRole = await escrowableERC20Contract.hasRole(ADMIN_CONTRACT_ROLE, deployer);
      
      if (hasAdminRole) {
        // Set CreateOps
        const setCreateOpsTx = await escrowableERC20Contract.setCreateOps(createOpsDeployment.address);
        await setCreateOpsTx.wait();
        console.log(`   ✅ Set CreateOps in EscrowableERC20`);

        // Set SettlementOps
        const setSettlementOpsTx = await escrowableERC20Contract.setSettlementOps(settlementOpsDeployment.address);
        await setSettlementOpsTx.wait();
        console.log(`   ✅ Set SettlementOps in EscrowableERC20`);

        // Set BondCollector
        const setBondCollectorTx = await escrowableERC20Contract.setBondCollector(bondCollectorDeployment.address);
        await setBondCollectorTx.wait();
        console.log(`   ✅ Set BondCollector in EscrowableERC20`);
      } else {
        console.log(`   ℹ️  Deployer does not have ROLE_ADMIN_CONTRACT. Ops contracts must be set via EscrowGovernanceTimelock.`);
      }
    } catch (error: any) {
      if (error.message?.includes('AccessControlUnauthorizedAccount')) {
        console.log(`   ℹ️  Deployer does not have permission to set ops contracts. Must be set via EscrowGovernanceTimelock.`);
      } else {
        throw error;
      }
    }
  } else {
    console.log(`\n   ℹ️  EscrowableERC20 deployment skipped (set DEPLOY_ESCROWABLE_ERC20=true to deploy)`);
  }
};

export default func;
func.tags = ['core', 'escrow'];
func.dependencies = [
  'yield-ops',
  'dispute-ops',
  'settlement-ops',
  'create-ops',
  'bond-collector',
  'module-management',
];
