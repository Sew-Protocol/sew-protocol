Lowest-risk solution: EscrowCore + External Feature Contracts (composition, no delegatecall)
Target architecture

BaseEscrowCore (must be <24KB)

Stores canonical escrow state: participants, token, amount, escrow state enum, timestamps, basic workflow config, module addresses.

Implements only:

create/accept/cancel/release/refund (whatever your minimal state machine is)

dispute “entry” and “finalize outcome” hooks

max dispute timeout escape hatch (your safety valve)

minimal access control / governance wiring

External composed contracts (advanced behaviour lives here)

DisputeEscalationOps (or inside your ResolutionModule)

YieldDistributionOps (or yield module)

BatchOps (batch release/cancel, admin recoveries)

Optional: GovernanceOps (propose/queue/activate helpers)

The base calls out to these contracts using normal external calls and passes context. No delegatecall, so the risk profile stays close to what you already have.

Why this is low risk

No shared storage across contracts (no storage collision risk).

Base remains authoritative for escrow state transitions.

Modules can be audited independently and swapped via your existing governance lanes.

Where to cut 13–15KB safely (high-confidence removals)
1) Move all yield distribution logic out (big win, low protocol risk)

You already identified yield as a high-impact chunk.

Go further than “remove fallback”:

Remove from BaseEscrow:

fallback distribution logic

per-workflow distribution config setters/getters

_encodeYieldDistribution / _validateYieldDistribution

any “remainder handling”

Replace with one external call:

yieldModule.onYield(workflowId, token, yieldAmount, escrowContext)

If you need configuration, store it in the yield module, not in BaseEscrow.

Why it’s safe: yield is usually “nice-to-have.” If it fails, worst case should be “yield not distributed” (and you can route to fee address), but it shouldn’t block escrow liveness.

2) Move dispute escalation orchestration out (big win, medium risk if done carefully)

Keep BaseEscrow responsible for:

verifying the caller is a participant

verifying the escrow is in DISPUTED state

collecting/forwarding ETH fees (optional)

Move everything else to the resolution module:

determining current level

computing escalation fee

choosing next resolver

emitting module-specific events

Then return a small result back to BaseEscrow:

(newResolver, newLevel, maybe newDeadline)
and BaseEscrow writes it to its own escrow transfer struct.

Key low-risk rule: module returns a decision; BaseEscrow applies it.

3) Move “rare-path” ops out (surprisingly large bytecode wins)

These often cost a lot of runtime size for little day-to-day value:

batch release/cancel

ERC20/native recovery

governance propose/activate helpers

category key generation

any debugging/admin-only utilities

Create EscrowOps as a separate contract that calls BaseEscrow functions in a loop, with proper access control.

Why it’s safe: you’re not changing core escrow flows, only relocating convenience functions.

Special note: EscrowVault / EscrowableERC20 strategy (this is where you can save the most)

If those two are huge because they inherit BaseEscrow, the most size-effective low-risk move is:

Prefer composition over inheritance for the deployable contracts

Instead of:

contract EscrowVault is BaseEscrow { ... }

contract EscrowableERC20 is BaseEscrow, ERC20 { ... }

Do:

EscrowVault becomes a thin wrapper that holds a reference to BaseEscrowCore (or is itself the core).

EscrowableERC20 becomes:

an ERC20, plus

a reference to BaseEscrowCore,

and exposes escrow-related functions by calling the core externally.

This avoids duplicating BaseEscrow runtime code into both big contracts. It’s often the single biggest structural win.

If you need “token + escrow” to feel integrated, you can keep the UX the same by having the token forward calls to the core.

A pragmatic plan that keeps risk low
Phase 0: One measurement that prevents wasted work

Confirm whether you’re failing on runtime bytecode size for the deployable implementations you actually ship (sounds like yes). Then decide which contract becomes the canonical core.

Phase 1: Guaranteed shrink (aim 8–12KB)

Yield: move fully to module/ops contract

Dispute escalation: move orchestration to module

Batch/recovery/admin ops: move out to EscrowOps

Phase 2: Ensure derived contracts don’t re-inflate (aim 10KB+ if needed)

Convert EscrowVault and EscrowableERC20 to composition wrappers around BaseEscrowCore (stop inheriting the heavy base).

This phase is usually what makes the 24KB target achievable across multiple deployables.