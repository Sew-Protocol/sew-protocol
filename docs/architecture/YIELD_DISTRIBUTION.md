# Yield Distribution

This document describes who receives yield when escrows are released or refunded.

## Overview

When an escrow is closed (either released or refunded), any yield generated on the escrowed funds is distributed according to the following process:

1. **Protocol Fee Deduction**: A configurable percentage (default: 30%) of the yield is collected as a protocol fee
2. **Remaining Yield Distribution**: The remaining yield (70% by default) is sent to the yield distribution module for distribution to recipients

---

## When Escrow is Released

**Scenario**: Buyer receives goods, escrow is released to recipient (`et.to`)

**Yield Distribution Flow**:

1. **Protocol Fee** (30% of yield by default):
   - Amount: `yieldAmount * yieldProtocolFeeBps / 10000`
   - Recipient: `escrowFeeAddress` (governance-controlled fee recipient)
   - Transferred directly from `YieldOps` contract

2. **Remaining Yield** (70% of yield by default):
   - Amount: `yieldAmount - protocolFeeAmount`
   - Recipient: Determined by yield distribution module
   - Currently: With empty `distributionData`, yield stays in `DefaultYieldDistributionModule` contract
   - Future: Can be configured to distribute to specific recipients (buyer, seller, or both)

3. **Principal Amount**:
   - Recipient: `et.to` (buyer/recipient)
   - Delivered via claimable balance

**Summary**: 
- Protocol gets 30% of yield
- Remaining 70% of yield currently accumulates in distribution module (not yet distributed)
- Buyer gets 100% of principal

---

## When Escrow is Refunded

**Scenario**: Escrow is cancelled, funds are refunded to sender (`et.from`)

**Yield Distribution Flow**:

1. **Protocol Fee** (30% of yield by default):
   - Amount: `yieldAmount * yieldProtocolFeeBps / 10000`
   - Recipient: `escrowFeeAddress` (governance-controlled fee recipient)
   - Transferred directly from `YieldOps` contract

2. **Remaining Yield** (70% of yield by default):
   - Amount: `yieldAmount - protocolFeeAmount`
   - Recipient: Determined by yield distribution module
   - Currently: With empty `distributionData`, yield stays in `DefaultYieldDistributionModule` contract
   - Future: Can be configured to distribute to specific recipients (typically sender)

3. **Principal Amount**:
   - Recipient: `et.from` (seller/sender)
   - Delivered via claimable balance

**Summary**: 
- Protocol gets 30% of yield
- Remaining 70% of yield currently accumulates in distribution module (not yet distributed)
- Seller gets 100% of principal

---

## Current Implementation Details

### Distribution Data

Currently, `distributionData` is passed as an empty string (`''`) to the yield distribution module. This means:

- `DefaultYieldDistributionModule.distributeYield()` receives empty data
- Module returns `(true, 0)` - success but 0 distributed
- **Yield remains in the `DefaultYieldDistributionModule` contract**

### Future Configuration

To enable actual yield distribution, `distributionData` must be provided with:
- `address[] recipients` - Array of addresses to receive yield
- `uint256[] percentages` - Array of percentages in basis points (must sum to 10000)

Example for 50/50 split between buyer and seller:
```solidity
address[] memory recipients = [buyer, seller];
uint256[] memory percentages = [5000, 5000]; // 50% each
bytes memory distributionData = abi.encode(recipients, percentages);
```

---

## Code Locations

- **Yield Protocol Fee**: `contracts/YieldOps.sol::handleYield()` (lines 108-115)
- **Yield Distribution**: `contracts/YieldOps.sol::_distributeYieldInternal()` (lines 149-173)
- **Release Flow**: `contracts/core/BaseEscrow.sol::_releaseEscrowTransfer()` (lines 1582-1609)
- **Refund Flow**: `contracts/core/BaseEscrow.sol::_cancelAndRefund()` (lines 1553-1580)
- **Distribution Module**: `contracts/modules/DefaultYieldDistributionModule.sol::distributeYield()`

---

## Summary Table

| Scenario | Protocol Fee | Remaining Yield | Principal |
|----------|-------------|----------------|-----------|
| **Escrow Released** | 30% → `escrowFeeAddress` | 70% → Stays in distribution module* | 100% → Buyer (`et.to`) |
| **Escrow Refunded** | 30% → `escrowFeeAddress` | 70% → Stays in distribution module* | 100% → Seller (`et.from`) |

*Currently not distributed due to empty `distributionData`. Can be configured via governance to distribute to specific recipients.
