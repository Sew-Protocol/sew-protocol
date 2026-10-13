#!/usr/bin/env ts-node
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { exportDeployables } from './_lib/deployables/export';
import { validateDeployables, readManifest } from './_lib/deployables/validate';
import { loadAllowlist } from './_lib/deployables/allowlist';
import { ConfigError } from './_lib/deployables/errors';
import { sha256Hex, sha256HexOfBuffer } from './_lib/hash';
import { canonicalJson } from './_lib/canonical-json';

const root = process.cwd();
const outDir = path.resolve(process.env.SEW_FORGE_OUT_DIR ?? path.join(root, 'out'));
const allowlist = loadAllowlist(path.join(root, 'config/deployable-allowlist.sew-core.json'));
const scratch: string[] = [];

function tempdir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sew-core-deployables-'));
  scratch.push(dir);
  return dir;
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

function expectFqnRejection(dir: string): void {
  try {
    validateDeployables({ allowlist, exportDir: dir });
    throw new Error('tampered FQN was accepted');
  } catch (error) {
    if (!(error instanceof ConfigError) || error.code !== 'ARTIFACT_FQN_MISMATCH') throw error;
  }
}

function main(): void {
  for (const entry of allowlist.entries) {
    if (!fs.existsSync(path.join(outDir, `${entry.contractName}.sol`, `${entry.contractName}.json`))) {
      throw new Error(`Missing Forge artifact for ${entry.contractName} in ${outDir}`);
    }
  }
  const a = tempdir();
  const b = tempdir();
  const first = exportDeployables({ allowlist, outDir, exportDir: a });
  const second = exportDeployables({ allowlist, outDir, exportDir: b });
  validateDeployables({ allowlist, exportDir: a });
  validateDeployables({ allowlist, exportDir: b });
  assert(first.manifest.build.profile === 'sew-core', 'manifest profile is not sew-core');
  assert(first.manifest.build.compiler.name === 'solc' && first.manifest.build.compiler.version.startsWith('0.8.37'), 'unexpected compiler identity');
  assert(first.manifest.build.settings.evmVersion === 'osaka', 'unexpected EVM version');
  assert(first.manifest.build.settings.optimizerRuns === 200 && first.manifest.build.settings.viaIR, 'unexpected optimizer/viaIR settings');
  assert(first.manifest.bundleRoot === second.manifest.bundleRoot, 'independent exports produced different bundle roots');
  assert(Object.keys(first.manifest.artifacts).length === allowlist.entries.length, 'export is not exact allowlist size');
  for (const entry of allowlist.entries) {
    const expectedFqn = `${entry.sourcePath}:${entry.contractName}`;
    assert(first.manifest.artifacts[entry.artifactName]?.fullyQualifiedName === expectedFqn, `manifest FQN mismatch for ${entry.artifactName}`);
    assert(sha256HexOfBuffer(fs.readFileSync(path.join(a, 'artifacts', `${entry.artifactName}.json`))) ===
      sha256HexOfBuffer(fs.readFileSync(path.join(b, 'artifacts', `${entry.artifactName}.json`))), `artifact bytes differ for ${entry.artifactName}`);
  }
  const vault = first.manifest.artifacts.EscrowVault;
  assert(vault?.hasLinkReferences && vault.hasDeployedLinkReferences, 'EscrowVault link metadata is incomplete');
  assert(Boolean(first.manifest.artifacts.EscrowVaultAccountingLibrary), 'linked accounting library is absent from export');

  const tampered = JSON.parse(fs.readFileSync(path.join(a, 'manifest.json'), 'utf8')) as Record<string, any>;
  tampered.artifacts.EscrowVault.fullyQualifiedName = 'contracts/Other.sol:EscrowVault';
  const { bundleRoot: _oldRoot, ...body } = tampered;
  tampered.bundleRoot = sha256Hex(canonicalJson(body));
  fs.writeFileSync(path.join(a, 'manifest.json'), JSON.stringify(tampered, null, 2) + '\n');
  expectFqnRejection(a);

  console.log(`sew-core artifact validation passed; bundleRoot=${first.manifest.bundleRoot}; dirty=${first.manifest.source.dirty}; source=${first.manifest.source.commit}`);
}

try {
  main();
} finally {
  for (const dir of scratch) fs.rmSync(dir, { recursive: true, force: true });
}
