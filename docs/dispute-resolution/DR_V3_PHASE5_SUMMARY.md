# DR v3 Phase 5: Insurance Pool + Recovery Procedures

## Overview

Phase 5 focuses on **insurance pool management** and **recovery procedures** - operational controls rather than core mechanics. This phase ensures the system has proper safeguards and recovery mechanisms for production deployment.

## 5.1 Insurance Pool (Minimal, Launch-Safe)

### Implementation

**InsurancePoolVault Contract** (`contracts/decentralized-resolution-module/InsurancePoolVault.sol`)

**Key Features:**
- ✅ Vault contract holding slashed funds
- ✅ Source-tagged accounting: `timeout`, `reversal`, `fraud` (separate tracking)
- ✅ Automatic deposits from slashing module (via `ROLE_SLASHING_MODULE`)
- ✅ Withdrawals disabled by default (gated by `withdrawalsEnabled` flag)
- ✅ Slow lane governance for payouts: `proposePayout()` → 7-day delay → `executePayout()`
- ✅ Events: `InsuranceFunded`, `InsurancePayoutProposed`, `InsurancePayoutExecuted`

**Distribution Logic:**
- 50% of slashed funds → Insurance Pool (via vault)
- 30% → Protocol Treasury (TODO: when treasury contract exists)
- 20% → Burned (deflationary)

**Integration:**
- `ResolverSlashingModuleV1` now transfers funds to `InsurancePoolVault` on slash
- Source tags (`TIMEOUT_ACCEPT`, `TIMEOUT_RESOLVE`, `REVERSAL`, `FRAUD`) are preserved
- Workflow IDs are tracked for auditability

### Governance Controls

**Deposits:**
- Automatic from slashing module (no governance required)
- Anyone can also fund via `fundInsurancePool()` (backward compatibility)

**Withdrawals:**
- **Default:** Disabled (`withdrawalsEnabled = false`)
- **Slow Lane:** `proposePayout()` → 7-day delay → `executePayout()` (requires `ROLE_TIMELOCK`)
- **Direct Withdrawals:** Only if `withdrawalsEnabled = true` (requires `ROLE_TIMELOCK`)

**Access Control:**
- `ROLE_SLASHING_MODULE`: Can deposit funds
- `ROLE_TIMELOCK`: Can propose/execute payouts
- `ROLE_ADMIN`: Can enable/disable withdrawals

### Events

```solidity
event InsuranceFunded(
    uint256 indexed amount,
    ISlashingModule.SlashReason indexed source,
    uint256 indexed workflowId,
    uint256 newTotalBalance
);

event InsurancePayoutProposed(
    uint256 indexed payoutId,
    address indexed to,
    uint256 amount,
    uint256 indexed workflowId,
    string reason,
    uint64 eta
);

event InsurancePayoutExecuted(
    uint256 indexed payoutId,
    address indexed to,
    uint256 amount,
    uint256 indexed workflowId
);
```

## 5.2 Recovery Procedures (Mechanical Playbooks)

### 5.2.1 Swap to NoOp Runbook

**Status:** ✅ Already proven in Phase 4 E2E tests

**Procedure:**
1. Queue `address(0)` for staking/slashing modules via `queueStakingModule()` / `queueSlashingModule()`
2. Wait 7 days (slow lane delay)
3. Activate via `activateStakingModule()` / `activateSlashingModule()`
4. System continues operating without V3 modules (backward compatible)

**Test Coverage:** `test_E2E_NoOpRollback()` in `DRv3E2E.t.sol`

**Documentation:** See `DR_V3_PHASE4_E2E_TRACES.md` for detailed execution trace

### 5.2.2 Pause Slashing (Circuit Breaker)

**Status:** ✅ Already implemented in `ResolverSlashingModuleV1`

**Functions:**
- `triggerCircuitBreaker(string reason)`: Activates circuit breaker (requires `ROLE_ADMIN`)
- `resetCircuitBreaker()`: Deactivates after cooldown (1 hour, requires `ROLE_ADMIN`)

**Scope:**
- Prevents new slashes when active
- Existing slashes continue processing
- Mass unavailability detection can auto-trigger

**Test Coverage:** `test_E2E_CircuitBreakerPreventsSlashing()` in `DRv3E2E.t.sol`

### 5.2.3 Freeze All New Assignments (Emergency Toggle)

**Status:** ✅ Implemented

**Implementation:**
- Added `newAssignmentsPaused` state variable to `DecentralizedResolutionModule`
- `pauseNewAssignments(string reason)`: Freezes all new assignments (requires `ROLE_TIMELOCK` or `DEFAULT_ADMIN_ROLE`)
- `resumeNewAssignments()`: Resumes new assignments (requires `ROLE_TIMELOCK` or `DEFAULT_ADMIN_ROLE`)
- `areNewAssignmentsPaused()`: Query function to check pause status

**Behavior:**
- When paused, `selectResolverRoundRobin()` and `selectResolverWithQuality()` return `address(0)`
- Existing disputes continue processing normally (only new assignments are blocked)
- Events: `NewAssignmentsPaused`, `NewAssignmentsResumed`

**Use Cases:**
- Emergency response to system issues
- Planned maintenance windows
- Gradual rollout control

## 5.3 Circuit Breaker Automation

**Status:** ⏸️ Manual for now (recommended for launch)

**Current Implementation:**
- Manual trigger via `triggerCircuitBreaker()` (multisig)
- Auto-trigger on mass unavailability (30% threshold)
- Transparent events: `CircuitBreakerActivated`, `CircuitBreakerDeactivated`

**Future Automation (Optional):**
- Objective on-chain signals: % of timeouts over epoch
- Threshold-based triggers (e.g., >30% timeout rate)
- Requires careful design to avoid false positives

## Files Modified

### New Contracts
- `contracts/decentralized-resolution-module/InsurancePoolVault.sol` - Insurance pool vault

### Modified Contracts
- `contracts/decentralized-resolution-module/ResolverSlashingModuleV1.sol`
  - Added `InsurancePoolVault` integration
  - Updated `initialize()` to accept vault and stable token
  - Updated `_distributeSlashedFunds()` to transfer to vault
  - Added `setInsurancePoolVault()` governance function
- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol`
  - Added `newAssignmentsPaused` state variable
  - Added `pauseNewAssignments()` and `resumeNewAssignments()` functions
  - Updated `selectResolverRoundRobin()` and `selectResolverWithQuality()` to check pause flag
  - Added events: `NewAssignmentsPaused`, `NewAssignmentsResumed`

### Modified Tests
- `test/foundry/decentralized-resolution-module/DRv3E2E.t.sol` - Updated to deploy vault
- `test/foundry/decentralized-resolution-module/SlashingModuleInvariants.t.sol` - Updated to deploy vault

## Next Steps

1. ✅ **5.1 Insurance Pool** - Complete
2. ✅ **5.2.1 Swap to NoOp** - Documented (already proven)
3. ✅ **5.2.2 Pause Slashing** - Already implemented
4. ✅ **5.2.3 Freeze Assignments** - Complete
5. ⏸️ **5.3 Circuit Breaker Automation** - Manual for now (recommended)

## Testing Status

- ✅ Insurance pool vault compiles
- ✅ Slashing module integration compiles
- ⏳ E2E tests need to be updated/verified
- ⏳ Recovery procedure tests need to be added

## Security Considerations

1. **Withdrawals Disabled by Default:** Prevents accidental fund drainage
2. **Slow Lane Governance:** 7-day delay for payouts prevents rushed decisions
3. **Source Tags:** Enables auditability and proper accounting
4. **Circuit Breaker:** Prevents cascading failures
5. **NoOp Rollback:** Allows graceful degradation if issues arise
