# Aave Integration & Per-Escrow Settings Implementation Plan

## Table of Contents
1. [Refactoring Prerequisites](#refactoring-prerequisites)
2. [Aave Vault Integration](#aave-vault-integration)
3. [Yield Distribution System](#yield-distribution-system)
4. [Per-Escrow Settings](#per-escrow-settings)
5. [Refund Problem Analysis](#refund-problem-analysis)
6. [Implementation Phases](#implementation-phases)

---

## 1. Refactoring Prerequisites

### 1.1 Extend EscrowTransfer Struct
**Priority: CRITICAL - Must be done first**

Current struct is missing fields needed for new features. We need to add:

```solidity
struct EscrowTransfer {
    // ... existing fields ...
    
    // NEW FIELDS:
    EscrowSettings settings;  // Per-escrow settings (see below)
    uint256 aTokenBalance;     // Track aToken balance for this escrow
    uint256 yieldAccrued;      // Track yield accrued (for accounting)
    bool yieldEnabled;         // Quick check if yield is enabled
}
```

**Alternative Approach (Gas Optimization):**
Instead of adding to struct, use separate mappings:
```solidity
mapping(uint256 => EscrowSettings) public escrowSettings;
mapping(uint256 => uint256) public aTokenBalances;
mapping(uint256 => uint256) public yieldAccrued;
```

**Recommendation:** Use separate mappings for gas efficiency and to avoid breaking existing struct layout.

### 1.2 Create EscrowSettings Struct
```solidity
struct EscrowSettings {
    address customResolver;     // Override default resolver (address(0) = use default)
    bool yieldEnabled;          // Opt-in for yield generation
    uint256 autoReleaseTime;    // Custom release time (0 = use default)
    uint256 autoCancelTime;     // Custom cancel time (0 = use default)
    EscrowType escrowType;      // For future extensibility
    YieldDistribution yieldDistribution; // Per-escrow yield distribution
}

enum EscrowType {
    STANDARD,      // Default escrow
    MILESTONE,     // Future: milestone-based releases
    RECURRING,     // Future: recurring payments
    CUSTOM         // Future: custom logic
}
```

### 1.3 Refactor Escrow Creation Functions
**Current Issue:** Multiple functions with overlapping parameters (`escrowTransfer`, `timedEscrowTransfer`)

**Proposed Solution:** Consolidate into single function with settings parameter:
```solidity
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public nonReentrant whenNotPaused returns (uint256)
```

**Backward Compatibility:** Keep existing functions as wrappers that call `createEscrow` with default settings.

---

## 2. Aave Vault Integration

### 2.1 Aave Integration Architecture

#### 2.1.1 Required Aave Interfaces
```solidity
import "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@aave/core-v3/contracts/interfaces/IAToken.sol";
```

#### 2.1.2 State Variables
```solidity
// Aave Pool
IPoolAddressesProvider public aavePoolAddressesProvider;
IPool public aavePool;

// Track Aave deposits per token
mapping(address => uint256) public totalDepositedToAave; // token => total amount
mapping(address => address) public tokenToAToken; // token => aToken address

// Per-escrow Aave tracking
mapping(uint256 => bool) public escrowInAave; // workflowId => is in Aave
mapping(uint256 => uint256) public escrowATokenBalance; // workflowId => aToken balance
```

### 2.2 Deposit to Aave Flow

#### 2.2.1 When Escrow is Created with Yield Enabled
```solidity
function _depositToAave(uint256 workflowId, address token, uint256 amount) internal {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Validate token is supported by Aave
    address aToken = tokenToAToken[token];
    require(aToken != address(0), "Token not supported by Aave");
    
    // Approve Aave Pool
    IERC20(token).safeApprove(address(aavePool), amount);
    
    // Deposit to Aave
    aavePool.supply(token, amount, address(this), 0);
    
    // Track deposit
    escrowInAave[workflowId] = true;
    uint256 aTokenBalance = IAToken(aToken).balanceOf(address(this));
    escrowATokenBalance[workflowId] = aTokenBalance;
    totalDepositedToAave[token] += amount;
    
    emit EscrowDepositedToAave(workflowId, token, amount, aTokenBalance);
}
```

#### 2.2.2 Token Support Validation
- Need to check if token is supported by Aave Pool
- Store aToken address mapping
- Handle unsupported tokens gracefully (revert or skip Aave)

### 2.3 Withdraw from Aave Flow

#### 2.3.1 When Escrow is Closed (Release/Cancel)
```solidity
function _withdrawFromAave(uint256 workflowId, address token, uint256 amount) internal returns (uint256) {
    if (!escrowInAave[workflowId]) {
        return amount; // Not in Aave, return original amount
    }
    
    address aToken = tokenToAToken[token];
    uint256 aTokenBalance = escrowATokenBalance[workflowId];
    
    // Calculate actual amount (aTokens may have appreciated)
    uint256 actualAmount = aavePool.withdraw(token, aTokenBalance, address(this));
    
    // Calculate yield
    uint256 yield = actualAmount > amount ? actualAmount - amount : 0;
    
    // Update tracking
    escrowInAave[workflowId] = false;
    escrowATokenBalance[workflowId] = 0;
    totalDepositedToAave[token] -= amount; // Subtract original, not actual
    
    emit EscrowWithdrawnFromAave(workflowId, token, amount, actualAmount, yield);
    
    return actualAmount;
}
```

**Critical Consideration:** 
- aToken balance may have changed due to yield
- Need to track original deposit vs current aToken balance
- Handle rounding errors and dust

### 2.4 Yield Calculation

#### 2.4.1 Calculate Yield on Close
```solidity
function _calculateYield(uint256 workflowId, address token) internal view returns (uint256) {
    if (!escrowInAave[workflowId]) {
        return 0;
    }
    
    address aToken = tokenToAToken[token];
    uint256 currentATokenBalance = IAToken(aToken).balanceOf(address(this));
    uint256 originalAmount = escrowTransfers[workflowId].amount;
    
    // Yield = current balance - original amount
    // Note: This is approximate as we need to track per-escrow aToken balance
    // Better approach: Track aToken balance at deposit time
    uint256 aTokenAtDeposit = escrowATokenBalance[workflowId];
    uint256 yield = currentATokenBalance > aTokenAtDeposit 
        ? currentATokenBalance - aTokenAtDeposit 
        : 0;
    
    return yield;
}
```

**Problem:** Aave deposits are pooled, so we can't track individual escrow aToken balances easily.

**Solution Options:**
1. **Separate Aave deposits per escrow** (gas expensive, complex)
2. **Track aToken balance at deposit** and calculate yield on withdrawal
3. **Use Aave's interest rate model** to calculate yield (complex, requires oracle)
4. **Track total aTokens and pro-rate** (simpler but less accurate)

**Recommended:** Option 2 - Track aToken balance at deposit, calculate yield on withdrawal.

---

## 3. Yield Distribution System

### 3.1 Yield Distribution Structure

```solidity
struct YieldDistribution {
    address[] recipients;      // Addresses to receive yield
    uint256[] percentages;     // Percentage per recipient (basis points, sum to 10000)
    bool isSet;               // Whether distribution is configured
}

// Global default yield distribution
YieldDistribution public defaultYieldDistribution;

// Per-escrow yield distribution (overrides default)
mapping(uint256 => YieldDistribution) public escrowYieldDistribution;
```

### 3.2 Yield Distribution Logic

#### 3.2.1 Distribute Yield on Escrow Close
```solidity
function _distributeYield(uint256 workflowId, address token, uint256 yieldAmount) internal {
    if (yieldAmount == 0) {
        return;
    }
    
    EscrowTransfer storage et = escrowTransfers[workflowId];
    YieldDistribution memory distribution;
    
    // Check if escrow has custom distribution, otherwise use default
    if (escrowYieldDistribution[workflowId].isSet) {
        distribution = escrowYieldDistribution[workflowId];
    } else {
        distribution = defaultYieldDistribution;
    }
    
    // Validate distribution exists
    if (!distribution.isSet || distribution.recipients.length == 0) {
        // No distribution configured, yield stays in contract (or goes to fee address)
        // Option: revert, or send to fee address, or accumulate
        return;
    }
    
    // Validate percentages sum to 100%
    uint256 totalPercentage = 0;
    for (uint256 i = 0; i < distribution.percentages.length; i++) {
        totalPercentage += distribution.percentages[i];
    }
    require(totalPercentage == 10000, "Invalid yield distribution percentages");
    
    // Distribute yield
    for (uint256 i = 0; i < distribution.recipients.length; i++) {
        uint256 share = (yieldAmount * distribution.percentages[i]) / 10000;
        if (share > 0) {
            IERC20(token).safeTransfer(distribution.recipients[i], share);
            emit YieldDistributed(workflowId, distribution.recipients[i], share);
        }
    }
}
```

### 3.3 Setting Yield Distribution

#### 3.3.1 Global Default
```solidity
function setDefaultYieldDistribution(
    address[] memory recipients,
    uint256[] memory percentages
) public onlyOwner {
    _validateYieldDistribution(recipients, percentages);
    defaultYieldDistribution = YieldDistribution({
        recipients: recipients,
        percentages: percentages,
        isSet: true
    });
    emit DefaultYieldDistributionUpdated(recipients, percentages);
}
```

#### 3.3.2 Per-Escrow (in Settings)
```solidity
// Set when creating escrow or update later
function setEscrowYieldDistribution(
    uint256 workflowId,
    address[] memory recipients,
    uint256[] memory percentages
) public {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    require(et.from == _msgSender() || _msgSender() == owner(), "Not authorized");
    require(et.escrowTransferStatus == EscrowTransferStatus.PENDING, "Escrow not pending");
    
    _validateYieldDistribution(recipients, percentages);
    escrowYieldDistribution[workflowId] = YieldDistribution({
        recipients: recipients,
        percentages: percentages,
        isSet: true
    });
    emit EscrowYieldDistributionUpdated(workflowId, recipients, percentages);
}
```

---

## 4. Per-Escrow Settings

### 4.1 Settings Structure (Revisited)

```solidity
struct EscrowSettings {
    address customResolver;           // address(0) = use default
    bool yieldEnabled;                // Opt-in for Aave yield
    uint256 autoReleaseTime;          // 0 = use default
    uint256 autoCancelTime;           // 0 = use default
    EscrowType escrowType;            // For future extensibility
    YieldDistribution yieldDistribution; // Optional per-escrow yield distribution
}
```

### 4.2 Settings Application

#### 4.2.1 On Escrow Creation
```solidity
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public nonReentrant whenNotPaused returns (uint256) {
    // ... validation ...
    
    // Create escrow with settings
    uint256 workflowId = _createEscrowInternal(token, to, amount, settings);
    
    // Apply settings
    if (settings.yieldEnabled) {
        // Check if token is supported
        address aToken = tokenToAToken[token];
        if (aToken != address(0)) {
            _depositToAave(workflowId, token, amountAfterFee);
        } else {
            // Token not supported, revert or disable yield?
            revert("Token not supported for yield generation");
        }
    }
    
    // Store settings
    escrowSettings[workflowId] = settings;
    
    // Apply custom resolver
    if (settings.customResolver != address(0)) {
        escrowTransfers[workflowId].disputeResolver = settings.customResolver;
    }
    
    // Apply custom times
    if (settings.autoReleaseTime > 0) {
        escrowTransfers[workflowId].autoReleaseTime = settings.autoReleaseTime;
    }
    if (settings.autoCancelTime > 0) {
        escrowTransfers[workflowId].autoCancelTime = settings.autoCancelTime;
    }
    
    return workflowId;
}
```

### 4.3 Backward Compatibility

Keep existing functions as wrappers:
```solidity
function escrowTransfer(address token, address to, uint256 amount) 
    public returns (uint256) 
{
    EscrowSettings memory defaultSettings = EscrowSettings({
        customResolver: address(0),
        yieldEnabled: false,
        autoReleaseTime: 0,
        autoCancelTime: 0,
        escrowType: EscrowType.STANDARD,
        yieldDistribution: YieldDistribution({
            recipients: new address[](0),
            percentages: new uint256[](0),
            isSet: false
        })
    });
    return createEscrow(token, to, amount, defaultSettings);
}
```

---

## 5. Refund Problem Analysis

### 5.1 Current Refund Implementation Issues

#### 5.1.1 **Problem: No Yield on Refunds**
**Current Behavior:** When escrow is cancelled, only original amount is refunded.

**Issue:** If yield was generated, sender loses yield on cancellation.

**Options:**
1. **Refund original amount only** (current) - Simple, but unfair if yield was generated
2. **Refund with yield** - Fair, but recipient might expect yield
3. **Distribute yield on cancellation** - Complex, who gets it?

**Recommendation:** Make it configurable via settings:
- `refundWithYield: bool` - If true, refund includes yield (distributed per yield distribution)
- Default: `false` (refund original only)

#### 5.1.2 **Problem: Aave Withdrawal Failures**
**Scenario:** Aave protocol has issues, withdrawal fails.

**Current Risk:** Escrow cannot be closed, funds stuck.

**Mitigation:**
1. **Try-catch wrapper** - If Aave fails, fallback to direct transfer (if tokens still in contract)
2. **Emergency withdrawal function** - Owner can force withdrawal
3. **Circuit breaker** - Pause Aave deposits if issues detected

**Implementation:**
```solidity
function _withdrawFromAaveSafe(uint256 workflowId, address token, uint256 amount) internal returns (uint256) {
    if (!escrowInAave[workflowId]) {
        return amount;
    }
    
    try this._withdrawFromAave(workflowId, token, amount) returns (uint256 actualAmount) {
        return actualAmount;
    } catch {
        // Aave withdrawal failed
        // Check if we have tokens in contract (shouldn't happen, but safety)
        uint256 contractBalance = IERC20(token).balanceOf(address(this));
        if (contractBalance >= amount) {
            emit AaveWithdrawalFailed(workflowId, token);
            return amount; // Return original amount
        } else {
            revert("Aave withdrawal failed and insufficient contract balance");
        }
    }
}
```

#### 5.1.3 **Problem: Partial Refunds with Yield**
**Scenario:** Resolver does partial cancel, escrow has yield.

**Current Behavior:** Partial amount refunded, yield calculation unclear.

**Issues:**
- How to calculate yield for partial amount?
- Should yield be distributed proportionally?
- What if only part of escrow was in Aave?

**Solution:**
```solidity
function resolverPartialCancel(uint256 workflowId, uint256 amount) public nonReentrant returns (bool) {
    // ... existing validation ...
    
    EscrowTransfer storage et = escrowTransfers[workflowId];
    address token = et.token;
    
    // Calculate proportional yield if in Aave
    uint256 yieldToDistribute = 0;
    if (escrowInAave[workflowId]) {
        uint256 totalYield = _calculateYield(workflowId, token);
        // Proportional yield = (amount / total) * totalYield
        yieldToDistribute = (totalYield * amount) / et.amount;
    }
    
    // Withdraw from Aave (proportional)
    uint256 actualAmount = _withdrawFromAaveProportional(workflowId, token, amount);
    
    // Update escrow
    et.amount -= amount;
    _updateEscrowBalance(token, amount, false);
    
    // Distribute yield if any
    if (yieldToDistribute > 0) {
        _distributeYield(workflowId, token, yieldToDistribute);
    }
    
    // Refund
    _transferTokens(token, et.from, actualAmount);
    
    // ... rest of logic ...
}
```

#### 5.1.4 **Problem: Yield Distribution Failures**
**Scenario:** One recipient in yield distribution fails (revert, zero address, etc.)

**Current Risk:** Entire distribution fails, yield stuck.

**Solution:**
```solidity
function _distributeYieldSafe(uint256 workflowId, address token, uint256 yieldAmount) internal {
    // ... get distribution ...
    
    uint256 totalDistributed = 0;
    for (uint256 i = 0; i < distribution.recipients.length; i++) {
        address recipient = distribution.recipients[i];
        if (recipient == address(0)) {
            continue; // Skip zero address
        }
        
        uint256 share = (yieldAmount * distribution.percentages[i]) / 10000;
        if (share > 0) {
            try IERC20(token).safeTransfer(recipient, share) {
                totalDistributed += share;
                emit YieldDistributed(workflowId, recipient, share);
            } catch {
                emit YieldDistributionFailed(workflowId, recipient, share);
                // Continue with other recipients
            }
        }
    }
    
    // Handle undistributed yield (send to fee address or accumulate)
    uint256 undistributed = yieldAmount - totalDistributed;
    if (undistributed > 0) {
        IERC20(token).safeTransfer(escrowFeeAddress, undistributed);
        emit UndistributedYieldSentToFeeAddress(workflowId, undistributed);
    }
}
```

#### 5.1.5 **Problem: Aave Token Support Changes**
**Scenario:** Token was supported when escrow created, but later removed from Aave.

**Risk:** Cannot withdraw from Aave.

**Mitigation:**
1. **Check on withdrawal** - If token no longer supported, handle gracefully
2. **Emergency migration** - Owner can migrate escrows out of Aave
3. **Monitor Aave changes** - Event listener for token support changes

#### 5.1.6 **Problem: Rounding Errors and Dust**
**Scenario:** Yield calculations result in dust amounts.

**Issues:**
- Distribution percentages might not sum exactly due to rounding
- Small amounts might be left undistributed

**Solution:**
- Use precise math (multiply before divide)
- Send remainder to fee address
- Minimum distribution threshold (skip if below threshold)

---

## 6. Implementation Phases

### Phase 1: Refactoring (Week 1)
**Priority: CRITICAL - Must complete before Aave integration**

1. ✅ Create `EscrowSettings` struct
2. ✅ Add settings mapping: `mapping(uint256 => EscrowSettings)`
3. ✅ Refactor `createEscrow` function with settings parameter
4. ✅ Maintain backward compatibility with wrapper functions
5. ✅ Add validation for settings
6. ✅ Update events to include settings
7. ✅ Add Aave tracking mappings (prepared for Phase 2)
8. ✅ Add YieldDistribution struct and infrastructure
9. ✅ Add Aave hook functions (virtual, to be implemented in Phase 2)
10. ✅ Integrate Aave hooks into release/cancel flows
11. ✅ Add yield distribution functions and validation

**Deliverables:**
- ✅ Updated `BaseEscrow.sol` with settings support
- ✅ Updated `EscrowableERC20.sol` and `EscrowVault.sol`
- ✅ Aave integration infrastructure (mappings, hooks, events)
- ✅ Yield distribution system (struct, validation, getters)
- ⏳ Tests for settings functionality (pending)
- ⏳ Migration guide for existing integrations (pending)

### Phase 2: Aave Integration Foundation (Week 2)
**Priority: HIGH**

1. ✅ Add Aave interfaces and dependencies
2. ✅ Add Aave state variables
3. ✅ Implement token support checking
4. ✅ Implement `_depositToAave` function
5. ✅ Implement `_withdrawFromAave` function (full and proportional)
6. ✅ Add Aave-related events
7. ✅ Add owner functions to configure Aave
8. ✅ Implement yield calculation logic
9. ✅ Implement yield distribution logic

**Deliverables:**
- ✅ Aave integration module
- ✅ Token support registry
- ✅ Deposit/withdraw functions
- ✅ Yield calculation and distribution
- ✅ Configuration functions
- ⏳ Basic tests (pending)

### Phase 3: Yield Calculation & Tracking (Week 2-3)
**Priority: HIGH**

1. ✅ Implement yield calculation logic
2. ✅ Track aToken balances per escrow
3. ✅ Handle yield on escrow close
4. ✅ Add yield-related events
5. ✅ Tests for yield calculation edge cases

**Deliverables:**
- Yield calculation functions
- Tracking system
- Tests

### Phase 4: Yield Distribution (Week 3)
**Priority: MEDIUM**

1. ✅ Create `YieldDistribution` struct
2. ✅ Implement global default distribution
3. ✅ Implement per-escrow distribution
4. ✅ Implement `_distributeYield` function
5. ✅ Add distribution validation
6. ✅ Handle distribution failures gracefully

**Deliverables:**
- Yield distribution system
- Configuration functions
- Tests

### Phase 5: Refund Improvements (Week 3-4)
**Priority: MEDIUM**

1. ✅ Implement refund with yield option
2. ✅ Handle Aave withdrawal failures
3. ✅ Implement partial refund with yield
4. ✅ Add emergency withdrawal functions
5. ✅ Add circuit breaker for Aave

**Deliverables:**
- Improved refund logic
- Safety mechanisms
- Tests

### Phase 6: Integration & Testing (Week 4)
**Priority: HIGH**

1. ✅ Integration tests for full flow
2. ✅ Gas optimization
3. ✅ Security audit preparation
4. ✅ Documentation
5. ✅ Migration scripts (if needed)

**Deliverables:**
- Complete test suite
- Gas reports
- Documentation
- Migration guide

---

## 7. Additional Considerations

### 7.1 Gas Optimization
- Batch Aave operations where possible
- Cache Aave Pool address
- Minimize storage writes
- Use events instead of storage for some data

### 7.2 Security
- Reentrancy guards (already in place)
- Access control for Aave configuration
- Validate all Aave interactions
- Handle Aave protocol upgrades

### 7.3 Upgradability
- Consider proxy pattern if settings structure might change
- Version settings struct for future changes
- Migration path for existing escrows

### 7.4 Monitoring
- Events for all Aave operations
- Events for yield distribution
- Error events for failures
- Metrics for yield generation

---

## 8. Open Questions

1. **Yield on Cancellation:** Should yield be distributed on cancellation, or only on release?
   - **Recommendation:** Configurable per escrow, default: only on release

   Yes also distributed on cancellation

2. **Unsupported Tokens:** What happens if user opts in for yield but token isn't supported?
   - **Recommendation:** Revert on creation, or disable yield silently with event

Disable yield silently with event

3. **Aave Protocol Risk:** Who bears risk if Aave has issues?
   - **Recommendation:** Clear documentation, consider insurance or disclaimer

Clear risk disclosure to user

4. **Yield Distribution Default:** What's the default if not set?
   - **Recommendation:** Send to fee address, or require explicit configuration

Require explicit configuration

5. **Partial Escrows in Aave:** Can we deposit only part of escrow to Aave?
   - **Recommendation:** No, all or nothing for simplicity

All or nothing
---

## 9. Next Steps

1. **Review and approve plan**
2. **Set up Aave test environment**
3. **Begin Phase 1 refactoring**
4. **Create detailed technical specifications**
5. **Set up testing infrastructure**

---

**Document Version:** 1.0  
**Last Updated:** [Current Date]  
**Status:** Draft - Pending Review

