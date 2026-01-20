# Changes to Apply to EscrowableERC20 Later

## Phase 3: View Function Removal
- [ ] Remove `isDisputeTimedOut()` from EscrowableERC20 (if it exists)
- [ ] EscrowViewContract already provides this functionality

## Phase 4: Settlement Automation
- [ ] EscrowableERC20 inherits from BaseEscrow, so changes to BaseEscrow automatically apply
- [ ] No additional changes needed for EscrowableERC20

## Other Optimizations Already Applied to EscrowVault
- [ ] Remove redundant events (EscrowTransferCreated/Released/Cancelled)
- [ ] Use onlyRole(ROLE_FEE_RECIPIENT) instead of address check
- [ ] Grant role externally (remove _grantRole from constructor)
- [ ] Simplify recoverERC20 (remove RecoveryLibrary call)
- [ ] Consolidate module getters

## Notes
- EscrowableERC20 inherits from BaseEscrow, so most changes are inherited
- Only EscrowableERC20-specific functions need updates
- Focus on EscrowVault first, then apply same patterns to EscrowableERC20
