/**
 * Deploy GuardianOps + EmergencyRecoveryProposal
 *
 * Emergency-recovery wiring. There is no dedicated deploy script for the emergency
 * unwind path, so in production GuardianOps was never registered as a recovery operator
 * and the emergency unwind would revert UnauthorizedEscrow. This mirrors the wiring in
 * test/foundry/governance/EmergencyRecoveryFlowTest.sol setUp (quote-order):
 *
 * 1. Deploy GuardianOps bound to the escrow vault (immutable escrowContract).
 * 2. Register GuardianOps as a recovery operator on AaveYieldModule
 *    (setRecoveryOperator(address, true), sent by the deployer, who holds ROLE_TIMELOCK from
 *     the module constructor). The module uses OpenZeppelin AccessControl: 75's constructor
 *     grants the deployer DEFAULT_ADMIN_ROLE and ROLE_TIMELOCK, and setRecoveryOperator is
 *     gated by onlyRole(ROLE_TIMELOCK). Actual governance (transferring ROLE_TIMELOCK and
 *     DEFAULT_ADMIN_ROLE to the TimelockController) is handled by deploy/60_protocol_governance.ts.
 * 3. Deploy EmergencyRecoveryProposal bound to (escrowVault, guardianOps, admin).
 * 4. Enable recovery on the proposal (setRecoveryEnabled(true), admin-gated).
 * 5. Grant the vault's ROLE_GUARDIAN to the guardian multisig AND to the
 *    EmergencyRecoveryProposal contract (so the recovery path can authenticate against
 *    GuardianOps via the vault).
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';
import { getGovConfig } from './_config';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);
  const config = getGovConfig(hre);

  console.log(`\n📦 Deploying GuardianOps + EmergencyRecoveryProposal...`);

  // Resolve the escrow vault (prioritize EscrowVault, fall back to EscrowableERC20 like 75).
  let vaultDeployment;
  try {
    vaultDeployment = await get('EscrowVault');
  } catch {
    vaultDeployment = await get('EscrowableERC20');
  }
  const vaultAddress = vaultDeployment.address;

  // Governance executor / proposal admin (mirror how 60 wires roles to TimelockController).
  const timelockDeployment = await get('TimelockController');
  const adminAddress = timelockDeployment.address;

  // Guardian multisig from config, falling back to the Safe deployment, then Timelock
  // (mirror deploy/60_protocol_governance.ts).
  let safeDeployment;
  try {
    safeDeployment = await get('GuardianSafe');
  } catch (error: any) {
    console.log('   ℹ️  GuardianSafe deployment not found (this is OK if Safe was not deployed)');
    safeDeployment = null;
  }
  const guardianMultisig =
    config.guardian.multisig || safeDeployment?.address || timelockDeployment.address;

  // AaveYieldModule (deployer holds ROLE_TIMELOCK + DEFAULT_ADMIN_ROLE from 75's constructor; setRecoveryOperator is onlyRole(ROLE_TIMELOCK)).
  const aaveModuleDeployment = await get('AaveYieldModule');
  const aaveModule = await ethers.getContractAt(
    'AaveYieldModule',
    aaveModuleDeployment.address,
  );

  // 1. Deploy GuardianOps bound to the escrow vault
  console.log(`\n   Deploying GuardianOps (bound to ${vaultAddress})...`);
  const guardianOpsDeployment = await deploy('GuardianOps', {
    contract: 'GuardianOps',
    from: deployer,
    args: [vaultAddress],
    log: true,
  });

  if (guardianOpsDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, guardianOpsDeployment.address);
    console.log(`   ✅ GuardianOps deployed at: ${guardianOpsDeployment.address}`);
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (guardianOpsDeployment.receipt) {
      await registerDeployment(hre, 'GuardianOps', {
        address: guardianOpsDeployment.address,
        txHash: guardianOpsDeployment.transactionHash,
        blockNumber: guardianOpsDeployment.receipt.blockNumber,
        constructorArgs: [vaultAddress],
        tags: ['guardian', 'emergency', 'yield', 'aave'],
      });
    }
  } else {
    console.log(`   ✅ GuardianOps already deployed at: ${guardianOpsDeployment.address}`);
  }

  // 2. Register GuardianOps as a recovery operator on AaveYieldModule.
  //    Sent by the deployer, who holds ROLE_TIMELOCK (granted by 75's constructor), since
  //    setRecoveryOperator is gated by onlyRole(ROLE_TIMELOCK).
  console.log(`\n   Registering GuardianOps as recovery operator on AaveYieldModule...`);
  try {
    const isOperator = await aaveModule.recoveryOperators(guardianOpsDeployment.address);
    if (!isOperator) {
      const setOpTx = await aaveModule.setRecoveryOperator(guardianOpsDeployment.address, true);
      await setOpTx.wait();
      console.log(`   ✅ GuardianOps registered as recovery operator`);
    } else {
      console.log(`   ✅ GuardianOps already a recovery operator`);
    }
  } catch (error: any) {
    if (
      error.message?.includes('AccessControlUnauthorizedAccount') ||
      error.message?.includes('caller is not the owner')
    ) {
      console.log(`   ⚠️  Could not set recovery operator: deployer lacks ROLE_TIMELOCK on the Aave yield module`);
    } else {
      throw error;
    }
  }

  // 3. Deploy EmergencyRecoveryProposal bound to (escrowVault, guardianOps, admin)
  console.log(`\n   Deploying EmergencyRecoveryProposal...`);
  const recoveryProposalDeployment = await deploy('EmergencyRecoveryProposal', {
    contract: 'EmergencyRecoveryProposal',
    from: deployer,
    args: [vaultAddress, guardianOpsDeployment.address, adminAddress],
    log: true,
  });

  if (recoveryProposalDeployment.newlyDeployed) {
    const explorerUrl = getBlockExplorerUrl(hre, recoveryProposalDeployment.address);
    console.log(
      `   ✅ EmergencyRecoveryProposal deployed at: ${recoveryProposalDeployment.address}`,
    );
    if (explorerUrl) {
      console.log(`      📊 View on ${chainConfig.blockExplorer.name}: ${explorerUrl}`);
    }

    if (recoveryProposalDeployment.receipt) {
      await registerDeployment(hre, 'EmergencyRecoveryProposal', {
        address: recoveryProposalDeployment.address,
        txHash: recoveryProposalDeployment.transactionHash,
        blockNumber: recoveryProposalDeployment.receipt.blockNumber,
        constructorArgs: [vaultAddress, guardianOpsDeployment.address, adminAddress],
        tags: ['guardian', 'emergency', 'recovery', 'governance'],
      });
    }
  } else {
    console.log(
      `   ✅ EmergencyRecoveryProposal already deployed at: ${recoveryProposalDeployment.address}`,
    );
  }

  const recoveryProposal = await ethers.getContractAt(
    'EmergencyRecoveryProposal',
    recoveryProposalDeployment.address,
  );

  // 4. Enable recovery on the proposal (admin-gated)
  console.log(`\n   Enabling recovery on EmergencyRecoveryProposal...`);
  try {
    const isEnabled = await recoveryProposal.recoveryEnabled();
    if (!isEnabled) {
      const enableTx = await recoveryProposal.setRecoveryEnabled(true);
      await enableTx.wait();
      console.log(`   ✅ Recovery enabled`);
    } else {
      console.log(`   ✅ Recovery already enabled`);
    }
  } catch (error: any) {
    if (error.message?.includes('AccessControlUnauthorizedAccount')) {
      console.log(`   ⚠️  Could not enable recovery: caller is not the proposal admin`);
    } else {
      throw error;
    }
  }

  // 5. Grant the vault's ROLE_GUARDIAN to the guardian multisig and to the proposal
  //    (so GuardianOps.emergencyUnwindAavePosition can authenticate against the vault).
  console.log(`\n   Granting ROLE_GUARDIAN on vault...`);
  const vault = await ethers.getContractAt('EscrowVault', vaultAddress);
  try {
    const ROLE_GUARDIAN = await vault.ROLE_GUARDIAN();

    const guardiansToGrant = [guardianMultisig, recoveryProposalDeployment.address].filter(
      (addr): addr is string => !!addr && addr !== ethers.ZeroAddress,
    );

    for (const grantee of guardiansToGrant) {
      try {
        const hasRole = await vault.hasRole(ROLE_GUARDIAN, grantee);
        if (!hasRole) {
          console.log(`      Granting ROLE_GUARDIAN to ${grantee}...`);
          const grantTx = await vault.grantRole(ROLE_GUARDIAN, grantee);
          await grantTx.wait();
          console.log(`      ✅ ROLE_GUARDIAN granted to ${grantee}`);
        } else {
          console.log(`      ✅ ${grantee} already has ROLE_GUARDIAN`);
        }
      } catch (error: any) {
        console.log(`      ⚠️  Could not grant ROLE_GUARDIAN to ${grantee}: ${error.message}`);
      }
    }
  } catch (error: any) {
    console.log(`   ⚠️  Could not grant ROLE_GUARDIAN on vault (non-fatal): ${error.message}`);
  }

  console.log(`\n   ✅ GuardianOps + EmergencyRecoveryProposal deployment complete`);
};

export default func;
func.tags = ['aave', 'yield', 'guardian', 'emergency'];
func.dependencies = ['aave-yield-module', 'escrow', 'timelock'];
