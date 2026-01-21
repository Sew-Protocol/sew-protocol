# Governance Surface Map

Complete mapping of all governance functions to roles, lanes, and delays.

## Deployment defaults (source: `config/governance.config.ts`)

These are **deployment-time defaults** (can be overridden via environment variables in deployment tooling). Exchanges/auditors should verify the deployed on-chain values.

### Governance token (SEW)
- **Name (default):** `Sew Token`
- **Symbol (default):** `SEW`
- **Initial supply (default):** `1,000,000,000 SEW` (18 decimals)

### Timelock / lanes
- **Timelock minDelay (default):** 48 hours (`TIMELOCK_DELAY=172800`)
- **Slow lane wall-clock:** ~9 days (48h queue + 7d wait + 48h activate)

### Governor parameters (defaults)
- **Voting delay:** 1 block
- **Voting period:** ~1 week (`VOTING_PERIOD=45818` blocks)
- **Proposal threshold:** 10,000,000 SEW (1% of supply)
- **Quorum:** 4,000,000 SEW (`ABSOLUTE_QUORUM=4000000000000000000000000`)

### Guardian / Safe
- **Guardian multisig:** configured via `GUARDIAN_MULTISIG`
- **Safe threshold (default):** 3 (3-of-N owners)
- **Fee recipient (deployment config):** `FEE_RECIPIENT` (feeds into protocol fee recipient configuration)

## Role Permissions Matrix

| Role                   | Standard Lane       | Slow Lane                | Emergency Lane      | Notes |
| ---------------------- | ------------------- | ------------------------ | ------------------- | ----- |
| **DAO (Governor)**     | Propose & Vote      | Propose & Vote           | Cannot execute      | Proposals execute through Timelock |
| **TimelockController** | Execute (48h delay) | Execute (48h + 7d delay) | Cannot execute      | Emergency lane functions are guarded by `onlyRole(ROLE_GUARDIAN)`; Timelock lacks this role |
| **Guardian Multisig**  | Cannot execute      | Cannot execute           | Execute (immediate) | Down-only powers |
| **Fee Recipient**      | None                | None                     | None                | Can withdraw fees only (no governance powers) |

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

### BaseEscrow.sol (`contracts/core/BaseEscrow.sol`)

| Function                                            | Role            | Lane      | Delay     | Bounds                         | Notes                                                                                                                                                                                   |
| --------------------------------------------------- | --------------- | --------- | --------- | ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `setDefaultAutoCancelTime(uint256)`                 | `ROLE_TIMELOCK` | Standard  | 48h       | 0 <= time <= 30 days           | Auto-cancel timeout                                                                                                                                                                     |
| `setDefaultAutoReleaseTime(uint256)`                | `ROLE_TIMELOCK` | Standard  | 48h       | 0 <= time <= 30 days           | Auto-release timeout                                                                                                                                                                    |
| `setMaxAttachments(uint256)`                        | `ROLE_TIMELOCK` | Standard  | 48h       | 0 <= max <= 20                 | Max attachments per escrow                                                                                                                                                              |
| `setMaxDisputeDuration(uint256)`                    | `ROLE_TIMELOCK` | Standard  | 48h       | -                              | Maximum dispute duration                                                                                                                                                                |
| `setDefaultYieldDistribution(address[], uint256[])` | `ROLE_TIMELOCK` | Standard  | 48h       | 1-10 recipients, sum=10000 bps | Yield distribution defaults (affects new escrows only)                                                                                                                                  |
| `unpause()`                                         | `ROLE_TIMELOCK` | Standard  | 48h       | -                              | Unpause protocol                                                                                                                                                                        |
| `pause()`                                           | `ROLE_GUARDIAN` | Emergency | 0h        | -                              | Pause protocol                                                                                                                                                                          |
| `queueEscrowFeeAddress(address)`                    | `ROLE_TIMELOCK` | Slow      | 48h queue | Non-zero address               | Queue fee address change                                                                                                                                                                |
| `activateEscrowFeeAddress()`                        | `ROLE_TIMELOCK` | Slow      | 7d + 48h  | -                              | Activate queued fee address                                                                                                                                                             |
| `queueEscrowFee(uint256)`                           | `ROLE_TIMELOCK` | Slow      | 48h queue | 0 <= fee <= 200 bps            | Queue fee change                                                                                                                                                                        |
| `activateEscrowFee()`                               | `ROLE_TIMELOCK` | Slow      | 7d + 48h  | -                              | Activate queued fee                                                                                                                                                                     |
| `queueYieldProtocolFeeBps(uint256)`                 | `ROLE_TIMELOCK` | Slow      | 48h queue | 0 <= fee <= 3000 bps           | Queue yield protocol fee (charged on yield only)                                                                                                                                        |
| `activateYieldProtocolFeeBps()`                     | `ROLE_TIMELOCK` | Slow      | 7d + 48h  | -                              | Activate queued yield protocol fee                                                                                                                                                      |
| `queueAppealBondProtocolFeeBps(uint256)`            | `ROLE_TIMELOCK` | Slow      | 48h queue | 0 <= fee <= 3000 bps           | Queue appeal bond protocol fee (charged at bond posting time)                                                                                                                           |
| `activateAppealBondProtocolFeeBps()`                | `ROLE_TIMELOCK` | Slow      | 7d + 48h  | -                              | Activate queued appeal bond protocol fee                                                                                                                                                 |
| `queueResolutionModule(address)`                    | `ROLE_TIMELOCK` | Slow      | 48h queue | Non-zero address               | Queue resolution module change (BaseEscrow level)                                                                                                                                       |
| `activateResolutionModule()`                        | `ROLE_TIMELOCK` | Slow      | 7d + 48h  | -                              | Activate queued resolution module                                                                                                                                                       |
| `getPendingResolutionModule()`                      | N/A             | N/A       | N/A       | -                              | View pending resolution module change                                                                                                                                                   |
| `recoverNativeETH(address, uint256)`                | `ROLE_TIMELOCK` | Standard  | 48h       | -                              | Recover stuck native ETH                                                                                                                                                                |
| `recoverERC20(address, address, uint256)`           | `ROLE_TIMELOCK` | Standard  | 48h       | -                              | Recover stuck ERC20 tokens                                                                                                                                                              |
| ~~`setAuthorizedResolver(address)`~~                | N/A             | N/A       | N/A       | N/A                            | ❌ **DEPRECATED & REMOVED** - Always reverts. Not used anywhere in code paths; kept for compatibility only. Will be removed from ABI in future version. Use resolution modules instead. |

### EscrowableERC20.sol (`contracts/core/EscrowableERC20.sol`)

| Function                                       | Role            | Lane | Delay     | Bounds              | Notes                                                  |
| ---------------------------------------------- | --------------- | ---- | --------- | ------------------- | ------------------------------------------------------ |
| `queueDefaultReleaseStrategy(address)`         | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address    | No-op (inherited from BaseEscrow, overridden as empty) |
| `activateDefaultReleaseStrategy()`             | `ROLE_TIMELOCK` | Slow | 7d + 48h  | -                   | No-op (inherited from BaseEscrow, overridden as empty) |
| `queueDefaultResolutionModule(address)`        | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address    | No-op (inherited from BaseEscrow, overridden as empty) |
| `activateDefaultResolutionModule()`            | `ROLE_TIMELOCK` | Slow | 7d + 48h  | -                   | No-op (inherited from BaseEscrow, overridden as empty) |
| `queueDefaultYieldGenerationModule(address)`   | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address    | No-op (inherited from BaseEscrow, overridden as empty) |
| `activateDefaultYieldGenerationModule()`       | `ROLE_TIMELOCK` | Slow | 7d + 48h  | -                   | No-op (inherited from BaseEscrow, overridden as empty) |
| `queueDefaultYieldDistributionModule(address)` | `ROLE_TIMELOCK` | Slow | 48h queue | Non-zero address    | No-op (inherited from BaseEscrow, overridden as empty) |
| `activateDefaultYieldDistributionModule()`     | `ROLE_TIMELOCK` | Slow | 7d + 48h  | -                   | No-op (inherited from BaseEscrow, overridden as empty) |
| `queueEscrowFee(uint256)`                      | `ROLE_TIMELOCK` | Slow | 48h queue | 0 <= fee <= 200 bps | No-op (inherited from BaseEscrow, overridden as empty) |
| `activateEscrowFee()`                          | `ROLE_TIMELOCK` | Slow | 7d + 48h  | -                   | No-op (inherited from BaseEscrow, overridden as empty) |

**Note**: `EscrowableERC20` inherits from `BaseEscrow` but overrides these functions as no-ops. Module configuration for `EscrowableERC20` is handled at deployment time via constructor parameters. All other governance functions are inherited from `BaseEscrow`.

### EscrowVault.sol (`contracts/core/EscrowVault.sol`)

| Function                                       | Role            | Lane     | Delay     | Bounds           | Notes                           |
| ---------------------------------------------- | --------------- | -------- | --------- | ---------------- | ------------------------------- |
| `queueDefaultReleaseStrategy(address)`         | `ROLE_TIMELOCK` | Slow     | 48h queue | Non-zero address | Queue release strategy          |
| `activateDefaultReleaseStrategy()`             | `ROLE_TIMELOCK` | Slow     | 7d + 48h  | -                | Activate queued strategy        |
| `queueDefaultYieldGenerationModule(address)`   | `ROLE_TIMELOCK` | Slow     | 48h queue | Non-zero address | Queue yield generation module   |
| `activateDefaultYieldGenerationModule()`       | `ROLE_TIMELOCK` | Slow     | 7d + 48h  | -                | Activate queued module          |
| `queueDefaultYieldDistributionModule(address)` | `ROLE_TIMELOCK` | Slow     | 48h queue | Non-zero address | Queue yield distribution module |
| `activateDefaultYieldDistributionModule()`     | `ROLE_TIMELOCK` | Slow     | 7d + 48h  | -                | Activate queued module          |
| `recoverERC20(address, address, uint256)`      | `ROLE_TIMELOCK` | Standard | 48h       | -                | Recover stuck ERC20 tokens      |

**Note**: `EscrowVault` inherits from `BaseEscrow` and uses BaseEscrow's `queueResolutionModule()` / `activateResolutionModule()` for resolution module changes. EscrowVault does not have its own separate resolution module mechanism. Other default modules (release strategy, yield generation, yield distribution) are EscrowVault-specific and have their own queue/activate functions.

### AaveYieldGenerationModule.sol (`contracts/modules/AaveYieldGenerationModule.sol`)

| Function                                           | Role            | Lane      | Delay     | Bounds                        | Notes                                                       |
| -------------------------------------------------- | --------------- | --------- | --------- | ----------------------------- | ----------------------------------------------------------- |
| `setAaveEnabled(bool)`                             | `ROLE_TIMELOCK` | Standard  | 48h       | -                             | Enable or disable Aave (Timelock can enable/disable)        |
| `guardianDisableAave()`                            | `ROLE_GUARDIAN` | Emergency | 0h        | -                             | Disable Aave (down-only, Guardian cannot enable)            |
| `queueAavePoolProvider(address)`                   | `ROLE_TIMELOCK` | Slow      | 48h queue | Non-zero address              | Queue Aave pool provider                                    |
| `activateAavePoolProvider()`                       | `ROLE_TIMELOCK` | Slow      | 7d + 48h  | -                             | Activate queued provider                                    |
| `registerTokenForAave(address, address)`           | `ROLE_TIMELOCK` | Standard  | 48h       | Non-zero addresses            | Register token for Aave                                     |
| `batchRegisterTokensForAave(address[], address[])` | `ROLE_TIMELOCK` | Standard  | 48h       | Non-zero addresses            | Batch register tokens                                       |
| `setTokenCap(address, uint256)`                    | `ROLE_TIMELOCK` | Standard  | 48h       | 0 <= cap <= type(uint128).max | Set token exposure cap (0 = disabled, enforced at deposit)  |
| `setGlobalCap(address, uint256)`                   | `ROLE_TIMELOCK` | Standard  | 48h       | 0 <= cap <= type(uint128).max | Set global exposure cap (0 = disabled, enforced at deposit) |
| `guardianLowerTokenCap(address, uint256)`          | `ROLE_GUARDIAN` | Emergency | 0h        | newCap <= currentCap          | Lower token cap (down-only)                                 |
| `guardianLowerGlobalCap(address, uint256)`         | `ROLE_GUARDIAN` | Emergency | 0h        | newCap <= currentCap          | Lower global cap (down-only)                                |

### DefaultResolutionModule.sol (`contracts/core/modules/DefaultResolutionModule.sol`)

| Function               | Role            | Lane     | Delay | Bounds           | Notes                |
| ---------------------- | --------------- | -------- | ----- | ---------------- | -------------------- |
| `setResolver(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Set resolver address |

### DecentralizedResolutionModule.sol (`contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`)

| Function                                                 | Role            | Lane     | Delay     | Bounds                  | Notes                                               |
| -------------------------------------------------------- | --------------- | -------- | --------- | ----------------------- | --------------------------------------------------- |
| `appointSeniorResolver(address, string, string)`         | `ROLE_TIMELOCK` | Standard | 48h       | Non-zero address        | Appoint senior resolver (affects new disputes only) |
| `removeSeniorResolver(address)`                          | `ROLE_TIMELOCK` | Standard | 48h       | -                       | Remove senior resolver (affects new disputes only)  |
| `setResolutionTableEntry(bytes32, ResolutionTableEntry)` | `ROLE_TIMELOCK` | Standard | 48h       | Valid entry             | Set resolution table entry for category             |
| `queueEscalationConfig(uint8, EscalationConfig)`         | `ROLE_TIMELOCK` | Slow     | 48h queue | Valid config            | Queue escalation configuration                      |
| `activateEscalationConfig(uint8)`                        | `ROLE_TIMELOCK` | Slow     | 7d + 48h  | -                       | Activate queued escalation config                   |
| `setExternalResolver(address)`                           | `ROLE_TIMELOCK` | Standard | 48h       | Non-zero address        | Set external resolver (e.g., Kleros)                |
| `registerEscrowContract(address)`                        | `ROLE_TIMELOCK` | Standard | 48h       | Non-zero address        | Register escrow contract                            |
| `unregisterEscrowContract(address)`                      | `ROLE_TIMELOCK` | Standard | 48h       | -                       | Unregister escrow contract                          |
| `setIncentiveModule(address)`                            | `ROLE_TIMELOCK` | Standard | 48h       | Non-zero address        | Set incentive module address                        |
| `setResolverActive(address, bool)`                       | `ROLE_TIMELOCK` | Standard | 48h       | -                       | Set resolver active status                          |
| `setResolverCapacity(address, uint256, bool)`            | `ROLE_TIMELOCK` | Standard | 48h       | -                       | Set resolver capacity limits                        |
| `setDisputeTimeout(uint256)`                             | `ROLE_TIMELOCK` | Standard | 48h       | 0 < timeout <= 365 days | Set dispute timeout                                 |

**Note:** `DecentralizedResolutionModule` is in a separate package (`contracts/decentralized-resolution-module/`) and is **not included in the initial mainnet release**. When ready, it will be deployed and swapped in via the same Slow lane governance process as other modules (queue + activate, ~9 days).

### CreateOps.sol (`contracts/CreateOps.sol`)

| Function                                    | Role            | Lane     | Delay | Bounds           | Notes                                                      |
| ------------------------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------------------------- |
| `registerEscrowContract(address)`           | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract (EscrowVault or EscrowableERC20) |
| `pauseYieldDeposits(string reason)`         | `ROLE_GUARDIAN` OR `ROLE_TIMELOCK` | Emergency OR Standard | 0h OR 48h | - | Pause yield deposits (Guardian can pause for emergencies, Timelock can pause via governance) |
| `resumeYieldDeposits()`                     | `ROLE_TIMELOCK` | Standard | 48h   | -                | Resume yield deposits (Guardian cannot resume, down-only)  |

**Note**: `CreateOps` is an external helper contract that handles escrow creation validation and computation. It uses consistent governance roles: `ROLE_TIMELOCK` for operational functions, `ROLE_GUARDIAN` for emergency pause.

### SettlementOps.sol (`contracts/SettlementOps.sol`)

| Function                      | Role            | Lane     | Delay | Bounds           | Notes                                    |
| ----------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------- |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract                 |

**Note**: `SettlementOps` is an external helper contract that handles settlement execution operations. It uses `ROLE_TIMELOCK` for all operational functions.

### DisputeOps.sol (`contracts/DisputeOps.sol`)

| Function                      | Role            | Lane     | Delay | Bounds           | Notes                                    |
| ----------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------- |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract                 |

**Note**: `DisputeOps` is an external helper contract that handles dispute escalation orchestration. It uses `ROLE_TIMELOCK` for all operational functions.

### YieldOps.sol (`contracts/YieldOps.sol`)

| Function                      | Role            | Lane     | Delay | Bounds           | Notes                                    |
| ----------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------- |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract                 |

**Note**: `YieldOps` is an external helper contract that handles yield withdrawal and distribution operations. It uses `ROLE_TIMELOCK` for all operational functions.

### BondCollector.sol (`contracts/core/BondCollector.sol`)

| Function                      | Role            | Lane     | Delay | Bounds           | Notes                                    |
| ----------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------- |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract                 |

**Note**: `BondCollector` is an external helper contract that handles escalation bond collection. It uses `ROLE_TIMELOCK` for all operational functions.

### ModuleManagementContract.sol (`contracts/core/ModuleManagementContract.sol`)

| Function                      | Role            | Lane     | Delay | Bounds           | Notes                                    |
| ----------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------- |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract for module management |

**Note**: `ModuleManagementContract` is a centralized module management contract that handles queue/activate pattern for default modules. It uses `ROLE_TIMELOCK` for all operational functions.

### EscrowAdminContract.sol (`contracts/admin/EscrowAdminContract.sol`)

| Function                      | Role            | Lane     | Delay | Bounds           | Notes                                    |
| ----------------------------- | --------------- | -------- | ----- | ---------------- | ---------------------------------------- |
| `registerEscrowContract(address)` | `ROLE_TIMELOCK` | Standard | 48h   | Non-zero address | Register escrow contract                 |

**Note**: `EscrowAdminContract` is an admin contract that handles time-delayed parameter updates for escrow contracts. It uses `ROLE_TIMELOCK` for all operational functions.

### ResolverIncentiveModule.sol (`contracts/decentralized-resolution-module/ResolverIncentiveModule.sol`)

**Note:** `ResolverIncentiveModule` is in a separate package (`contracts/decentralized-resolution-module/`) and is **not included in the initial mainnet release**. When ready, it will be deployed and swapped in via the same Slow lane governance process as other modules (queue + activate, ~9 days).

**Governance Functions** (when deployed):

- All configuration changes use Slow lane (queue + activate, ~9 days)
- All functions require `ROLE_TIMELOCK`
- Module swaps follow the same pattern as other modules: deploy new version and swap via Slow lane

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

---

## Ops Contracts Governance Pattern

All ops contracts (CreateOps, SettlementOps, DisputeOps, YieldOps, BondCollector) and auxiliary contracts (ModuleManagementContract, EscrowAdminContract) follow a **consistent governance pattern**:

### Consistent Role Usage

- **DEFAULT_ADMIN_ROLE**: Only granted in constructor to `initialOwner` for initial setup. Transferred to TimelockController after deployment.
- **ROLE_TIMELOCK**: Required for all operational functions (e.g., `registerEscrowContract()`).
- **ROLE_GUARDIAN**: Used for emergency pause functions (where applicable, e.g., `pauseYieldDeposits()` in CreateOps).

### Registration Pattern

All ops contracts require escrow contracts (EscrowVault, EscrowableERC20) to be registered before use:

1. **Registration**: `registerEscrowContract(address escrow)` - Requires `ROLE_TIMELOCK` (governance-controlled)
2. **Access**: Registered escrow contracts receive `ROLE_ESCROW_CONTRACT` role
3. **Usage**: Only registered escrow contracts can call ops contract functions

### Emergency Controls (Where Applicable)

Some ops contracts have emergency pause capabilities:

- **CreateOps**: `pauseYieldDeposits()` can be called by `ROLE_GUARDIAN` (emergency) OR `ROLE_TIMELOCK` (governance)
- **CreateOps**: `resumeYieldDeposits()` can only be called by `ROLE_TIMELOCK` (Guardian cannot resume, down-only control)

This pattern ensures:
- ✅ No admin role for operational functions
- ✅ Consistent governance across all auxiliary contracts
- ✅ Emergency controls where needed (Guardian can pause, Timelock can pause/resume)
- ✅ All changes are time-delayed and transparent

## Key Guarantees

1. **New Escrows Only**: Module changes apply only to new escrows. Existing escrows use snapshotted modules.
2. **No Per-Escrow Overrides**: No governance actor can modify rules for a specific escrow after creation.
3. **Time-Delayed Execution**: All non-emergency changes execute through TimelockController.
4. **Down-Only Emergency**: Guardian can only reduce risk, never increase it.
5. **Consistent Governance**: All ops contracts use the same governance pattern (ROLE_TIMELOCK for operations, ROLE_GUARDIAN for emergency pause where applicable).

---

## References

- `governance.md` - Governance model overview
- `GOVERNANCE_IMPLEMENTATION_STATUS.md` - Implementation status
- `GOVERNANCE_IMPLEMENTATION_PLAN.md` - Implementation plan
- `../reviews/GOVERNANCE_ROLES_CONSISTENCY.md` - Governance roles consistency review

## Change Log### 2026-01-27 - Added ops contracts to governance surface map
  - CreateOps (with yield deposits pause/resume)
  - SettlementOps
  - DisputeOps
  - YieldOps
  - BondCollector
  - ModuleManagementContract
  - EscrowAdminContract
- Documented consistent governance pattern across all ops contracts
- Updated role usage: All `registerEscrowContract()` functions now require `ROLE_TIMELOCK` (governance-controlled)
- Added emergency controls documentation for CreateOps yield deposits pause/resume