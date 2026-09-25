// Read-only: read back on-chain runtime codehash (keccak256 of eth_getCode)
// for all deployed anvil contracts. Deterministic, no state mutation.
const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

async function main() {
  const dir = 'deployments/anvil';
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.json') && f !== '.chainId');
  const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545');
  const rows = [];
  for (const file of files.sort()) {
    const name = file.replace(/\.json$/, '');
    if (name.startsWith('solcInputs')) continue;
    const j = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
    if (!j.address) continue;
    const code = await provider.getCode(j.address);
    const codehash = ethers.keccak256(code);
    const size = (code.length - 2) / 2;
    rows.push({ name, address: j.address, runtimeCodehash: codehash, runtimeBytes: size });
  }
  console.log('\n=== ANVIL ON-CHAIN RUNTIME CODEHASH READ-BACK (keccak256 of eth_getCode) ===');
  for (const r of rows.sort((a, b) => a.name.localeCompare(b.name))) {
    console.log(`${r.name.padEnd(42)} ${String(r.runtimeBytes).padStart(6)}B  ${r.runtimeCodehash}`);
  }
  fs.writeFileSync('/tmp/anvil-codehash-readback.json', JSON.stringify(rows, null, 2));
  console.log('\nwrote /tmp/anvil-codehash-readback.json');
}

main().catch((e) => { console.error(e); process.exit(1); });
