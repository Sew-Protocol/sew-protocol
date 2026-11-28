#!/usr/bin/env ts-node
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { exportDeployables } from './_lib/deployables/export';
import { validateDeployables } from './_lib/deployables/validate';
import { loadAllowlist } from './_lib/deployables/allowlist';
import { sha256HexOfBuffer } from './_lib/hash';

const root = process.cwd();
const outDir = path.resolve(process.env.SEW_FORGE_OUT_DIR ?? path.join(root, 'out'));
const allowlistPath = path.join(root, 'config/deployable-allowlist.sew-full-appeal.json');
const allowlist = loadAllowlist(allowlistPath);
const capabilities = JSON.parse(fs.readFileSync(
  path.join(root, 'config/sew-full-appeal-capabilities.json'), 'utf8'
)) as {
  profile: string;
  packageName: string;
  bundleVersion: string;
  targetNetwork: string;
  maxRuntimeBytes: number;
  capabilities: Record<string, boolean>;
  excludedArtifacts: string[];
  requiredPostDeployAssertions: Array<{ target: string; getter: string; equalsZero?: boolean; equals?: string; field?: string }>;
};
const scratch: string[] = [];

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function tempdir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sew-full-appeal-deployables-'));
  scratch.push(dir);
  return dir;
}

function main(): void {
  assert(allowlist.buildProfile === 'sew-full-appeal', 'allowlist profile is not sew-full-appeal');
  assert(allowlist.bundleVersion === '0.2.0', 'unexpected full-appeal bundle version');
  assert(allowlist.entries.length === 20, `expected 20 allowlisted artifacts; got ${allowlist.entries.length}`);
  assert(capabilities.profile === allowlist.buildProfile, 'capability profile does not match allowlist');
  assert(capabilities.packageName === allowlist.packageName, 'capability package does not match allowlist');
  assert(capabilities.bundleVersion === allowlist.bundleVersion, 'capability bundle version does not match allowlist');
  assert(capabilities.targetNetwork === 'Monad Testnet', 'Full Appeal size qualification target must be Monad Testnet');
  assert(capabilities.maxRuntimeBytes === 131_072, 'Monad Testnet runtime limit must be 128 KiB (131,072 bytes)');
  const artifactNames = new Set(allowlist.entries.map((entry) => entry.contractName));
  for (const excluded of capabilities.excludedArtifacts) {
    assert(!artifactNames.has(excluded), `excluded capability artifact is allowlisted: ${excluded}`);
  }
  assert(capabilities.capabilities.internalResolverAppeals, 'internal appeals must be enabled');
  assert(capabilities.capabilities.bondLedgerCustody, 'BondLedger custody must be enabled');
  for (const disabled of ['externalArbitration', 'drV3Staking', 'drV3Slashing', 'yieldCustody', 'prfAdjudication']) {
    assert(capabilities.capabilities[disabled] === false, `${disabled} must remain disabled in Full Appeal`);
  }
  const runtimeChecks = new Set(capabilities.requiredPostDeployAssertions.map(
    (item) => `${item.target}.${item.getter}.${item.field ?? ''}`
  ));
  for (const required of [
    'DecentralizedResolutionModule.stakingModule().',
    'DecentralizedResolutionModule.slashingModule().',
    'DecentralizedResolutionModule.externalResolver().',
    'DecentralizedResolutionModule.getResolutionConfig(activeResolutionConfigVersion).externalResolver',
    'ModuleSnapshotRegistry.getModule(escrow, YIELD_GEN).',
    'ModuleSnapshotRegistry.getModule(escrow, RESOLUTION).',
  ]) {
    assert(runtimeChecks.has(required), `missing required runtime capability assertion: ${required}`);
  }

  for (const entry of allowlist.entries) {
    const artifactPath = path.join(outDir, `${entry.contractName}.sol`, `${entry.contractName}.json`);
    if (!fs.existsSync(artifactPath)) throw new Error(`Missing Forge artifact for ${entry.contractName} in ${outDir}`);
  }

  const firstDir = tempdir();
  const secondDir = tempdir();
  const first = exportDeployables({ allowlist, outDir, exportDir: firstDir });
  const second = exportDeployables({ allowlist, outDir, exportDir: secondDir });
  validateDeployables({ allowlist, exportDir: firstDir });
  validateDeployables({ allowlist, exportDir: secondDir });

  assert(first.manifest.build.profile === 'sew-full-appeal', 'manifest profile is not sew-full-appeal');
  assert(first.manifest.source.repository === 'Sew-Protocol/sew-protocol',
    'manifest source repository is not the canonical GitHub repository');
  assert(first.manifest.source.dirty === false, 'full-appeal bundle source is dirty or not commit-bound');
  assert(first.manifest.build.compiler.name === 'solc', 'unexpected compiler');
  assert(first.manifest.build.compiler.version.startsWith('0.8.37'), 'unexpected compiler version');
  assert(first.manifest.build.settings.evmVersion === 'osaka', 'unexpected EVM version');
  assert(first.manifest.build.settings.optimizerRuns === 200 && first.manifest.build.settings.viaIR,
    'unexpected optimizer/viaIR settings');
  assert(first.manifest.bundleRoot === second.manifest.bundleRoot,
    'independent full-appeal exports produced different bundle roots');
  assert(Object.keys(first.manifest.artifacts).length === allowlist.entries.length,
    'export does not exactly match the full-appeal allowlist');

  for (const entry of allowlist.entries) {
    const record = first.manifest.artifacts[entry.artifactName];
    assert(record?.fullyQualifiedName === `${entry.sourcePath}:${entry.contractName}`,
      `manifest FQN mismatch for ${entry.artifactName}`);
    const firstArtifact = fs.readFileSync(path.join(firstDir, 'artifacts', `${entry.artifactName}.json`));
    const secondArtifact = fs.readFileSync(path.join(secondDir, 'artifacts', `${entry.artifactName}.json`));
    assert(sha256HexOfBuffer(firstArtifact) === sha256HexOfBuffer(secondArtifact),
      `independent artifact bytes differ for ${entry.artifactName}`);
    const exported = JSON.parse(firstArtifact.toString('utf8')) as { deployedBytecode: string };
    const runtimeBytes = (exported.deployedBytecode.replace(/^0x/, '').length / 2);
    assert(runtimeBytes <= capabilities.maxRuntimeBytes,
      `${entry.artifactName} runtime is ${runtimeBytes} bytes; configured ${capabilities.targetNetwork} limit is ${capabilities.maxRuntimeBytes}`);
  }

  console.log(
    `full-appeal artifact qualification passed; artifacts=${allowlist.entries.length}; ` +
    `bundleRoot=${first.manifest.bundleRoot}; dirty=${first.manifest.source.dirty}; ` +
    `source=${first.manifest.source.commit}`,
  );
}

try {
  main();
} finally {
  for (const dir of scratch) fs.rmSync(dir, { recursive: true, force: true });
}
