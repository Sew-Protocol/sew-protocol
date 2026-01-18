/**
 * Governance Configuration
 *
 * TypeScript configuration for governance contracts.
 * This file provides type-safe access to governance configuration.
 */

import {
  validateAddress,
  validateAndNormalizeAddress,
  isZeroAddress,
  ZERO_ADDRESS,
} from '../scripts/_lib/addresses';

/**
 * Safely parse an integer from an environment variable
 * @param envVar Environment variable value
 * @param defaultValue Default value if env var is not set
 * @param name Variable name for error messages
 * @returns Parsed integer
 * @throws Error if value cannot be parsed as an integer
 */
function parseInteger(
  envVar: string | undefined,
  defaultValue: number,
  name: string,
): number {
  const value = envVar || defaultValue.toString();

  // Trim whitespace
  const trimmed = value.trim();

  // Check if the entire string is numeric (allows negative numbers)
  if (!/^-?\d+$/.test(trimmed)) {
    throw new Error(
      `Invalid ${name}: "${value}" is not a valid integer. Expected a whole number.`,
    );
  }

  const parsed = parseInt(trimmed, 10);

  // Double-check parsing succeeded (should not happen after regex check, but safety first)
  if (isNaN(parsed) || !Number.isInteger(parsed)) {
    throw new Error(
      `Invalid ${name}: "${value}" could not be parsed as an integer.`,
    );
  }

  return parsed;
}

/**
 * Safely parse a BigInt from a string
 * @param value String value to parse
 * @param name Variable name for error messages
 * @returns Parsed BigInt
 * @throws Error if value cannot be parsed as a BigInt
 */
function parseBigInt(value: string, name: string): bigint {
  const trimmed = value.trim();

  // Check if the entire string is numeric (allows negative numbers)
  if (!/^-?\d+$/.test(trimmed)) {
    throw new Error(
      `Invalid ${name}: "${value}" is not a valid integer string for BigInt parsing.`,
    );
  }

  try {
    const parsed = BigInt(trimmed);
    if (parsed === 0n) {
      throw new Error(`Invalid ${name}: value must be greater than 0`);
    }
    return parsed;
  } catch (error) {
    if (error instanceof Error && error.message.includes('must be greater than 0')) {
      throw error;
    }
    throw new Error(
      `Invalid ${name}: "${value}" could not be parsed as a BigInt. ${error instanceof Error ? error.message : String(error)}`,
    );
  }
}

export const GOVERNANCE_CONFIG = {
  token: {
    name: process.env.GOVERNANCE_TOKEN_NAME || 'Sew Token',
    symbol: process.env.GOVERNANCE_TOKEN_SYMBOL || 'SEW',
    initialSupply: process.env.GOVERNANCE_TOKEN_SUPPLY || '1000000000000000000000000000', // 1B tokens
  },
  safe: {
    owners: [
      process.env.SAFE_OWNER_1!,
      process.env.SAFE_OWNER_2!,
      process.env.SAFE_OWNER_3!,
      process.env.SAFE_OWNER_4!,
      process.env.SAFE_OWNER_5!,
    ]
      .filter((addr): addr is string => !!addr && !isZeroAddress(addr))
      .map((addr) => validateAndNormalizeAddress(addr, 'SAFE_OWNER')),
    threshold: parseInteger(process.env.SAFE_THRESHOLD, 3, 'SAFE_THRESHOLD'),
  },
  timelock: {
    minDelay: parseInteger(
      process.env.TIMELOCK_DELAY,
      172800, // 48 hours (2 days)
      'TIMELOCK_DELAY',
    ),
  },
  governor: {
    votingDelay: parseInteger(process.env.VOTING_DELAY, 1, 'VOTING_DELAY'), // blocks
    votingPeriod: parseInteger(
      process.env.VOTING_PERIOD,
      45818, // blocks (~1 week)
      'VOTING_PERIOD',
    ),
    proposalThreshold: process.env.PROPOSAL_THRESHOLD || '500000000000000000000000', // 500k tokens (0.05% of supply)
    absoluteQuorum:
      process.env.ABSOLUTE_QUORUM || '4000000000000000000000000', // 4M tokens (in wei)
  },
  guardian: {
    multisig: process.env.GUARDIAN_MULTISIG || '',
  },
  feeRecipient: process.env.FEE_RECIPIENT || '',
} as const;

/**
 * Validate that required configuration is present
 */
export function validateConfig(): void {
  const errors: string[] = [];

  // Validate token
  if (!GOVERNANCE_CONFIG.token.name) {
    errors.push('GOVERNANCE_TOKEN_NAME is required');
  }
  if (!GOVERNANCE_CONFIG.token.symbol) {
    errors.push('GOVERNANCE_TOKEN_SYMBOL is required');
  }
  if (!GOVERNANCE_CONFIG.token.initialSupply) {
    errors.push('GOVERNANCE_TOKEN_SUPPLY is required');
  } else {
    try {
      parseBigInt(GOVERNANCE_CONFIG.token.initialSupply, 'GOVERNANCE_TOKEN_SUPPLY');
    } catch (error) {
      errors.push(
        error instanceof Error ? error.message : `Invalid GOVERNANCE_TOKEN_SUPPLY: ${String(error)}`,
      );
    }
  }

  // Validate Safe
  if (GOVERNANCE_CONFIG.safe.owners.length === 0) {
    errors.push('At least one SAFE_OWNER_* is required');
  }
  if (!Number.isInteger(GOVERNANCE_CONFIG.safe.threshold) || isNaN(GOVERNANCE_CONFIG.safe.threshold)) {
    errors.push(
      `SAFE_THRESHOLD must be a valid integer, got: ${GOVERNANCE_CONFIG.safe.threshold}`,
    );
  } else if (
    GOVERNANCE_CONFIG.safe.threshold < 1 ||
    GOVERNANCE_CONFIG.safe.threshold > GOVERNANCE_CONFIG.safe.owners.length
  ) {
    errors.push(
      `SAFE_THRESHOLD (${GOVERNANCE_CONFIG.safe.threshold}) must be between 1 and number of owners (${GOVERNANCE_CONFIG.safe.owners.length})`,
    );
  }

  // Validate timelock
  if (!Number.isInteger(GOVERNANCE_CONFIG.timelock.minDelay) || isNaN(GOVERNANCE_CONFIG.timelock.minDelay)) {
    errors.push(
      `TIMELOCK_DELAY must be a valid integer, got: ${GOVERNANCE_CONFIG.timelock.minDelay}`,
    );
  } else if (GOVERNANCE_CONFIG.timelock.minDelay < 0) {
    errors.push('TIMELOCK_DELAY must be non-negative');
  }

  // Validate governor
  if (
    !Number.isInteger(GOVERNANCE_CONFIG.governor.votingDelay) ||
    isNaN(GOVERNANCE_CONFIG.governor.votingDelay)
  ) {
    errors.push(
      `VOTING_DELAY must be a valid integer, got: ${GOVERNANCE_CONFIG.governor.votingDelay}`,
    );
  } else if (GOVERNANCE_CONFIG.governor.votingDelay < 0) {
    errors.push('VOTING_DELAY must be non-negative');
  }

  if (
    !Number.isInteger(GOVERNANCE_CONFIG.governor.votingPeriod) ||
    isNaN(GOVERNANCE_CONFIG.governor.votingPeriod)
  ) {
    errors.push(
      `VOTING_PERIOD must be a valid integer, got: ${GOVERNANCE_CONFIG.governor.votingPeriod}`,
    );
  } else if (GOVERNANCE_CONFIG.governor.votingPeriod <= 0) {
    errors.push('VOTING_PERIOD must be greater than 0');
  }

  if (
    !GOVERNANCE_CONFIG.governor.absoluteQuorum ||
    GOVERNANCE_CONFIG.governor.absoluteQuorum.trim().length === 0
  ) {
    errors.push('ABSOLUTE_QUORUM is required');
  } else {
    try {
      parseBigInt(GOVERNANCE_CONFIG.governor.absoluteQuorum, 'ABSOLUTE_QUORUM');
    } catch (error) {
      errors.push(error instanceof Error ? error.message : `Invalid ABSOLUTE_QUORUM: ${String(error)}`);
    }
  }

  // Validate proposalThreshold (should be a valid BigInt string)
  if (GOVERNANCE_CONFIG.governor.proposalThreshold) {
    try {
      parseBigInt(GOVERNANCE_CONFIG.governor.proposalThreshold, 'PROPOSAL_THRESHOLD');
    } catch (error) {
      errors.push(
        error instanceof Error
          ? error.message
          : `Invalid PROPOSAL_THRESHOLD: ${String(error)}`,
      );
    }
  }

  if (errors.length > 0) {
    throw new Error(`Configuration validation failed:\n${errors.join('\n')}`);
  }
}
