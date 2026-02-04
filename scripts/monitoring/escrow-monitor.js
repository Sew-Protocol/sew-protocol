#!/usr/bin/env node

/**
 * Escrow Monitor - Off-chain listener for pause/resume events
 * 
 * Monitors BaseEscrow contract for IncidentPauseTriggered and SystemResumed events
 * Sends alerts to configured channels (Slack, Discord, Email, PagerDuty)
 * 
 * Usage:
 *   npm run monitor:dev     # Development with logs
 *   npm run monitor:prod    # Production daemonized
 */

const ethers = require('ethers');
const axios = require('axios');
require('dotenv').config();

// Configuration
const config = {
  rpcUrl: process.env.RPC_URL || 'http://localhost:8545',
  escrowVaultAddress: process.env.ESCROW_VAULT_ADDRESS,
  guardianAddress: process.env.GUARDIAN_ADDRESS,
  slackWebhookUrl: process.env.SLACK_WEBHOOK_URL,
  discordWebhookUrl: process.env.DISCORD_WEBHOOK_URL,
  pagerDutyKey: process.env.PAGERDUTY_INTEGRATION_KEY,
  alertEmail: process.env.ALERT_EMAIL,
  pollInterval: 12000, // 12 seconds
  isDev: process.env.NODE_ENV !== 'production',
};

// ABI fragments for events
const INCIDENT_PAUSE_TRIGGERED = {
  type: 'event',
  name: 'IncidentPauseTriggered',
  inputs: [
    { name: 'reason', type: 'string', indexed: false },
    { name: 'timestamp', type: 'uint256', indexed: false },
  ],
};

const SYSTEM_RESUMED = {
  type: 'event',
  name: 'SystemResumed',
  inputs: [
    { name: 'timestamp', type: 'uint256', indexed: false },
  ],
};

// Event store (in-memory; use database in production)
const eventStore = {
  lastProcessedBlock: process.env.START_BLOCK || 0,
  processedEvents: new Map(),
  pauseStartTime: null,
  isPaused: false,
};

class EscrowMonitor {
  constructor(config) {
    this.config = config;
    this.provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.iface = new ethers.Interface([INCIDENT_PAUSE_TRIGGERED, SYSTEM_RESUMED]);
    this.isRunning = false;
  }

  async start() {
    this.isRunning = true;
    console.log('🚀 Starting Escrow Monitor...');
    console.log(`📡 RPC: ${this.config.rpcUrl}`);
    console.log(`🏠 Escrow Vault: ${this.config.escrowVaultAddress}`);
    
    // Run initial health check
    try {
      const blockNumber = await this.provider.getBlockNumber();
      console.log(`✅ Connected to blockchain at block ${blockNumber}`);
    } catch (error) {
      console.error('❌ Failed to connect to blockchain:', error.message);
      process.exit(1);
    }

    // Start polling for events
    this.pollInterval = setInterval(() => this.checkEvents(), this.config.pollInterval);
  }

  async stop() {
    this.isRunning = false;
    if (this.pollInterval) clearInterval(this.pollInterval);
    console.log('⏹️  Escrow Monitor stopped');
  }

  async checkEvents() {
    try {
      const currentBlock = await this.provider.getBlockNumber();
      const fromBlock = Math.max(eventStore.lastProcessedBlock, currentBlock - 1000);
      const toBlock = currentBlock;

      if (this.config.isDev) {
        console.log(`\n🔍 Scanning blocks ${fromBlock} to ${toBlock}...`);
      }

      // Get raw logs for pause events
      const filter = {
        address: this.config.escrowVaultAddress,
        topics: [
          ethers.id('IncidentPauseTriggered(string,uint256)'),
          ethers.id('SystemResumed(uint256)'),
        ],
      };

      const logs = await this.provider.getLogs({
        ...filter,
        fromBlock,
        toBlock,
      });

      if (logs.length === 0 && this.config.isDev) {
        console.log('   No events found');
        return;
      }

      for (const log of logs) {
        const eventName = this.getEventName(log.topics[0]);
        
        if (eventName === 'IncidentPauseTriggered') {
          await this.handlePauseTrigger(log);
        } else if (eventName === 'SystemResumed') {
          await this.handleSystemResumed(log);
        }
      }

      eventStore.lastProcessedBlock = toBlock;

      // Check pause duration
      if (eventStore.isPaused) {
        const pauseDuration = Date.now() - eventStore.pauseStartTime;
        const pauseHours = pauseDuration / (1000 * 60 * 60);
        
        if (pauseHours > 6 && pauseHours - 0.1 <= (pauseDuration + this.config.pollInterval) / (1000 * 60 * 60)) {
          await this.alertLongPauseDuration(pauseHours);
        }
      }
    } catch (error) {
      console.error('❌ Error checking events:', error.message);
    }
  }

  getEventName(topic) {
    if (topic === ethers.id('IncidentPauseTriggered(string,uint256)')) {
      return 'IncidentPauseTriggered';
    }
    if (topic === ethers.id('SystemResumed(uint256)')) {
      return 'SystemResumed';
    }
    return null;
  }

  async handlePauseTrigger(log) {
    const reason = this.extractPauseReason(log.data);
    const timestamp = new Date().toISOString();

    console.error('\n🚨 CRITICAL: ESCROW SYSTEM PAUSED');
    console.error(`   Reason: ${reason}`);
    console.error(`   Time: ${timestamp}`);
    console.error(`   Block: ${log.blockNumber}`);
    console.error(`   TX: ${log.transactionHash}`);

    eventStore.isPaused = true;
    eventStore.pauseStartTime = Date.now();

    // Send alerts
    await Promise.all([
      this.sendSlackAlert({
        text: '🚨 ESCROW SYSTEM PAUSED',
        reason,
        timestamp,
        block: log.blockNumber,
        tx: log.transactionHash,
        severity: 'CRITICAL',
      }),
      this.sendDiscordAlert({
        title: '🚨 ESCROW SYSTEM PAUSED',
        reason,
        timestamp,
        color: 0xFF0000, // Red
      }),
      this.sendPagerDutyAlert({
        summary: `Escrow system paused: ${reason}`,
        severity: 'critical',
        body: {
          details: `Reason: ${reason}\nBlock: ${log.blockNumber}\nTX: ${log.transactionHash}`,
        },
      }),
    ]);
  }

  async handleSystemResumed(log) {
    const timestamp = new Date().toISOString();
    const pauseDuration = eventStore.pauseStartTime ? 
      (Date.now() - eventStore.pauseStartTime) / 1000 : 0;

    console.log('\n✅ ESCROW SYSTEM RESUMED');
    console.log(`   Time: ${timestamp}`);
    console.log(`   Pause Duration: ${Math.round(pauseDuration)}s`);
    console.log(`   Block: ${log.blockNumber}`);

    eventStore.isPaused = false;
    eventStore.pauseStartTime = null;

    // Send alerts
    await Promise.all([
      this.sendSlackAlert({
        text: '✅ ESCROW SYSTEM RESUMED',
        timestamp,
        duration: Math.round(pauseDuration),
        block: log.blockNumber,
        severity: 'INFO',
      }),
      this.sendDiscordAlert({
        title: '✅ ESCROW SYSTEM RESUMED',
        timestamp,
        color: 0x00FF00, // Green
      }),
    ]);
  }

  async alertLongPauseDuration(pauseHours) {
    console.warn(`\n⚠️  WARNING: System paused for ${pauseHours.toFixed(1)} hours`);
    
    await this.sendSlackAlert({
      text: `⚠️ ESCALATION: Pause Duration Exceeds 6 Hours`,
      duration: `${pauseHours.toFixed(1)} hours`,
      severity: 'ESCALATION',
    });
  }

  async sendSlackAlert(alertData) {
    if (!this.config.slackWebhookUrl) return;

    try {
      const color = alertData.severity === 'CRITICAL' ? 'danger' : 
                   alertData.severity === 'ESCALATION' ? 'warning' : 'good';

      await axios.post(this.config.slackWebhookUrl, {
        attachments: [{
          fallback: alertData.text,
          color,
          title: alertData.text,
          fields: [
            { title: 'Severity', value: alertData.severity, short: true },
            { title: 'Time', value: alertData.timestamp || new Date().toISOString(), short: true },
            ...(alertData.reason ? [{ title: 'Reason', value: alertData.reason, short: false }] : []),
            ...(alertData.duration ? [{ title: 'Duration', value: alertData.duration, short: true }] : []),
            ...(alertData.block ? [{ title: 'Block', value: alertData.block.toString(), short: true }] : []),
            ...(alertData.tx ? [{ title: 'Transaction', value: alertData.tx, short: false }] : []),
          ],
          footer: 'Escrow Monitor',
          ts: Math.floor(Date.now() / 1000),
        }],
      });

      if (this.config.isDev) console.log('✉️  Slack alert sent');
    } catch (error) {
      console.error('❌ Failed to send Slack alert:', error.message);
    }
  }

  async sendDiscordAlert(alertData) {
    if (!this.config.discordWebhookUrl) return;

    try {
      await axios.post(this.config.discordWebhookUrl, {
        embeds: [{
          title: alertData.title,
          description: `${alertData.reason || ''}\n\n**Time**: ${alertData.timestamp || new Date().toISOString()}`,
          color: alertData.color,
          timestamp: new Date().toISOString(),
        }],
      });

      if (this.config.isDev) console.log('💬 Discord alert sent');
    } catch (error) {
      console.error('❌ Failed to send Discord alert:', error.message);
    }
  }

  async sendPagerDutyAlert(alertData) {
    if (!this.config.pagerDutyKey) return;

    try {
      await axios.post('https://events.pagerduty.com/v2/enqueue', {
        routing_key: this.config.pagerDutyKey,
        event_action: 'trigger',
        payload: {
          summary: alertData.summary,
          severity: alertData.severity,
          source: 'Escrow Monitor',
          custom_details: alertData.body,
          timestamp: new Date().toISOString(),
        },
      });

      if (this.config.isDev) console.log('📟 PagerDuty alert sent');
    } catch (error) {
      console.error('❌ Failed to send PagerDuty alert:', error.message);
    }
  }

  extractPauseReason(data) {
    // Simple extraction - in production use proper ABI decoding
    try {
      return Buffer.from(data, 'hex').toString('utf8').replace(/\0/g, '');
    } catch {
      return 'Unknown reason';
    }
  }

  getStatus() {
    return {
      running: this.isRunning,
      isPaused: eventStore.isPaused,
      pauseStartTime: eventStore.pauseStartTime ? new Date(eventStore.pauseStartTime).toISOString() : null,
      lastProcessedBlock: eventStore.lastProcessedBlock,
      processedEventCount: eventStore.processedEvents.size,
    };
  }
}

// Main
const monitor = new EscrowMonitor(config);

// Start on launch
monitor.start().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});

// Graceful shutdown
process.on('SIGINT', async () => {
  console.log('\n\nShutting down gracefully...');
  await monitor.stop();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  console.log('\n\nShutting down gracefully...');
  await monitor.stop();
  process.exit(0);
});

// Export for testing
module.exports = EscrowMonitor;
