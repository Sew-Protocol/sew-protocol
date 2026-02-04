/**
 * Monitoring Alert Thresholds & Configuration
 * 
 * These thresholds control when the monitoring watcher triggers alerts.
 * They are designed to detect anomalies without false positives.
 */

// ============ Dust Bounds ============
// Definition: Dust is any remainder below 1 unit of scaled share precision.
// Policy: Protocol-owned, bounded, and observable.

export const DUST_CONFIG = {
  // Absolute dust tolerance (in wei)
  TOLERANCE: 1n,
  
  // Relative dust threshold (as % of total deposits)
  // Alert if dust > 0.01% of total deposited amount
  RATIO_THRESHOLD: 0.0001,
  
  // Daily dust growth rate threshold
  // Alert if dust grows > 1% per day (sign of accounting drift)
  DAILY_GROWTH_RATE_THRESHOLD: 0.01,
};

// ============ Aave Health ============
// Aave health factor is: Total Collateral / Total Borrows
// When health factor drops below a threshold, the position becomes at-risk.

export const AAVE_HEALTH_CONFIG = {
  // Health factor threshold for alert
  // Standard threshold: 1.5 (conservative, gives safety margin)
  HEALTH_FACTOR_THRESHOLD: 1.5,
  
  // Reserve ratio threshold
  // Alert if available liquidity in Aave < 10% of module's deposits
  RESERVE_RATIO_THRESHOLD: 0.1,
  
  // Check interval (seconds)
  CHECK_INTERVAL: 300, // every 5 minutes
};

// ============ Yield Accounting ============
// Yield should be monotonic non-decreasing (only rounding noise should cause drift down).
// This config detects if yield decreases unexpectedly.

export const YIELD_ACCOUNTING_CONFIG = {
  // Monotonicity threshold
  // Allow small rounding drift down (e.g., -0.01% per operation)
  MONOTONICITY_THRESHOLD: -0.01,
  
  // Scaled balance mismatch threshold (in wei)
  // Alert if on-chain totalScaledBalance != actual scaledBalanceOf(aToken)
  // Threshold: >10 wei is critical
  SCALED_BALANCE_MISMATCH_THRESHOLD: 10n,
  
  // Check interval (seconds)
  CHECK_INTERVAL: 60, // every minute
};

// ============ Multi-Tenant Isolation ============
// Each escrow contract + workflowId should be isolated from others.
// Detect if positions are bleeding across tenants.

export const ISOLATION_CONFIG = {
  // Position mismatch threshold (in wei)
  // Any mismatch between expected and actual shares is critical
  POSITION_MISMATCH_THRESHOLD: 1n,
  
  // Check interval (seconds)
  CHECK_INTERVAL: 60, // every minute
};

// ============ Module State Consistency ============
// The yield module maintains several state invariants:
// 1. sum(all position scaled shares) == totalScaledBalance
// 2. Position snapshots are immutable per escrow

export const MODULE_STATE_CONFIG = {
  // Consistency check interval (seconds)
  CHECK_INTERVAL: 60, // every minute
  
  // Alert if mismatch in sum of positions
  CONSISTENCY_THRESHOLD: 1n,
};

// ============ Alert Routing ============
// Different alert levels go to different destinations.

export const ALERT_ROUTING = {
  // CRITICAL alerts (immediate action required)
  CRITICAL: {
    channels: ['slack', 'pagerduty', 'console'],
    prefix: '🚨 CRITICAL',
    description: 'Immediate incident response required. System may be at risk.',
  },
  
  // WARNING alerts (investigate soon)
  WARNING: {
    channels: ['slack', 'console'],
    prefix: '⚠️ WARNING',
    description: 'Investigate within 1 hour. System is degraded but not critical.',
  },
  
  // INFO alerts (for logging)
  INFO: {
    channels: ['console'],
    prefix: 'ℹ️ INFO',
    description: 'Informational message. No action required.',
  },
};

// ============ Guardian Pause Thresholds ============
// These are the conditions that should trigger guardian to pause.
// NOTE: Guardian pauses the system. Recovery is DAO-driven.

export const GUARDIAN_PAUSE_TRIGGERS = {
  // Trigger pause if Aave health factor drops below this
  AAVE_HEALTH_CRITICAL: 1.2,
  
  // Trigger pause if Aave reserve ratio drops below this
  AAVE_RESERVE_CRITICAL: 0.05,
  
  // Trigger pause if scaled balance mismatch is detected
  SCALED_BALANCE_MISMATCH_DETECTED: true,
  
  // Trigger pause if dust grows > 10% per day (sign of bug)
  DUST_EXPLOSION_RATE: 0.1,
  
  // Trigger pause if position isolation is violated
  ISOLATION_VIOLATION: true,
};

// ============ Recovery Procedures (DAO-Driven) ============
// When guardian pauses, the DAO must decide on recovery.
// These are the typical recovery scenarios and timelines.

export const RECOVERY_PROCEDURES = {
  // Scenario: Aave temporarily down
  // Expected recovery time: 1-6 hours
  AAVE_TEMPORARY_OUTAGE: {
    expectedRecoveryTime: '1-6 hours',
    action: 'Wait for Aave recovery (no DAO action needed)',
  },
  
  // Scenario: Aave permanently broken
  // Expected recovery time: 2-7 days (DAO vote)
  AAVE_PERMANENT_FAILURE: {
    expectedRecoveryTime: '2-7 days',
    action: 'DAO votes to migrate to new yield module',
  },
  
  // Scenario: Module bug discovered
  // Expected recovery time: 2-7 days (DAO vote)
  MODULE_BUG_DISCOVERED: {
    expectedRecoveryTime: '2-7 days',
    action: 'DAO votes to migrate to patched module',
  },
  
  // Scenario: Dust explosion (accounting bug)
  // Expected recovery time: Depends on scope, 2-7 days (DAO vote)
  DUST_EXPLOSION: {
    expectedRecoveryTime: '2-7 days',
    action: 'DAO votes on recovery (selective unwind, audit, etc.)',
  },
};

// ============ Testing Configuration ============
// When testing the monitoring system, use these synthetic values.

export const TEST_CONFIG = {
  // Synthetic test: create a scaled balance mismatch
  SYNTHETIC_MISMATCH_TRIGGER: {
    description: 'Create a mismatch between totalScaledBalance and actual balance',
    command: 'npx hardhat run scripts/monitoring/test-alerts.ts --trigger-mismatch',
  },
  
  // Synthetic test: create a dust explosion
  SYNTHETIC_DUST_EXPLOSION_TRIGGER: {
    description: 'Create rapid dust accumulation to trigger alert',
    command: 'npx hardhat run scripts/monitoring/test-alerts.ts --trigger-dust-explosion',
  },
  
  // Synthetic test: simulate Aave health drop
  SYNTHETIC_AAVE_HEALTH_TRIGGER: {
    description: 'Simulate Aave health factor drop',
    command: 'npx hardhat run scripts/monitoring/test-alerts.ts --trigger-aave-health',
  },
};

export default {
  DUST_CONFIG,
  AAVE_HEALTH_CONFIG,
  YIELD_ACCOUNTING_CONFIG,
  ISOLATION_CONFIG,
  MODULE_STATE_CONFIG,
  ALERT_ROUTING,
  GUARDIAN_PAUSE_TRIGGERS,
  RECOVERY_PROCEDURES,
  TEST_CONFIG,
};
