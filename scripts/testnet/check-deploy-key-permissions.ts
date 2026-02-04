import hre from 'hardhat';
import { ethers } from 'ethers';

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var: ${name}`);
  return v;
}

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

async function main() {
  const provider = hre.ethers.provider;
  const { deployments } = hre;
  const net = await provider.getNetwork();

  const pk = process.env.SEPOLIA_DEPLOY_KEY || process.env.DEPLOYER_PRIVATE_KEY;
  if (!pk) {
    throw new Error('Missing env var: SEPOLIA_DEPLOY_KEY (or DEPLOYER_PRIVATE_KEY)');
  }
  const signer = new ethers.Wallet(pk, provider);
  const signerAddr = await signer.getAddress();

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const escrowAdminAddr = (await deployments.get('EscrowGovernanceTimelock')).address;
  const mmAddr = (await deployments.get('ModuleManagementContract')).address;

  console.log(`\n🔐 Deploy key permissions (Base Sepolia)`);
  console.log(`- chainId: ${net.chainId.toString()}`);
  console.log(`- signer: ${signerAddr}`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- EscrowGovernanceTimelock: ${escrowAdminAddr}`);
  console.log(`  - ${basescanAddressLink(escrowAdminAddr)}`);
  console.log(`- ModuleManagementContract: ${mmAddr}`);
  console.log(`  - ${basescanAddressLink(mmAddr)}`);

  async function inspectAccessControl(label: string, addr: string, extraRoles?: { name: string; value: string }[]) {
    const ac = await hre.ethers.getContractAt(
      [
        'function DEFAULT_ADMIN_ROLE() view returns (bytes32)',
        'function hasRole(bytes32,address) view returns (bool)',
        'function getRoleAdmin(bytes32) view returns (bytes32)',
      ],
      addr
    );

    const DEFAULT_ADMIN_ROLE = await ac.DEFAULT_ADMIN_ROLE();
    const hasDefaultAdmin = await ac.hasRole(DEFAULT_ADMIN_ROLE, signerAddr);

    console.log(`\n${label}`);
    console.log(`- address: ${addr}`);
    console.log(`- has DEFAULT_ADMIN_ROLE: ${hasDefaultAdmin}`);

    for (const r of extraRoles || []) {
      const role = r.value;
      const has = await ac.hasRole(role, signerAddr);
      const adminRole = await ac.getRoleAdmin(role);
      const canGrant = await ac.hasRole(adminRole, signerAddr);
      console.log(`- role ${r.name}: ${role}`);
      console.log(`  - hasRole: ${has}`);
      console.log(`  - adminRole: ${adminRole}`);
      console.log(`  - can grant/revoke this role: ${canGrant}`);
    }
  }

  // EscrowVault: ROLE_ADMIN_CONTRACT is what gates setResolutionModule
  const escrowVault = await hre.ethers.getContractAt(
    ['function ROLE_ADMIN_CONTRACT() view returns (bytes32)', 'function ROLE_TIMELOCK() view returns (bytes32)'],
    escrowVaultAddr
  );
  const ROLE_ADMIN_CONTRACT = await escrowVault.ROLE_ADMIN_CONTRACT();
  const ROLE_TIMELOCK = await escrowVault.ROLE_TIMELOCK();

  await inspectAccessControl('EscrowVault roles', escrowVaultAddr, [
    { name: 'ROLE_ADMIN_CONTRACT', value: ROLE_ADMIN_CONTRACT },
    { name: 'ROLE_TIMELOCK', value: ROLE_TIMELOCK },
  ]);

  // EscrowGovernanceTimelock: ROLE_TIMELOCK gates queue/activate, but does NOT need grantRole on EscrowVault
  const escrowAdmin = await hre.ethers.getContractAt(['function ROLE_TIMELOCK() view returns (bytes32)'], escrowAdminAddr);
  const ADMIN_ROLE_TIMELOCK = await escrowAdmin.ROLE_TIMELOCK();
  await inspectAccessControl('EscrowGovernanceTimelock roles', escrowAdminAddr, [
    { name: 'ROLE_TIMELOCK', value: ADMIN_ROLE_TIMELOCK },
  ]);

  // ModuleManagementContract: ROLE_TIMELOCK gates registerEscrowContract in that contract
  const mm = await hre.ethers.getContractAt(['function ROLE_TIMELOCK() view returns (bytes32)'], mmAddr);
  const MM_ROLE_TIMELOCK = await mm.ROLE_TIMELOCK();
  await inspectAccessControl('ModuleManagementContract roles', mmAddr, [{ name: 'ROLE_TIMELOCK', value: MM_ROLE_TIMELOCK }]);

  console.log(`\nInterpretation`);
  console.log(
    `- If signer can grant EscrowVault.ROLE_ADMIN_CONTRACT, then it can authorize an EOA to call EscrowVault.setResolutionModule().`
  );
  console.log(
    `- If signer has EscrowGovernanceTimelock.ROLE_TIMELOCK, it can queue slow-lane changes, but still must wait SLOW_DELAY on-chain.`
  );
}

main().catch((err) => {
  console.error(`\n❌ Permission check failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

