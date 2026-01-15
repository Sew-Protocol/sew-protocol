# Architectural Principles for Future Contract Splitting

## Decision: Single Contract (For Now)

**Current Approach**: Keep escrow and dispute resolution in a single contract (`BaseEscrow`)

**Future Consideration**: May split into `EscrowCore` + `DisputeResolution` if size constraints persist

**Principle**: Design with separation boundaries in mind, even if not splitting now.

---

## Design Principles

### 1. Clear Functional Boundaries ⭐⭐⭐⭐⭐

**Principle**: Keep escrow operations and dispute operations logically separated, even within the same contract.

**Implementation**:

- Group related functions together
- Use clear naming conventions
- Document which functions belong to which domain

**Escrow Domain Functions**:

- `createEscrow()` (primary function; `escrowTransfer()` is deprecated)
- `releaseEscrowTransfer()`
- `buyerCancel()` / `sellerCancel()` (renamed from `senderCancel()` / `recipientCancel()`)
- `_cancelAndRefund()`
- `_releaseEscrowTransfer()`
- Attachment management
- Settings management
- Auto-time execution

**Dispute Domain Functions**:

- `raiseDispute()`
- `resolverRelease()`
- `resolverPartialRelease()`
- `resolverPartialCancel()`
- `resolve()` (flexible resolution)
- Resolver management
- Resolution module management

**Why**: Makes future extraction easier - clear boundaries mean less refactoring.

---

### 2. Minimize Cross-Domain Dependencies ⭐⭐⭐⭐⭐

**Principle**: Escrow operations should not depend on dispute-specific logic, and vice versa.

**Current Dependencies**:

- ✅ Disputes depend on escrow state (necessary)
- ✅ Disputes call escrow release/cancel functions (necessary)
- ⚠️ Avoid: Escrow operations calling dispute-specific functions

**Implementation**:

- Use state enums (`EscrowState`) as the interface between domains
- Avoid direct function calls between domains when possible
- Use events for cross-domain communication when appropriate

**Why**: Reduces coupling - easier to split later.

---

### 3. State Management Separation ⭐⭐⭐⭐

**Principle**: Keep state variables organized by domain.

**Escrow State**:

- `escrowTransfers[]` - Core escrow data
- `totalEscrowsPending`
- `escrowFee`, `escrowFeeAddress`
- `totalFees`
- `maxAttachments`
- `defaultAutoReleaseTime`, `defaultAutoCancelTime`

**Dispute State**:

- `authorizedResolver`
- `resolutionModule`, `pendingResolutionModule`
- `resolutionModuleDelay`, `pendingResolutionModuleEta`
- `dao` (governance for resolution)

**Shared State** (in `EscrowTransfer` struct):

- `escrowState` - Interface between domains
- `disputeResolver` - Set by escrow, used by disputes
- `senderStatus`, `recipientStatus` - Used by both

**Why**: Clear state ownership makes extraction straightforward.

---

### 4. Interface-First Design ⭐⭐⭐⭐

**Principle**: Design functions as if they might be called from another contract.

**Implementation**:

- Use `public` or `external` for functions that might be called cross-contract
- Avoid `internal` functions that mix domains
- Document function visibility and access patterns

**Example**:

```solidity
// Good: Clear interface, could be called from DisputeResolution contract
function releaseEscrowTransfer(uint256 workflowId) public nonReentrant returns (bool)

// Good: Internal helper, but domain-specific
function _releaseEscrowTransfer(uint256 workflowId) internal

// Avoid: Internal function that mixes domains
function _handleDisputeAndRelease(uint256 workflowId) internal // BAD
```

**Why**: Makes future extraction a matter of changing visibility, not redesigning.

---

### 5. Access Control Patterns ⭐⭐⭐⭐

**Principle**: Use consistent access control patterns that can be easily adapted for cross-contract calls.

**Current Pattern**:

```solidity
modifier onlyAuthorizedResolver(uint256 workflowId) {
    require(_isAuthorizedResolver(workflowId, _msgSender()), "Not authorized");
    _;
}
```

**Future Pattern** (if split):

```solidity
// In EscrowCore
modifier onlyDisputeResolution() {
    require(_msgSender() == disputeResolutionContract, "Not dispute resolution");
    _;
}

// In DisputeResolution
modifier onlyAuthorizedResolver(uint256 workflowId) {
    require(escrowCore.isAuthorizedResolver(workflowId, _msgSender()), "Not authorized");
    _;
}
```

**Implementation**:

- Keep access control logic centralized
- Use helper functions (`_isAuthorizedResolver()`) that can be easily extracted
- Document access control requirements

**Why**: Access control is a key concern when splitting - clear patterns help.

---

### 6. Event-Driven Communication ⭐⭐⭐

**Principle**: Use events for cross-domain communication when possible.

**Current Events**:

- `EscrowStateChanged` - Signals state transitions
- `DisputeOpened` - Signals dispute initiation
- `EscrowResolved` - Signals resolution completion

**Implementation**:

- Emit events at domain boundaries
- Use events to signal state changes that other domains care about
- Keep events focused on their domain

**Why**: Events are a natural interface between contracts - already works cross-contract.

---

### 7. Library Extraction Strategy ⭐⭐⭐⭐⭐

**Principle**: Extract shared logic to libraries, but keep domain-specific logic in the contract.

**Current Libraries**:

- `SettingsValidationLibrary` - Pure validation (domain-agnostic)
- `YieldDistributionLibrary` - Yield logic (could be either domain)
- `EscrowEncodingLibrary` - Encoding/decoding (domain-agnostic)
- `ResolverLogicLibrary` - Resolver calculations (dispute domain)

**Guidelines**:

- ✅ Extract pure functions to libraries
- ✅ Extract validation logic to libraries
- ✅ Extract encoding/decoding to libraries
- ⚠️ Keep state-changing logic in contracts
- ⚠️ Keep domain-specific business logic in contracts (for now)

**Why**: Libraries can be shared between contracts if split, reducing duplication.

---

### 8. State Machine Design ⭐⭐⭐⭐⭐

**Principle**: Use clear state transitions that work both within and across contracts.

**Current State Machine**:

```
NONE → PENDING → RELEASED (escrow domain)
NONE → PENDING → REFUNDED (escrow domain)
NONE → PENDING → DISPUTED → RESOLVED (dispute domain)
```

**Implementation**:

- State transitions are atomic within a function
- State is the interface between domains
- State changes emit events

**Why**: State machine is the natural boundary between contracts.

---

### 9. Function Grouping and Organization ⭐⭐⭐

**Principle**: Group functions by domain, even within the same contract.

**Suggested Organization**:

```solidity
contract BaseEscrow {
  // ============ STATE VARIABLES ============
  // Escrow state
  // Dispute state
  // Shared state
  // ============ ESCROW DOMAIN ============
  // Create, release, cancel functions
  // Attachment functions
  // Settings functions
  // Auto-time functions
  // ============ DISPUTE DOMAIN ============
  // Dispute raising
  // Resolver functions
  // Resolution module management
  // ============ SHARED HELPERS ============
  // State validation
  // Access control
  // Yield handling
}
```

**Why**: Makes code review easier and extraction clearer.

---

### 10. Documentation of Boundaries ⭐⭐⭐⭐

**Principle**: Document which functions belong to which domain.

**Implementation**:

- Add comments marking domain boundaries
- Document cross-domain dependencies
- Note functions that would need to be extracted together

**Example**:

```solidity
// ============ ESCROW DOMAIN ============
// Functions in this section handle core escrow operations.
// If splitting, these would go to EscrowCore contract.

/**
 * @notice Release escrow transfer to recipient
 * @dev ESCROW DOMAIN - Core escrow operation
 */
function releaseEscrowTransfer(uint256 workflowId) public returns (bool) {
  // ...
}

// ============ DISPUTE DOMAIN ============
// Functions in this section handle dispute resolution.
// If splitting, these would go to DisputeResolution contract.

/**
 * @notice Resolver releases disputed escrow
 * @dev DISPUTE DOMAIN - Calls escrow domain functions
 */
function resolverRelease(uint256 workflowId) public returns (bool) {
  // ...
}
```

**Why**: Makes future extraction a documentation exercise, not a discovery exercise.

---

## Refactoring Guidelines

### When Adding New Features

1. **Identify Domain**: Is this escrow or dispute functionality?
2. **Check Dependencies**: Does it depend on the other domain?
3. **Design Interface**: How would this work if split?
4. **Group Appropriately**: Place with similar domain functions
5. **Document Boundary**: Note which domain it belongs to

### When Refactoring Existing Code

1. **Maintain Boundaries**: Don't mix domains in functions
2. **Extract Libraries**: Move pure logic to libraries
3. **Clarify Dependencies**: Make cross-domain calls explicit
4. **Update Documentation**: Reflect domain boundaries

### When Optimizing for Size

1. **Preserve Boundaries**: Don't merge domains to save space
2. **Extract to Libraries**: Move logic to libraries, not other domains
3. **Simplify Within Domain**: Optimize within domain boundaries
4. **Document Trade-offs**: Note if optimization blurs boundaries

---

## Future Split Checklist

When/if splitting becomes necessary, use this checklist:

### EscrowCore Contract

- [ ] Core escrow operations (create, release, cancel)
- [ ] Attachment management
- [ ] Settings management
- [ ] Auto-time execution
- [ ] Yield generation hooks (delegate to modules)
- [ ] State management (EscrowTransfer struct)
- [ ] Access control for DisputeResolution

### DisputeResolution Contract

- [ ] Dispute raising
- [ ] Resolver functions
- [ ] Resolution module management
- [ ] Evidence submission
- [ ] Access control for resolvers

### Shared/Interface

- [ ] `IEscrowCore` interface
- [ ] State enums (EscrowState, etc.)
- [ ] Event definitions
- [ ] Error definitions

### Libraries (Shared)

- [ ] SettingsValidationLibrary
- [ ] YieldDistributionLibrary
- [ ] EscrowEncodingLibrary
- [ ] ResolverLogicLibrary

---

## Examples of Good vs. Bad Design

### ✅ Good: Clear Domain Separation

```solidity
// ESCROW DOMAIN
function releaseEscrowTransfer(uint256 workflowId) public {
  // Escrow-specific logic
  _releaseEscrowTransfer(workflowId);
}

// DISPUTE DOMAIN
function resolverRelease(uint256 workflowId) public {
  // Dispute-specific validation
  require(_isAuthorizedResolver(workflowId, _msgSender()));
  // Calls escrow domain function
  releaseEscrowTransfer(workflowId);
}
```

### ❌ Bad: Mixed Domains

```solidity
// BAD: Mixes escrow and dispute logic
function releaseEscrowTransfer(uint256 workflowId) public {
  if (_isAuthorizedResolver(workflowId, _msgSender())) {
    // Dispute logic mixed in
  }
  // Escrow logic
  _releaseEscrowTransfer(workflowId);
}
```

### ✅ Good: State as Interface

```solidity
// ESCROW DOMAIN: Changes state
function raiseDispute(uint256 workflowId) public {
  escrowTransfers[workflowId].escrowState = EscrowState.DISPUTED;
  emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.DISPUTED);
}

// DISPUTE DOMAIN: Reads state
function resolverRelease(uint256 workflowId) public {
  require(escrowTransfers[workflowId].escrowState == EscrowState.DISPUTED);
  // ...
}
```

### ❌ Bad: Direct State Manipulation Across Domains

```solidity
// BAD: Dispute domain directly manipulating escrow state
function resolverRelease(uint256 workflowId) public {
  // Should call escrow function, not manipulate state directly
  escrowTransfers[workflowId].amount = 0; // BAD
  escrowTransfers[workflowId].escrowState = EscrowState.RESOLVED; // BAD
}
```

---

## Summary

**Key Principles**:

1. ✅ Keep functional boundaries clear
2. ✅ Minimize cross-domain dependencies
3. ✅ Organize state by domain
4. ✅ Design interfaces for future extraction
5. ✅ Use consistent access control patterns
6. ✅ Extract shared logic to libraries
7. ✅ Document domain boundaries
8. ✅ Group functions by domain

**Goal**: Make future splitting a matter of cutting along clear lines, not redesigning.

**Current Status**: Single contract, but designed for easy future splitting.

---

**Last Updated**: Current Date  
**Status**: Active Design Principles
