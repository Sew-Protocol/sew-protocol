/**
 * Deterministic JSON serialization.
 *
 * Object keys are sorted recursively, `undefined` fields are omitted, bigint
 * values serialize as decimal strings, and a fixed indent produces identical
 * bytes for identical logical content. This guarantees deterministic export
 * and stable hashes regardless of property insertion order.
 */

type Compat = string | number | boolean | null | bigint | Compat[] | { [k: string]: Compat };

function serialize(value: Compat, indent: number, depth: number): string {
  const pad = (n: number): string => ' '.repeat(n);
  if (value === null) return 'null';
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new Error('Cannot serialize non-finite number');
    return JSON.stringify(value);
  }
  if (typeof value === 'bigint') return JSON.stringify(value.toString());
  if (typeof value === 'string') return JSON.stringify(value);
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const inner = value.map((v) => `${pad(indent + depth)}${serialize(v, indent, depth + 1)}`);
    return `[\n${inner.join(',\n')}\n${pad(indent + depth - indent)}]`;
  }
  const keys = Object.keys(value)
    .filter((k) => (value as Record<string, unknown>)[k] !== undefined)
    .sort();
  if (keys.length === 0) return '{}';
  const inner = keys.map(
    (k) => `${pad(indent + depth)}${JSON.stringify(k)}: ${serialize((value as Record<string, Compat>)[k]!, indent, depth + 1)}`,
  );
  return `{\n${inner.join(',\n')}\n${pad(indent + depth - indent)}}`;
}

/** Deterministic, pretty-printed JSON with sorted keys. */
export function stableStringify(value: unknown, indent = 2): string {
  return serialize(value as Compat, indent, 0);
}

/** Deterministic compact JSON (sorted keys, no whitespace) for hashing. */
export function canonicalJson(value: unknown): string {
  const pretty = serialize(value as Compat, 0, 0);
  return pretty.replace(/\n\s*/g, '');
}
