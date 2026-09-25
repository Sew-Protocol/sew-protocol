/**
 * Deploy BondLedger-backed DR v2 appeal-bond profile (Profile B) — independent graph
 *
 * Profile B (`sew-dr-v2-bondledger`) is the intended next-release composition, deployed as
 * a FRESH, INDEPENDENT profile (it does NOT mutate the Profile-A DRM in place):
 *
 *   fresh DecentralizedResolutionModule   (Profile-B instance)
 *     → ResolverIncentiveModuleV2BondLedger (facade over BondLedger)
 *     → BondLedger
 *   EscrowVault/DRM binding (Profile-B)
 *   profile manifest
 *
 * This script separates two phases:
 *
 *   DEPLOYMENT          — deploy the fresh Profile-B graph; does NOT set incentive module /
 *                         addAuthorizedCaller via the deployer unless the documented
 *                         Sew bootstrap grants it. Emits the required activation operations.
 *   GOVERNANCE ACTIVATION — execute through the real governance path (TimelockController /
 *                         EscrowGovernanceTimelock slow-lane), performing
 *                         BondLedger.addAuthorizedCaller(facade),
 *                         DRM.setIncentiveModule(facade), DRM.setAdminFacet,
 *                         DRM.setBondTokenRegistry, EscrowVault registration, and role grants.
 *
 * Profile selection is explicit via REQUIRED env var `DEPLOY_PROFILE`:
 *   DEPLOY_PROFILE=sew-dr-v2-bondledger         → this script
 *   DEPLOY_PROFILE=sew-dr-v2-inline-custody     → the existing 85/86 Profile A path
 *
 * The script refuses to run if `DEPLOY_PROFILE` is missing or contradicts.
 *
 * Governance stack (shared): TimelockController, EscrowGovernanceTimelock, SewToken, GovGovernor.
 * Shared protocol (reused): ResolverStakingModule, ResolverSlashingModule, InsurancePoolVault,
 * BondTokenRegistry, DRMAdminFacet, PaymentCalculationLibrary.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { validateNetworkForDeployment } from '../scripts/_lib/network-validation';
import { getChainConfig, getBlockExplorerUrl } from '../config/chains.config';
import { registerDeployment } from '../config/deployments.registry';

const PROFILE_B_ID = 'sew-dr-v2-bondledger';
// Distinct hardhat-deploy deployment names so Profile-B records never collide with Profile A.
const DRM_PB = 'DecentralizedResolutionModuleProfileB';
const LEDGER_PB = 'BondLedger';
const FACADE_PB = 'ResolverIncentiveModuleV2BondLedger';

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  // ── Explicit profile selection (mandatory, fail closed) ─────────────────
  const selectedProfile = (process.env.DEPLOY_PROFILE || '').trim();
  if (!selectedProfile) {
    throw new Error(
      'DEPLOY_PROFILE not set. Choose "sew-dr-v2-bondledger" for Profile B or ' +
        '"sew-dr-v2-inline-custody" for Profile A (handled by deploy/85,86).',
    );
  }
  if (selectedProfile !== PROFILE_B_ID) {
    throw new Error(
      `DEPLOY_PROFILE="${selectedProfile}" does not match this script's profile "${PROFILE_B_ID}". ` +
        'Run the inline-custody path (deploy/85,86) for Profile A.',
    );
  }

  await validateNetworkForDeployment(hre);

  const { deployments, getNamedAccounts, ethers } = hre;
  const { deploy, get } = deployments;
  const { deployer } = await getNamedAccounts();
  const chainConfig = getChainConfig(hre);

  const keccak256 = ethers.keccak256;
  const toUtf8Bytes = ethers.toUtf8Bytes;
  const ROLE_TIMELOCK = keccak256(toUtf8Bytes('ROLE_TIMELOCK'));
  const AUTHORIZED_CALLER = keccak256(toUtf8Bytes('AUTHORIZED_CALLER'));
  const PROPOSER_ROLE = keccak256(toUtf8Bytes('PROPOSER_ROLE'));

  // Local in-process (hardhat) and local anvil nodes both support the dev RPC
  // methods (evm_increaseTime / evm_mine) needed to drive the real
  // TimelockController activation path deterministically.
  const isLocalHardhat = hre.network.name === 'hardhat' || hre.network.name === 'anvil';

  console.log(`\n🔧 Deploying Profile B (${PROFILE_B_ID}) — INDEPENDENT graph`);
  console.log(`   chainId:      ${chainConfig.chainId}`);
  console.log(`   deployer:     ${deployer}`);

  // Resolve shared components (reused, never mutated)
  const timelockAddr = (await get('TimelockController')).address;
  let escrowAdminAddr: string | undefined;
  try { escrowAdminAddr = (await get('EscrowGovernanceTimelock')).address; } catch { /* optional */ }
  const paymentLibAddr = (await get('PaymentCalculationLibrary')).address;
  const adminFacetAddr = (await get('DRMAdminFacet')).address;
  const bondRegistryAddr = (await get('BondTokenRegistry')).address;

  // Profile-B EscrowVault binding: a dedicated Profile-B vault address (explicit), or the
  // shared vault if PROFILE_B_REUSE_VAULT=true. A fresh legacy-core vault is out of scope
  // here (separate qualification path).
  const reuseVault = (process.env.PROFILE_B_REUSE_VAULT || 'false') === 'true';
  let escrowVaultAddr: string | undefined;
  try {
    escrowVaultAddr = reuseVault ? (await get('EscrowVault')).address : process.env.PROFILE_B_ESCROW_VAULT;
  } catch { /* optional */ }

  // ─────────────────── DEPLOYMENT PHASE ───────────────────────────────────
  // 1. Fresh Profile-B DRM (distinct deployment record; never Profile A's DRM).
  console.log(`\n📦 Deploying FRESH DecentralizedResolutionModule (Profile-B)...`);
  const drmDeploy = await deploy(DRM_PB, {
    contract: 'DecentralizedResolutionModule',
    from: deployer,
    args: [deployer],
    log: true,
  });
  if (drmDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, drmDeploy.address);
    console.log(`   ✅ Profile-B DRM: ${drmDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (drmDeploy.receipt) {
      await registerDeployment(hre, DRM_PB, {
        address: drmDeploy.address,
        txHash: drmDeploy.transactionHash ?? '',
        blockNumber: drmDeploy.receipt.blockNumber,
        constructorArgs: [deployer],
        tags: ['profile-b', 'resolution-module'],
      });
    }
  } else {
    console.log(`   ✅ Profile-B DRM already deployed: ${drmDeploy.address}`);
  }

  // 2. BondLedger (admin = governance timelock).
  console.log(`\n📦 Deploying BondLedger... (admin=${timelockAddr})`);
  const ledgerDeploy = await deploy(LEDGER_PB, {
    contract: 'BondLedger',
    from: deployer,
    args: [timelockAddr],
    log: true,
  });
  if (ledgerDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, ledgerDeploy.address);
    console.log(`   ✅ BondLedger: ${ledgerDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (ledgerDeploy.receipt) {
      await registerDeployment(hre, LEDGER_PB, {
        address: ledgerDeploy.address,
        txHash: ledgerDeploy.transactionHash ?? '',
        blockNumber: ledgerDeploy.receipt.blockNumber,
        constructorArgs: [timelockAddr],
        tags: ['profile-b', 'bondledger'],
      });
    }
  } else {
    console.log(`   ✅ BondLedger already deployed: ${ledgerDeploy.address}`);
  }

  // 3. Facade (extends ResolverIncentiveModule, bound to BondLedger).
  console.log(`\n📦 Deploying ResolverIncentiveModuleV2BondLedger...`);
  const facadeDeploy = await deploy(FACADE_PB, {
    contract: 'ResolverIncentiveModuleV2BondLedger',
    from: deployer,
    args: [deployer, paymentLibAddr, ledgerDeploy.address],
    log: true,
  });
  if (facadeDeploy.newlyDeployed) {
    const url = getBlockExplorerUrl(hre, facadeDeploy.address);
    console.log(`   ✅ Facade: ${facadeDeploy.address}`);
    if (url) console.log(`      ${url}`);
    if (facadeDeploy.receipt) {
      await registerDeployment(hre, FACADE_PB, {
        address: facadeDeploy.address,
        txHash: facadeDeploy.transactionHash ?? '',
        blockNumber: facadeDeploy.receipt.blockNumber,
        constructorArgs: [deployer, paymentLibAddr, ledgerDeploy.address],
        tags: ['profile-b', 'incentive'],
      });
    }
  } else {
    console.log(`   ✅ Facade already deployed: ${facadeDeploy.address}`);
  }

  // 4. Profile-B EscrowVault binding. If no vault is provided via env (PROFILE_B_ESCROW_VAULT)
  //    or the shared vault (PROFILE_B_REUSE_VAULT=true), deploy a FRESH Profile-B vault so the
  //    closure is independent. The current EscrowVault constructor is 3-arg
  //    (escrowFeeBps, feeAddress, moduleManagementAddress) and REVERTS if
  //    moduleManagementAddress.code.length == 0, so we must bind it to a deployed
  //    ModuleSnapshotRegistry. The shared legacy core path (deploy/70) targets a different
  //    source contract and is out of scope here.
  const VAULT_PB = 'EscrowVaultProfileB';
  let vaultDeploy: { address: string; newlyDeployed: boolean } | undefined;
  if (!escrowVaultAddr) {
    let moduleSnapshotRegistryAddr: string;
    try {
      moduleSnapshotRegistryAddr = (await get('ModuleSnapshotRegistry')).address;
    } catch {
      console.log(`\n📦 Deploying Fresh ModuleSnapshotRegistry (Profile-B)...`);
      const msrDeploy = await deploy('ModuleSnapshotRegistryProfileB', {
        contract: 'ModuleSnapshotRegistry',
        from: deployer,
        args: [deployer], // initialAdmin (deployer bootstraps; governance hardened downstream)
        log: true,
      });
      moduleSnapshotRegistryAddr = msrDeploy.address;
      console.log(`   ✅ ModuleSnapshotRegistry (Profile-B): ${msrDeploy.address}`);
    }

    // EscrowVault links the external EscrowVaultAccountingLibrary (has code + storage mapping
    // pointers), so the library must be deployed first and linked. Otherwise hardhat-deploy/ethers
    // reject the unlinked artifact bytecode as invalid.
    let accountingLibAddr: string;
    try {
      accountingLibAddr = (await get('EscrowVaultAccountingLibrary')).address;
    } catch {
      console.log(`\n📦 Deploying EscrowVaultAccountingLibrary (Profile-B, shared)...`);
      const libDeploy = await deploy('EscrowVaultAccountingLibrary', {
        contract: 'EscrowVaultAccountingLibrary',
        from: deployer,
        log: true,
      });
      accountingLibAddr = libDeploy.address;
      console.log(`   ✅ EscrowVaultAccountingLibrary: ${accountingLibAddr}`);
    }

    console.log(`\n📦 Deploying FRESH EscrowVault (Profile-B)...`);
    vaultDeploy = await deploy(VAULT_PB, {
      contract: 'EscrowVault',
      from: deployer,
      args: [0, deployer, moduleSnapshotRegistryAddr], // escrowFeeBps, feeAddress, moduleManagement
      libraries: {
        EscrowVaultAccountingLibrary: accountingLibAddr,
      },
      log: true,
    });
    escrowVaultAddr = vaultDeploy.address;
    if (vaultDeploy.newlyDeployed) {
      console.log(`   ✅ Profile-B EscrowVault: ${vaultDeploy.address}`);
      if ((vaultDeploy as any).receipt) {
        await registerDeployment(hre, VAULT_PB, {
          address: vaultDeploy.address,
          txHash: (vaultDeploy as any).transactionHash,
          blockNumber: (vaultDeploy as any).receipt.blockNumber,
          constructorArgs: [0, deployer, moduleSnapshotRegistryAddr],
          tags: ['profile-b', 'escrow'],
        });
      }
    }
  }

  // ─────────────────── GOVERNANCE ACTIVATION ──────────────────────────────
  const ops: Array<{ op: string; target: string; via: string }> = [];
  const gov = `TimelockController:${timelockAddr}`;
  const push = (op: string, target: string, via: string) => ops.push({ op, target, via });
  push('addAuthorizedCaller(facade)', ledgerDeploy.address, gov);
  push('setAdminFacet(adminFacet)', drmDeploy.address, gov);
  push(`setBondTokenRegistry(${bondRegistryAddr})`, drmDeploy.address, gov);
  push(`setIncentiveModule(${facadeDeploy.address})`, drmDeploy.address, gov);
  if (escrowVaultAddr) push(`registerEscrowContract(${escrowVaultAddr})`, drmDeploy.address, gov);
  console.log(`\n🔒 Governance activation operations for Profile B (${ops.length}):`);
  ops.forEach((o) => console.log(`   - [${o.via}] ${o.op} on ${o.target}`));

  // Deterministic local qualification: the deployer is DEFAULT_ADMIN on the FRESH DRM and may
  // bootstrap DRM wiring directly (mirrors deploy/86 documented bootstrap). BondLedger
  // addAuthorizedCaller requires ROLE_TIMELOCK (admin=timelock); if the deployer does not hold
  // it, we emit rather than bypass — final authority remains with the governance stack.
  const signer = await ethers.getSigner(deployer);
  const drm = await ethers.getContractAt('DecentralizedResolutionModule', drmDeploy.address, signer);
  const ledger = await ethers.getContractAt('BondLedger', ledgerDeploy.address, signer);

  const applyGovernance = (process.env.PROFILE_B_APPLY_GOVERNANCE || 'true').toLowerCase() === 'true';

  // DRM bootstrap: grant ROLE_TIMELOCK to governance (deployer is DEFAULT_ADMIN on fresh DRM).
  console.log(`\n🔗 Bootstrapping DRM governance roles (fresh DRM)...`);
  if (!(await drm.hasRole(ROLE_TIMELOCK, timelockAddr))) {
    await (await drm.grantRole(ROLE_TIMELOCK, timelockAddr)).wait();
    console.log(`   ✅ ROLE_TIMELOCK granted to TimelockController`);
  } else {
    console.log(`   ✅ TimelockController already ROLE_TIMELOCK`);
  }

  // Fresh-DRM one-time bootstrap: wire the shared DRMAdminFacet so delegated admin setters
  // (setIncentiveModule, setBondTokenRegistry, ...) resolve without reverting AdminFacetNotSet.
  // Deployer is DEFAULT_ADMIN on the fresh DRM, which is sufficient for the first setAdminFacet.
  console.log(`\n🔗 Bootstrapping DRMAdminFacet on fresh Profile-B DRM...`);
  const currentFacet = await drm.adminFacet();
  if (currentFacet === ethers.ZeroAddress) {
    await (await drm.setAdminFacet(adminFacetAddr)).wait();
    console.log(`   ✅ adminFacet set to ${adminFacetAddr}`);
  } else {
    console.log(`   ✅ adminFacet already set: ${currentFacet}`);
  }

  // Deployer must hold ROLE_TIMELOCK on the fresh DRM to drive the delegated setters below
  // (mirrors deploy/86 documented bootstrap; grants are executed via DEFAULT_ADMIN).
  if (!(await drm.hasRole(ROLE_TIMELOCK, deployer))) {
    await (await drm.grantRole(ROLE_TIMELOCK, deployer)).wait();
    console.log(`   ✅ ROLE_TIMELOCK granted to deployer (temporary bootstrap)`);
  }

  const signerHasTimelockOnLedger = await ledger.hasRole(ROLE_TIMELOCK, deployer);
  if (applyGovernance) {
    // Facade must be AUTHORIZED_CALLER on BondLedger before DRM can settle through it.
    // BondLedger is admin'd by the governance TimelockController, so the deployer almost never
    // holds ROLE_TIMELOCK on it. On the deterministic local (hardhat) network the deployer IS the
    // temporary TimelockController admin, so we drive the REAL TimelockController path
    // (grant admin PROPOSER_ROLE -> schedule -> advance the clock past the delay -> execute)
    // with no deployer-level bypass. Off-local we emit rather than bypass: final authority stays
    // with the governance stack.
    const hasCaller = await ledger.hasRole(AUTHORIZED_CALLER, facadeDeploy.address);
    if (!hasCaller && isLocalHardhat && !signerHasTimelockOnLedger) {
      const timelock = await ethers.getContractAt('TimelockController', timelockAddr, signer);
      const isTimelockAdmin = await timelock.hasRole(await timelock.DEFAULT_ADMIN_ROLE(), deployer);
      if (isTimelockAdmin) {
        if (!(await timelock.hasRole(PROPOSER_ROLE, deployer))) {
          await (await timelock.grantRole(PROPOSER_ROLE, deployer)).wait();
        }
        const data = ledger.interface.encodeFunctionData('addAuthorizedCaller', [facadeDeploy.address]);
        const salt = ethers.keccak256(ethers.toUtf8Bytes('profile-b-sew-dr-v2-bondledger'));
        const minDelay = Number(await timelock.getMinDelay());
        await (await timelock.schedule(ledgerDeploy.address, 0, data, ethers.ZeroHash, salt, minDelay)).wait();
        await hre.network.provider.send('evm_increaseTime', [minDelay + 1]);
        await hre.network.provider.send('evm_mine');
        await (await timelock.execute(ledgerDeploy.address, 0, data, ethers.ZeroHash, salt)).wait();
        console.log(`   ✅ AUTHORIZED_CALLER granted to facade via TimelockController (hardhat).`);
      } else {
        console.log(`   ⚠  SKIPPED BondLedger.addAuthorizedCaller (deployer is not TimelockController admin).`);
      }
    } else if (!hasCaller && signerHasTimelockOnLedger) {
      await (await ledger.addAuthorizedCaller(facadeDeploy.address)).wait();
      console.log(`   ✅ AUTHORIZED_CALLER granted to facade (direct ROLE_TIMELOCK).`);
    } else if (!hasCaller) {
      console.log(`   ⚠  SKIPPED BondLedger.addAuthorizedCaller (governance activation not available off local).`);
    }

    // DRM wiring via documented bootstrap (deployer acts as onboarding admin on fresh DRM).
    const currentIncentive = await drm.incentiveModule();
    if (currentIncentive.toLowerCase() !== facadeDeploy.address.toLowerCase()) {
      await (await drm.setIncentiveModule(facadeDeploy.address)).wait();
      console.log(`   ✅ DRM.setIncentiveModule(facade)`);
    }
    const currentRegistryWiring = await drm.bondTokenRegistry();
    if (currentRegistryWiring === ethers.ZeroAddress) {
      await (await drm.setBondTokenRegistry(bondRegistryAddr)).wait();
      console.log(`   ✅ DRM.setBondTokenRegistry(shared registry)`);
    }
    if (escrowVaultAddr) {
      const registered = await drm.registeredEscrowContracts(escrowVaultAddr);
      if (!registered) {
        await (await drm.registerEscrowContract(escrowVaultAddr)).wait();
        console.log(`   ✅ DRM.registerEscrowContract(vault)`);
      }
    }
  } else {
    console.log(`   ⚠  Governance activation NOT applied (PROFILE_B_APPLY_GOVERNANCE=false).`);
    console.log(`      Execute the ${ops.length} emitted operations via TimelockController.`);
  }

  // ─────────────────── READ-BACK (authoritative, not deploy-script output) ──
  console.log(`\n🔎 Read-back of Profile B bindings:`);
  const readLedger = await ethers.getContractAt('BondLedger', ledgerDeploy.address, signer);
  const readFacade = await ethers.getContractAt('ResolverIncentiveModuleV2BondLedger', facadeDeploy.address, signer);
  const readDrm = await ethers.getContractAt('DecentralizedResolutionModule', drmDeploy.address, signer);

  const readback: Record<string, unknown> = {
    profile: PROFILE_B_ID,
    drm: drmDeploy.address,
    bondLedger: ledgerDeploy.address,
    facade: facadeDeploy.address,
    'facade.bondLedger()': await readFacade.bondLedger(),
    'ledger.authorizedCaller(facade)': await readLedger.hasRole(AUTHORIZED_CALLER, facadeDeploy.address),
    'drm.incentiveModule()': await readDrm.incentiveModule(),
    'drm.registeredEscrow(escrowVault)': escrowVaultAddr
      ? await readDrm.registeredEscrowContracts(escrowVaultAddr)
      : 'SKIP',
    'ledger.ROLE_TIMELOCK(timelock)': await readLedger.hasRole(ROLE_TIMELOCK, timelockAddr),
  };
  console.log(`   ${JSON.stringify(readback, null, 2)}`);

  const facadeBondLedger = (await readFacade.bondLedger()).toLowerCase();
  const drmIncentive = (await readDrm.incentiveModule()).toLowerCase();
  if (facadeBondLedger !== ledgerDeploy.address.toLowerCase()) {
    throw new Error('Facade not bound to the deployed BondLedger');
  }
  if (drmIncentive !== facadeDeploy.address.toLowerCase()) {
    throw new Error('DRM incentive module is not the Profile-B facade');
  }

  // ─────────────────── RUNTIME CODEHASH READ-BACK (A-4 mechanism) ──────────
  // On-chain runtime codehash (keccak256 of eth_getCode) for the Profile-B contracts.
  // NOTE on build binding: the deterministic local hardhat deployment compiles with the
  // hardhat config (solc 0.8.37 / evmVersion cancun / runs 10), which is NOT the A-2
  // deployable bundle (forge: solc 0.8.37 / evmVersion osaka / runs 200 / viaIR). So these
  // codehashes are hardhat-build-bound. A true A-2 runtime-codehash binding requires an
  // on-chain deployment compiled with the A-2 forge settings; these reported hashes are the
  // read-back surface, not that binding.
  const codeHashOf = async (label: string, address: string) => {
    const code = await ethers.provider.getCode(address);
    console.log(`   codehash[${label}]  ${address}`);
    console.log(`      keccak256(unlinked runtime) = ${ethers.keccak256(code)}`);
    return ethers.keccak256(code);
  };
  const drmCodehash = await codeHashOf('DRM(Profile-B)', drmDeploy.address);
  const ledgerCodehash = await codeHashOf('BondLedger', ledgerDeploy.address);
  const facadeCodehash = await codeHashOf('Facade(V2BondLedger)', facadeDeploy.address);
  readback['codehash'] = {
    'DRM(Profile-B)': drmCodehash,
    BondLedger: ledgerCodehash,
    'Facade(V2BondLedger)': facadeCodehash,
  };
  console.log(`   ${JSON.stringify(readback['codehash'], null, 2)}`);

  console.log(`\n✅ Profile B (${PROFILE_B_ID}) independent deployment/wiring complete`);
  console.log(`   DRM (Profile-B):  ${drmDeploy.address}`);
  console.log(`   BondLedger:       ${ledgerDeploy.address}`);
  console.log(`   Facade:           ${facadeDeploy.address}`);
  console.log(`   Escrow binding:   ${escrowVaultAddr ?? 'UNSET (set PROFILE_B_ESCROW_VAULT or PROFILE_B_REUSE_VAULT=true)'}`);
  console.log(`   Governance:       ${timelockAddr}`);
};

export default func;
func.tags = ['profile-b', 'sew-dr-v2-bondledger'];
func.dependencies = ['decentralized-resolution-module'];
