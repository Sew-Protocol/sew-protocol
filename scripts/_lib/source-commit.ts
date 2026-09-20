import { execSync } from 'child_process';

export interface SourceCommit {
  commit: string;
  source: 'env' | 'git' | 'jj' | 'unknown';
  override: boolean;
  dirty: boolean;
}

function run(cmd: string): string | null {
  try {
    const out = execSync(cmd, { cwd: process.cwd(), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    return out.trim() || null;
  } catch {
    return null;
  }
}

/**
 * Resolve source-revision provenance for the deployable bundle.
 *
 * Precedence:
 *  1. GIT_SHA env var (used by CI and the existing deployment ledger) — marked override.
 *  2. `git rev-parse HEAD` (works in CI / git checkouts).
 *  3. `jj log -r @` change id (this repo is developed as a jj workspace).
 *  4. fallback marker for uncommitted/local-only builds.
 */
export function resolveSourceCommit(): SourceCommit {
  const env = process.env.GIT_SHA;
  if (env && env.trim()) {
    return { commit: env.trim(), source: 'env', override: true, dirty: false };
  }

  const git = run('git rev-parse HEAD');
  if (git) {
    const dirtyOut = run('git status --porcelain');
    return { commit: git, source: 'git', override: false, dirty: dirtyOut !== null && dirtyOut.length > 0 };
  }

  const jj = run("jj log -r @ -n 1 --no-graph -T 'change_id'");
  if (jj) {
    return { commit: jj, source: 'jj', override: false, dirty: true };
  }

  return { commit: 'unknown-local', source: 'unknown', override: false, dirty: true };
}
