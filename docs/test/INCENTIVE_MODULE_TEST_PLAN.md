# Incentive Module Integration Test Plan

**Date**: 2025-01-XX  
**Scope**: Testing all missing integrations implemented for IIncentiveModule  
**Status**: In Progress

---

## Overview

This test plan covers comprehensive testing of the incentive module integrations:

- `onDisputeOpened` hook integration
- `recordAppealBond` integration
- `onDisputeFinalized` hook integration
- `distributeAppealBond` integration
- `distributePayments` interface method
- Rounding error fix in bond distribution
- Bond existence check

---

## Test Categories

### 1. Unit Tests (Simple - Provide Specifications)

#### 1.1 `onDisputeOpened` Hook Tests

**File**: `test/foundry/decentralized-resolution-module/IncentiveModuleHooks.unit.t.sol`

**Test Cases**:

1. **test_onDisputeOpened_CalledOnDisputeRaise**
   - **Setup**: Create escrow, raise dispute
   - **Action**: Call `raiseDispute()`
   - **Verify**:
     - `onDisputeOpened` is called with correct parameters
     - `workflowId` matches
     - `token` matches escrow token
     - `amount` matches original escrow amount (before fee)
     - `escrowFee` matches calculated fee
     - `round` is 0
   - **Helper**: Mock incentive module that tracks calls

2. **test_onDisputeOpened_HandlesMissingIncentiveModule**
   - **Setup**: Resolution module without incentive module set
   - **Action**: Raise dispute
   - **Verify**: No revert, dispute still opens successfully
   - **Note**: Uses try-catch, should not fail

3. **test_onDisputeOpened_HandlesIncentiveModuleRevert**
   - **Setup**: Incentive module that reverts on `onDisputeOpened`
   - **Action**: Raise dispute
   - **Verify**: No revert, dispute still opens (non-critical hook)

4. **test_onDisputeOpened_FeeCalculationCorrect**
   - **Setup**: Escrow with 10% fee, 1000 tokens
   - **Action**: Raise dispute
   - **Verify**:
     - Original amount = 1000 tokens
     - Fee = 100 tokens
     - `onDisputeOpened` called with (1000, 100, 0)

#### 1.2 `recordAppealBond` Tests

**File**: `test/foundry/decentralized-resolution-module/AppealBondRecording.unit.t.sol`

**Test Cases**:

1. **test_recordAppealBond_Success**
   - **Setup**: V2 incentive module, dispute at round 0
   - **Action**: Call `recordAppealBond(workflowId, depositor, amount, token, round)`
   - **Verify**:
     - Bond recorded in `appealBonds[workflowId][round]`
     - `depositor` matches
     - `amount` matches
     - `token` matches
     - `depositedAt` is current timestamp
     - `distributed` is false
     - `totalBondsPosted` incremented
     - `escalationDepthHistogram[round]` incremented
     - Event `AppealBondRecorded` emitted

2. **test_recordAppealBond_PreventDuplicate**
   - **Setup**: Bond already recorded for workflowId/round
   - **Action**: Try to record again
   - **Verify**: Reverts with "Bond already exists"

3. **test_recordAppealBond_InvalidParameters**
   - **Test Cases**:
     - Zero depositor → Revert "Invalid depositor"
     - Zero amount → Revert "Invalid amount"
     - Round 0 → Revert "Invalid round" (bonds only for rounds 1-2)
     - Round > 2 → Revert "Invalid round"
     - Not escrow contract → Revert "Not registered escrow contract"

4. **test_recordAppealBond_ETHBond**
   - **Setup**: Bond token = address(0) (ETH)
   - **Action**: Record bond with ETH
   - **Verify**: Bond recorded, contract receives ETH

5. **test_recordAppealBond_ERC20Bond**
   - **Setup**: Bond token = ERC20 address
   - **Action**: Record bond with ERC20
   - **Verify**: Bond recorded (assumes tokens already in contract)

#### 1.3 `distributeAppealBond` Tests

**File**: `test/foundry/decentralized-resolution-module/AppealBondDistribution.unit.t.sol`

**Test Cases**:

1. **test_distributeAppealBond_AppealSucceeds_Refund**
   - **Setup**:
     - Bond recorded at round 1
     - Decision at round 0: CANCEL
     - Decision at round 1: RELEASE (reversal)
   - **Action**: Call `distributeAppealBond(workflowId, 0, true)`
   - **Verify**:
     - Bond `distributed` = true
     - Bond `refunded` = true
     - `totalBondsRefunded` incremented
     - ETH/ERC20 transferred to depositor
     - Event `AppealBondRefunded` emitted

2. **test_distributeAppealBond_AppealFails_PayToResolvers**
   - **Setup**:
     - Bond recorded at round 1
     - 2 resolvers at round 0
     - Decision at round 0: CANCEL
     - Decision at round 1: CANCEL (same, appeal failed)
   - **Action**: Call `distributeAppealBond(workflowId, 0, false)`
   - **Verify**:
     - Bond `distributed` = true
     - Bond `refunded` = false
     - `totalBondsPaidToResolvers` incremented
     - Both resolvers have claimable payment increased
     - Payment split equally (with remainder handling)
     - Event `AppealBondPaidToResolvers` emitted

3. **test_distributeAppealBond_NoBondRecorded**
   - **Setup**: No bond recorded for workflowId/round
   - **Action**: Call `distributeAppealBond`
   - **Verify**: Reverts with "No bond recorded"

4. **test_distributeAppealBond_AlreadyDistributed**
   - **Setup**: Bond already distributed
   - **Action**: Try to distribute again
   - **Verify**: Reverts with "Bond already distributed"

5. **test_distributeAppealBond_NoResolvers_Forfeit**
   - **Setup**: Bond to distribute but no resolvers at prior round
   - **Action**: Call `distributeAppealBond`
   - **Verify**:
     - Event emitted with empty resolver array
     - Bond marked as distributed but not refunded
     - Bond remains in contract (protocol revenue)

#### 1.4 Rounding Error Fix Tests

**File**: `test/foundry/decentralized-resolution-module/BondRounding.unit.t.sol`

**Test Cases**:

1. **test_BondDistribution_Rounding_3Resolvers_100Wei**
   - **Setup**: 3 resolvers, 100 wei bond
   - **Action**: Distribute bond
   - **Verify**:
     - Total distributed = 100 wei (no loss)
     - Resolver1: 34 wei
     - Resolver2: 33 wei
     - Resolver3: 33 wei
     - Sum = 100 wei

2. **test_BondDistribution_Rounding_5Resolvers_99Wei**
   - **Setup**: 5 resolvers, 99 wei bond
   - **Action**: Distribute bond
   - **Verify**:
     - Total distributed = 99 wei
     - Each resolver gets 19 or 20 wei
     - Sum = 99 wei

3. **test_BondDistribution_EvenDivision**
   - **Setup**: 2 resolvers, 100 wei bond
   - **Action**: Distribute bond
   - **Verify**:
     - Each resolver gets exactly 50 wei
     - No remainder

#### 1.5 `distributePayments` Interface Method Tests

**File**: `test/foundry/decentralized-resolution-module/DistributePaymentsInterface.unit.t.sol`

**Test Cases**:

1. **test_distributePayments_V1_DelegatesToOnDisputeResolved**
   - **Setup**: V1 module, resolver and fees recorded
   - **Action**: Call `distributePayments(workflowId, token, totalFees)`
   - **Verify**:
     - `onDisputeResolved` is called internally
     - Payments calculated
     - `totalFees` parameter is ignored (fees already recorded)

2. **test_distributePayments_V2_DelegatesToOnDisputeResolved**
   - **Setup**: V2 module, resolver and fees recorded
   - **Action**: Call `distributePayments(workflowId, token, totalFees)`
   - **Verify**: Same as V1 test

3. **test_distributePayments_OnlyEscrowContract**
   - **Setup**: Non-escrow contract caller
   - **Action**: Call `distributePayments`
   - **Verify**: Reverts with "Not registered escrow contract"

---

### 2. Integration Tests (Complex - Written)

**File**: `test/foundry/decentralized-resolution-module/IncentiveModuleIntegration.test.t.sol`

**Status**: ✅ **WRITTEN** - See file for complete implementation

**Coverage**:

- ✅ `onDisputeOpened` integration with full escrow flow
- ✅ `recordAppealBond` integration with escalation
- ✅ `distributeAppealBond` on appeal success (reversal)
- ✅ `distributeAppealBond` on appeal failure (decision upheld)
- ✅ Rounding error fix verification
- ✅ `distributePayments` interface method

---

### 3. Edge Case Tests (Medium Complexity - Provide Specifications)

#### 3.1 Multiple Escalations

**File**: `test/foundry/decentralized-resolution-module/MultipleEscalations.test.t.sol`

**Test Cases**:

1. **test_MultipleEscalations_MultipleBonds**
   - **Setup**:
     - Dispute at round 0
     - Escalate to round 1 (bond recorded)
     - Escalate to round 2 (bond recorded)
   - **Verify**:
     - Two bonds recorded (round 1 and round 2)
     - Both bonds can be distributed independently
     - Final decision determines both bond outcomes

2. **test_MultipleEscalations_BondDistributionOrder**
   - **Setup**: Bonds at rounds 1 and 2
   - **Action**: Finalize dispute
   - **Verify**: Bonds distributed in correct order (round 0 → round 1 → round 2)

#### 3.2 Finalization Tests

**File**: `test/foundry/decentralized-resolution-module/DisputeFinalization.test.t.sol`

**Test Cases**:

1. **test_finalizeDispute_CallsOnDisputeFinalized**
   - **Setup**: Dispute with decision, appeal window expired
   - **Action**: Call `finalizeDispute(workflowId)`
   - **Verify**:
     - `onDisputeFinalized` called with correct parameters
     - `finalRound` matches current round
     - `finalDecision` matches decision at final round
     - Status set to `Final`

2. **test_finalizeDispute_DistributesAllBonds**
   - **Setup**:
     - Bonds at rounds 1 and 2
     - Final decision at round 2
   - **Action**: Finalize dispute
   - **Verify**: All bonds distributed based on outcomes

3. **test_finalizeDispute_CannotFinalizeBeforeAppealWindow**
   - **Setup**: Decision made, appeal window not expired
   - **Action**: Try to finalize
   - **Verify**: Reverts with "Cannot finalize yet"

4. **test_finalizeDispute_FinalRound_ImmediateFinalization**
   - **Setup**: Decision at round 2 (MAX_ROUND)
   - **Action**: Finalize immediately
   - **Verify**: Can finalize without waiting (no appeal possible)

#### 3.3 Error Handling Tests

**File**: `test/foundry/decentralized-resolution-module/IncentiveModuleErrorHandling.test.t.sol`

**Test Cases**:

1. **test_HookFailures_NonCritical**
   - **Setup**: Incentive module that reverts on hooks
   - **Actions**:
     - Raise dispute
     - Escalate
     - Finalize
   - **Verify**: All operations succeed despite hook failures

2. **test_MissingIncentiveModule_GracefulDegradation**
   - **Setup**: Resolution module without incentive module
   - **Actions**: Full dispute flow
   - **Verify**: All operations succeed, no reverts

---

### 4. Gas Optimization Tests (Simple - Provide Specifications)

**File**: `test/foundry/decentralized-resolution-module/IncentiveModuleGas.test.t.sol`

**Test Cases**:

1. **test_Gas_OnDisputeOpened**
   - **Measure**: Gas cost of `raiseDispute` with/without incentive module
   - **Verify**: Overhead is reasonable (< 50k gas)

2. **test_Gas_EscalationWithBond**
   - **Measure**: Gas cost of escalation with bond recording
   - **Verify**: Bond recording adds reasonable overhead

---

### 5. Fuzz Tests (Medium Complexity - Provide Specifications)

**File**: `test/foundry/decentralized-resolution-module/IncentiveModuleFuzz.test.t.sol`

**Test Cases**:

1. **testFuzz_BondDistribution_NoLoss(uint256 bondAmount, uint8 resolverCount)**
   - **Constraints**:
     - `bondAmount`: 1 to 1000 ether
     - `resolverCount`: 1 to 10
   - **Verify**: Total distributed always equals `bondAmount` (no rounding loss)

2. **testFuzz_AppealBond_RoundValidation(uint8 round)**
   - **Constraints**: `round`: 0 to 10
   - **Verify**: Only rounds 1-2 are valid, others revert

3. **testFuzz_MultipleBonds_Consistency(uint256 bond1, uint256 bond2)**
   - **Setup**: Two escalations with different bond amounts
   - **Verify**: Both bonds distributed correctly, no interference

---

## Test Implementation Priority

### High Priority (Must Have)

1. ✅ Integration tests (written)
2. Unit tests for `recordAppealBond` (specifications provided)
3. Unit tests for `distributeAppealBond` (specifications provided)
4. Rounding error tests (specifications provided)

### Medium Priority (Should Have)

5. `onDisputeOpened` unit tests (specifications provided)
6. Finalization tests (specifications provided)
7. Multiple escalations tests (specifications provided)

### Low Priority (Nice to Have)

8. Gas optimization tests (specifications provided)
9. Fuzz tests (specifications provided)
10. Error handling edge cases (specifications provided)

---

## Test Data Setup

### Common Setup Pattern

```solidity
function setUp() public {
  // Deploy contracts
  token = new ERC20Mock();
  paymentLib = new PaymentCalculationLibraryV1();
  incentiveModuleV1 = new ResolverIncentiveModuleV1(deployer, address(paymentLib));
  incentiveModuleV2 = new ResolverIncentiveModuleV2(deployer, address(paymentLib));
  resolutionModule = new DecentralizedResolutionModule(deployer);
  escrow = new EscrowVault();

  // Setup roles and registrations
  // Appoint resolvers
  // Configure modules
}
```

### Test Users

- `deployer`: Contract deployer, has admin roles
- `timelock`: Has ROLE_TIMELOCK for governance
- `resolver1`, `resolver2`: Standard resolvers
- `seniorResolver`: Senior resolver
- `user1`, `user2`: Escrow participants

---

## Assertion Patterns

### Verify Hook Called

```solidity
// Use mock incentive module that tracks calls
MockIncentiveModule mock = new MockIncentiveModule();
// ... setup ...
assertTrue(mock.onDisputeOpenedCalled(workflowId), "Hook should be called");
```

### Verify Bond Recorded

```solidity
AppealBondRecord memory bond = incentiveModuleV2.getAppealBond(workflowId, round);
assertEq(bond.amount, expectedAmount, "Bond amount should match");
assertEq(bond.depositor, expectedDepositor, "Depositor should match");
```

### Verify Payment Distribution

```solidity
uint256 claimable = incentiveModule.getClaimablePayment(workflowId, resolver);
assertEq(claimable, expectedAmount, "Claimable should match");
```

### Verify No Rounding Loss

```solidity
uint256 total = claimable1 + claimable2 + claimable3;
assertEq(total, bondAmount, "Total should equal bond amount");
```

---

## Mock Contracts Needed

### MockIncentiveModule

```solidity
contract MockIncentiveModule is IIncentiveModule {
    mapping(uint256 => bool) public onDisputeOpenedCalled;
    mapping(uint256 => AppealBondRecord) public bonds;

    function onDisputeOpened(...) external override {
        onDisputeOpenedCalled[workflowId] = true;
        // Store parameters for verification
    }

    // Implement other interface methods as no-ops or with tracking
}
```

---

## Coverage Goals

- **Line Coverage**: > 95% for incentive module contracts
- **Branch Coverage**: > 90% for all conditional logic
- **Function Coverage**: 100% for all public/external functions
- **Integration Coverage**: All integration points tested

---

## Known Test Gaps

1. **ETH Bond Handling**: Tests assume ETH is already in contract, may need to test transfer flow
2. **ERC20 Bond Approval**: Tests don't cover user approval flow for ERC20 bonds
3. **Concurrent Disputes**: Tests don't cover multiple disputes with bonds simultaneously
4. **Gas Limit Edge Cases**: Very large bond amounts or many resolvers

---

## Test Execution

### Run All Tests

```bash
forge test --match-path "**/IncentiveModule*.t.sol" -vvv
```

### Run Specific Category

```bash
# Integration tests
forge test --match-path "**/IncentiveModuleIntegration.test.t.sol" -vvv

# Unit tests
forge test --match-path "**/IncentiveModuleHooks.unit.t.sol" -vvv
```

### Coverage Report

```bash
forge coverage --match-path "**/IncentiveModule*.sol"
```

---

## Notes for Test Writers

1. **Use Foundry's `vm.prank`** for access control testing
2. **Use `vm.deal`** for ETH balance setup
3. **Use `vm.warp`** for time-based tests (appeal windows)
4. **Mock contracts** should implement full interface for realistic testing
5. **Event verification** using Foundry's event matching
6. **Gas snapshots** for optimization tests

---

**End of Test Plan**
