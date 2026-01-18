# Constructor Comparison: EscrowVault vs EscrowableERC20

## EscrowVault Constructor

```solidity
constructor(
    uint256 escrowFeeBps,
    address feeAddress,
    address yieldOpsAddress,
    address disputeOpsAddress
) SlowLaneQueueActivate() {
    // Validation
    if (escrowFeeBps > ESCROW_FEE_DENOMINATOR) {
        revert InvalidEscrowFee(escrowFeeBps, ESCROW_FEE_DENOMINATOR);
    }
    if (feeAddress == address(0)) revert InvalidAddress('Fee address cannot be zero', feeAddress);
    if (yieldOpsAddress == address(0)) revert InvalidAddress('YieldOps address cannot be zero', yieldOpsAddress);
    if (disputeOpsAddress == address(0)) revert InvalidAddress('DisputeOps address cannot be zero', disputeOpsAddress);

    // Assignment
    escrowFee = escrowFeeBps;
    escrowFeeAddress = feeAddress;
    yieldOps = YieldOps(yieldOpsAddress);
    disputeOps = DisputeOps(disputeOpsAddress);
    _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

    // Initialize protocol fees with validation
    uint256 initialYieldFee = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
    uint256 initialAppealFee = 0;
    
    if (initialYieldFee > MAX_PROTOCOL_FEE_BPS) {
        revert FeeExceedsMaximum(initialYieldFee, MAX_PROTOCOL_FEE_BPS);
    }
    if (initialAppealFee > MAX_PROTOCOL_FEE_BPS) {
        revert FeeExceedsMaximum(initialAppealFee, MAX_PROTOCOL_FEE_BPS);
    }
    
    yieldProtocolFeeBps = initialYieldFee;
    appealBondProtocolFeeBps = initialAppealFee;

    // Initialize timeout config
    timeoutConfig = TimeoutConfig({
        defaultAutoReleaseTime: 0,
        defaultAutoCancelTime: 0,
        maxDisputeDuration: 90 days,
        appealWindowDuration: 2 days
    });
}
```

## EscrowableERC20 Constructor

```solidity
constructor(
    string memory name,
    string memory symbol,
    uint256 escrowFeeBps,
    address feeAddress,
    address yieldOpsAddress,
    address disputeOpsAddress
) ERC20(name, symbol) {
    // Validation
    if (escrowFeeBps > ESCROW_FEE_DENOMINATOR) {
        revert InvalidEscrowFee(escrowFeeBps, ESCROW_FEE_DENOMINATOR);
    }
    if (feeAddress == address(0)) revert InvalidAddress('Fee address cannot be zero', feeAddress);
    if (yieldOpsAddress == address(0)) revert InvalidAddress('YieldOps address cannot be zero', yieldOpsAddress);
    if (disputeOpsAddress == address(0)) revert InvalidAddress('DisputeOps address cannot be zero', disputeOpsAddress);

    // Assignment
    escrowFee = escrowFeeBps;
    escrowFeeAddress = feeAddress;
    yieldOps = YieldOps(yieldOpsAddress);
    disputeOps = DisputeOps(disputeOpsAddress);
    
    _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    _grantRole(ROLE_TIMELOCK, _msgSender());

    // Initialize protocol fees (NO VALIDATION)
    yieldProtocolFeeBps = 3000; // 30% default
    appealBondProtocolFeeBps = 0; // 0% default

    // Initialize timeout config
    timeoutConfig = TimeoutConfig({
        defaultAutoReleaseTime: 0,
        defaultAutoCancelTime: 0,
        maxDisputeDuration: 90 days,
        appealWindowDuration: 2 days
    });
    
    // Mint initial supply to deployer
    _mint(_msgSender(), INITIAL_SUPPLY);
}
```

## Key Differences

### 1. **Additional Parameters** (EscrowableERC20)
- `name` and `symbol` for ERC20 token
- Inherits from `ERC20(name, symbol)` instead of `SlowLaneQueueActivate()`

### 2. **Protocol Fee Validation** ⚠️ **MISSING IN EscrowableERC20**
- **EscrowVault**: ✅ Validates `initialYieldFee` and `initialAppealFee` against `MAX_PROTOCOL_FEE_BPS`
- **EscrowableERC20**: ❌ No validation - directly assigns `3000` and `0`

**Issue**: EscrowableERC20 should also validate protocol fees to prevent misconfiguration.

### 3. **Role Assignment**
- **EscrowVault**: Only grants `DEFAULT_ADMIN_ROLE`
- **EscrowableERC20**: Grants both `DEFAULT_ADMIN_ROLE` and `ROLE_TIMELOCK`

### 4. **Token Minting** (EscrowableERC20 only)
- Mints `INITIAL_SUPPLY` to deployer

### 5. **Variable Naming** ✅ **NOW CONSISTENT**
- Both now use full names: `escrowFeeBps`, `feeAddress`, `yieldOpsAddress`, `disputeOpsAddress`
- Previously EscrowVault used: `f`, `fa`, `y`, `d` (now fixed)

## Recommendations

1. ✅ **FIXED**: EscrowVault now uses full parameter names
2. ⚠️ **TODO**: Add protocol fee validation to EscrowableERC20 constructor
3. ✅ **CONSISTENT**: Both constructors now follow same naming pattern

## Size Impact

Using full names instead of single-character abbreviations:
- **Source code**: Slightly larger (more readable)
- **Deployed bytecode**: No significant impact (variable names don't affect bytecode size)
- **Gas cost**: No impact (variable names are compile-time only)

**Note**: Variable names are stripped during compilation, so this change improves code readability without affecting contract size.
