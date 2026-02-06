# Off-Chain Monitoring Setup Guide

## Quick Start

### 1. Install Dependencies

The monitor requires Node.js 18+ and ethers.js:

```bash
npm install ethers dotenv axios
```

### 2. Configure Environment

Copy the example env file and fill in your values:

```bash
cp scripts/monitoring/.env.example scripts/monitoring/.env
```

Edit `scripts/monitoring/.env` with:
- RPC URL (Mainnet or testnet)
- Escrow Vault contract address
- Webhook URLs for Slack/Discord
- PagerDuty integration key (optional)

### 3. Start Monitoring

**Development mode** (with verbose logs):
```bash
NODE_ENV=development node scripts/monitoring/escrow-monitor.js
```

**Production mode** (daemonized):
```bash
NODE_ENV=production node scripts/monitoring/escrow-monitor.js &
```

Or use `pm2` for production:
```bash
pm2 start scripts/monitoring/escrow-monitor.js --name escrow-monitor
```

### 4. Verify It's Working

Check monitor status in another terminal:
```bash
curl http://localhost:3000/status
```

You should see:
```json
{
  "running": true,
  "isPaused": false,
  "processedEventCount": 0
}
```

## Configuration

### Environment Variables

```bash
# Required
RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY
ESCROW_VAULT_ADDRESS=0x...

# Alert channels (at least one required for production)
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...

# Optional
PAGERDUTY_INTEGRATION_KEY=YOUR_KEY
ALERT_EMAIL=ops@example.com
NODE_ENV=production
POLL_INTERVAL=12000
START_BLOCK=18000000
```

### Alert Channels Setup

#### Slack

1. Go to your Slack workspace
2. Settings > Apps & Integrations
3. Create New App > From scratch
4. Name it "Escrow Monitor"
5. Go to Incoming Webhooks
6. Create New Webhook
7. Select #escrow-incidents channel
8. Copy webhook URL to `.env`

#### Discord

1. Right-click channel > Edit Channel
2. Webhooks > Create Webhook
3. Copy webhook URL to `.env`

#### PagerDuty

1. Go to Integrations > Events API V2
2. Create new integration
3. Select Events Rule V2
4. Copy routing key to `.env`

## Alert Messages

### Pause Alert

```
🚨 CRITICAL: ESCROW SYSTEM PAUSED
   Reason: Unusual activity on Aave protocol
   Time: 2024-01-15T10:30:45.123Z
   Block: 18456789
   TX: 0xabc123...
```

**Slack**: Red attachment with all details
**Discord**: Red embed with reason and block
**PagerDuty**: Critical incident triggered

### Resume Alert

```
✅ ESCROW SYSTEM RESUMED
   Time: 2024-01-15T12:30:45.123Z
   Pause Duration: 7200 seconds (2 hours)
   Block: 18457895
```

**Slack**: Green attachment
**Discord**: Green embed
**PagerDuty**: Incident resolved

### Escalation Alert (Pause > 6 hours)

```
⚠️  ESCALATION: Pause Duration Exceeds 6 Hours
   Duration: 6.5 hours
   Time: 2024-01-15T16:30:00.000Z
```

**Slack**: Yellow/warning attachment
**Triggers**: Escalation workflow in PagerDuty

## Monitoring Dashboard

Real-time monitoring dashboard showing:
- System pause status (live)
- Current pause duration
- Alert history (last 30 days)
- Guardian activity log
- Recovery action status

Access at: `http://localhost:3000/dashboard`

## Testing the Monitor

### Test Pause Alert

```bash
# Simulate pause by calling contract
npx hardhat run scripts/test-pause.js --network mainnet
```

### Test Event Listening

```bash
# Check if monitor is receiving events
tail -f escrow-monitor.log | grep "CRITICAL"
```

### Manual Health Check

```bash
# Check monitor is running
ps aux | grep escrow-monitor

# Check recent events in log
tail -100 escrow-monitor.log
```

## Troubleshooting

### Monitor not connecting to RPC

```bash
# Check RPC URL is valid
curl $RPC_URL -X POST -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Update .env with correct URL
```

### Alerts not sending to Slack

```bash
# Test Slack webhook directly
curl -X POST $SLACK_WEBHOOK_URL \
  -H 'Content-type: application/json' \
  --data '{"text":"Test message"}'
```

### Missing pause events

```bash
# Check START_BLOCK is correct
echo $START_BLOCK  # Should be before first pause event

# Restart monitor with correct block
START_BLOCK=18000000 node scripts/monitoring/escrow-monitor.js
```

### High RPC load

Reduce polling frequency in .env:
```bash
POLL_INTERVAL=30000  # 30 seconds instead of 12
```

## Production Checklist

- [ ] RPC URL set to production mainnet
- [ ] ESCROW_VAULT_ADDRESS verified on etherscan
- [ ] Slack webhook tested and working
- [ ] Discord webhook tested and working
- [ ] PagerDuty integration configured (optional)
- [ ] NODE_ENV set to 'production'
- [ ] Monitor running via pm2 or systemd
- [ ] Log rotation configured
- [ ] Alerting team notified of webhook URLs
- [ ] Monitoring dashboard accessible internally
- [ ] Backup monitor instance on different server
- [ ] Health check monitoring enabled

## Logs

Monitor logs go to stdout and can be piped:

```bash
# Save logs to file
node scripts/monitoring/escrow-monitor.js > escrow-monitor.log 2>&1 &

# Watch logs in real-time
tail -f escrow-monitor.log

# Filter for critical events only
tail -f escrow-monitor.log | grep "CRITICAL"
```

## Performance

- **Memory usage**: ~50-100MB typical
- **CPU usage**: <1% typical
- **RPC calls**: 1 per poll interval (~12s)
- **Alert latency**: <30 seconds from pause to notification

## Future Enhancements

- [ ] Database backend for event persistence
- [ ] Web dashboard with historical analytics
- [ ] Automated recovery action proposals
- [ ] Integration with governance voting
- [ ] Multi-chain monitoring support
- [ ] Machine learning for anomaly detection
- [ ] Automated escalation policies
