# Deployable Artifact Export

`sew-protocol` remains authoritative for SEW Solidity source, compilation,
tests, and production deployable bytecode. This export produces a
**deterministic, immutable, versioned deployable-artifact bundle** that a
separate deployment-composition repository can consume **without recompiling**
SEW source.

```
sew-protocol source
    ↓
native sew-protocol compilation (forge build)
    ↓
existing tests (forge / halmos / invariants)
    ↓
deployable artifact export  (this subsystem)
    ↓
immutable/versioned bundle (deployables/)
    ↓
shared deployment repository
```

This is a **consumer boundary**, not an application SDK, and not a governance
or deployment-composition engine. It states what each contract **is**
(ABI + bytecode + provenance), not how a deployment chooses to govern it.

## Artifact source

The exporter reads the repository's **native, tested build output**: Foundry
`out/` artifacts (`forge build`). It does **not** invoke a second compiler
configuration. The same artifacts validated by the forge test suite are what
get exported. (The Hardhat/`hardhat-deploy` pipeline is used for deployment
execution; see [Assumptions](#assumptions) for the forge-vs-hardhat bytecode
note.)

## Inventory and classification

The current deployable production/system set is enumerated and classified in
`config/deployable-allowlist.json`. Classification is architectural metadata
only; no contracts are moved between repositories.

| Contract | Scope hint | Category | Notes |
|---|---|---|---|
| SewToken | shared | governance | governance voting token |
| GovGovernor | shared | governance | governor |
| TimelockController | shared | governance | OpenZeppelin timelock (external) |
| DefaultReleaseStrategy | shared | governance | release/governance strategy |
| DefaultCancellationStrategy | shared | governance | cancellation/governance strategy |
| EmergencyRecoveryProposal | shared | governance | emergency recovery |
| GuardianOps | shared | ops | guardian operations |
| EscrowGovernanceTimelock | shared | governance | escrow admin timelock |
| L2AddressRegistry | shared | infra | cross-chain address registry |
| EscrowVault | sew | core | core escrow vault |
| EscrowableERC20 | sew | core | escrowable token |
| EscrowCreationPolicy | sew | core | creation policy |
| BondCollector | sew | core | bond collection |
| CREATE2EscrowFactory | sew | core | CREATE2 factory |
| MultiL2ViewAggregator | sew | core | multi-L2 view aggregator |
| ModuleSnapshotRegistry | sew | infra | module snapshot registry |
| AaveYieldModule | sew | yield | Aave integration adapter |
| DecentralizedResolutionModule | sew | resolution | decentralized resolution |
| InsurancePoolVault | sew | resolution | insurance pool |
| ResolverStakingModule | sew | resolution | staking |
| ResolverSlashingModule | sew | resolution | slashing |
| BondTokenRegistry | sew | resolution | bond registry |
| DRMAdminFacet | sew | resolution | DRM admin facet |
| ResolverIncentiveModule | sew | resolution | incentive module |
| PaymentCalculationLibrary | sew | library | deployed (public) library |

A `scopeHint` of `shared` means the contract is **logically shared**
(governance/infrastructure that may serve both PRF and SEW) even though its
source currently lives in `sew-protocol`. This is a **source-level hint only**;
the deployment-composition repository is authoritative for which contracts are
shared, which applications consume them, and which token/governor/timelock
controls which operation groups.

**Excluded** (non-deployable / test-only / legacy): all `contracts/interfaces/`,
`contracts/mocks/`, `contracts/arbitration/mocks/`, abstract base contracts,
and obsolete historical contracts no longer in the active source (e.g.
`YieldOps`, `DisputeOps`, `SettlementOps`, `CreateOps` from an earlier
architecture). Historical deployment records remain historical facts in
`deploy-registry/`; they are **not** exported as current deployables.

## Allow-list

`config/deployable-allowlist.json` is the **reviewable, checked-in source of
truth** for what is exported. It is intentionally small. To export a new
contract, add it there (with scope/category/notes); to stop exporting one,
remove it. The exporter and validator both derive their behaviour from this
single file.

## Manifest schema

`deployables/manifest.json` (deterministic, sorted keys):

```jsonc
{
  "schemaVersion": 1,
  "packageName": "@sew/deployables",      // configurable
  "bundleVersion": "0.1.0",                // configurable
  "source": {
    "repository": "sew/sew-protocol",
    "commit": "<git sha or jj change id>",
    "commitSource": "git | jj | env",
    "commitOverride": false,
    "dirty": false
  },
  "build": {
    "artifactSource": "forge",
    "profile": "default",
    "compiler": { "name": "solc", "version": "0.8.37+commit.f401782d" },
    "settings": { "evmVersion": "osaka", "optimizerRuns": 200, "viaIR": true }
  },
  "artifacts": {
    "EscrowVault": {
      "contractName": "EscrowVault",
      "sourcePath": "contracts/core/EscrowVault.sol",
      "scopeHint": "sew",
      "category": "core",
      "artifactFile": "artifacts/EscrowVault.json",
      "abiSha256": "...",
      "creationBytecodeSha256": "...",
      "runtimeBytecodeSha256": "...",
      "fileSha256": "...",
      "hasLinkReferences": true,
      "hasDeployedLinkReferences": true
    }
  },
  "bundleRoot": "<sha256 of canonical manifest without bundleRoot>"
}
```

Per-artifact file `deployables/artifacts/<Name>.json` contains `abi`,
`bytecode` (creation, unlinked with `__$...$__` placeholders where libraries
must be linked), `deployedBytecode`, `linkReferences`, `deployedLinkReferences`,
`metadata` (solc metadata), and scope/category. **No deployment addresses are
encoded** — addresses belong to deployment instances in the deployment
repository/ledger, and current Base Sepolia deployment state is never used as
artifact identity.

## Commands

```bash
pnpm compile                 # native build (hardhat compile + forge build)
pnpm deployables:export      # write deployables/ bundle from forge out/
pnpm deployables:validate    # verify hashes + allow-list coverage
pnpm deployables:test        # round-trip / determinism / adversarial tests
pnpm deployables:pack        # tar.gz the bundle -> dist-deployables/
pnpm deployables:all         # export + validate + test
```

Optional commit override: `GIT_SHA=<sha> pnpm deployables:export` (used by CI).

## Integrity guarantees

Validation proves:
- manifest hashes equal exported artifact files;
- creation and runtime bytecode hashes are correct;
- ABI hashes are correct;
- every allow-listed artifact exists;
- non-deployable contracts are excluded (no extra artifact files);
- repeated export from identical source/build is deterministic
  (identical file hashes and `bundleRoot`);
- source commit/build provenance is recorded.

The future deployment repository can therefore assert:

```
artifact selected by logical deployment config
==
exact tested artifact produced by sew-protocol
```

## Local consumption

Consume the bundle directly (no compilation needed):

1. Run `pnpm deployables:export` (and optionally `pnpm deployables:pack`).
2. Point the deployment-composition repository at either:
   - the `deployables/` directory (fixture-style local consumption), or
   - the packed tarball `dist-deployables/sew-deployables-<version>.tgz`.
3. The consumer should verify `bundleRoot`, per-artifact hashes, ABI, and
   bytecode against the manifest before deploying (matching the hash
   convention used by the deployment-composition repo).

This preserves a path to immutable pinned packages for real deployments while
supporting easy local use now. Package publication is **not** mandatory in this
phase.

## Governance

The exporter exposes enough ABI/build information for the deployment repo to
identify governance/configuration functions, but it does **not** encode
semantic governance rules (e.g. which parameter belongs to which operation
group). Those belong to shared deployment/governance configuration. The bundle
states what a contract **is**, not how a deployment governs it.

## Assumptions

- **Foundry `out/` is the authoritative tested build artifact** for export,
  consistent with `forge build` and the forge test suite. The Hardhat deploy
  pipeline uses a different optimizer-runs/evmVersion setting
  (`runs=10`, `evmVersion=cancun` vs forge `runs=200`, `evmVersion=osaka`), so
  the exported (forge) bytecode is the canonical artifact going forward; the
  deployment repo deploys what this exporter emits. This is an explicit,
  documented decision.
- **Library link references** are preserved as `__$...$__` placeholders and
  `linkReferences`; hashes are computed over the unlinked bytecode string.
- **Source revision** resolves from `GIT_SHA` (CI), `git rev-parse HEAD`, then
  the jj change id (this repo is developed as a jj workspace).
- **`@sew/deployables` package name is provisional** and configurable in the
  allow-list.

## Non-goals

No Solidity redesign, no governance reorganization, no moving shared contracts
out, no removal of existing deploy/registries/config/governance tooling, no
replacement of Hardhat/Foundry config, no shared EDN config here, no PRF
verifier bindings, no generic ABI execution, no change to governance authority.
