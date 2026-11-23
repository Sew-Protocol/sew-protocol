#!/usr/bin/env ts-node
/**
 * Validate an exported deployables bundle.
 *
 * Verifies:
 *  - manifest bundleRoot integrity
 *  - every allow-listed artifact exists
 *  - no non-allow-listed / non-deployable artifact is exported
 *  - file hash, ABI hash, creation & runtime bytecode hashes
 *
 * Usage:
 *   pnpm deployables:validate
 *   pnpm deployables:validate -- <export-dir>
 *   pnpm deployables:validate -- --allowlist <allowlist.json> --export-dir <export-dir>
 */
import * as path from 'path';
import { validateDeployables } from './_lib/deployables/validate';
import { DEFAULT_EXPORT_DIR } from './_lib/deployables/export';
import { DEFAULT_ALLOWLIST_PATH, loadAllowlist } from './_lib/deployables/allowlist';

function main(): void {
  const rawArgs = process.argv.slice(2);
  // `pnpm run <script> -- ...` preserves the CLI separator in process.argv,
  // unlike a direct `ts-node script ...` invocation. Match the exporter and
  // ignore everything through that separator when it is present.
  const separator = rawArgs.indexOf('--');
  const args = separator >= 0 ? rawArgs.slice(separator + 1) : rawArgs;
  let allowlistPath = DEFAULT_ALLOWLIST_PATH;
  let exportDir = DEFAULT_EXPORT_DIR;
  const positional = args.filter((arg) => !arg.startsWith('-'));
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === '--allowlist') {
      const value = args[++i];
      if (!value) throw new Error('--allowlist requires a path');
      allowlistPath = path.resolve(value);
    } else if (arg === '--export-dir') {
      const value = args[++i];
      if (!value) throw new Error('--export-dir requires a path');
      exportDir = path.resolve(value);
    } else if (!arg.startsWith('-')) {
      // Preserve the original single positional argument as export-dir.
      if (positional.length === 1) exportDir = path.resolve(arg);
      else if (allowlistPath === DEFAULT_ALLOWLIST_PATH) allowlistPath = path.resolve(arg);
      else exportDir = path.resolve(arg);
    } else {
      throw new Error(`Unknown argument '${arg}'`);
    }
  }
  const issues = validateDeployables({ exportDir, allowlist: loadAllowlist(allowlistPath) });
  console.log(`✅ Deployables validated (${issues.length} artifact(s) OK): ${exportDir}`);
}

main();
