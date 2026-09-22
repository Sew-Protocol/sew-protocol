# Governance & Upgrade Policy

This document defines the governance model, upgrade policy, and emergency controls for the protocol.

## Goals

- Ensure protocol changes are **transparent**, **reviewable**, and **delayed**.
- Ensure no admin (including governance) can rewrite the rules of an **in-flight escrow**.
- Preserve agility through **modular, swappable components** while keeping core invariants stable.
- Provide narrowly scoped emergency controls that can only **reduce risk**, not expand it.

---

## Design Principles

### No Proxies for Core Contracts

**Decision:** Core escrow contracts (BaseEscrow, EscrowVault, EscrowableERC20) are **not upgradeable via proxies**.

**Rationale:**

- Modular architecture with swappable modules provides flexibility without proxies
- "New escrows only" semantics allow safe module upgrades
- Easier to explain and audit: upgrades are "swap module address" (timelocked) rather than "replace arbitrary logic"
- Reduces "soft-rug" optics around token launches
- Module swaps are timelocked and publicly observable

**Note:** `DecentralizedResolutionModule` and `ResolverIncentiveModule` are in a separate package (`contracts/decentralized-resolution-module/`) and are **not included in the initial mainnet release**. When ready, they will be deployed and swapped in via the same Slow lane governance process as other modules. All modules use the same governance pattern: module swaps via Slow lane (queue + activate, ~9 days).

### Timelock Canceller: Governor-Only

**Decision:** `CANCELLER_ROLE` on TimelockController is **Governor-only** (Guardian does not have cancellation rights).

**Rationale:**

- Guardian already has strong emergency tools (pause, disable Aave, lower caps)
- Cancellation is power over governance intent, not just risk reduction
- Prevents perception that "guardian can override governance"
- Clean launch stance: Governor-only cancellation

**Future Consideration:** If guardian cancellation is needed later, it should be constrained (e.g., only for allowlisted selectors, or require 2-of-2 guardian + governor approval).

---

## Canonical Reference

**The authoritative list of governed functions, lanes, and delays is [`GOVERNANCE_SURFACE_MAP.md`](./GOVERNANCE_SURFACE_MAP.md).**

**Interface versioning and compatibility information is documented in [`INTERFACE_VERSIONING.md`](./INTERFACE_VERSIONING.md).**

This document (`governance.md`) provides narrative context, guarantees, snapshot semantics, and operational runbooks. For the complete function mapping, see the surface map.

---

## Invariants We Guarantee

The following invariants are **mechanically enforced** by the contract implementation:

1. **No function can change `snapshot*Module` fields after escrow creation**
   - Module addresses are snapshotted at creation and stored in `EscrowTransfer` struct
   - These fields are never modified after creation

2. **Guardian functions are strictly down-only**
   - Guardian can only decrease caps (`newCap <= currentCap`)
   - Guardian can only disable features (cannot enable)
   - Guardian can pause (cannot unpause)

3. **Slow lane always uses queue/activate with stored ETA**
   - All slow lane changes use `SlowLaneQueueActivate` pattern
   - ETA is stored onchain and enforced: `block.timestamp >= eta`
   - Both `queueX()` and `activateX()` require `ROLE_TIMELOCK`

4. **`paused()` applies globally; unpause is timelock-only**
   - `pause()` is `onlyRole(ROLE_GUARDIAN)` (Emergency lane, 0h delay)
   - `unpause()` is `onlyRole(ROLE_TIMELOCK)` (Standard lane, 48h delay)
   - Pause state affects all escrows (existing and new)

5. **Emergency lane functions are access-controlled, not convention**
   - Emergency functions use `onlyRole(ROLE_GUARDIAN)` modifier
   - TimelockController does not have `ROLE_GUARDIAN` role
   - This is enforced by access control, not policy

6. **Default module setters only affect new escrows**
   - Module getters (`getResolutionModule()`, etc.) read from snapshotted fields
   - Default module changes apply only to escrows created after the change

---

## Key Guarantees

### New escrows only

Governance changes to defaults/modules apply to **new escrows only**.  
At escrow creation time, module choices are **snapshotted** into escrow state. Existing escrows continue using their original snapped modules/settings.

### No discretionary per-escrow intervention

No governance actor (DAO/timelock/guardian) may arbitrarily change the module selection or rules for a specific escrow after it is created.

### Time-delayed execution

All non-emergency changes execute through an onchain timelock.

---

## Snapshot Point: What Gets Locked at Escrow Creation

### What Is Snapshotted

At the moment an escrow is created (when `createEscrow()` or `createEscrowTransfer()` is called), the following values are **snapshotted** into the `EscrowTransfer` struct and **cannot be changed** by any governance action:

1. **Resolution Module Implementation**
   - Address of the resolution module that will handle disputes for this escrow
   - Stored in: `escrowTransfer.snapshotResolutionModule`
   - Determined by: Current default resolution module (or custom resolver from settings)

2. **Release Strategy**
   - Address of the release strategy module that controls when/how funds can be released
   - Stored in: `escrowTransfer.snapshotReleaseStrategy`
   - Determined by: Current default release strategy

3. **Yield Generation Module**
   - Address of the yield generation module (e.g., Aave) that will generate yield for this escrow
   - Stored in: `escrowTransfer.snapshotYieldGenerationModule`
   - Determined by: Current default yield generation module (if yield is enabled)

4. **Yield Distribution Module**
   - Address of the yield distribution module that controls how yield is distributed
   - Stored in: `escrowTransfer.snapshotYieldDistributionModule`
   - Determined by: Current default yield distribution module

5. **Auto-Release Time**
   - Timestamp when the escrow will automatically release (if set)
   - Stored in: `escrowTransfer.autoReleaseTime`
   - Determined by: Escrow settings or default auto-release time

6. **Auto-Cancel Time**
   - Timestamp when the escrow will automatically cancel (if set)
   - Stored in: `escrowTransfer.autoCancelTime`
   - Determined by: Escrow settings or default auto-cancel time

7. **Dispute Resolver**
   - Address of the resolver that will handle disputes (if any)
   - Stored in: `escrowTransfer.disputeResolver`
   - Determined by: Resolution module's resolver selection logic at creation time

### What Is NOT Snapshotted (Global Settings)

The following settings are **global** and can be changed by governance:

#### Global Defaults (Affect New Escrows Only)

These settings can be changed by governance, but only affect **new escrows** created after the change:

1. **Default Modules**
   - Default resolution module (Slow lane)
   - Default release strategy (Slow lane)
   - Default yield generation module (Slow lane)
   - Default yield distribution module (Slow lane)
   - Existing escrows use their snapshotted module addresses

2. **Default Parameters**
   - `defaultAutoReleaseTime` (Standard lane)
   - `defaultAutoCancelTime` (Standard lane)
   - `defaultYieldDistribution` (Standard lane) - fallback for new escrows
   - Existing escrows use their snapshotted values

3. **Fee Configuration**
   - `escrowFee` (Slow lane) - applies to new escrows only
   - `escrowFeeAddress` (Slow lane) - where fees are withdrawn from (affects all escrows)
   - Existing escrows have already had fees deducted at creation

#### Global Settings (Affect All Escrows)

These settings affect **all escrows** (existing and new):

1. **Protocol Pause Status**
   - `paused()` state affects all escrows
   - Can be changed by Guardian (emergency) or Timelock (unpause)

2. **Global Limits**
   - `maxAttachments` - global limit that applies to all escrows
   - `maxDisputeDuration` - maximum dispute duration for all escrows

### Immutability Rule

**No governance setter mutates `EscrowTransfer` state for an existing escrow.**

Specifically:

- ✅ Default module setters (`queueDefaultX()` / `activateDefaultX()`) only change the default used for **new escrows**
- ✅ Default parameter setters (`setDefaultAutoCancelTime()`, etc.) only affect **new escrows**
- ❌ No function can change `snapshotResolutionModule`, `snapshotReleaseStrategy`, `snapshotYieldGenerationModule`, or `snapshotYieldDistributionModule` after creation
- ❌ No function can change `autoReleaseTime` or `autoCancelTime` after creation (except via resolution)
- ❌ No function can change yield distribution configuration after escrow creation

### Mechanical Enforcement

The implementation enforces this through:

1. **Module Snapshotting**: `_snapshotModulesForEscrow()` is called immediately after escrow creation and writes module addresses to the `EscrowTransfer` struct. These fields are never modified after creation.

2. **Module Getters**: `getResolutionModule()`, `getReleaseStrategy()`, etc. read from the snapshotted fields, not from current defaults.

3. **No Per-Escrow Module Setters**: All per-escrow module override functions were removed in Phase 5:
   - ❌ `setReleaseStrategyForEscrow()` - Removed
   - ❌ `setResolutionModuleForEscrow()` - Removed
   - ❌ `setYieldGenerationModuleForEscrow()` - Removed
   - ❌ `setYieldDistributionModuleForEscrow()` - Removed

4. **Workflow ID Immutability**: Once a `workflowId` is assigned, the `EscrowTransfer` struct at that index is never deleted or replaced. Only state transitions (PENDING → RELEASED, etc.) are allowed.

5. **Yield Distribution Immutability**: Yield distribution configuration is determined by the snapshotted yield distribution module at escrow creation. Any distribution parameters (recipients, percentages) must be configured at creation time or handled by the module's internal logic. There is no function to modify yield distribution after escrow creation.

### Summary Tables

#### Escrow-Specific Fields (Snapshotted at Creation)

These fields are **snapshotted** into each escrow at creation time and **cannot be changed** by any governance action:

| Field                             | Snapshotted? | Can Be Changed After Creation? | Who Can Change?                                    |
| --------------------------------- | ------------ | ------------------------------ | -------------------------------------------------- |
| `snapshotResolutionModule`        | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| `snapshotReleaseStrategy`         | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| `snapshotYieldGenerationModule`   | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| `snapshotYieldDistributionModule` | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| `autoReleaseTime`                 | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| `autoCancelTime`                  | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| `disputeResolver`                 | ✅ Yes       | ❌ No                          | N/A (immutable)                                    |
| Yield distribution configuration  | ✅ Yes       | ❌ No                          | N/A (immutable - determined by snapshotted module) |

#### Global Defaults (Affect New Escrows Only)

These are **global settings** that can be changed by governance, but only affect **new escrows** created after the change:

| Setting                           | Can Be Changed? | Who Can Change? | Lane            | Affects                                             |
| --------------------------------- | --------------- | --------------- | --------------- | --------------------------------------------------- |
| Default resolution module         | ✅ Yes          | Timelock        | Slow (7d + 48h) | New escrows only                                    |
| Default release strategy          | ✅ Yes          | Timelock        | Slow (7d + 48h) | New escrows only                                    |
| Default yield generation module   | ✅ Yes          | Timelock        | Slow (7d + 48h) | New escrows only                                    |
| Default yield distribution module | ✅ Yes          | Timelock        | Slow (7d + 48h) | New escrows only                                    |
| `defaultAutoReleaseTime`          | ✅ Yes          | Timelock        | Standard (48h)  | New escrows only                                    |
| `defaultAutoCancelTime`           | ✅ Yes          | Timelock        | Standard (48h)  | New escrows only                                    |
| `defaultYieldDistribution`        | ✅ Yes          | Timelock        | Standard (48h)  | New escrows only (fallback)                         |
| `escrowFee`                       | ✅ Yes          | Timelock        | Slow (7d + 48h) | New escrows only                                    |
| `escrowFeeAddress`                | ✅ Yes          | Timelock        | Slow (7d + 48h) | Where fees are withdrawn from (affects all escrows) |

#### Global Settings (Affect All Escrows)

These are **global settings** that affect **all escrows** (existing and new):

| Setting              | Can Be Changed? | Who Can Change?                        | Lane                             | Affects     |
| -------------------- | --------------- | -------------------------------------- | -------------------------------- | ----------- |
| Protocol `paused()`  | ✅ Yes          | Guardian (pause) or Timelock (unpause) | Emergency (0h) or Standard (48h) | All escrows |
| `maxAttachments`     | ✅ Yes          | Timelock                               | Standard (48h)                   | All escrows |
| `maxDisputeDuration` | ✅ Yes          | Timelock                               | Standard (48h)                   | All escrows |

#### Lifecycle Fields (Not Governance-Controlled)

These fields change naturally as part of the escrow lifecycle, not through governance actions:

| Field             | Can Be Changed? | Who Can Change? | Notes                                                                        |
| ----------------- | --------------- | --------------- | ---------------------------------------------------------------------------- |
| `escrowState`     | ✅ Yes          | State machine   | Changes through normal operations (PENDING → RELEASED, etc.)                 |
| `attachmentURIs`  | ✅ Yes          | Sender          | Can be added by sender while escrow is PENDING (user action, not governance) |
| `senderStatus`    | ✅ Yes          | Sender          | User action (AGREE_TO_CANCEL, RAISE_DISPUTE)                                 |
| `recipientStatus` | ✅ Yes          | Recipient       | User action (AGREE_TO_CANCEL, RAISE_DISPUTE)                                 |

---

## Governance Actors

### DAO (Governor)

- Onchain token governance that proposes and votes on protocol changes.
- If a proposal passes, it queues operations into the TimelockController.

### TimelockController

- The _only_ executor of Standard and Slow changes.
- Global timelock delay: **48 hours**.
- Controls all operational functions in ops contracts (CreateOps, SettlementOps, DisputeOps, YieldOps, BondCollector, ModuleManagementContract, EscrowAdminContract).
- All `registerEscrowContract()` functions require `ROLE_TIMELOCK` (governance-controlled).

### Guardian Multisig

Emergency-only role with **risk-reduction** powers:

- can pause protocol operations
- can disable external yield deposits (e.g., Aave)
- can lower exposure caps (down-only)
- can pause yield deposits (via CreateOps)

Guardian **cannot**:

- unpause the protocol
- resume yield deposits (down-only control)
- swap modules
- raise caps
- change fees or fee recipient
- cancel governance actions in the timelock
- register escrow contracts with ops contracts

### Fee Recipient

- Can withdraw accrued protocol fees only.
- Has no governance authority.

## Governance Lanes

### Standard lane (Timelock: 48 hours)

**Purpose:** bounded parameter changes and operational configuration that cannot change the rules of existing escrows and cannot expand authority beyond predefined limits.

**Delay:** 48 hours (TimelockController)

**Examples:**

- default timeouts within bounds
- max attachments within bounds
- yield distribution defaults (bounded)
- enabling/disabling Aave (Timelock can enable/disable; Guardian can only disable)
- registering supported tokens (bounded)
- setting exposure caps (bounded: 0 <= cap <= type(uint128).max)

**Note**: Yield distribution configuration is immutable at escrow creation. It is determined by the snapshotted yield distribution module and any configuration parameters set at creation time.

### Slow lane (Queue + activate: 7 days, timelock-only)

**Purpose:** high-impact changes such as module swaps and fee recipient changes.

**Mechanism:** enforced at the application layer using a two-step pattern:

1. `queueX()` records a pending change with `eta = now + 7 days`
2. after the ETA, `activateX()` applies the change

Both `queueX()` and `activateX()` are timelock-only, meaning governance must:

- pass a proposal to queue (48h delay),
- wait 7 days,
- pass a proposal to activate (48h delay).

> Note: Under a single timelock, Slow lane takes ~9 days wall-clock (48h + 7d + 48h). This is intentional for safety.

**Note**: All module changes (resolution, release, yield generation, yield distribution) use the unified slow lane pattern with 7-day delay. This applies consistently across all contracts (BaseEscrow, EscrowVault, EscrowableERC20). The previous BaseEscrow mechanism with configurable delay has been removed for consistency.

### Emergency lane (Guardian: immediate)

**Purpose:** immediate risk reduction.

**Immediate actions:**

- `pause()`
- disable Aave deposits / external yield deposits
- lower exposure caps (down-only)

**Unpause:** timelock-only (Standard lane, 48h)

---

## TimelockController Roles (Hardened Posture)

- `PROPOSER_ROLE` → Governor (only Governor can propose)
- `EXECUTOR_ROLE` → `address(0)` (open execution - anyone can execute after delay)
- `CANCELLER_ROLE` → Governor only (Guardian does not have cancellation rights)
- `TIMELOCK_ADMIN_ROLE` → TimelockController itself (self-admin, no external admin)

**Rationale for Open Execution:**

- Open execution (`address(0)`) allows anyone to execute proposals after the delay period
- This prevents governance deadlock if the executor becomes unavailable
- The delay period provides sufficient safety (48 hours for Standard lane, ~9 days for Slow lane)
- Governor retains proposal and cancellation rights, maintaining control over what gets executed

---

## Protocol Permissions (High Level)

### Timelock-only (Standard & Slow)

The following categories of changes are timelock-only:

- default parameter changes
- module default changes
- slow-lane queue/activate actions (module swaps, fee recipient, escalation config, etc.)
- unpause()

### Guardian-only (Emergency, down-only)

Guardian can:

- pause
- disable Aave/external yield deposits
- lower exposure caps

Guardian cannot:

- enable Aave
- increase caps
- change fee parameters
- swap modules
- unpause

---

## Slow-Lane Surfaces (7 days)

Slow-lane queue/activate MUST be used for:

- fee recipient changes
- fee bps changes
- default module swaps:
  - release strategy
  - resolution module (BaseEscrow: `queueResolutionModule()` / `activateResolutionModule()`)
  - yield generation module
  - yield distribution module
- Aave pool provider changes
- decentralized escalation configuration changes

**Note**: All module swaps use the unified slow lane pattern with 7-day delay:

- **BaseEscrow**: Uses `queueResolutionModule()` / `activateResolutionModule()` to change the resolution module
- **EscrowVault**: Uses BaseEscrow's `queueResolutionModule()` / `activateResolutionModule()` (inherits from BaseEscrow, no separate mechanism)
- **EscrowableERC20**: Module setters are no-ops (placeholder implementation)

All resolution module changes use the same Slow lane pattern (queue + activate, ~9 days total).

**Note**: DAO address is immutable after deployment (set in constructor only). The `queueDao()` and `activateDao()` functions were removed to ensure DAO address cannot be changed.

Each slow-lane surface emits:

- `XQueued(oldValue, newValue, eta)`
- `XActivated(oldValue, newValue)`

---

## Bounds & Validation

All Standard-lane parameters are bounded onchain in `SettingsValidationLibrary`.

### Recommended bounds (v1)

- Default auto-cancel time: `0 .. 30 days`
- Default auto-release time: `0 .. 30 days`
- Max attachments: `0 .. 20`
- Fee bps: `0 .. 200` (Slow lane)
- Yield distribution recipients: `1 .. 10`
- Yield distribution sum: must equal `10_000 bps`

### Exposure caps (raw token units)

Exposure caps are stored per-token in smallest units. Deposits into external yield modules must enforce:
`exposure[token] + amount <= cap[token]` (if cap != 0).

**Cap Bounds**:

- Minimum: `0` (disables deposits for that token)
- Maximum: `type(uint128).max` (prevents overflow)
- Caps are enforced at deposit time
- `cap = 0` disables deposits for that token

**Guardian Powers**:
Guardian may only lower caps (down-only):

- `newCap <= currentCap`
- Guardian cannot raise caps or set new caps

**Timelock Powers**:
Timelock can set caps within bounds:

- `0 <= cap <= type(uint128).max`
- Can raise or lower caps (subject to bounds)

---

## Module Governance

**Rule**: All modules are immutable. Module upgrades are performed by deploying a new version and swapping via Slow lane (queue + activate, ~9 days).

**Applies To**: All module types (resolution, release, yield generation, yield distribution).

**Current Modules** (Initial Mainnet Release):

- `DefaultResolutionModule` - Simple single-resolver system
- `DefaultReleaseStrategy` - Default release logic
- `AaveYieldGenerationModule` - Aave yield generation
- `DefaultYieldDistributionModule` - Configurable yield distribution

**Process**:

1. Deploy new module version
2. Queue module swap (48h delay via Timelock)
3. Wait 7 days (slow lane delay)
4. Activate module swap (48h delay via Timelock)

**Total Time**: ~9 days wall-clock (48h + 7d + 48h)

**Guarantee**:

- Old escrows continue using the old module (snapshot preserved)
- New escrows use the new module
- No exceptions: This rule applies to all modules

**Future Modules**: Modules added after initial release (e.g., `DecentralizedResolutionModule`) will use the same governance pattern: deploy new version and swap via Slow lane.

---

## Risk Reduction for Decentralized Dispute Resolution Migration

When migrating from `DefaultResolutionModule` to `DecentralizedResolutionModule`, the protocol will use a staged approach to reduce risk:

### Migration Strategy

**Phase 1: Initial Deployment**

- Deploy `DecentralizedResolutionModule` as a separate contract
- Test extensively on testnet with real dispute scenarios
- Conduct security audits specific to the decentralized resolution logic

**Phase 2: Staged Rollout (Future Consideration)**

- **Option A: Percentage-Based Rollout via ResolutionRouter**
  - Deploy a `ResolutionRouter` module that implements `IResolutionModule`
  - Router deterministically routes escrows to either `DefaultResolutionModule` or `DecentralizedResolutionModule` based on a governed rollout percentage
  - Routing is deterministic (hash-based) and snapshotted at escrow creation
  - Governance can increase rollout percentage gradually (0% → 100%)
  - Guardian can lower rollout percentage (down-only) in case of issues
  - **Status**: Not implemented in initial release. Will be considered for future migration.

- **Option B: Direct Module Swap**
  - Deploy `DecentralizedResolutionModule`
  - Swap via Slow lane governance (queue + activate, ~9 days)
  - All new escrows use the new module
  - Existing escrows continue using their snapshotted module

### Risk Mitigation Measures

1. **Snapshot Semantics**: All escrows snapshot their resolution module at creation. Module swaps only affect new escrows.

2. **Slow Lane Governance**: Module swaps require ~9 days (48h queue + 7d wait + 48h activate), providing time for community review and potential cancellation.

3. **Guardian Emergency Controls**: Guardian can pause protocol if issues are detected during migration.

4. **Extensive Testing**: Decentralized resolution module will be tested extensively on testnet before mainnet deployment.

5. **Gradual Rollout (if ResolutionRouter implemented)**: Percentage-based rollout allows gradual migration, reducing risk of widespread issues.

### Current Status

- `DecentralizedResolutionModule` is **not included in the initial mainnet release**
- It will be deployed and tested separately before being considered for swap
- When ready, it will use the same Slow lane governance pattern as other modules
- ResolutionRouter pattern is a future consideration for staged rollout, not implemented in initial release

---

## Deployment Runbook (Fresh Setup)

1. Deploy `GovToken` (ERC20Votes), mint/distribute, ensure delegation.
2. Deploy `TimelockController(minDelay=48h, proposers=[], executors=[0x0])`.
3. Deploy `Governor` wired to `GovToken` and `TimelockController`.
4. Grant timelock roles:
   - grant `PROPOSER_ROLE` to Governor
   - grant `CANCELLER_ROLE` to Governor
5. Revoke deployer timelock admin rights; ensure timelock is self-admin.
6. Transfer protocol authority to timelock:
   - `transferOwnership(timelock)` for Ownable contracts, OR
   - grant `ROLE_TIMELOCK` to timelock and remove deployer roles for AccessControl.
7. Grant guardian emergency role to multisig across governed modules/contracts.
8. Disable/remove any per-escrow override admin surfaces for mainnet.

---

## Operational Practices

- Publish proposals and queued operations in a public forum with:
  - rationale
  - diff summary
  - security considerations
  - links to audits/tests
- Treat Slow lane changes as “release events”:
  - storage and migration notes (if any)
  - staging/testnet rehearsal
  - clearly communicated ETA

---

## Security Notes

- Emergency controls are intentionally one-way until timelock unpauses.
- Guardian powers are restricted to risk reduction; they do not override governance intent.
- External integrations (e.g., Aave) must be protectable via caps and disable switches.

---

## Deprecated Functions

### setAuthorizedResolver (Removed in Phase 7)

**Status**: ❌ **DEPRECATED & REMOVED** - Function always reverts

**Rationale**: The `authorizedResolver` global gate was eliminated in Phase 7 for mainnet credibility. Resolution is now handled entirely through resolution modules, which are snapshotted at escrow creation.

**Replacement**: Use resolution modules (`DefaultResolutionModule`, etc.) instead.

**Removal Timeline**: Function will be completely removed in a future version. Currently reverts with clear error message to prevent accidental use.

**Why It Exists**: Kept temporarily for interface compatibility during migration, but always reverts to prevent use.

**Why It Cannot Override Module Logic**: The function always reverts, so it cannot be used to override module-based resolution. All resolution goes through the snapshotted resolution module.

**Status**: Not used anywhere in code paths; kept for compatibility only. Will be removed from ABI in a future version.

---

## Change Log

### 2025-01-06

- Updated contract paths to reflect `contracts/core/` structure
- Added `setMaxDisputeDuration()` function to BaseEscrow
- Added recovery functions (`recoverNativeETH`, `recoverERC20`) to governance surface
- Clarified EscrowableERC20 module setters as no-ops
- Updated EscrowVault to include recovery functions
- Unified module governance: All modules use Slow lane swap pattern (immutable modules, ~9 days)

### 2025-01-27

- Added Design Principles section (no proxies for core, Governor-only cancellation)
- Unified module governance: All modules use immutable swap pattern (Slow lane, ~9 days)
- Enhanced TimelockController roles documentation with rationale
- Removed DAO address change references (DAO address is immutable)
- Scoped documentation to initial mainnet release modules only
- Merged content from gov-details.md

### Previous Updates

- Module snapshotting implemented at escrow creation
- Per-escrow override functions removed
- Slow lane queue/activate pattern implemented
- Guardian emergency controls implemented
- Bounds enforcement added to all Standard lane parameters
