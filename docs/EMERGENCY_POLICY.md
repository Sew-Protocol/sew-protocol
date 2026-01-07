# Emergency Policy

This document defines emergency triggers, Guardian powers and limits, and the reversal process.

---

## Emergency Triggers

### When to Activate Emergency Controls

Emergency controls should be activated when:

1. **Critical Vulnerability**: A critical vulnerability is discovered that could lead to fund loss
2. **Protocol Exploit**: An active exploit is draining funds or manipulating state
3. **External Dependency Failure**: A critical external dependency (e.g., Aave) has failed
4. **Governance Attack**: Governance has been compromised or is being abused
5. **Regulatory Requirement**: Legal/regulatory requirement to pause operations

### When NOT to Activate Emergency Controls

Emergency controls should **not** be activated for:

- Routine parameter adjustments
- Planned upgrades
- Non-critical bugs
- Performance issues
- Feature requests

---

## Guardian Powers

### Immediate Actions (0h delay)

The Guardian Multisig can execute the following actions **immediately**:

1. **`pause()`** - Pause all protocol operations
   - Prevents new escrow creation
   - Prevents releases, cancellations, disputes
   - Does not prevent withdrawals of existing escrows (if already released)

2. **`guardianDisableAave()`** - Disable Aave yield generation
   - Prevents new deposits to Aave
   - Existing deposits remain (cannot be withdrawn until unpaused or Aave re-enabled)

3. **`guardianLowerTokenCap(address token, uint256 newCap)`** - Lower token exposure cap
   - Requires: `newCap <= currentCap` (down-only)
   - Reduces maximum exposure for a specific token

4. **`guardianLowerGlobalCap(address token, uint256 newCap)`** - Lower global exposure cap
   - Requires: `newCap <= currentCap` (down-only)
   - Reduces maximum global exposure

### Down-Only Constraint

All Guardian powers are **down-only**:
- Can reduce risk, never increase it
- Can lower caps, never raise them
- Can disable features, never enable them
- Can pause, never unpause

---

## Guardian Limits

### What Guardian Cannot Do

The Guardian **cannot**:

1. **Unpause**: `unpause()` requires `ROLE_TIMELOCK` (48h delay)
2. **Enable Aave**: `setAaveEnabled(true)` requires `ROLE_TIMELOCK` (48h delay)
3. **Raise Caps**: Cap increases require `ROLE_TIMELOCK` (48h delay)
4. **Change Modules**: Module changes require Slow lane (~9 days)
5. **Change Fees**: Fee changes require Slow lane (~9 days)
6. **Redirect Funds**: Impossible by design (no such function exists)
7. **Modify Escrow Rules**: Per-escrow overrides removed in Phase 5
8. **Cancel Timelock Proposals**: Only Governor has `CANCELLER_ROLE`

---

## Emergency Response Process

### Step 1: Assess Situation

1. Confirm emergency trigger criteria met
2. Assess scope of impact
3. Determine required actions

### Step 2: Execute Emergency Actions

1. **Pause Protocol** (if needed):
   ```bash
   pnpm gov:emergency pause --contract EscrowableERC20 --network baseMainnet
   pnpm gov:emergency pause --contract EscrowVault --network baseMainnet
   ```

2. **Disable External Integrations** (if needed):
   ```bash
   pnpm gov:emergency disable-aave --network baseMainnet
   ```

3. **Lower Exposure Caps** (if needed):
   ```bash
   pnpm gov:emergency lower-cap --token 0x... --new-cap 5000000 --network baseMainnet
   ```

### Step 3: Communicate

1. Notify team and stakeholders
2. Post public announcement (if appropriate)
3. Document actions taken

### Step 4: Investigate & Remediate

1. Investigate root cause
2. Develop fix
3. Test fix thoroughly
4. Propose fix via governance (Standard or Slow lane)

### Step 5: Resume Operations

1. Execute fix via governance
2. Verify fix is working
3. Unpause protocol (via Timelock, 48h delay):
   ```solidity
   // Via governance proposal
   escrowableERC20.unpause();
   escrowVault.unpause();
   ```

---

## Reversal Process

### Reversing Emergency Actions

Emergency actions can be reversed, but **not by Guardian**:

1. **Unpause**: Requires Timelock (48h delay)
   - Create governance proposal
   - DAO votes
   - Queue to Timelock
   - Wait 48h
   - Execute

2. **Re-enable Aave**: Requires Timelock (48h delay)
   - Create governance proposal
   - DAO votes
   - Queue to Timelock
   - Wait 48h
   - Execute `setAaveEnabled(true)`

3. **Raise Caps**: Requires Timelock (48h delay)
   - Create governance proposal
   - DAO votes
   - Queue to Timelock
   - Wait 48h
   - Execute `setTokenCap()` or `setGlobalCap()`

### Why Guardian Cannot Reverse

Guardian powers are intentionally **down-only** to prevent:
- Accidental re-enabling of vulnerable features
- Rapid toggling of protocol state
- Governance bypass for risky actions

All risk-increasing actions require:
- DAO vote (onchain)
- Timelock delay (48h)
- Public visibility

---

## Guardian Multisig Configuration

### Recommended Setup

- **Threshold**: 3-of-5 (or higher for mainnet)
- **Signers**: Trusted team members, advisors, or community representatives
- **Key Management**: Hardware wallets or secure key management
- **Rotation Policy**: Regular rotation of signers

### Security Considerations

1. **Key Storage**: Use hardware wallets or secure key management
2. **Access Control**: Limit who has access to Guardian keys
3. **Monitoring**: Monitor for unauthorized access attempts
4. **Incident Response**: Have clear incident response procedures

---

## Emergency Drills

### Regular Practice

Conduct emergency drills regularly (e.g., monthly):

1. **Simulate Emergency**: Identify a scenario
2. **Execute Actions**: Practice emergency commands
3. **Verify Results**: Confirm actions worked
4. **Document Learnings**: Update procedures

### Drill Checklist

- [ ] Guardian keys accessible
- [ ] Emergency scripts tested
- [ ] Communication channels ready
- [ ] Team notified
- [ ] Actions executed successfully
- [ ] Protocol state verified
- [ ] Reversal process tested

---

## Examples

### Example 1: Critical Vulnerability

**Scenario**: Critical vulnerability discovered in Aave integration

**Actions**:
1. Pause protocol
2. Disable Aave
3. Lower Aave exposure caps to 0
4. Investigate and fix
5. Propose fix via governance
6. Unpause after fix deployed

### Example 2: Governance Attack

**Scenario**: Governance token compromised, attacker proposing malicious changes

**Actions**:
1. Pause protocol (prevents execution of malicious proposals)
2. Investigate attack
3. Remediate governance (may require offchain coordination)
4. Resume operations after remediation

### Example 3: External Dependency Failure

**Scenario**: Aave protocol fails, funds at risk

**Actions**:
1. Disable Aave immediately
2. Lower Aave caps to 0
3. Assess impact
4. Develop migration plan
5. Execute migration via governance

---

## References

- `governance.md` - Governance model
- `GOVERNANCE_SURFACE_MAP.md` - Function mapping
- `scripts/gov/emergency.ts` - Emergency tooling
- `governance/runbooks/emergency.md` - **Step-by-step emergency procedures**
- `governance/runbooks/recovery.md` - **Step-by-step recovery procedures**
- `docs/DRILLS_AND_REHEARSALS.md` - Drill documentation and results




