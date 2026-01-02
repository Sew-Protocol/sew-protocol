import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

/**
 * Wire TimelockController Roles
 * 
 * This script configures the TimelockController roles:
 * - Grant PROPOSER_ROLE to Governor (so Governor can queue proposals)
 * - Grant CANCELLER_ROLE to Governor (so Governor can cancel proposals)
 * - Set TIMELOCK_ADMIN_ROLE to Timelock itself (self-administered)
 * - Revoke deployer's admin role
 */
const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { get } = deployments;
  const { deployer } = await getNamedAccounts();

  const timelockDeployment = await get('TimelockController');
  const governorDeployment = await get('GovGovernor');

  const timelock = await ethers.getContractAt('TimelockController', timelockDeployment.address);
  const governor = await ethers.getContractAt('GovGovernor', governorDeployment.address);

  console.log(`\n🔗 Wiring TimelockController roles...`);
  console.log(`   Timelock: ${timelockDeployment.address}`);
  console.log(`   Governor: ${governorDeployment.address}`);

  // Get role constants
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const EXECUTOR_ROLE = await timelock.EXECUTOR_ROLE();
  const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
  const TIMELOCK_ADMIN_ROLE = await timelock.TIMELOCK_ADMIN_ROLE();

  // Check current roles
  const hasProposerRole = await timelock.hasRole(PROPOSER_ROLE, governorDeployment.address);
  const hasCancellerRole = await timelock.hasRole(CANCELLER_ROLE, governorDeployment.address);
  const hasAdminRole = await timelock.hasRole(TIMELOCK_ADMIN_ROLE, timelockDeployment.address);
  const deployerHasAdmin = await timelock.hasRole(TIMELOCK_ADMIN_ROLE, deployer);

  console.log(`\n📊 Current Role Status:`);
  console.log(`   Governor has PROPOSER_ROLE: ${hasProposerRole}`);
  console.log(`   Governor has CANCELLER_ROLE: ${hasCancellerRole}`);
  console.log(`   Timelock has TIMELOCK_ADMIN_ROLE: ${hasAdminRole}`);
  console.log(`   Deployer has TIMELOCK_ADMIN_ROLE: ${deployerHasAdmin}`);

  // Grant PROPOSER_ROLE to Governor
  if (!hasProposerRole) {
    console.log(`\n   Granting PROPOSER_ROLE to Governor...`);
    const tx1 = await timelock.grantRole(PROPOSER_ROLE, governorDeployment.address);
    await tx1.wait();
    console.log(`   ✅ PROPOSER_ROLE granted`);
  } else {
    console.log(`   ✅ Governor already has PROPOSER_ROLE`);
  }

  // Grant CANCELLER_ROLE to Governor
  if (!hasCancellerRole) {
    console.log(`\n   Granting CANCELLER_ROLE to Governor...`);
    const tx2 = await timelock.grantRole(CANCELLER_ROLE, governorDeployment.address);
    await tx2.wait();
    console.log(`   ✅ CANCELLER_ROLE granted`);
  } else {
    console.log(`   ✅ Governor already has CANCELLER_ROLE`);
  }

  // Set TIMELOCK_ADMIN_ROLE to Timelock itself (self-administered)
  if (!hasAdminRole) {
    console.log(`\n   Setting TIMELOCK_ADMIN_ROLE to Timelock itself...`);
    const tx3 = await timelock.grantRole(TIMELOCK_ADMIN_ROLE, timelockDeployment.address);
    await tx3.wait();
    console.log(`   ✅ Timelock is now self-administered`);
  } else {
    console.log(`   ✅ Timelock already has TIMELOCK_ADMIN_ROLE`);
  }

  // Revoke deployer's admin role
  if (deployerHasAdmin) {
    console.log(`\n   Revoking deployer's TIMELOCK_ADMIN_ROLE...`);
    const tx4 = await timelock.revokeRole(TIMELOCK_ADMIN_ROLE, deployer);
    await tx4.wait();
    console.log(`   ✅ Deployer admin role revoked`);
  } else {
    console.log(`   ✅ Deployer already doesn't have TIMELOCK_ADMIN_ROLE`);
  }

  // Verify final state
  console.log(`\n✅ Timelock role wiring complete!`);
  console.log(`\n📊 Final Role Status:`);
  console.log(`   Governor has PROPOSER_ROLE: ${await timelock.hasRole(PROPOSER_ROLE, governorDeployment.address)}`);
  console.log(`   Governor has CANCELLER_ROLE: ${await timelock.hasRole(CANCELLER_ROLE, governorDeployment.address)}`);
  console.log(`   Timelock has TIMELOCK_ADMIN_ROLE: ${await timelock.hasRole(TIMELOCK_ADMIN_ROLE, timelockDeployment.address)}`);
  console.log(`   Deployer has TIMELOCK_ADMIN_ROLE: ${await timelock.hasRole(TIMELOCK_ADMIN_ROLE, deployer)}`);
};

export default func;
func.tags = ['timelock-wiring', 'governance'];
func.dependencies = ['governor'];

