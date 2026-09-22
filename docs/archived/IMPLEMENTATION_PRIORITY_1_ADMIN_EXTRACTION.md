# Priority 1: Admin Extraction Implementation Plan

## Goal
Extract all admin/slow-lane functions from BaseEscrow to EscrowAdminContract, saving ~3-5 KB.

## Implementation Steps

### Step 1: Add Minimal Setters to BaseEscrow ✅ (In Progress)
Add these functions to BaseEscrow (only callable by admin contract):
- `setFeeRecipient(address)` - only callable by admin
- `setEscrowFeeBps(uint256)` - only callable by admin
- `setYieldProtocolFeeBps(uint256)` - only callable by admin
- `setAppealBondProtocolFeeBps(uint256)` - only callable by admin
- `setResolutionModule(address)` - only callable by admin
- `setTimeoutConfig(TimeoutConfig calldata)` - already exists, verify access control

### Step 2: Create EscrowAdminContract ✅ (Created)
- Created `contracts/admin/EscrowAdminContract.sol`
- Inherits `SlowLaneQueueActivate`
- Owns all pending state
- Calls minimal setters on BaseEscrow

### Step 3: Remove from BaseEscrow (Pending)
Remove:
- `SlowLaneQueueActivate` inheritance
- All `Pending*` storage variables
- All `queue*()` functions
- All `activate*()` functions
- All `getPending*()` functions
- Timeout config setters (keep only `setTimeoutConfig`)

### Step 4: Update Access Control
- Add `ROLE_ADMIN_CONTRACT` to BaseEscrow
- Grant admin contract this role
- Update all minimal setters to require this role

### Step 5: Update Tests
- Deploy EscrowAdminContract in test setup
- Update all admin function calls to go through EscrowAdminContract

## Files to Modify

1. `contracts/core/BaseEscrow.sol`
   - Add minimal setter functions
   - Remove SlowLaneQueueActivate inheritance
   - Remove all queue/activate/getPending functions
   - Remove pending state variables

2. `contracts/admin/EscrowAdminContract.sol` ✅ (Created)

3. `contracts/core/EscrowVault.sol`
   - Verify no admin functions remain (should be minimal)

4. `contracts/core/EscrowableERC20.sol`
   - Verify no admin functions remain (should be minimal)

5. All test files
   - Update to use EscrowAdminContract

## Expected Savings
- SlowLaneQueueActivate bytecode: ~800 bytes
- Queue/activate/getPending functions: ~2-3 KB
- Pending state structs: ~200 bytes
- Total: ~3-5 KB
