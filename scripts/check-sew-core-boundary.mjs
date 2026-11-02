import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const packageRoot = 'packages/sew-core';
const allowlist = JSON.parse(fs.readFileSync(path.join(root, packageRoot, 'deployables.allowlist.json'), 'utf8'));
const inventory = JSON.parse(fs.readFileSync(path.join(root, packageRoot, 'source-boundary.json'), 'utf8'));
const failures = [];

function walk(directory, files = []) {
  for (const entry of fs.readdirSync(path.join(root, directory), { withFileTypes: true })) {
    const relativePath = path.posix.join(directory, entry.name);
    if (entry.isDirectory()) walk(relativePath, files);
    else if (relativePath.endsWith('.sol')) files.push(relativePath);
  }
  return files;
}

const packageSolidity = [...walk(`${packageRoot}/contracts`), ...walk(`${packageRoot}/test`)];
for (const relativePath of packageSolidity) {
  const source = fs.readFileSync(path.join(root, relativePath), 'utf8');
  for (const match of source.matchAll(/import\s+(?:[^'";]*?from\s*)?['"]([^'"]+)['"]/g)) {
    const specifier = match[1];
    const resolved = specifier.startsWith('.')
      ? path.posix.normalize(path.posix.join(path.posix.dirname(relativePath), specifier))
      : specifier;
    if (
      resolved === 'contracts' ||
      resolved.startsWith('contracts/') ||
      specifier === 'contracts' ||
      specifier.startsWith('contracts/')
    ) {
      failures.push(`${relativePath} imports full-protocol source ${specifier}`);
    }
  }
}

for (const entry of allowlist.entries) {
  if (entry.sourcePath.startsWith('contracts/')) {
    const sourcePath = path.join(root, packageRoot, entry.sourcePath);
    if (!fs.existsSync(sourcePath)) failures.push(`${entry.artifactName} source is missing: ${sourcePath}`);
  }
}

for (const source of inventory.sources) {
  if (!source.path.startsWith(`${packageRoot}/contracts/`)) failures.push(`inventory source is outside package: ${source.path}`);
  if (!fs.existsSync(path.join(root, source.path))) failures.push(`inventory source is missing: ${source.path}`);
  const duplicate = path.join(root, source.path.replace(`${packageRoot}/`, ''));
  if (fs.existsSync(duplicate)) failures.push(`duplicate canonical source exists: ${duplicate}`);
}

if (failures.length) {
  console.error(failures.join('\n'));
  process.exitCode = 1;
} else {
  console.log(`Sew-core boundary check passed (${packageSolidity.length} package Solidity files, ${inventory.sources.length} inventory sources).`);
}
