import fs from 'node:fs';
import path from 'node:path';
import { network, ethers, artifacts, deployments } from 'hardhat';

export function isoStamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, '0');
  return (
    d.getUTCFullYear() +
    pad(d.getUTCMonth() + 1) +
    pad(d.getUTCDate()) +
    'T' +
    pad(d.getUTCHours()) +
    pad(d.getUTCMinutes()) +
    pad(d.getUTCSeconds()) +
    'Z'
  );
}

export function ensureDir(p: string) {
  fs.mkdirSync(p, { recursive: true });
}

export function writeJson(p: string, obj: any) {
  ensureDir(path.dirname(p));
  fs.writeFileSync(p, JSON.stringify(obj, null, 2) + '\n', 'utf-8');
}

export async function snapshotAbi(contractName: string, outDir: string) {
  const artifact = await artifacts.readArtifact(contractName);
  writeJson(path.join(outDir, `${contractName}.abi.json`), artifact.abi);
}

export async function metaBundle() {
  const [signer] = await ethers.getSigners();
  const net = await ethers.provider.getNetwork();
  const blockNumber = await ethers.provider.getBlockNumber();
  const gitSha = process.env.GIT_SHA;
  return {
    network: network.name,
    chainId: Number(net.chainId),
    timestamp: new Date().toISOString(),
    deployer: await signer.getAddress(),
    blockNumber,
    gitSha,
  };
}

export async function addressesBundle() {
  const all = await deployments.all();
  const out: Record<string, string> = {};
  for (const [name, dep] of Object.entries(all)) out[name] = dep.address;
  return out;
}

export function ledgerRoot(): string {
  return path.join(process.cwd(), 'deploy-ledger', network.name, isoStamp());
}
