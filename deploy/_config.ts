/**
 * Governance Deployment Configuration
 *
 * Centralized configuration for governance contracts deployment.
 * Reads from environment variables with sensible defaults for local development.
 */

import { HardhatRuntimeEnvironment } from 'hardhat/types';

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
    quorumBps: number; // basis points (e.g., 400 = 4%)
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
 * Get governance deployment configuration from environment variables
 *
 * @param hre Hardhat runtime environment
 * @returns Governance configuration object
 * @throws Error if required values are missing for non-local networks
 */
export function getGovConfig(hre: HardhatRuntimeEnvironment): GovDeployConfig {
  const chainId = hre.network.config.chainId ?? 31337;
  const isLocal = hre.network.name === 'hardhat' || chainId === 31337;

  // Token configuration
  const tokenName = process.env.GOVERNANCE_TOKEN_NAME || 'Sew Token';
  const tokenSymbol = process.env.GOVERNANCE_TOKEN_SYMBOL || '$EW';
  const tokenSupply = process.env.GOVERNANCE_TOKEN_SUPPLY || '1000000000000000000000000000'; // 1B tokens

  // Safe multisig configuration
  const safeOwners = [
    process.env.SAFE_OWNER_1,
    process.env.SAFE_OWNER_2,
    process.env.SAFE_OWNER_3,
    process.env.SAFE_OWNER_4,
    process.env.SAFE_OWNER_5,
  ].filter(
    (addr): addr is string => !!addr && addr !== '0x0000000000000000000000000000000000000000',
  );

  const safeThreshold = parseInt(process.env.SAFE_THRESHOLD || '3');

  // Validate Safe configuration
  if (!isLocal && safeOwners.length < safeThreshold) {
    throw new Error(
      `Invalid Safe configuration: ${safeOwners.length} owners but threshold is ${safeThreshold}. ` +
        `Need at least ${safeThreshold} owners.`,
    );
  }

  // Timelock configuration
  const timelockMinDelaySec = Number(process.env.TIMELOCK_DELAY || 48 * 60 * 60); // 48 hours default

  // Governor configuration
  const votingDelayBlocks = Number(process.env.VOTING_DELAY || 1);
  const votingPeriodBlocks = Number(process.env.VOTING_PERIOD || 45818); // ~1 week @ 13s/block
  const proposalThreshold = process.env.PROPOSAL_THRESHOLD || '10000000000000000000000000'; // 10M tokens
  const quorumBps = Number(process.env.QUORUM_BPS || 400); // 4%

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
    if (!guardianMultisig || guardianMultisig === '0x0000000000000000000000000000000000000000') {
      throw new Error('Missing GUARDIAN_MULTISIG environment variable for non-local network');
    }
    if (!feeRecipient || feeRecipient === '0x0000000000000000000000000000000000000000') {
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
      quorumBps,
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
  const isLocal = hre && (hre.network.name === 'hardhat' || hre.network.config.chainId === 31337);

  // Validate token
  if (!config.token.name || !config.token.symbol) {
    throw new Error('Token name and symbol are required');
  }
  if (!config.token.initialSupply || BigInt(config.token.initialSupply) === 0n) {
    throw new Error('Token initial supply must be greater than 0');
  }

  // Validate Safe (allow empty for local development)
  if (config.safe.owners.length === 0 && !isLocal) {
    throw new Error('At least one Safe owner is required for non-local networks');
  }
  if (config.safe.owners.length > 0) {
    if (config.safe.threshold < 1 || config.safe.threshold > config.safe.owners.length) {
      throw new Error(
        `Safe threshold (${config.safe.threshold}) must be between 1 and number of owners (${config.safe.owners.length})`,
      );
    }
  }

  // Validate timelock
  if (config.timelock.minDelaySec < 0) {
    throw new Error('Timelock min delay must be non-negative');
  }

  // Validate governor
  if (config.governor.votingDelayBlocks < 0) {
    throw new Error('Voting delay must be non-negative');
  }
  if (config.governor.votingPeriodBlocks <= 0) {
    throw new Error('Voting period must be greater than 0');
  }
  if (config.governor.quorumBps < 0 || config.governor.quorumBps > 10000) {
    throw new Error('Quorum must be between 0 and 10000 basis points');
  }

  // Validate addresses (basic format check)
  const addressRegex = /^0x[a-fA-F0-9]{40}$/;
  for (const owner of config.safe.owners) {
    if (!addressRegex.test(owner)) {
      throw new Error(`Invalid Safe owner address: ${owner}`);
    }
  }
  if (config.guardian.multisig && !addressRegex.test(config.guardian.multisig)) {
    throw new Error(`Invalid guardian multisig address: ${config.guardian.multisig}`);
  }
  if (config.feeRecipient && !addressRegex.test(config.feeRecipient)) {
    throw new Error(`Invalid fee recipient address: ${config.feeRecipient}`);
  }
}
