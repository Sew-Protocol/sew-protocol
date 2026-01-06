# Resolver Payment System: Functional Approach with Governance

**Date**: 2025-01-XX  
**Status**: Design Document  
**Approach**: Functional/Hybrid with Governance-Controlled Library Upgrades

---

## Executive Summary

This document designs a **functional/hybrid approach** for the resolver payment system where:
- **Payment calculations are pure functions in libraries**
- **Governance can approve and upgrade calculation libraries**
- **Slow lane queue/activate pattern for library upgrades**
- **State management remains in contracts (imperative)**

**Key Innovation**: Governance can upgrade payment calculation logic without touching core contracts, enabling evolution of payment models based on real-world data.

---

## Architecture Overview

### Three-Layer Architecture

```
┌─────────────────────────────────────┐
│   BaseEscrow / ResolverIncentiveModule  │  (Stateful - Imperative)
│   - State management                  │
│   - Token transfers                   │
│   - Event emission                    │
│   - Orchestration                     │
└──────────────┬──────────────────────┘
               │ uses
               ▼
┌─────────────────────────────────────┐
│   PaymentCalculationLibrary (v1)     │  (Pure Functions - Functional)
│   - calculatePayments()              │
│   - aggregateFees()                 │
│   - calculateWeights()               │
└──────────────┬──────────────────────┘
               │ can be upgraded via
               ▼
┌─────────────────────────────────────┐
│   Governance                        │  (Slow Lane - 7 days)
│   - queueNewLibrary()               │
│   - activateNewLibrary()            │
│   - Library validation              │
└─────────────────────────────────────┘
```

### Library Versioning

**Approach**: Deploy new library versions, swap via governance

```
PaymentCalculationLibraryV1.sol  (Initial - weighted by level)
PaymentCalculationLibraryV2.sol  (Future - with quality multipliers)
PaymentCalculationLibraryV3.sol  (Future - with staking bonuses)
```

---

## Library Interface Design

### Standard Interface

```solidity
interface IPaymentCalculationLibrary {
    /**
     * @notice Calculate resolver payments for a dispute
     * @param input Payment calculation input data
     * @return output Payment calculation results
     * @dev Must be pure function (no state access)
     * @dev Must implement this exact interface for compatibility
     */
    function calculatePayments(PaymentInput memory input)
        external pure returns (PaymentOutput memory output);
    
    /**
     * @notice Get library version
     * @return version Library version string
     */
    function version() external pure returns (string memory);
    
    /**
     * @notice Validate library implementation
     * @return valid True if library is valid
     * @dev Can check for required functions, interface compliance
     */
    function validate() external pure returns (bool valid);
}
```

### Data Structures

```solidity
struct PaymentInput {
    uint256 escrowFee;
    uint256 escalationFees;
    uint256 resolverSharePercentage;
    ResolverRecord[] resolvers;
    Weights weights;
    // Extensible: can add more fields in future versions
}

struct PaymentOutput {
    uint256 totalResolverShare;
    address[] resolvers;
    uint256[] payments;
    // Extensible: can add more fields in future versions
}

struct ResolverRecord {
    address resolver;
    uint8 level;
    uint256 timestamp;
}

struct Weights {
    uint256 level0;
    uint256 level1;
    uint256 level2;
}
```

---

## Governance Process for Library Upgrades

### Step 1: Library Development & Audit

**Process**:
1. Developer/team creates new library version
2. Library implements `IPaymentCalculationLibrary` interface
3. Library is audited (internal or external)
4. Library is deployed to testnet
5. Library is tested extensively

**Requirements**:
- Must implement `IPaymentCalculationLibrary` interface
- All functions must be `pure` (no state access)
- Must pass validation function
- Must be gas-efficient
- Must handle edge cases

### Step 2: Governance Proposal

**Proposal Includes**:
- New library address
- Library version/identifier
- Audit report (if available)
- Test results
- Migration plan
- Risk assessment

**Governance Action**:
```solidity
function queuePaymentCalculationLibrary(address newLibrary)
    external onlyRole(ROLE_TIMELOCK)
{
    // Validate library
    require(IPaymentCalculationLibrary(newLibrary).validate(), "Invalid library");
    
    // Queue for activation
    _queueAddress(_pendingPaymentLibrary, newLibrary);
    
    emit PaymentLibraryQueued(currentLibrary, newLibrary, _pendingPaymentLibrary.eta);
}
```

### Step 3: Community Review Period (7 Days)

**During Queue Period**:
- Community reviews library code
- Security researchers can audit
- Tests can be run
- Discussion on governance forum
- Can cancel if issues found

**View Pending Change**:
```solidity
function getPendingPaymentLibrary() 
    external view returns (address library, uint64 eta, bool exists)
{
    return getPendingAddress(_pendingPaymentLibrary);
}
```

### Step 4: Activation

**After 7-Day Delay**:
```solidity
function activatePaymentCalculationLibrary()
    external onlyRole(ROLE_TIMELOCK)
{
    address oldLibrary = currentPaymentLibrary;
    currentPaymentLibrary = _activateAddress(_pendingPaymentLibrary);
    
    emit PaymentLibraryActivated(oldLibrary, currentPaymentLibrary);
}
```

### Step 5: Verification & Monitoring

**Post-Activation**:
- Monitor first few resolutions
- Verify payments are correct
- Check for any issues
- Can rollback if critical issues found

---

## Library Validation

### Validation Requirements

**Interface Compliance**:
```solidity
function validate() external pure returns (bool) {
    // Check interface ID matches
    // Check required functions exist
    // Check functions are pure
    // Check return types match
    return true;
}
```

**Runtime Validation**:
```solidity
function validateLibrary(address library) internal view returns (bool) {
    // Check library is contract
    if (library.code.length == 0) return false;
    
    // Check interface compliance
    try IPaymentCalculationLibrary(library).validate() returns (bool valid) {
        if (!valid) return false;
    } catch {
        return false;
    }
    
    // Test calculation with known inputs
    PaymentInput memory testInput = createTestInput();
    try IPaymentCalculationLibrary(library).calculatePayments(testInput) returns (PaymentOutput memory) {
        return true;
    } catch {
        return false;
    }
}
```

### Validation Criteria

1. **Interface Compliance**
   - Implements `IPaymentCalculationLibrary`
   - Has `calculatePayments()` function
   - Has `version()` function
   - Has `validate()` function

2. **Function Purity**
   - All functions must be `pure` (no state, no external calls)
   - Can be verified via static analysis

3. **Output Validation**
   - Payments must sum to resolver share
   - No negative payments
   - Valid addresses
   - Correct array lengths

4. **Gas Efficiency**
   - Must complete within gas limits
   - Should be comparable to previous version

5. **Edge Case Handling**
   - Zero fees
   - Single resolver
   - Many resolvers
   - Zero weights

---

## Implementation Design

### Contract Structure

**ResolverIncentiveModule.sol**:
```solidity
contract ResolverIncentiveModule is 
    AccessControl, 
    ReentrancyGuard, 
    SlowLaneQueueActivate 
{
    using SafeERC20 for IERC20;
    
    // Current library (upgradeable via governance)
    address public currentPaymentLibrary;
    PendingAddress private _pendingPaymentLibrary;
    
    // State (imperative)
    mapping(uint256 => ResolverRecord[]) public disputeResolvers;
    mapping(uint256 => uint256) public disputeEscrowFees;
    mapping(uint256 => uint256) public disputeEscalationFees;
    
    // Configuration (governance-controlled)
    uint256 public resolverSharePercentage = 5000; // 50%
    Weights public weights = Weights({
        level0: 10000,
        level1: 15000,
        level2: 20000
    });
    
    /**
     * @notice Calculate and distribute payments using current library
     */
    function onDisputeResolved(
        uint256 workflowId,
        address resolvingResolver,
        address token,
        uint256 escrowFee
    ) external onlyEscrowContract {
        // 1. Gather data (imperative - state reads)
        ResolverRecord[] memory resolvers = disputeResolvers[workflowId];
        uint256 escalationFees = disputeEscalationFees[workflowId];
        
        // 2. Prepare input (functional data structure)
        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFees,
            resolverSharePercentage: resolverSharePercentage,
            resolvers: resolvers,
            weights: weights
        });
        
        // 3. Calculate payments (functional - pure library call)
        PaymentOutput memory output = IPaymentCalculationLibrary(currentPaymentLibrary)
            .calculatePayments(input);
        
        // 4. Distribute payments (imperative - state changes)
        distributePayments(workflowId, token, output);
    }
    
    /**
     * @notice Queue new payment calculation library
     * @param newLibrary Address of new library contract
     * @dev Validates library before queueing
     */
    function queuePaymentCalculationLibrary(address newLibrary)
        external onlyRole(ROLE_TIMELOCK)
    {
        require(newLibrary != address(0), "Zero address");
        require(validateLibrary(newLibrary), "Invalid library");
        
        _queueAddress(_pendingPaymentLibrary, newLibrary);
        emit PaymentLibraryQueued(currentPaymentLibrary, newLibrary, _pendingPaymentLibrary.eta);
    }
    
    /**
     * @notice Activate queued payment calculation library
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activatePaymentCalculationLibrary()
        external onlyRole(ROLE_TIMELOCK)
    {
        address oldLibrary = currentPaymentLibrary;
        currentPaymentLibrary = _activateAddress(_pendingPaymentLibrary);
        
        emit PaymentLibraryActivated(oldLibrary, currentPaymentLibrary);
    }
    
    /**
     * @notice Validate a library before queueing
     * @param library Library address to validate
     * @return valid True if library is valid
     */
    function validateLibrary(address library) public view returns (bool) {
        if (library.code.length == 0) return false;
        
        // Check interface compliance
        try IPaymentCalculationLibrary(library).validate() returns (bool valid) {
            if (!valid) return false;
        } catch {
            return false;
        }
        
        // Test with sample input
        PaymentInput memory testInput = createTestInput();
        try IPaymentCalculationLibrary(library).calculatePayments(testInput) 
            returns (PaymentOutput memory) 
        {
            return true;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Get pending library change
     * @return library Pending library address
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingPaymentLibrary() 
        external view returns (address library, uint64 eta, bool exists)
    {
        return getPendingAddress(_pendingPaymentLibrary);
    }
}
```

### Library Implementation (V1)

**PaymentCalculationLibraryV1.sol**:
```solidity
library PaymentCalculationLibraryV1 is IPaymentCalculationLibrary {
    /**
     * @notice Calculate payments using weighted distribution
     * @dev Pure function - no state access
     */
    function calculatePayments(PaymentInput memory input)
        external pure returns (PaymentOutput memory output)
    {
        // Validate input
        require(input.resolvers.length > 0, "No resolvers");
        require(input.resolverSharePercentage <= 10000, "Invalid percentage");
        
        // Aggregate fees
        uint256 totalFees = input.escrowFee + input.escalationFees;
        
        // Calculate resolver share
        uint256 resolverShare = (totalFees * input.resolverSharePercentage) / 10000;
        
        // Calculate total weight
        uint256 totalWeight = calculateTotalWeight(input.resolvers, input.weights);
        require(totalWeight > 0, "Zero total weight");
        
        // Calculate payments
        uint256[] memory payments = new uint256[](input.resolvers.length);
        address[] memory addresses = new address[](input.resolvers.length);
        
        for (uint256 i = 0; i < input.resolvers.length; i++) {
            uint256 weight = getWeightForLevel(input.resolvers[i].level, input.weights);
            payments[i] = (resolverShare * weight) / totalWeight;
            addresses[i] = input.resolvers[i].resolver;
        }
        
        return PaymentOutput({
            totalResolverShare: resolverShare,
            resolvers: addresses,
            payments: payments
        });
    }
    
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
    
    function validate() external pure returns (bool) {
        return true;
    }
    
    // Helper functions...
}
```

---

## Governance Workflow

### Proposal Process

1. **Development Phase**
   - Developer creates new library
   - Implements `IPaymentCalculationLibrary`
   - Tests thoroughly
   - Documents changes

2. **Audit Phase**
   - Internal code review
   - External audit (optional but recommended)
   - Security review
   - Gas analysis

3. **Testnet Deployment**
   - Deploy library to testnet
   - Test with testnet contracts
   - Verify calculations
   - Monitor gas costs

4. **Governance Proposal**
   - Create proposal with:
     - Library address
     - Version information
     - Audit report
     - Test results
     - Migration plan
   - Submit to DAO/Timelock

5. **Queue Phase (7 Days)**
   - Timelock queues library
   - Community review period
   - Security researchers can audit
   - Can cancel if issues found

6. **Activation**
   - After 7 days, Timelock activates
   - Library becomes active
   - New resolutions use new library

7. **Monitoring**
   - Monitor first resolutions
   - Verify payments correct
   - Check for issues
   - Can rollback if needed

### Emergency Procedures

**Rollback Mechanism**:
```solidity
function rollbackToPreviousLibrary(address previousLibrary)
    external onlyRole(ROLE_TIMELOCK)
{
    // Can rollback to previous library if issues found
    // Should be used only in emergencies
    currentPaymentLibrary = previousLibrary;
    emit PaymentLibraryRolledBack(previousLibrary);
}
```

**Pause Mechanism**:
- Can pause payment distribution if critical issues
- Resolvers can claim later
- Allows time to fix issues

---

## Library Version Evolution

### Version 1: Weighted by Level (Initial)

**Features**:
- Weighted distribution by escalation level
- Simple, proven approach
- Low gas costs

**Implementation**: `PaymentCalculationLibraryV1.sol`

### Version 2: Quality Multipliers (Future)

**Features**:
- Base weighted distribution
- Quality score multipliers
- Performance-based bonuses

**Migration**: Deploy V2, queue via governance, activate after 7 days

**Backward Compatibility**: V2 must accept same `PaymentInput` structure (or extend it)

### Version 3: Staking Bonuses (Future)

**Features**:
- Weighted distribution
- Staking-based multipliers
- Duration bonuses

**Migration**: Same process as V2

---

## Backward Compatibility

### Interface Evolution

**Strategy**: Extend, don't break

**Version 1 Input**:
```solidity
struct PaymentInput {
    uint256 escrowFee;
    uint256 escalationFees;
    uint256 resolverSharePercentage;
    ResolverRecord[] resolvers;
    Weights weights;
}
```

**Version 2 Input** (Extended):
```solidity
struct PaymentInput {
    uint256 escrowFee;
    uint256 escalationFees;
    uint256 resolverSharePercentage;
    ResolverRecord[] resolvers;
    Weights weights;
    // New fields
    mapping(address => uint256) qualityScores; // Can't use mapping in memory
    // Alternative: array of QualityScore structs
    QualityScore[] qualityScores;
}
```

**Solution**: Use optional fields or separate function
```solidity
// V1: calculatePayments(input)
// V2: calculatePaymentsWithQuality(input, qualityScores)
// Or: Extend PaymentInput with optional fields
```

### Migration Strategy

**Option 1: New Function Names**
- V1: `calculatePayments()`
- V2: `calculatePaymentsV2()`
- Contract calls appropriate version

**Option 2: Version Detection**
- Library reports version
- Contract calls version-specific function
- More complex but cleaner

**Option 3: Extensible Input**
- Input struct can have optional fields
- Libraries ignore unknown fields
- Most flexible

**Recommendation**: **Option 3 (Extensible Input)** with version detection

---

## Security Considerations

### Library Validation

**Pre-Queue Validation**:
- Interface compliance check
- Function existence check
- Purity verification (static analysis)
- Test calculation with known inputs

**Post-Activation Monitoring**:
- Monitor first resolutions
- Verify payment amounts
- Check for anomalies
- Gas cost monitoring

### Attack Vectors

1. **Malicious Library**
   - **Risk**: Library could return incorrect payments
   - **Mitigation**: Validation, audit, 7-day review period

2. **Library Upgrade Attack**
   - **Risk**: Unauthorized library upgrade
   - **Mitigation**: Access control (ROLE_TIMELOCK), slow lane

3. **Calculation Manipulation**
   - **Risk**: Library could favor certain resolvers
   - **Mitigation**: Transparent calculations, community review

4. **Gas Griefing**
   - **Risk**: Library could consume excessive gas
   - **Mitigation**: Gas limits, testing, monitoring

### Validation Checklist

Before Queueing:
- [ ] Library implements `IPaymentCalculationLibrary`
- [ ] All functions are `pure`
- [ ] Library passes `validate()` function
- [ ] Test calculation with known inputs produces expected results
- [ ] Gas costs are reasonable
- [ ] Edge cases handled
- [ ] Code reviewed/audited
- [ ] Version string set correctly

---

## Testing Strategy

### Library Testing

**Unit Tests** (Pure Functions):
```solidity
function testCalculatePayments() public {
    PaymentInput memory input = createTestInput();
    PaymentOutput memory output = PaymentCalculationLibraryV1.calculatePayments(input);
    
    assertEq(output.totalResolverShare, expectedShare);
    assertEq(output.payments.length, expectedCount);
    // ... more assertions
}
```

**Integration Tests**:
```solidity
function testLibraryUpgrade() public {
    // Deploy V1, use it
    // Queue V2
    // Wait 7 days
    // Activate V2
    // Verify V2 is used
    // Test calculations with V2
}
```

**Gas Tests**:
```solidity
function testGasCosts() public {
    uint256 gasBefore = gasleft();
    PaymentCalculationLibraryV1.calculatePayments(input);
    uint256 gasUsed = gasBefore - gasleft();
    
    assertLt(gasUsed, MAX_GAS);
}
```

---

## Example: Library Upgrade Flow

### Scenario: Upgrade to Quality-Based Payments

**Step 1: Develop V2 Library**
```solidity
library PaymentCalculationLibraryV2 is IPaymentCalculationLibrary {
    function calculatePayments(PaymentInput memory input)
        external pure returns (PaymentOutput memory output)
    {
        // Base calculation (same as V1)
        uint256 baseShare = calculateBaseShare(input);
        
        // Apply quality multipliers
        uint256[] memory payments = applyQualityMultipliers(
            baseShare,
            input.resolvers,
            input.qualityScores // New field
        );
        
        return PaymentOutput({...});
    }
}
```

**Step 2: Deploy & Test**
- Deploy to testnet
- Test with sample data
- Verify calculations
- Audit

**Step 3: Governance Proposal**
```typescript
// Governance proposal
const proposal = {
    target: incentiveModule.address,
    value: 0,
    calldata: incentiveModule.interface.encodeFunctionData(
        "queuePaymentCalculationLibrary",
        [v2Library.address]
    ),
    description: "Upgrade payment calculation to include quality multipliers"
};
```

**Step 4: Queue (Day 0)**
- Timelock queues library
- 7-day review period starts
- Community reviews code

**Step 5: Review Period (Days 1-7)**
- Security review
- Discussion
- Testing
- Can cancel if issues

**Step 6: Activate (Day 7+)**
- Timelock activates library
- New library becomes active
- Future resolutions use V2

**Step 7: Monitor**
- First resolution uses V2
- Verify payments correct
- Monitor for issues

---

## Configuration Parameters

### Governance-Controlled Parameters

**In ResolverIncentiveModule**:

1. **Resolver Share Percentage**
   - Default: 5000 (50%)
   - Range: 0-10000 (0-100%)
   - Governance: Slow lane

2. **Level Weights**
   - Level 0: 10000 (1x)
   - Level 1: 15000 (1.5x)
   - Level 2: 20000 (2x)
   - Governance: Slow lane

3. **Payment Calculation Library**
   - Current library address
   - Governance: Slow lane (library upgrades)

### Parameter Update Process

**Same Pattern as Library Upgrades**:
- Queue parameter change
- 7-day review period
- Activate after delay
- Monitor and adjust

---

## Gas Cost Analysis

### Functional Library Approach

**Library Function Calls**:
- Libraries are **inlined** (no external call overhead)
- Gas cost similar to inline code
- Slight overhead for memory management

**Comparison**:

| Approach | Gas Cost (Estimate) |
|----------|-------------------|
| Inline calculation | ~50k gas |
| Library (inlined) | ~52k gas (+2k overhead) |
| External module call | ~100k+ gas (external call) |

**For Resolver Payments**:
- Functional library: **~52k gas** (inlined, efficient)
- Modular approach: **~100k+ gas** (external calls)
- **Functional library is more gas-efficient**

---

## Benefits of Governance-Controlled Libraries

### 1. Evolution Without Upgrades
- Can improve payment logic without upgrading core contracts
- Lower risk (core contracts unchanged)
- Faster iteration

### 2. A/B Testing
- Can test different payment models
- Deploy multiple libraries
- Switch between them via governance

### 3. Community Innovation
- Community can propose new libraries
- Governance approves best ones
- Encourages innovation

### 4. Risk Management
- 7-day review period
- Community can audit before activation
- Can rollback if issues found

### 5. Transparency
- All library code is on-chain
- Governance proposals are public
- Community can review

---

## Implementation Plan

### Phase 1: Core Library (Week 1)
1. Create `IPaymentCalculationLibrary` interface
2. Implement `PaymentCalculationLibraryV1`
3. Add validation functions
4. Unit tests

### Phase 2: Module Integration (Week 2)
1. Add library reference to module
2. Implement queue/activate functions
3. Integrate library calls
4. Integration tests

### Phase 3: Governance Integration (Week 2-3)
1. Add governance functions
2. Implement validation
3. Add events
4. Governance tests

### Phase 4: Testing & Audit (Week 3-4)
1. Comprehensive testing
2. Security review
3. Gas optimization
4. Documentation

### Phase 5: Deployment (Week 4)
1. Deploy V1 library
2. Link to module
3. Test on testnet
4. Deploy to mainnet

---

## Future Library Versions

### V2: Quality Multipliers

**Enhancement**: Add quality-based payment multipliers

```solidity
struct PaymentInput {
    // ... existing fields
    QualityScore[] qualityScores; // New
}

function calculatePayments(PaymentInput memory input) {
    // Base calculation
    uint256 baseShare = calculateBaseShare(input);
    
    // Apply quality multipliers
    for (each resolver) {
        uint256 qualityMultiplier = getQualityMultiplier(resolver, qualityScores);
        payment = basePayment * qualityMultiplier / 10000;
    }
}
```

### V3: Staking Bonuses

**Enhancement**: Add staking-based bonuses

```solidity
struct PaymentInput {
    // ... existing fields
    StakingInfo[] stakingInfo; // New
}

function calculatePayments(PaymentInput memory input) {
    // Base + quality calculation
    // Apply staking bonuses
}
```

### V4: Reputation System

**Enhancement**: Integrate reputation scores

```solidity
struct PaymentInput {
    // ... existing fields
    ReputationScore[] reputationScores; // New
}
```

---

## Governance Best Practices

### Library Approval Criteria

1. **Code Quality**
   - Clean, well-documented code
   - Follows Solidity best practices
   - No known vulnerabilities

2. **Functionality**
   - Implements interface correctly
   - Handles edge cases
   - Gas efficient

3. **Testing**
   - Comprehensive test coverage
   - Test results provided
   - Edge cases tested

4. **Security**
   - Security review completed
   - No critical vulnerabilities
   - Audit report (if available)

5. **Community Support**
   - Community discussion
   - Positive feedback
   - No major objections

### Proposal Template

```markdown
## Payment Calculation Library Upgrade Proposal

### Library Information
- **Address**: 0x...
- **Version**: 2.0.0
- **Author**: [Name/Team]
- **Changes**: [Description]

### Technical Details
- **Interface Compliance**: ✅
- **Gas Costs**: [Analysis]
- **Test Coverage**: [Percentage]

### Security
- **Audit Status**: [Completed/Pending]
- **Auditor**: [Name]
- **Critical Issues**: [None/List]

### Testing
- **Testnet Deployment**: [Link]
- **Test Results**: [Link]
- **Edge Cases**: [Covered]

### Migration Plan
- **Activation Date**: [After 7-day delay]
- **Rollback Plan**: [Description]
- **Monitoring**: [Plan]

### Community Review
- **Discussion Thread**: [Link]
- **Feedback**: [Summary]
```

---

## Risk Mitigation

### Library Upgrade Risks

1. **Incorrect Calculations**
   - **Mitigation**: Validation, testing, 7-day review
   - **Response**: Rollback mechanism

2. **Gas Issues**
   - **Mitigation**: Gas testing, limits
   - **Response**: Can rollback if too expensive

3. **Interface Breaking Changes**
   - **Mitigation**: Interface validation, versioning
   - **Response**: Reject incompatible libraries

4. **Malicious Code**
   - **Mitigation**: Audit, community review, access control
   - **Response**: Cancel queue, don't activate

### Monitoring

**Post-Activation Monitoring**:
- Track first 10-20 resolutions
- Verify payment amounts
- Check gas costs
- Monitor for errors
- Community feedback

**Alert Triggers**:
- Payment amounts outside expected range
- Gas costs significantly higher
- Calculation errors
- Resolver complaints

---

## Conclusion

The functional/hybrid approach with governance-controlled library upgrades provides:

✅ **Flexibility**: Can evolve payment logic without core contract changes  
✅ **Security**: 7-day review period, validation, audits  
✅ **Innovation**: Community can propose improvements  
✅ **Risk Management**: Can rollback, monitor, adjust  
✅ **Gas Efficiency**: Library functions are inlined  
✅ **Testability**: Pure functions easy to test  

**Recommended Implementation**:
1. Start with V1 library (weighted by level)
2. Deploy with governance controls
3. Monitor and collect data
4. Propose V2 (with quality) when ready
5. Iterate based on real-world usage

**Next Steps**:
1. Implement `IPaymentCalculationLibrary` interface
2. Create `PaymentCalculationLibraryV1`
3. Add governance functions to module
4. Test and audit
5. Deploy

---

*This design enables the payment system to evolve based on real-world data while maintaining security and governance control.*

