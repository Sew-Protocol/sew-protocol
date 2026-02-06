# Prompt: Fix 40 Failing Tests After Yield Preset Migration

## Context

Recent changes migrated the escrow system from `yieldDistribution` struct to `YieldPreset` enum. All core contracts compile successfully, but 40 Foundry tests are failing.

## Error Summary

### Primary Issue: ERC20InsufficientAllowance (39 tests)
- **Error**: `ERC20InsufficientAllowance(address, 0, amount)`
- **Affected Test Files**:
  - `test/foundry/core/AutoTransfer.t.sol` - 14 tests
  - `test/foundry/core/BaseEscrowComprehensive.t.sol` - 15 tests
  - `test/foundry/core/EscrowVaultUniqueCoverage.t.sol` - 1 test
  - `test/foundry/core/WithdrawEscrow.t.sol` - 5 tests
  - `test/foundry/decentralized-resolution-module/EscalationDepthHistogram.integration.t.sol` - 3 tests

### Secondary Issues (1 test each)
- `test/foundry/governance/CirculatingSupplyQuorum.t.sol`: `vm.prank: cannot override an ongoing prank`
- `test/foundry/core/EscrowEdgeCases.t.sol`: `test_createEscrow_MaxAmount_Overflow()` - "next call did not revert as expected"

## Recent Changes Made

1. **Removed `yieldDistribution` struct** from `EscrowSettings`
2. **Added `yieldPreset: YieldPreset`** to `EscrowSettings` 
3. **Updated `BaseEscrow.createEscrow()`** to derive distribution data from presets using `YieldPresetLibrary.deriveDistributionData()`
4. **Updated `_handleYield()`** to use presets instead of `escrowYieldDistributions` mapping
5. **Test files updated** to use `yieldPreset: YieldPreset.OFF` instead of `yieldDistribution` structs

## Key Files Changed

- `contracts/types/EscrowTypes.sol` - EscrowSettings struct modified
- `contracts/core/BaseEscrow.sol` - createEscrow and _handleYield logic updated
- `contracts/libraries/YieldPresetLibrary.sol` - New library for deriving distribution data
- `contracts/types/YieldPresets.sol` - New enum (OFF, TO_SENDER)

## Investigation Required

The `ERC20InsufficientAllowance` errors suggest that:
1. **Tokens may not be approved** before `createEscrow()` is called
2. **The approval flow might have changed** in `createEscrow()` 
3. **Tests might be using `vault.getDefaultSettings()`** which may no longer work correctly
4. **Token transfer logic** might have been affected by the yield preset changes

## Specific Test Patterns to Check

1. **Tests using `vault.getDefaultSettings()`**:
   ```solidity
   vault.createEscrow(address(token), seller, amount, vault.getDefaultSettings())
   ```
   - Verify `getDefaultSettings()` returns correct `YieldPreset`
   - Ensure settings structure matches new `EscrowSettings`

2. **Tests with custom `EscrowSettings`**:
   ```solidity
   EscrowSettings memory settings = EscrowSettings({
       customResolver: address(0),
       yieldPreset: YieldPreset.OFF,  // Was: yieldDistribution: ...
       autoReleaseTime: 0,
       autoCancelTime: 0
   });
   vault.createEscrow(address(token), seller, amount, settings)
   ```

3. **Token approval in setUp()**:
   - Check if `token.approve(address(vault), amount)` is called
   - Verify approval happens before `createEscrow()` calls
   - Confirm approval amounts match escrow amounts

## Files to Review

1. `test/foundry/core/AutoTransfer.t.sol` - Check setUp() and token approvals
2. `test/foundry/core/BaseEscrowComprehensive.t.sol` - Review all test functions for approval patterns
3. `contracts/core/BaseEscrow.sol` - Verify `createEscrow()` token handling unchanged
4. `contracts/libraries/SettingsValidationLibrary.sol` - Check `getDefaultSettings()` implementation

## Fix Strategy

### For ERC20InsufficientAllowance errors:
1. **Audit each failing test's setUp()** - Ensure `token.approve()` is called with sufficient allowance
2. **Check token approval timing** - Approvals must happen before `createEscrow()` calls
3. **Verify approval amounts** - Must be >= the escrow amount (may need to account for fees)
4. **Review `createEscrow()` implementation** - Confirm it still uses `transferFrom` correctly

### For vm.prank error:
- `test/foundry/governance/CirculatingSupplyQuorum.t.sol:setUp()`
- Replace nested `vm.prank` calls with `vm.startPrank`/`vm.stopPrank`
- Or remove redundant prank calls

### For EscrowEdgeCases test:
- `test_createEscrow_MaxAmount_Overflow()` - Verify max amount validation still works
- Check if the overflow/revert logic was affected by EscrowSettings changes

## Validation

After fixes:
1. Run: `forge test`
2. All 411 tests should pass
3. Core contracts should still compile: `forge build`

## Codebase Context

- Solidity version: `^0.8.33`
- Testing framework: Foundry (forge-std)
- Token standard: ERC20
- All contracts compile successfully - issue is test-specific

## Expected Outcome

All 40 failing tests should pass after:
- Adding missing `token.approve()` calls where needed
- Fixing `vm.prank` usage in CirculatingSupplyQuorum
- Verifying edge case test logic still works with new EscrowSettings
