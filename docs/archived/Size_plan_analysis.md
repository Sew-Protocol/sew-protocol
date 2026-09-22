Updated plan:
(original plan is below)

Improvements to Phase 1–3 (to keep risk low and size wins real)
Phase 1: Yield extraction — make it non-blocking and non-reentrant

You correctly label this low risk, but only if you lock down failure modes.

Recommended pattern

BaseEscrow triggers yield distribution via external call, but must not allow yield logic to brick core flows.

If yield is genuinely non-critical, then failures should not revert release/refund.

Concrete guardrails

Use try/catch around yieldOps.handleYield(...) and emit an event if it fails.

Ensure YieldOps cannot reenter core escrow functions (either make YieldOps a “dumb” contract or add reentrancy protection around the yield call site).

If YieldOps needs tokens, prefer it to be pull-based (it calls core.claimYield(...)), not push-based, unless you’re confident in token transfer behavior.

Size impact note

Moving yield out will only reduce runtime size if you also remove:

encoding helpers

fallback logic

validation helpers

distribution storage/config from core (or at least stop referencing it)

If you leave “just in case” codepaths, the bytecode savings may be less than expected.

Phase 2: Dispute escalation — keep atomicity by using “compute → apply” with a single external call

Your proposed signature is very close to the safest approach.

Best low-risk pattern

BaseEscrow does:

minimal state/permission checks

fee collection (optional)

a single call to DisputeOps / module to compute next values

applies result to storage

No callbacks. No module writing BaseEscrow state.

Critical atomicity guarantee

Ensure computeEscalation(...) is pure/view-ish or if it modifies module state (workload counters etc.), it should do so in a way that is consistent with BaseEscrow applying the result.

If module state must change, you want a single call that returns the outcome and updates module state in the same transaction, then BaseEscrow applies it.

Avoid this

“Module updates resolver via callback” (adds complexity + failure modes + reentrancy surface).

Phase 3: Ops extraction — absolutely do this (and do it earlier)

Batch/admin functions are ideal to remove early because:

they bloat runtime size

they are not on critical user paths

they are easy to test

One tweak: ensure Ops contracts don’t expand attack surface:

keep Ops methods onlyRole(...) (or whichever governance lane applies)

Ops should be thin “for-loop forwarders” only

Reframing Phase 4 to lower risk: “Incremental composition” (not a big-bang rewrite)

Your plan correctly identifies Phase 4 as the highest impact. The risk comes from doing it as a single major architecture change.

Here’s a cleaner, lower-risk variant:

Phase 4A: Stop inheriting BaseEscrow in one contract first (pilot composition)

Pick EscrowableERC20 or EscrowVault (whichever is less entangled) and convert only that one to composition.

Keep BaseEscrow as-is (for now).

Create a new wrapper contract EscrowVaultV2 (composition).

Keep old contract for reference / migration.

Validate:

function parity

event parity (or documented differences)

gas deltas

invariants

Once one wrapper is stable, do the second.

This turns “High risk” into “Medium” because you’re not changing BaseEscrow itself yet, only the consumer structure.

Phase 4B: Optional rename BaseEscrow → EscrowCore later

Renaming/repackaging BaseEscrow can be deferred until you’re confident.

Why this works

The main bytecode win is eliminating BaseEscrow bytecode duplication in EscrowVault and EscrowableERC20.

You can eliminate duplication without touching BaseEscrow internals immediately.

One strategic question: do you actually need both EscrowVault and EscrowableERC20 to be deployable monoliths?

If both are “products” people deploy, then yes they must be <24KB.

If one is mainly “an example implementation,” you can:

keep the example as a wrapper and not require it to include all features

reduce scope

This is often the most aligned approach with “keep base simple.”

Suggested “minimal base” contract definition (what stays in BaseEscrow/Core)

To keep risk low, BaseEscrow should own only:

escrow state machine transitions

funds movement (token/native) and final accounting

dispute state entry/exit + safety timeout

module address registry & governance gates

essential events

Everything else:

yield distribution

dispute escalation orchestration

batch/admin helpers

category key generation

complex encoding
…moves out.

Tightened execution order (more reliable than the week plan)

If your goal is “get under 24KB as fast and safely as possible”:

Phase 3 (Ops extraction) first: quick, low-risk, immediate bytecode relief

Phase 1 (Yield) next: remove big optional chunk

Phase 2 (Escalation) next: medium-risk but large win

If still >24KB: Phase 4A incremental composition on one contract

This order reduces chance you spend time on risky refactors before harvesting easy wins.

Older plan:

Migration Plan: Reduce EscrowVault & EscrowableERC20 to <24KB

Problem Analysis

Both contracts inherit from BaseEscrow (~1693 lines), causing code duplication and exceeding 24KB
bytecode limit. The analysis identifies three high-impact areas for size reduction.

Migration Strategy (Phased Approach)

---

Phase 1: Extract Yield Logic (~4-6KB savings)

Contracts to Create:

     - YieldOps.sol - External yield orchestration contract

Changes to BaseEscrow:

     - Remove inline yield distribution from release(), refundBuyer(), refundSeller()
     - Replace with single external call: yieldOps.handleYield(workflowId, token, amount)
     - Keep only module references and minimal yield triggering
     - Remove YieldHandlingLibrary inline calls

Changes to EscrowVault/EscrowableERC20:

     - Add YieldOps reference
     - Remove yield-related functions if any

Risk Level: LOW

     - Yield is non-critical; failure doesn't block escrow lifecycle
     - Already modularized via IYieldDistributionModule

---

Phase 2: Extract Dispute Escalation Orchestration (~3-5KB savings)

Contracts to Create:

     - DisputeOps.sol - Escalation orchestration

Changes to BaseEscrow:

     - Keep only:
       - disputeRaisedTimestamp tracking
       - State verification (caller is participant, state is DISPUTED)
       - Updating resolver/level based on returned values
     - Move to DisputeOps:
       - Escalation fee calculation
       - Level progression logic
       - Complex event emission
       - Resolution module interaction

Function Pattern:

     // In BaseEscrow
     function escalateDispute(uint256 workflowId) external {
         // Basic validation
         (address newResolver, uint8 newLevel, uint256 newDeadline) =
             disputeOps.computeEscalation(workflowId, msg.sender, escrowTransfers[workflowId]);
         // Apply result
         escrowTransfers[workflowId].disputeResolver = newResolver;
         escrowTransfers[workflowId].escalationLevel = newLevel;
     }

Risk Level: MEDIUM

     - Requires careful separation of state updates
     - Must maintain atomicity guarantees

---

Phase 3: Extract Batch & Admin Operations (~2-4KB savings)

Contracts to Create:

     - EscrowOps.sol (already exists - verify/extend)

Move from BaseEscrow to EscrowOps:

     - Batch release functions
     - Batch cancel functions
     - Token/ETH recovery functions (if in BaseEscrow)
     - Admin debugging utilities
     - Category key generation (if present)

Pattern:

     // EscrowOps
     function batchRelease(uint256[] calldata workflowIds) external {
         for (uint i = 0; i < workflowIds.length; i++) {
             baseEscrow.release(workflowIds[i]);
         }
     }

Risk Level: LOW

     - No core logic changes
     - Convenience functions only

---

Phase 4: Composition over Inheritance (CRITICAL - ~8-12KB savings per contract)

This is the highest impact change for EscrowVault and EscrowableERC20.

Current Structure (Problematic):

     contract EscrowVault is BaseEscrow { ... }
     contract EscrowableERC20 is ERC20, BaseEscrow { ... }

Problem: Both contracts duplicate BaseEscrow bytecode (~50KB each)

Target Structure:

Option A: Thin Wrapper Pattern

     contract EscrowVault {
         BaseEscrow public immutable escrowCore;

         function createEscrow(...) external returns (uint256) {
             return escrowCore.createEscrow(...);
         }
         // Delegate all escrow methods
     }

Option B: BaseEscrow Becomes EscrowCore (Recommended)

     - Rename BaseEscrow → EscrowCore (make standalone, not abstract)
     - EscrowVault holds reference to EscrowCore
     - EscrowableERC20 holds reference to EscrowCore
     - Both forward escrow calls to EscrowCore

Risk Level: HIGH

     - Major architectural change
     - Requires extensive testing
     - Benefits: Eliminates all code duplication

---

Implementation Order

Week 1: Phase 1 (Yield Extraction)

     - Create YieldOps.sol
     - Refactor BaseEscrow.release(), refundBuyer(), refundSeller()
     - Update tests
     - Measure size reduction

Expected Result: EscrowVault: 28-30KB, EscrowableERC20: 28-30KB

Week 2: Phase 3 (Quick Win - Batch/Admin Ops)

     - Audit EscrowOps.sol
     - Move batch functions if in BaseEscrow
     - Move recovery functions
     - Update tests

Expected Result: EscrowVault: 26-28KB, EscrowableERC20: 26-28KB

Week 3: Phase 2 (Dispute Escalation)

     - Create DisputeOps.sol
     - Carefully separate state vs logic
     - Extensive testing of escalation flows
     - Measure size

Expected Result: EscrowVault: 23-25KB, EscrowableERC20: 23-25KB

Week 4 (If Still Over Limit): Phase 4 (Composition)

     - Design composition architecture
     - Create EscrowCore (from BaseEscrow)
     - Refactor EscrowVault to use composition
     - Refactor EscrowableERC20 to use composition
     - Comprehensive integration testing
     - Gas benchmarking

Expected Result: Both contracts <20KB

---

Size Validation Commands

After each phase:

     npx hardhat compile
     npx hardhat size-contracts
     # Or
     forge build --sizes

---

Testing Requirements

Each phase must include:

     - Unit tests for new external contracts
     - Integration tests for cross-contract calls
     - Regression tests for existing functionality
     - Gas cost comparison (external calls add ~2.6k gas)
     - Security audit review for Phase 2 & 4

---

Rollback Plan

     - Each phase in separate PR/branch
     - Feature flags for new external contracts
     - Maintain old code paths initially
     - Progressive rollout on testnet

---

Success Metrics

     - ✅ EscrowVault <24KB (target: 22KB)
     - ✅ EscrowableERC20 <24KB (target: 22KB)
     - ✅ No gas regression >10% for common operations
     - ✅ All existing tests pass
     - ✅ No new security vulnerabilities
