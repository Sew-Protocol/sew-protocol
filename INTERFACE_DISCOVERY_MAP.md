# Escrow Protocol Interface Discovery Map

**Version**: v1.0  
**Status**: PROVISIONAL - Internal clarity interface, not a standard  
**Last Updated**: 2026-02-06

---

## Overview

This document maps which contracts implement which protocol interfaces, enabling integrators and auditors to quickly understand the escrow surface area.

### Core Principle

We're documenting **what exists today** (v1) for clarity, not prescribing what must exist. Future versions may split these interfaces or add new ones. This is NOT an ERC standard claim.

---

## Interface: IEscrowCore

**Location**: `contracts/interfaces/IEscrowCore.sol`  
**Purpose**: Minimal facade covering core lifecycle (creation, settlement, disputes)

### Implementations

| Contract | File | Status | Notes |
|----------|------|--------|-------|
| `BaseEscrow` | `contracts/core/BaseEscrow.sol` | ✅ Partial | Abstract base; public methods exist but not formally implementing interface |
| `EscrowVault` | `contracts/core/EscrowVault.sol` | ✅ Partial | Multi-token implementation, inherits from BaseEscrow |
| `EscrowableERC20` | `contracts/core/EscrowableERC20.sol` | ✅ Partial | Single-token (ERC20) implementation, inherits from BaseEscrow |

**Next Steps**:
- [ ] Add explicit `is IEscrowCore` to BaseEscrow
- [ ] Verify all methods are present in child implementations
- [ ] Handle implementation-specific signatures (createEscrow takes different args)

---

## Planned Interfaces (v2+, NOT yet implemented)

### IEscrowPayment (Deferred)

**Goal**: Separate interface for payment-specific logic
- Settlement mechanics (push vs pull)
- Fee structures and calculations
- Yield handling callbacks

**Status**: Under research; depends on integrator feedback

**Questions for Magicians**:
- Should "settlement" be part of core escrow, or separated into payment module?
- Should fees be exposed via queryable methods (getEscrowFee, etc)?

### IEscrowDispute (Deferred)

**Goal**: Separate interface for dispute resolution  
**Status**: Under research; depends on resolver architecture feedback

**Open questions**:
- How much of dispute logic should be required vs optional?
- Should getResolutionMode() suffice, or need full dispute interface?
- Should resolver address be required in core interface?

---

## Current Method Mapping

### Creation (implementation-specific)

```solidity
// EscrowVault.sol - Multi-token version
function createEscrow(
    address token,
    address to,
    uint256 amount,
    EscrowSettings memory settings
) public returns (uint256 workflowId);

// EscrowableERC20.sol - Single-token (this) version
function createEscrow(address to, uint256 amount, EscrowSettings memory settings) 
    public returns (uint256 workflowId);

// BaseEscrow - Common internal dispatcher
function _createEscrowInternal(...) internal returns (uint256);
```

**Why different signatures?**: EscrowVault accepts any ERC20; EscrowableERC20 is always address(this).

**For IEscrowCore**: We DON'T mandate createEscrow signature (intentionally) because the token parameter differs. Integrators read implementation-specific docs.

### Settlement (Happy Path)

✅ Present in `BaseEscrow`, inherited by children:

```solidity
function withdrawEscrow(uint256 workflowId) external returns (uint256 amount);
function senderCancel(uint256 workflowId) external returns (bool success);
function recipientCancel(uint256 workflowId) external returns (bool success);
```

### Dispute (Contested Path)

✅ Present in `BaseEscrow`, inherited by children:

```solidity
function raiseDispute(uint256 workflowId) external;
function executePendingSettlement(uint256 workflowId) external;

// NEW (added to support IEscrowCore)
function getResolutionMode(uint256 workflowId) external view returns (string);
function getActiveDisputeHandler(uint256 workflowId) external view returns (address);
```

### State Query

✅ Present in `BaseEscrow`:

```solidity
function getEscrowCount() external view returns (uint256);
function getEscrowState(uint256 workflowId) external view returns (EscrowState);
```

---

## Events: What Integrators Can Index

**Implemented** (in BaseEscrow):

```solidity
event EscrowTransferCreated(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
event EscrowTransferReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
event EscrowTransferCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
event DisputeRaised(uint256 indexed workflowId, address indexed raiser);
event DisputeResolved(uint256 indexed workflowId, address indexed winner, uint256 amount);
```

**Note**: Some events are emitted via child contracts (EscrowVault, EscrowableERC20), not BaseEscrow directly.

---

## What's NOT in IEscrowCore (Intentional)

### Omitted (Implementation-Specific or Operator-Only)

❌ **Configuration / Admin**
- `setEscrowFeeBps()` - operator-only, in BaseEscrow but not integrator-facing
- `setTimeoutConfig()` - operator-only
- `setResolutionModule()` - operator-only
- Reason: These are governance, not protocol surface

❌ **Yield Generation**
- `initializeYield()`, `registerYieldProvider()` - out of scope for "core"
- Reason: Will likely be split into `IEscrowYield` interface if standardized

❌ **Module Management**
- `proposeModule()`, `getModule()` - lifecycle management
- Reason: Will likely be split into `IEscrowModules` interface

❌ **Emergency / Recovery**
- `recover()`, `recoverTokens()` - rare path
- Reason: Implementation-specific; not core escrow semantics

---

## Backwards Compatibility Policy (v1)

1. **Additive only in v1.x**: New methods added with semver patch bumps (v1.0 -> v1.1)
2. **No signature changes**: Existing function signatures frozen until v2.0
3. **Event stability**: Events are append-only; no field reordering
4. **Extension pattern**: New functionality via additional functions, not overloads

**Breaking Changes** (v2.0 only):
- Interface splits (e.g., `IEscrowCore` -> `IEscrowCore` + `IEscrowPayment`)
- Signature changes for clarity
- Removing deprecated methods

---

## Magicians Feedback Thread (TBD)

Once this interface is validated, we'll post to Ethereum Magicians with these questions:

1. **Lifecycle**: Is the PENDING→DISPUTED→RESOLVED flow standard enough for escrow, or are there other flows we're missing?
2. **Resolution**: Should `getResolutionMode()` and `getActiveDisputeHandler()` be required in a standard?
3. **Settlement**: Should settlement be "push" (escrow sends) or "pull" (recipient claims)? Or both?
4. **Fees**: Should escrow fees be explicitly queryable (e.g., `getEscrowFee(workflowId)`)?
5. **Token support**: Single-token vs multi-token - should this be an interface split?
6. **Events**: Are these events sufficient for indexers, or missing critical data?
7. **Dispute handler**: Should this always be a contract address, or can it be an EOA (for direct user dispute)?

---

## Contributing

If you're implementing an escrow and want to map your implementation:

1. Review `IEscrowCore`
2. Implement all public methods (or document why one is omitted)
3. Submit a PR updating this table
4. Include brief notes on your resolution strategy

**Reference implementations**: EscrowVault (multi-token), EscrowableERC20 (single-token)
