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
 */
import * as path from 'path';
import { exportDeployables, DEFAULT_EXPORT_DIR } from './_lib/deployables/export';
import { validateDeployables } from './_lib/deployables/validate';

function main(): void {
  const result = exportDeployables();
  // Immediately validate what we just exported.
  validateDeployables({ exportDir: result.exportDir });

  const n = Object.keys(result.manifest.artifacts).length;
  console.log(`✅ Exported ${n} deployable artifact(s) -> ${path.relative(process.cwd(), result.exportDir)}`);
  console.log(`   package:   ${result.manifest.packageName}@${result.manifest.bundleVersion}`);
  console.log(`   commit:    ${result.manifest.source.commit} (${result.manifest.source.commitSource}${result.manifest.source.dirty ? ', dirty' : ''})`);
  console.log(`   compiler:  ${result.manifest.build.compiler.name} ${result.manifest.build.compiler.version}`);
  console.log(`   bundleRoot:${result.manifest.bundleRoot}`);
  void DEFAULT_EXPORT_DIR;
}

main();
