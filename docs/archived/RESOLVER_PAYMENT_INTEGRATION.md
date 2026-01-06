# Resolver Payment System Integration Guide

**Date**: 2025-01-XX  
**Status**: Integration Guide  
**Module**: ResolverIncentiveModule

---

## Overview

The `ResolverIncentiveModule` provides a functional/hybrid approach to resolver payments with governance-controlled library upgrades. This guide explains how to integrate it with escrow contracts.

---

## Architecture

```
BaseEscrow / EscrowVault
    │
    ├─> DecentralizedResolutionModule (resolver assignment)
    │
    └─> ResolverIncentiveModule (payment tracking & distribution)
            │
            └─> PaymentCalculationLibraryV1 (payment calculations)
```

---

## Integration Steps

### 1. Deploy Contracts

**Deploy Payment Calculation Library**:
```solidity
PaymentCalculationLibraryV1 paymentLib = new PaymentCalculationLibraryV1();
```

**Deploy Resolver Incentive Module**:
```solidity
ResolverIncentiveModule incentiveModule = new ResolverIncentiveModule(
    owner,              // Initial owner (gets DEFAULT_ADMIN_ROLE and ROLE_TIMELOCK)
    address(paymentLib) // Initial payment calculation library
);
```

**Register Escrow Contract**:
```solidity
incentiveModule.registerEscrowContract(address(escrowContract));
```

---

### 2. Integrate with Escrow Contract

Add incentive module reference to your escrow contract:

```solidity
import "../modules/ResolverIncentiveModule.sol";

contract BaseEscrow {
    ResolverIncentiveModule public incentiveModule;
    
    function setIncentiveModule(address _incentiveModule) external onlyRole(ROLE_TIMELOCK) {
        incentiveModule = ResolverIncentiveModule(_incentiveModule);
    }
}
```

---

### 3. Hook Integration Points

#### A. When Dispute is Opened (`raiseDispute`)

**Record resolver and escrow fee**:

```solidity
function raiseDispute(uint256 workflowId) public returns (bool) {
    // ... existing dispute logic ...
    
    // After dispute is opened, record in incentive module
    if (address(incentiveModule) != address(0)) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Record resolver (level 0 = initial resolver)
        try incentiveModule.recordResolver(
            workflowId,
            et.disputeResolver,
            0 // Level 0 = initial resolver
        ) {} catch {
            // Incentive module call failed, continue anyway
        }
        
        // Record escrow fee (calculate from original amount)
        uint256 escrowFee = calculateEscrowFee(et.totalDeposited);
        if (escrowFee > 0) {
            try incentiveModule.recordEscrowFee(
                workflowId,
                et.token,
                escrowFee
            ) {} catch {
                // Incentive module call failed, continue anyway
            }
        }
    }
    
    return true;
}
```

#### B. When Dispute is Escalated (`escalateDispute`)

**Record escalation fee and new resolver**:

```solidity
function escalateDispute(uint256 workflowId) external payable returns (bool) {
    // ... existing escalation logic ...
    
    // After escalation, record in incentive module
    if (address(incentiveModule) != address(0)) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        // Get new escalation level from module
        bytes memory escrowData = _encodeResolutionData(...);
        (, uint8 newLevel) = IResolutionModule(resolutionModule).getResolver(
            workflowId,
            escrowData
        );
        
        // Record new resolver at escalated level
        try incentiveModule.recordResolver(
            workflowId,
            et.disputeResolver, // New resolver after escalation
            newLevel
        ) {} catch {
            // Incentive module call failed, continue anyway
        }
        
        // Record escalation fee (in ERC20 token, not ETH)
        // Note: Escalation fees should be in ERC20 tokens (same as escrow)
        // If you're collecting ETH, convert to token amount
        uint256 escalationFee = getEscalationFee(workflowId, newLevel);
        if (escalationFee > 0) {
            try incentiveModule.recordEscalationFee(
                workflowId,
                et.token,
                escalationFee
            ) {} catch {
                // Incentive module call failed, continue anyway
            }
        }
    }
    
    return true;
}
```

#### C. When Dispute is Resolved (`resolverRelease`, `resolverCancel`, etc.)

**Calculate and distribute payments**:

```solidity
function resolverRelease(uint256 workflowId) public nonReentrant returns (bool) {
    // ... existing resolution logic ...
    
    // After resolution, distribute payments
    if (address(incentiveModule) != address(0)) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        
        try incentiveModule.onDisputeResolved(
            workflowId,
            et.token
        ) {} catch {
            // Incentive module call failed, continue anyway
            // Payments will not be distributed, but resolution still succeeds
        }
    }
    
    return true;
}
```

**Important**: Ensure the escrow contract has sufficient token balance to pay resolvers. The incentive module will transfer tokens directly to resolvers.

---

## Payment Flow

### Example: Dispute with Escalation

1. **Dispute Opened**:
   - Escrow fee: 100 USDC (1% of 10,000 USDC)
   - Resolver A (level 0) assigned
   - `recordResolver(workflowId, resolverA, 0)`
   - `recordEscrowFee(workflowId, USDC, 100)`

2. **Dispute Escalated**:
   - Escalation fee: 50 USDC
   - Resolver B (level 1) assigned
   - `recordResolver(workflowId, resolverB, 1)`
   - `recordEscalationFee(workflowId, USDC, 50)`

3. **Dispute Resolved**:
   - Total fees: 150 USDC (100 escrow + 50 escalation)
   - Resolver share: 75 USDC (50% of 150)
   - Distribution:
     - Resolver A (level 0, weight 1.0): 30 USDC
     - Resolver B (level 1, weight 1.5): 45 USDC
   - `onDisputeResolved(workflowId, USDC)`

---

## Configuration

### Resolver Share Percentage

**Default**: 50% (5000 basis points)

**Change via Governance**:
```solidity
// Queue change (7-day delay)
incentiveModule.queueResolverSharePercentage(6000); // 60%

// Activate after 7 days
incentiveModule.activateResolverSharePercentage();
```

### Level Weights

**Default**:
- Level 0 (standard): 1.0x (10000)
- Level 1 (senior): 1.5x (15000)
- Level 2 (external): 2.0x (20000)

**Change via Governance**:
```solidity
Weights memory newWeights = Weights({
    level0: 10000,
    level1: 20000, // Increase senior resolver weight
    level2: 30000  // Increase external resolver weight
});

// Queue change (7-day delay)
incentiveModule.queueWeights(newWeights);

// Activate after 7 days
incentiveModule.activateWeights();
```

### Payment Calculation Library

**Upgrade via Governance**:
```solidity
// Deploy new library
PaymentCalculationLibraryV2 newLib = new PaymentCalculationLibraryV2();

// Queue upgrade (7-day delay)
incentiveModule.queuePaymentCalculationLibrary(address(newLib));

// Activate after 7 days
incentiveModule.activatePaymentCalculationLibrary();
```

---

## Token Requirements

### Escrow Contract Must Hold Tokens

The escrow contract must have sufficient token balance to pay resolvers. The incentive module transfers tokens directly from the escrow contract.

**Options**:

1. **Deduct from Escrow Fees**:
   - Collect fees in escrow contract
   - Escrow contract holds fees
   - Incentive module transfers from escrow contract

2. **Separate Fee Pool**:
   - Collect fees in separate contract
   - Transfer fees to incentive module
   - Incentive module holds and distributes

3. **Direct Transfer**:
   - When resolving, transfer resolver share to incentive module
   - Incentive module distributes immediately

**Recommended**: Option 1 (deduct from escrow fees)

---

## Error Handling

All incentive module calls should use try-catch to prevent reverting the main escrow flow:

```solidity
try incentiveModule.recordResolver(...) {} catch {
    // Log error, continue
}
```

**Rationale**:
- Payment tracking is important but not critical
- Escrow resolution should succeed even if payment tracking fails
- Payments can be distributed manually if needed

---

## View Functions

### Check Resolver Payments

```solidity
// Get resolvers for a dispute
ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(workflowId);

// Get fees for a dispute
(uint256 escrowFee, uint256 escalationFees) = incentiveModule.getDisputeFees(workflowId);

// Check if payments distributed
bool distributed = incentiveModule.arePaymentsDistributed(workflowId);
```

### Check Pending Governance Changes

```solidity
// Pending library upgrade
(address newLib, uint64 eta, bool exists) = incentiveModule.getPendingPaymentLibrary();

// Pending share percentage change
(uint256 newPct, uint64 eta, bool exists) = incentiveModule.getPendingResolverSharePercentage();

// Pending weights change
(Weights memory newWeights, uint64 eta, bool exists) = incentiveModule.getPendingWeights();
```

---

## Testing

### Unit Tests

Test payment calculations:
```solidity
function testPaymentCalculation() public {
    PaymentInput memory input = createTestInput();
    PaymentOutput memory output = PaymentCalculationLibraryV1.calculatePayments(input);
    
    assertEq(output.totalResolverShare, expectedShare);
    assertEq(output.payments.length, 2);
}
```

### Integration Tests

Test full flow:
```solidity
function testDisputeWithPayment() public {
    // Create escrow
    uint256 workflowId = createEscrow(...);
    
    // Raise dispute
    escrow.raiseDispute(workflowId);
    
    // Check resolver recorded
    ResolverRecord[] memory resolvers = incentiveModule.getDisputeResolvers(workflowId);
    assertEq(resolvers.length, 1);
    
    // Resolve dispute
    escrow.resolverRelease(workflowId);
    
    // Check payments distributed
    assertTrue(incentiveModule.arePaymentsDistributed(workflowId));
}
```

---

## Security Considerations

### Access Control

- Only registered escrow contracts can call incentive functions
- Governance functions require `ROLE_TIMELOCK`
- Library upgrades have 7-day delay

### Payment Validation

- Library validates input (no negative payments)
- Payments sum to resolver share (with rounding tolerance)
- Zero-address resolvers are skipped

### Reentrancy Protection

- `onDisputeResolved` uses `nonReentrant` modifier
- State updated before external calls
- Follows checks-effects-interactions pattern

---

## Troubleshooting

### Payments Not Distributed

**Check**:
1. Is incentive module registered?
2. Does escrow contract have sufficient token balance?
3. Are payments already distributed? (`arePaymentsDistributed`)
4. Are there resolvers recorded? (`getDisputeResolvers`)

### Library Upgrade Failed

**Check**:
1. Is library valid? (`validateLibrary`)
2. Has 7-day delay elapsed? (`getPendingPaymentLibrary`)
3. Does library implement interface? (`IPaymentCalculationLibrary`)

### Incorrect Payment Amounts

**Check**:
1. Are fees recorded correctly? (`getDisputeFees`)
2. Are resolvers recorded correctly? (`getDisputeResolvers`)
3. What is current share percentage? (`resolverSharePercentage`)
4. What are current weights? (`weights`)

---

## Future Enhancements

### V2: Quality Multipliers

Add quality scores to payment calculation:
```solidity
struct PaymentInput {
    // ... existing fields ...
    QualityScore[] qualityScores; // New field
}
```

### V3: Staking Bonuses

Add staking information:
```solidity
struct PaymentInput {
    // ... existing fields ...
    StakingInfo[] stakingInfo; // New field
}
```

Libraries can ignore unknown fields (extensible input design).

---

## Summary

The `ResolverIncentiveModule` provides:
- ✅ Functional payment calculations (pure functions)
- ✅ Governance-controlled library upgrades
- ✅ Extensible input design (backward compatible)
- ✅ Version detection
- ✅ Automatic payment distribution

Integration requires:
1. Deploy module and library
2. Register escrow contract
3. Add hooks in escrow contract (dispute opened, escalated, resolved)
4. Ensure token balance for payments

For questions or issues, refer to the main design document: `RESOLVER_PAYMENT_FUNCTIONAL_GOVERNANCE_DESIGN.md`

