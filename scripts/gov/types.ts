/**
 * Governance Proposal Types
 * 
 * Type definitions for proposal artifacts, payloads, and execution data.
 */

import { HardhatRuntimeEnvironment } from "hardhat/types";

/**
 * Proposal artifact structure stored in governance/proposals/
 */
export interface ProposalArtifact {
  /** Unique proposal identifier (e.g., "0001_set_token_cap") */
  id: string;
  
  /** Human-readable title */
  title: string;
  
  /** Detailed description (markdown supported) */
  description: string;
  
  /** Governance lane: "emergency" | "standard" | "slow" */
  lane: "emergency" | "standard" | "slow";
  
  /** Target contracts and function calls */
  calls: ProposalCall[];
  
  /** Metadata */
  metadata: {
    /** Author of the proposal */
    author: string;
    
    /** Date created (ISO 8601) */
    created: string;
    
    /** Network this proposal is for */
    network: string;
    
    /** Related issues/PRs */
    references?: string[];
  };
  
  /** Execution status */
  status?: {
    /** Proposal ID (from Governor) */
    proposalId?: string;
    
    /** Transaction hash when proposed */
    proposeTx?: string;
    
    /** Transaction hash when queued */
    queueTx?: string;
    
    /** Transaction hash when executed */
    executeTx?: string;
    
    /** Current state */
    state?: "pending" | "active" | "succeeded" | "queued" | "executed" | "canceled";
    
    /** Timestamps */
    proposedAt?: string;
    queuedAt?: string;
    executedAt?: string;
  };
}

/**
 * Individual function call in a proposal
 */
export interface ProposalCall {
  /** Target contract address */
  target: string;
  
  /** Contract name (for readability) */
  contractName?: string;
  
  /** Function name */
  functionName: string;
  
  /** Function arguments */
  args: any[];
  
  /** ETH value to send (in wei) */
  value?: string;
  
  /** Human-readable description of this call */
  description?: string;
}

/**
 * Payload builder function signature
 */
export type PayloadBuilder = (
  hre: HardhatRuntimeEnvironment,
  config?: any
) => Promise<ProposalCall[]>;

/**
 * Proposal execution result
 */
export interface ExecutionResult {
  /** Success status */
  success: boolean;
  
  /** Transaction hash */
  txHash?: string;
  
  /** Error message if failed */
  error?: string;
  
  /** Gas used */
  gasUsed?: bigint;
  
  /** Block number */
  blockNumber?: number;
}



