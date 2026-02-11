# Escrow Protocol Interface: Design Decisions & Non-Goals

**Version**: v1.0  
**Date**: 2026-02-06  
**Status**: PROVISIONAL - Internal clarity interface, not an ERC standard  

---

## Executive Summary

This document explains WHY `IEscrowCore` is designed the way it is, and what we're deliberately NOT doing yet.

**TLDR**:
- `IEscrowCore` = audit clarity + integrator discovery NOW
- ERC-ESCR standard talk = AFTER Magicians feedback
- Dispute semantics = deferred until resolver architecture stabilizes

---

## Goals (v1)

### ✅ What We're Doing

1. **Audit clarity**: Give auditors a clear interface to verify.
   - "Here's the public surface area."
   - "Here's what must be stable."
   - Reduces review scope.

2. **Integrator discovery**: Help external developers find escrow implementations quickly.
   - "What methods are stable across vendors?"
   - "What events can I rely on?"

3. **Low-risk documentation**: Mirror what exists (v1), don't redesign.
   - Reduces chance of breaking things by optimizing prematurely.
   - Makes the interface a faithful snapshot, not an architectural vision.

4. **Future-proof for evolution**: Signal that more interfaces may come.
   - Comments explicitly say "IEscrowPayment and IEscrowDispute are planned, not locked."
   - Prevents someone treating `IEscrowCore` as "the final interface forever."

### ❌ What We're NOT Doing (Yet)

1. **Claiming ERC standard status**: We're not submitting this to EIP editors, not claiming "ERC-ESCR".
   - This is a protocol interface, not a ratified standard.
   - Standards should have external consensus.

2. **Splitting into multiple interfaces**: `IEscrowPayment`, `IEscrowDispute`, etc. are future work.
   - Requires integrator + resolver feedback first.
   - Premature split might hide important semantics (e.g., what does "settlement" mean in your model?).

3. **Mandating implementation details**: We're not prescribing:
   - How `createEscrow()` signature should look (token param order, settings struct, etc)
   - Whether settlement is push-based or pull-based
   - Whether dispute resolver is on-chain module or external arbitrator
   - Reason: Different models (EscrowVault vs EscrowableERC20 already show this)

4. **Removing/changing existing implementations**: `IEscrowCore` is additive only.
   - BaseEscrow stays as-is; we're just formally documenting its public methods.
   - Child implementations (EscrowVault, EscrowableERC20) don't need code changes.

---

## Key Design Decisions

### Decision 1: Why Minimal Facade, Not Full Coverage?

**Choice**: `IEscrowCore` covers only the happy path (create, settle, dispute-raise) + critical view methods.

**Rejected**: Full interface including all admin, yield, recovery, module management methods.

**Rationale**:
- Admin methods are operator-only; integrators don't need them.
- Yield & module management are likely to be split into separate interfaces (v2).
- Recovery methods are edge cases; exposing them as "core" suggests they're normal.
- Smaller interface = easier to understand + lower coupling for integrators.

**Tradeoff**: Some methods in BaseEscrow aren't formalized. That's okay for v1; we can add them later if needed.

---

### Decision 2: Why No `createEscrow()` Signature?

**Choice**: `IEscrowCore` documents that `createEscrow()` exists, but NOT its signature.

**Rejected**: Mandating a single signature like `createEscrow(address to, uint256 amount)`.

**Rationale**:
- EscrowVault's version: `(address token, address to, uint256 amount, EscrowSettings settings)`
- EscrowableERC20's version: `(address to, uint256 amount, EscrowSettings settings)`
- Forcing one signature either:
  - (A) breaks one implementation, or
  - (B) adds unnecessary unused parameters

**Instead**: We document both implementations' signatures in `INTERFACE_DISCOVERY_MAP.md` and let integrators adapt.

**Why this works**: Creation is rare in integrator code (usually called once per use case). Settlement/dispute/query are the hot paths.

---

### Decision 3: Why Add `getResolutionMode()` and `getActiveDisputeHandler()` NOW?

**Choice**: Adding two new view methods (not yet in BaseEscrow).

**Rationale**:
- These are the #1 integrator question when a dispute arises: "Who's handling this?"
- Low risk: additive, no signature changes.
- High value: removes ambiguity about dispute handling.
- Aligns with the design review's "Critical Issue 1" observation.

**Implementation**:
```solidity
function getResolutionMode(uint256 workflowId) external view returns (string);
function getActiveDisputeHandler(uint256 workflowId) external view returns (address);
```

These should be added to `BaseEscrow` (trivial, just state queries) and automatically inherited by children.

---

### Decision 4: Why NO `IEscrowPayment` or `IEscrowDispute` Yet?

**Choice**: Deferring these until post-feedback.

**Rejected**: Creating a full interface split now (Model B from design review).

**Rationale**:
- **Uncertain split points**: We don't yet know what "payment" means across different implementations.
  - Is it just settlement mechanics?
  - Does it include fees, yield handling, bond handling?
  - Is settlement "push" (escrow decides recipient) or "pull" (recipient claims)?
  
- **Resolver architecture still evolving**: Dispute semantics depend on:
  - Should resolver be called on-chain (module) or off-chain (oracle)?
  - Can resolver be an EOA, or must be contract?
  - Should dispute have escalation? Appeals? Bonds?

- **Magicians feedback will clarify**: Once integrators weigh in, we'll know better how to split.

**Plan**: Post v1 to Magicians with **concrete questions** about payment and dispute, gather feedback for v2 design.

---

### Decision 5: Why Location = `contracts/interfaces/`, NOT `contracts/standards/`?

**Choice**: Put `IEscrowCore.sol` in `contracts/interfaces/` alongside other protocol interfaces.

**Not in**: `contracts/standards/` (which signals "this is meant to be external standard").

**Rationale**:
- `interfaces/` = internal clarity + protocol surface
- `standards/` = external commitment + immutability expectations
- Once it's in `standards/`, ecosystem depends on it; moving/changing becomes costly.
- `interfaces/` is lower commitment: "This is how OUR escrow works; others may differ."

**Post-Magicians**: If we get consensus, we can move to `standards/` or submit to EIP editors. For now, stay conservative.

---

## What WILL NOT Change in v1.0 (Stability Guarantees)

✅ Frozen:
- Function signatures (no param reordering, type changes)
- Event signatures (no field removal/reordering)
- Return value semantics (no surprise behavior changes)
- Error codes (documented errors must stay documented)

✅ May grow:
- New optional functions (v1.1, v1.2, etc)
- New event variants (additional events, not removing)
- Additional documentation/comments

❌ Will break in v2.0:
- Signature changes (if clarifications needed)
- Interface splits (if we move to Model B)
- Removal of "deprecation candidates" (if marked in v1.x)

---

## Open Questions for Integrators & Magicians

### Settlement
- Q: Should settlement be "pull" (recipient calls `withdrawEscrow`) or "push" (escrow sends automatically)?
- Q: Should settlement fee be deducted before or after release?
- Q: If yield is accrued, should principal + accrued yield be settled, or just principal?

### Dispute Lifecycle
- Q: Should `raiseDispute()` be callable by anyone, or only participants?
- Q: Should dispute resolution be on-chain (resolver contract) or off-chain (result posted)?
- Q: Should escrow allow multiple dispute raises, or lock after first?

### Tokens & Cross-Chain
- Q: Should a single escrow contract support multiple tokens, or one token per contract?
- Q: Should settlement allow different token (e.g., USDC principal -> USDT yield)?

### Integrator Concerns
- Q: Should query methods (getResolutionMode, getEscrowState) be mandatory or optional?
- Q: Should events be indexed the same way across implementations?
- Q: Should there be a standard for escrow metadata / additional fields?

---

## Backwards Compatibility: How We Handle Changes

### Example: Adding `getEscrowMetadata()` in v1.1

```solidity
// v1.0 interface (frozen)
interface IEscrowCore {
    function withdrawEscrow(uint256 workflowId) external returns (uint256);
    // ...
}

// v1.1 interface (additive)
interface IEscrowCore {
    function withdrawEscrow(uint256 workflowId) external returns (uint256);
    function getEscrowMetadata(uint256 workflowId) external view returns (string); // NEW
    // ...
}
```

Old code expecting `IEscrowCore` still works; new code can call the new method.

### Example: Changing `getResolutionMode()` Return Type in v2.0

```solidity
// v1.x (string, generic)
function getResolutionMode(uint256 workflowId) external view returns (string);

// v2.0 (enum, specific)
enum ResolutionMode { DIRECT_USER, MODULE_CONTRACT, ARBITRATION_SERVICE }
function getResolutionMode(uint256 workflowId) external view returns (ResolutionMode);
```

This is a BREAKING change = requires v2 interface. Old integrations may choose to stay on v1, or migrate.

---

## FAQ

### Q: Is this an ERC?
A: No. It's a protocol interface for our escrow implementation. Once Magicians gives feedback and we reach community consensus, we MIGHT formalize an ERC. For now, it's provisional.

### Q: Can I use this interface for my own escrow implementation?
A: Absolutely! That's the goal. Implement `IEscrowCore`, and auditors + integrators know what to expect.

### Q: Why not just use BaseEscrow as the interface?
A: BaseEscrow is abstract and inheritance-heavy. `IEscrowCore` is a minimal facade that any escrow (even non-inherited) can implement. Cleaner for external integrators.

### Q: Will there be a reference implementation?
A: Yes: EscrowVault and EscrowableERC20 both implement `IEscrowCore` semantics. They're reference examples.

### Q: What if I disagree with the interface?
A: Great! Post on Magicians or open an issue. This is v1; we're still gathering feedback.

### Q: When will this move to EIP draft status?
A: Only after integrator feedback + Magicians discussion shows consensus. Probably post-launch (Q2/Q3 2026) once we have real integrations.

---

## Metrics: Tracking Success

We'll measure success of `IEscrowCore` by:

1. **Audit clarity**: Do security reviews get through faster? (Check with auditors post-review)
2. **Integrator adoption**: Do external teams implement `IEscrowCore` for their escrows?
3. **Magicians feedback**: Do we get substantive questions on Magicians that improve v2 design?
4. **Stability**: Do we need breaking changes in v1.x? (If yes, we're not listening to feedback)

---

## See Also

- `INTERFACE_DISCOVERY_MAP.md` - What implements what, where to find methods
- `contracts/interfaces/IEscrowCore.sol` - The actual interface
- `contracts/core/BaseEscrow.sol` - Reference implementation of IEscrowCore semantics
- `contracts/core/EscrowVault.sol` - Multi-token escrow (implements IEscrowCore)
- `contracts/core/EscrowableERC20.sol` - Single-token escrow (implements IEscrowCore)
