# Branching & release discipline (Base Sepolia + mainnet readiness)

**Last updated:** 2026-01-19  
**Goal:** keep deployments reproducible and auditable while allowing parallel development.

---

## Principles (non-negotiable)

1) **Deployments must be reproducible**
- A deployment must map to exactly one git commit (tagged).
- Deployment artifacts must be regenerated on that commit (address index + version report + registry).

2) **Release lines must stay small**
- Avoid unrelated refactors, file moves, lint cleanups, and compiler setting changes on a release branch.
- Anything that changes bytecode unintentionally can break verification and partner integration.

3) **Append-only discipline**
- Do not “upgrade-in-place” module contracts; deploy new modules and swap references (where supported).
- Treat address registries and release tags as append-only history. See:
  - `docs/reference/MODULE_SWAPPING_STRATEGY.md`

---

## Branch model (recommended)

### `release/base-sepolia-ieo`
**Purpose:** the deployable line for the next Base Sepolia IEO / integration release.

**Allowed changes:**
- essential contract fixes that will be deployed in the next Base Sepolia release
- deployment scripts required for that release
- release docs + address index + registry updates
- fork/live validation scripts that will be used to validate the release

**Not allowed:**
- directory reorganizations, mass reformatting, non-essential lint cleanups
- speculative features not shipping in the next testnet release (e.g. Aave if excluded)
- compiler setting changes mid-stream (optimizer/viaIR/evmVersion) unless explicitly part of the release plan

### `next/aave`
**Purpose:** development line for Aave yield integration and any required escrow changes.

**Allowed changes:**
- changes to `BaseEscrow`/`YieldOps`/yield modules needed to make Aave integration correct
- Aave-specific tests (Foundry + Hardhat + fork/live)
- emergency / recovery tooling needed for yield custody safety

**Not allowed:**
- merging into release branch until the integration is “done enough” (explicitly cherry-picked when ready)

### `testnet/validation`
**Purpose:** continuous testing against the **already deployed** contracts (and forks pinned to them).

This is where you keep:
- fork-based Phase 0/Phase 1 health checks (wiring/roles/E2E)
- live testnet journeys (opt-in via `LIVE_TESTS=YES`)
- regression scripts that detect deployment drift or broken governance assumptions

**Merge policy:**
- This branch can be merged into `release/base-sepolia-ieo` when a validator becomes a release gate.
- Otherwise it can flow into `main` for ongoing quality.

### `main`
**Purpose:** the canonical long-lived branch.

**Policy:**
- `release/*`, `next/*`, and `testnet/*` should periodically merge back into `main` so tags and docs are not stranded.
- Treat `main` as “what we’d ship next” once the release branch is cut.

---

## Worktrees (recommended for parallel work)

To work on `release/base-sepolia-ieo` and `next/aave` simultaneously without constant checkout churn, use git worktrees:

```bash
# From repo root
git worktree add ../hardhat-deploy-hybrid-release release/base-sepolia-ieo
git worktree add ../hardhat-deploy-hybrid-aave next/aave
git worktree add ../hardhat-deploy-hybrid-validation testnet/validation
```

**Cursor note:** open each worktree folder as a separate workspace window. This avoids mixing node_modules artifacts and reduces accidental cross-branch edits.

---

## “Release snapshot” checklist (Base Sepolia)

Every Base Sepolia release should include, on the same commit:

1) **Regenerate machine snapshot**
- `deployments/baseSepolia/reports/version-report.json` via:
  - `pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia.ts`

2) **Update deployment registry (append-only)**
- `deploy-registry/chain-84532.json` (new entries appended)

3) **Update human address index**
- `docs/deployment/deployed.md` (addresses hyperlinked)
- `docs/deployment/BASE_SEPOLIA_CORE_TESTNET_GUIDE.md` if its index table needs updating

4) **Verify sources (as able)**
- `pnpm hardhat run --network baseSepolia scripts/verify-base-sepolia-sources.ts`

5) **Tag the commit**
- Use an annotated tag:
  - example: `basesepolia/ieo-v0.2.1-2026-01-20`
- The tag message should include:
  - deployer address
  - chainId
  - a short scope summary
  - link to the canonical address list doc

---

## Backport rules (how changes move between branches)

### Into `release/base-sepolia-ieo`
- Prefer **small, explicit cherry-picks** from `next/*` or `testnet/validation`.
- Each cherry-pick should clearly state why it is release-blocking.

### Into `main`
- After a release is shipped (or you decide not to ship it), merge `release/*` into `main`.
- Merge `testnet/validation` into `main` regularly so regression tooling stays current.

