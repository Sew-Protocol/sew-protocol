## Context

`contracts/types/EscrowTypes.sol` is a foundational “shared types” file. It defines:

- Custom errors used across multiple contracts/libraries
- Core structs (`EscrowSettings`, `EscrowTransfer`, `TimeoutConfig`)
- Core enums (`EscrowState`, `SenderStatus`, `RecipientStatus`)

Because these types are imported broadly, changes here have **wide blast radius**:

- **ABI surface**: custom errors and public getters that expose these structs become part of the onchain interface.
- **Storage layout**: `EscrowTransfer[] public escrowTransfers`, `TimeoutConfig public timeoutConfig`, and `mapping(uint256 => EscrowSettings) public escrowSettings` depend directly on these types (e.g., in `BaseEscrow`).
- **Offchain tooling**: indexers/SDKs/tests that decode structs/errors will break if signatures change.

Given “about to deploy to testnet”, this doc focuses on what is safe to change *now* vs what should be deferred.

---

## What’s in `EscrowTypes.sol` today

### Custom errors

`EscrowTypes.sol` currently defines both:

- **String-bearing errors**:
  - `InvalidAutoTime(string reason, uint256 providedTime, uint256 currentTime)`
  - `InvalidAddress(string reason, address addr)`
  - `InvalidAmount(string reason)`
- **Non-string / code-style errors** (introduced later, size-oriented):
  - `NotAContract(uint8 which, address addr)`
  - `AmountZero()`
  - `FeeOverflow()`
  - `AmountExceedsBalance(uint256 requested, uint256 available)`
  - plus some `Zero*Ops()` and recovery-related errors

Observations:

- The presence of both patterns indicates the repo is mid-migration from “UX strings” to “compact codes”.
- Some other contracts/libraries also define their own `InvalidAddress(string, address)` (same name/signature but different scope), which increases mental overhead and makes “standard error set” harder to enforce.

### `EscrowSettings`

Current shape:

- `address customResolver`
- `YieldPreset yieldPreset` (enum)
- `uint256 autoReleaseTime`
- `uint256 autoCancelTime`

Semantics (as implied by comments + usage elsewhere):

- `autoReleaseTime/autoCancelTime` are treated as **absolute timestamps** (seconds since epoch).
- `0` is used as a sentinel meaning **“use default”** (and/or “disabled”), depending on the code path.

### Enums

Enums are small (effectively `uint8`), but their storage packing depends on adjacent field ordering in structs.

### `EscrowTransfer`

Current shape:

- 4 addresses (`token`, `to`, `from`, `disputeResolver`)
- `uint256 amountAfterFee`
- `uint256 autoReleaseTime`
- `uint256 autoCancelTime`
- 3 enums (`EscrowState`, `SenderStatus`, `RecipientStatus`)

The comment claims “optimized packing”, but with two `uint256` timestamps, there is **no realistic packing win** versus the recommended `uint64` approach.

### `TimeoutConfig`

Current shape:

- `uint256 defaultAutoReleaseTime` (absolute timestamp or 0)
- `uint256 defaultAutoCancelTime` (absolute timestamp or 0)
- `uint256 maxDisputeDuration` (seconds)
- `uint256 appealWindowDuration` (seconds)

The comment says “Auto-execution defaults (0 = disabled, absolute timestamps)”.

---

## Testnet deployment risk analysis

### 1) Storage layout risk (P0)

If you deploy contracts that store these structs (e.g., `BaseEscrow`), then later:

- Reordering fields
- Changing integer sizes (`uint256` → `uint64`)
- Changing enum placement

…will break storage decoding for existing state **unless** you redeploy and migrate (or are using a proxy with a careful storage-gap strategy and explicit migrations).

For testnet this may be acceptable (redeploy is expected), but you still want to avoid churn *after* public integrations start using addresses/ABIs.

### 2) ABI / decoding risk (P0)

Custom errors are part of the ABI. Changing:

- error names
- parameter types
- parameter order

…will break:

- Frontend revert decoding
- Scripts/tests that assert specific error signatures
- Indexers that rely on error ABI (less common than events, but used in dev tooling)

### 3) Bytecode size + deployability risk (P0/P1)

String-bearing custom errors and dynamic string construction (e.g., `string.concat(...)`) increases:

- **Deployment bytecode size**
- **Runtime bytecode size**

If you are already close to size limits (or using contract-size-reduction measures elsewhere), leaving strings in shared errors can undermine those efforts.

### 4) Semantic footguns: absolute defaults (P1)

Storing “defaults” as absolute timestamps means a misconfigured default can silently create:

- immediately executable auto-actions (if default is in the past or “too soon”)
- confusing behavior when “0 means use default” interacts with “0 means disabled”

There is some validation elsewhere, but the overall model remains brittle compared to “defaults are durations”.

---

## Recommendations (prioritized for “deploy to testnet soon”)

### P0 (strongly recommended before testnet deploy)

- **Remove string parameters from shared custom errors** (or at minimum stop using them in core paths).
  - Replace:
    - `InvalidAutoTime(string, …)`
    - `InvalidAddress(string, …)`
    - `InvalidAmount(string)`
  - With compact, code-based variants (example pattern):
    - `InvalidAutoTime(uint8 code, uint256 providedTime, uint256 currentTime)`
    - `InvalidAddress(uint8 which, address addr)`
    - `InvalidAmount(uint8 code)`
  - Why now: smallest “global” bytecode win with minimal logic impact, and easiest to standardize across contracts.

- **Fix the misleading packing comment on `EscrowTransfer`**.
  - Either implement real packing (see below), or adjust comments to match reality.
  - Why now: inaccurate comments cause reviewers/integrators to assume gas/storage properties that aren’t true.

- **Remove obviously dead/unused errors from the shared file** if the feature is actually removed.
  - Example: `NoETHToRecover()` appears in `EscrowTypes.sol` while native-ETH recovery is described as removed elsewhere.
  - Why now: dead errors increase ABI surface and confusion without benefit.

### P1 (high-value, but decide “do now vs defer” based on schedule)

- **Actually pack `EscrowTransfer` timestamps + enums**.
  - Change `autoReleaseTime/autoCancelTime` to `uint64` (or smaller if you later move to deltas).
  - Group `uint64/uint8` fields to share a slot with enums.
  - Expected impact: fewer storage slots per escrow and lower SSTORE load/store footprint.
  - Cost: touches many call sites, any encoding/decoding, and requires test updates. If you do it, do it **before** testnet deploy so the testnet ABI/layout matches the intended long-term design.

- **Pack `TimeoutConfig`** (e.g., `uint64` defaults + `uint32` durations).
  - Benefit: smaller calldata/ABI and cheaper storage.
  - Cost: requires updating validation and any external interfaces that accept/return this struct.

- **Use `calldata` for `EscrowSettings` in external entrypoints**.
  - This is mainly a runtime gas win (less memory expansion) and sometimes shrinks ABI decoding paths.
  - Note: `BaseEscrow.createEscrow` is `public` and used internally; a common pattern is:
    - `external` wrapper accepts `EscrowSettings calldata`
    - internal function takes `EscrowSettings memory` (only if/when needed)

### P2 (good hygiene / longer-term)

- **Clarify and standardize “0 semantics” for auto-times and defaults**.
  - If you keep absolute timestamps, enforce a consistent invariant:
    - default times are either 0 or sufficiently in the future
    - per-escrow times are either 0 or sufficiently in the future
  - Consider switching defaults to durations post-testnet if you want fewer footguns.

- **Unify the error set** across repo (avoid duplicate `InvalidAddress` definitions in multiple scopes).
  - Goal: one canonical “types error set” used everywhere, plus a small number of module-local errors when truly module-specific.

---

## “Deploy to testnet” decision guidance

If you are planning **multiple testnet redeploys anyway** (typical), the best time to do “struct packing + error signature cleanup” is **before the first public testnet address** is shared widely.

If you need to deploy **immediately** and cannot afford broad refactors:

- Do P0 error-string removal first (largest bytecode win with minimal behavioral risk).
- Defer packing changes but fix comments so expectations are correct.
- Record a follow-up task: “packing + semantics cleanup in vNext” and plan for redeploy.

---

## Quick pre-testnet checklist (EscrowTypes-focused)

- **Compilation**: full repo compiles with the final `EscrowTypes.sol` signatures.
- **Bytecode size**: verify contract size limits are comfortably below the max after removing strings.
- **Tests**: update tests that assert revert strings / specific error signatures.
- **ABI export**: regenerate ABIs (Hardhat/Foundry) and ensure downstream scripts use the new error signatures.
- **Docs**: update `docs/reference/ERROR_STANDARDIZATION.md` to match the final canonical error set.

