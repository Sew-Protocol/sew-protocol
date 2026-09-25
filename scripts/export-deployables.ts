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
 *   SEW_SOURCE_COMMIT=<sha> pnpm deployables:export   # optional commit override
 *   pnpm deployables:export -- <allowlist-path> [export-dir]   # non-default profile/bundle
 */
import * as path from 'path';
import { exportDeployables, DEFAULT_EXPORT_DIR, DEFAULT_OUT_DIR } from './_lib/deployables/export';
import { validateDeployables } from './_lib/deployables/validate';
import { loadAllowlist, DEFAULT_ALLOWLIST_PATH } from './_lib/deployables/allowlist';

function main(): void {
  let allowlistPath: string | undefined;
  let exportDir: string | undefined;

  const pos = process.argv.indexOf('--');
  if (pos >= 0) {
    const args = process.argv.slice(pos + 1).filter((a) => a.length > 0 && !a.startsWith('-'));
    allowlistPath = args[0] ? path.resolve(args[0]) : DEFAULT_ALLOWLIST_PATH;
    exportDir = args[1] ? path.resolve(args[1]) : undefined;
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

  const result = exportDeployables({ allowlist, exportDir: resolvedExportDir });
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
