Approach

Produce the permission wiring (TimelockController + roles) that makes your lanes mechanically true: Standard=48h, Slow=7d, unpause timelock-only, guardian can only reduce risk.

Draft a ResolutionRouter spec that supports deterministic % rollout and “new escrows only”.

Provide a bounds table you can implement in SettingsValidationLibrary (with a slow-lane “change-the-bounds” mechanism).

1. AccessControl + TimelockController permission matrix
   Target architecture (simple + Ethereum-native)

One TimelockController (or two, see option B) holds authority over all governed contracts.

Governor (token governance) is the only PROPOSER.

Timelock is the only EXECUTOR.

CANCELLER is either:

Governor (recommended), and optionally

Guardian (optional, if you want a safety brake on queued actions)

Option A (recommended): single timelock, lane separation by function + bounds

You already have lanes; enforce lane by what’s callable, not by multiple timelocks.

TimelockController roles

PROPOSER_ROLE → Governor (or your DAO executor contract)

EXECUTOR_ROLE → address(0) (open execution) or a dedicated TimelockExecutor bot

If you set it to address(0), anyone can execute after delay (common pattern).

CANCELLER_ROLE → Governor (and optionally Guardian)

TIMELOCK_ADMIN_ROLE → itself (self-admin) (standard hardened posture)

Contract-level roles (recommended)
Define these roles in each governed contract (or in a single EscrowSettings hub):

ROLE_TIMELOCK (or DEFAULT_ADMIN_ROLE) → TimelockController

ROLE_GUARDIAN → Guardian multisig

Then gate functions:

Standard & Slow: onlyRole(ROLE_TIMELOCK)

Emergency actions: onlyRole(ROLE_GUARDIAN) but only for risk-reduction actions (pause, disable deposits, lower caps)

Why this passes scrutiny

DAO proposes → timelock delays → anyone executes.

Guardian cannot “change rules,” only reduce exposure.

Option B: dual timelock (cleaner lanes, more ops)

TimelockStandard with 48h

TimelockSlow with 7d

Slow timelock is admin of the Standard timelock (or both are controlled by the Governor)
This is very legible, but more moving parts. Given you want speed, Option A is usually sufficient if bounds are strong.

Concrete permission matrix
TimelockController (Option A)
Component Role Holder
TimelockController PROPOSER_ROLE Governor
TimelockController EXECUTOR_ROLE address(0) (recommended)
TimelockController CANCELLER_ROLE Governor (+ optional Guardian)
TimelockController TIMELOCK_ADMIN_ROLE TimelockController itself
Governed contracts (BaseEscrow, EscrowableERC20, modules, or EscrowSettings hub)
Contract Role Holder Notes
All governed contracts DEFAULT_ADMIN_ROLE (or ROLE_TIMELOCK) TimelockController Timelock-only for Standard/Slow
All governed contracts ROLE_GUARDIAN Guardian multisig Emergency risk reduction only
Fee withdrawal role ROLE_FEE_WITHDRAWER Fee recipient address Only withdrawFees

Unpause: belongs to ROLE_TIMELOCK only.

Guardian “risk reduction” permission set (your nuance request)

Guardian can perform only actions that cannot increase risk:

pause()

disableAaveDeposits() (or setAaveEnabled(false))

lowerMaxExposure(token, newCap) where newCap <= currentCap

lowerGlobalMaxExposure(newCap) where newCap <= currentCap

setEmergencyWithdrawMode(true) (optional) that stops new deposits but allows safe unwind paths

And explicitly cannot:

enable Aave

raise caps

change fee bps / recipient

swap modules

change dispute rules

Implement this by using “down-only” setters for guardian:

guardianLowerCap(uint256 newCap) with require(newCap <= cap)

timelock has setCap(uint256 newCap) within bounds

2. ResolutionRouter module spec (percentage rollout, no per-escrow admin power)
   Goals

Preserve your “1% → 100%” rollout capability.

Ensure new escrows only are affected by policy changes.

Prevent discretionary targeting of specific escrows.

Interfaces

ResolutionRouter implements IResolutionModule

It holds references to:

moduleA (DefaultResolutionModule)

moduleB (DecentralizedResolutionModule)

It reads routing policy from a governed settings store (recommended), or stores it internally with timelock-only setters.

Deterministic cohort routing (no discretion)

Routing key: use immutable properties available at escrow creation:

workflowId or escrowId (if deterministic at creation)

plus buyer, seller, token (optional)
Compute:

h = uint256(keccak256(abi.encodePacked(escrowId))) % 10_000

If h < rolloutBps → route to moduleB else moduleA

“New escrows only” enforcement (critical)

At escrow creation, BaseEscrow (or EscrowVault) should snapshot which resolution module to use for that escrow:

store escrow.resolutionModule = currentResolutionModuleAddress (router)

OR if router is default, store escrow.resolutionMode = router.route(escrowId) result (even stronger immutability)

Preferred pattern:

Store selectedResolutionImpl per escrow at creation (immutable thereafter).

Later policy changes only affect future escrows.

Governance controls

Timelock-only:

setRolloutBps(uint16 newBps) (Slow or Standard depending on your preference; I’d treat it as Standard if bounded and “new-only”)

setModuleA(address)

setModuleB(address) (Slow)

Bounds:

rolloutBps is 0..10_000

optional max step change (e.g., cannot increase by > 1000 bps per proposal unless Slow lane)

Events (for transparency)

RolloutBpsChanged(oldBps, newBps)

ResolutionImplChanged(which, old, new)

EscrowResolutionSelected(escrowId, impl) emitted at escrow creation (or first resolution action)

Safety knobs

Guardian can set rollout to 0 only (down-only) if an incident is detected:

guardianSetRolloutBps(uint16 newBps) with require(newBps <= rolloutBps)

Guardian cannot set it upward.

3. Bounds table for SettingsValidationLibrary (v1)

Below are reasonable v1 defaults with a “change-the-bounds” path:

A) Timings & attachments (Standard lane, 48h)
Parameter Suggested Min Suggested Max Notes
Default auto-cancel time 0 30 days 0 = disabled; cap prevents abusive lockups
Default auto-release time 0 30 days align with cancel cap
Max attachments 0 20 operational; prevents gas griefing
B) Fees (Slow lane, 7d)
Parameter Min Max Notes
Escrow fee (bps) 0 200 2% cap is commonly tolerable; tune as needed
Fee recipient allowlist allowlist require nonzero + EOA/contract ok
C) Yield distribution (Standard lane, 48h)
Parameter Constraint Notes
Recipient count 1..10 keep bounded
Percent sum must equal 10_000 bps use bps, not %
Recipient allowlist optional if you want compliance / treasury control
D) Resolution module mechanics
Parameter Suggested Min Suggested Max Notes
resolutionModuleDelay 48 hours 30 days min aligns with Standard lane
Router rollout bps 0 10_000 plus optional step limits
E) Aave / yield risk controls
Parameter Suggested Min Suggested Max Notes
Global max exposure 0 (policy) expressed in token units or USD oracle; choose model
Per-token max exposure 0 (policy) guardian can lower only
Aave enabled false/true — guardian can set false; timelock sets true

Important design choice: exposure caps need a unit system:

simplest: cap in raw token units per supported token

better: cap in USD using an oracle (more complex / higher attack surface)
Given your “new-only” rule and early stage, raw token caps are often acceptable.

“Change-the-bounds” mechanism (Slow lane)

Some bounds will evolve. Make bounds adjustable only via Slow (7d):

setFeeBpsMax(uint256 newMax) (Slow)

setMaxAttachmentsMax(uint256 newMax) (Slow)

etc.

Then Standard changes operate within bounds.

Assumptions

You’re comfortable with a single timelock (Option A) and enforcing lanes by function category + bounds.

You want guardian actions to be strictly “down-only” risk reduction.

You’re willing to remove/disable per-escrow admin overrides (15–18) for mainnet.

Next steps

If you tell me whether you prefer Option A (single timelock) or Option B (dual timelock), I’ll output the exact role assignment and migration steps.

I can turn the router spec into a contract interface + pseudocode aligned to your IResolutionModule.

I can generate a SettingsValidationLibrary checklist (each require, error types, and test cases).

What I need from you

Do you want single timelock (Option A) or dual timelock (Option B)?

For Aave exposure caps: do you want caps in raw token units (simple) or USD-oracle-based (complex)?

Suggested next step

Reply: “Option A + raw token caps” (or your preference) and I’ll produce the exact role wiring + concrete validation rules ready for implementation
