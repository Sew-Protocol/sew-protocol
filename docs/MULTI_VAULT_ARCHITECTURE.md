# Multi-Vault Architecture: AaveYieldGenerationModule

## Overview

The system supports a **single AaveYieldGenerationModule managing multiple EscrowVault and EscrowableERC20 contracts**. This architecture enables:
- Centralized yield operations with decentralized escrow instances
- Shared liquidity pool for improved capital efficiency
- Per-vault fairness caps and global safety limits
- Unified governance across multiple vaults

## Architecture Components

### 1. Single Yield Module, Multiple Vaults

```
┌─────────────────────────────────────────────────────────────┐
│         AaveYieldGenerationModule (Singleton)               │
│  • Manages all Aave V3 interactions                         │
│  • Tracks per-vault deposits and shares                     │
│  • Enforces global and per-vault caps                       │
└────────────┬────────────────────────────────────────────────┘
             │
             │ Manages yield for multiple vaults
             │
     ┌───────┴──────┬──────────────┬─────────────┐
     │              │              │             │
┌────▼────┐  ┌─────▼─────┐  ┌────▼────┐  ┌─────▼──────┐
│ Vault 1 │  │  Vault 2  │  │ Vault 3 │  │ EscrowERC20│
└─────────┘  └───────────┘  └─────────┘  └────────────┘
   ↓              ↓              ↓              ↓
Escrows       Escrows        Escrows        Escrows
```

### 2. Storage Architecture

#### Per-Vault Tracking (Two-Dimensional Mappings)

```solidity
// Track which escrows are active in Aave
mapping(address => mapping(uint256 => bool)) public escrowInAave;
// escrowContract => workflowId => isActive

// Track scaled balance shares (non-rebasing Aave shares)
mapping(address => mapping(uint256 => uint256)) public escrowScaledBalance;
// escrowContract => workflowId => scaledShares

// Track original deposit amounts
mapping(address => mapping(uint256 => uint256)) public escrowOriginalDeposit;
// escrowContract => workflowId => depositAmount

// Track ERC-4626 shares minted per workflow
mapping(address => mapping(uint256 => uint256)) public escrowShares;
// escrowContract => workflowId => shares
```

#### Global Aggregate Tracking

```solidity
// Total deposited across all vaults
mapping(address => uint256) public totalDepositedToAave;

// Total scaled shares across all vaults
mapping(address => uint256) public totalScaledBalance;

// Cumulative yield generated (all-time, for auditing)
mapping(address => uint256) public totalYieldGenerated;
```

#### Two-Tier Exposure Caps

```solidity
// System Safety: Global cap across all vaults
mapping(address => uint256) public globalCap;

// Tenant Fairness: Per-vault caps
mapping(address => mapping(address => uint256)) public escrowCap;
// escrowContract => token => maxExposure

// Current exposure tracking
mapping(address => uint256) public currentExposure; // global
mapping(address => mapping(address => uint256)) public currentEscrowExposure; // per-vault
```

### 3. Key Operations Flow

#### Deposit Flow

```
1. Vault calls depositForYield(workflowId, token, amount)
   └─> msg.sender is the vault address

2. Module checks caps:
   ├─> Global cap: currentExposure[token] + amount <= globalCap[token]
   └─> Per-vault cap: currentEscrowExposure[vault][token] + amount <= escrowCap[vault][token]

3. Module pulls tokens and supplies to Aave:
   ├─> EscrowVault: Module pulls via safeTransferFrom, then supplies to Aave
   └─> EscrowableERC20: Token approves Aave directly, module calls supply

4. Module tracks the deposit:
   ├─> Record scaled balance shares: escrowScaledBalance[vault][workflowId]
   ├─> Record original amount: escrowOriginalDeposit[vault][workflowId]
   ├─> Update global totals: totalDepositedToAave[token], totalScaledBalance[token]
   └─> Update exposure: currentExposure[token], currentEscrowExposure[vault][token]
```

#### Withdrawal Flow

```
1. Vault calls withdrawWithYield(workflowId, token, originalAmount, escrowContract)

2. Module calculates current value using proportional shares:
   estimatedValue = (totalATokenBalance * escrowScaledBalance[vault][workflowId]) / totalScaledBalance[token]
   yield = estimatedValue - escrowOriginalDeposit[vault][workflowId]

3. Module withdraws from Aave and distributes:
   ├─> Calculate withdrawal amount (principal + yield)
   ├─> Withdraw from Aave pool
   └─> Transfer to escrow contract

4. Module clears per-vault state:
   ├─> Delete escrowInAave[vault][workflowId]
   ├─> Delete escrowScaledBalance[vault][workflowId]
   ├─> Delete escrowOriginalDeposit[vault][workflowId]
   ├─> Update global totals: totalDepositedToAave[token], totalScaledBalance[token]
   └─> Reduce exposure: currentExposure[token], currentEscrowExposure[vault][token]
```

#### Yield Calculation (View Function)

```solidity
function calculateYield(uint256 workflowId, address token, address escrowContract) 
    external view returns (uint256 yieldAmount) {
    
    // Get current total aToken balance held by module
    uint256 currentATokenBalance = IAaveAToken(aToken).balanceOf(address(this));
    
    // Get this escrow's share of the pool
    uint256 trackedScaledBalance = escrowScaledBalance[escrowContract][workflowId];
    uint256 totalScaled = totalScaledBalance[token];
    
    // Calculate proportional value: (total value * my shares) / total shares
    uint256 estimatedCurrentValue = (currentATokenBalance * trackedScaledBalance) / totalScaled;
    
    // Yield = current value - original deposit
    uint256 originalDeposit = escrowOriginalDeposit[escrowContract][workflowId];
    yieldAmount = estimatedCurrentValue > originalDeposit 
        ? estimatedCurrentValue - originalDeposit 
        : 0;
}
```

## Governance Model

### Role-Based Access Control

The module uses OpenZeppelin's AccessControl with three key roles:

```solidity
ROLE_TIMELOCK        // Primary governance authority (TimelockController)
ROLE_GUARDIAN        // Emergency pause/cap reduction
ROLE_ESCROW_CONTRACT // Authorized vault contracts
```

### Timelock Governance (ROLE_TIMELOCK)

**Powers:**
- Register/authorize new vault contracts: `registerEscrowContract(address vault)`
- Set global safety caps: `setGlobalCap(address token, uint256 cap)`
- Set per-vault fairness caps: `setEscrowCap(address vault, address token, uint256 cap)`
- Configure Aave pool integration: `queuePoolProviderUpdate()`, `activatePoolProvider()`
- Enable/disable Aave: `setAaveEnabled(bool enabled)`
- Register supported tokens: `addSupportedToken(address token, address aToken)`

**Slow-Lane Protection:**
- Aave pool provider changes use 7-day queue/activate pattern
- Prevents immediate compromise if timelock is attacked

### Guardian Governance (ROLE_GUARDIAN)

**Emergency Powers:**
- Immediately disable Aave: `guardianDisableAave()`
- Lower global caps: `guardianLowerGlobalCap(address token, uint256 newCap)`
- **Cannot raise caps or enable Aave** (prevents abuse)

**Use Cases:**
- Aave exploit detected → disable Aave immediately
- Unusual activity → reduce caps to limit exposure
- Bridge compromise → lower caps for affected token

### Multi-Vault Governance Flow

```
┌─────────────────────────────────────────────────────────┐
│  TimelockController (Controlled by SewToken DAO)        │
│  • Holds ROLE_TIMELOCK on all contracts                 │
└──────────────┬──────────────────────────────────────────┘
               │
               │ Governs
               │
┌──────────────▼────────────────────────────────────────┐
│  ModuleManagementContract (Singleton)                 │
│  • Registers vault contracts                          │
│  • Configures default modules per vault               │
│  • Uses slow-lane for module changes (7-day delay)    │
└──────────────┬────────────────────────────────────────┘
               │
               │ Wires modules to vaults
               │
┌──────────────▼────────────────────────────────────────┐
│  AaveYieldGenerationModule (Singleton)                │
│  • Receives ROLE_ESCROW_CONTRACT for each vault       │
│  • Enforces global + per-vault caps                   │
│  • Manages shared Aave pool for all vaults            │
└───────────────────────────────────────────────────────┘
```

### Governance Actions by Scenario

#### Adding a New Vault

```
1. Deploy new EscrowVault or EscrowableERC20 contract
2. Governance calls ModuleManagementContract.registerEscrowContract(vaultAddress)
   └─> Requires ROLE_TIMELOCK
3. Governance calls AaveYieldGenerationModule.registerEscrowContract(vaultAddress)
   └─> Grants ROLE_ESCROW_CONTRACT to vault
4. Governance sets per-vault cap:
   └─> AaveYieldGenerationModule.setEscrowCap(vaultAddress, token, cap)
5. Vault is now authorized to use yield module
```

#### Changing Module Configuration for One Vault

```
1. Governance calls ModuleManagementContract.queueDefaultYieldGenerationModule(vaultAddress, newModule)
   └─> Enters 7-day slow-lane queue
2. After 7 days, governance calls activateDefaultYieldGenerationModule(vaultAddress)
   └─> Module change takes effect for new escrows in that vault
3. Other vaults are unaffected
```

#### Adjusting Exposure Caps

```
Global Cap (affects all vaults):
  setGlobalCap(token, newCap)          // Timelock only
  guardianLowerGlobalCap(token, newCap) // Guardian (emergency, can only lower)

Per-Vault Cap (affects one vault):
  setEscrowCap(vault, token, newCap)   // Timelock only
```

#### Emergency Response

```
Scenario: Aave exploit detected

1. Guardian immediately disables Aave:
   └─> guardianDisableAave()
   └─> No new deposits accepted

2. Existing escrows can still withdraw:
   └─> withdrawWithYield() still functions
   └─> Recovers funds from Aave

3. Governance investigates and decides next steps:
   ├─> Upgrade to new Aave pool (slow-lane queue/activate)
   ├─> Deploy new yield module
   └─> Re-enable when safe
```

## Cap Enforcement Logic

### Two-Tier Cap System

```solidity
function _checkAndAccrueExposure(address escrowContract, address token, uint256 amount) internal {
    uint256 newExposure = currentExposure[token] + amount;

    // 1. System Safety: Global Cap Check
    uint256 globalCapValue = globalCap[token];
    if (globalCapValue > 0 && newExposure > globalCapValue) {
        revert CapExceeded(token, newExposure, globalCapValue);
    }

    // 2. Tenant Fairness: Per-Vault Cap Check
    uint256 vaultCap = escrowCap[escrowContract][token];
    uint256 newVaultExposure = currentEscrowExposure[escrowContract][token] + amount;
    if (vaultCap > 0 && newVaultExposure > vaultCap) {
        revert EscrowCapExceeded(escrowContract, token, newVaultExposure, vaultCap);
    }

    // Update exposure tracking
    currentExposure[token] = newExposure;
    currentEscrowExposure[escrowContract][token] = newVaultExposure;
}
```

### Cap Design Rationale

**Global Cap (System Safety):**
- Protects protocol from over-exposure to Aave
- Limits total funds at risk in single DeFi protocol
- Example: Cap USDC at 10M across all vaults

**Per-Vault Cap (Fairness):**
- Prevents single vault from consuming all capacity
- Ensures fair access for all vaults
- Example: Global cap 10M USDC, per-vault cap 2M USDC → supports 5+ vaults

**Cap = 0 Semantics:**
- `globalCap[token] = 0` → token deposits disabled globally
- `escrowCap[vault][token] = 0` → no enforced per-vault limit (only global applies)

## Implementation Review & Issues

### ✅ Strengths

1. **Isolation**: Per-vault state isolation prevents cross-contamination
2. **Fairness**: Two-tier caps ensure equitable resource allocation
3. **Auditability**: Global aggregates enable financial reconciliation
4. **Flexibility**: Vaults can be added/removed without affecting others

### ⚠️  Identified Issues

#### Issue 1: Missing Vault Authorization Check in depositForYield

**Location:** `AaveYieldGenerationModule.sol`, line 162-243

**Problem:**
```solidity
function depositForYield(uint256 workflowId, address token, uint256 amount) 
    external override returns (bool success, uint256 yieldTokenBalance) {
    
    address escrowContract = _msgSender();
    if (escrowContract == address(0)) revert EscrowContractCannotBeZero();
    
    // ⚠️  MISSING: No check for hasRole(ROLE_ESCROW_CONTRACT, escrowContract)
    // Any contract can call this and create deposits!
```

**Impact:** Unauthorized contracts could deposit to Aave through the module, bypassing governance controls.

**Recommendation:**
```solidity
function depositForYield(uint256 workflowId, address token, uint256 amount) 
    external override returns (bool success, uint256 yieldTokenBalance) {
    
    address escrowContract = _msgSender();
    if (escrowContract == address(0)) revert EscrowContractCannotBeZero();
    
    // Add authorization check
    if (!hasRole(ROLE_ESCROW_CONTRACT, escrowContract)) {
        revert NotAuthorized(escrowContract);
    }
    
    // ... rest of function
}
```

#### Issue 2: Missing Vault Authorization Check in withdrawWithYield

**Location:** `AaveYieldGenerationModule.sol`, line 256-400

**Problem:**
```solidity
function withdrawWithYield(
    uint256 workflowId,
    address token,
    uint256 originalAmount,
    address escrowContract
) external override returns (bool success, uint256 actualAmount, uint256 yieldAmount) {
    // ⚠️  MISSING: No check that msg.sender is authorized
    // Any address can attempt withdrawal by passing escrowContract parameter
```

**Impact:** Potential unauthorized access to withdrawal logic (though funds still go to escrowContract parameter).

**Recommendation:**
```solidity
function withdrawWithYield(...) external override returns (...) {
    // Verify caller is authorized vault
    if (!hasRole(ROLE_ESCROW_CONTRACT, msg.sender)) {
        revert NotAuthorized(msg.sender);
    }
    
    // Verify escrowContract matches caller (prevent parameter manipulation)
    if (escrowContract != msg.sender) {
        revert InvalidEscrowContract(escrowContract, msg.sender);
    }
    
    // ... rest of function
}
```

#### Issue 3: Exposure Accounting Mismatch on Partial Withdrawals

**Location:** `AaveYieldGenerationModule.sol`, line 858-873

**Problem:**
```solidity
function _reduceExposure(address escrowContract, address token, uint256 amount) internal {
    // Uses originalDeposit as reduction amount
    // But if Aave suffered a loss, actual withdrawn amount < originalDeposit
    // This can cause exposure accounting to underflow or become inaccurate
}
```

**Scenario:**
1. Vault deposits 100 USDC → currentExposure = 100
2. Aave suffers 10% loss
3. Vault withdraws 90 USDC
4. `_reduceExposure(escrowContract, token, 100)` → currentExposure becomes negative (clamped to 0)
5. Exposure tracking now inaccurate

**Recommendation:** Reduce exposure by actual withdrawn amount, not original deposit:
```solidity
// In withdrawWithYield:
_reduceExposure(escrowContract, token, actualAmount); // Use actual, not originalAmount
```

#### Issue 4: No Validation of Vault Registration in ModuleManagementContract

**Location:** `ModuleManagementContract.sol`, line 100+

**Problem:**
Two separate registrations are required:
1. `ModuleManagementContract.registerEscrowContract(vault)`
2. `AaveYieldGenerationModule.registerEscrowContract(vault)`

No enforcement that both are called, leading to potential inconsistency.

**Recommendation:**
- Document required registration sequence in deployment docs
- Consider adding a registration validation view function
- Or consolidate registration into single call that registers with both contracts

#### Issue 5: Global Aggregate Tracking Doesn't Account for Yield Distribution

**Location:** Lines 64-65

```solidity
mapping(address => uint256) public totalYieldGenerated; // All-time total
mapping(address => uint256) public totalYieldWithdrawn; // All-time total
```

**Problem:**
These aggregates are useful for auditing but:
- Don't account for yield distributed to different parties (buyer vs seller)
- Can't reconstruct historical yield splits
- No event emitted on yield generation (only on withdrawal)

**Recommendation:**
- Emit `YieldGenerated` event during withdrawal with breakdown
- Consider tracking yield distribution per party type
- Add view function to query historical yield by vault

### 🔧 Minor Issues

#### Issue 6: Deprecated tokenCap Still Writable

```solidity
function setTokenCap(address token, uint256 newCap) public onlyRole(ROLE_TIMELOCK) {
    // Function marked DEPRECATED but still callable
    tokenCap[token] = newCap;
    globalCap[token] = newCap; // Syncs with globalCap
}
```

**Recommendation:** Remove function or make it revert with deprecation notice.

#### Issue 7: Missing Events for Exposure Updates on Failure Recovery

When `_reduceExposure` clamps to zero due to underflow, no special event is emitted.

**Recommendation:** Add `ExposureReconciled` event when clamping occurs.

## Testing Recommendations

### Multi-Vault Scenarios to Test

1. **Concurrent Deposits**: Multiple vaults deposit simultaneously
2. **Cap Boundaries**: Test global cap exhaustion and per-vault cap limits
3. **Yield Distribution**: Verify proportional yield distribution across vaults
4. **Vault Removal**: Remove authorization and verify existing deposits still work
5. **Emergency Scenarios**: Guardian disables Aave mid-operation
6. **Exposure Accounting**: Verify exposure correctly tracks through deposit/withdrawal cycles
7. **Loss Scenarios**: Test behavior when Aave returns less than deposited (exploit/depeg)

### Invariants to Maintain

```solidity
// Exposure invariant
assert(currentExposure[token] <= globalCap[token])
assert(currentEscrowExposure[vault][token] <= escrowCap[vault][token])

// Aggregate invariant
assert(sum(escrowScaledBalance[*][*]) == totalScaledBalance[token])
assert(sum(escrowOriginalDeposit[*][*]) <= totalDepositedToAave[token])

// Share invariant (proportionality)
assert((escrowScaledBalance[vault][id] * totalATokenBalance) / totalScaledBalance[token] 
       >= escrowOriginalDeposit[vault][id])
```

## Deployment Checklist

- [ ] Deploy AaveYieldGenerationModule with initial admin
- [ ] Transfer ROLE_TIMELOCK to TimelockController
- [ ] Configure Aave pool addresses
- [ ] Register supported tokens (addSupportedToken)
- [ ] Set global caps for each token
- [ ] Deploy first EscrowVault
- [ ] Register vault in ModuleManagementContract
- [ ] Register vault in AaveYieldGenerationModule (grant ROLE_ESCROW_CONTRACT)
- [ ] Set per-vault cap
- [ ] Wire default modules via ModuleManagementContract
- [ ] Test deposit/withdrawal flow
- [ ] Deploy additional vaults (repeat registration steps)
- [ ] Configure guardian address (grant ROLE_GUARDIAN)
- [ ] Revoke admin powers from deployer

## Conclusion

The multi-vault architecture provides a robust, scalable foundation for yield generation across multiple escrow contracts. The two-tier governance model (Timelock + Guardian) balances decentralized control with emergency responsiveness.

**Critical fixes needed:**
1. Add authorization checks in `depositForYield` and `withdrawWithYield`
2. Fix exposure reduction to use actual withdrawn amount
3. Validate vault registration consistency

**Once addressed, the architecture is production-ready for multi-vault deployments.**
