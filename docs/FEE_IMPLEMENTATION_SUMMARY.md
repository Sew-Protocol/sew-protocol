# Current Fee Implementation in Contracts

**Date:** 2026-01-16  
**Status:** Updated (Yield protocol fee + appeal bond protocol fee implemented)

---

## Summary

The current contract implementation supports:

1. **Escrow fee** (charged on escrow principal at creation; governance-controlled)
2. **Yield protocol fee** (charged on yield only; default 30%; governance-controlled)
3. **Appeal bond protocol fee** (charged on appeal bonds at posting time; default 0% at launch; governance-controlled)

---

## 1. Escrow Fee ✅

**Location:** `BaseEscrow.sol`

**Implementation:**
```solidity
uint256 public escrowFee;
uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;

// Calculated at escrow creation (line 476)
uint256 fee = (amount * escrowFee) / ESCROW_FEE_DENOMINATOR;
uint256 amountAfterFee = amount - fee;
```

**Details:**
- **Fee Rate:** Configurable via governance, defaults to 1% (100 basis points)
- **When Collected:** At escrow creation
- **Formula:** `fee = (amount × escrowFee) / 10000`
- **Fee Recipient:** `escrowFeeAddress` (set via governance)
- **Governance:** Fee can be updated via `queueEscrowFee()` + `activateEscrowFee()` (Slow lane, ~9 days)

**Example:**
- Escrow amount: 1000 tokens
- Escrow fee: 100 basis points (1%)
- Fee collected: `(1000 × 100) / 10000 = 10 tokens`
- Amount after fee: `1000 - 10 = 990 tokens`

---

## 2. Yield Protocol Fee ✅ (Active)

**What it is:** A protocol fee charged on **generated yield only** (never escrow principal), when a yield generation module is enabled.

**Locations:**
- `contracts/core/BaseEscrow.sol` (parameter + governance controls)
- `contracts/YieldOps.sol` (fee deduction + transfer + event)

**Current default:**
- `yieldProtocolFeeBps = 3000` (30%)

**Collection behavior (high level):**
- If yield is generated (`actualAmount > amount`), compute:
  - `protocolFeeAmount = yield * yieldProtocolFeeBps / 10000`
  - `yieldToDistribute = yield - protocolFeeAmount`
- Transfer `protocolFeeAmount` to `escrowFeeAddress` (fee recipient)
- Distribute remaining yield via the configured yield distribution module

**Events:**
- `YieldProtocolFeeBpsUpdated(oldFeeBps, newFeeBps)` (BaseEscrow)
- `YieldProtocolFeeCollected(escrowId, token, yieldAmount, protocolFeeAmount)` (YieldOps)

---

## 3. Appeal Bond Protocol Fee ✅ (Implemented; inactive by default at launch)

**What it is:** A configurable protocol fee charged on **appeal bonds** at the time they are posted.

**Where it is applied:** In the escalation flow on the escrow contract side (before the bond is recorded in the incentive module):
- `contracts/core/BaseEscrow.sol` deducts `appealBondProtocolFeeBps` from the bond amount and transfers the fee portion to `escrowFeeAddress`.

**Defaults (launch-safe):**
- `appealBondProtocolFeeBps = 0` (0% at launch; bonds are refunded/distributed in full)

**Governance controls:**
- `queueAppealBondProtocolFeeBps(feeBps)` + `activateAppealBondProtocolFeeBps()` (slow lane, timelock role)
- Fee is **bounded** by `MAX_PROTOCOL_FEE_BPS` (immutable constant in `BaseEscrow`)

**Events:**
- `AppealBondProtocolFeeBpsUpdated(oldFeeBps, newFeeBps)` (BaseEscrow)
- `AppealBondProtocolFeeCollected(escrowId, token, bondAmount, protocolFeeAmount)` (BaseEscrow)

---

## 4. Revenue Streams (current implementation)

**Current Protocol Revenue:**

1. **Escrow fees:** basis-points fee on escrow principal at creation ✅
2. **Yield protocol fee:** basis-points fee on generated yield only ✅
3. **Appeal bond protocol fee:** basis-points fee on appeal bonds (default 0 at launch; can be activated later) ✅

---

## Conclusion

**Current Fee Implementation:**
- ✅ **Escrow fee:** charged at escrow creation
- ✅ **Yield protocol fee:** charged only on yield, default 30%
- ✅ **Appeal bond protocol fee:** implemented but default 0% at launch (no impact until activated)
