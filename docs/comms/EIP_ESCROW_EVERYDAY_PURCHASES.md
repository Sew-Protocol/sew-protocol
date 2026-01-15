# EIP-XXXX: Standard Interface for Escrow-Based Payments for Everyday Purchases

**Authors**: [Your Name/Organization]  
**Status**: Draft  
**Type**: Standards Track  
**Category**: ERC  
**Created**: 2025-01-XX  
**Requires**: EIP-20, EIP-165

## Simple Summary

This EIP defines a standard interface for escrow-based payment systems that enable secure, reversible transactions for everyday purchases on Ethereum. It provides a foundation for buyer protection, dispute resolution, and automated settlement mechanisms suitable for e-commerce, services, and peer-to-peer transactions.

## Abstract

Traditional on-chain token transfers are irreversible, creating a significant barrier to adoption for everyday purchases where trust between parties may be limited. This EIP proposes a standard interface for escrow contracts that:

1. **Locks funds** until delivery/completion conditions are met
2. **Enables dispute resolution** through neutral third parties
3. **Supports automated time-based releases** and cancellations
4. **Provides attachment/metadata support** for transaction context
5. **Maintains composability** with existing DeFi protocols

This standard enables marketplaces, payment processors, and dApps to implement consistent escrow functionality while maintaining interoperability across the ecosystem.

## Motivation

### Current Limitations

1. **Irreversible Payments**: Standard ERC-20 transfers are final, creating risk for buyers
2. **No Built-in Dispute Resolution**: No standard mechanism for handling transaction disputes
3. **Lack of Buyer Protection**: Sellers can receive payment without delivering goods/services
4. **Fragmented Solutions**: Each platform implements custom escrow logic, reducing composability

### Use Cases

- **E-commerce**: Buyers pay for goods that ship later
- **Services**: Freelancers receive payment upon work completion
- **Marketplaces**: Platform-mediated transactions with dispute resolution
- **Subscription Services**: Recurring payments with cancellation rights
- **Peer-to-Peer Sales**: Direct sales between individuals with protection

## Specification

### Core Interface

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;

interface IEscrowPayment {
  /// @notice Creates an escrow payment, locking funds until release conditions are met
  /// @param recipient Address that will receive funds upon release
  /// @param amount Amount of tokens to escrow
  /// @param settings Escrow configuration (resolver, auto-times, metadata)
  /// @return workflowId Unique identifier for this escrow
  function createEscrow(
    address recipient,
    uint256 amount,
    EscrowSettings calldata settings
  ) external returns (uint256 workflowId);

  /// @notice Releases escrowed funds to recipient (typically called by sender)
  /// @param workflowId Identifier of the escrow to release
  function releaseEscrow(uint256 workflowId) external;

  /// @notice Cancels escrow and refunds to sender (requires mutual agreement or timeout)
  /// @param workflowId Identifier of the escrow to cancel
  function cancelEscrow(uint256 workflowId) external;

  /// @notice Initiates a dispute, transferring resolution authority to a resolver
  /// @param workflowId Identifier of the escrow in dispute
  function raiseDispute(uint256 workflowId) external;

  /// @notice Resolves a dispute with specified payout distribution
  /// @param workflowId Identifier of the escrow to resolve
  /// @param payouts Array of payout recipients and amounts
  function resolveDispute(uint256 workflowId, Payout[] calldata payouts) external;

  /// @notice Gets the current state of an escrow
  /// @param workflowId Identifier of the escrow
  /// @return EscrowTransfer struct containing all escrow details
  function getEscrow(uint256 workflowId) external view returns (EscrowTransfer memory);

  /// @notice Gets the total number of escrows created
  /// @return count Total number of escrows
  function getEscrowCount() external view returns (uint256 count);
}

/// @notice Escrow state enumeration
enum EscrowState {
  NONE, // Escrow does not exist
  PENDING, // Funds locked, awaiting release/cancel
  RELEASED, // Funds released to recipient
  REFUNDED, // Funds refunded to sender
  DISPUTED, // Dispute raised, awaiting resolution
  RESOLVED // Dispute resolved with payout
}

/// @notice Configuration for escrow creation
struct EscrowSettings {
  address customResolver; // Optional: Custom dispute resolver (0 = use default)
  bool yieldEnabled; // Enable yield generation during escrow period
  uint256 autoReleaseTime; // Timestamp for automatic release (0 = disabled)
  uint256 autoCancelTime; // Timestamp for automatic cancellation (0 = disabled)
  EscrowType escrowType; // Type classification for categorization
  bytes metadata; // Optional metadata (IPFS hash, JSON, etc.)
}

/// @notice Escrow type classification
enum EscrowType {
  STANDARD, // Standard purchase
  SERVICE, // Service delivery
  SUBSCRIPTION, // Recurring payment
  CUSTOM // Custom type
}

/// @notice Complete escrow transfer information
struct EscrowTransfer {
  uint256 workflowId;
  address token; // ERC-20 token address
  address sender; // Address that created escrow
  address recipient; // Address that will receive funds
  uint256 amount; // Amount currently in escrow
  uint256 totalDeposited; // Total amount originally deposited
  EscrowState state; // Current state
  address disputeResolver; // Address authorized to resolve disputes
  uint256 autoReleaseTime; // Timestamp for auto-release
  uint256 autoCancelTime; // Timestamp for auto-cancel
  string[] attachmentURIs; // IPFS/HTTP URIs for attachments
  bytes32[] attachmentHashes; // Content hashes for verification
  bytes metadata; // Additional metadata
}

/// @notice Payout specification for dispute resolution
struct Payout {
  address recipient; // Address to receive payout
  uint256 amount; // Amount to pay (in escrowed token)
}

/// @notice Events
event EscrowCreated(
  uint256 indexed workflowId,
  address indexed sender,
  address indexed recipient,
  address token,
  uint256 amount
);

event EscrowReleased(uint256 indexed workflowId, address indexed recipient, uint256 amount);

event EscrowCancelled(uint256 indexed workflowId, address indexed sender, uint256 refundAmount);

event DisputeRaised(uint256 indexed workflowId, address indexed raisedBy, address indexed resolver);

event DisputeResolved(uint256 indexed workflowId, address indexed resolver, Payout[] payouts);
```

### State Machine

```
NONE → PENDING → RELEASED (via releaseEscrow)
              → REFUNDED (via cancelEscrow)
              → DISPUTED (via raiseDispute) → RESOLVED (via resolveDispute)
              → RELEASED (via autoReleaseTime)
              → REFUNDED (via autoCancelTime)
```

### Access Control

- **Sender**: Can release, cancel (with recipient agreement), or raise dispute
- **Recipient**: Can cancel (with sender agreement) or raise dispute
- **Resolver**: Can resolve disputes with arbitrary payout distribution
- **Anyone**: Can view escrow state (read-only)

### Dispute Resolution

1. Either party can raise a dispute at any time while escrow is `PENDING`
2. Upon dispute, escrow state changes to `DISPUTED`
3. A resolver (specified at creation or via resolution module) can:
   - Release full amount to recipient
   - Refund full amount to sender
   - Split funds between parties (partial resolution)
4. Resolution is final and cannot be reversed

### Auto-Release and Auto-Cancel

- **Auto-Release**: If `autoReleaseTime` is set and reached, funds automatically release to recipient
- **Auto-Cancel**: If `autoCancelTime` is set and reached, funds automatically refund to sender
- Only one auto-time can be set per escrow (mutually exclusive)
- Auto-times provide buyer/seller protection against indefinite holds

### Attachments and Metadata

- **Attachments**: IPFS/HTTP URIs for documents, images, or other evidence
- **Attachment Hashes**: Content hashes for verification
- **Metadata**: Arbitrary bytes (typically IPFS hash or JSON) for additional context
- Useful for dispute resolution and transaction history

### Yield Generation (Optional)

- Escrowed funds can generate yield via DeFi protocols (e.g., Aave, Compound)
- Yield can be distributed according to resolution outcome
- Enables fair compensation for time value of locked funds

## Rationale

### Why a Standard Interface?

1. **Composability**: DApps can integrate with any compliant escrow contract
2. **Interoperability**: Marketplaces can support multiple escrow providers
3. **User Experience**: Consistent interface across applications
4. **Innovation**: Enables ecosystem of tools, analytics, and services

### Design Decisions

1. **Workflow ID**: Sequential IDs provide simple, predictable identifiers
2. **State Machine**: Clear states prevent invalid transitions
3. **Modular Resolution**: Supports various dispute resolution mechanisms
4. **Optional Features**: Yield, attachments, and metadata are optional to reduce gas costs

### Security Considerations

1. **Reentrancy**: All state changes must follow checks-effects-interactions pattern
2. **Access Control**: Clear authorization for each action
3. **Time-based Attacks**: Auto-times use block.timestamp (with known limitations)
4. **Resolver Trust**: Resolvers have significant power; selection is critical

## Backwards Compatibility

This EIP is compatible with:

- **ERC-20**: Works with any ERC-20 token
- **ERC-165**: Supports interface detection
- **ERC-721/ERC-1155**: Can be extended for NFT escrow (future EIP)

## Test Cases

### Test Case 1: Standard Purchase Flow

1. Buyer creates escrow for $100 purchase
2. Seller ships goods
3. Buyer releases escrow
4. Seller receives $100

### Test Case 2: Dispute Resolution

1. Buyer creates escrow
2. Seller fails to deliver
3. Buyer raises dispute
4. Resolver refunds buyer
5. Escrow marked as RESOLVED

### Test Case 3: Auto-Release

1. Buyer creates escrow with 7-day auto-release
2. Buyer doesn't respond
3. After 7 days, funds automatically release to seller

### Test Case 4: Mutual Cancellation

1. Buyer creates escrow
2. Both parties agree to cancel
3. Funds refunded to buyer

## Implementation

Reference implementations:

- [EscrowableERC20](https://github.com/your-org/escrow-contracts): ERC-20 token with built-in escrow
- [EscrowVault](https://github.com/your-org/escrow-contracts): Multi-token escrow vault

## Security Considerations

1. **Resolver Selection**: Resolvers must be trusted; consider reputation systems
2. **Time Manipulation**: Auto-times rely on block.timestamp (miners can manipulate ±15 seconds)
3. **Front-running**: Senders should be aware of MEV risks when releasing
4. **Gas Costs**: Complex resolution logic may be expensive; consider L2 deployment

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
