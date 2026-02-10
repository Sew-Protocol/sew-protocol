# Sew Protocol Security Model

Sew Protocol is designed as a containment layer for protected transfers on Ethereum. Rather than attempting to eliminate all risk, the protocol focuses on narrowing scope, isolating failures, and ensuring that funds always follow deterministic paths.

## Security Philosophy

Ethereum transactions are irreversible. Smart contracts introduce new capabilities, but also new forms of risk. Sew approaches security through three core principles:

1. **Containment over prevention**: Failures may occur. The protocol is designed to limit their impact.
2. **Determinism over discretion**: Funds move according to predefined rules, not human judgment.
3. **Isolation over shared risk**: Each escrow is treated as an independent agreement.

## Core Security Properties

### Non-custodial by Design

- Funds are held by smart contracts, not by an operator or intermediary
- Participants retain full control over fund movement and resolution paths
- No privileged "super-user" can unilaterally move funds

### Deterministic Release Paths

- Every escrow defines its release and resolution rules at **creation time**
- Settlement follows predefined state transitions
- Configuration changes do not affect existing escrows (forward-only evolution)

### Per-Escrow Isolation

Each protected transfer is **independent**. If one fails, others are unaffected. This is enforced through:

- **Per-escrow module snapshots**: Each escrow captures module addresses at creation time via `ModuleSnapshot`, ensuring:
  - Resolution module stays fixed (no retroactive module swaps)
  - Release strategy stays fixed (no retroactive strategy changes)
  - Yield generation/distribution modules stay fixed
  
- **Per-escrow timeout configuration**: Each escrow snapshots its timeout parameters at creation:
  - `defaultAutoReleaseDelay` - automatic release deadline
  - `defaultAutoCancelDelay` - automatic cancellation deadline
  - `maxDisputeDuration` - how long disputes can remain open
  - `appealWindowDuration` - time to appeal resolution decisions

- **Per-escrow fee snapshot**: Each escrow captures `escrowFeeBps` at creation, ensuring fee changes don't affect existing escrows

- **Per-escrow escrow settings**: Release authorization, custom resolver, auto-timing preferences captured at creation

### Emergency Circuit-Breaker: Vault-Level Pause

While the protocol emphasizes per-escrow isolation, a **vault-level pause mechanism** exists as an emergency circuit-breaker (similar to financial market circuit-breakers):

- **Activation**: Guardians can pause the vault in response to critical vulnerabilities
- **Scope**: Blocks new escrow creation and pauses specific functions on existing escrows
- **Rationale**: Provides rapid containment when zero-day vulnerabilities are discovered, preventing exploitation of additional escrows while preserving existing fund integrity
- **Not isolation violation**: The pause is not a normal operation; it's an emergency containment measure to prevent mass exploitation
- **Automatic expiration**: Pause cycles have maximum duration limits (`MAX_PAUSE_DURATION`, `MAX_PAUSE_CYCLES`) to prevent indefinite lockdown
- **Documented recovery path**: Each pause documents what will restore normal operation

### Forward-Only Evolution

- Protocol upgrades do not alter existing agreements
- Historical agreements remain stable under their original rules
- New escrows adopt new defaults, old escrows keep snapshotted values

## Threat Model

Sew is designed to operate in an adversarial environment, addressing risks like:

### User Error
- Sending funds to the wrong address
- Premature or unauthorized release
- **Mitigated by**: Escrow state machine enforcing pre-release confirmation from recipient; release strategy authorization checks

### Counterparty Risk
- Fraudulent participants or failure to deliver
- Dispute resolution corruption
- **Mitigated by**: Dispute mechanism with independent resolution modules; escalation paths to higher-authority resolvers

### Smart Contract Risk
- Bugs in integrations or extension modules
- Yield protocol failures (e.g., Aave attacks)
- **Mitigated by**: Per-escrow module isolation; yield withdrawal bounds validation; optional yield opt-out

### Governance Risk
- Malicious or compromised privileged roles
- Unauthorized module swaps affecting existing escrows
- **Mitigated by**: Role separation (admin, timelock, guardian); timelock delays on module changes; snapshot isolation

### Validator Censorship
- Validators preventing release transactions
- **Mitigated by**: Multiple release paths (participant, keeper, resolver); guardian pause allows reboot if needed

## Module Isolation Architecture

### ModuleSnapshot Structure

Each escrow captures a frozen snapshot of its configuration:

```solidity
struct ModuleSnapshot {
    address resolutionModule;           // Dispute resolver module
    address releaseStrategy;            // Authorization logic for release
    address yieldGenerationModule;      // Yield accrual module
    address yieldDistributionModule;    // Yield withdrawal module
    address incentiveModule;            // Incentive mechanism
    uint256 yieldProtocolFeeBps;        // Yield fee percentage
    uint256 appealBondProtocolFeeBps;   // Appeal bond fee percentage
    uint256 escrowFeeBps;               // Escrow creation fee percentage (per-escrow)
    uint256 defaultAutoReleaseDelay;    // Default release timeout (per-escrow)
    uint256 defaultAutoCancelDelay;     // Default cancellation timeout (per-escrow)
    uint256 maxDisputeDuration;         // Max dispute duration (per-escrow)
    uint256 appealWindowDuration;       // Appeal window (per-escrow)
}
```

### Snapshot Capture

Snapshots are captured in `_snapshotModulesForEscrow()` at escrow creation time:

1. Resolution module is locked to prevent retroactive module swaps
2. All module addresses (yield, release, etc.) are captured
3. Global fee percentages and timeout configs are captured
4. This happens immediately after escrow creation, before yield deposit

### Snapshot Usage

Throughout escrow lifecycle, snapshot values are used instead of global defaults:

- **Dispute handling**: Uses `snap.resolutionModule`
- **Yield operations**: Uses `snap.yieldGenerationModule` and `snap.yieldDistributionModule`
- **Release authorization**: Uses `snap.releaseStrategy`
- **Timeout enforcement**: Uses `snap.maxDisputeDuration`, `snap.appealWindowDuration`, etc.
- **Fee calculations**: Uses `snap.escrowFeeBps` instead of global `escrowFee`

## Security Guarantees

### Cannot Be Violated

1. **Module stability**: Once created, an escrow's modules are frozen
2. **Fee certainty**: Escrow fee is locked at creation; future fee changes don't affect existing escrows
3. **Timeout certainty**: Auto-timing defaults are locked at creation
4. **Recipient confirmation**: Recipients must explicitly accept transfers before release
5. **Deterministic paths**: Release/cancellation follow explicit state machine

### Can Be Paused

In emergencies, the vault can be paused by guardians to prevent new escrow creation and temporarily disable certain functions. This is an **intentional circuit-breaker, not a design flaw**. Recovery requires:

1. Vulnerability remediation
2. Time delay (7 days) for module updates
3. Community consensus or governance approval

### Per-Escrow Guarantees

Each escrow is guaranteed:

- Its modules will never change
- Its fees will never increase
- Its timeouts are predictable
- Its release strategy is fixed
- Its resolution path is predetermined
- If it fails, other escrows continue normally

## Implementation Notes

### Accessing Snapshotted Values

When implementing logic that reads configuration:

```solidity
// ✅ CORRECT: Use snapshot for existing escrows
ModuleSnapshot storage snap = moduleSnapshots[workflowId];
uint256 appealWindow = snap.appealWindowDuration;

// ✅ CORRECT: Use global config at creation time only
_applyEscrowSettings(workflowId, settings);  // Uses global timeoutConfig for new escrows
_snapshotModulesForEscrow(workflowId);       // Captures global values

// ❌ WRONG: Using global config for existing escrow operations
if (block.timestamp > ts + timeoutConfig.maxDisputeDuration) {  // Uses old global value
    // This breaks isolation if config was changed since creation
}

// ✅ CORRECT: Use snapshot
if (block.timestamp > ts + snap.maxDisputeDuration) {
    // Works correctly regardless of global config changes
}
```

### Testing Module Isolation

Tests should verify:

1. Module changes don't affect existing escrows
2. Fee changes don't affect existing escrows
3. Timeout changes don't affect existing escrows
4. Module snapshots are captured at creation time
5. Snapshot values are used in escrow operations

See `test/foundry/core/PerEscrowSettings.t.sol` for examples.

## Recovery Procedures

If a vulnerability is discovered:

1. **Immediate**: Guardian pauses vault to prevent new escrows
2. **Short-term**: Fix deployed; prepare module update
3. **Medium-term**: Queue module update with 7-day timelock delay
4. **Recovery**: Activate fixed module; begin unpausing escrows
5. **Long-term**: Potentially migrate affected escrows (if necessary)

## Phase 4 Work: Per-Escrow Configuration Isolation (Complete)

**Objective**: Ensure all runtime configuration is captured per-escrow at creation time, preventing retroactive changes from affecting existing agreements.

**Changes**:
1. ✅ Extended `ModuleSnapshot` struct to capture:
   - `escrowFeeBps` - escrow creation fee
   - `defaultAutoReleaseDelay` - default release timeout
   - `defaultAutoCancelDelay` - default cancellation timeout
   - `maxDisputeDuration` - max dispute window
   - `appealWindowDuration` - appeal window

2. ✅ Updated `_snapshotModulesForEscrow()` to capture new fields

3. ✅ Updated runtime code to use snapshots:
   - `automateTimedActions()` - passes snapshotted timeout config
   - `autoCancelDisputedEscrow()` - uses `snap.maxDisputeDuration`
   - `raiseDispute()` - uses `snap.escrowFeeBps` for incentive module

4. ✅ Updated tests to use snapshotted values

**Result**: All escrow configuration is now frozen at creation time, fully implementing "isolation over shared risk" principle.

## Future Work: Phase 5 (Proposed)

To further strengthen isolation, future work could include:

1. **Per-escrow pause mechanism** (optional): Allow guardians to pause specific escrows instead of global pause
2. **Module pause granularity**: Track which modules are paused separately
3. **Emergency fund recovery**: Automated recovery paths for paused escrows
4. **Audit trail**: Log all configuration snapshots for transparency

