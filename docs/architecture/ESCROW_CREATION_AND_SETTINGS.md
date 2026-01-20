# Escrow Creation and Settings Guide

**Last Updated:** 2026-01-13  
**Purpose:** Comprehensive guide to how `createEscrow` uses settings, yield opt-in, and the claimable balances system

---

## Overview

This document explains:
1. How `createEscrow` processes and applies `EscrowSettings`
2. How users opt into yield generation
3. The claimable balances system (pull model vs push model)

---

## 1. How `createEscrow` Uses Settings

### 1.1 Function Signature

```solidity
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public nonReentrant whenNotPaused returns (uint256)
```

### 1.2 Settings Structure

```solidity
struct EscrowSettings {
    address customResolver;    // Override default resolver (address(0) = use default)
    bool yieldEnabled;         // Opt-in for yield generation
    uint256 autoReleaseTime;   // Custom release time (0 = use default)
    uint256 autoCancelTime;    // Custom cancel time (0 = use default)
    EscrowType escrowType;     // For future extensibility
}
```

### 1.3 Settings Processing Flow

#### Step 1: Validation
```solidity
_validateEscrowSettings(settings);
```

**Validations performed:**
- **Auto times**: Cannot set both `autoReleaseTime` and `autoCancelTime`
- **Time bounds**: Auto times must be:
  - In the future (not past)
  - Within 30 days from current block timestamp (validated via `validateAutoRelease`/`validateAutoCancel`)
  - Not exceeding 10 years maximum duration (validated via `validateAutoTime`)
- **Custom resolver**: If set, must be non-zero address
  - **Note:** No validation that resolver is a contract or implements required interface
  - **Recommendation:** Ensure custom resolver implements `IResolver` interface
  
**Missing validations (future improvements):**
- Minimum escrow amount (prevents dust amounts)
- Maximum escrow duration (prevents indefinite locks)
- Recipient cannot be zero address or sender address
- Custom resolver contract validation (isContract check)
- EscrowType enum bounds validation

#### Step 2: Fee Calculation
```solidity
uint256 fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
uint256 amountAfterFee = amount - fee;
```

**Note:** Fee is deducted upfront and recorded separately. Only `amountAfterFee` is held in escrow.

#### Step 3: Token Transfer
```solidity
_pullTokens(token, _msgSender(), amount);
```

**Implementation:**
- `EscrowVault`: `IERC20(token).safeTransferFrom(from, address(this), amount)`
- `EscrowableERC20`: Internal transfer from sender's balance to escrow contract

#### Step 4: Resolver Selection
```solidity
address defaultResolver = _getDisputeResolverForNewEscrow(
    workflowId,
    token,
    _msgSender(),
    to,
    amountAfterFee
);
```

**Resolver selection logic:**
- If `settings.customResolver != address(0)`: Use custom resolver
- Otherwise: Use default resolution module's resolver selection logic
- Resolver is stored in `EscrowTransfer.disputeResolver` field

#### Step 5: Create Escrow Transfer Struct
```solidity
escrowTransfers.push(
    EscrowCreationLibrary.createEscrowTransferStruct(
        token,
        to,
        _msgSender(),
        amountAfterFee,
        defaultResolver
    )
);
```

#### Step 6: Apply Settings
```solidity
_applyEscrowSettings(workflowId, settings);
```

**What gets applied:**

1. **Custom Resolver**:
   ```solidity
   if (settings.customResolver != address(0)) {
       et.disputeResolver = settings.customResolver;
   }
   ```

2. **Auto Times**:
   ```solidity
   bool def = (settings.autoReleaseTime == 0 && settings.autoCancelTime == 0);
   et.autoReleaseTime = settings.autoReleaseTime > 0
       ? uint64(settings.autoReleaseTime)
       : (def ? uint64(timeoutConfig.defaultAutoReleaseTime) : 0);
   et.autoCancelTime = settings.autoCancelTime > 0
       ? uint64(settings.autoCancelTime)
       : (def ? uint64(timeoutConfig.defaultAutoCancelTime) : 0);
   ```

   **Fallback logic:**
   - If `autoReleaseTime > 0`: Use custom value, `autoCancelTime` set to 0
   - If `autoCancelTime > 0`: Use custom value, `autoReleaseTime` set to 0
   - If **both times are 0**: Use defaults from `timeoutConfig` (both default times applied)
   - If **one time is 0 but other is set**: The zero time remains 0 (no default fallback for that field)
   - Times are snapshotted to `EscrowTransfer` struct (immutable after creation)
   
   **Example:**
   - Settings: `autoReleaseTime = 0, autoCancelTime = 0` → Uses both defaults
   - Settings: `autoReleaseTime = 1000, autoCancelTime = 0` → Uses custom release, cancel = 0
   - Settings: `autoReleaseTime = 0, autoCancelTime = 2000` → Uses default release, custom cancel

3. **Settings Storage**:
   ```solidity
   escrowSettings[workflowId] = settings;
   emit EscrowSettingsUpdated(workflowId, settings);
   ```

#### Step 7: Snapshot Modules
```solidity
_snapshotModulesForEscrow(workflowId);
```

**What gets snapshotted:**
- Resolution module
- Release strategy
- Yield generation module
- Yield distribution module

**Why snapshot?** Ensures escrow uses the same modules throughout its lifecycle, even if defaults change via governance.

#### Step 8: Yield Opt-In (if enabled)
```solidity
if (settings.yieldEnabled) {
    IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
    if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
        _depositForYield(genModule, workflowId, token, amountAfterFee);
    }
}
```

**See Section 2 for details on yield opt-in.**

### 1.4 Settings Immutability

**Important:** Settings are **immutable after creation** (except for `customResolver` which can be updated while escrow is PENDING).

```solidity
function updateEscrowSettings(uint256 workflowId, EscrowSettings memory settings) public {
    _validateWorkflowId(workflowId);
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Can only update if escrow is PENDING
    if (et.escrowState != EscrowState.PENDING)
        revert TransferNotPending(workflowId, et.escrowState);
    
    // Can only be updated by sender or ROLE_TIMELOCK
    if (et.from != _msgSender() && !hasRole(ROLE_TIMELOCK, _msgSender()))
        revert NotParticipant(workflowId, _msgSender(), et.from, et.to);
    
    _validateEscrowSettings(settings);
    _applyEscrowSettings(workflowId, settings);
}
```

**What can be updated:**
- All settings fields (while escrow is PENDING state)
- Only by sender (`et.from`) or governance (`ROLE_TIMELOCK`)

**What cannot be updated:**
- Settings after escrow enters DISPUTED, RELEASED, REFUNDED, or RESOLVED states
- Module snapshots (always immutable - taken at creation time)

**Important considerations:**
- **Yield opt-in toggle:** Can be changed while PENDING, but yield deposit only occurs at creation. Changing `yieldEnabled` after creation won't deposit existing funds to yield.
- **Auto times:** Can be changed while PENDING, but auto-execution only checks the values at execution time.
- **Custom resolver:** Can be changed while PENDING, but won't affect resolver already assigned.

---

## 2. How to Opt Into Yield Generation

### 2.1 Opt-In During Creation

**Method 1: Set `yieldEnabled = true` in settings**

```solidity
EscrowSettings memory settings = getDefaultSettings();
settings.yieldEnabled = true;

uint256 workflowId = escrowContract.createEscrow(
    token,
    recipient,
    amount,
    settings
);
```

**Method 2: Use convenience function (if available)**

```solidity
// If contract provides convenience overload
uint256 workflowId = escrowContract.createEscrow(
    token,
    recipient,
    amount,
    autoReleaseTime,
    autoCancelTime,
    true  // yieldEnabled
);
```

### 2.2 Yield Opt-In Flow

#### Step 1: Check Setting
```solidity
if (settings.yieldEnabled) {
    // Proceed with yield deposit
}
```

#### Step 2: Get Yield Generation Module
```solidity
IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
```

**Module resolution:**
- Snapshot module from escrow creation time
- Fall back to default module if snapshot is empty
- Returns `address(0)` if no module configured

#### Step 3: Validate Token Support
```solidity
if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
    // Token is supported, proceed with deposit
}
```

**Token support:**
- Module checks if token has registered `aToken` (Aave) or equivalent
- Unsupported tokens skip yield deposit (no error)

#### Step 4: Deposit to Yield Module
```solidity
_depositForYield(genModule, workflowId, token, amountAfterFee);
```

**Implementation:**
```solidity
function _depositForYield(
    IYieldGenerationModule genModule,
    uint256 workflowId,
    address token,
    uint256 amount
) internal override {
    genModule.depositForYield(workflowId, token, amount);
}
```

**What happens:**
- `AaveYieldGenerationModule.depositForYield()` is called
- Funds are deposited to Aave Pool
- `aToken` balance is tracked per escrow
- Yield accrues automatically on Aave

### 2.3 Yield Opt-In Conditions

**Yield deposit occurs if:**
- ✅ `settings.yieldEnabled == true`
- ✅ Yield generation module is configured (not `address(0)`)
- ✅ Token is supported by module (`isTokenSupported(token) == true`)
- ✅ Aave is enabled globally (`aaveEnabled == true`)
- ✅ Token has registered `aToken` mapping

**Yield deposit is skipped (no error) if:**
- ❌ `settings.yieldEnabled == false`
- ❌ No yield generation module configured
- ❌ Token not supported by module
- ❌ Aave disabled globally

**Note:** Yield opt-in is **graceful**. If any condition fails, escrow creation still succeeds, just without yield.

### 2.4 Yield Withdrawal

**When escrow is finalized (release or cancel):**

```solidity
if (address(yieldOps) != address(0)) {
    IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
    IYieldDistributionModule distModule = _getYieldDistributionModule(workflowId);
    yieldOps.handleYield(
        genModule,
        distModule,
        workflowId,
        token,
        amount,
        yieldProtocolFeeBps,
        escrowFeeAddress
    );
}
```

**Yield handling:**
1. Withdraw from Aave (if deposited)
2. Calculate yield = `currentBalance - originalDeposit`
3. Deduct protocol fee (default: 30% of yield)
4. Distribute remainder according to `YieldDistribution` config

---

## 3. Claimable vs Non-Claimable (Pull Model vs Push Model)

### 3.1 Pull Model Design

**The protocol uses a pull model for escrow finalization.**

**Pull model means:**
- Funds are **not automatically transferred** when escrow finalizes
- Instead, a **claimable balance** is recorded
- Recipients must call `withdrawEscrow()` to claim their funds

**Why pull model?**
- **Gas efficiency**: Avoids failed transfers to contracts that can't receive ERC20
- **User control**: Recipients control when to claim
- **Batch operations**: Recipients can claim multiple escrows in one transaction
- **Security**: Reduces risk of funds stuck in non-standard contracts

### 3.2 Claimable Balance System

#### Structure
```solidity
// Pull model: claimable balances (escrowId => recipient => token => amount)
mapping(uint256 => mapping(address => mapping(address => uint256))) public claimable;
```

**Three-level mapping:**
- `escrowId`: Which escrow
- `recipient`: Who can claim
- `token`: Which token (single token per escrow, but mapping supports multiple)

#### Event
```solidity
event ClaimableBalanceSet(
    uint256 indexed escrowId,
    address indexed recipient,
    address indexed token,
    uint256 amount
);
```

### 3.3 When Claimable Balances Are Set

#### Scenario 1: Escrow Released
```solidity
function _releaseEscrowTransfer(uint256 workflowId) internal {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    uint256 amount = et.amountAfterFee;
    address to = et.to;
    address token = et.token;
    
    // ... state transition ...
    
    // Handle yield (withdraw from Aave, distribute)
    if (address(yieldOps) != address(0)) {
        // ... yield handling ...
    }
    
    _updateEscrowBalance(token, amount, false);  // Decrease escrow balance
    
    // Pull model: Set claimable balance instead of transferring tokens
    claimable[workflowId][to][token] += amount;
    emit ClaimableBalanceSet(workflowId, to, token, amount);
}
```

**What happens:**
1. Escrow state transitions to `RELEASED`
2. Yield is handled (if applicable)
3. Escrow balance is decreased
4. Claimable balance is **incremented** (not set to, allows multiple claims)
5. No token transfer occurs

#### Scenario 2: Escrow Cancelled
```solidity
function _cancelAndRefund(uint256 workflowId) internal {
    EscrowTransfer storage et = escrowTransfers[workflowId];
    uint256 amount = et.amountAfterFee;
    address from = et.from;
    address token = et.token;
    
    // ... state transition ...
    
    // Handle yield (withdraw from Aave, distribute)
    if (address(yieldOps) != address(0)) {
        // ... yield handling ...
    }
    
    _updateEscrowBalance(token, amount, false);  // Decrease escrow balance
    
    // Pull model: Set claimable balance instead of transferring tokens
    claimable[workflowId][from][token] += amount;
    emit ClaimableBalanceSet(workflowId, from, token, amount);
}
```

**What happens:**
1. Escrow state transitions to `REFUNDED`
2. Yield is handled (if applicable)
3. Escrow balance is decreased
4. Claimable balance is incremented for **sender** (not recipient)
5. No token transfer occurs

#### Scenario 3: Escrow Resolved (by resolver)

**Note:** BaseEscrow supports two resolution functions for full release or full cancel only:

**Full Release:**
```solidity
function releaseAsDisputeResolver(
    uint256 workflowId,
    bytes32 resolutionHash
) external returns (bool)
```

**Full Cancel:**
```solidity
function cancelAsDisputeResolver(
    uint256 workflowId,
    bytes32 resolutionHash
) external returns (bool)
```

Both functions call `_executeResolution()` which:
1. Validates resolver authorization
2. Checks escrow is in DISPUTED state
3. Records resolution outcome
4. Handles appeal window (if applicable)
5. Eventually calls `_releaseEscrowTransfer()` or `_cancelAndRefund()`

**What happens:**
1. Resolver calls `releaseAsDisputeResolver()` or `cancelAsDisputeResolver()`
2. If appeal window expires or it's final round, settlement executes immediately
3. Otherwise, settlement is stored as `PendingSettlement` until appeal window expires
4. After appeal window, `executePendingSettlement()` is called
5. Claimable balance is incremented for recipient (release) or sender (cancel)
6. No token transfers occur until withdrawal

**Important:** BaseEscrow only supports full release or full cancel. Partial payouts (multiple recipients, split amounts) are not supported by BaseEscrow core, but may be supported by specific resolution modules (e.g., DecentralizedResolutionModule via `resolve()` with `Payout[]`).

### 3.4 Claiming Funds (Withdrawal)

#### Function
```solidity
function withdrawEscrow(uint256 workflowId) external nonReentrant returns (uint256) {
    _validateWorkflowId(workflowId);
    EscrowTransfer storage et = escrowTransfers[workflowId];
    
    // Verify escrow is finalized
    require(
        et.escrowState == EscrowState.RESOLVED ||
        et.escrowState == EscrowState.RELEASED ||
        et.escrowState == EscrowState.REFUNDED,
        'Not finalized'
    );
    
    address token = et.token;
    uint256 amount = claimable[workflowId][msg.sender][token];
    require(amount > 0, 'No claimable balance');
    
    // Idempotent: set to 0 before transfer (checks-effects-interactions)
    claimable[workflowId][msg.sender][token] = 0;
    
    // Transfer tokens
    _transferTokens(token, msg.sender, amount);
    
    emit EscrowWithdrawn(workflowId, msg.sender, token, amount);
    return amount;
}
```

#### Withdrawal Flow

**Step 1: Validation**
- Escrow must be finalized (`RESOLVED`, `RELEASED`, or `REFUNDED`)
- Caller must have claimable balance > 0

**Step 2: Claim Extraction**
```solidity
uint256 amount = claimable[workflowId][msg.sender][token];
```

**Step 3: Idempotent Update**
```solidity
claimable[workflowId][msg.sender][token] = 0;
```

**Why set to 0 first?** Prevents reentrancy attacks. Checks-effects-interactions pattern.

**Step 4: Token Transfer**
```solidity
_transferTokens(token, msg.sender, amount);
```

**Implementation:**
- `EscrowVault`: `IERC20(token).safeTransfer(to, amount)`
- `EscrowableERC20`: Internal transfer to caller's balance

### 3.5 Pull Model Benefits

#### 1. Gas Efficiency
- **Push model**: Every finalization requires transfer gas, even if recipient can't receive tokens
- **Pull model**: Transfer only occurs when recipient is ready, saving gas on failed transfers

#### 2. User Control
- Recipients control when to claim
- Can batch multiple claims in one transaction
- Can delay claiming if desired

#### 3. Contract Compatibility
- Works with contracts that can't receive ERC20 (non-standard implementations)
- Works with contracts that implement hooks (can call `withdrawEscrow` when ready)

#### 4. Multi-Payout Support
- Resolver resolutions can split funds among multiple recipients
- Each recipient claims their portion independently
- No need for all recipients to be ready simultaneously

### 3.6 Pull Model Trade-offs

#### 1. User Experience
- Requires additional transaction to claim (not automatic)
- Recipients must be aware they need to call `withdrawEscrow()`

#### 2. Abandoned Funds
- If recipient never claims, funds remain in contract
- Can be recovered via governance recovery functions (if implemented)

#### 3. Gas Cost
- Recipients pay gas for withdrawal transaction
- However, this is offset by savings from avoiding failed transfers

### 3.7 Best Practices

#### For Users
1. **Monitor escrow status**: Check when escrow finalizes
2. **Claim promptly**: Don't leave funds unclaimed indefinitely
3. **Batch claims**: If you have multiple escrows, claim them in one transaction

#### For Integrators
1. **Listen for events**: Monitor `ClaimableBalanceSet` events
2. **Auto-claim option**: Provide UI option to auto-claim on finalization
3. **Batch withdrawal**: Implement batch withdrawal for multiple escrows

#### For Resolvers
1. **Multi-payout support**: Can split funds among multiple recipients
2. **Partial claims**: Recipients can claim portions independently (if resolver splits)

---

## Summary

### Settings Flow
1. Validate settings (bounds, logic)
2. Calculate fees
3. Transfer tokens
4. Select resolver (custom or default)
5. Apply settings to escrow struct
6. Snapshot modules (immutable after creation)
7. Opt into yield (if enabled)

### Yield Opt-In
- Set `yieldEnabled = true` in `EscrowSettings`
- Requires: configured module, supported token, enabled Aave
- Graceful failure: escrow still created if yield fails
- Withdrawal handled automatically on finalization

### Claimable Balances (Pull Model)
- Funds are **not automatically transferred** on finalization
- Claimable balance is **incremented** instead
- Recipients must call `withdrawEscrow()` to claim
- Benefits: gas efficiency, user control, contract compatibility
- Trade-offs: requires user action, potential for abandoned funds

---

## Related Documentation

- [Escrow Types and Settings](../types/EscrowTypes.sol)
- [Settings Validation Library](../libraries/SettingsValidationLibrary.sol)
- [Yield Generation Module](../modules/AaveYieldGenerationModule.sol)
- [Security Model](../SECURITY_MODEL.md)
