# Recovery Functionality in Multi-Escrow

## Overview

In Phase 3, the `recoverERC20` and `recoverNativeETH` functions have been **entirely removed** from the production contracts (`BaseEscrow.sol`, `EscrowVault.sol`, and `EscrowableERC20.sol`) to comply with strict EIP-170 contract size limits (24.576 KB).

This document serves as a guide for future developers who may wish to re-add this functionality if contract space becomes available.

## Why it was removed

Current contract sizes (as of Feb 2026):
- `EscrowVault`: ~24.9 KB
- `EscrowableERC20`: ~25.3 KB

To fit core escrow logic and critical security fixes, non-core features like generic token recovery were sacrificed.

## How to implement Recovery Safely

If you decide to re-implement `recoverERC20`, follow these strict requirements to avoid introducing vulnerabilities.

### 1. Function Signature and Modifiers

The function MUST be gated by both access control and a reentrancy guard.

```solidity
/**
 * @notice Recover ERC20 tokens sent to the contract by mistake
 * @param token Token address to recover
 * @param recipient Address to receive the recovered tokens
 * @param amount Amount of tokens to recover
 * @return success Whether recovery succeeded
 */
function recoverERC20(
    address token,
    address recipient,
    uint256 amount
) external onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
    // ... logic ...
}
```

### 2. Mandatory Accounting Check

You MUST validate that the tokens being recovered are indeed "excess" or "dust" and do not belong to active escrows, pending fees, or claimable balances.

**Correct Calculation Logic:**

```solidity
// 1. Sum up all protected funds
uint256 protected = totalHeldInEscrowPerToken[token] + 
                    totalFeesPerToken[token] + 
                    totalClaimableAssets[token];

// 2. Check actual contract balance
uint256 balance = IERC20(token).balanceOf(address(this));

// 3. Determine safe available amount
uint256 available = balance > protected ? balance - protected : 0;

// 4. Enforce limit
require(amount <= available, "Recovery: Amount exceeds available excess");

// 5. Execute transfer
IERC20(token).safeTransfer(recipient, amount);
emit ERC20Recovered(token, recipient, amount);
return true;
```

### 3. Location

- Add the `event ERC20Recovered(address indexed token, address indexed recipient, uint256 amount);` to `BaseEscrow.sol`.
- Add the `recoverERC20` function to `EscrowVault.sol` and `EscrowableERC20.sol` (or `BaseEscrow.sol` if they share the exact same accounting state variables).

## Security Warnings

- **NEVER** implement a recovery function without `ROLE_TIMELOCK` protection.
- **NEVER** recover tokens based on `IERC20(token).balanceOf(address(this))` alone without subtracting protected funds.
- Improper implementation can allow a malicious governance proposal to drain all user funds from the vault.