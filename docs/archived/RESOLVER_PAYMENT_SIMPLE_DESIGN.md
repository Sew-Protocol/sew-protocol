# Simple Resolver Payment Design: 50% Fee Split

**Date**: 2025-01-XX  
**Status**: Design Proposal  
**Approach**: Simplest possible implementation

---

## Executive Summary

This document proposes the simplest resolver payment system:
- **Resolvers receive 50% of all fees** (escrow fees + escalation fees)
- **All resolvers involved in a dispute are paid** (if escalated, each resolver gets their share)
- **Payment happens when dispute is resolved** (immediate distribution)

**Key Principles**:
- Simple to implement and understand
- Fair compensation for all work done
- No complex quality metrics or staking
- Easy to audit and verify

---

## Fee Sources

### 1. Escrow Fees
- **Source**: Fees collected when escrows are created
- **Amount**: `amount * escrowFee / ESCROW_FEE_DENOMINATOR`
- **Current Storage**: `totalFees` (EscrowableERC20) or `totalFeesPerToken[token]` (EscrowVault)
- **Distribution**: 50% to resolvers, 50% to protocol

### 2. Escalation Fees
- **Source**: ERC20 tokens (same token as escrow) paid when disputes are escalated
- **Amount**: Configured per escalation level in `DecentralizedResolutionModule`
- **Rationale**: Buyers prefer using only one currency in a single transaction
- **Current Flow**: Paid to `escrowFeeAddress`
- **Distribution**: 50% to resolvers, 50% to protocol

---

## Payment Model

### Basic Case: Single Resolver (No Escalation)

**Scenario**: Dispute raised, resolved by initial resolver, no escalation

**Payment**:
- Resolver receives: **50% of escrow fee** for that escrow
- Protocol receives: **50% of escrow fee**

**Example**:
- Escrow amount: 2,000 USDC
- Escrow fee: 1% (100 bps)
- Escrow fee collected: 20 USDC
- Resolver payment: 10 USDC
- Protocol fee: 10 USDC

### Escalation Case: Multiple Resolvers

**Scenario**: Dispute escalated through multiple levels

**Payment Rules**:
1. **Each resolver involved gets paid** for their work
2. **Payment split equally** among all resolvers who worked on the dispute
3. **Total payment = 50% of (escrow fee + all escalation fees)**

**Example**:
- Escrow fee: 20 USDC
- Escalation fee (level 0→1): 5 USDC
- Escalation fee (level 1→2): 10 USDC
- Total fees: 35 USDC
- Resolver share: 17.5 USDC (50% of 35 USDC)

**Distribution**:
- Resolver 1 (initial): 17.5 USDC / 3 = 5.83 USDC
- Resolver 2 (senior): 17.5 USDC / 3 = 5.83 USDC
- Resolver 3 (final): 17.5 USDC / 3 = 5.83 USDC
- Protocol: 17.5 USDC

**Alternative Distribution (Recommended)**:
- **Weighted by level**: Higher level resolvers get more (e.g., 1x, 1.5x, 2x)
  - Level 0 (initial resolver): 1x weight
  - Level 1 (senior resolver): 1.5x weight
  - Level 2 (external resolver): 2x weight

---

## Implementation Design

### 1. Resolver Tracking

**Track all resolvers who worked on a dispute**:

```solidity
struct ResolverPayment {
    address resolver;
    uint8 level;           // Escalation level (0, 1, 2)
    uint256 timestamp;    // When they were assigned
    bool resolved;         // Did they resolve it?
}

mapping(uint256 => ResolverPayment[]) public disputeResolvers;
```

**When to record**:
- When dispute is raised → Record initial resolver
- When dispute is escalated → Record new resolver
- When dispute is resolved → Mark resolving resolver

### 2. Fee Calculation

**On Resolution**:

```solidity
function calculateResolverPayments(uint256 workflowId) internal view returns (
    uint256 totalResolverShare,
    ResolverPayment[] memory resolvers,
    uint256[] memory payments
) {
    // Get escrow fee for this escrow
    uint256 escrowFeeAmount = getEscrowFeeForEscrow(workflowId);
    
    // Get all escalation fees paid
    uint256 totalEscalationFees = getEscalationFeesForDispute(workflowId);
    
    // Total fees
    uint256 totalFees = escrowFeeAmount + totalEscalationFees;
    
    // Resolver share (50%)
    totalResolverShare = totalFees / 2;
    
    // Get all resolvers who worked on this dispute
    resolvers = disputeResolvers[workflowId];
    
    // Calculate payments (equal split)
    uint256 resolverCount = resolvers.length;
    payments = new uint256[](resolverCount);
    
    for (uint256 i = 0; i < resolverCount; i++) {
        payments[i] = totalResolverShare / resolverCount;
    }
    
    return (totalResolverShare, resolvers, payments);
}
```

### 3. Payment Distribution

**On Resolution**:

```solidity
function distributeResolverPayments(uint256 workflowId) internal {
    (uint256 totalShare, ResolverPayment[] memory resolvers, uint256[] memory payments) = 
        calculateResolverPayments(workflowId);
    
    // Distribute to each resolver
    for (uint256 i = 0; i < resolvers.length; i++) {
        address resolver = resolvers[i].resolver;
        uint256 payment = payments[i];
        
        // Transfer payment in escrow's token (both escrow fees and escalation fees use same token)
        _transferResolverPayment(resolver, payment, workflowId);
        
        emit ResolverPaid(workflowId, resolver, payment, resolvers[i].level);
    }
    
    // Remaining 50% stays in protocol (already in totalFees)
}
```

### 4. Payment Method

**Selected: Immediate Transfer**
- Transfer payment immediately when dispute is resolved
- Pros: Simple, resolvers get paid right away, no need to claim
- Cons: Requires contract to hold funds, gas costs per payment
- **Implementation**: All payments distributed atomically during resolution

### 5. Multi-Token Support

**Unified Token Approach**:
- Both escrow fees and escalation fees use the same ERC20 token as the escrow
- Simplifies payment distribution (single token type per dispute)
- Better UX: Users only need to approve/transfer one token type

**Implementation**:
- Escalation fees paid in same token as escrow (not ETH)
- All payments distributed in the escrow's token
- Track payments per token: `mapping(address => mapping(address => uint256)) public resolverTokenBalance; // resolver => token => balance`

**Example**:
- Escrow in USDC → Escrow fee in USDC → Escalation fees in USDC → Resolver payments in USDC

---

## Data Structures

### New State Variables

**In BaseEscrow**:
```solidity
// Track resolver payments per dispute
mapping(uint256 => address[]) public disputeResolvers; // All resolvers who worked on dispute
mapping(uint256 => mapping(address => uint8)) public resolverLevel; // Resolver's escalation level
mapping(uint256 => uint256) public disputeEscrowFee; // Escrow fee for this dispute
mapping(uint256 => uint256) public disputeEscalationFees; // Total escalation fees paid
```

**In DecentralizedResolutionModule**:
```solidity
// Track escalation fees per dispute
mapping(uint256 => uint256) public escalationFeesPaid; // Total escalation fees for dispute
mapping(uint256 => mapping(uint8 => uint256)) public escalationFeeByLevel; // Fee paid per level
```

### New Events

```solidity
event ResolverRecorded(uint256 indexed workflowId, address indexed resolver, uint8 level);
event ResolverPaid(uint256 indexed workflowId, address indexed resolver, uint256 amount, address token);
event EscalationFeeRecorded(uint256 indexed workflowId, uint8 level, uint256 fee);
```

---

## Implementation Flow

### Step 1: Escrow Creation
1. Escrow created, fee collected
2. Store escrow fee: `disputeEscrowFee[workflowId] = fee`
3. No resolver payment yet (no dispute)

### Step 2: Dispute Raised
1. `raiseDispute()` called
2. Record initial resolver: `disputeResolvers[workflowId].push(resolver)`
3. Record level: `resolverLevel[workflowId][resolver] = 0`

### Step 3: Escalation (if any)
1. `escalateDispute()` called, fee paid in escrow's ERC20 token
2. Record escalation fee: `escalationFeesPaid[workflowId] += fee`
3. Record new resolver: `disputeResolvers[workflowId].push(newResolver)`
4. Record level: `resolverLevel[workflowId][newResolver] = newLevel`
5. Emit `EscalationFeeRecorded(workflowId, level, fee)`

### Step 4: Resolution
1. `resolve()` called by final resolver
2. Calculate total fees: `escrowFee + escalationFees`
3. Calculate resolver share: `totalFees / 2`
4. Split among all resolvers (equal split)
5. Distribute payments to each resolver
6. Emit `ResolverPaid` for each resolver

---

## Payment Distribution: Weighted by Level (Selected)

**Selected Approach**: Weighted distribution by escalation level

**Formula**: `paymentPerResolver = (totalResolverShare * weight) / totalWeight`

**Weights by Level**:
- Level 0 (initial resolver): 1x weight
- Level 1 (senior resolver): 1.5x weight
- Level 2 (external resolver): 2x weight

**Calculation**:
```solidity
uint256 totalWeight = 0;
for (each resolver) {
    uint256 weight = getWeightForLevel(resolver.level);
    totalWeight += weight;
}

for (each resolver) {
    uint256 weight = getWeightForLevel(resolver.level);
    uint256 payment = (totalResolverShare * weight) / totalWeight;
    // Pay resolver
}
```

**Example**:
- Resolver 1 (level 0): weight 1
- Resolver 2 (level 1): weight 1.5
- Resolver 3 (level 2): weight 2
- Total weight: 4.5
- Resolver share: 17.5 USDC
- Resolver 1: (17.5 * 1) / 4.5 = 3.89 USDC
- Resolver 2: (17.5 * 1.5) / 4.5 = 5.83 USDC
- Resolver 3: (17.5 * 2) / 4.5 = 7.78 USDC

**Rationale**:
- Rewards higher-level resolvers (more responsibility and expertise)
- Fair compensation for escalation complexity
- Simple to implement and understand
- Configurable weights via governance

---

## Edge Cases

### 1. No Dispute (Escrow Released/Cancelled Normally)
- **No resolver payment** (no dispute, no work done)
- Escrow fee goes 100% to protocol

### 2. Dispute Resolved by Non-Resolver
- **Should not happen** (only resolvers can resolve)
- If it does, no payment

### 3. Multiple Escalations, Same Resolver
- **Track resolver once** (don't double-pay)
- Use mapping to deduplicate: `mapping(uint256 => mapping(address => bool)) public resolverRecorded`

### 4. External Resolver (Kleros, etc.)
- **Treat as regular resolver** (level 2)
- Payment goes to external resolver contract
- External resolver distributes internally

### 5. Partial Resolution
- **Payment on final resolution** only
- All resolvers who worked get paid when dispute fully resolved

### 6. Dispute Cancelled (Not Resolved)
- **No payment** (dispute not resolved, no work completed)
- Fees remain in protocol

---

## Gas Optimization

### Batch Payments
- If multiple disputes resolved, batch payments
- Not needed for simple approach (pay immediately)

### Claimable Balances
- Allow resolvers to claim accumulated payments
- Reduces gas costs
- More complex, defer to later iteration

### Payment Threshold
- Only pay if amount > minimum (e.g., 1 USDC)
- Accumulate small amounts, pay when threshold reached
- Prevents dust payments

---

## Configuration Parameters

### DAO-Settable Parameters

1. **Resolver Share Percentage**
   - Default: 50% (5000 bps)
   - Range: 0-100% (0-10000 bps)
   - Governance: Slow lane (7-day delay)

2. **Level Weights** (if using weighted distribution)
   - Level 0 weight: 1x (10000 bps)
   - Level 1 weight: 1.5x (15000 bps)
   - Level 2 weight: 2x (20000 bps)
   - Governance: Slow lane

3. **Payment Threshold** (optional)
   - Minimum payment before distribution: 1 USDC (or equivalent in token)
   - Governance: Standard lane

4. **Payment Method**
   - Immediate vs. claimable
   - Governance: Slow lane (major change)

---

## Implementation Steps

### Phase 1: Basic Tracking
1. Add resolver tracking to `DisputeMetadata`
2. Record resolver when dispute raised
3. Record resolver when escalated
4. Track escalation fees per dispute

### Phase 2: Fee Calculation
1. Calculate escrow fee for dispute
2. Sum escalation fees for dispute
3. Calculate 50% share
4. Calculate per-resolver payments

### Phase 3: Payment Distribution
1. Implement payment transfer logic
2. Handle multi-token payments
3. Emit events
4. Update balances

### Phase 4: Testing
1. Test single resolver case
2. Test escalation case
3. Test edge cases
4. Gas optimization

---

## Example Scenarios

### Scenario 1: Simple Resolution (No Escalation)

**Flow**:
1. Escrow created: 2,000 USDC, fee 20 USDC
2. Dispute raised → Resolver A assigned
3. Resolver A resolves → 50/50 split

**Payments**:
- Resolver A: 10 USDC
- Protocol: 10 USDC

### Scenario 2: One Escalation

**Flow**:
1. Escrow created: 2,000 USDC, fee 20 USDC
2. Dispute raised → Resolver A assigned
3. Escalated (fee 5 USDC) → Resolver B assigned
4. Resolver B resolves → Split among A and B

**Payments** (Equal Split):
- Total fees: 25 USDC
- Resolver share: 12.5 USDC
- Resolver A: 6.25 USDC
- Resolver B: 6.25 USDC
- Protocol: 12.5 USDC

**Payments** (Weighted: A=1x, B=1.5x):
- Total fees: 25 USDC
- Resolver share: 12.5 USDC
- Total weight: 2.5
- Resolver A: (12.5 * 1) / 2.5 = 5 USDC
- Resolver B: (12.5 * 1.5) / 2.5 = 7.5 USDC
- Protocol: 12.5 USDC

### Scenario 3: Two Escalations

**Flow**:
1. Escrow created: 2,000 USDC, fee 20 USDC
2. Dispute raised → Resolver A assigned
3. Escalated to level 1 (fee 5 USDC) → Resolver B assigned
4. Escalated to level 2 (fee 10 USDC) → Resolver C assigned
5. Resolver C resolves → Split among A, B, C

**Payments** (Equal Split):
- Total fees: 35 USDC
- Resolver share: 17.5 USDC
- Each resolver: 5.83 USDC
- Protocol: 17.5 USDC

**Payments** (Weighted: A=1x, B=1.5x, C=2x):
- Total fees: 35 USDC
- Resolver share: 17.5 USDC
- Total weight: 4.5
- Resolver A: (17.5 * 1) / 4.5 = 3.89 USDC
- Resolver B: (17.5 * 1.5) / 4.5 = 5.83 USDC
- Resolver C: (17.5 * 2) / 4.5 = 7.78 USDC
- Protocol: 17.5 USDC

---

## Security Considerations

### 1. Payment Verification
- Verify resolver is authorized before payment
- Verify dispute is actually resolved
- Prevent double payment

### 2. Fee Tracking
- Accurately track all fees (escrow + escalation)
- Prevent fee manipulation
- Audit trail for all payments

### 3. Access Control
- Only authorized resolvers can resolve
- Only contract can record payments
- Governance controls parameters

### 4. Reentrancy
- Use `nonReentrant` modifier on payment functions
- Follow checks-effects-interactions pattern

---

## Design Decisions

1. **Payment Timing**: ✅ **Immediate Transfer**
   - Payments distributed atomically during resolution
   - Resolvers receive payment immediately, no claiming needed

2. **Distribution Method**: ✅ **Weighted by Level**
   - Level 0: 1x, Level 1: 1.5x, Level 2: 2x
   - Rewards higher-level resolvers appropriately

3. **Escalation Fee Currency**: ✅ **ERC20 Token (Same as Escrow)**
   - Escalation fees paid in same token as escrow
   - Better UX: Users only need one token approval
   - Simplified payment distribution

4. **External Resolvers**: How to handle?
   - **Recommendation**: Treat as level 2 resolver, payment to contract
   - External resolver contract distributes internally

5. **Multi-Token**: How to handle different tokens?
   - **Solution**: Each dispute uses single token (escrow's token)
   - Track payments per token: `resolverTokenBalance[resolver][token]`
   - Distribute separately per token type

6. **Gas Costs**: Who pays for payment distribution?
   - **Recommendation**: Protocol (from remaining 50%)

7. **Unresolved Disputes**: What happens to fees?
   - **Recommendation**: Fees remain in protocol (no payment if not resolved)

---

## Next Steps

1. **Review and Finalize Design**
   - Confirm payment distribution method
   - Confirm payment timing
   - Confirm parameter defaults

2. **Implementation**
   - Add resolver tracking
   - Add fee calculation
   - Add payment distribution
   - Add events

3. **Testing**
   - Unit tests for all scenarios
   - Integration tests
   - Gas optimization

4. **Deployment**
   - Deploy to testnet
   - Monitor and adjust
   - Deploy to mainnet

---

## Summary

**Simple Approach**:
- Resolvers get 50% of all fees (escrow + escalation)
- All resolvers involved are paid
- Payment on resolution (immediate transfer)
- Weighted distribution by escalation level
- Escalation fees in same ERC20 token as escrow

**Benefits**:
- Simple to implement
- Easy to understand
- Fair compensation (weighted by responsibility)
- Better UX (single token type per transaction)
- No complex metrics

**Selected Design**:
- ✅ Weighted distribution by level (1x, 1.5x, 2x)
- ✅ Immediate payment on resolution
- ✅ Escalation fees in escrow's ERC20 token

---

*This design can be enhanced later with quality metrics, staking, and reputation systems as outlined in RESOLVER_INCENTIVES_DESIGN.md*

