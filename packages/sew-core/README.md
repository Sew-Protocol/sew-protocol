# `@sew/sew-core`

This is the in-tree package boundary for the standalone Sew-core profile. It
uses the source scope in `docs/deployment/sew-core-standalone-profile.md` and
the 13-artifact allowlist in `deployables.allowlist.json`.

## Included product scope

ERC-20 escrow creation/funding, participant release, bilateral cancellation,
single-resolver disputes, timeout refund, pull settlement, and guardian intake
pause. Appeals, Kleros, yield, split settlement, partial release, staking and
slashing, DR3, EAE, PRF, pro-rata, and multi-L2 are outside this package.

## Workspace commands

Run these from the repository root:

```sh
pnpm --filter @sew/sew-core build
pnpm --filter @sew/sew-core test:profile
pnpm --filter @sew/sew-core test:artifacts
pnpm --filter @sew/sew-core deployables
```

The profile test exercises `SewCoreVault`; the artifact check verifies the
dedicated Sew-core deployables export. The build command still uses the root
Foundry project and compiles the monorepo source tree.

## Source boundary status

This first package step establishes workspace identity and package-owned build
and release commands without copying contracts. Canonical Solidity sources
remain under `contracts/`; the package manifest records that transitional
source root. This avoids a second copy of contracts that are still shared by
the full protocol.

The 13 allowlisted artifact roots currently import a closure of 51 local
Solidity files and 22 OpenZeppelin source files. In particular,
`SewCoreVault` inherits `BaseEscrow`, whose source imports appeal, yield,
Kleros, incentives, and other shared protocol components even where the Sew
core profile disables those features. Therefore this package is in-tree and
scoped, but not yet an independently compilable source package.

The next source-migration step is to establish an explicit shared-kernel
dependency for `BaseEscrow` and its common interfaces/types, then move the
Sew-core-owned contracts and focused tests into this package. Keep a single
canonical copy of shared sources. The extraction is complete when the package
can build and test from its own configuration using only declared workspace
dependencies, and its deployable export remains deterministic.
