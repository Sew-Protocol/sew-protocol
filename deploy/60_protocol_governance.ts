import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { getGovConfig, validateGovConfig } from './_config';

/**
 * Transfer Protocol Ownership to Governance
 * 
 * This script transfers ownership and grants roles to governance:
 * - Transfer ownership of Ownable contracts to Timelock
 * - Grant ROLE_TIMELOCK to Timelock (for AccessControl contracts)
 * - Grant ROLE_GUARDIAN to Guardian multisig
 * - Revoke deployer roles
 * 
 * Note: This assumes contracts will be migrated to AccessControl in Phase 2.
 * For now, we only transfer ownership of Ownable contracts.
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { get } = deployments;
  const { deployer } = await getNamedAccounts();
  
  const config = getGovConfig(hre);
  validateGovConfig(config, hre);

  const timelockDeployment = await get('TimelockController');
  const timelock = await ethers.getContractAt('TimelockController', timelockDeployment.address);

  console.log(`\n🔐 Transferring protocol ownership to governance...`);
  console.log(`   Timelock: ${timelockDeployment.address}`);
  console.log(`   Guardian: ${config.guardian.multisig || 'Not configured'}`);

  // List of contracts that use Ownable (will be migrated to AccessControl in Phase 2)
  const ownableContracts = [
    'EscrowableERC20',
    'EscrowVault',
    'BaseEscrow',
  ];

  let transferredCount = 0;
  let skippedCount = 0;

  for (const contractName of ownableContracts) {
    try {
      const deployment = await get(contractName);
      if (!deployment || !deployment.address) {
        console.log(`   ⚠️  ${contractName} not deployed, skipping`);
        skippedCount++;
        continue;
      }

      const contract = await ethers.getContractAt(contractName, deployment.address);
      
      // Check if contract has owner() function
      try {
        const currentOwner = await contract.owner();
        console.log(`\n   📋 ${contractName}:`);
        console.log(`      Current owner: ${currentOwner}`);
        
        if (currentOwner.toLowerCase() === timelockDeployment.address.toLowerCase()) {
          console.log(`      ✅ Already owned by Timelock`);
          skippedCount++;
          continue;
        }

        if (currentOwner.toLowerCase() === deployer.toLowerCase()) {
          console.log(`      Transferring to Timelock...`);
          const tx = await contract.transferOwnership(timelockDeployment.address);
          await tx.wait();
          console.log(`      ✅ Ownership transferred to Timelock`);
          transferredCount++;
        } else {
          console.log(`      ⚠️  Owned by ${currentOwner}, not transferring`);
          skippedCount++;
        }
      } catch (error: any) {
        // Contract might not have owner() function or might use AccessControl
        console.log(`      ⚠️  ${contractName} doesn't use Ownable or has different access control`);
        skippedCount++;
      }
    } catch (error: any) {
      console.log(`   ⚠️  Error processing ${contractName}: ${error.message}`);
      skippedCount++;
    }
  }

  // Grant Guardian role (if configured and contracts support AccessControl)
  if (config.guardian.multisig && config.guardian.multisig !== ethers.ZeroAddress) {
    console.log(`\n   🛡️  Guardian multisig configured: ${config.guardian.multisig}`);
    console.log(`      Note: Guardian roles will be granted in Phase 2 (AccessControl migration)`);
  }

  console.log(`\n✅ Protocol ownership transfer complete!`);
  console.log(`   Transferred: ${transferredCount}`);
  console.log(`   Skipped: ${skippedCount}`);
  console.log(`\n   ⚠️  Note: Full role-based access control will be implemented in Phase 2`);
};

export default func;
func.tags = ['governance', 'ownership'];
func.dependencies = ['timelock', 'governor'];

