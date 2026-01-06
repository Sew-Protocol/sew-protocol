# Module Developer - Mainnet Ops Role Design

**Date**: 2025-01-XX  
**Status**: Design Document  
**Purpose**: Define the "module developer - mainnet ops" role for instant module upgrades

---

## Executive Summary

To provide flexibility for rapid iteration and improvements to the DecentralizedResolutionModule, we introduce a new governance role: **"module developer - mainnet ops"**. This role allows instant upgrades of the module (via UUPS proxy) while maintaining security through event emission, disclosure requirements, and DAO oversight.

**Key Features**:
- ✅ Instant upgrades (no slow-lane delay)
- ✅ DAO-controlled role issuance
- ✅ Event emission for transparency
- ✅ Disclosure process for upgrade details
- ✅ Maintains security through role management

---

## Role Definition

### Role Name

**`ROLE_MODULE_DEVELOPER`** or **`ROLE_MODULE_DEV_OPS`**

**Full Name**: "Module Developer - Mainnet Operations"  
**Purpose**: Enable rapid, secure upgrades of DecentralizedResolutionModule

### Role Permissions

**Allowed Actions**:
- ✅ Upgrade DecentralizedResolutionModule implementation (via `upgradeTo()`)
- ✅ Upgrade and call (via `upgradeToAndCall()`)
- ✅ Upgrade ResolverIncentiveModule (if upgradeable, internal dependency)
- ✅ Swap PaymentCalculationLibrary (internal dependency)
- ❌ Cannot change upgrade authorization (prevents privilege escalation)
- ❌ Cannot grant/revoke roles (prevents access control changes)
- ❌ Cannot modify other critical settings
- ❌ Cannot swap modules in BaseEscrow (cannot change `resolutionModule` address)
- ❌ Cannot bypass standard/slow-lane governance actions
- ❌ Cannot swap other modules (release strategy, yield modules, etc.)

**Restrictions**:
- Only can upgrade the module implementation and its internal dependencies
- Cannot modify access control
- Cannot change governance parameters
- Cannot swap modules in BaseEscrow (requires `ROLE_TIMELOCK` + slow-lane)
- Cannot bypass governance delays

---

## Implementation Design

### Role Constant

```solidity
bytes32 public constant ROLE_MODULE_DEVELOPER = keccak256("ROLE_MODULE_DEVELOPER");
```

### Upgrade Authorization

**Current Design** (from Phase 1):
```solidity
function _authorizeUpgrade(address newImplementation) 
    internal 
    override 
    onlyRole(ROLE_TIMELOCK) 
{}
```

**New Design**:
```solidity
function _authorizeUpgrade(address newImplementation) 
    internal 
    override 
{
    require(
        hasRole(ROLE_TIMELOCK, _msgSender()) || 
        hasRole(ROLE_MODULE_DEVELOPER, _msgSender()),
        "Not authorized to upgrade"
    );
    
    // Emit upgrade event
    emit ModuleUpgraded(
        _getImplementation(), // Current implementation
        newImplementation,
        _msgSender(),
        block.timestamp
    );
}
```

### Upgrade Event

```solidity
event ModuleUpgraded(
    address indexed oldImplementation,
    address indexed newImplementation,
    address indexed upgradedBy,
    uint256 timestamp
);
```

---

## Governance Model

### Role Issuance

**Who Can Grant**: `ROLE_TIMELOCK` (DAO-controlled)

**Process**:
1. DAO proposal to grant role to address
2. Proposal passes through governance
3. Timelock executes role grant
4. Role is active immediately

**Who Can Revoke**: `ROLE_TIMELOCK` (DAO-controlled)

**Process**:
1. DAO proposal to revoke role from address
2. Proposal passes through governance
3. Timelock executes role revocation
4. Role is revoked immediately

### Role Holders

**Typical Holders**:
- Core development team (trusted developers)
- Security auditors (for emergency fixes)
- DAO-designated operators

**Selection Criteria**:
- Technical expertise
- Trust and reputation
- Security track record
- DAO approval

**Multi-Sig Requirement** (Recommended):
- Role should be held by multi-sig wallet
- Not by individual EOA
- Reduces single point of failure

---

## Upgrade Process

### Standard Upgrade Flow

**Step 1: Development**
- Developer creates new implementation
- Tests on testnet
- Security review (if major changes)
- Documentation prepared

**Step 2: Disclosure**
- Upgrade details disclosed (see Disclosure Requirements)
- Community review period (recommended: 24-48 hours)
- Address concerns if any

**Step 3: Deployment**
- Deploy new implementation to mainnet
- Verify implementation address
- Prepare upgrade transaction

**Step 4: Execution**
- Module developer calls `upgradeTo(newImplementation)`
- Event emitted automatically
- Upgrade complete

**Step 5: Verification**
- Verify upgrade successful
- Test critical functions
- Monitor for issues

### Emergency Upgrade Flow

**For Critical Bugs/Security Issues**:
- Immediate upgrade allowed
- Disclosure can follow (within 24 hours)
- Post-upgrade explanation required

---

## Disclosure Requirements

### Required Information

**Minimum Disclosure** (Must be provided before or immediately after upgrade):

1. **Implementation Address**:
   - New implementation contract address
   - Verification on block explorer

2. **Changes Summary**:
   - What changed (high-level)
   - Why changed (rationale)
   - Impact assessment

3. **Storage Layout**:
   - Storage layout compatibility confirmation
   - Any storage layout changes (if any)

4. **Testing**:
   - Test coverage
   - Testnet validation
   - Security review status

5. **Rollback Plan**:
   - How to rollback if needed
   - Rollback conditions

### Disclosure Channels

**Recommended Channels**:
- ✅ On-chain event (automatic)
- ✅ Governance forum post
- ✅ GitHub release notes
- ✅ Discord/Telegram announcement

**Timing**:
- **Standard**: Before upgrade (24-48 hours notice)
- **Emergency**: Within 24 hours after upgrade

---

## Security Considerations

### Risk Mitigation

#### 1. Privilege Escalation Prevention

**Protection**: Upgrade function cannot modify access control

```solidity
function _authorizeUpgrade(address newImplementation) 
    internal 
    override 
{
    // Only checks role, cannot grant roles
    require(
        hasRole(ROLE_TIMELOCK, _msgSender()) || 
        hasRole(ROLE_MODULE_DEVELOPER, _msgSender()),
        "Not authorized"
    );
    // Cannot modify _authorizeUpgrade itself (in implementation)
}
```

**Rationale**: Even if malicious implementation is deployed, it cannot grant itself additional permissions.

#### 2. Storage Layout Safety

**Requirement**: All upgrades must preserve storage layout

**Enforcement**:
- Automated storage layout checks (pre-upgrade)
- Manual verification
- Test coverage

**Protection**: Storage layout mismatches will cause data corruption, making malicious upgrades obvious.

#### 3. Implementation Verification

**Requirement**: Implementation must be verified on block explorer

**Process**:
- Deploy implementation
- Verify source code
- Share verification link
- Community can review code

#### 4. Multi-Sig Requirement

**Recommendation**: Role held by multi-sig, not EOA

**Benefits**:
- Reduces single point of failure
- Requires multiple approvals
- Better security

#### 5. Event Transparency

**Automatic**: All upgrades emit events

**Benefits**:
- On-chain record of all upgrades
- Transparent upgrade history
- Can be monitored by anyone

---

## Comparison: Timelock vs Module Developer Role

### Timelock-Controlled Upgrades

**Process**:
1. DAO proposal
2. Voting period
3. Timelock queue (48h delay)
4. Execution

**Timeline**: ~1 week  
**Use Case**: Major changes, governance decisions

### Module Developer-Controlled Upgrades

**Process**:
1. Development and testing
2. Disclosure
3. Instant upgrade

**Timeline**: ~1-2 days (with disclosure)  
**Use Case**: Bug fixes, improvements, feature additions

---

## Use Cases

### ✅ Appropriate Uses

1. **Bug Fixes**: Critical bugs discovered in production
2. **Security Patches**: Security vulnerabilities fixed
3. **Gas Optimizations**: Improve gas efficiency
4. **Feature Additions**: New features (backward compatible)
5. **Performance Improvements**: Optimize resolver selection
6. **Configuration Updates**: Update internal parameters

### ❌ Inappropriate Uses

1. **Breaking Changes**: Changes that break existing functionality
2. **Governance Changes**: Changes to governance parameters
3. **Access Control Changes**: Modifying who can do what
4. **Major Architecture Changes**: Fundamental redesigns

**Rule of Thumb**: If it requires governance discussion, use Timelock. If it's a technical improvement, use Module Developer role.

---

## Event Design

### ModuleUpgraded Event

```solidity
event ModuleUpgraded(
    address indexed oldImplementation,
    address indexed newImplementation,
    address indexed upgradedBy,
    uint256 timestamp
);
```

**Fields**:
- `oldImplementation`: Previous implementation address
- `newImplementation`: New implementation address
- `upgradedBy`: Address that executed upgrade (module developer)
- `timestamp`: Block timestamp of upgrade

**Usage**:
- On-chain upgrade history
- Monitoring and alerts
- Governance tracking
- Transparency

### Additional Events (Optional)

**ModuleUpgradeProposed** (if pre-disclosure):
```solidity
event ModuleUpgradeProposed(
    address indexed proposedImplementation,
    address indexed proposedBy,
    string disclosureURI, // IPFS hash or URL
    uint256 proposedAt
);
```

**ModuleUpgradeDisclosed**:
```solidity
event ModuleUpgradeDisclosed(
    address indexed implementation,
    string disclosureURI,
    uint256 disclosedAt
);
```

---

## Disclosure Process

### Standard Disclosure Format

**Template**:
```markdown
# Module Upgrade Disclosure

**Implementation Address**: `0x...`
**Upgraded By**: `0x...` (module developer address)
**Timestamp**: `2025-01-XX XX:XX:XX UTC`

## Changes Summary
- [List of changes]

## Rationale
- [Why these changes were made]

## Impact Assessment
- [What is affected]
- [Backward compatibility]

## Storage Layout
- [Compatibility confirmation]
- [Any changes]

## Testing
- [Test coverage]
- [Testnet validation]

## Rollback Plan
- [How to rollback]
- [When to rollback]
```

### Disclosure Location

**Recommended**: IPFS or GitHub

**Process**:
1. Create disclosure document
2. Upload to IPFS or GitHub
3. Share URI in event or forum
4. Community can review

---

## Implementation Steps

### Step 1: Add Role Constant

```solidity
bytes32 public constant ROLE_MODULE_DEVELOPER = keccak256("ROLE_MODULE_DEVELOPER");
```

### Step 2: Update Upgrade Authorization

```solidity
function _authorizeUpgrade(address newImplementation) 
    internal 
    override 
{
    require(
        hasRole(ROLE_TIMELOCK, _msgSender()) || 
        hasRole(ROLE_MODULE_DEVELOPER, _msgSender()),
        "Not authorized to upgrade"
    );
    
    address oldImplementation = _getImplementation();
    
    emit ModuleUpgraded(
        oldImplementation,
        newImplementation,
        _msgSender(),
        block.timestamp
    );
}
```

### Step 3: Add Event

```solidity
event ModuleUpgraded(
    address indexed oldImplementation,
    address indexed newImplementation,
    address indexed upgradedBy,
    uint256 timestamp
);
```

### Step 4: Governance Integration

- Document role in governance docs
- Create role grant/revoke process
- Define disclosure requirements

---

## Monitoring and Alerts

### On-Chain Monitoring

**Events to Monitor**:
- `ModuleUpgraded`: All upgrades
- `RoleGranted(ROLE_MODULE_DEVELOPER)`: New role grants
- `RoleRevoked(ROLE_MODULE_DEVELOPER)`: Role revocations

**Monitoring Tools**:
- Event listeners
- Block explorers
- Custom dashboards

### Alert Triggers

**Immediate Alerts**:
- Module upgrade detected
- New role grant
- Role revocation

**Daily Reports**:
- Upgrade history
- Active role holders
- Recent changes

---

## Governance Integration

### Role Management

**Granting Role**:
```solidity
// Via Timelock
module.grantRole(ROLE_MODULE_DEVELOPER, developerAddress);
```

**Revoking Role**:
```solidity
// Via Timelock
module.revokeRole(ROLE_MODULE_DEVELOPER, developerAddress);
```

**Checking Role**:
```solidity
bool hasRole = module.hasRole(ROLE_MODULE_DEVELOPER, address);
```

### Governance Process

**Granting**:
1. DAO proposal to grant role
2. Community discussion
3. Vote
4. If passed, Timelock executes
5. Role active

**Revoking**:
1. DAO proposal to revoke role
2. Community discussion
3. Vote
4. If passed, Timelock executes
5. Role revoked

---

## Comparison with Current Approach

### Current: Timelock-Only Upgrades

**Pros**:
- ✅ Maximum security (DAO approval required)
- ✅ Community oversight
- ✅ No single point of failure

**Cons**:
- ❌ Slow (1+ week timeline)
- ❌ Not suitable for rapid fixes
- ❌ Governance overhead for technical changes

### Proposed: Module Developer Role

**Pros**:
- ✅ Fast (instant upgrades)
- ✅ Suitable for technical improvements
- ✅ Maintains security (role controlled by DAO)
- ✅ Transparent (events + disclosure)

**Cons**:
- ⚠️ Requires trust in role holders
- ⚠️ Faster = less time for review
- ⚠️ Need good disclosure process

### Hybrid Approach (Recommended)

**Use Module Developer Role For**:
- Bug fixes
- Security patches
- Gas optimizations
- Feature additions (backward compatible)

**Use Timelock For**:
- Major architecture changes
- Governance parameter changes
- Breaking changes
- Controversial upgrades

---

## Security Best Practices

### For Role Holders

1. **Multi-Sig**: Use multi-sig wallet, not EOA
2. **Key Management**: Secure key storage
3. **Code Review**: Review all upgrades before execution
4. **Testing**: Test on testnet first
5. **Disclosure**: Always disclose upgrade details

### For DAO

1. **Role Selection**: Careful selection of role holders
2. **Regular Review**: Periodic review of role holders
3. **Revocation Process**: Clear process for revocation
4. **Monitoring**: Monitor all upgrades
5. **Oversight**: Maintain oversight of upgrade process

### For Community

1. **Monitor Events**: Watch for upgrade events
2. **Review Disclosures**: Review upgrade disclosures
3. **Report Issues**: Report any concerns
4. **Governance**: Participate in role management

---

## Implementation Checklist

### Contract Changes

- [ ] Add `ROLE_MODULE_DEVELOPER` constant
- [ ] Update `_authorizeUpgrade()` to allow role
- [ ] Add `ModuleUpgraded` event
- [ ] Add `_getImplementation()` helper (if needed)
- [ ] Test upgrade authorization

### Governance Integration

- [ ] Document role in governance docs
- [ ] Create role grant process
- [ ] Create role revoke process
- [ ] Define disclosure requirements
- [ ] Create disclosure template

### Process Documentation

- [ ] Document upgrade process
- [ ] Document disclosure process
- [ ] Create upgrade checklist
- [ ] Create disclosure template
- [ ] Document emergency procedures

### Monitoring

- [ ] Set up event monitoring
- [ ] Create alert system
- [ ] Set up dashboards
- [ ] Document monitoring process

---

## Recommendations

### Immediate Actions

1. ✅ **Implement Role**: Add `ROLE_MODULE_DEVELOPER` to contract
2. ✅ **Update Authorization**: Allow role to upgrade
3. ✅ **Add Events**: Emit upgrade events
4. ✅ **Document Process**: Create disclosure process

### Before Mainnet

1. ✅ **Select Role Holders**: Choose trusted developers/operators
2. ✅ **Set Up Multi-Sig**: Use multi-sig for role holder
3. ✅ **Create Disclosure Process**: Define disclosure requirements
4. ✅ **Set Up Monitoring**: Monitor upgrade events

### Ongoing

1. ✅ **Regular Review**: Review role holders periodically
2. ✅ **Monitor Upgrades**: Track all upgrades
3. ✅ **Enforce Disclosure**: Ensure disclosures are provided
4. ✅ **Community Engagement**: Keep community informed

---

## Risk Assessment

### Low Risk ✅
- Role controlled by DAO (can revoke)
- Events provide transparency
- Storage layout safety (prevents data corruption)
- Multi-sig requirement (reduces single point of failure)

### Medium Risk ⚠️
- Faster upgrades = less review time
- Requires trust in role holders
- Disclosure process must be followed

### High Risk ❌
- None identified (with proper safeguards)

**Mitigation**:
- DAO can revoke role at any time
- Events provide transparency
- Disclosure requirements
- Multi-sig requirement
- Storage layout safety

---

## Conclusion

The "module developer - mainnet ops" role provides the flexibility needed for rapid iteration while maintaining security through:

1. ✅ **DAO Control**: Role issuance/revocation controlled by DAO
2. ✅ **Transparency**: Events emitted for all upgrades
3. ✅ **Disclosure**: Well-defined disclosure process
4. ✅ **Safety**: Storage layout safety, multi-sig requirement
5. ✅ **Oversight**: Community can monitor and respond

This approach balances **flexibility** (rapid upgrades) with **security** (DAO oversight, transparency, disclosure).

---

*This document should be updated as the role is implemented and processes are refined.*

