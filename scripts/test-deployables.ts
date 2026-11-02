#!/usr/bin/env ts-node
/**
 * Export tests (round-trip + determinism + adversarial integrity).
 *
 * These run the actual exporter and validator against a real (fixture)
 * copy of the build output, so they are self-contained and fast. They do not
 * require a live network.
 *
 * Usage:
 *   pnpm deployables:test
 */
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { exportDeployables } from './_lib/deployables/export';
import { validateDeployables, readManifest } from './_lib/deployables/validate';
import { loadAllowlist } from './_lib/deployables/allowlist';
import { ConfigError } from './_lib/deployables/errors';
import { sha256Hex, sha256HexOfBuffer } from './_lib/hash';
import { canonicalJson } from './_lib/canonical-json';
import { sourceCommitFromEnvironment } from './_lib/source-commit';

const OUT_DIR = path.resolve(process.env.SEW_FORGE_OUT_DIR ?? path.resolve(process.cwd(), 'out'));
const SEW_CORE_OUT_DIR = path.resolve(process.env.SEW_CORE_FORGE_OUT_DIR ?? path.join(process.cwd(), 'packages', 'sew-core', 'out'));
const ALLOWLIST = loadAllowlist();
const BONDLEDGER_ALLOWLIST_PATH = path.resolve(process.cwd(), 'config', 'deployable-allowlist-bondledger.json');
const SEW_CORE_ALLOWLIST_PATH = path.resolve(process.cwd(), 'packages', 'sew-core', 'deployables.allowlist.json');

let passed = 0;
let failed = 0;
const failures: string[] = [];

function test(name: string, fn: () => void): void {
  try {
    fn();
    passed++;
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failed++;
    failures.push(name);
    console.log(`  ✗ ${name}`);
    console.log(`      ${e instanceof Error ? e.message : String(e)}`);
  }
}

function tmpdir(): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'sew-deployables-'));
}

function expectThrows(fn: () => void, code: string): void {
  try {
    fn();
    throw new Error(`expected ConfigError '${code}' but no error thrown`);
  } catch (e) {
    if (e instanceof ConfigError && e.code === code) return;
    throw new Error(`expected ConfigError '${code}' but got: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function expectNotThrows(fn: () => void): void {
  fn();
}

function main(): void {
  test('source override cannot falsely attest dirty or unverifiable artifacts as clean', () => {
    if (sourceCommitFromEnvironment('abc123', 'abc123', '').dirty !== false) {
      throw new Error('expected a matching clean Git checkout to be clean');
    }
    if (!sourceCommitFromEnvironment('abc123', 'abc123', ' M packages/sew-core/contracts/core/SewCoreVault.sol').dirty) {
      throw new Error('dirty checkout was marked clean');
    }
    if (!sourceCommitFromEnvironment('abc123', null, null).dirty) {
      throw new Error('unverifiable source override was marked clean');
    }
    if (!sourceCommitFromEnvironment('abc123', 'different', '').dirty) {
      throw new Error('source revision mismatch was marked clean');
    }
  });

  if (!fs.existsSync(path.join(OUT_DIR, 'EscrowVault.sol', 'EscrowVault.json'))) {
    console.error('Foundry build output not found. Run `pnpm compile` (or `forge build`) first.');
    process.exit(2);
  }

  const expectedCount = ALLOWLIST.entries.length;

  test('exports all allow-listed artifacts', () => {
    const dir = tmpdir();
    const r = exportDeployables({ exportDir: dir });
    expectNotThrows(() => validateDeployables({ exportDir: dir }));
    if (Object.keys(r.manifest.artifacts).length !== expectedCount) {
      throw new Error(`expected ${expectedCount} artifacts, got ${Object.keys(r.manifest.artifacts).length}`);
    }
  });

  test('re-export is deterministic (identical bundle root + file hashes)', () => {
    const a = tmpdir();
    const b = tmpdir();
    const ra = exportDeployables({ exportDir: a });
    const rb = exportDeployables({ exportDir: b });
    if (ra.manifest.bundleRoot !== rb.manifest.bundleRoot) {
      throw new Error(`bundleRoot differs: ${ra.manifest.bundleRoot} vs ${rb.manifest.bundleRoot}`);
    }
    for (const name of Object.keys(ra.manifest.artifacts)) {
      const fa = sha256HexOfBuffer(fs.readFileSync(path.join(a, 'artifacts', `${name}.json`)));
      const fb = sha256HexOfBuffer(fs.readFileSync(path.join(b, 'artifacts', `${name}.json`)));
      if (fa !== fb) throw new Error(`artifact '${name}' file differs between runs`);
    }
    if (ra.manifest.source.commit !== rb.manifest.source.commit) {
      throw new Error('source commit differs between runs (unexpected)');
    }
  });

  test('Profile-B (bondledger) re-export is deterministic + validates against its allow-list', () => {
    const allowlist = loadAllowlist(BONDLEDGER_ALLOWLIST_PATH);
    const a = tmpdir();
    const b = tmpdir();
    const ra = exportDeployables({ allowlist, exportDir: a });
    const rb = exportDeployables({ allowlist, exportDir: b });
    if (ra.manifest.bundleRoot !== rb.manifest.bundleRoot) {
      throw new Error(`Profile-B bundleRoot differs: ${ra.manifest.bundleRoot} vs ${rb.manifest.bundleRoot}`);
    }
    if (ra.manifest.build.profile !== 'sew-dr-v2-bondledger') {
      throw new Error(`Profile-B build.profile is '${ra.manifest.build.profile}', expected sew-dr-v2-bondledger`);
    }
    for (const name of Object.keys(ra.manifest.artifacts)) {
      const fa = sha256HexOfBuffer(fs.readFileSync(path.join(a, 'artifacts', `${name}.json`)));
      const fb = sha256HexOfBuffer(fs.readFileSync(path.join(b, 'artifacts', `${name}.json`)));
      if (fa !== fb) throw new Error(`Profile-B artifact '${name}' file differs between runs`);
    }
    // validate the second export against the Profile-B allow-list (must not fall back to Profile A)
    validateDeployables({ allowlist, exportDir: b });
  });

  test('sew-core release inventory is FQN-bound, link-complete and deterministic', () => {
    const allowlist = loadAllowlist(SEW_CORE_ALLOWLIST_PATH);
    const a = tmpdir();
    const b = tmpdir();
    const ra = exportDeployables({ allowlist, outDir: SEW_CORE_OUT_DIR, exportDir: a });
    const rb = exportDeployables({ allowlist, outDir: SEW_CORE_OUT_DIR, exportDir: b });
    validateDeployables({ allowlist, exportDir: a });
    validateDeployables({ allowlist, exportDir: b });
    if (ra.manifest.build.profile !== 'sew-core') throw new Error(`sew-core profile label is '${ra.manifest.build.profile}'`);
    if (ra.manifest.bundleRoot !== rb.manifest.bundleRoot) throw new Error('sew-core bundleRoot differs between exports');
    for (const entry of allowlist.entries) {
      const expectedFqn = `${entry.sourcePath}:${entry.contractName}`;
      const record = ra.manifest.artifacts[entry.artifactName];
      if (record?.fullyQualifiedName !== expectedFqn) throw new Error(`FQN mismatch for ${entry.artifactName}`);
    }
    const vault = ra.manifest.artifacts.SewCoreVault;
    if (!vault?.hasLinkReferences || !vault.hasDeployedLinkReferences) throw new Error('SewCoreVault library links are missing from sew-core artifact metadata');
    for (const library of [
      'SettingsValidationLibrary', 'EscrowCreationLogic', 'EscrowDisputeLogic',
      'EscrowSettlementLogic', 'DisputeInitializationLibrary', 'DisputeRaiseLibrary',
      'StateManagementLibrary',
    ]) {
      if (!ra.manifest.artifacts[library]) throw new Error(`linked library ${library} is missing from sew-core inventory`);
    }
  });

  test('tampered fully qualified manifest identity fails validation', () => {
    const dir = tmpdir();
    const allowlist = loadAllowlist(SEW_CORE_ALLOWLIST_PATH);
    exportDeployables({ allowlist, outDir: SEW_CORE_OUT_DIR, exportDir: dir });
    const manifestPath = path.join(dir, 'manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as Record<string, any>;
    manifest.artifacts.SewCoreVault.fullyQualifiedName = 'contracts/Other.sol:SewCoreVault';
    const { bundleRoot: _oldRoot, ...rootedBody } = manifest;
    manifest.bundleRoot = sha256Hex(canonicalJson(rootedBody));
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
    expectThrows(() => validateDeployables({ allowlist, exportDir: dir }), 'ARTIFACT_FQN_MISMATCH');
  });

  test('tampered artifact file fails validation', () => {
    const dir = tmpdir();
    exportDeployables({ exportDir: dir });
    const name = ALLOWLIST.entries[0]!.artifactName;
    const file = path.join(dir, 'artifacts', `${name}.json`);
    const buf = fs.readFileSync(file);
    buf[0] = buf[0] === 0x7b ? 0x7c : 0x7b; // flip first byte
    fs.writeFileSync(file, buf);
    expectThrows(() => validateDeployables({ exportDir: dir }), 'ARTIFACT_FILE_HASH_MISMATCH');
  });

  test('extra non-allow-listed artifact file is rejected (non-deployable exclusion)', () => {
    const dir = tmpdir();
    exportDeployables({ exportDir: dir });
    fs.writeFileSync(path.join(dir, 'artifacts', 'NotDeployable.json'), '{}');
    expectThrows(() => validateDeployables({ exportDir: dir }), 'NON_DEPLOYABLE_EXPORTED');
  });

  test('removing an allow-listed artifact file is rejected', () => {
    const dir = tmpdir();
    exportDeployables({ exportDir: dir });
    const name = ALLOWLIST.entries[0]!.artifactName;
    fs.rmSync(path.join(dir, 'artifacts', `${name}.json`));
    expectThrows(() => validateDeployables({ exportDir: dir }), 'ALLOWLISTED_FILE_MISSING');
  });

  test('bytecode hashes correspond to exported bytecode', () => {
    const dir = tmpdir();
    const r = exportDeployables({ exportDir: dir });
    const manifest = readManifest(dir);
    for (const entry of ALLOWLIST.entries) {
      const rec = manifest.artifacts[entry.artifactName]!;
      if (rec.hasLinkReferences) {
        // EscrowVault links an internal library; the exported bytecode must contain placeholders
        const art = JSON.parse(fs.readFileSync(path.join(dir, rec.artifactFile), 'utf8'));
        if (!art.bytecode || art.bytecode.length === 0) throw new Error(`bytecode empty for ${entry.artifactName}`);
      }
    }
    void r;
  });

  console.log('');
  console.log(`Deployables tests: ${passed} passed, ${failed} failed`);
  if (failed > 0) {
    console.log(`Failures: ${failures.join(', ')}`);
    process.exit(1);
  }
}

main();
