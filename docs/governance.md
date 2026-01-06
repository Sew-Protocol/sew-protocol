# Governance & Upgrade Policy

This document defines the governance model, upgrade policy, and emergency controls for the protocol.

## Goals

- Ensure protocol changes are **transparent**, **reviewable**, and **delayed**.
- Ensure no admin (including governance) can rewrite the rules of an **in-flight escrow**.
- Preserve agility through **modular, swappable components** while keeping core invariants stable.
- Provide narrowly scoped emergency controls that can only **reduce risk**, not expand it.

---

## Canonical Reference

**The authoritative list of governed functions, lanes, and delays is [`GOVERNANCE_SURFACE_MAP.md`](./GOVERNANCE_SURFACE_MAP.md).**

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

The following settings are **global** and apply to all escrows (including existing ones):

1. **Protocol Pause Status**
   - `paused()` state affects all escrows
   - Can be changed by Guardian (emergency) or Timelock (unpause)

2. **Default Yield Distribution Recipients/Percentages**
   - `defaultYieldDistribution` is used as a fallback for escrows that don't have escrow-specific distribution set
   - Can be changed by Timelock (Standard lane)
   - **Note**: Escrow-specific yield distribution (set via `setEscrowYieldDistribution()`) is set by the sender and can only be changed by the sender or Timelock, but only while the escrow is PENDING

3. **Default Timeouts**
   - `defaultAutoReleaseTime` and `defaultAutoCancelTime` only affect new escrows
   - Existing escrows use their snapshotted values

4. **Max Attachments**
   - `maxAttachments` is a global limit that applies to all escrows

5. **Escrow Fee Rate**
   - `escrowFee` applies to all new escrows
   - Existing escrows have already had fees deducted at creation

6. **Fee Recipient Address**
   - `escrowFeeAddress` is where fees are withdrawn from
   - Does not affect existing escrows (fees already deducted)

### Immutability Rule

**No governance setter mutates `EscrowTransfer` state for an existing escrow.**

Specifically:
- ✅ Default module setters (`queueDefaultX()` / `activateDefaultX()`) only change the default used for **new escrows**
- ✅ Default parameter setters (`setDefaultAutoCancelTime()`, etc.) only affect **new escrows**
- ✅ `setEscrowYieldDistribution(workflowId, ...)` can only be called while escrow is `PENDING` and only by sender or Timelock (not a governance bypass)
- ❌ No function can change `snapshotResolutionModule`, `snapshotReleaseStrategy`, `snapshotYieldGenerationModule`, or `snapshotYieldDistributionModule` after creation
- ❌ No function can change `autoReleaseTime` or `autoCancelTime` after creation (except via resolution)

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

5. **Yield Distribution Exception**: `setEscrowYieldDistribution(workflowId, ...)` is the only function that can modify escrow-specific state after creation, but:
   - It can only be called while `escrowState == PENDING`
   - It can only be called by the sender or Timelock (not arbitrary governance)
   - It does not affect the snapshotted modules
   - It only sets the yield distribution recipients/percentages for that specific escrow
   - **Rationale**: This allows the sender to configure yield distribution after escrow creation (e.g., if they forgot to set it initially), but does not allow governance to change the rules of an existing escrow. The Timelock role is included to allow governance to set distribution if needed, but this is a limited exception that does not affect module selection or core escrow rules.

### Summary Table

| Field | Snapshotted? | Can Be Changed After Creation? | Who Can Change? |
|-------|--------------|--------------------------------|-----------------|
| `snapshotResolutionModule` | ✅ Yes | ❌ No | N/A (immutable) |
| `snapshotReleaseStrategy` | ✅ Yes | ❌ No | N/A (immutable) |
| `snapshotYieldGenerationModule` | ✅ Yes | ❌ No | N/A (immutable) |
| `snapshotYieldDistributionModule` | ✅ Yes | ❌ No | N/A (immutable) |
| `autoReleaseTime` | ✅ Yes | ❌ No | N/A (immutable) |
| `autoCancelTime` | ✅ Yes | ❌ No | N/A (immutable) |
| `disputeResolver` | ✅ Yes | ❌ No | N/A (immutable) |
| `escrowYieldDistribution[workflowId]` | ❌ No | ⚠️ Limited | Sender or Timelock (only while PENDING) |
| `escrowState` | ❌ No | ✅ Yes | State machine transitions only |
| `attachmentURIs` | ❌ No | ✅ Yes | Sender (only while PENDING) |
| Protocol `paused()` | ❌ No | ✅ Yes | Guardian (pause) or Timelock (unpause) |
| `defaultYieldDistribution` | ❌ No | ✅ Yes | Timelock (affects new escrows only) |

---

## Governance Actors

### DAO (Governor)
- Onchain token governance that proposes and votes on protocol changes.
- If a proposal passes, it queues operations into the TimelockController.

### TimelockController
- The *only* executor of Standard and Slow changes.
- Global timelock delay: **48 hours**.

### Guardian Multisig
Emergency-only role with **risk-reduction** powers:
- can pause protocol operations
- can disable external yield deposits (e.g., Aave)
- can lower exposure caps (down-only)

Guardian **cannot**:
- unpause the protocol
- swap modules
- raise caps
- change fees or fee recipient
- cancel governance actions in the timelock

### Fee Recipient
- Can withdraw accrued protocol fees only.
- Has no governance authority.

---

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
- managing senior resolvers (affects new disputes only, active disputes use stored resolver)

**Note**: Sender updates to `setEscrowYieldDistribution()` are not governance actions; they are user configuration during PENDING state. Only Timelock path is a governance action.

### Slow lane (Queue + activate: 7 days, timelock-only)
**Purpose:** high-impact changes such as module swaps and fee recipient changes.

**Mechanism:** enforced at the application layer using a two-step pattern:
1) `queueX()` records a pending change with `eta = now + 7 days`
2) after the ETA, `activateX()` applies the change

Both `queueX()` and `activateX()` are timelock-only, meaning governance must:
- pass a proposal to queue (48h delay),
- wait 7 days,
- pass a proposal to activate (48h delay).

> Note: Under a single timelock, Slow lane takes ~9 days wall-clock (48h + 7d + 48h). This is intentional for safety.

### Emergency lane (Guardian: immediate)
**Purpose:** immediate risk reduction.

**Immediate actions:**
- `pause()`
- disable Aave deposits / external yield deposits
- lower exposure caps (down-only)

**Unpause:** timelock-only (Standard lane, 48h)

---

## TimelockController Roles (Hardened Posture)

- `PROPOSER_ROLE` → Governor
- `EXECUTOR_ROLE` → `address(0)` (anyone can execute after delay)
- `CANCELLER_ROLE` → Governor only
- `TIMELOCK_ADMIN_ROLE` → TimelockController itself (self-admin)

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
  - resolution module (in addition to existing propose/activate)
  - yield generation module
  - yield distribution module
- Aave pool provider changes
- DAO address changes (if applicable)
- decentralized escalation configuration changes

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
- Resolution module delay: `48 hours .. 30 days`
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

## Resolution Routing & Rollout

The protocol supports safe rollouts of new resolution mechanisms without per-escrow admin control.

### ResolutionRouter
- Implements `IResolutionModule`
- Routes deterministically using `hash(escrowId) % 10_000 < rolloutBps`
- `rolloutBps` is governed (timelock-only); guardian may reduce `rolloutBps` (down-only) if needed

### Snapshot rule
At escrow creation, the chosen resolution implementation is snapshotted into escrow state:
- `escrow.resolutionImpl = router.route(escrowId)`

Policy changes affect new escrows only.

### Senior Resolver Management (DecentralizedResolutionModule)

**Governance Lane**: Standard (48h delay)

**Functions**:
- `addSeniorResolver(address)` - Add a senior resolver to the registry
- `removeSeniorResolver(address)` - Remove a senior resolver from the registry

**Behavior**:
- **Affects new disputes only**: Senior resolver changes only affect disputes that are created after the change
- **Active disputes protected**: Once a dispute is created, the resolver is stored in `disputeMetadata[workflowId].currentResolver`
- **Authorization check**: `isAuthorizedResolver()` first checks if the resolver matches the stored `currentResolver` for that dispute. If it matches, authorization is granted regardless of registry status.
- **New dispute assignment**: For new disputes, `getResolver()` uses the current senior resolver registry to assign a resolver.

**Why Standard Lane is Acceptable**:
- Cannot retroactively change active dispute paths (resolver is snapshotted in dispute metadata)
- Only affects new dispute assignments
- Does not violate "new escrows only" guarantee (disputes are separate from escrow creation)

---

## Deployment Runbook (Fresh Setup)

1) Deploy `GovToken` (ERC20Votes), mint/distribute, ensure delegation.
2) Deploy `TimelockController(minDelay=48h, proposers=[], executors=[0x0])`.
3) Deploy `Governor` wired to `GovToken` and `TimelockController`.
4) Grant timelock roles:
   - grant `PROPOSER_ROLE` to Governor
   - grant `CANCELLER_ROLE` to Governor
5) Revoke deployer timelock admin rights; ensure timelock is self-admin.
6) Transfer protocol authority to timelock:
   - `transferOwnership(timelock)` for Ownable contracts, OR
   - grant `ROLE_TIMELOCK` to timelock and remove deployer roles for AccessControl.
7) Grant guardian emergency role to multisig across governed modules/contracts.
8) Disable/remove any per-escrow override admin surfaces for mainnet.

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

**Replacement**: Use resolution modules (`DefaultResolutionModule`, `DecentralizedResolutionModule`, etc.) instead.

**Removal Timeline**: Function will be completely removed in a future version. Currently reverts with clear error message to prevent accidental use.

**Why It Exists**: Kept temporarily for interface compatibility during migration, but always reverts to prevent use.

**Why It Cannot Override Module Logic**: The function always reverts, so it cannot be used to override module-based resolution. All resolution goes through the snapshotted resolution module.

**Status**: Not used anywhere in code paths; kept for compatibility only. Will be removed from ABI in a future version.

---

## Change Log
- Maintain a changelog of governance policy changes and parameter updates.