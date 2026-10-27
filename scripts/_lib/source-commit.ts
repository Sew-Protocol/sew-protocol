import { execSync } from 'child_process';

export interface SourceCommit {
  commit: string;
  source: 'env' | 'git' | 'jj' | 'unknown';
  override: boolean;
  dirty: boolean;
}

/** Resolve an environment-supplied revision without treating an override as a cleanliness attestation. */
export function sourceCommitFromEnvironment(
  envCommit: string,
  localGitHead: string | null,
  gitStatus: string | null,
): SourceCommit {
  const commit = envCommit.trim();
  const matchesCheckout = localGitHead !== null && localGitHead.toLowerCase() === commit.toLowerCase();
  return {
    commit,
    source: 'env',
    override: true,
    // A revision override says which commit to label; it does not prove the
    // exported artifacts came from that clean checkout. Fail closed unless
    // the checkout identity matches and Git explicitly reports no changes.
    dirty: !matchesCheckout || gitStatus === null || gitStatus.length > 0,
  };
}

function run(cmd: string): string | null {
  try {
    const out = execSync(cmd, { cwd: process.cwd(), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    // Preserve a successful command's empty output (notably a clean
    // `git status --porcelain`) so it cannot be confused with a failed check.
    return out.trim();
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
 *  3. `jj log -r @-` commit id when the jj working copy is clean.
 *  4. fallback marker for uncommitted/local-only builds.
 */
export function resolveSourceCommit(): SourceCommit {
  const env = process.env.GIT_SHA;
  if (env && env.trim()) {
    const commit = env.trim();
    const head = run('git rev-parse HEAD');
    const status = head && head.toLowerCase() === commit.toLowerCase() ? run('git status --porcelain') : null;
    return sourceCommitFromEnvironment(commit, head, status);
  }

  const git = run('git rev-parse HEAD');
  if (git) {
    const dirtyOut = run('git status --porcelain');
    return { commit: git, source: 'git', override: false, dirty: dirtyOut === null || dirtyOut.length > 0 };
  }

  const jjStatus = run('jj status --no-pager');
  const jj = jjStatus?.includes('Working copy clean')
    ? run("jj log -r @- -n 1 --no-graph -T 'commit_id'")
    : null;
  if (jj) {
    return { commit: jj, source: 'jj', override: false, dirty: false };
  }

  const jjWorkingCopy = run("jj log -r @ -n 1 --no-graph -T 'change_id'");
  if (jjWorkingCopy) return { commit: jjWorkingCopy, source: 'jj', override: false, dirty: true };

  return { commit: 'unknown-local', source: 'unknown', override: false, dirty: true };
}
