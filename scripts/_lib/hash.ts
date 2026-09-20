import { createHash } from 'crypto';

export function sha256Hex(data: string | Buffer): string {
  return createHash('sha256').update(data).digest('hex');
}

export function sha256HexOfBuffer(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex');
}

/**
 * Hash of bytecode (without 0x prefix) interpreted as ASCII characters.
 * Bytecode may contain library link placeholders (`__$<40hex>$__`), so this is
 * not restricted to pure hex. Matches the consumer-side convention in the
 * deployment composition repo.
 */
export function bytecodeHash(bytecode: string): string {
  return sha256Hex(normalizeBytecode(bytecode));
}

/** Normalize bytecode string: lowercase, strip 0x, validate charset/shape. */
export function normalizeBytecode(value: string): string {
  let v = value.trim().toLowerCase();
  if (v.startsWith('0x')) v = v.slice(2);
  if (v.length === 0 || !/^[0-9a-f_$]+$/.test(v)) {
    throw new Error(`Invalid bytecode (not hex/placeholders): ${value.slice(0, 40)}...`);
  }
  // validate placeholder shape if present (foundry uses __$<hex>$__)
  const ph = v.match(/__\$[0-9a-f]+\$__/g) ?? [];
  for (const p of ph) {
    if (p.slice(3, -3).length === 0) throw new Error(`Malformed library placeholder: ${p}`);
  }
  return v;
}

export function isBytecode(value: string): boolean {
  const v = value.trim().toLowerCase().replace(/^0x/, '');
  if (v.length === 0 || !/^[0-9a-f_$]+$/.test(v)) return false;
  const ph = v.match(/__\$[0-9a-f]+\$__/g) ?? [];
  return ph.every((p) => p.slice(3, -3).length > 0);
}

export function normalizeHex(value: string): string {
  let v = value.trim().toLowerCase();
  if (v.startsWith('0x')) v = v.slice(2);
  if (v.length === 0 || !/^[0-9a-f]+$/.test(v)) {
    throw new Error(`Not valid hex: ${value}`);
  }
  return v;
}

export function isHex(value: string): boolean {
  const v = value.trim().toLowerCase().replace(/^0x/, '');
  return v.length > 0 && /^[0-9a-f]+$/.test(v);
}
