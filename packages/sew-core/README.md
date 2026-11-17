# `@sew/sew-core`

This in-tree package owns the standalone Sew-core profile. It uses the source
scope in `../../docs/deployment/sew-core-standalone-profile.md` and the
13-artifact allowlist in `deployables.allowlist.json`.

## Included product scope

Single-token ERC-20 escrow creation/funding, participant release, bilateral
cancellation, default-resolver-only disputes, timeout refund, pull settlement,
and guardian intake pause. A guardian pause stops new escrow creation while
leaving dispute initiation, existing settlement, claims, and withdrawals
available. The profile omits appeals and Kleros escalation, yield generation,
split settlement, partial release, staking/slashing, DR3, EAE, PRF, pro-rata
settlement, and multi-L2 deployment. These are product-profile exclusions;
some related implementation code remains in the shared inherited source
closure. `SewCoreVault` disables yield, rejects nonzero per-escrow resolver
overrides, and omits appeal and split entrypoints. Its constructor pins one
supported ERC-20 address; the Base Sepolia candidate pins Circle test USDC.
Token transfers must deliver at least the requested amount.

## Workspace commands

Run these from the repository root:

```sh
pnpm --filter @sew/sew-core build
pnpm --filter @sew/sew-core test:profile
pnpm --filter @sew/sew-core test:artifacts
pnpm --filter @sew/sew-core deployables
```

The package build and profile test use this directory's Foundry configuration
and compile only the package source closure. The root Foundry project remains
the full-protocol integration build.

## Source boundary status

The 51 local source files in the Sew-core artifact closure now have their
canonical location under `contracts/` in this package. Full-protocol contracts
and tests import those package sources; there are no duplicate Solidity
sources. The package does not import from the root `contracts/` tree.

The supported in-repository consumers are the standalone Sew-core deployable
profile and the root full-protocol build/tests. This package is an experimental
in-tree boundary; it does not establish a public API, independent audit claim,
or external compatibility promise. Bundle 0.1.4 is the current behavior-change
candidate; it is not deployment-qualified. The 0.1.2 baseline and 0.1.3
source-migration candidate remain retained for comparison.

## Review-driven behavior gates

The candidate uses a zero minimum dispute escrow value so the dispute threshold
cannot make an otherwise valid small escrow undisputable. A separate minimum
creation amount still applies. Creation accepts only the constructor-pinned
token and rejects nonzero custom resolver overrides. While intake is paused,
participants can still open disputes on existing escrows.

These changes produce a new executable candidate and require a new deterministic
export, exact linked-bytecode qualification, local and Base Sepolia fork
rehearsals, and independent review. They do not qualify the prior 0.1.2 or 0.1.3
artifacts.

The generated source/consumer inventory is in
[`source-boundary.json`](./source-boundary.json). Regenerate it with
`pnpm --filter @sew/sew-core source:inventory`; it records full-protocol
contracts and tests that consume package sources. No `escrow-kernel` package
was introduced; the package owns the canonical closure and the root build
integrates it with the rest of the protocol.

The pinned 0.1.2 deployment artifact hashes are retained in
[`deployment-baseline-0.1.2.json`](./deployment-baseline-0.1.2.json). Source
relocation changes source identity and can change bytecode metadata. The new
package build is a candidate until ABI, storage layout, creation/runtime
bytecode, compiler settings, and deterministic export are compared and
reviewed. The current comparison and storage-layout snapshots are under
[`migration/`](./migration/); ABIs, storage layouts, and metadata-stripped
runtime code match the 0.1.2 baseline, while full bytecode hashes differ because
of source/remapping metadata. The pinned deployment bundle has not been
replaced or requalified.
