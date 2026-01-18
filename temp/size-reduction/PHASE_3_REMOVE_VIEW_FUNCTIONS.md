# Phase 3: Remove View Functions from BaseEscrow

## Functions to Remove

1. `isDisputeTimedOut(uint256)` - Line ~605
   - Can be computed from `disputeRaisedTimestamp[workflowId]` + `timeoutConfig.maxDisputeDuration`
   - Move to EscrowViewContract if needed

## Functions to Keep

1. `getEscrowTransfer(uint256)` - Line ~1107
   - Needed for EscrowViewContract compatibility
   
2. `getPendingSettlement(uint256)` - Line ~979
   - Needed for on-chain checks

3. Public storage getters (auto-generated):
   - `escrowTransfers(uint256)`
   - `escrowSettings(uint256)`
   - `claimableBalances(uint256, address)`
   - `pendingSettlements(uint256)`

## Changes Required

### BaseEscrow.sol
- Remove `isDisputeTimedOut()` function (lines ~605-616)
- Keep `getEscrowTransfer()` and `getPendingSettlement()`

### EscrowViewContract.sol
- Add `isDisputeTimedOut()` implementation if needed
