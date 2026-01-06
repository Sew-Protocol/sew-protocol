/**
 * Governance Configuration
 * 
 * TypeScript configuration for governance contracts.
 * This file provides type-safe access to governance configuration.
 */

export const GOVERNANCE_CONFIG = {
  token: {
    name: process.env.GOVERNANCE_TOKEN_NAME || "Sew Token",
    symbol: process.env.GOVERNANCE_TOKEN_SYMBOL || "$EW",
    initialSupply: process.env.GOVERNANCE_TOKEN_SUPPLY || "1000000000000000000000000000", // 1B tokens
  },
  safe: {
    owners: [
      process.env.SAFE_OWNER_1!,
      process.env.SAFE_OWNER_2!,
      process.env.SAFE_OWNER_3!,
      process.env.SAFE_OWNER_4!,
      process.env.SAFE_OWNER_5!,
    ].filter((addr): addr is string => !!addr && addr !== "0x0000000000000000000000000000000000000000"),
    threshold: parseInt(process.env.SAFE_THRESHOLD || "3"),
  },
  timelock: {
    minDelay: parseInt(process.env.TIMELOCK_DELAY || "172800"), // 48 hours (2 days)
  },
  governor: {
    votingDelay: parseInt(process.env.VOTING_DELAY || "1"), // blocks
    votingPeriod: parseInt(process.env.VOTING_PERIOD || "45818"), // blocks (~1 week)
    proposalThreshold: process.env.PROPOSAL_THRESHOLD || "10000000000000000000000000", // 10M tokens (1% of supply)
    quorumBps: parseInt(process.env.QUORUM_BPS || "400"), // 4%
  },
  guardian: {
    multisig: process.env.GUARDIAN_MULTISIG || "",
  },
  feeRecipient: process.env.FEE_RECIPIENT || "",
} as const;

/**
 * Validate that required configuration is present
 */
export function validateConfig(): void {
  const errors: string[] = [];

  if (!GOVERNANCE_CONFIG.token.name) {
    errors.push("GOVERNANCE_TOKEN_NAME is required");
  }
  if (!GOVERNANCE_CONFIG.token.symbol) {
    errors.push("GOVERNANCE_TOKEN_SYMBOL is required");
  }
  if (!GOVERNANCE_CONFIG.token.initialSupply || BigInt(GOVERNANCE_CONFIG.token.initialSupply) === 0n) {
    errors.push("GOVERNANCE_TOKEN_SUPPLY must be greater than 0");
  }

  if (GOVERNANCE_CONFIG.safe.owners.length === 0) {
    errors.push("At least one SAFE_OWNER_* is required");
  }
  if (GOVERNANCE_CONFIG.safe.threshold < 1 || GOVERNANCE_CONFIG.safe.threshold > GOVERNANCE_CONFIG.safe.owners.length) {
    errors.push(
      `SAFE_THRESHOLD (${GOVERNANCE_CONFIG.safe.threshold}) must be between 1 and number of owners (${GOVERNANCE_CONFIG.safe.owners.length})`
    );
  }

  if (GOVERNANCE_CONFIG.timelock.minDelay < 0) {
    errors.push("TIMELOCK_DELAY must be non-negative");
  }

  if (GOVERNANCE_CONFIG.governor.votingDelay < 0) {
    errors.push("VOTING_DELAY must be non-negative");
  }
  if (GOVERNANCE_CONFIG.governor.votingPeriod <= 0) {
    errors.push("VOTING_PERIOD must be greater than 0");
  }
  if (GOVERNANCE_CONFIG.governor.quorumBps < 0 || GOVERNANCE_CONFIG.governor.quorumBps > 10000) {
    errors.push("QUORUM_BPS must be between 0 and 10000");
  }

  if (errors.length > 0) {
    throw new Error(`Configuration validation failed:\n${errors.join("\n")}`);
  }
}




