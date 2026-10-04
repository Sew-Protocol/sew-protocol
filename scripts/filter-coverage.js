const fs = require('fs');
const path = require('path');

// forge coverage --report lcov writes lcov.info to the repo root (./lcov.info).
// Accept that as the primary source, with coverage/lcov.info as a fallback.
const inRoot = path.join(process.cwd(), 'lcov.info');
const inCoverage = path.join(process.cwd(), 'coverage', 'lcov.info');
const inPath = fs.existsSync(inRoot) ? inRoot : inCoverage;
const outPath = path.join(process.cwd(), 'coverage', 'lcov.filtered.info');

if (!fs.existsSync(inPath)) {
  console.error('lcov.info not found. Run `forge coverage --report lcov` first.');
  process.exit(2);
}

const data = fs.readFileSync(inPath, 'utf8').split(/\r?\n/);
let out = [];
let include = false;
for (let i = 0; i < data.length; i++) {
  const line = data[i];
  if (line.startsWith('SF:')) {
    // Include only project contracts: path contains /contracts/ (or starts with
    // contracts/) AND is not under node_modules or test dirs.
    // node_modules must be checked without a leading slash: forge emits paths like
    // "node_modules/@openzeppelin/contracts/..." which also contain "/contracts/",
    // so dependency sources would otherwise leak into the filtered report.
    const p = line.slice(3);
    const normalized = p.replace(/\\/g, '/');
    if (normalized.includes('node_modules') || normalized.includes('/test/')) {
      include = false;
    } else {
      include = normalized.includes('/contracts/') || normalized.startsWith('contracts/');
    }
  }
  if (include) out.push(line);
}

if (out.length === 0) {
  console.error('No records matched filters; output will be empty.');
}
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, out.join('\n'), 'utf8');
console.log('Wrote filtered lcov to', outPath);
process.exit(0);
