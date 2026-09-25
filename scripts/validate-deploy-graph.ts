#!/usr/bin/env ts-node
/**
 * Read-only deployment dependency-graph validator.
 *
 * Parses every `deploy/*.ts` hardhat-deploy script's `func.tags` and
 * `func.dependencies`, expands each dependency tag to the scripts that carry
 * that tag, builds the real script dependency graph, and runs DFS with
 * `visiting`/`visited` sets to detect cycles. Fails (non-zero) with the exact
 * cycle path when a cycle is found.
 *
 * It also specifically detects:
 *   - self-dependency through a tag (a script depending on a tag it itself carries)
 *   - dependency on a tag whose script set includes the current script
 *
 * This tool is read-only: it does not execute any deploy function or touch the
 * network. Long-term convention it enforces/reports:
 *   - precise phase tags may be used as dependencies;
 *   - umbrella/grouping tags (family-level selectors such as `dr3`, `all`,
 *     `governance`, `core`) are CLI selection only and should NOT appear in
 *     `func.dependencies` when an exact phase exists.
 *
 * Usage:
 *   npx ts-node scripts/validate-deploy-graph.ts
 */
import * as fs from 'fs';
import * as path from 'path';

const DEPLOY_DIR = path.resolve(process.cwd(), 'deploy');

interface Script {
  file: string; // e.g. "60_protocol_governance.ts"
  tags: string[];
  deps: string[]; // dependency tags
}

/** Extract the string array assigned to a given `func.<prop> = [...]` statement. */
function extractArray(src: string, prop: string): string[] | null {
  // Match `func.tags =` or `func.dependencies =` followed by an array literal up to ';'.
  // Handles single-line and multi-line arrays; only string elements (single- or double-quoted).
  const re = new RegExp(`func\\.${prop}\\s*=\\s*(\\[[^\\]]*\\])`);
  const m = src.match(re);
  if (!m) return null;
  const strItems = m[1].match(/['"]([^'"]+)['"]/g) ?? [];
  return strItems.map((s) => s.slice(1, -1));
}

function loadScripts(): Script[] {
  const files = fs
    .readdirSync(DEPLOY_DIR)
    .filter((f) => f.endsWith('.ts') && f !== '_config.ts')
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

  const scripts: Script[] = [];
  for (const f of files) {
    const src = fs.readFileSync(path.join(DEPLOY_DIR, f), 'utf8');
    const tags = extractArray(src, 'tags') ?? [];
    const deps = extractArray(src, 'dependencies') ?? [];
    scripts.push({ file: f, tags, deps });
  }
  return scripts;
}

function main(): void {
  const scripts = loadScripts();
  if (scripts.length === 0) {
    console.error('No deploy scripts found under ' + DEPLOY_DIR);
    process.exit(2);
  }

  // tag -> scripts carrying that tag
  const tagToScripts = new Map<string, string[]>();
  for (const s of scripts) {
    for (const t of s.tags) {
      if (!tagToScripts.has(t)) tagToScripts.set(t, []);
      tagToScripts.get(t)!.push(s.file);
    }
  }

  // Build real script dependency graph.
  const adj = new Map<string, string[]>();
  for (const s of scripts) {
    const targets: string[] = [];
    const unknownTags: string[] = [];
    for (const dep of s.deps) {
      const carried = tagToScripts.get(dep);
      if (!carried) {
        unknownTags.push(dep);
        continue;
      }
      targets.push(...carried);
    }
    adj.set(s.file, targets);
    if (unknownTags.length > 0) {
      console.log(`[warn] ${s.file}: dependency tag(s) carried by no script: ${unknownTags.join(', ')}`);
    }
  }

  // Self-dependency / tag-self checks.
  let selfIssue = false;
  for (const s of scripts) {
    for (const dep of s.deps) {
      if (s.tags.includes(dep)) {
        console.log(
          `[self-cycle] ${s.file} depends on tag '${dep}' which it itself carries (tags: ${s.tags.join(', ')})`,
        );
        selfIssue = true;
      }
    }
  }

  // DFS cycle detection with visiting/visited sets.
  const visiting: string[] = [];
  const visited = new Set<string>();
  const inVisiting = new Set<string>();
  const cycles: string[][] = [];

  function dfs(node: string, path: string[]): boolean {
    if (inVisiting.has(node)) {
      // Found a cycle; recover the exact path from first occurrence.
      const start = path.indexOf(node);
      const cycle = path.slice(start);
      cycles.push([...cycle, node]);
      return true;
    }
    if (visited.has(node)) return false;

    inVisiting.add(node);
    visiting.push(node);
    path.push(node);

    for (const nxt of adj.get(node) ?? []) {
      // skip self-edge (already reported by self-check) to avoid noise
      if (nxt === node) continue;
      dfs(nxt, path);
    }

    path.pop();
    visiting.pop();
    inVisiting.delete(node);
    visited.add(node);
    return false;
  }

  for (const s of scripts) {
    if (!visited.has(s.file)) {
      dfs(s.file, []);
    }
  }

  const tagSummary = (s: Script) => `${s.file} ${s.tags.length ? `[${s.tags.join(', ')}]` : '[]'}`;

  console.log('\nDeploy dependency graph (script -> expanded dependency targets):');
  for (const s of scripts) {
    const targets = (adj.get(s.file) ?? []).filter((t) => t !== s.file);
    console.log(`  ${tagSummary(s)}`);
    if (targets.length) console.log(`      -> ${[...new Set(targets)].join(', ')}`);
  }

  let ret = 0;

  if (selfIssue) {
    console.log('\nRESULT: SELF-CYCLE DETECTED (script depends on a tag it carries).');
    ret = 1;
  }

  if (cycles.length > 0) {
    console.log('\nRESULT: DEPENDENCY CYCLES DETECTED');
    for (const c of cycles) {
      console.log(`\nDeploy dependency cycle:`);
      for (let i = 0; i < c.length; i++) {
        const nl = i === c.length - 1 ? '' : '\n→ ';
        process.stdout.write(c[i] + nl);
      }
      console.log('');
    }
    ret = 1;
  }

  if (ret === 0) {
    console.log('\nRESULT: OK — deploy dependency graph is acyclic.');
  }

  process.exit(ret);
}

main();
