/* eslint-disable no-console */
/**
 * Base Sepolia deployment verification + version report
 *
 * Generates `deployments/baseSepolia/reports/version-report.json` containing:
 * - Deployed addresses (from hardhat-deploy)
 * - Runtime code size + codehash
 * - Best-effort ERC-165 interface support probes
 * - Best-effort module metadata probes (moduleName/moduleVersion)
 *
 * Run:
 *   pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia.ts
 */

import fs from 'node:fs';
import path from 'node:path';

import hre from 'hardhat';

type InterfaceProbeResult = {
  interfaceId: string;
  supported: boolean | null; // null = probe failed / not ERC165
};

type DeploymentEntryReport = {
  name: string;
  address: string;
  runtimeCodeSizeBytes: number;
  runtimeCodeHash: string | null; // null if no code (EOA)
  supportsErc165: boolean | null; // null if unknown (call failed)
  interfaces: Record<string, InterfaceProbeResult>;
  metadata: {
    moduleName?: string;
    moduleVersion?: string;
    strategyName?: string;
  };
};

type VersionReport = {
  generatedAt: string; // ISO
  network: {
    name: string;
    chainId: number;
  };
  hardhat: {
    solidity?: {
      optimizerRuns?: number;
      viaIR?: boolean;
    };
  };
  interfaceIds: Record<string, string>;
  deployments: Record<string, DeploymentEntryReport>;
};

const ERC165_ID = '0x01ffc9a7';

// Interface IDs for contracts/interfaces/*.sol and contracts/shared/interfaces/*.sol
// (Computed as XOR of declared function selectors; see docs/reference/INTERFACE_ID_ANALYSIS.md)
const INTERFACE_IDS: Record<string, string> = {
  IERC165: ERC165_ID,
  IYieldGenerationModule: '0xaab6380b',
  IYieldDistributionModule: '0xf48a788f',
  IReleaseStrategy: '0xf4856173',
  IResolutionModule: '0x9735510f',
  IEvidenceModule: '0xfa935b7e',
  IResolver: '0xe88ef641',
  IModuleRegistry: '0xbae9fd9d',
  IFraudProofModule: '0x9308ac9d',
  IStakingModule: '0x0dcc3563',
  ISlashingModule: '0x10e6c65d',
  IArbitrable: '0x311a6c56',
  IArbitrator: '0x8114b8a3'
};

function getEthersFn<T extends Function>(name: string): T {
  // Prefer v6-style (top-level), but allow v5-style under .utils for older hardhat-ethers typings.
  const anyEthers: any = hre.ethers as any;
  const direct = anyEthers?.[name];
  if (typeof direct === 'function') return direct as T;
  const viaUtils = anyEthers?.utils?.[name];
  if (typeof viaUtils === 'function') return viaUtils as T;
  throw new Error(`${name} not available on hre.ethers`);
}

function keccak256Hex(hex: string): string {
  const keccak256 = getEthersFn<(data: string) => string>('keccak256');
  return keccak256(hex);
}

function keccak256Utf8(text: string): string {
  const toUtf8Bytes = getEthersFn<(text: string) => string>('toUtf8Bytes');
  return keccak256Hex(toUtf8Bytes(text));
}

function getOptimizerRunsFromHardhatConfig(): number | undefined {
  // hardhat types differ across plugin versions; be defensive.
  const solc: any = (hre.config as any).solidity;
  if (!solc) return undefined;
  // single compiler config shape
  const runs = solc?.settings?.optimizer?.runs;
  if (typeof runs === 'number') return runs;
  // multi-compiler config shape
  const comps = solc?.compilers;
  if (Array.isArray(comps) && comps.length > 0) {
    const r = comps[0]?.settings?.optimizer?.runs;
    if (typeof r === 'number') return r;
  }
  return undefined;
}

function getViaIRFromHardhatConfig(): boolean | undefined {
  const solc: any = (hre.config as any).solidity;
  if (!solc) return undefined;
  const viaIR = solc?.settings?.viaIR;
  if (typeof viaIR === 'boolean') return viaIR;
  const comps = solc?.compilers;
  if (Array.isArray(comps) && comps.length > 0) {
    const v = comps[0]?.settings?.viaIR;
    if (typeof v === 'boolean') return v;
  }
  return undefined;
}

async function trySupportsInterface(
  address: string,
  interfaceId: string
): Promise<boolean | null> {
  // Best-effort ERC-165 probe. Returns null if call fails (not a contract, reverts, no method).
  const c = new (hre.ethers as any).Contract(
    address,
    ['function supportsInterface(bytes4 interfaceId) view returns (bool supported)'],
    hre.ethers.provider
  );
  try {
    const supported: boolean = await c.supportsInterface(interfaceId);
    return supported;
  } catch {
    return null;
  }
}

async function tryReadString(
  address: string,
  fragment: string
): Promise<string | undefined> {
  // fragment example: "function moduleVersion() view returns (string)"
  try {
    const iface = new (hre.ethers as any).Interface([fragment]);
    const fnName = iface.fragments[0].name;
    const data = iface.encodeFunctionData(fnName, []);
    const ret = await hre.ethers.provider.call({ to: address, data });
    const decoded = iface.decodeFunctionResult(fnName, ret);
    const value = decoded?.[0];
    if (typeof value === 'string') return value;
    return undefined;
  } catch {
    return undefined;
  }
}

function runtimeCodeSizeBytes(codeHex: string): number {
  if (!codeHex || codeHex === '0x') return 0;
  // 0x prefixed hex string
  return (codeHex.length - 2) / 2;
}

function runtimeCodeHash(codeHex: string): string | null {
  if (!codeHex || codeHex === '0x') return null;
  return keccak256Hex(codeHex);
}

function sortObjectKeys<T extends Record<string, any>>(obj: T): T {
  const out: any = {};
  for (const k of Object.keys(obj).sort()) out[k] = obj[k];
  return out as T;
}

async function buildDeploymentEntryReport(
  name: string,
  address: string
): Promise<DeploymentEntryReport> {
  const code = await hre.ethers.provider.getCode(address);
  const codeSize = runtimeCodeSizeBytes(code);
  const codeHash = runtimeCodeHash(code);

  const supports165 = await trySupportsInterface(address, ERC165_ID);

  // Probe common module interfaces; cheap and useful for dashboards.
  const interfaces: Record<string, InterfaceProbeResult> = {};
  for (const [ifaceName, ifaceId] of Object.entries(INTERFACE_IDS)) {
    if (ifaceName === 'IERC165') continue;
    const supported = supports165 ? await trySupportsInterface(address, ifaceId) : null;
    interfaces[ifaceName] = { interfaceId: ifaceId, supported };
  }

  // Best-effort metadata probes (do not assume the contract is a module).
  const metadata: DeploymentEntryReport['metadata'] = {};
  const moduleName = await tryReadString(address, 'function moduleName() view returns (string)');
  const moduleVersion = await tryReadString(address, 'function moduleVersion() view returns (string)');
  const strategyName = await tryReadString(address, 'function strategyName() view returns (string)');
  if (moduleName) metadata.moduleName = moduleName;
  if (moduleVersion) metadata.moduleVersion = moduleVersion;
  if (strategyName) metadata.strategyName = strategyName;

  return {
    name,
    address,
    runtimeCodeSizeBytes: codeSize,
    runtimeCodeHash: codeHash,
    supportsErc165: supports165,
    interfaces: sortObjectKeys(interfaces),
    metadata
  };
}

async function main() {
  const networkName = hre.network.name;
  const chainId = Number(hre.network.config.chainId ?? (await hre.ethers.provider.getNetwork()).chainId);

  if (networkName !== 'baseSepolia') {
    console.warn(
      `\n⚠️  This script is intended for --network baseSepolia, but got "${networkName}". Continuing anyway.\n`
    );
  }

  const allDeployments = await hre.deployments.all();
  const names = Object.keys(allDeployments).sort();

  const report: VersionReport = {
    generatedAt: new Date().toISOString(),
    network: { name: networkName, chainId },
    hardhat: {
      solidity: {
        optimizerRuns: getOptimizerRunsFromHardhatConfig(),
        viaIR: getViaIRFromHardhatConfig()
      }
    },
    interfaceIds: sortObjectKeys({ ...INTERFACE_IDS }),
    deployments: {}
  };

  for (const name of names) {
    const dep = allDeployments[name];
    const addr = (dep as any)?.address as string | undefined;
    if (!addr) {
      console.warn(`⚠️  Skipping deployment "${name}" (missing address in hardhat-deploy artifact)`);
      continue;
    }
    report.deployments[name] = await buildDeploymentEntryReport(name, addr);
  }

  // Make output deterministic (stable key order).
  report.deployments = sortObjectKeys(report.deployments);

  // Write under a subdirectory so hardhat-deploy doesn't treat the report as a deployment artifact.
  const outDir = path.join(hre.config.paths.root, 'deployments', networkName, 'reports');
  const outPath = path.join(outDir, 'version-report.json');
  fs.mkdirSync(outDir, { recursive: true });

  const json = JSON.stringify(report, null, 2) + '\n';
  fs.writeFileSync(outPath, json, { encoding: 'utf8' });

  // A short console summary for humans.
  const deploymentCount = Object.keys(report.deployments).length;
  const codeHashAll = keccak256Utf8(json); // content hash for the report itself
  console.log(`✅ Wrote ${outPath}`);
  console.log(`   - deployments: ${deploymentCount}`);
  console.log(`   - reportHash: ${codeHashAll}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});

