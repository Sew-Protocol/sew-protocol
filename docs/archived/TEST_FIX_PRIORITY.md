# Test Fix Priority Analysis

## Current Status
- **Before**: 75 passing tests
- **After**: 25 passing tests (94 passing, 61 failing)
- **Regression**: 50 tests broken by governance changes

## Root Cause Analysis

### Issue #1: `ResolutionModuleNotConfigured()` - **HIGHEST PRIORITY**
- **Count**: 26 failures
- **Root Cause**: Phase 7 removed `authorizedResolver` fallback. All escrow creation now requires a resolution module to be configured.
- **Impact**: Blocks all escrow creation tests
- **Fix Strategy**: 
  - Create a test helper function to set up resolution modules in `beforeEach`
  - Apply to all test files that create escrows

### Issue #2: `AccessControlUnauthorizedAccount` - **HIGH PRIORITY**
- **Count**: 10 failures
- **Root Cause**: Phase 2 migrated from `Ownable` to `AccessControl`. Tests calling admin functions need roles.
- **Impact**: Blocks admin function tests
- **Fix Strategy**:
  - Grant `ROLE_TIMELOCK` to deployer in test setup
  - Update error expectations from `OwnableUnauthorizedAccount` to `AccessControlUnauthorizedAccount`

### Issue #3: Function Name Changes - **MEDIUM PRIORITY**
- **Count**: 10 failures
- **Root Cause**: Phase 3 moved functions to slow lane (queue/activate pattern)
- **Impact**: Tests calling renamed functions
- **Examples**:
  - `setEscrowFeeAddress()` → `queueEscrowFeeAddress()` + `activateEscrowFeeAddress()`
  - `setAavePoolAddressesProvider()` → `queueAavePoolProvider()` + `activateAavePoolProvider()`
  - `owner()` → removed (use `hasRole(DEFAULT_ADMIN_ROLE, address)`)
- **Fix Strategy**: Update function calls in tests

## Recommended Fix Order

### Phase 1: Fix Resolution Module Setup (Blocks 26 tests)
1. Create `test/helpers/setupResolutionModule.ts` helper
2. Apply to all test files that create escrows
3. **Expected Result**: ~26 tests fixed

### Phase 2: Fix Access Control (Blocks 10 tests)
1. Grant `ROLE_TIMELOCK` to deployer in test setup
2. Update error expectations
3. **Expected Result**: ~10 tests fixed

### Phase 3: Fix Function Names (Blocks 10 tests)
1. Update function calls to use new names
2. Handle queue/activate pattern where needed
3. **Expected Result**: ~10 tests fixed

### Phase 4: Remaining Issues
- Fix any edge cases
- Verify all tests pass

## Implementation Plan

### Step 1: Create Test Helper
```typescript
// test/helpers/setupResolutionModule.ts
export async function setupResolutionModule(
  contract: EscrowableERC20 | EscrowVault,
  deployer: Signer,
  resolutionModule: DefaultResolutionModule
) {
  const ROLE_TIMELOCK = await contract.ROLE_TIMELOCK();
  await contract.grantRole(ROLE_TIMELOCK, await deployer.getAddress());
  await contract.proposeResolutionModule(await resolutionModule.getAddress());
  await contract.activateResolutionModule();
}
```

### Step 2: Apply to Test Files
- `test/hardhat/EscrowableERC20.ts`
- `test/hardhat/EscrowVault.test.ts`
- `test/hardhat/BaseEscrow.test.ts`
- `test/hardhat/ErrorHandling.ts`
- Any other files creating escrows

### Step 3: Fix Access Control
- Grant roles in `beforeEach` hooks
- Update error expectations

### Step 4: Fix Function Names
- Search and replace function calls
- Update to queue/activate pattern where needed

## Expected Outcome
- **Target**: Restore to 75+ passing tests
- **Time Estimate**: 2-3 hours
- **Risk**: Low (test-only changes, no contract changes)


