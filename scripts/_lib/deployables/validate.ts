import * as fs from 'fs';
import * as path from 'path';
import { ConfigError } from './errors';
import { sha256Hex, sha256HexOfBuffer, bytecodeHash, normalizeBytecode } from '../hash';
import { canonicalJson, stableStringify } from '../canonical-json';
import type { Manifest, ManifestArtifactRecord, ExportedArtifactFile, Allowlist } from './types';
import { loadAllowlist } from './allowlist';

export interface ValidationIssue {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

/**
 * Validate an exported deployables directory against its manifest and the
 * allow-list. Throws ConfigError on the first failure; returns the list of
 * checks performed on success.
 */
export function validateDeployables(opts: {
  exportDir: string;
  allowlist?: Allowlist;
  allowlistPath?: string;
}): ValidationIssue[] {
  const exportDir = opts.exportDir;
  const allowlist = opts.allowlist ?? loadAllowlist(opts.allowlistPath);

  const manifest = readManifest(exportDir);
  const issues: ValidationIssue[] = [];
  const fail = (code: string, message: string, details?: Record<string, unknown>): never => {
    throw new ConfigError(code, message, details);
  };

  // --- bundle root integrity -------------------------------------------------
  const { bundleRoot, ...rest } = manifest as Manifest & { bundleRoot: string };
  const recomputedRoot = sha256Hex(canonicalJson(rest));
  if (recomputedRoot !== manifest.bundleRoot) {
    fail('BUNDLE_ROOT_MISMATCH', `Manifest bundleRoot mismatch: expected ${manifest.bundleRoot}, got ${recomputedRoot}`);
  }

  // --- allow-listed artifacts must exist in manifest --------------------------
  for (const entry of allowlist.entries) {
    if (!manifest.artifacts[entry.artifactName]) {
      fail('ALLOWLISTED_MISSING', `Allow-listed artifact '${entry.artifactName}' missing from manifest`);
    }
  }

  // --- every manifest artifact must be allow-listed (no extra exports) --------
  const allowed = new Set(allowlist.entries.map((e) => e.artifactName));
  for (const name of Object.keys(manifest.artifacts)) {
    if (!allowed.has(name)) {
      fail('NON_ALLOWLISTED_EXPORTED', `Manifest contains '${name}' which is not on the allow-list`);
    }
  }

  // --- artifact files on disk must match allow-list exactly --------------------
  const artifactsDir = path.join(exportDir, 'artifacts');
  const filesOnDisk = fs.existsSync(artifactsDir) ? fs.readdirSync(artifactsDir) : [];
  const expectedFiles = allowlist.entries.map((e) => `${e.artifactName}.json`).sort();
  const actualFiles = filesOnDisk.filter((f) => f.endsWith('.json')).sort();
  const diff = (a: string[], b: string[]) => {
    const onlyA = a.filter((x) => !b.includes(x));
    const onlyB = b.filter((x) => !a.includes(x));
    return { onlyA, onlyB };
  };
  const d = diff(actualFiles, expectedFiles);
  if (d.onlyA.length > 0) {
    fail('NON_DEPLOYABLE_EXPORTED', `Exported artifact files not on allow-list: ${d.onlyA.join(', ')}`);
  }
  if (d.onlyB.length > 0) {
    fail('ALLOWLISTED_FILE_MISSING', `Allow-listed artifact files missing on disk: ${d.onlyB.join(', ')}`);
  }

  // --- per-artifact integrity ---------------------------------------------------
  for (const entry of allowlist.entries) {
    const record = manifest.artifacts[entry.artifactName]!;
    verifyArtifact(entry.artifactName, record, exportDir, fail);
    issues.push({ code: 'ARTIFACT_OK', message: `artifact '${entry.artifactName}' verified` });
  }

  return issues;
}

function verifyArtifact(
  artifactName: string,
  record: ManifestArtifactRecord,
  exportDir: string,
  fail: (code: string, message: string, details?: Record<string, unknown>) => never,
): void {
  const filePath = path.join(exportDir, record.artifactFile);
  if (!fs.existsSync(filePath)) {
    fail('ARTIFACT_FILE_MISSING', `Artifact file missing: ${record.artifactFile}`);
  }
  const fileBuf = fs.readFileSync(filePath);
  const fileSha = sha256HexOfBuffer(fileBuf);
  if (fileSha !== record.fileSha256) {
    fail('ARTIFACT_FILE_HASH_MISMATCH', `File hash mismatch for ${artifactName}: expected ${record.fileSha256}, got ${fileSha}`);
  }

  let exported: ExportedArtifactFile;
  try {
    exported = JSON.parse(fileBuf.toString('utf8')) as ExportedArtifactFile;
  } catch (e) {
    fail('ARTIFACT_UNREADABLE', `Cannot parse artifact ${artifactName}: ${e instanceof Error ? e.message : String(e)}`);
  }

  normalizeBytecode(exported.bytecode);
  normalizeBytecode(exported.deployedBytecode);

  const abiSha = sha256Hex(canonicalJson(exported.abi));
  if (abiSha !== record.abiSha256) {
    fail('ABI_HASH_MISMATCH', `ABI hash mismatch for ${artifactName}`);
  }
  const creationSha = bytecodeHash(exported.bytecode);
  if (creationSha !== record.creationBytecodeSha256) {
    fail('CREATION_BYTECODE_HASH_MISMATCH', `Creation bytecode hash mismatch for ${artifactName}`);
  }
  const runtimeSha = bytecodeHash(exported.deployedBytecode);
  if (runtimeSha !== record.runtimeBytecodeSha256) {
    fail('RUNTIME_BYTECODE_HASH_MISMATCH', `Runtime bytecode hash mismatch for ${artifactName}`);
  }
}

export function readManifest(exportDir: string): Manifest {
  const p = path.join(exportDir, 'manifest.json');
  if (!fs.existsSync(p)) {
    throw new ConfigError('MANIFEST_MISSING', `Manifest not found at ${p}`);
  }
  let m: Manifest;
  try {
    m = JSON.parse(fs.readFileSync(p, 'utf8')) as Manifest;
  } catch (e) {
    throw new ConfigError('MANIFEST_UNREADABLE', `Cannot parse manifest at ${p}: ${e instanceof Error ? e.message : String(e)}`);
  }
  if (m.schemaVersion !== 1) {
    throw new ConfigError('MANIFEST_SCHEMA', `Unsupported manifest schemaVersion ${m.schemaVersion}`);
  }
  return m;
}
