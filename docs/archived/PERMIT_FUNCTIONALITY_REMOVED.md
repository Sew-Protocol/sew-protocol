# Permit Functionality - Removed for Contract Size

## Status: REMOVED (Temporary)

Permit functionality has been removed to reduce contract size. This document preserves the implementation for potential future re-addition.

## What Was Removed

### Functions Removed:
1. `createEscrowWithPermit()` - In EscrowVault and EscrowableERC20
2. `_usePermit()` - Internal helper in BaseEscrow

### Errors Removed:
- `PermitExpired(uint256 deadline, uint256 currentTime)`
- `PermitInvalidSignature(address token, address owner)`
- `TokenDoesNotSupportPermit(address token)`

### Imports Removed:
- `@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol`

## Original Implementation

### BaseEscrow._usePermit()

```solidity
/**
 * @dev Internal helper to use ERC-2612 permit for token approval
 * @param token Token address (must support IERC20Permit)
 * @param owner Token owner
 * @param spender Address to approve (this contract)
 * @param amount Amount to approve
 * @param deadline Permit expiration timestamp
 * @param v Signature component
 * @param r Signature component
 * @param s Signature component
 * @dev Validates deadline and calls permit on the token contract
 */
function _usePermit(
    address token,
    address owner,
    address spender,
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) internal {
    // Check deadline
    if (block.timestamp > deadline) {
        revert PermitExpired(deadline, block.timestamp);
    }

    // Check if token supports permit
    if (token.code.length == 0) {
        revert TokenDoesNotSupportPermit(token);
    }

    // Try to call permit
    try IERC20Permit(token).permit(owner, spender, amount, deadline, v, r, s) {
        // Permit succeeded
    } catch {
        revert PermitInvalidSignature(token, owner);
    }
}
```

### EscrowVault.createEscrowWithPermit()

```solidity
/**
 * @notice Create an escrow transfer with ERC-2612 permit (gasless approval)
 * @param token ERC20 token address
 * @param to Recipient address
 * @param amount Amount to escrow
 * @param settings Escrow settings (custom resolver, auto times, etc.)
 * @param deadline Permit expiration timestamp
 * @param v Signature component
 * @param r Signature component
 * @param s Signature component
 * @return workflowId The escrow transfer ID
 * @dev Uses ERC-2612 permit to approve tokens without a separate approval transaction.
 *      Token must support IERC20Permit interface.
 */
function createEscrowWithPermit(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
) public returns (uint256) {
    // Use permit to approve this contract
    _usePermit(token, _msgSender(), address(this), amount, deadline, v, r, s);
    
    // Now create escrow (will use the permit approval)
    return createEscrow(token, to, amount, settings);
}
```

### EscrowableERC20.createEscrowWithPermit()

Similar implementation but uses `address(this)` as the token.

## Impact

**Bytecode Reduction**: ~2-3KB

**User Impact**: 
- Users must pre-approve tokens before creating escrow
- Cannot use gasless permit flow
- Requires two transactions instead of one

**Workaround**: Users can call `token.approve(escrowContract, amount)` before `createEscrow()`

## Re-adding Permit Functionality

To re-add permit functionality in the future:

1. Add back the import: `import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";`
2. Add back the error definitions
3. Add back `_usePermit()` function to BaseEscrow
4. Add back `createEscrowWithPermit()` to EscrowVault and EscrowableERC20
5. Test thoroughly with tokens that support permit

**Note**: Re-adding will increase contract size by ~2-3KB, so ensure other optimizations are in place first.

---

**Removed Date**: 2024-12-31  
**Reason**: Contract size reduction (EIP-170 limit)  
**Estimated Size Saved**: 2-3KB


