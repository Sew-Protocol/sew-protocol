# Governance Surface Map

Complete mapping of all governance functions to roles, lanes, and delays.

## Role Permissions Matrix

| Role | Standard Lane | Slow Lane | Emergency Lane | Module Upgrades | Notes |
|------|--------------|-----------|----------------|----------------|-------|
| **DAO (Governor)** | Propose & Vote | Propose & Vote | Cannot execute | Cannot execute | Proposals go through Timelock |
| **TimelockController** | Execute (48h delay) | Execute (48h + 7d delay) | Cannot execute | Can upgrade (instant) | Only executor for Standard/Slow. Emergency lane functions are guarded by `onlyRole(ROLE_GUARDIAN)`; Timelock lacks this role. |
| **Guardian Multisig** | Cannot execute | Cannot execute | Execute (immediate) | Cannot execute | Down-only powers |
| **Fee Recipient** | None | None | None | None | Can only withdraw fees |
| **Module Developer** | Cannot execute | Cannot execute | Cannot execute | Can upgrade (staged delays) | Can upgrade DecentralizedResolutionModule and ResolverIncentiveModule with staged delays (first 3 instant, then 1h/24h/7d based on time since deployment). Cannot swap modules in BaseEscrow. |

## Governance Lanes

### Emergency Lane (0h delay, Guardian only)
**Purpose**: Immediate risk reduction  
**Executor**: Guardian Multisig  
**Delay**: None (immediate execution)

### Standard Lane (48h delay, Timelock)
**Purpose**: Bounded parameter changes and operational configuration  
**Executor**: TimelockController  
**Delay**: 48 hours

### Slow Lane (7d + 48h delay, Timelock)
**Purpose**: High-impact changes (module swaps, fee recipient changes)  
**Executor**: TimelockController  
**Delay**: ~9 days wall-clock (48h queue + 7d wait + 48h activate)

---

## Complete Function Mapping

### BaseEscrow.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `setDefaultAutoCancelTime(uint256)` | `ROLE_TIMELOCK` | Standard | 48h | 0 <= time <= 30 days | Auto-cancel timeout |
| `setDefaultAutoReleaseTime(uint256)` | `ROLE_TIMELOCK` | Standard | 48h | 0 <= time <= 30 days | Auto-release timeout |
| `setMaxAttachments(uint256)` | `ROLE_TIMELOCK` | Standard | 48h | 0 <= max <= 20 | Max attachments per escrow |
| `setResolutionModuleDelay(uint256)` | `ROLE_TIMELOCK` | Standard | 48h | 48h <= delay <= 30 days | Resolution delay |
| `setDefaultYieldDistribution(address[], uint256[])` | `ROLE_TIMELOCK` | Standard | 48h | 1-10 recipients, sum=10000 bps | Yield distribution |
| `setEscrowYieldDistribution(uint256, address[], uint256[])` (Sender path) | Sender | N/A (User action) | No delay | 1-10 recipients, sum=10000 bps | Sender-only (while PENDING) – User configuration, not governance |
| `setEscrowYieldDistribution(uint256, address[], uint256[])` (Timelock path) | `ROLE_TIMELOCK` | Standard | 48h | 1-10 recipients, sum=10000 bps | Timelock can set (while PENDING) – Does not affect snapshotted modules |
| `unpause()` | `ROLE_TIMELOCK` | Standard | 48h | - | Unpause protocol |
| `pause()` | `ROLE_GUARDIAN` | Emergency | 0h | - | Pause protocol |
| `queueEscrowFeeAddress(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue fee address change |
| `activateEscrowFeeAddress()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued fee address |
| `queueEscrowFee(uint256)` | `ROLE_TIMELOCK` | Slow | 48h queue | 0 <= fee <= 200 bps | Queue fee change |
| `activateEscrowFee()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued fee |
| ~~`queueDao(address)`~~ | N/A | N/A | N/A | N/A | ❌ **REMOVED** - DAO address is immutable after deployment (set in constructor only) |
| ~~`activateDao()`~~ | N/A | N/A | N/A | N/A | ❌ **REMOVED** - DAO address is immutable after deployment |
| `proposeResolutionModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Propose new resolution module |
| `activateResolutionModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate proposed module |
| `setAuthorizedResolver(address)` | `ROLE_TIMELOCK` | N/A | N/A | N/A | ❌ **DEPRECATED & REMOVED** - Always reverts. Not used anywhere in code paths; kept for compatibility only. Will be removed from ABI in future version. Use resolution modules instead. |

### EscrowableERC20.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `queueDefaultReleaseStrategy(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue release strategy |
| `activateDefaultReleaseStrategy()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued strategy |
| `queueDefaultResolutionModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue resolution module |
| `activateDefaultResolutionModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued module |
| `queueDefaultYieldGenerationModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue yield generation module |
| `activateDefaultYieldGenerationModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued module |
| `queueDefaultYieldDistributionModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue yield distribution module |
| `activateDefaultYieldDistributionModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued module |

### EscrowVault.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `queueDefaultReleaseStrategy(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue release strategy |
| `activateDefaultReleaseStrategy()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued strategy |
| `queueDefaultResolutionModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue resolution module |
| `activateDefaultResolutionModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued module |
| `queueDefaultYieldGenerationModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue yield generation module |
| `activateDefaultYieldGenerationModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued module |
| `queueDefaultYieldDistributionModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue yield distribution module |
| `activateDefaultYieldDistributionModule()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued module |

### AaveYieldGenerationModule.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `setAaveEnabled(bool)` | `ROLE_TIMELOCK` | Standard | 48h | - | Enable or disable Aave (Timelock can enable/disable) |
| `guardianDisableAave()` | `ROLE_GUARDIAN` | Emergency | 0h | - | Disable Aave (down-only, Guardian cannot enable) |
| `queueAavePoolProvider(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address | Queue Aave pool provider |
| `activateAavePoolProvider()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued provider |
| `registerTokenForAave(address, address)` | `ROLE_TIMELOCK` | Standard | 48h | Non-zero addresses | Register token for Aave |
| `batchRegisterTokensForAave(address[], address[])` | `ROLE_TIMELOCK` | Standard | 48h | Non-zero addresses | Batch register tokens |
| `setTokenCap(address, uint256)` | `ROLE_TIMELOCK` | Standard | 48h | 0 <= cap <= type(uint128).max | Set token exposure cap (0 = disabled, enforced at deposit) |
| `setGlobalCap(address, uint256)` | `ROLE_TIMELOCK` | Standard | 48h | 0 <= cap <= type(uint128).max | Set global exposure cap (0 = disabled, enforced at deposit) |
| `guardianLowerTokenCap(address, uint256)` | `ROLE_GUARDIAN` | Emergency | 0h | newCap <= currentCap | Lower token cap (down-only) |
| `guardianLowerGlobalCap(address, uint256)` | `ROLE_GUARDIAN` | Emergency | 0h | newCap <= currentCap | Lower global cap (down-only) |

### DefaultResolutionModule.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `setResolver(address)` | `ROLE_TIMELOCK` | Standard | 48h | Non-zero address | Set resolver address |

### ResolverIncentiveModule.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `initialize(address,address)` | Initializer | N/A | 0h | Non-zero addresses | Initialize upgradeable contract (one-time) |
| `upgradeTo(address)` | `ROLE_TIMELOCK` OR `ROLE_MODULE_DEVELOPER` | Instant | 0h | Valid implementation | Upgrade module implementation (UUPS) |
| `upgradeToAndCall(address,bytes)` | `ROLE_TIMELOCK` OR `ROLE_MODULE_DEVELOPER` | Instant | 0h | Valid implementation | Upgrade and call (UUPS) |
| `swapPaymentLibraryInstant(address)` | `ROLE_MODULE_DEVELOPER` | Instant | 0h | Valid library | Swap payment library instantly (no slow-lane delay) |
| `queuePaymentCalculationLibrary(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Valid library | Queue payment library change (slow-lane) |
| `activatePaymentCalculationLibrary()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued library |
| `queueResolverSharePercentage(uint256)` | `ROLE_TIMELOCK` | Slow | 48h queue | 0 <= pct <= 10000 bps | Queue resolver share percentage change |
| `activateResolverSharePercentage()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued percentage |
| `queueWeights(Weights)` | `ROLE_TIMELOCK` | Slow | 48h queue | Valid weights | Queue weight configuration change |
| `activateWeights()` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued weights |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h | Non-zero address | Register escrow contract |
| `unregisterEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h | - | Unregister escrow contract |

### DecentralizedResolutionModule.sol

| Function | Role | Lane | Delay | Bounds | Notes |
|----------|------|------|-------|--------|-------|
| `initialize(address)` | Initializer | N/A | 0h | Non-zero address | Initialize upgradeable contract (one-time) |
| `upgradeTo(address)` | `ROLE_TIMELOCK` OR `ROLE_MODULE_DEVELOPER` | Module Upgrade | Staged delays | Valid implementation | Upgrade module implementation (UUPS). ROLE_TIMELOCK: instant. ROLE_MODULE_DEVELOPER: first 3 instant, then 1h/24h/7d based on time since deployment |
| `upgradeToAndCall(address,bytes)` | `ROLE_TIMELOCK` OR `ROLE_MODULE_DEVELOPER` | Module Upgrade | Staged delays | Valid implementation | Upgrade and call (UUPS). ROLE_TIMELOCK: instant. ROLE_MODULE_DEVELOPER: first 3 instant, then 1h/24h/7d based on time since deployment |
| `queueUpgrade(address)` | `ROLE_MODULE_DEVELOPER` | Module Upgrade | 48h queue | Valid implementation | Queue upgrade (after first 3 upgrades) |
| `activateUpgrade()` | `ROLE_MODULE_DEVELOPER` | Module Upgrade | Staged delay | - | Activate queued upgrade after delay |
| `getUpgradeDelay()` | View | N/A | N/A | - | Get current upgrade delay based on phase |
| `getCurrentPhase()` | View | N/A | N/A | - | Get current phase name (INSTANT/LAUNCH/EARLY/MATURE) |
| `getPendingUpgrade()` | View | N/A | N/A | - | Get pending upgrade information |
| `setUpgradeDelayConfig(...)` | `ROLE_TIMELOCK` | Standard | 48h | Valid config | Configure upgrade delay parameters (governance override) |
| `addSeniorResolver(address)` | `ROLE_TIMELOCK` | Standard | 48h | Non-zero address | Add senior resolver (affects new disputes only, active disputes use stored resolver) |
| `removeSeniorResolver(address)` | `ROLE_TIMELOCK` | Standard | 48h | - | Remove senior resolver (affects new disputes only, active disputes use stored resolver) |
| `setResolutionTableEntry(...)` | `ROLE_TIMELOCK` | Standard | 48h | - | Set resolution table entry |
| `setExternalResolver(address)` | `ROLE_TIMELOCK` | Standard | 48h | Non-zero address | Set external resolver |
| `queueEscalationConfig(uint8, EscalationConfig)` | `ROLE_TIMELOCK` | Slow | 48h queue | Valid level | Queue escalation config |
| `activateEscalationConfig(uint8)` | `ROLE_TIMELOCK` | Slow | 7d + 48h | - | Activate queued config |

---

## Removed Functions (No Longer Available in ABI)

The following functions were **removed from the ABI** in Phase 5 to eliminate per-escrow admin overrides:

- `setReleaseStrategyForEscrow(uint256, address)` - Removed from EscrowableERC20
- `setResolutionModuleForEscrow(uint256, address)` - Removed from EscrowableERC20
- `setYieldGenerationModuleForEscrow(uint256, address)` - Removed from EscrowableERC20
- `setYieldDistributionModuleForEscrow(uint256, address)` - Removed from EscrowableERC20

**Rationale**: Per-escrow overrides allow selective intervention, which undermines the "new escrows only" guarantee. Module changes now apply to all new escrows via default module setters.

**Status**: These functions no longer exist in the contract code. They are not available in the ABI and cannot be called.

---

## Lane Definitions

### Emergency Lane
- **Delay**: 0 hours (immediate)
- **Executor**: Guardian Multisig
- **Scope**: Risk reduction only (pause, disable features, lower caps)
- **Constraints**: Down-only (cannot increase risk)

### Standard Lane
- **Delay**: 48 hours
- **Executor**: TimelockController
- **Scope**: Bounded parameter changes, operational configuration
- **Constraints**: All parameters must be within predefined bounds

### Slow Lane
- **Delay**: ~9 days wall-clock (48h queue + 7d wait + 48h activate)
- **Executor**: TimelockController
- **Scope**: High-impact changes (module swaps, fee recipient, governance infrastructure)
- **Mechanism**: Two-step queue/activate pattern enforced onchain

### Module Upgrade Lane (Staged Delays)
- **Delay**: Staged based on time since deployment and upgrade count
  - First 3 upgrades: Instant (0h)
  - Launch phase (0-30 days): 1 hour
  - Early phase (30-90 days): 24 hours
  - Mature phase (90+ days): 7 days (same as slow lane)
- **Executor**: TimelockController (instant) OR Module Developer (staged delays)
- **Scope**: Upgrade DecentralizedResolutionModule and ResolverIncentiveModule implementations
- **Mechanism**: UUPS proxy upgrade pattern with queue/activate after first 3 upgrades
- **Restrictions**: Cannot swap modules in BaseEscrow, cannot bypass governance
- **Rationale**: Allows rapid iteration during early phases while transitioning to conservative upgrades as system matures

---

## Key Guarantees

1. **New Escrows Only**: Module changes apply only to new escrows. Existing escrows use snapshotted modules.
2. **No Per-Escrow Overrides**: No governance actor can modify rules for a specific escrow after creation.
3. **Time-Delayed Execution**: All non-emergency changes execute through TimelockController.
4. **Down-Only Emergency**: Guardian can only reduce risk, never increase it.

---

## References

- `governance.md` - Governance model overview
- `GOVERNANCE_IMPLEMENTATION_STATUS.md` - Implementation status
- `GOVERNANCE_IMPLEMENTATION_PLAN.md` - Implementation plan

