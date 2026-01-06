# Upgrade Policy

This document defines the upgrade policy, ossification plan, and storage layout discipline for the Sew Protocol.

---

## Ossification Plan

### Core Invariants (Intended to Ossify)

The following core invariants are intended to **ossify** (become immutable) over time:

1. **Escrow Immutability**: Once an escrow is created, its rules cannot be changed by any governance actor.
2. **Module Snapshotting**: Module choices are snapshotted at escrow creation and persist for the escrow's lifetime.
3. **No Per-Escrow Overrides**: No selective intervention is possible for individual escrows.
4. **Time-Delayed Execution**: All non-emergency changes execute through TimelockController.

### Upgradeable Components

The following components are designed to be upgradeable:

1. **Module Implementations**: New modules can be added and swapped via governance.
2. **Default Parameters**: Bounded parameters can be adjusted within predefined limits.
3. **Fee Configuration**: Fee rates and recipients can be changed via Slow lane.
4. **Governance Infrastructure**: DAO, Timelock, and Guardian addresses can be updated.

---

## Upgrade Process

### Standard Lane Upgrades (48h delay)

**Scope**: Bounded parameter changes, operational configuration

**Process**:
1. Create governance proposal with bounded parameter change
2. DAO votes on proposal
3. If passed, proposal queues to TimelockController
4. Wait 48 hours
5. Anyone can execute the queued proposal

**Examples**:
- Adjust default timeouts (within 0-30 days)
- Change max attachments (within 0-20)
- Update yield distribution recipients/percentages
- Register new tokens for Aave
- Set exposure caps

### Slow Lane Upgrades (~9 days delay)

**Scope**: High-impact changes (module swaps, fee recipient, governance infrastructure)

**Process**:
1. **Queue Phase**:
   - Create governance proposal to queue change
   - DAO votes on proposal
   - If passed, proposal queues to TimelockController
   - Wait 48 hours
   - Execute queue proposal (sets pending change with ETA = now + 7 days)

2. **Wait Phase**:
   - Wait 7 days (enforced onchain)

3. **Activate Phase**:
   - Create governance proposal to activate change
   - DAO votes on proposal
   - If passed, proposal queues to TimelockController
   - Wait 48 hours
   - Execute activate proposal (applies pending change)

**Total Time**: ~9 days wall-clock (48h + 7d + 48h)

**Examples**:
- Swap resolution module
- Change fee recipient address
- Update DAO address
- Change Aave pool provider

---

## Storage Layout Discipline

### Proxy Upgrades

If using UUPS or Transparent proxies:

1. **Storage Layout Rules**:
   - Never remove storage variables
   - Never change variable order
   - Never change variable types
   - Only append new variables at the end

2. **Storage Gaps**:
   - Use storage gaps for future variables:
   ```solidity
   uint256[50] private __gap;
   ```

3. **Initialization**:
   - Always use `initializer` modifier
   - Never call constructor logic in implementation

### Module Swaps (Preferred)

Instead of proxy upgrades, prefer **module swaps**:

1. Deploy new module implementation
2. Queue new module via Slow lane
3. Activate new module after 7 days
4. New escrows use new module
5. Existing escrows continue using old module (snapshotted)

**Benefits**:
- No storage layout concerns
- No proxy upgrade risks
- Clear separation of concerns
- Easier to audit

---

## Upgrade Safety Checklist

Before executing any upgrade:

- [ ] Proposal has passed DAO vote
- [ ] Proposal has been queued to TimelockController
- [ ] Timelock delay has elapsed (48h for Standard, 7d+48h for Slow)
- [ ] All parameters are within bounds
- [ ] Storage layout is compatible (if proxy upgrade)
- [ ] Tests pass for new configuration
- [ ] Fork simulation has been run
- [ ] Emergency pause is available if needed

---

## Emergency Upgrades

Emergency upgrades are **not supported**. The protocol is designed to be:

1. **Pausable**: Guardian can pause operations immediately
2. **Capable**: Guardian can lower exposure caps (down-only)
3. **Disableable**: Guardian can disable external integrations (e.g., Aave)

**What Guardian Cannot Do**:
- Unpause (Timelock-only)
- Raise caps (Timelock-only)
- Enable features (Timelock-only)
- Change modules (Timelock-only)
- Redirect funds (impossible by design)

---

## Version Management

### Contract Versions

Contracts should implement version tracking:

```solidity
string public constant VERSION = "1.0.0";
```

### Module Versions

Modules implement `moduleVersion()`:

```solidity
function moduleVersion() external pure returns (string memory) {
    return "1.0.0";
}
```

### Deployment Tracking

All deployments are tracked in:
- `deployments/` directory (hardhat-deploy artifacts)
- Deployment ledger with timestamps
- Governance proposal artifacts

---

## Rollback Procedures

### Module Rollback

To rollback a module change:

1. Queue previous module via Slow lane
2. Wait 7 days
3. Activate previous module

**Note**: This only affects new escrows. Existing escrows continue using their snapshotted modules.

### Parameter Rollback

To rollback a parameter change:

1. Create new proposal with previous parameter value
2. Execute via Standard lane (48h delay)

### Emergency Rollback

If a critical issue is discovered:

1. Guardian pauses protocol (immediate)
2. Guardian disables affected features (immediate)
3. Governance proposes fix via appropriate lane
4. Execute fix after delay
5. Guardian unpause is not possible (Timelock-only)

---

## Testing Upgrades

### Pre-Upgrade Testing

1. **Unit Tests**: All new code paths
2. **Integration Tests**: Full governance flow
3. **Fork Simulation**: Test on forked mainnet/testnet
4. **Invariant Tests**: Verify core invariants hold

### Post-Upgrade Verification

1. **State Verification**: Verify state variables updated correctly
2. **Event Verification**: Verify events emitted
3. **Functionality Tests**: Verify new functionality works
4. **Invariant Checks**: Verify invariants still hold

---

## References

- `governance.md` - Governance model
- `GOVERNANCE_PROCESS.md` - Governance process
- `EMERGENCY_POLICY.md` - Emergency procedures
- `MODULE_MAP.md` - Module mapping




