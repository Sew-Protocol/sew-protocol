import hre from 'hardhat';
import { ethers } from 'ethers';

function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

async function main() {
  const { deployments } = hre;
  const provider = hre.ethers.provider;
  const net = await provider.getNetwork();

  const escrowVaultAddr = (await deployments.get('EscrowVault')).address;
  const moduleMgmtAddr = (await deployments.get('ModuleManagementContract')).address;
  const escrowAdminAddr = (await deployments.get('EscrowAdminContract')).address;
  const timelockAddr = (await deployments.get('TimelockController')).address;

  const escrow: any = await hre.ethers.getContractAt('EscrowVault', escrowVaultAddr);
  const mm: any = await hre.ethers.getContractAt('ModuleManagementContract', moduleMgmtAddr);
  const admin: any = await hre.ethers.getContractAt('EscrowAdminContract', escrowAdminAddr);

  const resolutionModule = await escrow.disputeResolutionModule();
  const defaultResolutionModule = await mm.getDefaultModule(escrowVaultAddr, 0); // ModuleType.RESOLUTION = 0

  console.log(`\n🔎 Resolution module status`);
  console.log(`- chainId: ${net.chainId.toString()}`);
  console.log(`- EscrowVault: ${escrowVaultAddr}`);
  console.log(`  - ${basescanAddressLink(escrowVaultAddr)}`);
  console.log(`- ModuleManagementContract: ${moduleMgmtAddr}`);
  console.log(`  - ${basescanAddressLink(moduleMgmtAddr)}`);
  console.log(`- EscrowAdminContract: ${escrowAdminAddr}`);
  console.log(`  - ${basescanAddressLink(escrowAdminAddr)}`);
  console.log(`- TimelockController: ${timelockAddr}`);
  console.log(`  - ${basescanAddressLink(timelockAddr)}`);

  console.log(`\nWiring`);
  console.log(`- EscrowVault.disputeResolutionModule: ${resolutionModule}`);
  console.log(`- ModuleManagement default RESOLUTION: ${defaultResolutionModule}`);

  try {
    const pending = await admin.getPendingResolutionModule(escrowVaultAddr);
    console.log(`- EscrowAdminContract pending resolution module:`, pending);
  } catch (e: any) {
    console.log(`- Could not read EscrowAdminContract.getPendingResolutionModule: ${e?.message || e}`);
  }

  // Role wiring checks (best-effort; some contracts may not expose the role constants)
  try {
    const roleAdminContract = await escrow.ROLE_ADMIN_CONTRACT();
    const hasAdminContract = await escrow.hasRole(roleAdminContract, escrowAdminAddr);
    console.log(`\nRole wiring`);
    console.log(`- EscrowAdminContract has EscrowVault.ROLE_ADMIN_CONTRACT: ${hasAdminContract}`);
  } catch (e: any) {
    console.log(`\nRole wiring`);
    console.log(`- Could not read EscrowVault.ROLE_ADMIN_CONTRACT/hasRole: ${e?.message || e}`);
  }

  try {
    const adminRoleTimelock = await admin.ROLE_TIMELOCK();
    const mmRoleTimelock = await mm.ROLE_TIMELOCK();
    const [defaultSigner] = await hre.ethers.getSigners();
    const signerAddr = await defaultSigner.getAddress();
    const adminHas = await admin.hasRole(adminRoleTimelock, signerAddr);
    const mmHas = await mm.hasRole(mmRoleTimelock, signerAddr);
    console.log(`- Current signer: ${signerAddr}`);
    console.log(`- Signer has EscrowAdminContract.ROLE_TIMELOCK: ${adminHas}`);
    console.log(`- Signer has ModuleManagementContract.ROLE_TIMELOCK: ${mmHas}`);
  } catch (e: any) {
    console.log(`- Could not check ROLE_TIMELOCK for current signer: ${e?.message || e}`);
  }

  async function printModuleInfo(label: string, addr: string) {
    if (!addr || addr === ethers.ZeroAddress) return;
    console.log(`\n${label}`);
    console.log(`- address: ${addr}`);
    console.log(`  - ${basescanAddressLink(addr)}`);
    const mod = await hre.ethers.getContractAt(
      [
        'function moduleName() view returns (string)',
        'function moduleVersion() view returns (string)',
        'function resolver() view returns (address)',
      ],
      addr
    );
    const name = await mod.moduleName().catch(() => '');
    const ver = await mod.moduleVersion().catch(() => '');
    const resolver = await mod.resolver().catch(() => ethers.ZeroAddress);
    console.log(`- moduleName: ${name || '(n/a)'}`);
    console.log(`- moduleVersion: ${ver || '(n/a)'}`);
    console.log(`- resolver(): ${resolver}`);
  }

  await printModuleInfo('Current disputeResolutionModule', resolutionModule);
  await printModuleInfo('Default RESOLUTION module (ModuleManagement)', defaultResolutionModule);
}

main().catch((err) => {
  console.error(`\n❌ Inspect failed:\n${err?.stack || err?.message || err}`);
  process.exitCode = 1;
});

