# Incentive Module Test Implementation Task

**Status**: Ready for Implementation  
**Priority**: High  
**Assigned To**: Claude Haiku  
**Estimated Effort**: 2-3 hours

---

## Overview

Implement the missing unit tests specified in `INCENTIVE_MODULE_TEST_PLAN.md`. Integration tests are already written, but unit tests for individual functions are missing.

---

## Test Files to Create

### 1. `test/foundry/decentralized-resolution-module/IncentiveModuleHooks.unit.t.sol`

**Status**: Not created  
**Priority**: High

**Test Cases** (from plan):
1. `test_onDisputeOpened_CalledOnDisputeRaise` - Verify hook is called with correct parameters
2. `test_onDisputeOpened_HandlesMissingIncentiveModule` - Graceful degradation
3. `test_onDisputeOpened_HandlesIncentiveModuleRevert` - Non-critical hook failure
4. `test_onDisputeOpened_FeeCalculationCorrect` - Verify fee calculation

**Setup Pattern**:
```solidity
contract IncentiveModuleHooksTest is Test {
    EscrowVault public escrow;
    DecentralizedResolutionModule public resolutionModule;
    ResolverIncentiveModuleV1 public incentiveModule;
    ERC20Mock public token;
    
    function setUp() public {
        // Deploy contracts
        // Setup roles
        // Appoint resolvers
        // Configure modules
    }
}
```

---

### 2. `test/foundry/decentralized-resolution-module/AppealBondRecording.unit.t.sol`

**Status**: ✅ **EXISTS** - Verify completeness against plan  
**Priority**: High

**Test Cases** (from plan):
1. `test_recordAppealBond_Success` - Verify bond recording
2. `test_recordAppealBond_PreventDuplicate` - Prevent duplicate bonds
3. `test_recordAppealBond_InvalidParameters` - Parameter validation
4. `test_recordAppealBond_ETHBond` - ETH bond handling
5. `test_recordAppealBond_ERC20Bond` - ERC20 bond handling

**Key Assertions**:
- Bond recorded in `appealBonds[workflowId][round]`
- `totalBondsPosted` incremented
- `escalationDepthHistogram[round]` incremented
- Event `AppealBondRecorded` emitted

---

### 3. `test/foundry/decentralized-resolution-module/AppealBondDistribution.unit.t.sol`

**Status**: Partially exists (check if complete)  
**Priority**: High

**Test Cases** (from plan):
1. `test_distributeAppealBond_AppealSucceeds_Refund` - Refund on reversal
2. `test_distributeAppealBond_AppealFails_PayToResolvers` - Pay resolvers on upheld decision
3. `test_distributeAppealBond_NoBondRecorded` - Error handling
4. `test_distributeAppealBond_AlreadyDistributed` - Prevent double distribution
5. `test_distributeAppealBond_NoResolvers_Forfeit` - No resolvers case

**Key Assertions**:
- Bond `distributed` flag set
- `refunded` flag correct
- Metrics incremented correctly
- Transfers executed correctly

---

### 4. `test/foundry/decentralized-resolution-module/BondRounding.unit.t.sol`

**Status**: ✅ **EXISTS** - Verify completeness against plan  
**Priority**: Medium

**Test Cases** (from plan):
1. `test_BondDistribution_Rounding_3Resolvers_100Wei` - 3 resolvers, 100 wei
2. `test_BondDistribution_Rounding_5Resolvers_99Wei` - 5 resolvers, 99 wei
3. `test_BondDistribution_EvenDivision` - Even division case

**Key Assertion**: Total distributed always equals bond amount (no rounding loss)

---

### 5. `test/foundry/decentralized-resolution-module/DistributePaymentsInterface.unit.t.sol`

**Status**: Not created  
**Priority**: Medium

**Test Cases** (from plan):
1. `test_distributePayments_V1_DelegatesToOnDisputeResolved` - V1 delegation
2. `test_distributePayments_V2_DelegatesToOnDisputeResolved` - V2 delegation
3. `test_distributePayments_OnlyEscrowContract` - Access control

---

## Implementation Guidelines

### 1. Use Foundry Best Practices

- Use `vm.prank()` for access control
- Use `vm.deal()` for ETH balances
- Use `vm.warp()` for time-based tests
- Use `vm.expectRevert()` for error cases
- Use `vm.expectEmit()` for event verification

### 2. Common Setup Pattern

```solidity
function setUp() public {
    deployer = address(this);
    timelock = makeAddr('timelock');
    resolver1 = makeAddr('resolver1');
    user1 = makeAddr('user1');
    
    // Deploy contracts
    token = new ERC20Mock('Test Token', 'TEST', address(this), 0);
    paymentLib = new PaymentCalculationLibraryV1();
    incentiveModule = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
    resolutionModule = new DecentralizedResolutionModule(deployer);
    
    // Setup roles
    bytes32 ROLE_TIMELOCK = resolutionModule.ROLE_TIMELOCK();
    resolutionModule.grantRole(ROLE_TIMELOCK, timelock);
    
    // Register contracts
    vm.prank(timelock);
    resolutionModule.registerEscrowContract(address(escrow));
    resolutionModule.setIncentiveModule(address(incentiveModule));
    
    // Appoint resolvers
    // Configure escalation cost config
}
```

### 3. Mock Contracts

Create `test/foundry/decentralized-resolution-module/mocks/MockIncentiveModule.sol`:

```solidity
contract MockIncentiveModule is IIncentiveModule {
    mapping(uint256 => bool) public onDisputeOpenedCalled;
    mapping(uint256 => uint256) public escrowFeeRecorded;
    
    function onDisputeOpened(...) external override {
        onDisputeOpenedCalled[workflowId] = true;
        escrowFeeRecorded[workflowId] = escrowFee;
    }
    
    // Implement other interface methods as no-ops
}
```

### 4. Test Organization

- Group related tests in `describe` blocks (if using foundry-std)
- Use descriptive test names
- Add comments for complex test logic
- Follow existing test patterns from `IncentiveModuleIntegration.test.t.sol`

---

## Verification Checklist

After implementation, verify:

- [ ] All tests compile without errors
- [ ] All tests pass (`forge test`)
- [ ] Test coverage > 95% for incentive module functions
- [ ] All error cases tested
- [ ] All events verified
- [ ] Gas snapshots reasonable
- [ ] No duplicate test logic

---

## Reference Files

- **Test Plan**: `docs/test/INCENTIVE_MODULE_TEST_PLAN.md`
- **Existing Integration Tests**: `test/foundry/decentralized-resolution-module/IncentiveModuleIntegration.test.t.sol`
- **Contract Under Test**: `contracts/decentralized-resolution-module/ResolverIncentiveModuleV2.sol`
- **Interface**: `contracts/decentralized-resolution-module/IIncentiveModule.sol`

---

## Notes

1. Integration tests already exist and pass - use them as reference
2. Focus on unit tests for individual functions
3. Mock contracts can simplify testing
4. Follow existing test patterns in the codebase
5. Ensure all edge cases from the plan are covered

---

**End of Task**
