# Interface IDs (`interfaceId`) and ERC-165 support — repo-wide analysis

**Status**: Active reference  
**Scope**: How this repo computes, exposes, checks, and should version interface IDs for escrows, resolvers, and modules.

---

## What an `interfaceId` is (ERC-165)

ERC-165 defines a standard way for contracts to advertise supported interfaces via:

- `supportsInterface(bytes4 interfaceId) -> bool`
- Where `interfaceId` is the XOR of the 4-byte selectors for every function in the interface.

**Key properties**:

- **Selectors ignore** `view`/`pure`, parameter names, and data locations (`memory`/`calldata`).
- **Selectors include** function name + canonical argument types only.
- **Return types do not affect** selectors.
- **Events and errors do not affect** `interfaceId`.
- **Overloads matter**: adding/removing an overload changes `interfaceId`.
- **Structs compile to tuples** in the signature (e.g. `Payout[]` becomes `(address,uint256)[]`).
- **Enums compile to integers** in the signature (typically `uint8` if not forced; treat ABI as canonical).

### Solidity compiler nuance: inherited interface functions

In Solidity, `type(IMyInterface).interfaceId` matches the *“interface itself”* (it does **not** include selectors inherited via `is IERC165`).

This is consistent with widely-used standards:
- `type(IERC721).interfaceId == 0x80ac58cd` (does **not** XOR `supportsInterface(bytes4)`).

**Practical implication**: For interfaces declared `interface IX is IERC165`, the interface ID is computed from the functions declared in `IX` only.

---

## How this repo uses interface IDs today

### Where interface IDs are checked (consumers)

- **Module allowlisting / validation**
  - `contracts/registry/ModuleRegistry.sol` checks modules support:
    - `type(IYieldGenerationModule).interfaceId`
    - `type(IYieldDistributionModule).interfaceId`
    - `type(IResolutionModule).interfaceId`
  - `contracts/libraries/ModuleManagementLibrary.sol` validates a queued module against `ModuleConfig.interfaceId`.

- **Resolver sanity checks**
  - `contracts/libraries/DisputeInitializationLibrary.sol` uses ERC-165 to check a custom resolver supports `type(IResolver).interfaceId`.

### Where interface IDs are advertised (providers)

The following contracts implement `supportsInterface` to advertise module/resolver interfaces:

- Yield generation:
  - `contracts/modules/AaveYieldGenerationModule.sol` → `IYieldGenerationModule`
  - `contracts/modules/DefaultYieldModule.sol` → `IYieldGenerationModule`
- Yield distribution:
  - `contracts/modules/DefaultYieldDistributionModule.sol` → `IYieldDistributionModule`
  - `contracts/modules/TestYieldDistributionModule.sol` → `IYieldDistributionModule`
- Release strategy:
  - `contracts/modules/DefaultReleaseStrategy.sol` → `IReleaseStrategy`
- Resolution modules:
  - `contracts/core/modules/DefaultResolutionModule.sol` → `IResolutionModule`
  - `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol` → `IResolutionModule`
  - `contracts/arbitration/KlerosArbitrableProxy.sol` → `IResolutionModule` and `IArbitrable`
- Evidence module:
  - `contracts/evidence-module/EvidenceModuleV1.sol` → `IEvidenceModule` (and explicitly `IERC165`)
- Resolver example:
  - `contracts/mocks/TestnetForwardingResolver.sol` → `IResolver`

### Notably: Escrow contracts do **not** currently advertise ERC-165

`contracts/core/EscrowVault.sol` and `contracts/core/EscrowableERC20.sol` do **not** expose `supportsInterface`.

Implications:
- Wallet/integration code cannot reliably use ERC-165 to detect escrow “user-facing” method versions (create/release/cancel/etc.).
- The existing doc `docs/reference/INTERFACE_VERSIONING.md` describes an ERC-165 based versioning approach for escrow resolver-actions, but **the escrow contracts do not currently implement that**.

### EscrowVault is the current “standard surface” (de facto)

This repo’s user-facing escrow API is effectively defined by `BaseEscrow` + `EscrowVault`, not by an `IEscrowPayment` interface file.

Key properties that matter for standards work:

- **Multi-token escrow**: `EscrowVault` escrows arbitrary ERC-20 tokens.
- **Pull fallback**: push transfers can fail and fall back to claimable balances (`withdrawEscrow`).
- **Dispute resolution is full-outcome** (no partial splits):
  - resolver resolves with either:
    - `releaseAsDisputeResolver(workflowId, resolutionHash)` (full release), or
    - `cancelAsDisputeResolver(workflowId, resolutionHash)` (full refund).
  - resolution may be delayed by an appeal window via `pendingSettlements(workflowId)` + `executePendingSettlement(workflowId)`.
- **No partial releases accounting** (intentional invariant):
  - `EscrowVault` tracks total held per token and assumes escrow amounts are immutable (no partial releases).

**Standards implication**: the minimal “escrow standard” for this repo should treat partial splits as an optional extension (if supported at all), not part of core.

---

## Canonical interface IDs in this repo

This section records the **computed** interface IDs for the primary protocol interfaces. These were computed by XOR’ing the function selectors for each interface’s functions as declared in the interface.

### Core module interfaces

| Interface | Path | `interfaceId` |
|---|---|---|
| `IYieldGenerationModule` | `contracts/interfaces/IYieldGenerationModule.sol` | `0xaab6380b` |
| `IYieldDistributionModule` | `contracts/interfaces/IYieldDistributionModule.sol` | `0xf48a788f` |
| `IReleaseStrategy` | `contracts/interfaces/IReleaseStrategy.sol` | `0xf4856173` |
| `IResolutionModule` | `contracts/shared/interfaces/IResolutionModule.sol` | `0x9735510f` |
| `IEvidenceModule` | `contracts/interfaces/IEvidenceModule.sol` | `0xfa935b7e` |

### Resolver + registry interfaces

| Interface | Path | `interfaceId` |
|---|---|---|
| `IResolver` | `contracts/interfaces/IResolver.sol` | `0xe88ef641` |
| `IModuleRegistry` | `contracts/interfaces/IModuleRegistry.sol` | `0xbae9fd9d` |

### DR v3 placeholder interfaces (shared)

| Interface | Path | `interfaceId` |
|---|---|---|
| `IFraudProofModule` | `contracts/shared/interfaces/IFraudProofModule.sol` | `0x9308ac9d` |
| `IStakingModule` | `contracts/shared/interfaces/IStakingModule.sol` | `0x0dcc3563` |
| `ISlashingModule` | `contracts/shared/interfaces/ISlashingModule.sol` | `0x10e6c65d` |

### Arbitration interfaces (Kleros / ERC-792 style)

| Interface | Path | `interfaceId` |
|---|---|---|
| `IArbitrable` | `contracts/arbitration/IArbitrable.sol` | `0x311a6c56` |
| `IArbitrator` | `contracts/arbitration/IArbitrator.sol` | `0x8114b8a3` |

---

## How to reproduce these interface IDs (recommended workflow)

**Rule**: treat the interface file as source-of-truth, and generate the ID from its declared function signatures.

Recommended local snippet (Node + Ethers v6):

```js
const { id } = require("ethers");

const selector = (sig) => BigInt(id(sig).slice(0, 10)); // bytes4
const xorInterface = (sigs) => {
  let x = 0n;
  for (const s of sigs) x ^= selector(s);
  return "0x" + x.toString(16).padStart(8, "0");
};
```

**Important**:
- Use ABI-canonical tuple signatures for structs (e.g. `resolve(uint256,(address,uint256)[],bytes)`).
- Use ABI-canonical integer widths for enums (`uint8` in this repo’s module registry surface).

---

## Correctness and safety pitfalls to watch

### 1) “Looks like ERC-165” vs actually ERC-165

An interface can be used to compute an `interfaceId` even if it does not inherit `IERC165`. But ERC-165 detection only works if the *implementing contract* exposes `supportsInterface`.

In this repo:
- `IResolver` does not inherit `IERC165`, but `TestnetForwardingResolver` still advertises `type(IResolver).interfaceId` via an ERC-165 base class.
- `DisputeInitializationLibrary` assumes a resolver *might* implement ERC-165 and probes it.

**Recommendation**: Standardize resolvers on ERC-165 by making `IResolver` inherit `IERC165`, and requiring resolvers to implement `supportsInterface` (or document that resolver detection is best-effort).

### 1.1) “Resolver payouts” interface drift vs escrow’s full-outcome model

`contracts/interfaces/IResolver.sol` currently defines flexible payout resolution:

- `resolve(uint256,(address,uint256)[],bytes)` (partial splits allowed)

But the core escrow contract (`BaseEscrow` / `EscrowVault`) has moved to a **full-outcome** resolver surface (release or refund) and no longer supports partial split execution.

**Recommendation**:
- Either:
  - deprecate/rename `IResolver` (treat it as legacy), and introduce a new, ERC-165-first-class resolver hook interface aligned with the full-outcome model, or
  - version it explicitly (`IResolverV1` = payouts, `IResolverV2` = full outcome).

### 2) Interface drift without interface renaming

If you add/remove/reorder/overload functions in an interface file, its `interfaceId` changes. That is effectively a breaking change for any system relying on `supportsInterface`.

**Recommendation**:
- Never make breaking changes to an existing interface file.
- Instead, create `I…V2.sol` (or `I…V1_1.sol` if you insist on a minor bump but still want a different ID).

### 3) Relying on `moduleVersion()` strings for on-chain detection

`moduleVersion()` is useful for UX and off-chain indexing, but it is not a safe on-chain capability signal:
- strings can lie,
- strings are expensive to compare,
- and they don’t guarantee function presence.

**Recommendation**: Use ERC-165 for capability detection; keep `moduleVersion()` for metadata only.

### 4) EIP-165 false positives / collisions

`bytes4` collisions are possible in theory. In practice they are rare, but **do not** use ERC-165 as your only security boundary.

**Recommendation**:
- Continue to validate module behavior via allowlists (registry), governance-controlled swapping, and invariant tests.
- Where high-risk, add explicit “handshake” checks (e.g. `moduleName()` exact match or immutable feature flags) as secondary, non-security critical validation.

---

## Holistic recommendations for organizing and tracking interface versions

### A) Adopt a single “interface surface registry” in code

Create a small library contract that centralizes your interface IDs and intended meanings, for example:

- `contracts/reference/InterfaceIds.sol`:
  - `bytes4 internal constant IID_YIELD_GEN_V1 = type(IYieldGenerationModule).interfaceId;`
  - `bytes4 internal constant IID_RESOLUTION_V1 = type(IResolutionModule).interfaceId;`
  - etc.

Benefits:
- prevents typos / mismatched IDs across validation sites,
- makes audits easier,
- keeps docs in sync with code intent.

### B) Separate “capability IDs” from “module types”

Today, module types are expressed structurally (YieldGen/YieldDist/Resolution) and validated by interface ID. That’s good. Extend this pattern:

- For each module type, define a **minimum required interface** (V1) and optional feature interfaces (V2+, extensions).
- Example: `IResolutionModule` is minimum; `IResolutionModuleWithBonds` could be an optional extension (separate interfaceId).

Concrete candidates already implied by existing call patterns:
- `IResolutionModuleFinalizable`: supports `finalizeDispute(uint256)` (currently called best-effort via selector).
- `IResolutionModuleDecisionHistory`: supports `getDecisionAtRound(uint256,uint8)` (currently queried best-effort via low-level `staticcall`).

Using ERC-165 for these optional capabilities avoids “probe by selector and ignore failures” as the default standard pattern.

### C) Make versioning explicit in filenames + docs

Recommended convention:
- `IResolutionModuleV1.sol` (freeze forever)
- `IResolutionModuleV2.sol` (breaking changes only)
- Optional: `IResolutionModuleExtBonds.sol` (capability extension, composable)

And update docs:
- Keep this document (`INTERFACE_ID_ANALYSIS.md`) as the “numbers and mapping” page.
- Keep `INTERFACE_VERSIONING.md` as the “policy/migration strategy” page, but ensure it matches actual contract behavior (not aspirational).

### D) Decide how (or whether) to version the escrow contract interface

Because `EscrowVault` is near the 24KB limit, adding full ERC-165 support there may be undesirable.

Options:
- **Option D1 (size-friendly)**: keep escrow as non-ERC165 and version via:
  - `function protocolVersion() external pure returns (uint32)` (or `bytes32`)
  - plus stable event schemas
- **Option D2 (ERC-165)**: add minimal `supportsInterface` only for *escrow-facing* integration points (e.g. a minimal `IEscrowVaultCore` interface) if size allows.
- **Option D3 (hybrid)**: keep escrow core lean but add a small “introspection helper” contract that:
  - returns the intended interface IDs (constants) and protocol version
  - can be referenced by UIs/indexers as a canonical “what to expect” entrypoint
  - does not attempt to be a security boundary

If you choose D2, document it as a deliberate interface surface and keep it minimal.

### E) Add a reproducible “interface ID snapshot” check in CI

Add a script that computes the IDs from a curated list of signatures and:
- updates this doc table, or
- fails CI if the values drift unexpectedly.

This prevents silent breaking changes.

