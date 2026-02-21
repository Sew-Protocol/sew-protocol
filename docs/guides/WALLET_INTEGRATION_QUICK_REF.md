# Wallet Integration - Quick Reference

**For:** Wallet developers integrating Sew Protocol  
**Network:** Base Sepolia (84532)  
**Updated:** February 20, 2026

---

## ⚡ 30-Second Overview

Sew Protocol enables **escrow-based token transfers** with **optional yield**:

```
1. Approve tokens to EscrowVault
2. Call createEscrow(token, recipient, amount, settings)
3. Release or cancel anytime
4. Recipient gets tokens (+ yield if enabled)
```

---

## 🔑 Essential Addresses

```
EscrowVault:        0x13b8b7572c72b46879662BFEA53851cBeD3bC47a
AaveYieldModule:    0x084DD3BA96B14Ce07746E7c6AF23454dcbB65C01
RPC (Base Sepolia): https://sepolia.base.org
```

---

## 📋 Key Functions (Copy-Paste Ready)

### Create Escrow
```solidity
function createEscrow(
    address token,           // ERC20 token
    address to,              // Recipient (MUST ≠ sender!)
    uint256 amount,          // Amount to escrow
    EscrowSettings memory settings  // Config struct
) returns (uint256 workflowId)
```

### Release Escrow
```solidity
function releaseEscrowTransfer(uint256 workflowId)
```

### Cancel Escrow
```solidity
function senderCancel(uint256 workflowId) returns (bool)
```

### Query Functions
```solidity
function escrowStates(uint256 workflowId) returns (EscrowState)
function escrowTransfers(uint256 workflowId) returns (EscrowTransfer)
function getYieldAmount(uint256 workflowId, address token) returns (uint256)
function escrowInYield(uint256 workflowId, address token) returns (bool)
```

---

## 🛠️ Settings Struct

```solidity
struct EscrowSettings {
    address customResolver;      // Optional dispute resolver
    address releaseAddress;      // Optional authorized releaser
    uint8 yieldPreset;           // 0=OFF, 1=TO_SENDER
    uint256 autoReleaseTime;     // Auto-release timestamp (0=disabled)
    uint256 autoCancelTime;      // Auto-cancel timestamp (0=disabled)
}
```

---

## 📦 Minimal Integration

```typescript
// 1. Approve
await token.approve(ESCROW_VAULT, amount);

// 2. Create (no yield)
const settings = {
    customResolver: ethers.constants.AddressZero,
    releaseAddress: ethers.constants.AddressZero,
    yieldPreset: 0,
    autoReleaseTime: 0,
    autoCancelTime: 0
};
const workflowId = await escrowVault.createEscrow(
    tokenAddr, recipientAddr, amount, settings
);

// 3. Release
await escrowVault.releaseEscrowTransfer(workflowId);

// OR Cancel
// await escrowVault.senderCancel(workflowId);
```

---

## ⚠️ Critical Constraint

**Recipient MUST ≠ Sender**

```
❌ INVALID:  wallet.createEscrow(token, myAddress, amount, settings)
✅ VALID:    wallet.createEscrow(token, otherAddress, amount, settings)
```

Error if violated: `InvalidAddress(1, recipient)`

---

## 🎯 Common Flows

### No Yield
```
User → Approve → Create → Release → Recipient gets tokens
                         OR
                        Cancel → User gets tokens back
```

### With Yield (Aave Integration)
```
User → Approve → Create (yieldPreset=1) → [yield accrues 7+ days]
                                        → Release → Recipient gets + yield
```

### Multi-Sig Release
```
Sender → Create (releaseAddress=arbitrator) → Arbitrator calls release()
```

---

## 🔄 Flow Diagram

```
┌─ Create Escrow ─────────────────────┐
│ Input: token, recipient, amount     │
│ Output: workflowId (unique ID)      │
│ Fee: Protocol takes small amount    │
└─────────────────┬───────────────────┘
                  │
                  ├─→ PENDING state
                  │
        ┌─────────┴─────────┐
        │                   │
    Release            Cancel
        │                   │
        ├─→ RELEASED    ├─→ REFUNDED
        │  (to recipient) │ (to sender)
        │                   │
        └─────────────────┘
```

**Dispute Flow:**
```
┌─ PENDING ──────────────────────────┐
│  Either party can raise dispute     │
└─────────────────┬───────────────────┘
                  │
              DISPUTED
                  │
           Resolver decides
                  │
              RESOLVED
                  │
    ├─→ Auto-release or Cancel
    │
RELEASED or REFUNDED (final)
```

---

## 🔍 State Machine

| State | Can Release? | Can Cancel? | Can Dispute? | Next States |
|-------|---------|---------|---------|---------|
| PENDING | ✅ Yes | ✅ Yes | ✅ Yes | RELEASED, REFUNDED, or DISPUTED |
| RELEASED | ❌ No | ❌ No | ❌ No | (final) |
| REFUNDED | ❌ No | ❌ No | ❌ No | (final) |
| DISPUTED | ❌ No | ❌ No | ❌ No | RESOLVED |
| RESOLVED | ❌ No | ❌ No | ❌ No | RELEASED or REFUNDED (final) |

---

## ✅ Pre-Flight Checklist

```
□ Token approved to EscrowVault
□ Recipient address ≠ sender address
□ Amount > 0
□ Token contract exists
□ EscrowVault contract exists
□ Network is Base Sepolia (84532)
```

---

## 🚨 Error Codes Quick Fix

| Error | Fix |
|-------|-----|
| `InvalidAddress(1, to)` | Use different recipient address |
| `NotPending(workflowId)` | Escrow already released/cancelled |
| `NotSender(...)` | Use sender's wallet for release |
| `ERC20: insufficient allowance` | Increase token approval |
| `AccountingDeficit(...)` | Token transfer failed, check balance |

---

## 📊 Fee Structure

```
Protocol Fee: 0 bps (testnet)
              [adjust for mainnet]

Example:
  Send: 1000 tokens
  Fee: 1000 * (0 / 10000) = 0 tokens
  Recipient gets: 1000 tokens
```

---

## 🧪 Test It

```bash
# Run testnet validation
pnpm hardhat run scripts/testnet/phase1-multi-party-escrow.ts \
  --network baseSepolia

# Check contract bytecode
cast code 0x13b8b7572c72b46879662BFEA53851cBeD3bC47a \
  --rpc-url https://sepolia.base.org
```

---

## 📚 Full Documentation

For complete details, see:
- **WALLET_INTEGRATION_PACK.md** ← Full integration guide
- **DEPLOYMENT_CURRENT_STATUS.md** ← All addresses & status
- **ESCROW_VALIDATION_ROOT_CAUSE.md** ← Protocol constraints explained

---

## 🎯 Next Steps

1. **Copy minimal integration** (code above)
2. **Update addresses** for your network
3. **Test with small amounts** first
4. **Check WALLET_INTEGRATION_PACK.md** for edge cases
5. **Deploy to production**

---

## 💡 Pro Tips

✅ **Always parse workflowId from event**, not assume 0  
✅ **Validate recipient ≠ sender early**  
✅ **Check allowance before creating**  
✅ **Implement retry logic for failed txs**  
✅ **Monitor gas prices** on Base Sepolia  

---

**Ready to go!** Copy the minimal integration and start testing.

See WALLET_INTEGRATION_PACK.md for complete reference.
