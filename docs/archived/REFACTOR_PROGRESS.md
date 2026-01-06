# Aave Module Refactor Progress

## Status: 🟡 IN PROGRESS

### ✅ Completed

1. **AaveYieldModule Created** - `packages/hardhat/contracts/modules/AaveYieldModule.sol`
   - All Aave logic moved to module
   - Implements `IYieldModule` interface
   - Handles deposits, withdrawals, yield calculation
   - Configuration functions included

2. **Core Aave Functions Refactored** in BaseEscrow:
   - ✅ `_depositToAave()` - Now calls `IYieldModule.depositForYield()`
   - ✅ `_withdrawFromAave()` - Now calls `IYieldModule.withdrawWithYield()`
   - ✅ `_withdrawFromAaveProportional()` - Now calls `IYieldModule.withdrawProportional()`
   - ✅ `_calculateYield()` - Now calls `IYieldModule.calculateYield()`

3. **Aave Configuration Functions Removed** from BaseEscrow
   - Functions moved to AaveYieldModule
   - Note added directing users to use module functions

4. **Core Release/Cancel Functions Updated**:
   - ✅ `_releaseEscrowTransfer()` - Uses yield module
   - ✅ `_cancelAndRefund()` - Uses yield module

### 🟡 In Progress

1. **Resolver Functions** - Need to remove Aave state checks:
   - `resolverRelease()` - Line 670
   - `resolverPartialRelease()` - Lines 726, 742, 754
   - `resolverPartialCancel()` - Lines 819, 839, 851
   - `resolve()` - Lines 1903-1927

2. **View Functions** - Need to query yield module:
   - `isEscrowInAave()` - Line 1183
   - `getEscrowATokenBalance()` - Line 1193
   - `getEscrowOriginalDeposit()` - Line 1203

### ❌ Remaining

1. **Remove Aave State Variables** from BaseEscrow:
   - `IPoolAddressesProvider public aavePoolAddressesProvider;` (line 188)
   - `IPool public aavePool;` (line 189)
   - `bool public aaveEnabled;` (line 190)
   - `mapping(address => uint256) public totalDepositedToAave;` (line 193)
   - `mapping(address => address) public tokenToAToken;` (line 194)
   - `mapping(uint256 => bool) public escrowInAave;` (line 200)
   - `mapping(uint256 => uint256) public escrowATokenBalance;` (line 201)
   - `mapping(uint256 => uint256) public escrowOriginalDeposit;` (line 202)

2. **Remove Aave Interfaces** from BaseEscrow (now in AaveYieldModule):
   - `IPoolAddressesProvider` interface (lines 20-22)
   - `IPool` interface (lines 24-28)
   - `IAToken` interface (lines 30-33)
   - `DataTypes` library (lines 35-57)

3. **Remove Aave Events** from BaseEscrow (now in AaveYieldModule):
   - `EscrowDepositedToAave` (line 249)
   - `EscrowWithdrawnFromAave` (line 250)
   - `AaveWithdrawalFailedEvent` (line 251)

4. **Update Tests** - All tests need to be updated to use AaveYieldModule

5. **Update Deployment Scripts** - Deploy AaveYieldModule and set as default

---

## Next Steps

1. Update resolver functions to remove `escrowInAave` checks
2. Update view functions to query yield module
3. Remove Aave state variables
4. Remove Aave interfaces/types
5. Remove Aave events
6. Test compilation
7. Update tests

---

**Estimated Remaining Work**: 2-3 hours


