# AaveYieldGenerationModule Token Handling Pattern

**Date**: 2026-01-23  
**Contract**: `contracts/modules/AaveYieldGenerationModule.sol`  
**Function**: `depositForYield()`

## Overview

The `AaveYieldGenerationModule` handles two different escrow contract patterns:
1. **EscrowVault**: Multi-token escrow (tokens held by vault, module pulls from vault)
2. **EscrowableERC20**: Single-token escrow (escrow contract IS the token, approves pool directly)

## Implementation Pattern

### Token Transfer Logic

```solidity
// Check if escrow contract approved this module (for EscrowVault)
uint256 moduleAllowance = IERC20(token).allowance(escrowContract, address(this));
bool pulledTokens = false;

if (moduleAllowance >= amount) {
    // EscrowVault case: Pull tokens from escrow contract
    IERC20(token).safeTransferFrom(escrowContract, address(this), amount);
    pulledTokens = true;
    // Approve pool to spend tokens (module now holds the tokens)
    // ... approval logic ...
}
// Else: EscrowableERC20 case - escrow contract approved pool directly, just call pool.supply

// Deposit to Aave
aavePool.supply(token, amount, escrowContract, 0);
```

## Design Decisions

### ✅ Why Check Allowance First?

**Previous approach**: Try to pull tokens, check return value  
**Current approach**: Check allowance first, then pull if sufficient

**Benefits**:
1. **Clearer logic**: Explicit check before attempting transfer
2. **Better error handling**: Fails fast if allowance insufficient
3. **Gas efficiency**: Avoids failed `transferFrom` call
4. **Type safety**: Uses `safeTransferFrom` (reverts on failure)

### EscrowVault Pattern

**Flow**:
1. `EscrowVault._depositForYield()` approves module to spend tokens
2. Module checks `allowance(escrowContract, module) >= amount`
3. If sufficient: Module pulls tokens via `safeTransferFrom`
4. Module approves Aave pool
5. Module calls `pool.supply()` (pool pulls from module)
6. Module resets pool approval to zero

**Key points**:
- EscrowVault holds tokens
- Module acts as intermediary (pulls from vault, supplies to pool)
- `msg.sender` in `pool.supply()` = module (pool pulls from module)

### EscrowableERC20 Pattern

**Flow**:
1. `EscrowableERC20._depositForYield()` approves Aave pool directly
2. Module checks `allowance(escrowContract, module)` - insufficient
3. Module skips token pull
4. Module calls `pool.supply()` (pool pulls from escrowContract)
5. No approval reset needed (module never held tokens)

**Key points**:
- EscrowableERC20 IS the token contract
- EscrowableERC20 approves pool directly (not module)
- `msg.sender` in `pool.supply()` = module, but pool pulls from `escrowContract` (onBehalfOf)

## Security Considerations

### ✅ Safe Transfer Pattern

- Uses `safeTransferFrom` (reverts on failure, no silent failures)
- Checks allowance before attempting transfer
- Resets approvals to zero after use (defense in depth)

### ✅ Approval Management

**EscrowVault**:
- EscrowVault approves module
- Module approves pool
- Both approvals reset to zero after use

**EscrowableERC20**:
- EscrowableERC20 approves pool directly
- Module never holds tokens (no module approval needed)

## Integration Points

### EscrowVault._depositForYield()

```solidity
function _depositForYield(...) internal override {
    // Approve module to spend tokens
    address moduleAddress = address(generationModule);
    if (moduleAddress != address(0)) {
        // ... approval logic ...
    }
    generationModule.depositForYield(workflowId, token, amount);
    // Reset approval to zero
}
```

### EscrowableERC20._depositForYield()

```solidity
function _depositForYield(...) internal override {
    // Approve pool directly (not module)
    address approvalTarget = generationModule.getApprovalTarget(token);
    if (approvalTarget != address(0)) {
        // ... approval logic for pool ...
    }
    generationModule.depositForYield(workflowId, token, amount);
    // Reset approval to zero
}
```

## Testing Considerations

### Test Cases Needed

1. ✅ **EscrowVault with sufficient allowance**: Module pulls tokens, supplies to pool
2. ✅ **EscrowVault with insufficient allowance**: Should revert or handle gracefully
3. ✅ **EscrowableERC20 pattern**: Module skips pull, pool pulls from escrowContract
4. ✅ **Approval reset**: Verify approvals reset to zero after deposit

## Related Documentation

- **Architecture**: `docs/optimization/AAVE_ARCHITECTURE_ANALYSIS.md`
- **Module Pattern**: `docs/reference/MODULE_MAP.md`
- **Escrow Creation**: `docs/architecture/ESCROW_CREATION_AND_SETTINGS.md`
