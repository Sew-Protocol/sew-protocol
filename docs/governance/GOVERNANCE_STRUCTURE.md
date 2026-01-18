# Sew Protocol Governance Structure

**Date:** 2026-01-28  
**Last Updated:** 2026-01-28  
**Status:** ✅ **IMPLEMENTED** - Track + Absolute Quorum Approach

---

## Overview

Sew Protocol uses a **decentralized autonomous organization (DAO)** governance model built on OpenZeppelin's Governor framework. Governance is token-weighted, with proposals executed through a timelock for security.

---

## Governance Components

### 1. GovGovernor

**Contract:** `contracts/governance/GovGovernor.sol`  
**Purpose:** Main governance contract that manages proposals, voting, and execution

**Key Features:**
- **Token-Weighted Voting:** Uses SewToken (SEW) for voting power
- **Absolute Quorum:** Fixed quorum amount (e.g., 4M tokens) - simple and safe
- **Non-Circulating Tracking:** Tracks addresses for transparency/APIs (CoinGecko, etc.)
- **Timelock Execution:** All proposals execute through TimelockController

**Configuration:**
- **Voting Delay:** 1 block (configurable, longer for mainnet)
- **Voting Period:** ~1 week (configurable, ~45,818 blocks @ 13s/block)
- **Proposal Threshold:** 500k tokens (0.05% of total supply)
- **Quorum:** 4M tokens (absolute amount, can be updated via governance)

**Key Functions:**
```solidity
// Propose a new governance action
function propose(
    address[] memory targets,
    uint256[] memory values,
    bytes[] memory calldatas,
    string memory description
) public returns (uint256 proposalId)

// Vote on a proposal
function castVote(uint256 proposalId, uint8 support) public returns (uint256)

// Queue proposal for timelock execution
function queue(...) public returns (uint256)

// Execute proposal (after timelock delay)
function execute(...) public payable returns (uint256)

// Update absolute quorum (governance only)
function setAbsoluteQuorum(uint256 newQuorum) external

// Manage non-circulating addresses (governance only)
function addNonCirculatingAddress(address addr) external
function removeNonCirculatingAddress(address addr) external
```

---

### 2. GovernorTimelockControl

**Contract:** `@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol`  
**Purpose:** Integrates GovGovernor with TimelockController for secure execution

**Key Features:**
- **Timelock Integration:** All proposals execute through TimelockController
- **48-Hour Delay:** Minimum delay for all executions (configurable)
- **Security:** Prevents immediate execution of malicious proposals

**Workflow:**
1. Proposal is created and voted on
2. If passed, proposal is queued in TimelockController
3. After timelock delay (48h), proposal can be executed
4. Execution happens atomically through TimelockController

**Security Benefits:**
- **Time to Review:** Community has 48h to review queued proposals
- **Emergency Response:** Can cancel proposals before execution if issues found
- **Prevents Rush:** Prevents rushing through malicious proposals

---

### 3. TimelockController

**Contract:** `@openzeppelin/contracts/governance/TimelockController.sol`  
**Purpose:** Executes governance proposals after a delay

**Key Features:**
- **Minimum Delay:** 48 hours (configurable)
- **Role-Based Access:** Proposers and executors managed via roles
- **Batch Operations:** Can execute multiple operations atomically

**Roles:**
- **PROPOSER_ROLE:** Can queue proposals (GovGovernor has this role)
- **EXECUTOR_ROLE:** Can execute proposals (GovGovernor has this role)
- **CANCELLER_ROLE:** Can cancel proposals (can be set to multisig for emergencies)

**Workflow:**
```
1. GovGovernor queues proposal → TimelockController.schedule()
2. Wait for delay (48h)
3. GovGovernor executes proposal → TimelockController.execute()
```

---

## Governance Process

### Step 1: Proposal Creation

**Requirements:**
- Must hold at least **500k SEW tokens** (proposal threshold)
- Must have delegated voting power (ERC20Votes requirement)

**Process:**
1. Prepare proposal:
   - **Targets:** Contract addresses to call
   - **Values:** ETH amounts to send (usually 0)
   - **Calldatas:** Function calls with parameters
   - **Description:** Human-readable description (IPFS hash)

2. Call `propose()`:
   ```solidity
   governor.propose(targets, values, calldatas, description)
   ```

3. Proposal enters **Pending** state (waiting for voting delay)

**Example:**
```solidity
// Propose to update quorum to 5M tokens
address[] memory targets = new address[](1);
targets[0] = address(governor);
uint256[] memory values = new uint256[](1);
values[0] = 0;
bytes[] memory calldatas = new bytes[](1);
calldatas[0] = abi.encodeWithSignature(
    "setAbsoluteQuorum(uint256)",
    5_000_000 ether
);
string memory description = "Update quorum to 5M tokens";

uint256 proposalId = governor.propose(targets, values, calldatas, description);
```

---

### Step 2: Voting Period

**Duration:** ~1 week (configurable)

**Voting Options:**
- **Against (0):** Vote against the proposal
- **For (1):** Vote for the proposal
- **Abstain (2):** Abstain from voting

**Process:**
1. Token holders vote using their voting power
2. Voting power = delegated SEW tokens
3. Votes are weighted by token amount

**Quorum Requirement:**
- Must reach **4M tokens** (absolute quorum) in votes
- Votes can be For, Against, or Abstain (all count toward quorum)

**Example:**
```solidity
// Vote "For" on proposal
governor.castVote(proposalId, 1); // 1 = For

// Vote "Against" on proposal
governor.castVote(proposalId, 0); // 0 = Against
```

---

### Step 3: Proposal Execution

**After Voting Period:**

1. **If Quorum Met & Majority For:**
   - Proposal enters **Succeeded** state
   - Can be queued for timelock execution

2. **Queue Proposal:**
   ```solidity
   governor.queue(proposalId)
   ```
   - Proposal enters **Queued** state
   - Scheduled in TimelockController
   - Must wait for timelock delay (48h)

3. **After Timelock Delay:**
   - Proposal enters **Ready** state
   - Can be executed

4. **Execute Proposal:**
   ```solidity
   governor.execute(proposalId)
   ```
   - Proposal enters **Executed** state
   - Actions are executed atomically

**If Quorum Not Met or Majority Against:**
- Proposal enters **Defeated** state
- Cannot be executed

---

## Governance Powers

### What Can Be Governed

1. **Protocol Parameters:**
   - Update quorum: `setAbsoluteQuorum(uint256)`
   - Update proposal threshold: `setProposalThreshold(uint256)`
   - Update voting period: `setVotingPeriod(uint256)`
   - Update voting delay: `setVotingDelay(uint256)`

2. **Non-Circulating Addresses:**
   - Add address: `addNonCirculatingAddress(address)`
   - Remove address: `removeNonCirculatingAddress(address)`
   - Used for transparency/APIs (CoinGecko, etc.)

3. **Protocol Contracts:**
   - Upgrade contracts (if upgradeable)
   - Update module addresses
   - Change fee recipients
   - Update timelock parameters

4. **Emergency Actions:**
   - Pause contracts (if pausable)
   - Cancel queued proposals
   - Emergency withdrawals

---

## Security Model

### Multi-Layer Security

1. **Proposal Threshold:**
   - Requires 500k tokens to propose
   - Prevents spam proposals
   - Ensures proposers have skin in the game

2. **Quorum Requirement:**
   - Requires 4M tokens to vote
   - Ensures sufficient participation
   - Prevents minority from passing proposals

3. **Timelock Delay:**
   - 48-hour delay before execution
   - Time to review and respond
   - Can cancel if issues found

4. **Role-Based Access:**
   - Only timelock can execute governance functions
   - Timelock itself is controlled by multisig
   - Multiple layers of protection

### Attack Vectors & Mitigations

| Attack Vector | Mitigation |
|--------------|------------|
| **Proposal Spam** | Proposal threshold (500k tokens) |
| **Low Participation** | Quorum requirement (4M tokens) |
| **Rushed Execution** | Timelock delay (48h) |
| **Malicious Proposals** | Community review period, cancellation |
| **Governance Capture** | High quorum, token distribution |

---

## Quorum Strategy

### Absolute Quorum Approach

**Current Implementation:**
- **Quorum:** 4M tokens (absolute amount)
- **Not Percentage-Based:** Fixed amount, not % of supply
- **Simple & Safe:** Easy to understand and verify

**Benefits:**
- ✅ Simple and predictable
- ✅ Low risk (no complex calculations)
- ✅ Easy to audit
- ✅ Can be updated via governance

**Updating Quorum:**
```solidity
// Governance proposal to update quorum
governor.setAbsoluteQuorum(5_000_000 ether); // Update to 5M tokens
```

**When to Update:**
- As circulating supply grows significantly
- If quorum becomes too high or too low
- Based on community consensus

**Future Migration:**
- Can migrate to circulating-based quorum later
- Infrastructure already in place (non-circulating tracking)
- Requires governance proposal to switch

---

## Non-Circulating Token Tracking

### Purpose

**NOT Used for Quorum:**
- Non-circulating addresses are tracked but NOT used in quorum calculation
- Quorum uses absolute amount (4M tokens)

**Used For:**
- **External APIs:** CoinGecko, CoinMarketCap (circulating supply data)
- **Transparency:** Public visibility into token distribution
- **Analytics:** Dashboard and reporting
- **Future Migration:** Infrastructure ready if switching to circulating-based quorum

### Managing Non-Circulating Addresses

**Add Address:**
```solidity
// Governance proposal to add vesting contract
governor.addNonCirculatingAddress(vestingContract);
```

**Remove Address:**
```solidity
// Governance proposal to remove address
governor.removeNonCirculatingAddress(vestingContract);
```

**Requirements:**
- Only timelock can call (via governance proposal)
- Maximum 100 addresses (prevents DoS)
- Address must not be zero
- Address must not already be in list

---

## Governance Roles & Responsibilities

### Token Holders

**Rights:**
- Propose governance actions (if holding 500k+ tokens)
- Vote on proposals (weighted by token amount)
- Delegate voting power to others

**Responsibilities:**
- Participate in governance
- Review proposals before voting
- Monitor protocol changes

### Proposers

**Requirements:**
- Must hold 500k+ SEW tokens
- Must have delegated voting power

**Responsibilities:**
- Create well-researched proposals
- Provide clear descriptions
- Engage with community

### Executors

**Role:** TimelockController (via GovGovernor)
- Executes proposals after timelock delay
- Cannot execute before delay expires
- Can be cancelled by canceller role

### Cancellers

**Role:** Can be set to multisig for emergencies
- Can cancel queued proposals
- Emergency response mechanism
- Should be used sparingly

---

## Proposal Lifecycle

```
┌─────────┐
│ Pending │ ← Proposal created (waiting for voting delay)
└────┬────┘
     │
     ▼
┌─────────┐
│ Active  │ ← Voting period (~1 week)
└────┬────┘
     │
     ├─→ ┌──────────┐
     │   │ Defeated │ ← Quorum not met or majority against
     │   └──────────┘
     │
     └─→ ┌──────────┐
         │ Succeeded│ ← Quorum met and majority for
         └────┬─────┘
              │
              ▼
         ┌────────┐
         │ Queued │ ← Queued in timelock (waiting 48h)
         └────┬───┘
              │
              ▼
         ┌──────────┐
         │ Ready    │ ← Timelock delay expired
         └────┬─────┘
              │
              ▼
         ┌──────────┐
         │ Executed │ ← Proposal executed
         └──────────┘
```

---

## Best Practices

### For Proposers

1. **Research First:**
   - Understand the impact of your proposal
   - Get community feedback before proposing
   - Consider edge cases and risks

2. **Clear Descriptions:**
   - Explain what the proposal does
   - Why it's needed
   - What the impact will be

3. **Test First:**
   - Test on testnet if possible
   - Verify calldata is correct
   - Double-check addresses and parameters

### For Voters

1. **Review Proposals:**
   - Read the full description
   - Understand the technical details
   - Consider long-term implications

2. **Participate:**
   - Vote on all proposals
   - Delegate if you can't vote directly
   - Engage in discussions

3. **Monitor:**
   - Watch for queued proposals
   - Review before execution
   - Report issues if found

---

## Emergency Procedures

### Cancelling Queued Proposals

**If a malicious proposal is queued:**
1. Canceller role can cancel before execution
2. Must act within 48h timelock window
3. Should be used only in emergencies

**Process:**
```solidity
// Canceller cancels queued proposal
timelock.cancel(id);
```

### Pausing Contracts

**If critical vulnerability found:**
1. Governance can pause contracts (if pausable)
2. Emergency pause via multisig (if configured)
3. Fix vulnerability, then unpause

---

## Configuration Reference

### Current Configuration

| Parameter | Value | Notes |
|-----------|-------|-------|
| **Voting Delay** | 1 block | Configurable, longer for mainnet |
| **Voting Period** | ~1 week | ~45,818 blocks @ 13s/block |
| **Proposal Threshold** | 500k tokens | 0.05% of total supply |
| **Quorum** | 4M tokens | Absolute amount (not percentage) |
| **Timelock Delay** | 48 hours | Minimum delay for execution |

### Updating Configuration

All parameters can be updated via governance:
- `setVotingDelay(uint256)`
- `setVotingPeriod(uint256)`
- `setProposalThreshold(uint256)`
- `setAbsoluteQuorum(uint256)`

---

## Related Documentation

- **Implementation Details:** `contracts/governance/GovGovernor.sol`
- **Security Analysis:** `docs/security/QUORUM_APPROACH_COMPARISON.md`
- **Non-Circulating Tracking:** `docs/security/NON_CIRCULATING_TRACKING_BENEFITS.md`
- **Issue Analysis:** `docs/security/NON_CIRCULATING_SUPPLY_ISSUE.md`

---

## Summary

**Governance Model:** Token-weighted DAO with timelock execution  
**Quorum Strategy:** Absolute quorum (4M tokens) - simple and safe  
**Security:** Multi-layer (threshold, quorum, timelock, roles)  
**Flexibility:** All parameters updatable via governance  
**Transparency:** Non-circulating tracking for external APIs  

**Status:** ✅ **Ready for Launch** - Simple, safe, and well-documented
