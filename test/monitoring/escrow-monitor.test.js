/**
 * Tests for Escrow Monitor
 *
 * Tests the off-chain monitoring system for pause/resume events
 */

const test = require('node:test');
const assert = require('node:assert');
const EscrowMonitor = require('../../scripts/monitoring/escrow-monitor');

test('EscrowMonitor - Initialization', async () => {
  const config = {
    rpcUrl: 'http://localhost:8545',
    escrowVaultAddress: '0x0000000000000000000000000000000000000001',
    guardianAddress: '0x0000000000000000000000000000000000000002',
    isDev: true,
  };

  const monitor = new EscrowMonitor(config);

  assert.ok(monitor, 'Monitor should be created');
  assert.equal(monitor.config.rpcUrl, config.rpcUrl, 'RPC URL should match');
  assert.equal(
    monitor.config.escrowVaultAddress,
    config.escrowVaultAddress,
    'Vault address should match',
  );
});

test('EscrowMonitor - Status Check', async () => {
  const config = {
    rpcUrl: 'http://localhost:8545',
    escrowVaultAddress: '0x0000000000000000000000000000000000000001',
    isDev: true,
  };

  const monitor = new EscrowMonitor(config);
  const status = monitor.getStatus();

  assert.equal(status.running, false, 'Should not be running initially');
  assert.equal(status.isPaused, false, 'System should not be paused initially');
  assert.ok('lastProcessedBlock' in status, 'Status should have lastProcessedBlock');
  assert.equal(status.processedEventCount, 0, 'Should have no processed events initially');
});

test('EscrowMonitor - Event Name Detection', async () => {
  const config = {
    rpcUrl: 'http://localhost:8545',
    escrowVaultAddress: '0x0000000000000000000000000000000000000001',
    isDev: true,
  };

  const monitor = new EscrowMonitor(config);

  // Test event name extraction
  const pauseTopic = monitor.getEventName(
    '0x1234567890123456789012345678901234567890123456789012345678901234',
  );
  assert.ok(pauseTopic === null || typeof pauseTopic === 'string', 'Should return string or null');
});

test('EscrowMonitor - Pause Reason Extraction', async () => {
  const config = {
    rpcUrl: 'http://localhost:8545',
    escrowVaultAddress: '0x0000000000000000000000000000000000000001',
    isDev: true,
  };

  const monitor = new EscrowMonitor(config);

  // Test with real hex data (simple test)
  const reason = monitor.extractPauseReason('0x');
  assert.ok(typeof reason === 'string', 'Should return a string');
});

console.log('✅ Monitor tests would run with: npm test:monitor');
