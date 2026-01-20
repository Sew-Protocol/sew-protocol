/**
 * Governance Deployment Configuration
 *
 * Centralized configuration for governance contracts deployment.
 * Reads from environment variables with sensible defaults for local development.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';
import {
  validateAddress,
  validateAndNormalizeAddress,
  isZeroAddress,
  ZERO_ADDRESS,
} from '../scripts/_lib/addresses';
import { isLocal as isLocalNetwork } from '../config/chains.config';

export type GovDeployConfig = {
  // Token configuration
  token: {
    name: string;
    symbol: string;
    initialSupply: string; // wei as string
  };

  // Safe multisig configuration
  safe: {
    owners: string[];
    threshold: number;
  };

  // Timelock configuration
  timelock: {
    minDelaySec: number; // seconds
  };

  // Governor configuration
  governor: {
    votingDelayBlocks: number;
    votingPeriodBlocks: number;
    proposalThreshold: string; // token units as string
    absoluteQuorum: string; // absolute quorum amount in token units as string (e.g., "4000000000000000000000000" = 4M tokens)
    initialNonCirculatingAddresses?: string[]; // addresses to track for transparency/APIs (e.g., vesting contracts)
  };

  // Guardian configuration
  guardian: {
    multisig: string;
  };

  // Fee recipient
  feeRecipient: string;

  // Initial token mints (for testing)
  initialGovTokenMints: Array<{ to: string; amount: string }>;
};

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
 * Get governance deployment configuration from environment variables
 *
 * @param hre Hardhat runtime environment
 * @returns Governance configuration object
 * @throws Error if required values are missing for non-local networks or if parsing fails
 */
export function getGovConfig(hre: HardhatRuntimeEnvironment): GovDeployConfig {
  const isLocal = isLocalNetwork(hre);

  // Token configuration
  const tokenName = process.env.GOVERNANCE_TOKEN_NAME || 'Sew Token';
  const tokenSymbol = process.env.GOVERNANCE_TOKEN_SYMBOL || 'SEW';
  const tokenSupply = process.env.GOVERNANCE_TOKEN_SUPPLY || '1000000000000000000000000000'; // 1B tokens

  // Safe multisig configuration
  const safeOwners = [
    process.env.SAFE_OWNER_1,
    process.env.SAFE_OWNER_2,
    process.env.SAFE_OWNER_3,
    process.env.SAFE_OWNER_4,
    process.env.SAFE_OWNER_5,
  ]
    .filter((addr): addr is string => !!addr && !isZeroAddress(addr))
    .map((addr) => validateAndNormalizeAddress(addr, 'SAFE_OWNER'));

  const safeThreshold = parseInteger(
    process.env.SAFE_THRESHOLD,
    3,
    'SAFE_THRESHOLD',
  );

  // Validate Safe configuration
  if (!isLocal && safeOwners.length < safeThreshold) {
    throw new Error(
      `Invalid Safe configuration: ${safeOwners.length} owners but threshold is ${safeThreshold}. ` +
        `Need at least ${safeThreshold} owners.`,
    );
  }

  // Timelock configuration
  const timelockMinDelaySec = parseInteger(
    process.env.TIMELOCK_DELAY,
    48 * 60 * 60, // 48 hours default
    'TIMELOCK_DELAY',
  );

  // Governor configuration
  const votingDelayBlocks = parseInteger(
    process.env.VOTING_DELAY,
    1,
    'VOTING_DELAY',
  );
  const votingPeriodBlocks = parseInteger(
    process.env.VOTING_PERIOD,
    45818, // ~1 week @ 13s/block
    'VOTING_PERIOD',
  );
  const proposalThreshold = process.env.PROPOSAL_THRESHOLD || '500000000000000000000000'; // 500k tokens (0.05% of supply)
  const absoluteQuorum = process.env.ABSOLUTE_QUORUM || '4000000000000000000000000'; // 4M tokens (absolute quorum)

  // Initial non-circulating addresses (e.g., vesting contracts, locked tokens)
  // Format: comma-separated addresses: ADDR1,ADDR2,ADDR3
  const initialNonCirculatingAddresses: string[] = [];
  const nonCirculatingEnv = process.env.INITIAL_NON_CIRCULATING_ADDRESSES || '';
  if (nonCirculatingEnv) {
    nonCirculatingEnv.split(',').forEach((addr) => {
      const trimmed = addr.trim();
      if (trimmed && !isZeroAddress(trimmed)) {
        initialNonCirculatingAddresses.push(validateAndNormalizeAddress(trimmed, 'INITIAL_NON_CIRCULATING_ADDRESSES'));
      }
    });
  }

  // Guardian configuration
  const guardianMultisig = process.env.GUARDIAN_MULTISIG || '';

  // Fee recipient
  const feeRecipient = process.env.FEE_RECIPIENT || guardianMultisig || '';

  // Initial token mints (for testing)
  const initialGovTokenMints: Array<{ to: string; amount: string }> = [];
  const mintsEnv = process.env.GOV_MINTS || '';
  if (mintsEnv) {
    mintsEnv.split(',').forEach((pair) => {
      const [to, amount] = pair.split(':');
      if (to && amount) {
        initialGovTokenMints.push({ to: to.trim(), amount: amount.trim() });
      }
    });
  }

  // Validation for non-local networks
  if (!isLocal) {
    if (safeOwners.length === 0) {
      throw new Error('Missing SAFE_OWNER_* environment variables for non-local network');
    }
    if (!guardianMultisig || isZeroAddress(guardianMultisig)) {
      throw new Error('Missing GUARDIAN_MULTISIG environment variable for non-local network');
    }
    if (!feeRecipient || isZeroAddress(feeRecipient)) {
      throw new Error('Missing FEE_RECIPIENT environment variable for non-local network');
    }
  }

  return {
    token: {
      name: tokenName,
      symbol: tokenSymbol,
      initialSupply: tokenSupply,
    },
    safe: {
      owners: safeOwners,
      threshold: safeThreshold,
    },
    timelock: {
      minDelaySec: timelockMinDelaySec,
    },
    governor: {
      votingDelayBlocks,
      votingPeriodBlocks,
      proposalThreshold,
      absoluteQuorum,
      initialNonCirculatingAddresses: initialNonCirculatingAddresses.length > 0 ? initialNonCirculatingAddresses : undefined,
    },
    guardian: {
      multisig: guardianMultisig,
    },
    feeRecipient,
    initialGovTokenMints,
  };
}

/**
 * Validate governance configuration
 *
 * @param config Governance configuration to validate
 * @param hre Optional HardhatRuntimeEnvironment to check if local network
 * @throws Error if configuration is invalid
 */
export function validateGovConfig(config: GovDeployConfig, hre?: HardhatRuntimeEnvironment): void {
  const isLocal = hre ? isLocalNetwork(hre) : false;

  // Validate token
  if (!config.token.name || !config.token.symbol) {
    throw new Error('Token name and symbol are required');
  }
  if (!config.token.initialSupply) {
    throw new Error('Token initial supply is required');
  }
  // Validate initialSupply is a valid BigInt string
  try {
    const supply = BigInt(config.token.initialSupply);
    if (supply === 0n) {
      throw new Error('Token initial supply must be greater than 0');
    }
  } catch (error) {
    throw new Error(
      `Invalid token initial supply: "${config.token.initialSupply}" is not a valid BigInt string. ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  // Validate Safe (allow empty for local development)
  if (config.safe.owners.length === 0 && !isLocal) {
    throw new Error('At least one Safe owner is required for non-local networks');
  }
  if (config.safe.owners.length > 0) {
    if (!Number.isInteger(config.safe.threshold) || isNaN(config.safe.threshold)) {
      throw new Error(`Safe threshold must be a valid integer, got: ${config.safe.threshold}`);
    }
    if (config.safe.threshold < 1 || config.safe.threshold > config.safe.owners.length) {
      throw new Error(
        `Safe threshold (${config.safe.threshold}) must be between 1 and number of owners (${config.safe.owners.length})`,
      );
    }
  }

  // Validate timelock
  if (!Number.isInteger(config.timelock.minDelaySec) || isNaN(config.timelock.minDelaySec)) {
    throw new Error(
      `Timelock min delay must be a valid integer, got: ${config.timelock.minDelaySec}`,
    );
  }
  if (config.timelock.minDelaySec < 0) {
    throw new Error('Timelock min delay must be non-negative');
  }

  // Validate governor
  if (!Number.isInteger(config.governor.votingDelayBlocks) || isNaN(config.governor.votingDelayBlocks)) {
    throw new Error(
      `Voting delay must be a valid integer, got: ${config.governor.votingDelayBlocks}`,
    );
  }
  if (config.governor.votingDelayBlocks < 0) {
    throw new Error('Voting delay must be non-negative');
  }
  if (
    !Number.isInteger(config.governor.votingPeriodBlocks) ||
    isNaN(config.governor.votingPeriodBlocks)
  ) {
    throw new Error(
      `Voting period must be a valid integer, got: ${config.governor.votingPeriodBlocks}`,
    );
  }
  if (config.governor.votingPeriodBlocks <= 0) {
    throw new Error('Voting period must be greater than 0');
  }
  // Validate absolute quorum (must be a valid BigInt string)
  try {
    const quorumBigInt = BigInt(config.governor.absoluteQuorum);
    if (quorumBigInt === 0n) {
      throw new Error(`Absolute quorum must be greater than 0, got: ${config.governor.absoluteQuorum}`);
    }
  } catch (error: any) {
    throw new Error(`Invalid absolute quorum format: ${config.governor.absoluteQuorum}. ${error.message}`);
  }

  // Validate addresses (format + checksum)
  for (const owner of config.safe.owners) {
    try {
      validateAddress(owner, 'Safe owner', false);
    } catch (error) {
      throw new Error(
        error instanceof Error ? error.message : `Invalid Safe owner address: ${owner}`,
      );
    }
  }
  if (config.guardian.multisig) {
    try {
      validateAddress(config.guardian.multisig, 'Guardian multisig', false);
    } catch (error) {
      throw new Error(
        error instanceof Error
          ? error.message
          : `Invalid guardian multisig address: ${config.guardian.multisig}`,
      );
    }
  }
  if (config.feeRecipient) {
    try {
      validateAddress(config.feeRecipient, 'Fee recipient', false);
    } catch (error) {
      throw new Error(
        error instanceof Error
          ? error.message
          : `Invalid fee recipient address: ${config.feeRecipient}`,
      );
    }
  }
}
