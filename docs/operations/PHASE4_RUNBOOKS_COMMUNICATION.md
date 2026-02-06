# Phase 4: Documentation & Communication

## Overview

Phase 4 provides operational runbooks, governance templates, and user communications for the Guardian Pause & Recovery system.

## Table of Contents

1. [Guardian Runbook](#guardian-runbook)
2. [Operator Runbook](#operator-runbook)
3. [Recovery Runbook](#recovery-runbook)
4. [Governance Templates](#governance-templates)
5. [User Communications](#user-communications)
6. [FAQ & Troubleshooting](#faq--troubleshooting)

---

## Guardian Runbook

### Purpose

This runbook guides guardians in detecting incidents and making pause decisions.

### When to Pause

Pause the escrow system if you detect ANY of:

✅ **Market Anomalies**
- Unusual transaction patterns (e.g., mass withdrawals)
- Slippage exceeding thresholds
- Oracle price deviations > 5%
- Liquidity pool drains on Aave

✅ **Technical Issues**
- Yield module malfunction
- Contract function failures
- Smart contract revert loops
- Module state corruption

✅ **Security Threats**
- Vulnerability discovered (internal or external)
- Suspicious contract interactions
- Reentrancy attempts detected
- Unauthorized access attempts

✅ **External Dependency Failures**
- Aave protocol halt or emergency mode
- Oracle service downtime
- Chain finality issues
- Block proposer issues

✅ **Governance Override**
- Multi-sig emergency vote
- Multi-chain coordination issue
- Protocol upgrade conflicts
- Emergency DAO decision

### How to Pause

**Step 1: Alert Operations**
```
Send to #escrow-incident:
"INCIDENT ALERT: [issue description]
Guardian: [your address]
Severity: [critical/high/medium]
Impact: [fund risk/data loss/service outage]"
```

**Step 2: Prepare Pause Reason**
```
Good: "Oracle failure on Aave: prices not updating for 2+ hours"
Bad:  "Something wrong"
Better: "Aave oracle halt - prices frozen for 134 blocks (32 minutes)"
```

**Step 3: Call Pause Function**
```solidity
vault.pause("Aave oracle failure: prices frozen for 2+ hours, unable to process yields safely");
```

**Step 4: Confirm Pause**
- [ ] Check `vault.paused()` returns `true`
- [ ] Verify `IncidentPauseTriggered` event emitted
- [ ] Confirm off-chain monitor sent alerts
- [ ] Check Slack/Discord notifications received

**Step 5: Document Incident**
```
Create incident report with:
- Time of pause
- Reason for pause
- Root cause (preliminary)
- Actions taken
- Expected recovery time
```

### Decision Tree

```
INCIDENT DETECTED
    │
    ├─ Is it a critical security issue?
    │  └─ YES → PAUSE IMMEDIATELY
    │
    ├─ Could it affect fund security?
    │  └─ YES → PAUSE IMMEDIATELY
    │
    ├─ Is the issue temporary (< 1 hour recovery)?
    │  └─ YES → Monitor closely, pause if persists > 30 min
    │
    ├─ Can it be resolved without pausing?
    │  └─ YES → Work with ops team
    │
    └─ UNCERTAIN?
       └─ PAUSE → Better safe than sorry
```

### Post-Pause Actions

1. **Immediate** (0-15 minutes)
   - [ ] Document incident details
   - [ ] Gather system logs and metrics
   - [ ] Alert governance leadership
   - [ ] Brief ops team on recovery plan

2. **Investigation Phase** (15-120 minutes)
   - [ ] Identify root cause
   - [ ] Assess financial impact
   - [ ] Verify no ongoing damage
   - [ ] Draft recovery proposal

3. **Recovery Proposal** (120-1440 minutes)
   - [ ] Coordinate with DAO governance
   - [ ] Propose recovery actions
   - [ ] Prepare governance vote materials
   - [ ] Await token holder vote

### Escalation Contacts

- **Head of Security**: @security-lead (Slack)
- **Operations Director**: @ops-director (Slack)
- **Governance Lead**: @governance (Slack)
- **Emergency Line**: +1-XXX-XXX-XXXX (SMS)

---

## Operator Runbook

### Purpose

This runbook guides operations team in responding to system pause alerts.

### Alert Response (0-5 minutes)

When you receive a pause alert:

1. **Acknowledge Alert**
   - [ ] React to alert with ✅
   - [ ] Post "Acknowledged" in #escrow-incident
   - [ ] Open monitoring dashboard

2. **Assess Current State**
   - [ ] Is system actually paused? `curl RPC/vault.paused()`
   - [ ] What was the pause reason?
   - [ ] How many escrows are affected?
   - [ ] Is anything actively breaking?

3. **Gather Initial Info**
   - [ ] Pull system logs from last 30 minutes
   - [ ] Check Aave protocol status
   - [ ] Review recent transactions
   - [ ] Check oracle prices

### Investigation Phase (5-30 minutes)

1. **Technical Diagnosis**
   ```bash
   # Check escrow vault state
   cast call $VAULT "paused()" --rpc-url $RPC
   
   # Get pause reason from event
   cast logs --address $VAULT "IncidentPauseTriggered" --rpc-url $RPC
   
   # Check Aave pool health
   cast call $AAVE_POOL "getReserveData(address)" $TOKEN --rpc-url $RPC
   ```

2. **Impact Assessment**
   - [ ] How many active escrows?
   - [ ] Total value at risk?
   - [ ] Number of affected users?
   - [ ] Estimated recovery cost?

3. **Root Cause Analysis**
   - [ ] Is it application-level bug?
   - [ ] External dependency failure?
   - [ ] Configuration issue?
   - [ ] Security threat?

### Communication (30-60 minutes)

1. **Internal Briefing**
   - Brief: ops team, security team, governance
   - Shared doc: Incident details + assessment
   - Slack update: Current status + ETA

2. **Public Communication**
   - Wait for ops director approval
   - Post to Discord #announcements
   - Tweet from official account (optional)
   - Email to affected users (if user data available)

### Recovery Coordination (60+ minutes)

1. **Prepare Recovery Proposal**
   - Coordinate recovery action with security team
   - Draft recovery proposal details
   - Get governance team prepared

2. **Monitor Recovery Vote**
   - [ ] Governance proposal submitted
   - [ ] Voting period active
   - [ ] Check vote progress
   - [ ] Monitor social channels

3. **Execute Recovery** (after 2-day delay)
   - [ ] Confirm 2-day timelock passed
   - [ ] Execute recovery action
   - [ ] Verify execution succeeded
   - [ ] Monitor system state

4. **Resume Operations**
   - [ ] Guardian/Timelock calls `unpause()`
   - [ ] Confirm system is running
   - [ ] Test escrow operations
   - [ ] Monitor for issues

---

## Recovery Runbook

### Purpose

This runbook guides governance/DAO in executing recovery actions.

### Pre-Recovery (Incident Detection → Governance)

1. **Incident Confirmed**
   - Guardian pauses system
   - Off-chain alerts sent
   - Root cause investigation begins

2. **Recovery Planning** (0-24 hours)
   - Security team confirms issue
   - Recovery actions identified
   - Impact assessment completed
   - Recovery cost estimated

3. **Governance Preparation** (24-48 hours)
   - Draft recovery proposal
   - Prepare governance materials
   - Build consensus in forums
   - Schedule governance vote

### Creating Recovery Proposal

**Step 1: Gather Information**
```
Recovery Proposal Template:
- Issue: [What went wrong?]
- Impact: [What funds/users affected?]
- Root Cause: [Why did it happen?]
- Action: [What recovery action?]
- Benefits: [What does this fix?]
- Risks: [What could go wrong?]
- Alternatives: [Other options?]
```

**Step 2: Draft Governance Proposal**

Example proposal text:
```
TITLE: Emergency Recovery - Aave Oracle Failure

SUMMARY:
Aave oracle failed on [DATE], stopping yield generation for 
[DURATION]. Escrow system was paused by guardian. This proposal 
authorizes emergency unwind of Aave positions to recover funds.

DESCRIPTION:
On [DATE] at [TIME], the Aave oracle stopped updating prices,
making yield generation impossible. The escrow system was safely
paused by the guardian to prevent further issues.

This proposal authorizes the EmergencyRecoveryProposal contract
to execute EMERGENCY_UNWIND_AAVE action, which will:
1. Unwind all Aave positions
2. Return underlying tokens to escrow vault
3. Record emergency unwind event for audit trail

Total affected: [NUM] escrows worth $[VALUE]
Expected recovery: 98% of principle (2% slippage + gas)

RISKS:
- Aave liquidity pool might have high slippage
- Unwind might be partial if liquidity low
- Gas costs estimated at $[AMOUNT]

RECOVERY TIMELINE:
- Vote closes: [DATE + VOTING_PERIOD]
- Timelock delay: [DATE + TIMELOCK]
- Recovery execution: [DATE + TIMELOCK + 1 hour]
- System resume: [DATE + TIMELOCK + 2 hours]

VOTING:
FOR: Execute recovery unwind immediately
AGAINST: Wait for alternative solution
ABSTAIN: No position

This vote requires [QUORUM]% quorum and >50% support.
```

**Step 3: Submit to Governance**

```solidity
// Create Governor proposal
governor.propose(
    targets,              // [recoveryProposal]
    values,               // [0]
    calldatas,            // [abi.encodeWithSelector(...)]
    description           // Full proposal text
);
```

### During Voting (Voting Period)

1. **Monitor Vote Progress**
   - Check voting participation
   - Track FOR/AGAINST/ABSTAIN
   - Monitor governance forums
   - Address concerns

2. **Engage Community**
   - Answer questions
   - Provide additional analysis
   - Respond to concerns
   - Build support

3. **Prepare Execution**
   - If passing: prep recovery action
   - If failing: prep alternative
   - Brief execution team
   - Ready for either outcome

### Post-Vote (After Vote Closes)

**If Vote PASSED:**

1. Governor queues proposal with Timelock
2. System shows status: APPROVED
3. 2-day delay begins

**During 2-Day Delay:**

1. **Security Review**
   - [ ] Final check of recovery logic
   - [ ] Verify no edge cases
   - [ ] Prepare for execution

2. **Communication**
   - [ ] Update community on timeline
   - [ ] Prepare for system resume
   - [ ] Ready support team

3. **Preparations**
   - [ ] Alert monitoring services
   - [ ] Brief on-call ops team
   - [ ] Test recovery in staging

**Recovery Execution:**

1. **Execute Recovery**
   ```bash
   # After 2-day delay, execute recovery
   npx hardhat run scripts/execute-recovery.ts --network mainnet
   ```

2. **Monitor Execution**
   - [ ] Transaction submitted
   - [ ] Watching for confirmation
   - [ ] Checking event logs
   - [ ] Verifying funds recovered

3. **Verify Success**
   - [ ] Escrow vault balance correct
   - [ ] User balances updated
   - [ ] No errors or failures
   - [ ] System state consistent

4. **System Resume**
   ```solidity
   // Guardian/Timelock calls unpause()
   vault.unpause();
   ```

5. **Post-Recovery**
   - [ ] Announce recovery completion
   - [ ] Monitor system for 24 hours
   - [ ] Verify user operations work
   - [ ] Begin post-incident analysis

### If Vote FAILED:

1. Proposal rejected
2. System remains paused
3. Alternative recovery needed
4. Start recovery planning again

---

## Governance Templates

### Emergency Recovery Proposal Template

```markdown
# Emergency Recovery Proposal

## Proposal Information
- **Title**: [Title]
- **Type**: Emergency Recovery
- **Proposed By**: [Address]
- **Date**: [YYYY-MM-DD]

## Executive Summary
[1-2 paragraph overview of the issue and proposed action]

## Background
- **Incident Date**: [Date/Time]
- **Root Cause**: [Technical explanation]
- **Affected Systems**: [Which contracts/functions]
- **Financial Impact**: [Amount at risk]

## Proposed Action
- **Action Type**: [EMERGENCY_UNWIND_AAVE | WITHDRAW_PAUSED_ESCROWS | etc]
- **Target Contract**: [Contract address]
- **Expected Outcome**: [What will happen]

## Impact Assessment
- **Number of Escrows**: [X]
- **Total Value Affected**: $[X]
- **Users Impacted**: [X]
- **Expected Recovery %**: [X%]

## Implementation Details
[Technical steps for recovery]

## Risk Analysis
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| [Risk] | [High/Med/Low] | [High/Med/Low] | [How mitigated] |

## Timeline
- Voting Period: [X days]
- Timelock Delay: 2 days
- Expected Execution: [Date + Timelock]
- System Resume: [Date + Timelock + 1h]

## Budget
- Gas Costs: $[X]
- Slippage: $[X]
- Total Cost: $[X]
- Recovered: $[X]
- Net Recovery: $[X]

## Voting
- FOR: Execute recovery
- AGAINST: Reject recovery
- ABSTAIN: No position

Quorum: [X%] | Support: >50%

## Questions?
See #governance or email governance@protocol.io
```

---

## User Communications

### Initial Incident Alert (sent to Discord/Twitter)

```
🚨 SYSTEM PAUSE NOTICE

Our escrow system was paused on [DATE] at [TIME UTC] due to 
[brief reason].

YOUR FUNDS ARE SAFE:
- All escrowed funds are secure in the contract
- No funds have been accessed or transferred
- Yield generation temporarily halted
- You can view your funds in your dashboard

WHAT'S HAPPENING:
- Our security team is investigating
- Recovery plan will be proposed to DAO
- Token holders will vote on recovery
- We will provide updates every 24 hours

NEXT STEPS:
1. Investigation: 0-24 hours
2. Governance vote: 24-72 hours  
3. Recovery execution: 72-96 hours
4. System resume: 96+ hours

Questions? See FAQ or email support@protocol.io
```

### Daily Status Updates (during pause)

```
📋 ESCROW SYSTEM PAUSE - STATUS UPDATE

Pause Duration: [X hours]

INVESTIGATION STATUS: [70% complete]
- Root cause: Identified ✅
- Impact assessment: Complete ✅
- Recovery plan: In progress ⏳
- Recovery cost estimate: $[X]

GOVERNANCE:
- Proposal drafted: ✅
- Community review: In progress ⏳
- Vote scheduled: [Date]

ESTIMATED TIMELINE:
- Investigation complete: [Date]
- Governance vote: [Date]
- Recovery execution: [Date]
- System resume: [Date + 2 days]

LATEST NEWS:
[Updates from past 24 hours]

FAQ: See docs/phase4-faq.md
Support: support@protocol.io
```

### Recovery Announcement

```
✅ RECOVERY APPROVED & EXECUTED

Governance Vote Results:
- FOR: [X%]
- AGAINST: [Y%]
- Participation: [Z%]

Recovery Action: EMERGENCY_UNWIND_AAVE
- Status: EXECUTED ✅
- Funds Recovered: $[X]
- Gas Cost: $[X]
- Net Recovery: $[X]

SYSTEM STATUS:
- Pause status: ACTIVE
- Recovery actions: COMPLETE ✅
- System health: GOOD

NEXT STEPS:
- Guardian/Timelock will unpause system
- Normal operations will resume
- Yields will resume
- Full post-incident analysis coming

THANK YOU for your patience and trust.
```

### System Resume Announcement

```
🟢 ESCROW SYSTEM RESUMED

The escrow system has been resumed and is operating normally.

INCIDENT SUMMARY:
- Duration: [X hours]
- Root Cause: [Issue]
- Funds Recovered: 100% - $[X]
- Users Affected: [X]
- Service Level: RESTORED

WHAT WE'VE DONE:
1. Identified and fixed root cause
2. Executed recovery via governance
3. Restored system to full health
4. Implemented safeguards to prevent recurrence

WHAT'S NEXT:
- Post-incident analysis: [Date]
- Enhanced monitoring: LIVE
- Governance improvements: [Date]
- Full report: [Date]

We appreciate your trust and patience during this incident.
```

---

## FAQ & Troubleshooting

### What does "paused" mean?

**Paused State**:
- ❌ Cannot create new escrows
- ❌ Cannot release existing escrows  
- ❌ Cannot receive yields
- ✅ Can view your funds
- ✅ Funds remain secure
- ✅ Can withdraw after recovery

### Why did the system pause?

The system was paused by a guardian (emergency operator) due to a detected issue:

- Market anomaly
- Technical issue
- Security threat
- External dependency failure
- Governance decision

### Are my funds safe?

**YES.** Your funds are:
- Held in escrow contract (non-custodial)
- Protected by smart contract security
- Not affected by pause
- Recoverable after pause
- Insured (if applicable)

### When will the system resume?

Timeline:
1. Investigation: 0-24 hours
2. Governance vote: 24-72 hours
3. Recovery execution: 72+ hours
4. System resume: Usually within 96 hours

You'll receive updates every 24 hours.

### Can I withdraw during pause?

Generally NO, but:
- Emergency governance can vote to enable emergency withdrawals
- Timelock enforces minimum 2-day delay
- Withdrawals happen after governance vote

### What if I disagree with the recovery?

You can:
- Vote AGAINST recovery proposal (if token holder)
- Join governance forums and share concerns
- Propose alternative recovery actions
- Contact governance team

### Who decides on recovery?

Recovery is governed by:
1. **Guardian**: Decides to pause
2. **DAO/Governance**: Proposes recovery
3. **Token Holders**: Vote on recovery
4. **Timelock**: Enforces delays
5. **Executor**: Executes approved recovery

### Will this happen again?

We've implemented safeguards:
- Real-time monitoring
- Automatic alerts
- Guardian pause mechanism
- Governance recovery
- Regular security audits
- Enhanced testing

Risk is always present in DeFi, but we're committed to safety.

### Where can I learn more?

- **Documentation**: docs/PHASE1-4_summary.md
- **Guardian System**: docs/GUARDIAN_PAUSE_SUMMARY.md
- **Monitoring**: docs/MONITOR_SETUP.md
- **Recovery Framework**: docs/PHASE3_RECOVERY_FRAMEWORK.md
- **Discord**: #escrow-help channel
- **Email**: support@protocol.io

---

## Summary

This Phase 4 documentation provides:

✅ **Guardian Runbook**: When and how to pause
✅ **Operator Runbook**: How to respond to incidents  
✅ **Recovery Runbook**: How to execute recovery
✅ **Governance Templates**: How to propose recovery
✅ **User Communications**: Keeping users informed
✅ **FAQ & Troubleshooting**: Common questions answered

All materials are designed to:
- Keep users informed and calm
- Enable fast incident response
- Enable effective governance
- Build trust in emergency systems
- Provide clear next steps

---

**Status**: ✅ Phase 4 Complete
**Coverage**: All operational scenarios
**Ready for**: Production deployment
