#!/usr/bin/env ts-node
/**
 * Export deployable artifacts.
 *
 * Reads the allow-list (config/deployable-allowlist.json) and the repository's
 * native Foundry build (out/) and writes a deterministic deployable bundle
 * under deployables/ (manifest.json + artifacts/ + build-info/).
 *
 * Usage:
 *   pnpm deployables:export
 *   GIT_SHA=<sha> pnpm deployables:export   # optional revision label; must match a clean Git checkout to qualify as clean
 *   pnpm deployables:export -- <allowlist-path> [export-dir] [--out-dir <forge-output>]
 */
import * as path from 'path';
import { exportDeployables, DEFAULT_EXPORT_DIR, DEFAULT_OUT_DIR } from './_lib/deployables/export';
import { validateDeployables } from './_lib/deployables/validate';
import { loadAllowlist, DEFAULT_ALLOWLIST_PATH } from './_lib/deployables/allowlist';

function main(): void {
  let allowlistPath: string | undefined;
  let exportDir: string | undefined;
  let outDir: string | undefined;

  const pos = process.argv.indexOf('--');
  if (pos >= 0) {
    const positional: string[] = [];
    const args = process.argv.slice(pos + 1);
    for (let i = 0; i < args.length; i++) {
      const arg = args[i]!;
      if (arg === '--out-dir') {
        const value = args[++i];
        if (!value) throw new Error('--out-dir requires a path');
        outDir = path.resolve(value);
      } else if (!arg.startsWith('-')) positional.push(arg);
      else throw new Error(`Unknown argument '${arg}'`);
    }
    allowlistPath = positional[0] ? path.resolve(positional[0]) : DEFAULT_ALLOWLIST_PATH;
    exportDir = positional[1] ? path.resolve(positional[1]) : undefined;
  }

  const allowlist = loadAllowlist(allowlistPath ?? DEFAULT_ALLOWLIST_PATH);
  // Always export into a profile-scoped directory so distinct bundles (Profile A and B)
  // never overwrite one another; default stays DEFAULT_EXPORT_DIR for the default profile.
  const resolvedExportDir = exportDir ?? (allowlist.buildProfile === 'default' ? DEFAULT_EXPORT_DIR : undefined);
  if (!resolvedExportDir) {
    throw new Error(
      `Profile '${allowlist.buildProfile}' requires an explicit export-dir; pass: deployables:export -- <allowlist> <export-dir>`,
    );
  }

  const result = exportDeployables({ allowlist, exportDir: resolvedExportDir, outDir: outDir ?? DEFAULT_OUT_DIR });
  // Immediately validate what we just exported.
  validateDeployables({ allowlist, exportDir: result.exportDir });

  const n = Object.keys(result.manifest.artifacts).length;
  console.log(`✅ Exported ${n} deployable artifact(s) -> ${path.relative(process.cwd(), result.exportDir)}`);
  console.log(`   profile:   ${result.manifest.build.profile}`);
  console.log(`   package:   ${result.manifest.packageName}@${result.manifest.bundleVersion}`);
  console.log(`   commit:    ${result.manifest.source.commit} (${result.manifest.source.commitSource}${result.manifest.source.dirty ? ', dirty' : ''})`);
  console.log(`   compiler:  ${result.manifest.build.compiler.name} ${result.manifest.build.compiler.version}`);
  console.log(`   bundleRoot:${result.manifest.bundleRoot}`);
}

main();
