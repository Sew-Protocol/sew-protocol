# Phase 2: Monitoring & Alerting System

## Overview

The Guardian Pause system requires robust monitoring and alerting capabilities to ensure rapid incident response. This document describes the monitoring infrastructure for detecting pause events and triggering alerts.

## Architecture

### Event Monitoring

The system emits two critical events:

1. **IncidentPauseTriggered**
   - Emitted when guardian calls `pause(reason)`
   - Includes: `reason` (string), `timestamp` (uint256)
   - **Severity**: CRITICAL
   - **Action Required**: Immediate notification to ops team

2. **SystemResumed**
   - Emitted when timelock calls `unpause()`
   - Includes: `timestamp` (uint256)
   - **Severity**: INFO
   - **Action**: Notification to stakeholders

### Off-Chain Watcher Architecture

```
┌─────────────────┐
│  Blockchain     │
│  (Escrow Vault) │
│  IncidentPause  │
│  Event          │
└────────┬────────┘
         │
         ▼
┌─────────────────────────┐
│  Event Monitor          │
│  (Node.js Service)      │
│  - Listen to events     │
│  - Parse reason/context │
│  - Store in DB          │
└────────┬────────────────┘
         │
         ▼
┌─────────────────────────┐
│  Alert Router           │
│  - Slack notification   │
│  - Discord webhook      │
│  - PagerDuty escalation │
│  - Email alert          │
└─────────────────────────┘
         │
         ▼
┌──────────────────────────┐
│  Ops Team               │
│  - Receives notification │
│  - Investigates incident │
│  - Executes recovery     │
└──────────────────────────┘
```

## Events Reference

### IncidentPauseTriggered

**Emitted by**: `BaseEscrow.pause(string reason)`

**When**: Guardian detects and pauses the escrow system

**Parameters**:
- `reason` (string): Human-readable reason for pause
  - Examples: "Unusual activity detected", "Security vulnerability", "Yield module failure"
- `timestamp` (uint256): Block timestamp when paused

**Suggested Alert Priority**: CRITICAL

### SystemResumed

**Emitted by**: `BaseEscrow.unpause()`

**When**: Timelock (governance) decides to resume operations

**Parameters**:
- `timestamp` (uint256): Block timestamp when resumed

**Suggested Alert Priority**: INFORMATIONAL

## Monitoring Rules

### Rule 1: Rapid Alert on Pause

```yaml
Rule: "Pause Detected"
Condition: IncidentPauseTriggered event
Threshold: Immediate (no delay)
Action:
  - Send CRITICAL alert to #escrow-incident channel
  - Ping on-call ops engineer
  - Create PagerDuty incident
  - Archive event data for audit trail
```

### Rule 2: Pause Duration Tracking

```yaml
Rule: "Pause Duration Monitor"
Condition: Time elapsed since pause > threshold
Threshold: 6 hours (configurable)
Action:
  - Send escalation alert "System paused for 6+ hours"
  - Notify governance team
  - Request status update from guardian
```

### Rule 3: Resume Notification

```yaml
Rule: "System Resumed"
Condition: SystemResumed event
Threshold: Immediate
Action:
  - Send INFO notification to #escrow-incidents
  - Update monitoring dashboard
  - Send notification to all subscribers
  - Log timestamp for analytics
```

### Rule 4: Multiple Pause Events

```yaml
Rule: "Repeated Pauses"
Condition: > 2 pauses in 24 hours
Threshold: 2 events / 24h
Action:
  - Escalate to CRITICAL
  - Notify head of security
  - Request formal incident report
  - Schedule emergency governance vote
```

## Alert Channels

### Production Alerts

| Channel | Trigger | Recipient | Response |
|---------|---------|-----------|----------|
| Slack | Any pause | #escrow-incident | On-call engineer |
| Discord | Any pause | @escrow-ops-role | Community notification |
| PagerDuty | Pause > 2h | On-call team | Formal incident |
| Email | Summary | ops@escrow.io | Audit trail |
| SMS | Pause > 6h | +1-XXX-XXX-XXXX | Urgent escalation |

### Monitoring Dashboard

Real-time dashboard showing:
- Last pause event (reason, timestamp, guardian)
- Current system status (paused/running)
- Pause duration (if paused)
- Historical pause events (last 30 days)
- Recovery actions in progress

## Implementation: Simple Watcher Service

### Prerequisites

```bash
npm install ethers dotenv axios
```

### Configuration (.env)

```
RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY
ESCROW_VAULT_ADDRESS=0x...
GUARDIAN_ADDRESS=0x...
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
PAGERDUTY_INTEGRATION_KEY=...
ALERT_EMAIL=ops@escrow.io
```

### Service Implementation

See `scripts/monitoring/escrow-monitor.ts` for complete implementation.

Key responsibilities:
1. Connect to blockchain via RPC
2. Listen to `IncidentPauseTriggered` events
3. Parse pause reason and context
4. Route alerts to configured channels
5. Store event history for analytics
6. Maintain heartbeat health check

### Running the Watcher

```bash
# Development (with logs)
npm run monitor:dev

# Production (daemonized)
npm run monitor:prod

# Check status
npm run monitor:status

# View recent events
npm run monitor:logs
```

## Event Storage & Audit Trail

All pause events must be stored in a database for audit purposes:

```javascript
{
  id: "pause_001",
  timestamp: 1701234567,
  blockNumber: 18456789,
  transactionHash: "0xabc...",
  guardian: "0x...",
  reason: "Unusual activity detected",
  duration: 3600, // seconds until unpause
  status: "active", // active | resolved
  alerts_sent: ["slack", "discord", "email"],
  incident_report: "https://...",
  recovery_actions: [
    { action: "emergency_unwind", status: "completed", timestamp: 1701238167 }
  ]
}
```

## Documentation for Operators

### When to Pause

Guardian should pause if:
- ✅ Unusual transaction patterns detected
- ✅ Yield module malfunction detected
- ✅ Smart contract vulnerability discovered
- ✅ External dependency failure (Aave, oracle)
- ✅ Mass withdrawal requests detected
- ✅ Manual override by governance (multi-sig)

### What Happens When Paused

- ❌ Cannot create new escrows
- ❌ Cannot release existing escrows
- ❌ Cannot execute automatic releases
- ✅ Can query escrow state
- ✅ Can execute emergency unwind via GuardianOps
- ✅ Can execute recovery operations

### Recovery Timeline

1. **Pause Event** (T+0s)
  - Guardian detects issue and calls `pause(reason)`
  - `IncidentPauseTriggered` event emitted
  - Alerts triggered to ops team

2. **Investigation Phase** (T+0h to T+2h)
  - Ops team investigates root cause
  - Security review of issue
  - Recovery plan drafted

3. **Governance Vote** (T+2h to T+24h)
  - Governance proposes recovery actions
  - DAO votes on proposal
  - Timelock enforces voting delay

4. **Recovery Execution** (T+24h to T+48h)
  - Approved recovery actions execute
  - Funds safely unwound from yield
  - System state restored

5. **System Resume** (T+48h+)
  - Timelock calls `unpause()`
  - `SystemResumed` event emitted
  - Normal operations resume

## Runbook for On-Call

### Alert Received: "Escrow System Paused"

1. **Immediate (0-5 min)**
   - [ ] Acknowledge alert
   - [ ] Check reason in alert details
   - [ ] Open monitoring dashboard
   - [ ] Pull up recent transaction history

2. **Investigation (5-30 min)**
   - [ ] Check Aave protocol status
   - [ ] Check oracle status
   - [ ] Review recent transactions
   - [ ] Contact guardian for more context

3. **Escalation (30+ min)**
   - [ ] Notify security team
   - [ ] Notify governance leads
   - [ ] Prepare incident report
   - [ ] Schedule governance emergency call

### Alert Received: "Pause Duration > 6 hours"

1. [ ] Verify governance vote is in progress
2. [ ] Check recovery actions scheduled
3. [ ] Escalate to head of security
4. [ ] Request status update from governance
5. [ ] Prepare stakeholder communication

## Success Metrics

- **Alert Latency**: < 1 minute from pause to notification
- **Alert Accuracy**: 0 false positives
- **Coverage**: 100% of events monitored
- **Channel Availability**: 99.9% uptime
- **Incident Response Time**: < 30 minutes from alert to team investigation

## Future Enhancements

- [ ] Automated recovery proposal generation
- [ ] Multi-signature governance execution
- [ ] Advanced anomaly detection for pause triggers
- [ ] Unified incident dashboard across all systems
- [ ] Automated testing of pause/resume flows
- [ ] Integration with on-call scheduling systems
- [ ] Analytics on pause frequency and duration
