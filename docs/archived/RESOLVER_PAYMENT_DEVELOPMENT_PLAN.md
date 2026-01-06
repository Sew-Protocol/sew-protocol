# Resolver Payment System - Development Plan

**Date**: 2025-01-XX  
**Status**: Planning  
**Design Document**: `RESOLVER_PAYMENT_SIMPLE_DESIGN.md`

---

## Executive Summary

This document outlines the development plan for implementing the simple resolver payment system:
- Resolvers receive 50% of all fees (escrow + escalation)
- Weighted distribution by escalation level (1x, 1.5x, 2x)
- Immediate payment on resolution
- Escalation fees in ERC20 tokens (same as escrow)

**Estimated Timeline**: 3-4 weeks  
**Complexity**: Medium  
**Risk Level**: Medium

---

## Development Phases

### Phase 1: Data Structures & Tracking (Week 1)

**Goal**: Add data structures to track resolvers and fees per dispute

#### Tasks

1. **Add Resolver Tracking to BaseEscrow**
   - [ ] Add `disputeResolvers` mapping: `mapping(uint256 => address[])`
   - [ ] Add `resolverLevel` mapping: `mapping(uint256 => mapping(address => uint8))`
   - [ ] Add `disputeEscrowFee` mapping: `mapping(uint256 => uint256)`
   - [ ] Add `disputeEscalationFees` mapping: `mapping(uint256 => uint256)`
   - [ ] Add `resolverTokenBalance` mapping: `mapping(address => mapping(address => uint256))`

2. **Add Escalation Fee Tracking to DecentralizedResolutionModule**
   - [ ] Add `escalationFeesPaid` mapping: `mapping(uint256 => uint256)`
   - [ ] Add `escalationFeeByLevel` mapping: `mapping(uint256 => mapping(uint8 => uint256))`
   - [ ] Update `executeEscalation()` to record fees

3. **Store Escrow Fee on Creation**
   - [ ] Modify `createEscrow()` to store fee: `disputeEscrowFee[workflowId] = fee`
   - [ ] Test fee storage for both EscrowableERC20 and EscrowVault

4. **Record Resolver on Dispute**
   - [ ] Modify `raiseDispute()` to record initial resolver
   - [ ] Add resolver to `disputeResolvers[workflowId]`
   - [ ] Set `resolverLevel[workflowId][resolver] = 0`

5. **Record Resolver on Escalation**
   - [ ] Modify `escalateDispute()` to record new resolver
   - [ ] Add new resolver to `disputeResolvers[workflowId]`
   - [ ] Set `resolverLevel[workflowId][newResolver] = newLevel`
   - [ ] Record escalation fee in module

**Deliverables**:
- Data structures added to contracts
- Resolver tracking working
- Fee tracking working
- Unit tests for tracking

**Testing**:
- Test resolver recording on dispute
- Test resolver recording on escalation
- Test fee storage
- Test deduplication (same resolver at multiple levels)

---

### Phase 2: Escalation Fee Collection (Week 1-2)

**Goal**: Change escalation fees from ETH to ERC20 tokens

#### Tasks

1. **Update BaseEscrow.escalateDispute()**
   - [ ] Change from `payable` to accept ERC20 token
   - [ ] Get escrow token: `et.token`
   - [ ] Require token approval/transfer instead of `msg.value`
   - [ ] Transfer escalation fee to contract
   - [ ] Record fee in module: `IResolutionModule(resolutionModule).recordEscalationFee(workflowId, level, fee)`

2. **Update DecentralizedResolutionModule**
   - [ ] Add `recordEscalationFee()` function
   - [ ] Update `escalationFeesPaid[workflowId] += fee`
   - [ ] Update `escalationFeeByLevel[workflowId][level] = fee`
   - [ ] Emit `EscalationFeeRecorded` event

3. **Update Interface (if needed)**
   - [ ] Check if `IResolutionModule` needs new function
   - [ ] Add interface function if required

4. **Remove ETH Transfer Logic**
   - [ ] Remove `payable` modifier
   - [ ] Remove ETH transfer to `escrowFeeAddress`
   - [ ] Update refund logic (if any excess tokens sent)

**Deliverables**:
- Escalation fees work with ERC20 tokens
- Fees properly tracked
- Backward compatibility considered

**Testing**:
- Test escalation with ERC20 token
- Test fee recording
- Test insufficient token balance
- Test excess token refund
- Test with different token types

---

### Phase 3: Payment Calculation (Week 2)

**Goal**: Implement payment calculation logic

#### Tasks

1. **Add Configuration Parameters**
   - [ ] Add `resolverSharePercentage` (default: 5000 = 50%)
   - [ ] Add level weights: `level0Weight`, `level1Weight`, `level2Weight`
   - [ ] Add setter functions with access control (ROLE_TIMELOCK)
   - [ ] Add slow lane queue/activate for parameter changes

2. **Implement calculateResolverPayments()**
   - [ ] Get escrow fee: `disputeEscrowFee[workflowId]`
   - [ ] Get escalation fees: `escalationFeesPaid[workflowId]`
   - [ ] Calculate total fees
   - [ ] Calculate resolver share: `totalFees * resolverSharePercentage / 10000`
   - [ ] Get all resolvers: `disputeResolvers[workflowId]`
   - [ ] Calculate weights for each resolver
   - [ ] Calculate payments using weighted distribution
   - [ ] Return payments array

3. **Add Helper Functions**
   - [ ] `getWeightForLevel(uint8 level) internal view returns (uint256)`
   - [ ] `getTotalFeesForDispute(uint256 workflowId) internal view returns (uint256)`
   - [ ] `getResolverCount(uint256 workflowId) internal view returns (uint256)`

4. **Add View Functions**
   - [ ] `calculateResolverPayments(uint256 workflowId) external view returns (uint256 totalShare, address[] memory resolvers, uint256[] memory payments)`
   - [ ] `getDisputeFees(uint256 workflowId) external view returns (uint256 escrowFee, uint256 escalationFees)`

**Deliverables**:
- Payment calculation working
- Configurable parameters
- View functions for testing/debugging

**Testing**:
- Test calculation with single resolver
- Test calculation with multiple resolvers
- Test weighted distribution
- Test edge cases (zero fees, one resolver, etc.)
- Test parameter changes

---

### Phase 4: Payment Distribution (Week 2-3)

**Goal**: Implement immediate payment distribution on resolution

#### Tasks

1. **Implement distributeResolverPayments()**
   - [ ] Call `calculateResolverPayments()`
   - [ ] Get escrow token: `et.token`
   - [ ] For each resolver:
     - [ ] Transfer payment: `IERC20(token).safeTransfer(resolver, payment)`
     - [ ] Update balance: `resolverTokenBalance[resolver][token] += payment` (for tracking)
     - [ ] Emit `ResolverPaid` event
   - [ ] Handle errors gracefully (continue if one payment fails)

2. **Integrate into resolve() Function**
   - [ ] Call `distributeResolverPayments()` after resolution
   - [ ] Ensure payment happens before state changes (or after, depending on pattern)
   - [ ] Handle reentrancy protection

3. **Update Fee Accounting**
   - [ ] Deduct resolver payments from `totalFees`
   - [ ] Update `totalFeesPerToken[token]` (for EscrowVault)
   - [ ] Ensure protocol receives remaining 50%

4. **Add Events**
   - [ ] `event ResolverPaid(uint256 indexed workflowId, address indexed resolver, uint256 amount, address token, uint8 level)`
   - [ ] `event ResolverRecorded(uint256 indexed workflowId, address indexed resolver, uint8 level)`
   - [ ] `event EscalationFeeRecorded(uint256 indexed workflowId, uint8 level, uint256 fee)`

**Deliverables**:
- Payment distribution working
- Events emitted
- Fee accounting correct

**Testing**:
- Test payment distribution
- Test with insufficient contract balance
- Test with multiple resolvers
- Test event emission
- Test fee accounting accuracy

---

### Phase 5: Edge Cases & Error Handling (Week 3)

**Goal**: Handle all edge cases and error scenarios

#### Tasks

1. **Handle Edge Cases**
   - [ ] No dispute (escrow released/cancelled) → No payment
   - [ ] Dispute cancelled (not resolved) → No payment
   - [ ] Same resolver at multiple levels → Deduplicate
   - [ ] External resolver → Payment to contract address
   - [ ] Zero fees → No payment
   - [ ] Payment amount too small → Consider threshold

2. **Error Handling**
   - [ ] Insufficient contract balance → Revert or handle gracefully
   - [ ] Token transfer failure → Log and continue or revert
   - [ ] Invalid resolver address → Skip or revert
   - [ ] Calculation overflow → Use SafeMath or check bounds

3. **Access Control**
   - [ ] Verify only authorized resolvers can resolve
   - [ ] Verify only participants can escalate
   - [ ] Verify only governance can change parameters

4. **Gas Optimization**
   - [ ] Batch operations where possible
   - [ ] Use storage efficiently
   - [ ] Minimize external calls
   - [ ] Consider payment threshold to avoid dust

**Deliverables**:
- All edge cases handled
- Robust error handling
- Gas optimized

**Testing**:
- Test all edge cases
- Test error scenarios
- Test access control
- Gas profiling

---

### Phase 6: Testing & Integration (Week 3-4)

**Goal**: Comprehensive testing and integration

#### Tasks

1. **Unit Tests**
   - [ ] Test resolver tracking
   - [ ] Test fee calculation
   - [ ] Test payment distribution
   - [ ] Test weighted distribution
   - [ ] Test edge cases
   - [ ] Test parameter changes

2. **Integration Tests**
   - [ ] Test full flow: create → dispute → resolve → payment
   - [ ] Test escalation flow: create → dispute → escalate → resolve → payment
   - [ ] Test multiple escalations
   - [ ] Test with different tokens
   - [ ] Test with EscrowableERC20
   - [ ] Test with EscrowVault

3. **Gas Testing**
   - [ ] Profile gas costs
   - [ ] Optimize if needed
   - [ ] Document gas costs

4. **Security Review**
   - [ ] Review access control
   - [ ] Review reentrancy protection
   - [ ] Review fee calculation accuracy
   - [ ] Review payment distribution logic
   - [ ] Consider audit

5. **Documentation**
   - [ ] Update code comments
   - [ ] Update README if needed
   - [ ] Document parameters
   - [ ] Document events

**Deliverables**:
- Comprehensive test suite
- Integration tests passing
- Gas optimized
- Documentation complete

**Testing**:
- All unit tests passing
- All integration tests passing
- Gas costs acceptable
- Security review complete

---

### Phase 7: Deployment Preparation (Week 4)

**Goal**: Prepare for deployment

#### Tasks

1. **Deployment Scripts**
   - [ ] Update deployment scripts
   - [ ] Set initial parameters
   - [ ] Register escrow contracts with module
   - [ ] Verify contract addresses

2. **Parameter Configuration**
   - [ ] Set `resolverSharePercentage = 5000` (50%)
   - [ ] Set `level0Weight = 10000` (1x)
   - [ ] Set `level1Weight = 15000` (1.5x)
   - [ ] Set `level2Weight = 20000` (2x)
   - [ ] Set escalation fees per level

3. **Verification**
   - [ ] Verify contract bytecode
   - [ ] Verify on Etherscan (if mainnet)
   - [ ] Test on testnet first
   - [ ] Monitor initial transactions

4. **Monitoring**
   - [ ] Set up event monitoring
   - [ ] Set up payment tracking
   - [ ] Set up alerts for errors

**Deliverables**:
- Deployment scripts ready
- Parameters configured
- Monitoring in place

**Testing**:
- Testnet deployment successful
- Parameters correct
- Monitoring working

---

## Implementation Details

### Contract Changes

#### BaseEscrow.sol

**New State Variables**:
```solidity
// Resolver tracking
mapping(uint256 => address[]) public disputeResolvers;
mapping(uint256 => mapping(address => uint8)) public resolverLevel;
mapping(uint256 => uint256) public disputeEscrowFee;
mapping(uint256 => uint256) public disputeEscalationFees;
mapping(address => mapping(address => uint256)) public resolverTokenBalance;

// Configuration
uint256 public resolverSharePercentage = 5000; // 50%
uint256 public level0Weight = 10000; // 1x
uint256 public level1Weight = 15000; // 1.5x
uint256 public level2Weight = 20000; // 2x
```

**Modified Functions**:
- `createEscrow()` - Store escrow fee
- `raiseDispute()` - Record initial resolver
- `escalateDispute()` - Accept ERC20, record resolver and fee
- `resolve()` - Calculate and distribute payments

**New Functions**:
- `calculateResolverPayments()` - Calculate payments
- `distributeResolverPayments()` - Distribute payments
- `getWeightForLevel()` - Get weight for level
- `setResolverSharePercentage()` - Set share percentage
- `setLevelWeights()` - Set level weights

#### DecentralizedResolutionModule.sol

**New State Variables**:
```solidity
mapping(uint256 => uint256) public escalationFeesPaid;
mapping(uint256 => mapping(uint8 => uint256)) public escalationFeeByLevel;
```

**Modified Functions**:
- `executeEscalation()` - Record escalation fee

**New Functions**:
- `recordEscalationFee()` - Record fee (called by BaseEscrow)

---

## Testing Strategy

### Unit Tests

1. **Resolver Tracking**
   - Test recording resolver on dispute
   - Test recording resolver on escalation
   - Test deduplication
   - Test level assignment

2. **Fee Calculation**
   - Test single resolver payment
   - Test multiple resolver payment
   - Test weighted distribution
   - Test edge cases (zero fees, one resolver)

3. **Payment Distribution**
   - Test immediate payment
   - Test multiple resolver payments
   - Test token transfer
   - Test error handling

### Integration Tests

1. **Full Flow Tests**
   - Create escrow → Dispute → Resolve → Verify payment
   - Create escrow → Dispute → Escalate → Resolve → Verify payments
   - Create escrow → Dispute → Multiple escalations → Resolve → Verify payments

2. **Token Tests**
   - Test with USDC
   - Test with DAI
   - Test with custom ERC20

3. **Contract Tests**
   - Test with EscrowableERC20
   - Test with EscrowVault

### Edge Case Tests

1. **No Payment Scenarios**
   - Escrow released normally (no dispute)
   - Escrow cancelled normally (no dispute)
   - Dispute cancelled (not resolved)

2. **Error Scenarios**
   - Insufficient contract balance
   - Token transfer failure
   - Invalid resolver address
   - Calculation overflow

3. **Special Cases**
   - Same resolver at multiple levels
   - External resolver (contract)
   - Zero fees
   - Very small fees

---

## Risk Assessment

### Technical Risks

1. **Gas Costs**
   - **Risk**: Payment distribution may be expensive
   - **Mitigation**: Optimize loops, consider batching, set payment threshold

2. **Token Transfer Failures**
   - **Risk**: Some tokens may not transfer correctly
   - **Mitigation**: Use SafeERC20, handle errors gracefully

3. **Calculation Errors**
   - **Risk**: Payment calculation may have rounding errors
   - **Mitigation**: Use precise math, test edge cases, consider rounding direction

4. **Reentrancy**
   - **Risk**: Payment distribution may be vulnerable
   - **Mitigation**: Use nonReentrant, follow checks-effects-interactions

### Business Risks

1. **Parameter Misconfiguration**
   - **Risk**: Wrong parameters may break economics
   - **Mitigation**: Slow lane governance, extensive testing, conservative defaults

2. **Insufficient Funds**
   - **Risk**: Contract may not have enough tokens for payments
   - **Mitigation**: Ensure fees collected before payments, handle gracefully

3. **Resolver Gaming**
   - **Risk**: Resolvers may try to game the system
   - **Mitigation**: Clear rules, monitoring, future reputation system

---

## Success Criteria

### Functional Requirements
- ✅ Resolvers receive 50% of fees
- ✅ All resolvers involved are paid
- ✅ Weighted distribution by level works
- ✅ Escalation fees in ERC20 tokens
- ✅ Immediate payment on resolution

### Non-Functional Requirements
- ✅ Gas costs acceptable (< 200k gas for resolution with payment)
- ✅ All tests passing
- ✅ Security review complete
- ✅ Documentation complete
- ✅ Parameters configurable via governance

### Performance Requirements
- ✅ Payment distribution completes in single transaction
- ✅ No significant increase in gas costs for normal operations
- ✅ View functions return quickly

---

## Timeline

| Phase | Duration | Start | End |
|-------|----------|-------|-----|
| Phase 1: Data Structures | 3-4 days | Week 1 | Week 1 |
| Phase 2: Escalation Fees | 2-3 days | Week 1 | Week 2 |
| Phase 3: Payment Calculation | 3-4 days | Week 2 | Week 2 |
| Phase 4: Payment Distribution | 3-4 days | Week 2 | Week 3 |
| Phase 5: Edge Cases | 2-3 days | Week 3 | Week 3 |
| Phase 6: Testing | 4-5 days | Week 3 | Week 4 |
| Phase 7: Deployment Prep | 2-3 days | Week 4 | Week 4 |
| **Total** | **3-4 weeks** | | |

---

## Dependencies

### External Dependencies
- OpenZeppelin SafeERC20 (already in use)
- ERC20 token contracts (for testing)

### Internal Dependencies
- BaseEscrow contract
- DecentralizedResolutionModule contract
- Access control system
- Slow lane governance

### Testing Dependencies
- Hardhat test framework
- Test ERC20 tokens
- Mock contracts

---

## Rollout Strategy

### Phase 1: Testnet Deployment
1. Deploy to testnet
2. Test with small amounts
3. Verify all functionality
4. Monitor for issues

### Phase 2: Mainnet Deployment (Limited)
1. Deploy to mainnet
2. Start with low parameters (conservative)
3. Monitor closely
4. Collect data

### Phase 3: Full Rollout
1. Adjust parameters based on data
2. Increase limits if needed
3. Full production use

---

## Monitoring & Metrics

### Key Metrics
- Number of disputes resolved
- Total fees collected
- Total payments to resolvers
- Average payment per resolver
- Gas costs per resolution
- Error rate

### Alerts
- Payment failures
- Calculation errors
- Insufficient balance
- Unusual patterns

### Dashboards
- Resolver payment dashboard
- Fee collection dashboard
- Dispute resolution dashboard

---

## Future Enhancements

### Short-term (Post-Launch)
- Payment threshold optimization
- Gas cost optimization
- Batch payment claims (if needed)

### Medium-term
- Quality-based multipliers
- Resolver statistics
- Performance tracking

### Long-term
- Staking system
- Reputation system
- Marketplace features

---

## Open Questions

1. **Payment Threshold**: Should we implement minimum payment threshold?
   - **Decision**: Defer to post-launch based on gas costs

2. **Failed Payments**: What happens if payment fails?
   - **Decision**: Log error, continue with other payments, allow manual claim

3. **External Resolvers**: How to handle payment to contract?
   - **Decision**: Send to contract address, let contract distribute internally

4. **Parameter Changes**: How often can parameters change?
   - **Decision**: Slow lane (7-day delay), quarterly review

---

## Conclusion

This development plan provides a structured approach to implementing the resolver payment system. The phased approach allows for incremental development, testing, and validation at each stage.

**Key Success Factors**:
- Thorough testing at each phase
- Careful parameter configuration
- Monitoring and adjustment
- Security review before mainnet

**Next Steps**:
1. Review and approve plan
2. Begin Phase 1 implementation
3. Set up testing infrastructure
4. Schedule security review

---

*This plan should be updated as development progresses and new requirements or constraints are discovered.*

