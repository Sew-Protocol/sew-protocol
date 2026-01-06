# Resolver Payment System - Modular Development Plan

**Date**: 2025-01-XX  
**Status**: Planning  
**Design Document**: `RESOLVER_PAYMENT_SIMPLE_DESIGN.md`  
**Modularization Reference**: `RESOLVER_INCENTIVES_DESIGN.md` (Section 4.3)

---

## Executive Summary

This document outlines a **modular development plan** for implementing the resolver payment system. Instead of adding payment logic directly to `BaseEscrow` and `DecentralizedResolutionModule`, we create a separate `ResolverIncentiveModule` that handles all payment logic.

**Key Benefits of Modular Approach**:
- **Separation of Concerns**: Payment logic isolated from core escrow logic
- **Upgradeability**: Can upgrade payment system without touching core contracts
- **Testability**: Easier to test payment logic in isolation
- **Flexibility**: Can swap different incentive modules
- **Reduced Risk**: Core contracts remain unchanged

**Estimated Timeline**: 4-5 weeks (1 week longer due to module architecture)  
**Complexity**: Medium-High  
**Risk Level**: Medium

---

## Architecture Overview

### Module Structure

```
BaseEscrow
  ├── DecentralizedResolutionModule (existing)
  └── ResolverIncentiveModule (new)
       ├── Payment Calculation
       ├── Payment Distribution
       ├── Resolver Tracking
       └── Configuration
```

### Interface Design

```solidity
interface IResolverIncentiveModule {
    // Called when dispute is raised
    function onDisputeRaised(
        uint256 workflowId,
        address resolver,
        uint8 level
    ) external;
    
    // Called when dispute is escalated
    function onDisputeEscalated(
        uint256 workflowId,
        address newResolver,
        uint8 newLevel,
        uint256 escalationFee
    ) external;
    
    // Called when dispute is resolved
    function onDisputeResolved(
        uint256 workflowId,
        address resolvingResolver,
        address token,
        uint256 escrowFee
    ) external;
    
    // View functions
    function calculatePayments(uint256 workflowId) 
        external view returns (
            address[] memory resolvers,
            uint256[] memory payments
        );
    
    function getResolverBalance(address resolver, address token) 
        external view returns (uint256);
}
```

---

## Development Phases

### Phase 1: Module Architecture & Interface (Week 1)

**Goal**: Design and create the incentive module contract structure

#### Tasks

1. **Create IResolverIncentiveModule Interface**
   - [ ] Define interface with all required functions
   - [ ] Document function purposes
   - [ ] Define events
   - [ ] Add to interfaces directory

2. **Create ResolverIncentiveModule Base Contract**
   - [ ] Create new contract file
   - [ ] Inherit from AccessControl, ReentrancyGuard
   - [ ] Add state variables for configuration
   - [ ] Add access control modifiers
   - [ ] Add basic structure

3. **Define Data Structures**
   - [ ] `ResolverRecord` struct (resolver, level, timestamp)
   - [ ] `DisputePaymentInfo` struct (total fees, resolver records)
   - [ ] Mappings for tracking
   - [ ] Events

4. **Add Configuration Parameters**
   - [ ] `resolverSharePercentage` (default: 5000 = 50%)
   - [ ] `level0Weight`, `level1Weight`, `level2Weight`
   - [ ] Slow lane queue/activate for parameter changes
   - [ ] Setter functions with access control

5. **Integration Points**
   - [ ] Define how BaseEscrow calls module
   - [ ] Define callback mechanism
   - [ ] Define access control (who can call module functions)

**Deliverables**:
- Interface contract
- Base module contract structure
- Data structures defined
- Configuration system

**Testing**:
- Interface compilation
- Contract deployment
- Configuration functions

---

### Phase 2: Resolver Tracking Module (Week 1-2)

**Goal**: Implement resolver tracking in the module

#### Tasks

1. **Implement onDisputeRaised()**
   - [ ] Record initial resolver
   - [ ] Store resolver level (0)
   - [ ] Store timestamp
   - [ ] Emit event
   - [ ] Access control: only registered escrow contracts

2. **Implement onDisputeEscalated()**
   - [ ] Record new resolver
   - [ ] Store escalation level
   - [ ] Record escalation fee
   - [ ] Deduplicate if same resolver
   - [ ] Emit event

3. **Add Resolver Tracking Storage**
   - [ ] `mapping(uint256 => ResolverRecord[]) public disputeResolvers`
   - [ ] `mapping(uint256 => uint256) public disputeEscrowFees`
   - [ ] `mapping(uint256 => uint256) public disputeEscalationFees`
   - [ ] Helper functions for querying

4. **Add View Functions**
   - [ ] `getDisputeResolvers(uint256 workflowId) external view returns (ResolverRecord[] memory)`
   - [ ] `getDisputeFees(uint256 workflowId) external view returns (uint256 escrowFee, uint256 escalationFees)`
   - [ ] `hasResolver(uint256 workflowId, address resolver) external view returns (bool)`

5. **Access Control**
   - [ ] Register escrow contracts that can call module
   - [ ] `registerEscrowContract(address)` function
   - [ ] `onlyEscrowContract` modifier

**Deliverables**:
- Resolver tracking working
- Events emitting correctly
- View functions working

**Testing**:
- Test resolver recording
- Test escalation recording
- Test deduplication
- Test access control

---

### Phase 3: Payment Calculation Module (Week 2)

**Goal**: Implement payment calculation logic in module

#### Tasks

1. **Implement calculatePayments()**
   - [ ] Get escrow fee for dispute
   - [ ] Get escalation fees for dispute
   - [ ] Calculate total fees
   - [ ] Calculate resolver share (50%)
   - [ ] Get all resolvers
   - [ ] Calculate weights
   - [ ] Calculate weighted payments
   - [ ] Return arrays

2. **Add Weight Calculation**
   - [ ] `getWeightForLevel(uint8 level) internal view returns (uint256)`
   - [ ] Use configured weights
   - [ ] Handle invalid levels

3. **Add Fee Aggregation**
   - [ ] `getTotalFees(uint256 workflowId) internal view returns (uint256)`
   - [ ] Sum escrow fee + escalation fees
   - [ ] Handle zero fees

4. **Add Payment Validation**
   - [ ] Verify payments sum to resolver share
   - [ ] Verify no negative payments
   - [ ] Verify resolver addresses valid

5. **Add Helper Functions**
   - [ ] `calculateTotalWeight(ResolverRecord[] memory) internal view returns (uint256)`
   - [ ] `calculatePaymentForResolver(uint256 totalShare, uint256 weight, uint256 totalWeight) internal pure returns (uint256)`

**Deliverables**:
- Payment calculation working
- Weighted distribution correct
- View functions for testing

**Testing**:
- Test single resolver calculation
- Test multiple resolver calculation
- Test weighted distribution
- Test edge cases (zero fees, one resolver)
- Test rounding

---

### Phase 4: Payment Distribution Module (Week 2-3)

**Goal**: Implement payment distribution in module

#### Tasks

1. **Implement onDisputeResolved()**
   - [ ] Calculate payments
   - [ ] Distribute to each resolver
   - [ ] Update balances
   - [ ] Emit events
   - [ ] Handle errors gracefully

2. **Add Payment Distribution Logic**
   - [ ] Get token address
   - [ ] For each resolver:
     - [ ] Calculate payment amount
     - [ ] Transfer tokens: `IERC20(token).safeTransfer(resolver, amount)`
     - [ ] Update balance tracking
     - [ ] Emit `ResolverPaid` event
   - [ ] Handle transfer failures

3. **Add Balance Tracking**
   - [ ] `mapping(address => mapping(address => uint256)) public resolverTokenBalance`
   - [ ] Update on payment
   - [ ] View function for checking

4. **Add Error Handling**
   - [ ] Try-catch for transfers
   - [ ] Continue if one payment fails
   - [ ] Log failures
   - [ ] Allow manual claim for failed payments

5. **Add Claim Function (Optional)**
   - [ ] `claimPayment(address token)` for failed payments
   - [ ] Resolvers can claim accumulated balance
   - [ ] Useful for failed immediate payments

**Deliverables**:
- Payment distribution working
- Error handling robust
- Balance tracking accurate

**Testing**:
- Test payment distribution
- Test with insufficient balance
- Test transfer failures
- Test event emission
- Test balance tracking

---

### Phase 5: BaseEscrow Integration (Week 3)

**Goal**: Integrate module into BaseEscrow without modifying core logic

#### Tasks

1. **Add Module Reference**
   - [ ] Add `address public resolverIncentiveModule`
   - [ ] Add setter with access control (ROLE_TIMELOCK)
   - [ ] Add slow lane queue/activate

2. **Integrate onDisputeRaised()**
   - [ ] In `raiseDispute()`, after resolver assigned
   - [ ] Call `IResolverIncentiveModule(incentiveModule).onDisputeRaised(workflowId, resolver, 0)`
   - [ ] Store escrow fee: `IResolverIncentiveModule(incentiveModule).recordEscrowFee(workflowId, fee)`
   - [ ] Use try-catch (module optional)

3. **Integrate onDisputeEscalated()**
   - [ ] In `escalateDispute()`, after escalation successful
   - [ ] Call `IResolverIncentiveModule(incentiveModule).onDisputeEscalated(workflowId, newResolver, newLevel, escalationFee)`
   - [ ] Use try-catch (module optional)

4. **Integrate onDisputeResolved()**
   - [ ] In `resolve()`, after resolution successful
   - [ ] Get escrow fee for dispute
   - [ ] Call `IResolverIncentiveModule(incentiveModule).onDisputeResolved(workflowId, resolver, token, escrowFee)`
   - [ ] Use try-catch (module optional, don't fail resolution if payment fails)

5. **Handle Module Optional**
   - [ ] Check if module is set before calling
   - [ ] Don't fail if module not set
   - [ ] Don't fail if module call fails
   - [ ] Log errors but continue

**Deliverables**:
- Module integrated into BaseEscrow
- Core logic unchanged
- Graceful degradation if module not set

**Testing**:
- Test with module set
- Test without module (backward compatible)
- Test module call failures
- Test integration points

---

### Phase 6: Escalation Fee ERC20 Integration (Week 3-4)

**Goal**: Update escalation to use ERC20 tokens instead of ETH

#### Tasks

1. **Update BaseEscrow.escalateDispute()**
   - [ ] Remove `payable` modifier
   - [ ] Get escrow token: `et.token`
   - [ ] Require token transfer instead of ETH
   - [ ] Transfer escalation fee to contract
   - [ ] Record fee in incentive module

2. **Update Module Interface**
   - [ ] `onDisputeEscalated()` accepts token address
   - [ ] Module handles token tracking
   - [ ] Update function signature

3. **Update DecentralizedResolutionModule**
   - [ ] Remove ETH-specific logic (if any)
   - [ ] Ensure compatibility with ERC20
   - [ ] Update `recordEscalationFee()` if needed

4. **Test Token Transfers**
   - [ ] Test with USDC
   - [ ] Test with DAI
   - [ ] Test with custom ERC20
   - [ ] Test insufficient balance
   - [ ] Test excess token refund

**Deliverables**:
- Escalation fees work with ERC20
- Module tracks fees correctly
- Backward compatibility maintained

**Testing**:
- Test escalation with ERC20
- Test fee recording
- Test different tokens
- Test error cases

---

### Phase 7: Testing & Integration (Week 4-5)

**Goal**: Comprehensive testing of modular system

#### Tasks

1. **Module Unit Tests**
   - [ ] Test resolver tracking
   - [ ] Test payment calculation
   - [ ] Test payment distribution
   - [ ] Test configuration
   - [ ] Test edge cases

2. **Integration Tests**
   - [ ] Test full flow with module
   - [ ] Test without module (backward compatible)
   - [ ] Test module swap
   - [ ] Test multiple escrow contracts
   - [ ] Test with different tokens

3. **BaseEscrow Tests**
   - [ ] Test integration points
   - [ ] Test graceful degradation
   - [ ] Test module optional
   - [ ] Test error handling

4. **End-to-End Tests**
   - [ ] Create escrow → Dispute → Resolve → Verify payment
   - [ ] Create escrow → Dispute → Escalate → Resolve → Verify payments
   - [ ] Test with EscrowableERC20
   - [ ] Test with EscrowVault

5. **Gas Testing**
   - [ ] Profile module calls
   - [ ] Compare with non-modular approach
   - [ ] Optimize if needed

**Deliverables**:
- Comprehensive test suite
- All tests passing
- Gas optimized
- Documentation

**Testing**:
- All unit tests passing
- All integration tests passing
- Gas costs acceptable
- Backward compatibility verified

---

### Phase 8: Deployment & Migration (Week 5)

**Goal**: Deploy module and integrate with existing contracts

#### Tasks

1. **Deployment Scripts**
   - [ ] Deploy ResolverIncentiveModule
   - [ ] Set initial parameters
   - [ ] Register escrow contracts
   - [ ] Link module to BaseEscrow instances

2. **Migration Strategy**
   - [ ] Deploy module to testnet
   - [ ] Test integration
   - [ ] Deploy to mainnet
   - [ ] Activate module gradually

3. **Parameter Configuration**
   - [ ] Set `resolverSharePercentage = 5000` (50%)
   - [ ] Set level weights
   - [ ] Configure escalation fees
   - [ ] Set via governance

4. **Verification**
   - [ ] Verify module deployment
   - [ ] Verify integration
   - [ ] Test with real transactions
   - [ ] Monitor for issues

5. **Monitoring**
   - [ ] Set up event monitoring
   - [ ] Track payments
   - [ ] Monitor errors
   - [ ] Set up alerts

**Deliverables**:
- Module deployed
- Integrated with contracts
- Parameters configured
- Monitoring active

**Testing**:
- Testnet deployment successful
- Mainnet deployment successful
- Integration working
- Monitoring operational

---

## Module Contract Design

### ResolverIncentiveModule.sol

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IResolverIncentiveModule.sol";
import "../governance/SlowLaneQueueActivate.sol";

contract ResolverIncentiveModule is 
    AccessControl, 
    ReentrancyGuard, 
    IResolverIncentiveModule,
    SlowLaneQueueActivate 
{
    using SafeERC20 for IERC20;
    
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    
    // Resolver tracking
    struct ResolverRecord {
        address resolver;
        uint8 level;
        uint256 timestamp;
    }
    
    mapping(uint256 => ResolverRecord[]) public disputeResolvers;
    mapping(uint256 => uint256) public disputeEscrowFees;
    mapping(uint256 => uint256) public disputeEscalationFees;
    mapping(address => mapping(address => uint256)) public resolverTokenBalance;
    
    // Registered escrow contracts
    mapping(address => bool) public registeredEscrowContracts;
    
    // Configuration
    uint256 public resolverSharePercentage = 5000; // 50%
    uint256 public level0Weight = 10000; // 1x
    uint256 public level1Weight = 15000; // 1.5x
    uint256 public level2Weight = 20000; // 2x
    
    // Events
    event ResolverRecorded(uint256 indexed workflowId, address indexed resolver, uint8 level);
    event EscalationFeeRecorded(uint256 indexed workflowId, uint8 level, uint256 fee);
    event ResolverPaid(uint256 indexed workflowId, address indexed resolver, uint256 amount, address token, uint8 level);
    event EscrowFeeRecorded(uint256 indexed workflowId, uint256 fee);
    
    // Implementation...
}
```

---

## Integration Points

### BaseEscrow Integration

**Minimal Changes to BaseEscrow**:

1. **Add Module Reference**:
```solidity
address public resolverIncentiveModule;
```

2. **In raiseDispute()**:
```solidity
// After resolver assigned
if (address(resolverIncentiveModule) != address(0)) {
    try IResolverIncentiveModule(resolverIncentiveModule).onDisputeRaised(
        workflowId,
        resolver,
        0
    ) {} catch {
        // Module call failed, continue without payment tracking
    }
}
```

3. **In escalateDispute()**:
```solidity
// After escalation successful
if (address(resolverIncentiveModule) != address(0)) {
    try IResolverIncentiveModule(resolverIncentiveModule).onDisputeEscalated(
        workflowId,
        newResolverAddress,
        newEscalationLevel,
        escalationFee
    ) {} catch {
        // Module call failed, continue
    }
}
```

4. **In resolve()**:
```solidity
// After resolution successful
if (address(resolverIncentiveModule) != address(0)) {
    uint256 escrowFee = disputeEscrowFee[workflowId]; // Stored on creation
    try IResolverIncentiveModule(resolverIncentiveModule).onDisputeResolved(
        workflowId,
        resolver,
        et.token,
        escrowFee
    ) {} catch {
        // Payment failed, but resolution succeeded
        // Log error, allow manual claim later
    }
}
```

**Key Principle**: Module is optional, BaseEscrow works without it.

---

## Advantages of Modular Approach

### 1. Separation of Concerns
- **Core Logic**: BaseEscrow focuses on escrow functionality
- **Payment Logic**: Module handles all payment complexity
- **Clear Boundaries**: Easy to understand what does what

### 2. Upgradeability
- **Module Upgrades**: Can upgrade payment logic without touching BaseEscrow
- **Multiple Modules**: Can have different incentive modules for different use cases
- **A/B Testing**: Can test different payment models

### 3. Testability
- **Isolated Testing**: Test payment logic independently
- **Mock Contracts**: Easy to mock BaseEscrow for module tests
- **Unit Tests**: Clear test boundaries

### 4. Flexibility
- **Swap Modules**: Can replace with different incentive system
- **Optional Feature**: Contracts work without module
- **Gradual Rollout**: Deploy module separately, activate when ready

### 5. Risk Reduction
- **Core Stability**: BaseEscrow remains unchanged
- **Isolated Bugs**: Payment bugs don't affect core functionality
- **Easy Rollback**: Can disable module if issues arise

---

## Disadvantages of Modular Approach

### 1. Increased Complexity
- **More Contracts**: Additional contract to deploy and maintain
- **Integration Points**: More places where things can go wrong
- **Gas Costs**: Additional external calls

### 2. Additional Gas Costs
- **External Calls**: Each module call costs gas
- **Multiple Transactions**: May need separate transactions
- **Storage Duplication**: Some data stored in both places

### 3. Integration Overhead
- **Callback Mechanism**: Need to ensure callbacks work correctly
- **Error Handling**: Need to handle module failures gracefully
- **State Synchronization**: Ensure module state matches escrow state

### 4. Deployment Complexity
- **More Deployments**: Need to deploy module separately
- **Configuration**: Need to configure module and link to contracts
- **Migration**: Need migration path for existing contracts

---

## Comparison: Modular vs. Direct Implementation

| Aspect | Direct Implementation | Modular Approach |
|--------|----------------------|------------------|
| **Complexity** | Lower | Higher |
| **Gas Costs** | Lower (no external calls) | Higher (external calls) |
| **Upgradeability** | Harder (upgrade entire contract) | Easier (upgrade module only) |
| **Testability** | Harder (test entire system) | Easier (test module separately) |
| **Risk** | Higher (changes core contract) | Lower (isolated changes) |
| **Flexibility** | Lower (hardcoded) | Higher (swappable modules) |
| **Deployment** | Simpler (one contract) | More complex (multiple contracts) |
| **Maintenance** | Harder (all in one place) | Easier (separated concerns) |

---

## Migration Path

### Option 1: New Deployments Only
- Deploy module
- New escrow contracts use module
- Existing contracts continue without module
- **Pros**: No migration needed
- **Cons**: Inconsistent behavior

### Option 2: Gradual Migration
- Deploy module
- Link to existing contracts via governance
- Activate module for new disputes only
- **Pros**: Gradual rollout, lower risk
- **Cons**: Takes time

### Option 3: Full Migration
- Deploy module
- Link to all existing contracts
- Activate immediately
- **Pros**: Consistent behavior
- **Cons**: Higher risk, all contracts affected

**Recommendation**: **Option 2 (Gradual Migration)**

---

## Implementation Details

### Module Registration

**In ResolverIncentiveModule**:
```solidity
mapping(address => bool) public registeredEscrowContracts;

function registerEscrowContract(address escrowContract) 
    external onlyRole(ROLE_TIMELOCK) 
{
    registeredEscrowContracts[escrowContract] = true;
    emit EscrowContractRegistered(escrowContract);
}

modifier onlyEscrowContract() {
    require(registeredEscrowContracts[_msgSender()], "Not registered escrow");
    _;
}
```

**In BaseEscrow**:
```solidity
function setResolverIncentiveModule(address module) 
    external onlyRole(ROLE_TIMELOCK) 
{
    resolverIncentiveModule = module;
    emit ResolverIncentiveModuleSet(module);
}
```

### Fee Storage

**Option A: Store in Module** (Recommended)
- Module stores all fee information
- BaseEscrow calls module to record fees
- Module calculates and distributes

**Option B: Store in BaseEscrow, Module Reads**
- BaseEscrow stores fees
- Module reads from BaseEscrow
- More coupling, but simpler

**Recommendation**: **Option A** (Module stores everything)

### Error Handling

**Strategy**: Graceful Degradation
- If module not set → Continue without payments
- If module call fails → Log error, continue
- If payment fails → Log error, allow manual claim
- Never fail core functionality due to payment issues

---

## Testing Strategy

### Module Tests (Isolated)

1. **Resolver Tracking Tests**
   - Test `onDisputeRaised()`
   - Test `onDisputeEscalated()`
   - Test deduplication
   - Test access control

2. **Payment Calculation Tests**
   - Test `calculatePayments()`
   - Test weighted distribution
   - Test edge cases
   - Test rounding

3. **Payment Distribution Tests**
   - Test `onDisputeResolved()`
   - Test token transfers
   - Test error handling
   - Test balance tracking

### Integration Tests

1. **BaseEscrow + Module**
   - Test full flow with module
   - Test without module
   - Test module failures
   - Test callback timing

2. **Multiple Contracts**
   - Test with EscrowableERC20
   - Test with EscrowVault
   - Test multiple instances

3. **Token Tests**
   - Test with different ERC20 tokens
   - Test with non-standard tokens
   - Test transfer failures

---

## Risk Assessment

### Technical Risks

1. **Module Call Failures**
   - **Risk**: Module calls may fail, breaking core functionality
   - **Mitigation**: Use try-catch, never revert on module failure

2. **State Synchronization**
   - **Risk**: Module state may get out of sync with BaseEscrow
   - **Mitigation**: Idempotent operations, validation checks

3. **Gas Costs**
   - **Risk**: External calls add gas costs
   - **Mitigation**: Optimize module, batch operations where possible

4. **Integration Complexity**
   - **Risk**: More integration points = more failure modes
   - **Mitigation**: Thorough testing, clear interfaces

### Business Risks

1. **Module Deployment**
   - **Risk**: Module deployment may fail or have bugs
   - **Mitigation**: Extensive testing, gradual rollout

2. **Configuration Errors**
   - **Risk**: Wrong parameters may break economics
   - **Mitigation**: Slow lane governance, conservative defaults

3. **Migration Issues**
   - **Risk**: Linking module to existing contracts may have issues
   - **Mitigation**: Test thoroughly, gradual activation

---

## Success Criteria

### Functional Requirements
- ✅ Module tracks all resolvers correctly
- ✅ Module calculates payments correctly
- ✅ Module distributes payments immediately
- ✅ BaseEscrow integrates seamlessly
- ✅ Backward compatible (works without module)

### Non-Functional Requirements
- ✅ Gas costs acceptable (< 250k for resolution with payment)
- ✅ Module upgradeable
- ✅ All tests passing
- ✅ Security review complete
- ✅ Documentation complete

### Performance Requirements
- ✅ Module calls complete in reasonable time
- ✅ No significant impact on core contract gas costs
- ✅ View functions return quickly

---

## Timeline

| Phase | Duration | Start | End |
|-------|----------|-------|-----|
| Phase 1: Module Architecture | 4-5 days | Week 1 | Week 1 |
| Phase 2: Resolver Tracking | 3-4 days | Week 1 | Week 2 |
| Phase 3: Payment Calculation | 3-4 days | Week 2 | Week 2 |
| Phase 4: Payment Distribution | 3-4 days | Week 2 | Week 3 |
| Phase 5: BaseEscrow Integration | 3-4 days | Week 3 | Week 3 |
| Phase 6: ERC20 Escalation | 2-3 days | Week 3 | Week 4 |
| Phase 7: Testing & Integration | 5-6 days | Week 4 | Week 5 |
| Phase 8: Deployment & Migration | 3-4 days | Week 5 | Week 5 |
| **Total** | **4-5 weeks** | | |

---

## Dependencies

### External Dependencies
- OpenZeppelin contracts (AccessControl, ReentrancyGuard, SafeERC20)
- ERC20 token contracts

### Internal Dependencies
- BaseEscrow contract (minimal changes)
- DecentralizedResolutionModule (no changes needed)
- Access control system
- Slow lane governance

### New Dependencies
- IResolverIncentiveModule interface
- Module deployment scripts
- Module testing framework

---

## Rollout Strategy

### Phase 1: Module Development
1. Develop module in isolation
2. Test module independently
3. Verify interface compatibility

### Phase 2: Integration Testing
1. Integrate with BaseEscrow on testnet
2. Test full flows
3. Verify backward compatibility

### Phase 3: Testnet Deployment
1. Deploy module to testnet
2. Link to test escrow contracts
3. Test with real transactions
4. Monitor and adjust

### Phase 4: Mainnet Deployment (Gradual)
1. Deploy module to mainnet
2. Link to one escrow contract
3. Test with small disputes
4. Gradually expand

### Phase 5: Full Activation
1. Link to all escrow contracts
2. Activate for all new disputes
3. Monitor closely
4. Adjust parameters as needed

---

## Monitoring & Metrics

### Module-Specific Metrics
- Number of disputes tracked
- Number of payments distributed
- Total payments made
- Average payment per resolver
- Payment failure rate
- Gas costs per operation

### Integration Metrics
- Module call success rate
- Module call failure reasons
- State synchronization issues
- Backward compatibility usage

### Alerts
- Module call failures
- Payment distribution failures
- State synchronization errors
- Unusual patterns

---

## Future Enhancements

### Module Upgrades
- Can upgrade to add quality metrics
- Can upgrade to add staking
- Can upgrade to add reputation
- Can swap for different incentive model

### Multiple Modules
- Different modules for different use cases
- A/B testing different models
- Specialized modules per escrow type

### Module Marketplace
- Third-party incentive modules
- Competition between modules
- Resolver choice of module

---

## Comparison Summary

### When to Use Modular Approach

**Use Modular If**:
- ✅ You want upgradeability without touching core contracts
- ✅ You want to test payment logic separately
- ✅ You want flexibility to swap payment models
- ✅ You want to reduce risk to core contracts
- ✅ You're okay with slightly higher gas costs

**Use Direct Implementation If**:
- ✅ You want simplest possible implementation
- ✅ You want lowest gas costs
- ✅ You don't need upgradeability
- ✅ You want everything in one place
- ✅ You're okay with upgrading entire contract

**Recommendation**: 
- **Start with Direct Implementation** for simplicity and speed
- **Migrate to Modular** later if upgradeability becomes important
- **OR**: Use Modular from start if you know you'll need flexibility

---

## Conclusion

The modular approach provides greater flexibility and upgradeability at the cost of increased complexity and gas costs. It's ideal for systems that need to evolve their incentive mechanisms over time or want to test different payment models.

**Key Advantages**:
- Separation of concerns
- Easy upgrades
- Better testability
- Reduced risk to core contracts

**Key Trade-offs**:
- More complex
- Higher gas costs
- More integration points
- Additional deployment

**Next Steps**:
1. Review and approve modular approach
2. Begin Phase 1 implementation
3. Set up module testing infrastructure
4. Plan integration strategy

---

*This plan should be updated as development progresses and new requirements or constraints are discovered.*

