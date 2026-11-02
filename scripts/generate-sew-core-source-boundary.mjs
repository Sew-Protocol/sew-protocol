import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const allowlistPath = 'packages/sew-core/deployables.allowlist.json';
const outputPath = 'packages/sew-core/source-boundary.json';
const allowlist = JSON.parse(fs.readFileSync(path.join(root, allowlistPath), 'utf8'));
const solidityFiles = [];

function walk(directory) {
  for (const entry of fs.readdirSync(path.join(root, directory), { withFileTypes: true })) {
    const relativePath = path.posix.join(directory, entry.name);
    if (entry.isDirectory()) walk(relativePath);
    else if (relativePath.endsWith('.sol')) solidityFiles.push(relativePath);
  }
}

walk('contracts');
walk('packages/sew-core/contracts');
walk('test/foundry');
walk('packages/sew-core/test');

const importsByFile = new Map();
for (const relativePath of solidityFiles) {
  const source = fs.readFileSync(path.join(root, relativePath), 'utf8');
  const imports = [];
  for (const match of source.matchAll(/import\s+(?:[^'";]*?from\s*)?['"]([^'"]+)['"]/g)) {
    if (match[1].startsWith('.')) {
      imports.push(path.posix.normalize(path.posix.join(path.posix.dirname(relativePath), match[1])));
    }
  }
  importsByFile.set(relativePath, imports);
}

const roots = allowlist.entries
  .map(({ sourcePath }) => sourcePath)
  .filter((sourcePath) => sourcePath.startsWith('contracts/'))
  .map((sourcePath) => path.posix.join('packages/sew-core', sourcePath));
const closure = new Set();
const pending = [...roots];
while (pending.length) {
  const relativePath = pending.pop();
  if (closure.has(relativePath)) continue;
  closure.add(relativePath);
  for (const importedPath of importsByFile.get(relativePath) ?? []) {
    if (importedPath.startsWith('packages/sew-core/contracts/')) pending.push(importedPath);
  }
}

const sources = [...closure].sort().map((relativePath) => {
  const directOutsideConsumers = [...importsByFile]
    .filter(([consumerPath, imports]) => !closure.has(consumerPath) && imports.includes(relativePath))
    .map(([consumerPath]) => consumerPath)
    .sort();
  return {
    path: relativePath,
    canonicalOwner: '@sew/sew-core',
    consumerScope: directOutsideConsumers.length
      ? 'used-outside-deployable-source-closure'
      : 'package-internal-source-only',
    directOutsideConsumers,
  };
});

const outsideConsumers = sources.flatMap(({ directOutsideConsumers }) => directOutsideConsumers);
const output = {
  schemaVersion: 1,
  generatedFrom: allowlistPath,
  method: 'Recursive resolution of relative Solidity imports from local allowlist roots; direct importers outside that closure are listed. OpenZeppelin dependencies are excluded.',
  summary: {
    localSoliditySources: sources.length,
    withOutsideDirectConsumers: sources.filter(({ directOutsideConsumers }) => directOutsideConsumers.length).length,
    withoutOutsideDirectConsumers: sources.filter(({ directOutsideConsumers }) => !directOutsideConsumers.length).length,
    distinctOutsideContractConsumers: new Set(outsideConsumers.filter((consumer) => consumer.startsWith('contracts/'))).size,
    distinctOutsideTestConsumers: new Set(outsideConsumers.filter((consumer) => consumer.startsWith('test/'))).size,
    packageOwnedTestConsumers: new Set(outsideConsumers.filter((consumer) => consumer.startsWith('packages/sew-core/test/'))).size,
  },
  sources,
};

const outputFile = path.join(root, outputPath);
const serializedOutput = `${JSON.stringify(output, null, 2)}\n`;
if (process.argv.includes('--check')) {
  if (!fs.existsSync(outputFile) || fs.readFileSync(outputFile, 'utf8') !== serializedOutput) {
    console.error(`${outputPath} is stale; run the Sew-core source:inventory command.`);
    process.exitCode = 1;
  } else {
    console.log(`Sew-core source inventory is current (${sources.length} local Solidity sources).`);
  }
} else {
  fs.writeFileSync(outputFile, serializedOutput);
  console.log(`Wrote ${outputPath} (${sources.length} local Solidity sources).`);
}
