#!/usr/bin/env ts-node
/**
 * Pack an exported deployables bundle into a tarball for local consumption or
 * publication (publication is not mandatory in this phase).
 *
 * Usage:
 *   pnpm deployables:pack
 *   pnpm deployables:pack -- <export-dir>
 */
import * as fs from 'fs';
import * as path from 'path';
import { execSync } from 'child_process';
import { DEFAULT_EXPORT_DIR } from './_lib/deployables/export';
import { readManifest } from './_lib/deployables/validate';

function main(): void {
  const explicit = process.argv[2];
  const exportDir = explicit && !explicit.startsWith('-') ? path.resolve(explicit) : DEFAULT_EXPORT_DIR;
  const manifest = readManifest(exportDir);

  const name = manifest.packageName.replace(/^@/, '').replace(/\//g, '-');
  const version = manifest.bundleVersion;
  const outDir = path.resolve(process.cwd(), 'dist-deployables');
  fs.mkdirSync(outDir, { recursive: true });
  const tarFile = path.join(outDir, `${name}-${version}.tgz`);

  const target = path.join(outDir, 'bundle');
  fs.rmSync(target, { recursive: true, force: true });
  fs.cpSync(exportDir, target, { recursive: true });

  // Repack so the tarball root is the package directory, then clean up.
  execSync(`tar -czf "${tarFile}" -C "${outDir}" bundle`, { stdio: 'inherit' });
  fs.rmSync(target, { recursive: true, force: true });

  console.log(`✅ Packed ${manifest.packageName}@${version} -> ${tarFile}`);
}

main();
