# Sew Protocol - Wallet Integration Pack

**Version:** 1.0  
**Updated:** February 20, 2026  
**Network:** Base Sepolia (ChainID 84532)  
**Status:** Production Ready

---

## 📖 Table of Contents

1. [Quick Start](#quick-start)
2. [Core Concepts](#core-concepts)
3. [Contract Addresses](#contract-addresses)
4. [Key Interfaces](#key-interfaces)
5. [Integration Flow](#integration-flow)
6. [Function Reference](#function-reference)
7. [Error Handling](#error-handling)
8. [Code Examples](#code-examples)
9. [Testing & Verification](#testing--verification)
10. [Common Integration Patterns](#common-integration-patterns)

---

## Quick Start

The Sew Protocol enables **escrow-based token transfers** with optional **yield generation**. Wallets integrate by:

1. **Approve tokens** to EscrowVault
2. **Create escrows** specifying sender, recipient, amount, and yield settings
3. **Release or cancel** escrows based on parties' decisions
4. **Handle yield** if enabled (automatically accrues in integrated Aave pool)

---

## Core Concepts

### Escrow Flow

```
┌─────────────────────────────────────────────────────────┐
│ ESCROW LIFECYCLE                                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│ 1. CREATE ESCROW (sender approves & creates)           │
│    ↓                                                     │
│    [PENDING] - Tokens locked in vault                  │
│    ↓                                                     │
│ 2. RELEASE (sender releases to recipient) OR CANCEL    │
│    ├─→ [RELEASED] - Tokens + yield to recipient        │
│    └─→ [REFUNDED] - Tokens + yield back to sender      │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Key Properties

| Property | Meaning |
|----------|---------|
| **workflowId** | Unique ID returned from `createEscrow()` |
| **token** | ERC20 token address being escrowed |
| **sender** | Address that creates escrow (buyer/payer) |
| **recipient** | Address receiving escrowed tokens (seller) |
| **amount** | Total amount sender transfers |
| **amountAfterFee** | Amount recipient gets (after protocol fee) |
| **escrowFee** | Protocol fee in basis points (bps) |
| **yieldPreset** | Whether yield is enabled (OFF or TO_SENDER) |

### Important Protocol Constraint

⚠️ **REQUIREMENT: Recipient must NOT equal sender**

This is intentional design to prevent self-escrow scenarios. Error if violated:
```
InvalidAddress(ADDR_RECIPIENT, recipient)
```

---

## Contract Addresses

### Base Sepolia (84532)

#### Core Contracts

| Contract | Address | Verified |
|----------|---------|----------|
| **EscrowVault** | `0x13b8b7572c72b46879662BFEA53851cBeD3bC47a` | ✅ BaseScan |
| **SewToken** | `0x62BD47154D0b5Fe435F220E1294405040102b2ba` | ✅ BaseScan |
| **ModuleSnapshotRegistry** | `0x1B152685Fb8268d7eb4F292524d86661dCFEEdE6` | ✅ Sourcify |

#### Operations Contracts

| Contract | Address | Purpose |
|----------|---------|---------|
| **CreateOps** | `0xBC60481020457CAC819B6938396a1002B0518f34` | Escrow creation validation |
| **YieldOps** | `0xEc421d01E88754dAe5AAdE24C7616F8161f9f0F3` | Yield initialization |
| **DisputeOps** | `0xd62A061bcC7b934558bd4c5dDa4E1FbeDC06D394` | Dispute resolution |
| **SettlementOps** | `0x2cB13cefF8E5326647454aa2d50db15f5282c3A4` | Settlement logic |

#### Yield Integration

| Contract | Address |
|----------|---------|
| **AaveYieldModule** | `0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01` |
| **Aave V3 Pool** | `0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27` |

#### Governance Contracts

| Contract | Address |
|----------|---------|
| **EscrowGovernanceTimelock** | [See DEPLOYMENT_CURRENT_STATUS.md] |
| **DEFAULT_ADMIN_ROLE** | [Multi-sig on mainnet] |

---

## Key Interfaces

### 1. EscrowVault Interface

**Location:** `contracts/core/EscrowVault.sol` (extends BaseEscrow)

**Core Functions:**

```solidity
// Create an escrow
function createEscrow(
    address token,           // ERC20 token to escrow
    address to,              // Recipient address (MUST ≠ sender)
    uint256 amount,          // Amount to escrow (pre-fee)
    EscrowSettings memory settings  // Configuration
) public returns (uint256 workflowId);

// Release escrow to recipient
function releaseEscrowTransfer(uint256 workflowId) public;

// Cancel escrow (returns to sender)
function senderCancel(uint256 workflowId) external returns (bool);

// Release as dispute resolver
function releaseAsDisputeResolver(
    uint256 workflowId,
    bytes32 resolutionHash
) public returns (bool);

// Query escrow state
function escrowTransfers(uint256 workflowId) 
    external view returns (EscrowTransfer memory);
```

### 2. EscrowSettings Structure

```solidity
struct EscrowSettings {
    address customResolver;      // Custom dispute resolver (optional)
    address releaseAddress;      // Address that can release (optional)
    YieldPreset yieldPreset;     // OFF or TO_SENDER
    uint256 autoReleaseTime;     // Automatic release delay (0 = disabled)
    uint256 autoCancelTime;      // Automatic cancel delay (0 = disabled)
}
```

### 3. EscrowTransfer Structure

```solidity
struct EscrowTransfer {
    address token;                   // ERC20 token
    address to;                      // Recipient
    address from;                    // Sender
    uint256 amountAfterFee;          // Amount after protocol fee
    EscrowState escrowState;         // PENDING, RELEASED, REFUNDED
    SenderStatus senderStatus;       // Sender's status
    RecipientStatus recipientStatus; // Recipient's status
    address disputeResolver;         // Dispute resolution address
    uint256 autoReleaseTime;         // Auto-release timestamp (0 = no auto)
    uint256 autoCancelTime;          // Auto-cancel timestamp (0 = no auto)
}
```

### 4. YieldPreset Enum

```solidity
enum YieldPreset {
    OFF,                // No yield generation (default)
    TO_SENDER           // Yield accrues to sender (buyer)
}
```

### 5. EscrowState Enum

```solidity
enum EscrowState {
    NONE,          // Not created
    PENDING,       // Created, awaiting release/cancel
    RELEASED,      // Released to recipient
    REFUNDED,      // Cancelled, refunded to sender
    DISPUTED,      // In active dispute (resolution pending)
    RESOLVED       // Dispute resolved (release or cancel executed)
}
```

### 6. View Functions

```solidity
// Get escrow state
function escrowStates(uint256 workflowId) 
    external view returns (EscrowState);

// Get current fee structure
function escrowFee() 
    external view returns (uint256);  // In basis points

// Get total escrow held per token
function totalHeldInEscrowPerToken(address token) 
    external view returns (uint256);

// Get accounting breakdown
function getAccountingBreakdown(address token) 
    external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    );

// Check if escrow has yield enabled
function escrowInYield(uint256 workflowId, address token) 
    external view returns (bool);

// Get yield amount accrued
function getYieldAmount(uint256 workflowId, address token) 
    external view returns (uint256);
```

---

## Integration Flow

### Standard Flow (No Yield)

```typescript
// 1. Approve tokens to EscrowVault
await token.approve(escrowVault.address, amount);

// 2. Create escrow
const settings = {
    customResolver: ethers.constants.AddressZero,  // Use default
    releaseAddress: ethers.constants.AddressZero,  // Only sender can release
    yieldPreset: 0,  // YieldPreset.OFF
    autoReleaseTime: 0,  // No auto-release
    autoCancelTime: 0   // No auto-cancel
};

const tx = await escrowVault.createEscrow(
    token.address,
    recipientAddress,
    amount,
    settings
);

const receipt = await tx.wait();
const workflowId = 0;  // First escrow, or parse event

// 3. Release (when ready)
await escrowVault.releaseEscrowTransfer(workflowId);

// OR Cancel
await escrowVault.senderCancel(workflowId);
```

### Yield-Enabled Flow

```typescript
// 1. Approve tokens to EscrowVault
await token.approve(escrowVault.address, amount);

// 2. Create escrow WITH YIELD
const settings = {
    customResolver: ethers.constants.AddressZero,
    releaseAddress: ethers.constants.AddressZero,
    yieldPreset: 1,  // YieldPreset.TO_SENDER (yield to buyer)
    autoReleaseTime: 0,
    autoCancelTime: 0
};

const tx = await escrowVault.createEscrow(
    token.address,
    recipientAddress,
    amount,
    settings
);

const receipt = await tx.wait();
const workflowId = 0;  // Or parse from EscrowCreated event

// 3. Wait for yield to accrue (Aave integration)
//    Yield automatically accrues in Aave V3 Pool

// 4. After yield accrual period, release
const yieldAmount = await escrowVault.getYieldAmount(workflowId, token.address);
console.log(`Yield generated: ${yieldAmount}`);

await escrowVault.releaseEscrowTransfer(workflowId);
// Recipient receives: amountAfterFee + yieldAmount
```

### Multi-Release Flow (Authorized Releaser)

```typescript
// Designate someone other than sender to release
const settings = {
    customResolver: ethers.constants.AddressZero,
    releaseAddress: arbitratorAddress,  // Arbitrator can release
    yieldPreset: 0,
    autoReleaseTime: 0,
    autoCancelTime: 0
};

const workflowId = await escrowVault.createEscrow(
    token.address,
    recipientAddress,
    amount,
    settings
);

// Later, arbitrator releases
const arbitratorEscrow = escrowVault.connect(arbitratorSigner);
await arbitratorEscrow.releaseEscrowTransfer(workflowId);
```

---

## Function Reference

### Create Escrow

```solidity
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public nonReentrant returns (uint256)
```

**Parameters:**
- `token`: ERC20 token address
- `to`: Recipient address (MUST ≠ msg.sender)
- `amount`: Total amount (before fee)
- `settings`: EscrowSettings struct

**Returns:**
- `workflowId`: Unique identifier for this escrow

**Requirements:**
- Caller must have approved `amount` tokens to EscrowVault
- `to` must not equal `msg.sender`
- Token must be valid ERC20

**Events Emitted:**
- `EscrowCreated(workflowId, token, from, to, amount, amountAfterFee, fee)`
- `EscrowStateChanged(workflowId, EscrowState.NONE, EscrowState.PENDING)`

**Reverts:**
- `ZeroCreateOps()` if CreateOps not initialized
- `InvalidAddress(1, to)` if to == msg.sender
- `AccountingDeficit(token, amount)` if transfer fails

---

### Release Escrow

```solidity
function releaseEscrowTransfer(uint256 workflowId) 
    public nonReentrant
```

**Parameters:**
- `workflowId`: ID from createEscrow()

**Requirements:**
- Escrow must be in PENDING state
- Caller must be sender (from address) OR releaseAddress
- Escrow must not be in dispute

**Events Emitted:**
- `EscrowReleased(workflowId, ...)`
- `EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.RELEASED)`

**Reverts:**
- `NotPending(workflowId)` if not in PENDING state
- `NotSender(...)` if caller not authorized
- `InDispute(...)` if escrow is disputed

---

### Cancel Escrow

```solidity
function senderCancel(uint256 workflowId) 
    external nonReentrant returns (bool)
```

**Parameters:**
- `workflowId`: ID from createEscrow()

**Requirements:**
- Escrow must be in PENDING state
- Caller must be sender
- Escrow must not be in active dispute

**Returns:**
- `bool`: true if cancelled successfully

**Events Emitted:**
- `EscrowCancelled(workflowId, ...)`
- `EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.REFUNDED)`

**Reverts:**
- `NotPending(workflowId)` if not in PENDING state
- `NotSender(...)` if caller is not sender

---

### Query Functions

```solidity
// Get escrow details
function escrowTransfers(uint256 workflowId) 
    external view returns (EscrowTransfer memory)

// Get escrow state
function escrowStates(uint256 workflowId) 
    external view returns (EscrowState)

// Get protocol fee in basis points
function escrowFee() 
    external view returns (uint256)

// Check if yield is enabled
function escrowInYield(uint256 workflowId, address token) 
    external view returns (bool)

// Get accrued yield amount
function getYieldAmount(uint256 workflowId, address token) 
    external view returns (uint256)

// Get total held per token
function totalHeldInEscrowPerToken(address token) 
    external view returns (uint256)

// Get accounting breakdown
function getAccountingBreakdown(address token) 
    external view returns (
        uint256 principalHeld,
        uint256 feesCollected,
        uint256 contractBalance,
        uint256 yieldInBalance
    )
```

---

## Error Handling

### Common Errors

| Error | Cause | Resolution |
|-------|-------|-----------|
| `NotPending(workflowId)` | Escrow not in PENDING state | Check `escrowStates(workflowId)` first |
| `NotSender(...)` | Caller is not the sender | Switch to sender's wallet signer |
| `InvalidAddress(1, to)` | Recipient == Sender | Ensure recipient ≠ sender |
| `AccountingDeficit(token, amount)` | Transfer failed | Check token allowance |
| `ZeroCreateOps()` | CreateOps not initialized | Contact protocol team |
| `InDispute(...)` | Escrow in active dispute | Wait for dispute resolution |
| `ERC20: insufficient allowance` | Token allowance too low | Call `approve()` with higher amount |

### Error Handling Pattern

```typescript
try {
    const tx = await escrowVault.createEscrow(
        token,
        recipient,
        amount,
        settings
    );
    const receipt = await tx.wait();
    console.log(`Escrow created: ${receipt.transactionHash}`);
} catch (error) {
    if (error.reason === 'InvalidAddress(1, to)') {
        console.error('Recipient cannot be same as sender');
    } else if (error.reason === 'ERC20: insufficient allowance') {
        console.error('Need to approve more tokens');
    } else {
        console.error('Unknown error:', error.message);
    }
}
```

---

## Code Examples

### Example 1: Simple Escrow with USDC

```typescript
const ethers = require('ethers');

const ESCROW_VAULT = '0x13b8b7572c72b46879662BFEA53851cBeD3bC47a';
const USDC = '0x036CbD53842c5426634e7929541eC2318f3dCF7e';

const ESCROW_ABI = [
    'function createEscrow(address token, address to, uint256 amount, tuple(address customResolver, address releaseAddress, uint8 yieldPreset, uint256 autoReleaseTime, uint256 autoCancelTime) settings) returns (uint256)',
    'function releaseEscrowTransfer(uint256 workflowId)',
    'function senderCancel(uint256 workflowId) returns (bool)',
    'function escrowTransfers(uint256 workflowId) view returns (tuple(address token, address to, address from, uint256 amountAfterFee, uint8 escrowState, uint8 senderStatus, uint8 recipientStatus, address disputeResolver, uint256 autoReleaseTime, uint256 autoCancelTime))'
];

const ERC20_ABI = [
    'function approve(address spender, uint256 amount) returns (bool)',
    'function balanceOf(address account) view returns (uint256)'
];

async function createSimpleEscrow(
    signer,
    recipientAddress,
    amountInUsdc
) {
    // 1. Get contract instances
    const vault = new ethers.Contract(ESCROW_VAULT, ESCROW_ABI, signer);
    const usdc = new ethers.Contract(USDC, ERC20_ABI, signer);

    // 2. Approve tokens
    console.log('Approving USDC...');
    const approveTx = await usdc.approve(ESCROW_VAULT, amountInUsdc);
    await approveTx.wait();
    console.log('Approved!');

    // 3. Create escrow
    console.log('Creating escrow...');
    const settings = {
        customResolver: ethers.constants.AddressZero,
        releaseAddress: ethers.constants.AddressZero,
        yieldPreset: 0,  // OFF
        autoReleaseTime: 0,
        autoCancelTime: 0
    };

    const createTx = await vault.createEscrow(
        USDC,
        recipientAddress,
        amountInUsdc,
        settings
    );

    const receipt = await createTx.wait();
    const workflowId = 0;  // Or parse from logs

    console.log(`✅ Escrow created! Workflow ID: ${workflowId}`);
    return workflowId;
}

async function releaseEscrow(signer, workflowId) {
    const vault = new ethers.Contract(ESCROW_VAULT, ESCROW_ABI, signer);
    
    console.log('Releasing escrow...');
    const tx = await vault.releaseEscrowTransfer(workflowId);
    const receipt = await tx.wait();
    
    console.log(`✅ Escrow released! Tx: ${receipt.transactionHash}`);
}

async function cancelEscrow(signer, workflowId) {
    const vault = new ethers.Contract(ESCROW_VAULT, ESCROW_ABI, signer);
    
    console.log('Cancelling escrow...');
    const tx = await vault.senderCancel(workflowId);
    const receipt = await tx.wait();
    
    console.log(`✅ Escrow cancelled! Tx: ${receipt.transactionHash}`);
}

// Usage:
// const signer = new ethers.Wallet(privateKey, provider);
// const workflowId = await createSimpleEscrow(signer, '0x...recipient', ethers.parseUnits('100', 6));
// await releaseEscrow(signer, workflowId);
```

### Example 2: Escrow with Yield

```typescript
async function createYieldEscrow(
    signer,
    recipientAddress,
    amountInSew
) {
    const vault = new ethers.Contract(ESCROW_VAULT, ESCROW_ABI, signer);
    const sew = new ethers.Contract(SEW_TOKEN, ERC20_ABI, signer);

    // Approve
    const approveTx = await sew.approve(ESCROW_VAULT, amountInSew);
    await approveTx.wait();

    // Create with YIELD enabled
    const settings = {
        customResolver: ethers.constants.AddressZero,
        releaseAddress: ethers.constants.AddressZero,
        yieldPreset: 1,  // TO_SENDER (yield accrues to buyer)
        autoReleaseTime: 0,
        autoCancelTime: 0
    };

    const createTx = await vault.createEscrow(
        SEW_TOKEN,
        recipientAddress,
        amountInSew,
        settings
    );

    const receipt = await createTx.wait();
    const workflowId = 0;

    console.log(`✅ Yield escrow created! ID: ${workflowId}`);
    
    // Wait for yield to accrue (e.g., 7 days)
    console.log('Waiting for yield to accrue...');
    // ... (wait time logic)

    // Release after yield period
    const releaseTx = await vault.releaseEscrowTransfer(workflowId);
    const releaseReceipt = await releaseTx.wait();
    
    console.log(`✅ Released with yield! Tx: ${releaseReceipt.transactionHash}`);
    
    return workflowId;
}
```

### Example 3: Check Escrow Status

```typescript
async function checkEscrowStatus(workflowId) {
    const vault = new ethers.Contract(ESCROW_VAULT, ESCROW_ABI, provider);

    // Get escrow details
    const escrow = await vault.escrowTransfers(workflowId);
    const state = await vault.escrowStates(workflowId);

    const states = ['NONE', 'PENDING', 'RELEASED', 'REFUNDED', 'DISPUTED', 'RESOLVED'];

    console.log('=== ESCROW STATUS ===');
    console.log(`Workflow ID: ${workflowId}`);
    console.log(`State: ${states[state]} (${state})`);
    console.log(`From: ${escrow.from}`);
    console.log(`To: ${escrow.to}`);
    console.log(`Token: ${escrow.token}`);
    console.log(`Amount After Fee: ${ethers.formatUnits(escrow.amountAfterFee, 18)}`);
    console.log(`Auto Release Time: ${escrow.autoReleaseTime}`);
    console.log(`Auto Cancel Time: ${escrow.autoCancelTime}`);

    // Check yield
    const hasYield = await vault.escrowInYield(workflowId, escrow.token);
    if (hasYield) {
        const yieldAmount = await vault.getYieldAmount(workflowId, escrow.token);
        console.log(`Yield Accrued: ${ethers.formatUnits(yieldAmount, 18)}`);
    }
}
```

---

## Testing & Verification

### Network Information

**Base Sepolia:**
- **Chain ID:** 84532
- **RPC URL:** https://sepolia.base.org
- **Block Explorer:** https://sepolia.basescan.org
- **Status:** ✅ Production ready

### Verify Integration

```bash
# 1. Check EscrowVault is deployed
cast code 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a --rpc-url https://sepolia.base.org

# 2. Check your token approval
cast call 0x62BD47154D0b5Fe435F220E1294405040102b2ba \
  "allowance(address,address)(uint256)" \
  0xYourAddress \
  0x13b8b7572c72b46879662BFEA53851cBeD3bC47a \
  --rpc-url https://sepolia.base.org

# 3. Check escrow state
cast call 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a \
  "escrowStates(uint256)(uint8)" \
  0 \
  --rpc-url https://sepolia.base.org
```

### Test Script Locations

Reference implementations available in repository:

```
scripts/testnet/
├── phase0-base-sepolia-health.ts      # Infrastructure validation
├── phase1-multi-party-escrow.ts       # Basic escrow flows
├── phase2-aave-yield-testing.ts       # Yield integration
└── phase4-yield-test-sew.ts           # Long-term yield test
```

Run tests:
```bash
pnpm hardhat run scripts/testnet/phase1-multi-party-escrow.ts --network baseSepolia
```

---

## Common Integration Patterns

### Pattern 1: Escrow for P2P Trading

```
Alice (Buyer) → Funds → EscrowVault → Bob (Seller confirms) → Release → Bob gets funds
                                    ↓
                             If dispute: Refund to Alice
```

**Implementation:**
```typescript
// Alice creates escrow
const workflowId = await vault.createEscrow(
    tokenAddress,
    bobAddress,
    amount,
    { /* no yield */ }
);

// Wait for Bob's confirmation (off-chain)

// Alice releases
await vault.releaseEscrowTransfer(workflowId);
```

### Pattern 2: Escrow with Yield (DeFi Integration)

```
Buyer → Funds → EscrowVault → Aave Pool (accrues yield)
                           ↓ (after period)
                    Release → Recipient gets principal + yield
```

**Implementation:**
```typescript
const workflowId = await vault.createEscrow(
    tokenAddress,
    recipientAddress,
    amount,
    {
        yieldPreset: 1,  // TO_SENDER
        autoReleaseTime: 0
    }
);

// Yield accrues automatically in Aave
// After period:
const yieldAmount = await vault.getYieldAmount(workflowId, tokenAddress);
await vault.releaseEscrowTransfer(workflowId);
```

### Pattern 3: Multi-Signer Escrow

```
Sender → EscrowVault ← Arbitrator (authorized releaser)
         (awaits release from arbitrator)
```

**Implementation:**
```typescript
const workflowId = await vault.createEscrow(
    tokenAddress,
    recipientAddress,
    amount,
    {
        releaseAddress: arbitratorAddress  // Only arbitrator can release
    }
);

// Arbitrator releases later
const arbitratorVault = vault.connect(arbitratorSigner);
await arbitratorVault.releaseEscrowTransfer(workflowId);
```

### Pattern 4: Automatic Timeout Handling

```
Sender creates escrow → Wait for recipient confirmation
                    ↓
            If confirmed: Release immediately
            If not confirmed after timeout: Auto-refund
```

**Implementation:**
```typescript
// Create with auto-cancel timeout
const autoTimeoutSeconds = 7 * 24 * 60 * 60;  // 7 days
const blockTime = Math.floor(Date.now() / 1000);

const workflowId = await vault.createEscrow(
    tokenAddress,
    recipientAddress,
    amount,
    {
        autoReleaseTime: 0,
        autoCancelTime: blockTime + autoTimeoutSeconds
    }
);

// Monitor escrow state
// After timeout, anyone can call automateTimedActions(workflowId)
// which will trigger auto-cancel
```

---

## Best Practices for Wallet Developers

### 1. **Always Validate Inputs**
```typescript
// Check recipient ≠ sender
if (recipient.toLowerCase() === sender.toLowerCase()) {
    throw new Error('Recipient cannot be the same as sender');
}

// Check amount > 0
if (amount.lte(0)) {
    throw new Error('Amount must be greater than 0');
}

// Validate token is ERC20
if (tokenAddress === ethers.constants.AddressZero) {
    throw new Error('Invalid token address');
}
```

### 2. **Check Allowances**
```typescript
const token = new ethers.Contract(tokenAddress, ERC20_ABI, signer);
const allowance = await token.allowance(signer.address, ESCROW_VAULT);

if (allowance.lt(amount)) {
    const approveTx = await token.approve(ESCROW_VAULT, amount);
    await approveTx.wait();
}
```

### 3. **Parse Events for workflowId**
```typescript
const createTx = await vault.createEscrow(token, recipient, amount, settings);
const receipt = await createTx.wait();

const event = receipt.events.find(e => e.event === 'EscrowCreated');
const workflowId = event.args.workflowId;
```

### 4. **Handle State Transitions Properly**
```typescript
const state = await vault.escrowStates(workflowId);
const states = {
    0: 'NONE',
    1: 'PENDING',
    2: 'RELEASED',
    3: 'REFUNDED'
};

if (state !== 1) {  // Not PENDING
    throw new Error(`Cannot release escrow in state: ${states[state]}`);
}
```

### 5. **Implement Retry Logic**
```typescript
async function createEscrowWithRetry(
    vault, token, recipient, amount, settings,
    maxAttempts = 3
) {
    for (let i = 0; i < maxAttempts; i++) {
        try {
            return await vault.createEscrow(
                token, recipient, amount, settings
            );
        } catch (error) {
            if (i === maxAttempts - 1) throw error;
            console.log(`Attempt ${i + 1} failed, retrying...`);
            await new Promise(r => setTimeout(r, 1000 * (i + 1)));
        }
    }
}
```

### 6. **Monitor Gas Prices**
```typescript
const gasPrice = await provider.getGasPrice();
const gasPriceBn = ethers.BigNumber.from(gasPrice);

const estimatedGas = await vault.estimateGas.createEscrow(
    token, recipient, amount, settings
);

const estimatedCost = estimatedGas.mul(gasPriceBn);
console.log(`Estimated cost: ${ethers.formatEther(estimatedCost)} ETH`);
```

---

## Support & Resources

### Documentation
- **Full Protocol Docs:** See repository README.md
- **Deployment Status:** DEPLOYMENT_CURRENT_STATUS.md
- **Addresses Reference:** DEPLOYMENT_CURRENT_STATUS.md
- **Root Cause Analysis:** ESCROW_VALIDATION_ROOT_CAUSE.md

### Testing
- **Test Scripts:** `scripts/testnet/`
- **Phase 1 Tests:** Multi-party escrow flows
- **Phase 2 Tests:** Aave yield integration

### Contract Verification
- **BaseScan:** https://sepolia.basescan.org/address/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a#code
- **Sourcify:** https://repo.sourcify.dev/contracts/full_match/84532/0x13b8b7572c72b46879662BFEA53851cBeD3bC47a/

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Feb 20, 2026 | Initial release for Base Sepolia testnet |

---

**Ready to integrate!** For questions, refer to the contract source code or DEPLOYMENT_CURRENT_STATUS.md
