# Contract Improvements Proposal

**Date**: 2025-01-XX  
**Focus**: DecentralizedResolutionModule and Connected Modules  
**Perspectives**: Real-World Use & Code Quality

---

## Executive Summary

This document proposes improvements to `DecentralizedResolutionModule`, `ResolverIncentiveModule`, and `PaymentCalculationLibraryV1` from two perspectives:

1. **Real-World Use**: Practical usability, edge cases, and operational concerns
2. **Code Quality**: Security, gas efficiency, maintainability, and best practices

---

## 1. Real-World Use Improvements

### 1.1 Resolver Availability & Health Checks

**Issue**: No mechanism to check if a resolver is active/available before assignment

**Problem**:
- Round-robin may assign inactive resolvers
- No way to skip unavailable resolvers
- Resolvers might be removed but still in array

**Proposal**:
```solidity
// Add to DecentralizedResolutionModule
mapping(address => bool) public resolverActive; // Quick check
mapping(address => uint256) public resolverLastActive; // Timestamp

function selectResolverRoundRobin(bytes32 category, bool useSeniorResolvers)
    internal view returns (address selectedResolver)
{
    address[] memory resolverList = useSeniorResolvers ? approvedSeniorResolvers : approvedResolvers;
    
    if (resolverList.length == 0) {
        return address(0);
    }
    
    uint256 currentIndex = useSeniorResolvers 
        ? categorySeniorResolverIndex[category] 
        : categoryResolverIndex[category];
    
    // Try up to resolverList.length times to find active resolver
    for (uint256 i = 0; i < resolverList.length; i++) {
        uint256 index = (currentIndex + i) % resolverList.length;
        address candidate = resolverList[index];
        
        // Check if resolver is active
        if (resolverActive[candidate] && 
            (isApprovedResolver[candidate] || isApprovedSeniorResolver[candidate])) {
            return candidate;
        }
    }
    
    return address(0); // No active resolvers
}

function setResolverActive(address resolver, bool active) 
    external onlyRole(ROLE_TIMELOCK) 
{
    resolverActive[resolver] = active;
    if (active) {
        resolverLastActive[resolver] = block.timestamp;
    }
    emit ResolverActiveStatusChanged(resolver, active);
}
```

**Benefits**:
- Skip inactive resolvers automatically
- Better user experience
- Prevents assignment to removed resolvers

---

### 1.2 Resolver Workload Balancing

**Issue**: Round-robin doesn't account for resolver capacity or current workload

**Problem**:
- High-capacity resolvers get same weight as low-capacity
- No way to prioritize available resolvers
- Can't handle resolver-specific limits

**Proposal**:
```solidity
struct ResolverCapacity {
    uint256 maxConcurrentDisputes;
    uint256 currentDisputes;
    bool acceptsNewDisputes;
}

mapping(address => ResolverCapacity) public resolverCapacity;

function selectResolverRoundRobin(bytes32 category, bool useSeniorResolvers)
    internal view returns (address selectedResolver)
{
    // ... existing code ...
    
    // Filter by capacity
    for (uint256 i = 0; i < resolverList.length; i++) {
        uint256 index = (currentIndex + i) % resolverList.length;
        address candidate = resolverList[index];
        
        ResolverCapacity memory capacity = resolverCapacity[candidate];
        
        if (capacity.acceptsNewDisputes && 
            capacity.currentDisputes < capacity.maxConcurrentDisputes) {
            return candidate;
        }
    }
    
    // Fallback: return first available even if at capacity
    return selectResolverRoundRobin(category, useSeniorResolvers);
}
```

**Benefits**:
- Better workload distribution
- Prevents resolver overload
- More realistic for production use

---

### 1.3 Dispute Timeout & Auto-Escalation

**Issue**: No timeout mechanism for disputes - can remain unresolved indefinitely

**Problem**:
- Disputes can stall if resolver is unresponsive
- No automatic escalation after timeout
- Users have no recourse for slow resolvers

**Proposal**:
```solidity
struct DisputeMetadata {
    address currentResolver;
    uint8 escalationLevel;
    address escalatedBy;
    uint256 escalationTimestamp;
    uint256 timeoutTimestamp; // NEW: When dispute should auto-escalate
    bytes resolutionData;
}

uint256 public disputeTimeout = 7 days; // Configurable via governance

function initializeDispute(...) external onlyEscrowContract {
    // ... existing code ...
    
    dm.timeoutTimestamp = block.timestamp + disputeTimeout;
    emit DisputeInitialized(workflowId, resolver, dm.timeoutTimestamp);
}

function checkAndAutoEscalate(uint256 workflowId) external {
    DisputeMetadata storage dm = disputeMetadata[workflowId];
    
    require(dm.currentResolver != address(0), "No dispute");
    require(block.timestamp >= dm.timeoutTimestamp, "Not timed out");
    require(dm.escalationLevel < 2, "Max level reached");
    
    // Auto-escalate
    executeEscalation(workflowId, "");
}
```

**Benefits**:
- Prevents disputes from stalling
- Automatic escalation path
- Better user experience

---

### 1.4 Category Auto-Assignment

**Issue**: Categories must be manually set - no automatic categorization

**Problem**:
- Escrow contracts must call `setEscrowCategory` manually
- Easy to forget
- Inconsistent categorization

**Proposal**:
```solidity
function getResolver(
    uint256 workflowId,
    bytes calldata escrowData
) external view override returns (address resolver, uint8 escalationLevel) {
    DisputeMetadata memory dm = disputeMetadata[workflowId];
    
    if (dm.currentResolver != address(0)) {
        return (dm.currentResolver, dm.escalationLevel);
    }
    
    // Auto-determine category if not set
    bytes32 category = escrowCategory[workflowId];
    if (category == bytes32(0)) {
        // Auto-categorize based on escrow data
        category = autoCategorizeEscrow(escrowData);
        // Note: Can't write to storage in view function
        // Escrow contract should call setEscrowCategory
    }
    
    // ... rest of logic ...
}

function autoCategorizeEscrow(bytes calldata escrowData) 
    public pure returns (bytes32) 
{
    // Decode escrow data
    (address token, , , uint256 amount, ) = abi.decode(
        escrowData, 
        (address, address, address, uint256, uint256)
    );
    
    // Generate category based on amount and token
    return keccak256(abi.encodePacked(token, getAmountTier(amount)));
}

function getAmountTier(uint256 amount) public pure returns (string memory) {
    if (amount < 1 ether) return "SMALL";
    if (amount < 10 ether) return "MEDIUM";
    if (amount < 100 ether) return "LARGE";
    return "VERY_LARGE";
}
```

**Benefits**:
- Automatic categorization
- Less manual work
- More consistent

---

### 1.5 Resolver Reputation & Quality Tracking

**Issue**: No way to track resolver performance or quality

**Problem**:
- Can't identify good vs. bad resolvers
- No data for future improvements
- Can't weight selection by quality

**Proposal**:
```solidity
struct ResolverStats {
    uint256 disputesResolved;
    uint256 disputesEscalated; // Escalated away from this resolver
    uint256 averageResolutionTime;
    uint256 lastResolutionTimestamp;
    uint256 qualityScore; // 0-10000 (basis points)
}

mapping(address => ResolverStats) public resolverStats;

function recordResolution(
    uint256 workflowId,
    address resolver,
    bool wasEscalated
) external onlyEscrowContract {
    ResolverStats storage stats = resolverStats[resolver];
    
    if (wasEscalated) {
        stats.disputesEscalated++;
    } else {
        stats.disputesResolved++;
    }
    
    // Update quality score (simplified)
    uint256 total = stats.disputesResolved + stats.disputesEscalated;
    if (total > 0) {
        stats.qualityScore = (stats.disputesResolved * 10000) / total;
    }
    
    stats.lastResolutionTimestamp = block.timestamp;
}
```

**Benefits**:
- Track resolver performance
- Enable quality-based selection in future
- Data for governance decisions

---

### 1.6 Batch Operations

**Issue**: No batch operations for common tasks

**Problem**:
- Gas inefficient for multiple operations
- Slow for bulk resolver management
- Poor UX for governance

**Proposal**:
```solidity
function batchAppointResolvers(
    address[] calldata resolvers,
    string[] calldata names,
    string[] calldata descriptions
) external onlySeniorResolver {
    require(
        resolvers.length == names.length && 
        names.length == descriptions.length,
        "Array length mismatch"
    );
    
    for (uint256 i = 0; i < resolvers.length; i++) {
        appointResolver(resolvers[i], names[i], descriptions[i]);
    }
}

function batchRemoveResolvers(address[] calldata resolvers) external {
    for (uint256 i = 0; i < resolvers.length; i++) {
        removeResolver(resolvers[i]);
    }
}
```

**Benefits**:
- Gas efficient
- Better governance UX
- Faster setup

---

## 2. Code Quality Improvements

### 2.1 Gas Optimization

#### Issue 1: Array Iteration in `removeResolver`

**Current**:
```solidity
for (uint256 i = 0; i < approvedResolvers.length; i++) {
    if (approvedResolvers[i] == resolver) {
        approvedResolvers[i] = approvedResolvers[approvedResolvers.length - 1];
        approvedResolvers.pop();
        break;
    }
}
```

**Problem**: O(n) iteration, can be expensive for large arrays

**Proposal**:
```solidity
mapping(address => uint256) public resolverIndex; // Resolver => index in array

function removeResolver(address resolver) external {
    // ... existing checks ...
    
    uint256 index = resolverIndex[resolver];
    uint256 lastIndex = approvedResolvers.length - 1;
    
    if (index != lastIndex) {
        address lastResolver = approvedResolvers[lastIndex];
        approvedResolvers[index] = lastResolver;
        resolverIndex[lastResolver] = index;
    }
    
    approvedResolvers.pop();
    delete resolverIndex[resolver];
    
    // ... rest of code ...
}
```

**Benefits**: O(1) removal instead of O(n)

---

#### Issue 2: External Call in `executeEscalation`

**Current**: `executeEscalation` calls `this.canEscalate()` (external call)

**Problem**: Unnecessary external call overhead, more gas

**Proposal**:
```solidity
function executeEscalation(
    uint256 workflowId,
    bytes calldata escrowData
) external override nonReentrant returns (
    bool success,
    address newResolver,
    uint8 newLevel
) {
    DisputeMetadata storage dm = disputeMetadata[workflowId];
    uint8 currentLevel = dm.escalationLevel;
    uint8 nextLevel = currentLevel + 1;
    
    // Inline escalation check instead of external call
    if (nextLevel > 2) {
        return (false, address(0), currentLevel);
    }
    
    EscalationConfig memory config = escalationConfig[nextLevel];
    if (!config.enabled) {
        return (false, address(0), 0);
    }
    
    // Determine next resolver (inline logic from canEscalate)
    address nextResolver;
    if (nextLevel == 1) {
        bytes32 category = escrowCategory[workflowId];
        if (approvedSeniorResolvers.length > 0) {
            nextResolver = selectResolverRoundRobin(category, true);
            if (nextResolver == address(0)) {
                return (false, address(0), 0);
            }
        } else {
            return (false, address(0), 0);
        }
    } else if (nextLevel == 2) {
        nextResolver = externalResolver;
        if (nextResolver == address(0)) {
            return (false, address(0), 0);
        }
    } else {
        nextResolver = config.resolver;
    }
    
    // ... rest of function ...
}
```

**Benefits**: Eliminates external call, saves ~2100 gas per escalation

---

#### Issue 3: Redundant Storage Reads

**Current**: Multiple storage reads in `selectResolverRoundRobin`

**Proposal**:
```solidity
function selectResolverRoundRobin(bytes32 category, bool useSeniorResolvers)
    internal view returns (address selectedResolver)
{
    // Cache resolver list
    address[] storage resolverList = useSeniorResolvers 
        ? approvedSeniorResolvers 
        : approvedResolvers;
    
    uint256 length = resolverList.length;
    if (length == 0) return address(0);
    
    // Single storage read for index
    uint256 currentIndex = useSeniorResolvers 
        ? categorySeniorResolverIndex[category] 
        : categoryResolverIndex[category];
    
    return resolverList[currentIndex % length];
}
```

**Benefits**: Fewer storage reads, lower gas

---

### 2.2 Security Improvements

#### Issue 1: Missing Zero Address Checks

**Current**: Some functions don't validate zero addresses

**Proposal**:
```solidity
function setIncentiveModule(address _incentiveModule) external onlyRole(ROLE_TIMELOCK) {
    // Allow zero address to disable, but validate if non-zero
    if (_incentiveModule != address(0)) {
        require(
            _incentiveModule.code.length > 0,
            "Not a contract"
        );
    }
    
    address oldModule = address(incentiveModule);
    incentiveModule = ResolverIncentiveModule(_incentiveModule);
    emit IncentiveModuleUpdated(oldModule, _incentiveModule);
}
```

---

#### Issue 2: Reentrancy in Payment Distribution

**Current**: `onDisputeResolved` uses `nonReentrant` but could be improved

**Proposal**: Already has `nonReentrant`, but add checks-effects-interactions validation:
```solidity
function onDisputeResolved(uint256 workflowId, address token)
    external onlyEscrowContract nonReentrant 
{
    // Checks
    require(token != address(0), "Zero token");
    require(!disputePaymentsDistributed[workflowId], "Payments already distributed");
    
    // Effects (state changes before external calls)
    disputePaymentsDistributed[workflowId] = true;
    
    // Interactions (external calls last)
    // ... payment calculation and distribution ...
}
```

**Status**: Already implemented correctly ✓

---

#### Issue 4: Front-Running in Round-Robin

**Issue**: Resolver selection can be front-run

**Problem**: Attacker could predict next resolver and manipulate selection

**Proposal**: Add commit-reveal or use blockhash:
```solidity
function selectResolverRoundRobin(bytes32 category, bool useSeniorResolvers)
    internal view returns (address selectedResolver)
{
    // ... existing code ...
    
    // Add randomness from blockhash to prevent front-running
    uint256 randomOffset = uint256(keccak256(abi.encodePacked(
        blockhash(block.number - 1),
        category,
        block.timestamp
    ))) % resolverList.length;
    
    uint256 index = (currentIndex + randomOffset) % resolverList.length;
    return resolverList[index];
}
```

**Trade-off**: Less predictable but more fair

---

### 2.3 Error Handling & Validation

#### Issue 1: Silent Failures in Incentive Module Calls

**Current**: Try-catch silently fails

**Problem**: Failures are hidden, hard to debug

**Proposal**:
```solidity
if (address(incentiveModule) != address(0)) {
    try incentiveModule.recordResolver(workflowId, resolver, 0) {
        // Success
    } catch Error(string memory reason) {
        emit IncentiveModuleCallFailed(workflowId, "recordResolver", reason);
    } catch (bytes memory lowLevelData) {
        emit IncentiveModuleCallFailed(workflowId, "recordResolver", "Low-level error");
    }
}
```

**Benefits**: Better observability, easier debugging

---

#### Issue 2: Missing Input Validation

**Current**: Some functions lack comprehensive validation

**Proposal**:
```solidity
function recordEscalationFee(
    uint256 workflowId,
    address token,
    uint256 amount
) external onlyEscrowContract {
    require(token != address(0), "Zero token");
    require(amount > 0, "Zero amount");
    require(amount < type(uint256).max / 2, "Amount too large"); // Prevent overflow
    
    // Check if dispute exists
    require(
        disputeResolvers[workflowId].length > 0,
        "Dispute not initialized"
    );
    
    disputeEscalationFees[workflowId] += amount;
    emit EscalationFeeRecorded(workflowId, token, amount);
}
```

---

### 2.4 Code Organization & Maintainability

#### Issue 1: Large Contract Size

**Current**: DecentralizedResolutionModule is 813 lines

**Problem**: Close to contract size limit, harder to maintain

**Proposal**: Split into multiple contracts:
```solidity
// ResolverRegistry.sol - Resolver management
contract ResolverRegistry {
    // Resolver appointment, removal, metadata
}

// EscalationManager.sol - Escalation logic
contract EscalationManager {
    // Escalation paths, configuration
}

// ResolutionTable.sol - Category management
contract ResolutionTable {
    // Category assignment, resolution table
}

// DecentralizedResolutionModule.sol - Orchestrator
contract DecentralizedResolutionModule is 
    ResolverRegistry, 
    EscalationManager, 
    ResolutionTable 
{
    // Main logic, coordinates sub-modules
}
```

**Benefits**: Better organization, easier testing, smaller contracts

---

#### Issue 2: Magic Numbers

**Current**: Hard-coded values like `level <= 2`, `10000` (basis points)

**Proposal**:
```solidity
uint8 public constant MAX_ESCALATION_LEVEL = 2;
uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
uint256 public constant DEFAULT_DISPUTE_TIMEOUT = 7 days;
```

**Benefits**: More maintainable, self-documenting

---

#### Issue 3: Inconsistent Naming

**Current**: Mix of `workflowId` and `escrowId` in comments

**Proposal**: Standardize on `workflowId` throughout (already mostly done)

---

### 2.5 Event Completeness

#### Issue: Missing Events for State Changes

**Current**: Some state changes don't emit events

**Proposal**:
```solidity
event RoundRobinCounterAdvanced(
    bytes32 indexed category,
    bool seniorResolvers,
    uint256 newIndex
);

function advanceRoundRobinCounter(bytes32 category, bool useSeniorResolvers) 
    internal 
{
    // ... existing code ...
    
    emit RoundRobinCounterAdvanced(category, useSeniorResolvers, newIndex);
}
```

**Benefits**: Better off-chain tracking, transparency

---

### 2.6 Payment Calculation Improvements

#### Issue 1: Rounding Errors

**Current**: Remainder goes to first resolver

**Problem**: Unfair if first resolver is different each time

**Proposal**: Distribute remainder proportionally:
```solidity
// Distribute remainder proportionally
if (paymentSum < resolverShare) {
    uint256 remainder = resolverShare - paymentSum;
    uint256 distributed = 0;
    
    for (uint256 i = 0; i < payments.length && distributed < remainder; i++) {
        uint256 add = (remainder - distributed) / (payments.length - i);
        payments[i] += add;
        distributed += add;
    }
    
    // Any final remainder to last resolver
    if (distributed < remainder) {
        payments[payments.length - 1] += (remainder - distributed);
    }
}
```

---

#### Issue 2: Zero Payment Handling

**Current**: Zero payments are skipped silently

**Proposal**: Emit event for zero payments:
```solidity
if (output.payments[i] > 0 && output.resolvers[i] != address(0)) {
    tokenContract.safeTransfer(output.resolvers[i], output.payments[i]);
} else {
    emit ZeroPaymentSkipped(workflowId, output.resolvers[i]);
}
```

---

## 3. Integration Improvements

### 3.1 Better Escrow Contract Integration

**Issue**: Escrow contracts must manually call multiple functions

**Proposal**: Add helper function in escrow contract:
```solidity
function _initializeDisputeWithIncentive(uint256 workflowId) internal {
    // Initialize in resolution module
    if (address(resolutionModule) != address(0)) {
        bytes memory escrowData = _encodeResolutionData(...);
        (address resolver, ) = IResolutionModule(resolutionModule).getResolver(
            workflowId, 
            escrowData
        );
        
        // Get category
        bytes32 category = IResolutionModule(resolutionModule).autoCategorizeEscrow(escrowData);
        
        // Initialize dispute
        IResolutionModule(resolutionModule).initializeDispute(
            workflowId, 
            resolver, 
            category
        );
    }
    
    // Record fees in incentive module
    if (address(incentiveModule) != address(0)) {
        uint256 fee = calculateEscrowFee(et.totalDeposited);
        incentiveModule.recordEscrowFee(workflowId, et.token, fee);
    }
}
```

---

## 4. Priority Recommendations

### High Priority (Security & Critical Functionality)

1. ✅ **Add resolver active status checks** - Prevents assignment to inactive resolvers
2. ✅ **Improve error handling** - Better observability
3. ✅ **Add input validation** - Prevent edge cases
4. ✅ **Gas optimization for array removal** - O(1) instead of O(n)
5. ✅ **Remove external call in executeEscalation** - Inline canEscalate logic, save ~2100 gas

### Medium Priority (Usability & Efficiency)

5. ✅ **Dispute timeout mechanism** - Prevent stalling
6. ✅ **Batch operations** - Better governance UX
7. ✅ **Resolver capacity tracking** - Workload balancing
8. ✅ **Auto-categorization** - Less manual work

### Low Priority (Nice to Have)

9. ✅ **Resolver reputation system** - Future quality-based selection
10. ✅ **Contract size reduction** - Split into modules
11. ✅ **Additional events** - Better tracking
12. ✅ **Proportional remainder distribution** - Fairer payments

---

## 5. Implementation Notes

### Breaking Changes

Most improvements are **non-breaking** and can be added incrementally:
- New functions (additive)
- New state variables (additive)
- Enhanced validation (more restrictive, but safer)

### Migration Path

1. **Phase 1**: Add new features (resolver active status, capacity)
2. **Phase 2**: Optimize existing code (gas improvements)
3. **Phase 3**: Refactor if needed (contract splitting)

### Testing Considerations

- Test resolver selection with inactive resolvers
- Test dispute timeout scenarios
- Test batch operations
- Test gas costs before/after optimizations

---

## 6. Summary

### Real-World Use
- ✅ Resolver availability checks
- ✅ Workload balancing
- ✅ Dispute timeouts
- ✅ Auto-categorization
- ✅ Batch operations
- ✅ Reputation tracking

### Code Quality
- ✅ Gas optimizations
- ✅ Security hardening
- ✅ Better error handling
- ✅ Code organization
- ✅ Event completeness
- ✅ Input validation

**Estimated Impact**:
- **Gas Savings**: 25-35% for common operations (especially escalation)
- **Security**: Improved with additional validations
- **Usability**: Significantly better for production use
- **Maintainability**: Better organized, easier to extend

---

## 7. Additional Critical Issues Found

### 7.1 Payment Distribution Token Balance Check

**Issue**: `onDisputeResolved` doesn't check if contract has sufficient token balance

**Current**: Assumes tokens are already in contract

**Problem**: Will revert with unclear error if insufficient balance

**Proposal**:
```solidity
function onDisputeResolved(uint256 workflowId, address token)
    external onlyEscrowContract nonReentrant 
{
    // ... existing checks ...
    
    // Calculate payments
    PaymentOutput memory output = calculatePaymentsWithVersion(input);
    
    // Check contract has sufficient balance
    IERC20 tokenContract = IERC20(token);
    uint256 contractBalance = tokenContract.balanceOf(address(this));
    require(contractBalance >= output.totalResolverShare, "Insufficient balance");
    
    // Mark as distributed before external calls
    disputePaymentsDistributed[workflowId] = true;
    
    // Distribute payments
    distributePayments(workflowId, token, output);
}
```

---

### 7.2 Resolver Removal During Active Dispute

**Issue**: Resolvers can be removed while they have active disputes

**Problem**: 
- Removed resolver might still be assigned to disputes
- No way to reassign active disputes
- Could lead to stuck disputes

**Proposal**:
```solidity
mapping(address => uint256) public resolverActiveDisputes;

function removeResolver(address resolver) external {
    require(isApprovedResolver[resolver], "Not a resolver");
    require(
        resolverMetadata[resolver].appointedBy == _msgSender() || 
        hasRole(ROLE_TIMELOCK, _msgSender()),
        "Not authorized to remove"
    );
    
    // Check if resolver has active disputes
    require(
        resolverActiveDisputes[resolver] == 0,
        "Resolver has active disputes"
    );
    
    // ... rest of removal logic ...
}

// Track active disputes
function initializeDispute(...) external onlyEscrowContract {
    // ... existing code ...
    
    resolverActiveDisputes[resolver]++;
}

// Decrement when dispute resolved
// (Would need to be called from escrow contract or incentive module)
```

---

### 7.3 Category Key Collision Risk

**Issue**: `generateCategoryKey` uses simple hash - potential collisions

**Current**:
```solidity
keccak256(abi.encodePacked(token, amount, categoryType))
```

**Problem**: Different inputs could hash to same category

**Proposal**: Use more robust hashing:
```solidity
function generateCategoryKey(
    address token,
    uint256 amount,
    string memory categoryType
) external pure returns (bytes32) {
    // Use abi.encode instead of abi.encodePacked for better collision resistance
    return keccak256(abi.encode(token, amount, categoryType));
}
```

**Note**: `abi.encodePacked` can have collisions, `abi.encode` is safer

---

### 7.4 Token Transfer Pattern for Payments

**Issue**: Unclear how tokens get to incentive module for distribution

**Current**: Incentive module transfers from its own balance

**Problem**: 
- Escrow contract must transfer tokens to incentive module first
- Not clear from integration guide
- Easy to forget, causing payment failures

**Proposal**: Add pull pattern or make transfer explicit:
```solidity
// Option 1: Pull pattern (incentive module pulls from escrow)
function onDisputeResolved(uint256 workflowId, address token)
    external onlyEscrowContract nonReentrant 
{
    // ... calculate payments ...
    
    // Pull tokens from escrow contract
    IERC20(token).safeTransferFrom(_msgSender(), address(this), output.totalResolverShare);
    
    // Distribute
    distributePayments(workflowId, token, output);
}

// Option 2: Explicit transfer requirement (better error message)
function onDisputeResolved(uint256 workflowId, address token, uint256 amountToTransfer)
    external onlyEscrowContract nonReentrant 
{
    // ... calculate payments ...
    
    require(amountToTransfer >= output.totalResolverShare, "Insufficient transfer");
    
    // Transfer from caller (escrow contract)
    IERC20(token).safeTransferFrom(_msgSender(), address(this), output.totalResolverShare);
    
    // Distribute
    distributePayments(workflowId, token, output);
}
```

**Benefits**: Clearer integration, better error messages

---

### 7.5 Missing Validation in Payment Calculation

**Issue**: Payment calculation doesn't validate resolver addresses are unique

**Problem**: Same resolver could be recorded multiple times with different levels

**Proposal**:
```solidity
function calculatePayments(PaymentInput memory input)
    external pure override returns (PaymentOutput memory output)
{
    // ... existing validation ...
    
    // Check for duplicate resolvers (same address, different levels are OK)
    // But validate addresses are not zero
    for (uint256 i = 0; i < input.resolvers.length; i++) {
        require(input.resolvers[i].resolver != address(0), "Zero resolver address");
    }
    
    // ... rest of calculation ...
}
```

---

*This proposal focuses on practical improvements that enhance both security and usability while maintaining backward compatibility where possible.*

