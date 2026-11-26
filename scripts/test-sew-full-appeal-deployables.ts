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
