# Wallet Integration Guide

## Overview

This protocol provides 4 core view functions that enable wallet implementations to safely display escrow state and actions consistently across all integrations.

## Core View Functions

### 1. `getState(uint256 workflowId) → EscrowState`

Returns the current state of an escrow.

**Returns**:
- `PENDING` - Escrow is active, awaiting release or cancellation
- `RELEASED` - Recipient claimed funds
- `REFUNDED` - Sender cancelled and received refund
- `DISPUTED` - Dispute was raised, pending resolution
- `RESOLVED` - Dispute was resolved by authorized resolver

**Use**: Render state badge, enable/disable action buttons, show status timeline

### 2. `getParties(uint256 workflowId) → (address sender, address recipient)`

Returns the two parties involved in the escrow.

**Returns**:
- `sender` - Address that initiated the escrow (funded it)
- `recipient` - Address designated to receive funds

**Use**: Display party avatars, names, and action prompts ("You can release" / "Awaiting your action")

### 3. `getAmount(uint256 workflowId) → (address token, uint256 amountAfterFee)`

Returns the token and amount held in escrow.

**Returns**:
- `token` - ERC20 token address (or address(this) for EscrowableERC20)
- `amountAfterFee` - Amount held in escrow after protocol fees deducted

**Use**: Display "X.XX USDC" in UI, show price in USD, enable amount input validation

### 4. `getDeadlines(uint256 workflowId) → (uint64 autoReleaseTime, uint64 autoCancelTime, uint64 disputeWindowEnd)`

Returns time-based deadlines for the escrow.

**Returns**:
- `autoReleaseTime` - Unix timestamp when escrow auto-releases (0 if disabled)
- `autoCancelTime` - Unix timestamp when escrow auto-cancels (0 if disabled)
- `disputeWindowEnd` - Unix timestamp when dispute appeal window closes (0 if not in dispute)

**Use**: Display countdown timers, show "Auto-release in X hours" warnings, indicate deadline urgency

## Typical Integration Pattern

```typescript
// Load escrow view
async function renderEscrow(escrowAddress: string, workflowId: number) {
  const contract = new ethers.Contract(escrowAddress, escrowAbi, provider);
  
  // 4 RPC calls to get complete state picture
  const [state, parties, amount, deadlines] = await Promise.all([
    contract.getState(workflowId),
    contract.getParties(workflowId),
    contract.getAmount(workflowId),
    contract.getDeadlines(workflowId)
  ]);
  
  // Render UI
  displayStateIcon(state);
  displayParties(parties.sender, parties.recipient);
  displayAmount(amount.token, amount.amountAfterFee);
  
  // Display action-relevant timers
  if (deadlines.autoReleaseTime > 0) {
    displayCountdown("Auto-release in", deadlines.autoReleaseTime);
  }
  if (deadlines.autoCancelTime > 0) {
    displayCountdown("Auto-cancel in", deadlines.autoCancelTime);
  }
  if (state === "DISPUTED" && deadlines.disputeWindowEnd > 0) {
    displayCountdown("Appeal window closes in", deadlines.disputeWindowEnd);
  }
}
```

## Action Eligibility Rules

Based on state, sender/recipient, and caller, determine which actions are available:

```typescript
function getAvailableActions(
  state: EscrowState,
  sender: string,
  recipient: string,
  caller: string
): string[] {
  const actions: string[] = [];
  
  if (state === "PENDING") {
    if (caller === recipient) {
      actions.push("release");  // Recipient can release funds
    }
    if (caller === sender) {
      actions.push("cancel");   // Sender can cancel
    }
    // Both can raise dispute
    actions.push("raiseDispute");
  }
  
  if (state === "DISPUTED") {
    // Authorized resolvers can resolve
    // Both parties can appeal (if appeal window open)
    actions.push("escalate");  // Simplified
  }
  
  if (state === "PENDING" || state === "RELEASED" || state === "REFUNDED") {
    // Other actions available depending on specific protocol
  }
  
  return actions;
}
```

## Event Listening

Subscribe to state changes via events:

```typescript
contract.on("EscrowStateChanged", (workflowId, oldState, newState, event) => {
  console.log(`Escrow ${workflowId} changed from ${oldState} to ${newState}`);
  // Refresh UI
  renderEscrow(contractAddress, workflowId);
});
```

## Error Handling

The view functions will revert if:
- `workflowId` is invalid (>= total number of escrows)

```typescript
try {
  const state = await contract.getState(9999);
} catch (error) {
  // Handle: "InvalidWorkflowId(9999, 100)"
  console.error("Escrow not found");
}
```

## Performance Considerations

- Each view function is ~2500 gas (negligible cost on testnet/mainnet)
- Batch calls with `Promise.all()` to minimize RPC roundtrips
- Cache results for 1-5 minutes unless listening to events
- Use event logs for real-time updates

## Standards Compatibility

These 4 functions follow the wallet interoperability pattern for everyday payments escrow protocols. Other implementations using this pattern will have compatible function signatures, enabling:

- Unified wallet UX across different escrow protocols
- Standardized integration for multi-protocol wallets
- Consistent end-user experience

## Next Steps

1. **Testnet Integration**: Deploy protocol to testnet
2. **ABI Access**: Use official ABI from compiled artifacts
3. **Test Integration**: Implement above pattern in your wallet
4. **Provide Feedback**: Report on:
   - Function usefulness
   - Missing view functions
   - Gas efficiency concerns
   - UX gaps
5. **Phase 2 Extensions**: If demand shows, the protocol may add:
   - `getActionStatus(workflowId)` for explicit action eligibility bitmask
   - `Released` and `Cancelled` events for better indexing
   - Additional deadline types for complex dispute scenarios

---

**Questions?** Open an issue on the repository or reach out to the protocol team.
