Mainnet-Ready Contracts Repo Checklist
A) Repository hygiene and reproducibility (must-have)

Single source of truth README that states:

what the repo contains (contracts only / deploy scripts)

supported networks (e.g. Base, Base Sepolia)

how to run tests (Hardhat + Foundry)

Pinned toolchain versions

.nvmrc or Volta (Node version)

pnpm-lock.yaml committed

Foundry version pinned (e.g. foundry.toml + CI install version)

Deterministic builds

hardhat compile produces stable artifacts

forge build reproducible

Clean env handling

.env.example (no secrets)

.gitignore includes .env, keystores, deploy caches, reports as appropriate

B) Security baseline (must-have)

Threat model / security assumptions

docs/SECURITY_MODEL.md (1–3 pages is fine)

Responsible disclosure

SECURITY.md with a security contact + policy

Static analysis

Slither config + CI run

Mythril (optional but good) or at least documented manual runs

Critical invariants covered

Foundry invariants for:

escrow state machine correctness

snapshot immutability (“new escrows only”)

caps enforcement (if yield modules exist)

pause/unpause semantics

Fuzzing

forge fuzz / property tests for boundary conditions (fees, timeouts, payouts)

Reentrancy and auth review

explicit checklist pass on all external calls

pull patterns for token transfers where appropriate

C) Governance & admin surface (must-have)

Governance docs in repo

docs/governance.md

docs/GOVERNANCE_SURFACE_MAP.md (role → function → lane → delay → bounds)

Role sanity

deployer has no lingering privileged roles

timelock has correct roles

guardian has down-only powers only

Parameter bounds enforced onchain

SettingsValidationLibrary (or equivalents) used everywhere

Slow lane enforcement

queue/activate is enforced onchain for high-impact changes

No per-escrow admin overrides (if guaranteed)

confirm removed functions are actually absent or hard-revert

D) Deployment readiness (must-have)

Deployment scripts

hardhat-deploy tags for:

deploy core contracts

deploy modules

post-deploy wiring (roles, ownership transfers)

Deploy output artifacts

saved addresses per network (json)

ABI export strategy (if consumers need it)

Verification

automated verify script

confirmed verification steps documented

Fork simulation

script to run a “mainnet deploy rehearsal” on a fork

script to simulate governance proposals on fork (queue/execute)

E) Testing completeness (must-have)

Hardhat unit tests

core flows: create escrow → release → refund

dispute flows: raise dispute → resolve with payouts

edge cases: invalid payouts, timeouts, max attachments, pause states

Foundry tests

invariant suite + fuzz tests

gas snapshots for hot paths (optional)

CI

pnpm test runs both HH + Foundry

lint + format + typecheck

slither job

produces artifacts / reports as build outputs

F) Operational runbooks (strongly recommended)

Runbooks

emergency: pause, disable yield, lower caps

recovery: unpause via timelock

standard changes: bounded parameter updates

slow changes: module swap queue → wait → activate

Drill evidence

Base Sepolia rehearsals with tx hashes

fork simulation logs

G) Audit readiness (strongly recommended)

Audit package

scope list (contracts, commit hash)

architecture overview (1–2 pages)

invariants list

known risks + mitigations

Audit log

docs/AUDIT.md with:

auditor name(s)

report links / summaries

fixes linked to commits

Changelog discipline

CHANGELOG.md

release tags (v1.0.0-rc1, v1.0.0)

H) Mainnet transparency (strongly recommended)

Addresses + roles disclosure

deployed addresses

timelock address

governor address

guardian multisig address

treasury address

Parameter snapshot

initial caps, fee bps, timeouts, module addresses

Block explorer links (in docs, not code)

I) Repo security hygiene (must-have)

Secret scanning

GitHub secret scanning enabled

pre-commit hook (optional)

Dependency review

lockfile committed

only necessary deps

no unmaintained crypto libs

License clarity

LICENSE

NOTICE if needed

“Must-pass” release gate (the short list)

If you only enforce one gate before mainnet:

fork deployment rehearsal succeeds

full HH + Foundry suite green

slither clean (or triaged with documented exceptions)

governance surface map matches code

deployer has no privileged roles

emergency + recovery drills performed

Mainnet checklist including deployment and ops:

Mainnet-Ready Contracts + Deployment Repo Checklist

Target chain: Base mainnet
Repo type: Contracts + deployment infra + ops scripts

0. Repo boundary & intent (must-have)

Goal: Make it unambiguous what is and is not in scope.

README.md explicitly states:

this repo contains onchain contracts + deploy + ops

no frontend / backend / indexer code

Base is the only supported mainnet

Folder intent documented:

/contracts → onchain logic only

/deploy → deterministic deployment scripts

/scripts → ops / verification / rehearsal tooling

/docs → governance, security, runbooks

No app-level assumptions baked into contracts

1. Tooling & reproducibility (must-have)

Node version pinned (.nvmrc or Volta)

Package manager locked (pnpm-lock.yaml)

Foundry version pinned and documented

hardhat.config.ts:

Base + Base Sepolia only

chain IDs explicit

Deterministic compilation:

pnpm compile

forge build

.env.example includes:

RPC URL placeholders

private key placeholders

no secrets

2. Deployment infra readiness (must-have)
   Hardhat deploy structure

Clear deploy order (e.g. 00*, 10*, 90\_)

Separate scripts for:

implementations

proxies / initial wiring

post-deploy role transfer

Deploy tags usable individually:

--tags core

--tags governance

--tags modules

Address artifacts

Address JSON per network:

addresses.base.json

addresses.base-sepolia.json

Includes:

core contracts

modules

governor

timelock

guardian multisig

3. Governance & authority transfer (must-have)

docs/governance.md up to date with code

docs/GOVERNANCE_SURFACE_MAP.md matches deployed functions

Deployer role cleanup scripted:

deployer has zero admin roles post-deploy

Timelock roles:

PROPOSER_ROLE → Governor

CANCELLER_ROLE → Governor

EXECUTOR_ROLE → open

timelock is self-admin

Guardian:

pause

disable yield

lower caps

cannot unpause or upgrade

4. Security & invariants (must-have)
   Static & automated analysis

Slither config committed

Slither run clean or triaged

Mythril/manual symbolic review (documented)

Invariants (Foundry)

Escrow lifecycle correctness

Snapshot immutability (“new escrows only”)

Dispute resolution cannot rewrite escrow

Caps enforced at deposit time

Guardian down-only enforcement

Pause/unpause correctness

5. Test coverage (must-have)
   Hardhat (behavioral)

escrow create → release

escrow create → refund

dispute → resolve (multi-payout)

invalid resolution reverts

pause blocks unsafe paths

Foundry (property & fuzz)

fuzz escrow settings bounds

fuzz payout splits

fuzz dispute escalation paths

invariant suite runs in CI

6. Ops & emergency runbooks (must-have)

Docs

docs/RUNBOOK_EMERGENCY.md

docs/RUNBOOK_GOVERNANCE.md

docs/RUNBOOK_UPGRADES.md

Covered scenarios

pause protocol

disable yield module

lower exposure caps

unpause via timelock

slow-lane queue → wait → activate

failed proposal recovery

7. Fork & testnet rehearsals (must-have)
   Base Sepolia

Full deploy rehearsal completed

Governance proposal rehearsal

Emergency drill tx hashes recorded

Fork (Base mainnet fork)

Dry-run full deployment

Simulate:

pause

disable yield

queue + activate module

Logs committed under docs/rehearsals/

8. Verification & transparency (must-have)

Automated contract verification script

Verified on Base explorer

ABI export script (if consumers exist)

Public disclosure doc:

deployed addresses

initial parameters

role assignments

9. Audit readiness (strongly recommended)

docs/SECURITY_MODEL.md

docs/AUDIT.md

Audit scope frozen at commit hash

Fixes linked to commits

Post-audit diff reviewed

10. Repo exclusions (important)
    Should NOT be in this repo

❌ frontend code

❌ backend services

❌ governance UI

❌ off-chain bots (unless purely ops-related)

❌ analytics / dashboards

Acceptable

✅ deploy scripts

✅ fork rehearsal scripts

✅ ops scripts (pause, verify, export)

✅ governance simulation helpers

Mainnet release gate (non-negotiable)

Before first live escrow on Base:

Base Sepolia rehearsal complete

Base fork rehearsal complete

Full test suite green

Governance surface == docs

Deployer has zero power

Emergency drill completed
