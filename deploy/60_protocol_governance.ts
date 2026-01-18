import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig } from './_config';

/**
 * Grant Protocol Roles to Governance
 *
 * This script grants AccessControl roles to governance:
 * - Grant ROLE_TIMELOCK to TimelockController (for Standard/Slow functions)
 * - Grant ROLE_GUARDIAN to Guardian multisig (for Emergency functions)
 * - Grant DEFAULT_ADMIN_ROLE to TimelockController
 * - Revoke deployer roles
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { get, all } = deployments;
  const { deployer } = await getNamedAccounts();

  const config = getGovConfig(hre);

  console.log('\n🔄 Granting protocol roles to governance...');

  const timelockDeployment = await get('TimelockController');
  
  // Safe deployment is optional (skipped if @safe-global/safe-contracts not installed)
  let safeDeployment;
  try {
    safeDeployment = await get('GuardianSafe');
  } catch (error: any) {
    console.log('   ℹ️  GuardianSafe deployment not found (this is OK if Safe was not deployed)');
    safeDeployment = null;
  }
  
  const guardianMultisig = config.guardian.multisig || safeDeployment?.address || timelockDeployment.address;

  // Role constants (must match contracts)
  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));
  const ROLE_GUARDIAN = ethers.keccak256(ethers.toUtf8Bytes('ROLE_GUARDIAN'));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroAddress; // AccessControl uses 0x00 for DEFAULT_ADMIN_ROLE

  const allDeployments = await all();
  const contractsToGovern = [
    'EscrowableERC20',
    'EscrowVault',
    'EscrowAdminContract',
    'AaveYieldGenerationModule',
    'DefaultResolutionModule',
    // Ops contracts
    'CreateOps', // Has ROLE_TIMELOCK and ROLE_GUARDIAN for yield deposits control
    'SettlementOps',
    'DisputeOps',
    'YieldOps', // Has ROLE_TIMELOCK and ROLE_GUARDIAN
    'BondCollector',
    'ModuleManagementContract',
    // DecentralizedResolutionModule is in separate package
    // Add other AccessControl contracts as they are deployed
  ];

  let rolesGranted = 0;
  let rolesSkipped = 0;

  for (const contractName of contractsToGovern) {
    const deployment = allDeployments[contractName];
    if (!deployment) {
      console.log(`   ⚠️  Contract ${contractName} not found in deployments, skipping.`);
      rolesSkipped++;
      continue;
    }

    try {
      const contract = await ethers.getContractAt(contractName, deployment.address);
      console.log(`\n   📋 ${contractName} (${deployment.address}):`);

      // Check if contract has AccessControl roles
      try {
        // Check if contract supports ROLE_TIMELOCK (not all contracts have it)
        let hasTimelockSupport = false;
        try {
          await contract.ROLE_TIMELOCK();
          hasTimelockSupport = true;
        } catch {
          // Contract doesn't have ROLE_TIMELOCK, skip
        }

        // Grant ROLE_TIMELOCK to TimelockController (if contract supports it)
        if (hasTimelockSupport) {
          const hasTimelockRole = await contract.hasRole(ROLE_TIMELOCK, timelockDeployment.address);
          if (!hasTimelockRole) {
            console.log(`      Granting ROLE_TIMELOCK to TimelockController...`);
            const tx1 = await contract.grantRole(ROLE_TIMELOCK, timelockDeployment.address);
            await tx1.wait();
            console.log(`      ✅ ROLE_TIMELOCK granted`);
            rolesGranted++;
          } else {
            console.log(`      ✅ TimelockController already has ROLE_TIMELOCK`);
          }
        }

        // Check if contract supports ROLE_GUARDIAN (not all contracts have it)
        let hasGuardianSupport = false;
        try {
          await contract.ROLE_GUARDIAN();
          hasGuardianSupport = true;
        } catch {
          // Contract doesn't have ROLE_GUARDIAN, skip
        }

        // Grant ROLE_GUARDIAN to Guardian multisig (if contract supports it)
        if (hasGuardianSupport) {
          const hasGuardianRole = await contract.hasRole(ROLE_GUARDIAN, guardianMultisig);
          if (!hasGuardianRole) {
            console.log(`      Granting ROLE_GUARDIAN to Guardian (${guardianMultisig})...`);
            const tx2 = await contract.grantRole(ROLE_GUARDIAN, guardianMultisig);
            await tx2.wait();
            console.log(`      ✅ ROLE_GUARDIAN granted`);
            rolesGranted++;
          } else {
            console.log(`      ✅ Guardian already has ROLE_GUARDIAN`);
          }
        }

        // Revoke DEFAULT_ADMIN_ROLE from deployer (if deployer has it)
        const deployerHasAdmin = await contract.hasRole(DEFAULT_ADMIN_ROLE, deployer);
        if (deployerHasAdmin) {
          // Grant DEFAULT_ADMIN_ROLE to TimelockController first
          const timelockHasAdmin = await contract.hasRole(
            DEFAULT_ADMIN_ROLE,
            timelockDeployment.address,
          );
          if (!timelockHasAdmin) {
            console.log(`      Granting DEFAULT_ADMIN_ROLE to TimelockController...`);
            const tx3 = await contract.grantRole(DEFAULT_ADMIN_ROLE, timelockDeployment.address);
            await tx3.wait();
            console.log(`      ✅ DEFAULT_ADMIN_ROLE granted to TimelockController`);
            rolesGranted++;
          }

          // Revoke deployer's DEFAULT_ADMIN_ROLE
          console.log(`      Revoking DEFAULT_ADMIN_ROLE from deployer...`);
          const tx4 = await contract.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
          await tx4.wait();
          console.log(`      ✅ Deployer's DEFAULT_ADMIN_ROLE revoked`);
          rolesGranted++;
        } else {
          console.log(`      ✅ Deployer does not have DEFAULT_ADMIN_ROLE`);
        }
      } catch (error: any) {
        // Contract might not have AccessControl
        console.log(`      ⚠️  Contract does not support AccessControl: ${error.message}`);
        rolesSkipped++;
      }
    } catch (error: any) {
      console.log(`      ⚠️  Error processing ${contractName}: ${error.message}`);
      rolesSkipped++;
    }
  }

  console.log('\n✅ Protocol role grants complete!');
  console.log(`   Roles granted: ${rolesGranted}`);
  console.log(`   Contracts skipped: ${rolesSkipped}`);
};

export default func;
func.tags = ['governance', 'ownership'];
func.dependencies = ['timelock', 'governor', 'safe', 'escrow-admin'];
