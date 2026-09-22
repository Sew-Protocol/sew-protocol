# Appeal Bond Security Review

## Issues Identified

### 1. Missing Access Control: Only Disagreed-With Participant Should Appeal

**Current State:**
- `escalateDispute()` in `BaseEscrow.sol` is `external` and can be called by anyone
- `DisputeOps.computeEscalation()` only checks if caller is a participant (`from` or `to`), but doesn't verify they are the one who disagrees with the resolution
- `DecentralizedResolutionModule.canEscalate()` doesn't check which participant should be allowed to appeal

**Expected Behavior:**
- If resolution is `RELEASE` (funds go to recipient): Only `from` (sender) should be able to appeal
- If resolution is `CANCEL` (funds go to sender): Only `to` (recipient) should be able to appeal

**Risk:**
- The "winning" participant could appeal their own win (wasteful but not critical)
- More importantly, a third party who somehow becomes a participant could appeal
- The intended participant (the one who lost) might be blocked if access control is too restrictive elsewhere

**Fix Required:**
Add validation in `DecentralizedResolutionModule.canEscalate()` or `DisputeOps.computeEscalation()` to check:
```solidity
// Get the last decision
ResolutionOutcome lastDecision = disputeMetadata[workflowId].decisionAtRound[currentLevel];

// Only allow escalation by the participant who disagrees
if (lastDecision == ResolutionOutcome.RELEASE) {
    // RELEASE means recipient wins, so sender should be able to appeal
    require(caller == from, 'Only sender can appeal RELEASE decision');
} else if (lastDecision == ResolutionOutcome.CANCEL) {
    // CANCEL means sender wins, so recipient should be able to appeal
    require(caller == to, 'Only recipient can appeal CANCEL decision');
} else {
    revert('No decision to appeal');
}
```

### 2. Currency Restrictions: Bond Token vs Escrow Token

**Current State:**
- `getRequiredAppealBond()` in `DecentralizedResolutionModule.sol` returns `bondToken` from `escalationCostConfig.bondToken` or `defaultBondToken`
- There is **NO validation** that `bondToken` matches the escrow's token (`et.token`)
- The bond token can be completely different from the escrow token (e.g., escrow in USDC, bond in ETH)

**Current Code:**
```solidity
// contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol:601-606
address bondToken = (defaultBondToken != address(0) && acceptedBondTokens[defaultBondToken])
    ? defaultBondToken
    : escalationCostConfig.bondToken;
```

**Risk:**
- Participants might not have the bond token (e.g., escrow in USDC but bond requires ETH)
- Creates friction and potential for failed escalations
- Token mixing in `claimablePayments` is already prevented by `_requirePayoutToken()`, but the bond token itself can differ

**Options:**
1. **Enforce matching tokens** (recommended for launch):
   ```solidity
   // In getRequiredAppealBond, decode escrowData to get escrow token
   (address escrowToken, , , ) = abi.decode(escrowData, (address, address, address, uint256));
   // Use escrow token as bond token
   address bondToken = escrowToken;
   ```

2. **Allow different tokens but document clearly**:
   - Document that participants must have bond token available
   - Consider adding a helper to check if participant has sufficient bond token balance

**Recommendation:** For launch, enforce matching tokens to reduce complexity and ensure participants can always appeal.

### 3. `currentFees` in EscrowAccountingLibrary

**Finding:**
- `EscrowAccountingLibrary.sol` does **NOT** have a `currentFees` function
- `currentFees` is a **local variable** used in `_recordFee()` functions in:
  - `EscrowVault.sol:133` - `uint256 currentFees = totalFeesPerToken[token];`
  - `EscrowableERC20.sol:165` - `uint256 currentFees = totalFees;`

**What it represents:**
- `currentFees` is the current total accumulated fees for a token before adding the new fee
- It's used to check for overflow: `if (amount > type(uint256).max - currentFees)`
- After the check, it's updated: `totalFeesPerToken[token] = currentFees + amount;`

**Conclusion:**
- `currentFees` is not a function or public state - it's just a local variable name
- The actual fee tracking is in `totalFeesPerToken[token]` (EscrowVault) or `totalFees` (EscrowableERC20)

## Implementation Status

### ✅ COMPLETED: Participant Validation for Appeals
**Implementation:**
- Added `getDecisionAtRound()` function to `DecentralizedResolutionModule.sol`
- Added `_getDecisionAtRound()` helper in `DisputeOps.sol`
- Added validation in `DisputeOps.computeEscalation()` to ensure only the disagreed-with participant can appeal:
  - RELEASE decision → only sender (from) can appeal
  - CANCEL decision → only recipient (to) can appeal
  - NONE decision → no appeal allowed
- Maintains backward compatibility: if module doesn't support decision tracking, escalation is allowed

**Files Modified:**
- `contracts/DisputeOps.sol` - Added participant validation logic
- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol` - Added `getDecisionAtRound()` function

### ✅ COMPLETED: Enforce Bond Token = Escrow Token
**Implementation:**
- Modified `getRequiredAppealBond()` in `DecentralizedResolutionModule.sol` to decode `escrowData` and use escrow token as bond token
- `escalationCostConfig.bondToken` and `defaultBondToken` are now ignored for security
- Ensures participants always have the required bond token (same as escrow token)

**Files Modified:**
- `contracts/decentralized-resolution-module/DecentralizedResolutionModule.sol` - Modified `getRequiredAppealBond()` to enforce matching tokens

### ✅ COMPLETED: Document `currentFees`
**Implementation:**
- Added inline comments in `_recordFee()` functions explaining that `currentFees` is a local variable representing the current total accumulated fees before adding the new fee

**Files Modified:**
- `contracts/core/EscrowVault.sol` - Added comment for `currentFees`
- `contracts/core/EscrowableERC20.sol` - Added comment for `currentFees`

## Testing Required

1. **Appeal Access Control Tests:**
   - Test sender can appeal RELEASE decisions
   - Test recipient can appeal CANCEL decisions
   - Test winning participant cannot appeal their own win
   - Test third parties cannot appeal
   - Test modules without decision tracking still work (backward compatibility)

2. **Bond Token Matching Tests:**
   - Test bond token always matches escrow token
   - Test with different escrow tokens (ERC20, native token)
   - Test that `escalationCostConfig.bondToken` is ignored

3. **Edge Cases:**
   - Test appeal when decision is NONE (should fail)
   - Test appeal at round 0 (before any decision)
   - Test appeal at final round (should be prevented by other checks)
