# Constructor Review: EscrowVault & EscrowableERC20

**Date**: 2026-01-23 (Updated: 2026-01-23)  
**Contracts**: `EscrowVault.sol`, `EscrowableERC20.sol`  
**Status**: ✅ **UPDATED** - Contract validation and immutability improvements implemented

## EscrowVault Constructor

```solidity
constructor(
    uint256 escrowFeeBps,
    address feeAddress,
    address yieldOpsAddress,
    address disputeOpsAddress,
    address moduleManagementAddress
) {
    address deployer = _msgSender();
    _grantRole(DEFAULT_ADMIN_ROLE, deployer);
    _grantRole(ROLE_TIMELOCK, deployer);
    if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
    if (feeAddress == address(0)) revert ZeroAddress(1);
    if (yieldOpsAddress == address(0)) revert ZeroAddress(2);
    if (disputeOpsAddress == address(0)) revert ZeroAddress(3);
    if (moduleManagementAddress == address(0)) revert ZeroAddress(4);
    if (yieldOpsAddress.code.length == 0 || !_supportsInterface(yieldOpsAddress, 0x01ffc9a7)) revert ZeroAddress(2);
    if (disputeOpsAddress.code.length == 0 || !_supportsInterface(disputeOpsAddress, 0x01ffc9a7)) revert ZeroAddress(3);
    if (moduleManagementAddress.code.length == 0 || !_supportsInterface(moduleManagementAddress, 0x01ffc9a7)) revert ZeroAddress(4);
    escrowFee = escrowFeeBps;
    escrowFeeAddress = feeAddress;
    moduleManagement = ModuleManagementContract(moduleManagementAddress);
    yieldOps = YieldOps(yieldOpsAddress);
    disputeOps = DisputeOps(disputeOpsAddress);
    yieldProtocolFeeBps = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
    appealBondProtocolFeeBps = 0;
    timeoutConfig.maxDisputeDuration = 90 days;
    timeoutConfig.appealWindowDuration = 2 days;
    emit WiringConfigured(yieldOpsAddress, disputeOpsAddress, moduleManagementAddress);
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
    address disputeOpsAddress,
    address moduleManagementAddress
) ERC20(name, symbol) {
    // Validate escrow fee is within allowed range (0 to 2%)
    if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
    if (feeAddress == address(0)) revert ZeroAddress(1);
    if (yieldOpsAddress == address(0)) revert ZeroAddress(2);
    if (disputeOpsAddress == address(0)) revert ZeroAddress(3);
    if (moduleManagementAddress == address(0)) revert ZeroAddress(4);
    if (yieldOpsAddress.code.length == 0 || !_supportsInterface(yieldOpsAddress, 0x01ffc9a7)) revert ZeroAddress(2);
    if (disputeOpsAddress.code.length == 0 || !_supportsInterface(disputeOpsAddress, 0x01ffc9a7)) revert ZeroAddress(3);
    if (moduleManagementAddress.code.length == 0 || !_supportsInterface(moduleManagementAddress, 0x01ffc9a7)) revert ZeroAddress(4);

    escrowFee = escrowFeeBps;
    escrowFeeAddress = feeAddress;
    yieldOps = YieldOps(yieldOpsAddress);
    disputeOps = DisputeOps(disputeOpsAddress);
    moduleManagement = ModuleManagementContract(moduleManagementAddress);
    
    _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    _grantRole(ROLE_TIMELOCK, _msgSender());

    // Initialize protocol fees (constants are already within bounds)
    yieldProtocolFeeBps = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
    appealBondProtocolFeeBps = 0; // 0% default

    // Set timeout config fields directly (avoid struct literal to save bytecode)
    timeoutConfig.maxDisputeDuration = 90 days;
    timeoutConfig.appealWindowDuration = 2 days;
    // Note: defaultAutoReleaseTime and defaultAutoCancelTime are zero by default
    
    emit WiringConfigured(yieldOpsAddress, disputeOpsAddress, moduleManagementAddress);
    
    // Mint initial supply to deployer
    _mint(_msgSender(), INITIAL_SUPPLY);
}
```

---

## Security Analysis

### ✅ Strengths

1. **Input Validation**: Both constructors validate:
   - Escrow fee is within bounds (0 to 2%)
   - All addresses are non-zero

2. **Role Assignment**: Both grant `DEFAULT_ADMIN_ROLE` and `ROLE_TIMELOCK` to deployer

3. **Protocol Fee Initialization**: Both set reasonable defaults (30% yield fee, 0% appeal bond fee)

4. **Timeout Configuration**: Both set reasonable defaults (90 days dispute, 2 days appeal window)

### ✅ Issues Fixed (2026-01-23)

#### 1. ✅ Contract Validation (IMPLEMENTED)

**Status**: ✅ **FIXED** - Contract validation with `supportsInterface` implemented

**Implementation**:
- Validates all aux contract addresses are contracts (not EOAs) via `code.length == 0` check
- Checks `supportsInterface(0x01ffc9a7)` to ensure IERC165 support (AccessControl implements this)
- Applied to `yieldOpsAddress`, `disputeOpsAddress`, and `moduleManagementAddress`
- Uses private helper `_supportsInterface()` for safe validation

**Previous Issue**: Constructors did not verify that aux addresses are contracts before using them.

**Result**: ✅ Fails fast in constructor if EOA addresses provided, with clear error messages.

---

#### 2. ✅ Protocol Fee Consistency (IMPLEMENTED)

**Status**: ✅ **FIXED** - Both contracts now use `DEFAULT_YIELD_PROTOCOL_FEE_BPS` constant

**Implementation**:
- Constant moved to `BaseEscrow` (shared by both contracts)
- EscrowVault now uses `DEFAULT_YIELD_PROTOCOL_FEE_BPS` instead of hardcoded `3000`
- Both contracts explicitly set `appealBondProtocolFeeBps = 0`

**Result**: ✅ Consistent initialization pattern across both contracts

---

#### 3. ✅ Explicit Initialization (IMPLEMENTED)

**Status**: ✅ **FIXED** - Both contracts explicitly initialize all protocol fees

**Implementation**:
- EscrowVault explicitly sets `appealBondProtocolFeeBps = 0`
- Both contracts use consistent initialization pattern

**Result**: ✅ Clear and explicit initialization, no implicit defaults

---

#### 5. Missing CreateOps/SettlementOps/BondCollector Initialization (DESIGN DECISION)

**Issue**: Constructors don't initialize `createOps`, `settlementOps`, or `bondCollector`.

**Current behavior**:
- These are set to `address(0)` initially
- Must be set via `setCreateOps()`, `setSettlementOps()`, `setBondCollector()` after deployment
- `createEscrow()` will revert if `createOps` is not set

**Analysis**: 
- ✅ **Intentional design**: These contracts may not exist at deployment time
- ✅ **Flexible**: Allows deployment before all dependencies are ready
- ⚠️ **Risk**: If not set, contract is unusable (but `createEscrow` checks and reverts)

**Recommendation**: Current design is acceptable, but consider:
1. Document that these must be set before use
2. Add deployment checklist
3. Consider making them constructor parameters if they're always needed

**Priority**: Low (design decision, but documentation would help)

---

## Comparison: EscrowVault vs EscrowableERC20

| Aspect | EscrowVault | EscrowableERC20 | Status |
|--------|-------------|-----------------|--------|
| Escrow fee validation | ✅ | ✅ | ✅ Consistent |
| Address validation | ✅ | ✅ | ✅ Consistent |
| Contract validation | ✅ | ✅ | ✅ Consistent (supportsInterface) |
| Role assignment | ✅ | ✅ | ✅ Consistent |
| Protocol fee initialization | ✅ Constant | ✅ Constant | ✅ Consistent |
| Appeal bond fee initialization | ✅ Explicit (0) | ✅ Explicit (0) | ✅ Consistent |
| Timeout config | ✅ Complete | ✅ Complete | ✅ Consistent |
| Wiring event | ✅ | ✅ | ✅ Consistent |
| Immutability | ✅ moduleManagement | ✅ moduleManagement | ✅ Consistent |
| CreateOps initialization | ❌ Not in constructor | ❌ Not in constructor | ✅ Consistent (design) |

---

## Recommendations Summary

### ✅ Completed (2026-01-23)
1. ✅ **Contract validation** - Added `supportsInterface` checks for all aux contracts
2. ✅ **Immutability** - Made `moduleManagement` immutable in both contracts
3. ✅ **Wiring events** - Added `WiringConfigured` event
4. ✅ **Consistency** - Both contracts use `DEFAULT_YIELD_PROTOCOL_FEE_BPS` constant
5. ✅ **Explicit initialization** - Both contracts explicitly set `appealBondProtocolFeeBps = 0`

### Low Priority (Remaining)
1. **Document** that CreateOps/SettlementOps/BondCollector must be set after deployment
2. **Consider** making `yieldOps` and `disputeOps` immutable (requires BaseEscrow constructor)

---

## Code Quality Improvements

### 1. Consistency
- Both constructors should follow same pattern
- Use constants where possible
- Explicit initialization is clearer than implicit defaults

### 2. Defensive Programming
- Validate contracts have code
- Fail fast in constructor (better than runtime errors)

### 3. Documentation
- Document required post-deployment setup
- Document default values and their meanings

---

## Testing Considerations

### Unit Tests Needed
1. ✅ Constructor with valid inputs (should succeed)
2. ✅ Constructor with invalid escrow fee (should revert)
3. ✅ Constructor with zero addresses (should revert)
4. ✅ Constructor with EOA addresses (should revert - implemented)
5. ✅ Constructor with non-IERC165 contracts (should revert - implemented)
6. ✅ Role assignment (deployer has admin and timelock roles)
7. ✅ Protocol fee initialization (correct defaults)
8. ✅ Timeout config initialization (correct defaults)
9. ✅ WiringConfigured event emission

### Integration Tests Needed
1. ✅ Deployment and immediate use (should work if ops contracts set)
2. ✅ Deployment with EOA addresses (should fail - implemented)
3. ✅ WiringConfigured event verification

---

## Conclusion

**Overall Assessment**: ✅ **MOSTLY SECURE** with minor improvements needed

**Critical Issues**: None found

**Recommendations**:
1. Add contract validation for better error handling
2. Improve consistency between EscrowVault and EscrowableERC20
3. Document post-deployment setup requirements

**No blocking issues found.** Constructors are secure but could be more defensive and consistent.
