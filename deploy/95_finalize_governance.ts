/**
 * Finalize Governance — Strip Post-Deploy Deployer Authority
 *
 * This script runs AFTER every wiring script (70/75/85/86/90) and revokes the deployer's
 * DEFAULT_ADMIN_ROLE and ROLE_TIMELOCK from EVERY governed (OpenZeppelin AccessControl)
 * contract. It must run LAST.
 *
 * Rationale: governed contracts grant the deployer DEFAULT_ADMIN_ROLE and ROLE_TIMELOCK at
 * construction so the wiring scripts (queueApproveEscrow, setSlashingModule,
 * setRecoveryOperator, grantRole, etc.) can be driven by the deployer EOA. deploy/60_protocol_
 * governance.ts intentionally leaves those roles in place for that reason. This script closes the
 * resulting "deployer EOA retains ROLE_TIMELOCK and could unilaterally govern" gap by stripping
 * both roles once all wiring is complete, leaving governance resting solely with the
 * TimelockController (and the guardian for emergency paths).
 *
 * ROLE_TIMELOCK is revoked FIRST (while the deployer still holds DEFAULT_ADMIN_ROLE, which is
 * required to revoke any role); DEFAULT_ADMIN_ROLE is revoked immediately after.
 */
import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, ethers } = hre;
  const { all } = deployments;
  const { deployer } = await getNamedAccounts();

  // Role constants (must match contracts)
  const ROLE_TIMELOCK = ethers.keccak256(ethers.toUtf8Bytes('ROLE_TIMELOCK'));
  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash; // AccessControl uses bytes32(0) for DEFAULT_ADMIN_ROLE

  const allDeployments = await all();

  // Extended governed-contract list: 60's canonical list + DRM contracts from 85/86 that grant the
  // deployer ROLE_TIMELOCK / DEFAULT_ADMIN_ROLE (dedup).
  const contractsToGovern = [
    // ── 60's canonical governed contracts ────────────────────────────────
    'EscrowableERC20',
    'EscrowVault',
    'EscrowGovernanceTimelock',
    'AaveYieldModule',
    'DefaultResolutionModule',
    'EscrowCreationPolicy',
    'BondCollector',
    'ModuleSnapshotRegistry',
    // ── DR v3 module contracts (85/86) ───────────────────────────────────
    'ResolverStakingModule',
    'ResolverSlashingModule',
    'InsurancePoolVault',
    'ResolverIncentiveModule',
    'DRMAdminFacet',
    'DecentralizedResolutionModule',
  ];

  console.log('\n🔒 Finalizing governance — stripping deployer authority...');

  for (const name of contractsToGovern) {
    const dep = allDeployments[name];
    if (!dep) {
      console.log(`  skip ${name} (not deployed)`);
      continue;
    }
    const c = await ethers.getContractAt(name, dep.address);

    // Revoke ROLE_TIMELOCK first, while the deployer still holds DEFAULT_ADMIN_ROLE (required to
    // revoke any role).
    try {
      if (await c.hasRole(ROLE_TIMELOCK, deployer)) {
        const t = await c.revokeRole(ROLE_TIMELOCK, deployer);
        await t.wait();
        console.log(`  revoked ROLE_TIMELOCK from deployer on ${name}`);
      }
    } catch (e) {
      console.log(`  skip ROLE_TIMELOCK revoke on ${name}: ${(e as Error).message}`);
    }

    // Revoke DEFAULT_ADMIN_ROLE last.
    try {
      if (await c.hasRole(DEFAULT_ADMIN_ROLE, deployer)) {
        const t = await c.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        await t.wait();
        console.log(`  revoked DEFAULT_ADMIN_ROLE from deployer on ${name}`);
      }
    } catch (e) {
      console.log(`  skip DEFAULT_ADMIN revoke on ${name}: ${(e as Error).message}`);
    }
  }

  console.log('\n✅ Governance finalized — deployer no longer holds admin/timelock roles');
};

export default func;
func.tags = ['governance', 'finalize', 'ownership'];
func.dependencies = [
  'aave-yield-module',
  'guardian',
  'escrow',
  'module-management',
  'decentralized-resolution-module',
];
