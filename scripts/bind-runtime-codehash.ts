#!/usr/bin/env ts-node
/**
 * Bind the deterministic on-chain runtime codehash for the Profile-B deployable closure.
 *
 * For contracts whose deployed runtime has NO library link references and NO immutable
 * references, the on-chain runtime codehash is a pure function of the compiled bytecode:
 *
 *     codehash = keccak256( bytes( deployedBytecode.object minus 0x ) )
 *
 * It does NOT depend on the deployment network, the deployed address, or constructor
 * arguments. So it can be computed deterministically from the A-2 forge build (`out/`)
 * with no live deployment and no gas — this is exactly the A-4 runtime identity binding
 * for those contracts, and a baseSepolia deployment compiled with the same A-2 build
 * settings MUST produce exactly this `eth_getCode` hash.
 *
 * Contracts carrying deployed link references or immutable references are flagged
 * `ADDRESS_DEPENDENT`: their deployed code contains placeholders filled at construction
 * (linked-library address / immutable constructor value), so the on-chain codehash must
 * be read back from a real deployment (or patched from known constructor args) and is
 * not closed-form here.
 *
 * The script also verifies that the current forge `out/` runtime bytecode matches the
 * manifest `runtimeBytecodeSha256` for every closure artifact, confirming `out/` is the
 * A-2 build the manifest was exported from.
 *
 * Usage:
 *   npx ts-node scripts/bind-runtime-codehash.ts
 *   npx ts-node scripts/bind-runtime-codehash.ts config/deployable-allowlist-bondledger.json
 *
 * Complements `scripts/export-deployables.ts` (build identity) and hardhat-deploy/87
 * (local live read-back). Replaces no existing tooling.
 */
import * as fs from 'fs';
import * as path from 'path';
import { createHash } from 'crypto';
import { keccak256, getBytes } from 'ethers';

const MANIFEST_PATH = path.resolve(__dirname, '../deployables-bondledger/manifest.json');
const OUT_DIR = path.resolve(__dirname, '../out');

interface AllowlistEntry {
  artifactName: string;
  contractName?: string;
  sourcePath?: string;
  category?: string;
  scopeHint?: string;
}

function normalizeBytecode(value: string): string {
  let v = value.trim().toLowerCase();
  if (v.startsWith('0x')) v = v.slice(2);
  if (v.length === 0 || !/^[0-9a-f_$]+$/.test(v)) {
    throw new Error(`Invalid bytecode (not hex/placeholders): ${value.slice(0, 40)}...`);
  }
  const ph = v.match(/__\$[0-9a-f]+\$__/g) ?? [];
  for (const p of ph) {
    if (p.slice(3, -3).length === 0) throw new Error(`Malformed library placeholder: ${p}`);
  }
  return v;
}

function bytecodeHash(bytecode: string): string {
  return createHash('sha256').update(normalizeBytecode(bytecode)).digest('hex');
}

function countLinks(lr: Record<string, unknown>): number {
  return Object.keys(lr ?? {}).length;
}

function main(): void {
  const allowlistArg = process.argv[2];
  const allowlist: { entries: AllowlistEntry[] } = allowlistArg
    ? JSON.parse(fs.readFileSync(allowlistArg, 'utf-8'))
    : JSON.parse(fs.readFileSync(path.resolve(__dirname, '../config/deployable-allowlist-bondledger.json'), 'utf-8'));

  if (!fs.existsSync(MANIFEST_PATH)) {
    throw new Error(`Manifest not found at ${MANIFEST_PATH}`);
  }
  const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf-8'));
  const arts = manifest.artifacts as Record<string, { runtimeBytecodeSha256: string }>;

  console.log(`\n🔗 Profile-B runtime codehash binding (A-2 forge build, out/)`);
  console.log(`   bundleRoot: ${manifest.bundleRoot}`);
  const build = {
    compiler: manifest.build?.compiler,
    settings: manifest.build?.settings ?? {},
  };
  console.log(`   build: ${build.compiler?.name} ${build.compiler?.version} / ${build.settings?.evmVersion ?? 'n/a'} / runs ${build.settings?.optimizerRuns ?? 'n/a'} / viaIR ${build.settings?.viaIR ?? 'n/a'}`);
  console.log('');

  let staticCount = 0;
  let dependentCount = 0;

  for (const entry of allowlist.entries) {
    const name = entry.artifactName;
    const rec = arts[name];
    if (!rec) {
      console.log(`   ⚠ ${name.padEnd(44)} not in manifest`);
      continue;
    }
    const artifactPath = path.join(OUT_DIR, `${name}.sol`, `${name}.json`);
    if (!fs.existsSync(artifactPath)) {
      console.log(`   ⚠ ${name.padEnd(44)} no forge artifact at out/${name}.sol/`);
      continue;
    }
    const art = JSON.parse(fs.readFileSync(artifactPath, 'utf-8'));
    const runtimeObj: string = art.deployedBytecode?.object ?? '';
    if (!runtimeObj || runtimeObj === '0x') {
      console.log(`   ⚠ ${name.padEnd(44)} no deployed bytecode (abstract/library?)`);
      continue;
    }

    // 1) Confirm out/ matches the A-2 manifest runtime bytecode hash.
    const manifestMatch = bytecodeHash(runtimeObj) === rec.runtimeBytecodeSha256;

    const linkCount = countLinks(art.deployedBytecode?.linkReferences ?? {});
    const immCount = countLinks(art.deployedBytecode?.immutableReferences ?? {});

    if (linkCount === 0 && immCount === 0) {
      // Fully static: on-chain codehash is closed-form.
      const codehash = keccak256(getBytes(runtimeObj));
      staticCount++;
      console.log(`   ✅ ${name.padEnd(44)} codehash=${codehash}${manifestMatch ? '' : '  (out/ DOES NOT MATCH manifest!)'}`);
    } else {
      dependentCount++;
      const why =
        (linkCount > 0 ? `${linkCount} linked-lib${linkCount > 1 ? 's' : ''}` : '') +
        (linkCount > 0 && immCount > 0 ? ' + ' : '') +
        (immCount > 0 ? `${immCount} immutable${immCount > 1 ? 's' : ''}` : '');
      console.log(`   🔶 ${name.padEnd(44)} ADDRESS_DEPENDENT (${why}); bind via live read-back${manifestMatch ? '' : '  (out/ DOES NOT MATCH manifest!)'}`);
    }

    if (!manifestMatch) {
      console.log(`        ⚠️  manifest runtimeBytecodeSha256 ${rec.runtimeBytecodeSha256} != forge out/ sha256 ${bytecodeHash(runtimeObj)}`);
    }
  }

  console.log('');
  console.log(`   static (deterministic codehash): ${staticCount}`);
  console.log(`   address-dependent (live read-back): ${dependentCount}`);
  console.log('');
  console.log('   NOTE: codehash is keccak256 of the deployed runtime bytes. The manifest\n' +
    '   runtimeBytecodeSha256 is SHA-256 over the normalized bytecode string (ASCII),\n' +
    '   NOT the on-chain codehash — both are provided; do not conflate them.');
}

main();
