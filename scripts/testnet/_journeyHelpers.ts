import { ethers } from 'ethers';

export const ESCROW_STATE = {
  NONE: 0,
  PENDING: 1,
  RELEASED: 2,
  REFUNDED: 3,
  DISPUTED: 4,
  RESOLVED: 5,
} as const;

export const SENDER_STATUS = {
  NONE: 0,
  AGREE_TO_CANCEL: 1,
  RAISE_DISPUTE: 2,
} as const;

export const RECIPIENT_STATUS = {
  NONE: 0,
  AGREE_TO_CANCEL: 1,
  RAISE_DISPUTE: 2,
} as const;

export function envNumber(name: string, defaultValue: number): number {
  const v = process.env[name];
  if (!v) return defaultValue;
  const n = Number(v);
  if (!Number.isFinite(n) || n < 0) throw new Error(`Invalid ${name}: ${v}`);
  return n;
}

export function envBool(name: string, defaultValue: boolean): boolean {
  const v = process.env[name];
  if (!v) return defaultValue;
  return v === '1' || v.toLowerCase() === 'true' || v.toLowerCase() === 'yes';
}

export function envStr(name: string): string | undefined {
  const v = process.env[name];
  if (!v) return undefined;
  const trimmed = v.trim();
  return trimmed.length ? trimmed : undefined;
}

export function envFirst(...names: string[]): string | undefined {
  for (const n of names) {
    const v = envStr(n);
    if (v) return v;
  }
  return undefined;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function basescanAddressLink(address: string): string {
  return `https://sepolia.basescan.org/address/${address}`;
}

export function normalizeAddressLike(input: string): string {
  const withoutComments = input.split('//')[0].split('#')[0].trim();
  return withoutComments.split(/\s+/)[0] ?? '';
}

export function requireAddress(name: string, value: string): string {
  const normalized = normalizeAddressLike(value);
  if (!ethers.isAddress(normalized)) {
    throw new Error(`Invalid ${name}: "${value}" (parsed as "${normalized}")`);
  }
  return ethers.getAddress(normalized);
}

export function assert(condition: any, msg: string): asserts condition {
  if (!condition) throw new Error(msg);
}

export async function retry<T>(
  label: string,
  fn: () => Promise<T>,
  opts?: { attempts?: number; delayMs?: number }
): Promise<T> {
  const attempts = opts?.attempts ?? 12;
  const delayMs = opts?.delayMs ?? 1500;
  let lastErr: any = null;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (e: any) {
      lastErr = e;
      const msg = e?.shortMessage || e?.reason || e?.message || String(e);
      if (i < attempts - 1) {
        // Common on load-balanced RPCs right after a tx:
        // - node is behind, array index out-of-bounds panics, or "header not found"
        // Keep the message so the user can see what's happening.
        // eslint-disable-next-line no-console
        console.log(`  retry(${label}) [${i + 1}/${attempts}] due to: ${msg}`);
        await sleep(delayMs);
        continue;
      }
    }
  }
  throw new Error(`Failed after retries (${label}): ${lastErr?.shortMessage || lastErr?.message || lastErr}`);
}

