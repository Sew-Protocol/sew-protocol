Approach

Finalize Option A (single timelock) into an implementable wiring plan: exact roles, ownership transfers, and function gating rules.

Convert the bounds table into concrete validation rules + error set + test checklist for SettingsValidationLibrary.

Turn the ResolutionRouter spec into an implementation-ready contract outline aligned to your “new escrows only” policy.

1) Single Timelock wiring plan (implementable)
1.1 TimelockController config (48h standard, 7d slow within one timelock)

With a single TimelockController, you can’t have two native delays. So we enforce lane delays at the application layer:

Timelock delay = 48 hours (global)

Slow lane (7 days) enforced via:

a minEta check stored per-change (your existing propose/activate mechanism), or

a generic “two-step queue/activate” wrapper for slow actions.

Recommended hybrid (minimal changes, strongest story):

Keep Timelock delay at 48h for all executions.

For Slow lane actions, require a second, contract-enforced delay of 7 days (two-step queue/activate), similar to your resolution-module activation.

This yields:

Standard actions: Governor → Timelock (48h) → execute

Slow actions: Governor → Timelock (48h) → queueX() (records ETA=now+7d) → after 7d Governor→Timelock (48h) → activateX()

Yes, it means Slow takes ~9 days wall-clock (48h + 7d + 48h). If you want Slow to be exactly 7 days wall-clock, the cleanest way is dual timelocks—but you chose single, so this is the safe and credible trade.

If you’d rather keep wall-clock closer to ~7d, we can set timelock delay to 24h and enforce 7d in-contract for slow; but you explicitly want Standard=48h, so I’m sticking to that.

1.2 TimelockController roles (exact)

PROPOSER_ROLE → Governor (your onchain DAO governor)

EXECUTOR_ROLE → address(0) (open execution; common + censorship-resistant)

CANCELLER_ROLE → Governor (optionally add Guardian; I’d start with Governor-only)

TIMELOCK_ADMIN_ROLE → TimelockController itself (self-admin)

1.3 Contract roles & gating (exact)

Across governed contracts (or preferably one EscrowSettings hub):

ROLE_TIMELOCK (or DEFAULT_ADMIN_ROLE) → TimelockController

ROLE_GUARDIAN → Guardian multisig

ROLE_FEE_WITHDRAWER → fee recipient address (EscrowVault only)

Gating rules:

Standard: onlyRole(ROLE_TIMELOCK) + bounded validation

Slow: onlyRole(ROLE_TIMELOCK) + must be “activated” after queuedAt + 7 days

Emergency: onlyRole(ROLE_GUARDIAN) and strictly down-only

Unpause:

unpause() → onlyRole(ROLE_TIMELOCK) (as requested)

2) Slow-lane enforcement pattern (reusable)

You already have:

proposeResolutionModule()

activateResolutionModule()

Extend the same idea to other slow surfaces. Two ways:

2.1 Minimal-code approach: add per-surface queue/activate

Add to the contract where the value lives:

Example: Fee recipient

queueEscrowFeeAddress(address newAddr) (timelock-only)

stores pendingFeeAddress

stores feeAddressEta = block.timestamp + 7 days

emits FeeAddressQueued(old,new,eta)

activateEscrowFeeAddress() (timelock-only)

requires block.timestamp >= feeAddressEta

sets live value

clears pending

emits FeeAddressActivated(old,new)

Repeat for:

setEscrowFee (or queue/activate fee)

default module setters (19–22)

Aave pool provider (24)

setDao (9)

escalation config (29)

2.2 Cleaner approach: central EscrowSettings hub

Put all slow parameters and module addresses into EscrowSettings, so you implement queue/activate once per surface in one place.

Given your current spread, I recommend you eventually converge here, but the minimal approach above works now.

3) Guardian nuanced precautions (raw token caps)

Add these guardian-only down-only functions to the Aave module (or a YieldRiskManager module):

guardianDisableAave() → sets enabled=false

guardianLowerGlobalCap(address token, uint256 newCap) with require(newCap <= cap)

guardianLowerTokenCap(address token, uint256 newCap) with require(newCap <= cap)

And timelock-only:

setTokenCap(address token, uint256 newCap) with require(newCap <= CAP_MAX[token])

setGlobalCap(address token, uint256 newCap) similarly

setAaveEnabled(true) timelock-only

Caps in raw token units:

store cap[token] in smallest units (wei-like)

enforce at deposit time: currentExposure[token] + amount <= cap[token]

Exposure measurement:

simplest: track internal “principal deposited” net of withdrawals

safe: derive from aToken balance changes attributable to escrow vault deposits (avoid external transfers into module)

4) Bounds table → concrete validation rules (SettingsValidationLibrary)
4.1 Errors (consistent, gas-friendly)

Define custom errors (Solidity ≥0.8.4):

error OutOfBounds(bytes32 key, uint256 value, uint256 min, uint256 max);

error InvalidAddress(bytes32 key);

error InvalidArrayLength(bytes32 key, uint256 a, uint256 b);

error InvalidBpsSum(uint256 sum);

error TooManyRecipients(uint256 n, uint256 max);

4.2 Validation rules (exact)

Timings

autoCancelTime:

0 <= t <= 30 days

autoReleaseTime:

0 <= t <= 30 days

Attachments

maxAttachments:

0 <= n <= 20

Fees

feeBps:

0 <= bps <= 200

feeAddress:

addr != 0

Resolution module delay

resolutionModuleDelay:

48 hours <= d <= 30 days

Yield distribution

recipients:

1 <= len <= 10

all nonzero

no duplicates (recommended)

percentages (bps):

same length as recipients

sum == 10_000

each entry > 0 (recommended)

Aave caps

cap[token]:

allow 0 (means disabled effectively) or enforce min >0 if enabled

max is policy-defined; you can set CAP_MAX[token] via Slow lane if you want hard ceilings.

4.3 Tests checklist (what to add)

For each rule:

passes at min

passes at max

fails below min

fails above max

emits correct error selector

For distributions:

mismatched lengths

sum != 10_000

duplicates

zero address recipient

too many recipients

5) ResolutionRouter implementation outline (new escrows only)
5.1 Contract skeleton (outline)

Storage:

address moduleA;

address moduleB;

uint16 rolloutBps; (0..10_000)

uint16 guardianFloorBps; optional if you want “down-only” guard separate (not needed)

Roles:

timelock-only setters: setRolloutBps, setModuleA, setModuleB

guardian-only down-only: guardianLowerRolloutBps

Core:

route(escrowId) -> address impl

resolve(...) delegates to chosen impl

5.2 Enforcing “new only”

At escrow creation in BaseEscrow (or vault), snapshot:

escrow.resolutionImpl = router.route(escrowId);

Then later resolution calls use escrow.resolutionImpl directly. Router policy changes won’t affect existing escrows.

This is the key property you want and it’s easy to explain in docs.

Deliverable: “Implementation task list” (hand to your agent)
Timelock & roles

Deploy TimelockController(minDelay=48h, proposers=[Governor], executors=[0x0], cancellers=[Governor]).

Update contracts to use AccessControl (or ownable->accesscontrol) with:

ROLE_TIMELOCK granted to Timelock

ROLE_GUARDIAN granted to multisig

Replace onlyOwner / onlyDaoOrOwner:

Standard/Slow → onlyRole(ROLE_TIMELOCK)

Emergency pause + down-only caps → onlyRole(ROLE_GUARDIAN)

Unpause → timelock only

Slow lane (7d) queue/activate

Implement queue/activate for:

fee bps

fee recipient

default module swaps (19–22)

Aave pool provider

DAO address change

decentralized escalation config

Each: queueX() sets eta=now+7d, activateX() checks eta.

Remove per-escrow overrides

Deprecate/remove 15–18 for mainnet builds.

Implement ResolutionRouter + snapshot selection per escrow at creation.

Bounds

Implement SettingsValidationLibrary rules + custom errors.

Add tests for every bound + distribution validation.

Assumptions

You accept Slow-lane being “two-step” on top of a 48h timelock (slower wall-clock but strongest safety under single-timelock constraint).

You’re okay making per-escrow overrides unavailable on mainnet for credibility.

You prefer minimal new dependencies (OZ AccessControl + TimelockController + Governor).

Next steps

I can convert the above into exact Solidity pseudocode for:

queue/activate pattern (generic helper)

guardian down-only caps

ResolutionRouter + escrow snapshotting

I can produce a permission matrix doc (contracts × functions × role × lane × delay) ready for your repo’s /docs/governance.md.

I can draft a test plan section aligned to Foundry + Hardhat for these governance paths.

What I need from you

Do you want Slow lane to be ~9 days wall-clock under single timelock (48h + 7d + 48h), or should we tweak the mechanism to keep it closer to 7d?

Are you using OpenZeppelin Governor already, or should I assume a fresh Governor + TimelockController setup?

Suggested next step

Reply with: “Keep ~9d” (or “keep ~7d”) and “Governor: existing/new”, and I’ll output the concrete contract outlines + exact role-grant/transfer sequence.



Approach

Finalize Option A (single timelock) into an implementable wiring plan: exact roles, ownership transfers, and function gating rules.

Convert the bounds table into concrete validation rules + error set + test checklist for SettingsValidationLibrary.

Turn the ResolutionRouter spec into an implementation-ready contract outline aligned to your “new escrows only” policy.

1) Single Timelock wiring plan (implementable)
1.1 TimelockController config (48h standard, 7d slow within one timelock)

With a single TimelockController, you can’t have two native delays. So we enforce lane delays at the application layer:

Timelock delay = 48 hours (global)

Slow lane (7 days) enforced via:

a minEta check stored per-change (your existing propose/activate mechanism), or

a generic “two-step queue/activate” wrapper for slow actions.

Recommended hybrid (minimal changes, strongest story):

Keep Timelock delay at 48h for all executions.

For Slow lane actions, require a second, contract-enforced delay of 7 days (two-step queue/activate), similar to your resolution-module activation.

This yields:

Standard actions: Governor → Timelock (48h) → execute

Slow actions: Governor → Timelock (48h) → queueX() (records ETA=now+7d) → after 7d Governor→Timelock (48h) → activateX()

Yes, it means Slow takes ~9 days wall-clock (48h + 7d + 48h). If you want Slow to be exactly 7 days wall-clock, the cleanest way is dual timelocks—but you chose single, so this is the safe and credible trade.

If you’d rather keep wall-clock closer to ~7d, we can set timelock delay to 24h and enforce 7d in-contract for slow; but you explicitly want Standard=48h, so I’m sticking to that.

1.2 TimelockController roles (exact)

PROPOSER_ROLE → Governor (your onchain DAO governor)

EXECUTOR_ROLE → address(0) (open execution; common + censorship-resistant)

CANCELLER_ROLE → Governor (optionally add Guardian; I’d start with Governor-only)

TIMELOCK_ADMIN_ROLE → TimelockController itself (self-admin)

1.3 Contract roles & gating (exact)

Across governed contracts (or preferably one EscrowSettings hub):

ROLE_TIMELOCK (or DEFAULT_ADMIN_ROLE) → TimelockController

ROLE_GUARDIAN → Guardian multisig

ROLE_FEE_WITHDRAWER → fee recipient address (EscrowVault only)

Gating rules:

Standard: onlyRole(ROLE_TIMELOCK) + bounded validation

Slow: onlyRole(ROLE_TIMELOCK) + must be “activated” after queuedAt + 7 days

Emergency: onlyRole(ROLE_GUARDIAN) and strictly down-only

Unpause:

unpause() → onlyRole(ROLE_TIMELOCK) (as requested)

2) Slow-lane enforcement pattern (reusable)

You already have:

proposeResolutionModule()

activateResolutionModule()

Extend the same idea to other slow surfaces. Two ways:

2.1 Minimal-code approach: add per-surface queue/activate

Add to the contract where the value lives:

Example: Fee recipient

queueEscrowFeeAddress(address newAddr) (timelock-only)

stores pendingFeeAddress

stores feeAddressEta = block.timestamp + 7 days

emits FeeAddressQueued(old,new,eta)

activateEscrowFeeAddress() (timelock-only)

requires block.timestamp >= feeAddressEta

sets live value

clears pending

emits FeeAddressActivated(old,new)

Repeat for:

setEscrowFee (or queue/activate fee)

default module setters (19–22)

Aave pool provider (24)

setDao (9)

escalation config (29)

2.2 Cleaner approach: central EscrowSettings hub

Put all slow parameters and module addresses into EscrowSettings, so you implement queue/activate once per surface in one place.

Given your current spread, I recommend you eventually converge here, but the minimal approach above works now.

3) Guardian nuanced precautions (raw token caps)

Add these guardian-only down-only functions to the Aave module (or a YieldRiskManager module):

guardianDisableAave() → sets enabled=false

guardianLowerGlobalCap(address token, uint256 newCap) with require(newCap <= cap)

guardianLowerTokenCap(address token, uint256 newCap) with require(newCap <= cap)

And timelock-only:

setTokenCap(address token, uint256 newCap) with require(newCap <= CAP_MAX[token])

setGlobalCap(address token, uint256 newCap) similarly

setAaveEnabled(true) timelock-only

Caps in raw token units:

store cap[token] in smallest units (wei-like)

enforce at deposit time: currentExposure[token] + amount <= cap[token]

Exposure measurement:

simplest: track internal “principal deposited” net of withdrawals

safe: derive from aToken balance changes attributable to escrow vault deposits (avoid external transfers into module)

4) Bounds table → concrete validation rules (SettingsValidationLibrary)
4.1 Errors (consistent, gas-friendly)

Define custom errors (Solidity ≥0.8.4):

error OutOfBounds(bytes32 key, uint256 value, uint256 min, uint256 max);

error InvalidAddress(bytes32 key);

error InvalidArrayLength(bytes32 key, uint256 a, uint256 b);

error InvalidBpsSum(uint256 sum);

error TooManyRecipients(uint256 n, uint256 max);

4.2 Validation rules (exact)

Timings

autoCancelTime:

0 <= t <= 30 days

autoReleaseTime:

0 <= t <= 30 days

Attachments

maxAttachments:

0 <= n <= 20

Fees

feeBps:

0 <= bps <= 200

feeAddress:

addr != 0

Resolution module delay

resolutionModuleDelay:

48 hours <= d <= 30 days

Yield distribution

recipients:

1 <= len <= 10

all nonzero

no duplicates (recommended)

percentages (bps):

same length as recipients

sum == 10_000

each entry > 0 (recommended)

Aave caps

cap[token]:

allow 0 (means disabled effectively) or enforce min >0 if enabled

max is policy-defined; you can set CAP_MAX[token] via Slow lane if you want hard ceilings.

4.3 Tests checklist (what to add)

For each rule:

passes at min

passes at max

fails below min

fails above max

emits correct error selector

For distributions:

mismatched lengths

sum != 10_000

duplicates

zero address recipient

too many recipients

5) ResolutionRouter implementation outline (new escrows only)
5.1 Contract skeleton (outline)

Storage:

address moduleA;

address moduleB;

uint16 rolloutBps; (0..10_000)

uint16 guardianFloorBps; optional if you want “down-only” guard separate (not needed)

Roles:

timelock-only setters: setRolloutBps, setModuleA, setModuleB

guardian-only down-only: guardianLowerRolloutBps

Core:

route(escrowId) -> address impl

resolve(...) delegates to chosen impl

5.2 Enforcing “new only”

At escrow creation in BaseEscrow (or vault), snapshot:

escrow.resolutionImpl = router.route(escrowId);

Then later resolution calls use escrow.resolutionImpl directly. Router policy changes won’t affect existing escrows.

This is the key property you want and it’s easy to explain in docs.

Deliverable: “Implementation task list” (hand to your agent)
Timelock & roles

Deploy TimelockController(minDelay=48h, proposers=[Governor], executors=[0x0], cancellers=[Governor]).

Update contracts to use AccessControl (or ownable->accesscontrol) with:

ROLE_TIMELOCK granted to Timelock

ROLE_GUARDIAN granted to multisig

Replace onlyOwner / onlyDaoOrOwner:

Standard/Slow → onlyRole(ROLE_TIMELOCK)

Emergency pause + down-only caps → onlyRole(ROLE_GUARDIAN)

Unpause → timelock only

Slow lane (7d) queue/activate

Implement queue/activate for:

fee bps

fee recipient

default module swaps (19–22)

Aave pool provider

DAO address change

decentralized escalation config

Each: queueX() sets eta=now+7d, activateX() checks eta.

Remove per-escrow overrides

Deprecate/remove 15–18 for mainnet builds.

Implement ResolutionRouter + snapshot selection per escrow at creation.

Bounds

Implement SettingsValidationLibrary rules + custom errors.

Add tests for every bound + distribution validation.

Assumptions

You accept Slow-lane being “two-step” on top of a 48h timelock (slower wall-clock but strongest safety under single-timelock constraint).

You’re okay making per-escrow overrides unavailable on mainnet for credibility.

You prefer minimal new dependencies (OZ AccessControl + TimelockController + Governor).

Next steps

I can convert the above into exact Solidity pseudocode for:

queue/activate pattern (generic helper)

guardian down-only caps

ResolutionRouter + escrow snapshotting

I can produce a permission matrix doc (contracts × functions × role × lane × delay) ready for your repo’s /docs/governance.md.

I can draft a test plan section aligned to Foundry + Hardhat for these governance paths.

What I need from you

Do you want Slow lane to be ~9 days wall-clock under single timelock (48h + 7d + 48h), or should we tweak the mechanism to keep it closer to 7d?

Are you using OpenZeppelin Governor already, or should I assume a fresh Governor + TimelockController setup?

Suggested next step

Reply with: “Keep ~9d” (or “keep ~7d”) and “Governor: existing/new”, and I’ll output the concrete contract outlines + exact role-grant/transfer sequence.

Its a fresh OZ Governor + timelockcontroller setup. Keep it as is
Approach

Provide an implementation-ready fresh OZ Governor + TimelockController setup that matches: Standard=48h, Slow=7d via queue/activate, unpause timelock-only, guardian down-only risk controls, new-escrows-only module effects.

Give the exact deployment + role-grant sequence and the wiring changes you’ll apply across contracts.

Output concrete Solidity skeletons for (a) Governor/Timelock, (b) reusable Slow-lane queue/activate, (c) guardian down-only caps, (d) ResolutionRouter + escrow snapshotting.

1) Fresh OZ Governor + TimelockController setup (exact wiring)
1.1 Contracts to use (OpenZeppelin)

TimelockController

Governor + extensions:

GovernorSettings (voting delay/period, proposal threshold)

GovernorVotes (ERC20Votes token)

GovernorVotesQuorumFraction (quorum)

GovernorTimelockControl (routes execution through timelock)

Token:

ERC20Votes (or ERC20Permit + ERC20Votes)

1.2 Timelock roles (your chosen policy)

minDelay = 48 hours

PROPOSER_ROLE → Governor

EXECUTOR_ROLE → address(0) (open execution)

CANCELLER_ROLE → Governor

TIMELOCK_ADMIN_ROLE → Timelock itself (self-admin)

1.3 Guardian multisig (emergency-only)

Guardian address is not a proposer/executor on timelock.

Guardian gets ROLE_GUARDIAN in governed contracts/modules.

Guardian cannot unpause; cannot raise caps; cannot enable Aave; cannot swap modules.

2) Deployment & role grant sequence (copy/paste runbook)
Step 0 — Deploy token (if not already)

Deploy GovToken = ERC20Votes token.

Mint/distribute.

Ensure delegates exist (even if to self) so votes count.

Step 1 — Deploy TimelockController

Deploy TimelockController with:

minDelay = 48 hours

proposers = [] (empty at deploy)

executors = [address(0)]

admin = deployer temporarily (or set admin empty and self-admin later)

Step 2 — Deploy Governor

Deploy Governor pointing at:

GovToken

TimelockController

Step 3 — Hand timelock proposer/canceller to Governor

On Timelock:

grantRole(PROPOSER_ROLE, Governor)

grantRole(CANCELLER_ROLE, Governor)

(EXECUTOR_ROLE already open via address(0))

Step 4 — Remove deployer from timelock admin

revokeRole(TIMELOCK_ADMIN_ROLE, deployer)

Ensure timelock has admin self-management (typical is to have the timelock itself as admin; OZ TimelockController uses role admin relationships—your deploy script should end in the hardened posture).

Step 5 — Transfer protocol control to timelock

For each governed contract/module:

If Ownable: transferOwnership(Timelock)

If AccessControl: grantRole(ROLE_TIMELOCK, Timelock) and remove deployer admin roles.

Set guardian:

grantRole(ROLE_GUARDIAN, guardianMultisig)

End state: only the timelock can do Standard/Slow; guardian can only do emergency down-only.

3) Contract-side wiring changes (make the governance map true)
3.1 Replace access modifiers

Replace onlyOwner with:

onlyRole(ROLE_TIMELOCK) for Standard & Slow setters

onlyRole(ROLE_GUARDIAN) for emergency + down-only caps

Replace onlyDaoOrOwner with onlyRole(ROLE_TIMELOCK).

3.2 Unpause rule

unpause() must be onlyRole(ROLE_TIMELOCK).

3.3 “New escrows only”

Snapshot module choices at escrow creation.

Changes to defaults/modules affect only future escrows.

4) Reusable Slow-lane queue/activate (7d) pattern (Solidity skeleton)

Use this in contracts that own slow surfaces (fees, default modules, aave provider, dao addr, escalation config).

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract SlowLaneQueueActivate {
    uint256 public constant SLOW_DELAY = 7 days;

    struct PendingAddress {
        address value;
        uint64 eta;
        bool exists;
    }

    struct PendingUint {
        uint256 value;
        uint64 eta;
        bool exists;
    }

    error NotReady(uint64 eta);
    error NoPending();
    error InvalidValue();

    function _queueAddress(PendingAddress storage p, address newValue) internal {
        if (newValue == address(0)) revert InvalidValue();
        p.value = newValue;
        p.eta = uint64(block.timestamp + SLOW_DELAY);
        p.exists = true;
    }

    function _activateAddress(PendingAddress storage p) internal returns (address) {
        if (!p.exists) revert NoPending();
        if (block.timestamp < p.eta) revert NotReady(p.eta);
        address v = p.value;
        delete p;
        return v;
    }

    function _queueUint(PendingUint storage p, uint256 newValue) internal {
        p.value = newValue;
        p.eta = uint64(block.timestamp + SLOW_DELAY);
        p.exists = true;
    }

    function _activateUint(PendingUint storage p) internal returns (uint256) {
        if (!p.exists) revert NoPending();
        if (block.timestamp < p.eta) revert NotReady(p.eta);
        uint256 v = p.value;
        delete p;
        return v;
    }
}


Usage example (fee recipient)

PendingAddress private _pendingFeeRecipient;

function queueFeeRecipient(address newAddr) external onlyRole(ROLE_TIMELOCK) {
    _queueAddress(_pendingFeeRecipient, newAddr);
    emit FeeRecipientQueued(feeRecipient, newAddr, _pendingFeeRecipient.eta);
}

function activateFeeRecipient() external onlyRole(ROLE_TIMELOCK) {
    address old = feeRecipient;
    feeRecipient = _activateAddress(_pendingFeeRecipient);
    emit FeeRecipientActivated(old, feeRecipient);
}


This exactly enforces 7d slow-lane on top of the 48h timelock.

5) Guardian down-only caps for Aave (raw token units)
Storage (in AaveYieldGenerationModule or a dedicated risk manager)

mapping(address token => uint256 cap);

mapping(address token => uint256 exposure);

bool aaveEnabled;

Functions (skeleton)
error CapTooHigh(uint256 newCap, uint256 currentCap);

function setTokenCap(address token, uint256 newCap) external onlyRole(ROLE_TIMELOCK) {
    // Optional: validate against CAP_MAX[token] bounds
    cap[token] = newCap;
    emit TokenCapSet(token, newCap);
}

function guardianLowerTokenCap(address token, uint256 newCap) external onlyRole(ROLE_GUARDIAN) {
    uint256 cur = cap[token];
    if (newCap > cur) revert CapTooHigh(newCap, cur);
    cap[token] = newCap;
    emit TokenCapLoweredByGuardian(token, cur, newCap);
}

function setAaveEnabled(bool enabled) external onlyRole(ROLE_TIMELOCK) {
    aaveEnabled = enabled;
    emit AaveEnabledSet(enabled);
}

function guardianDisableAave() external onlyRole(ROLE_GUARDIAN) {
    if (aaveEnabled) {
        aaveEnabled = false;
        emit AaveDisabledByGuardian();
    }
}

Enforce caps at deposit time
error CapExceeded(address token, uint256 nextExposure, uint256 cap);

function _checkAndAccrueExposure(address token, uint256 amount) internal {
    uint256 next = exposure[token] + amount;
    uint256 c = cap[token];
    if (c != 0 && next > c) revert CapExceeded(token, next, c);
    exposure[token] = next;
}


Note: Track exposure strictly from your controlled deposit/withdraw pathways to avoid aToken external transfer weirdness.

6) ResolutionRouter + new-escrows-only snapshot
Router skeleton (governed)
contract ResolutionRouter is IResolutionModule, AccessControl {
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    bytes32 public constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");

    address public moduleA;
    address public moduleB;
    uint16  public rolloutBps; // 0..10_000

    error InvalidBps();

    event RolloutBpsChanged(uint16 oldBps, uint16 newBps);
    event RolloutLoweredByGuardian(uint16 oldBps, uint16 newBps);
    event ModuleChanged(uint8 which, address oldAddr, address newAddr);

    constructor(address timelock, address guardian, address _a, address _b, uint16 _bps) {
        _grantRole(ROLE_TIMELOCK, timelock);
        _grantRole(ROLE_GUARDIAN, guardian);
        moduleA = _a;
        moduleB = _b;
        rolloutBps = _bps;
    }

    function setRolloutBps(uint16 newBps) external onlyRole(ROLE_TIMELOCK) {
        if (newBps > 10_000) revert InvalidBps();
        uint16 old = rolloutBps;
        rolloutBps = newBps;
        emit RolloutBpsChanged(old, newBps);
    }

    function guardianLowerRolloutBps(uint16 newBps) external onlyRole(ROLE_GUARDIAN) {
        if (newBps > rolloutBps) revert InvalidBps();
        uint16 old = rolloutBps;
        rolloutBps = newBps;
        emit RolloutLoweredByGuardian(old, newBps);
    }

    function route(uint256 escrowId) public view returns (address) {
        uint256 h = uint256(keccak256(abi.encodePacked(escrowId))) % 10_000;
        return (h < rolloutBps) ? moduleB : moduleA;
    }

    // resolve(...) should delegate to the selected impl (see below)
}

Snapshot at escrow creation (new-only)

In BaseEscrow.createEscrow(...) (or wherever escrow is instantiated):

compute impl = router.route(escrowId)

store escrows[escrowId].resolutionImpl = impl

emit EscrowResolutionSelected(escrowId, impl)

Then during dispute resolution:

call the stored resolutionImpl directly (not router), guaranteeing immutability.

Delegation mechanics

The router itself can provide helper methods, but the safest is:

snapshot implementation address per escrow

call that implementation via interface

7) SettingsValidationLibrary: implementable checklist (based on your bounds)

Add functions like:

validateAutoCancel(uint256 t)

validateAutoRelease(uint256 t)

validateMaxAttachments(uint256 n)

validateFeeBps(uint256 bps)

validateResolutionDelay(uint256 d)

validateYieldDistribution(address[] recipients, uint256[] bps)

validateNonZero(address a, bytes32 key)

Use the error set described earlier for consistent revert reasons.

Assumptions

You’re okay with Slow-lane taking ~9 days wall-clock under single-timelock + queue/activate.

You’ll centralize roles by transferring ownership / granting roles to the timelock across all governed contracts.

You want governance changes to affect new escrows only via snapshotting.

Next steps

I can generate a deploy script plan for Hardhat + Foundry (Ignition not required) that performs steps 0–5 deterministically.

I can produce a docs/governance.md that includes your lanes, roles, emergency powers, and “new escrows only” guarantee.

I can draft the exact function list to convert to queue/activate slow-lane (with proposed event names) across your current inventory.

What I need from you

Are you using UUPS/Transparent proxies at all, or are you relying purely on module swaps + settings?

Should guardian be able to cancel queued timelock ops (CANCELLER_ROLE), or Governor-only?

Suggested next step

Answer those two, and I’ll output the concrete deploy scripts + the exact per-contract patch list (by file/function) to implement everything.
