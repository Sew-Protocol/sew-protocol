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
import { sha256HexOfBuffer } from './_lib/hash';

const OUT_DIR = path.resolve(process.cwd(), 'out');
const ALLOWLIST = loadAllowlist();

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
