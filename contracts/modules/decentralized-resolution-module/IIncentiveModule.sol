// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './DecentralizedResolverStructs.sol';

/**
 * @title IIncentiveModule
 * @notice Interface for swappable incentive modules in decentralized resolution system
 * @dev Defines the contract between DecentralizedResolutionModule and incentive logic
 *      - V1: Performance-based workload routing (no appeal bonds)
 *      - V2: Appeal bonds + escalation cost curves (no resolver staking)
 *      - V3: Resolver staking, slashing, delegation (future)
 */
interface IIncentiveModule {
    // ============ Core Lifecycle Hooks ============

    /**
     * @notice Called when a dispute is opened
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param token Token address for escrow
     * @param amount Escrow amount
     * @param escrowFee Fee collected from escrow
     * @param round Current round (0=initial)
     */
    function onDisputeOpened(
        uint256 workflowId,
        address escrowContract,
        address token,
        uint256 amount,
        uint256 escrowFee,
        uint8 round
    ) external;

    /**
     * @notice Called when a resolver is assigned to a dispute
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param resolver Address of assigned resolver
     * @param round Current round
     */
    function onResolverAssigned(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint8 round
    ) external;

    /**
     * @notice Called when a resolver submits a decision
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param resolver Address of resolver
     * @param round Current round
     * @param decision Resolution outcome
     * @param responseTime Time taken to resolve (seconds)
     */
    function onDecisionSubmitted(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint8 round,
        ResolutionOutcome decision,
        uint256 responseTime
    ) external;

    /**
     * @notice Called when a dispute is escalated to the next round
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param fromRound Previous round
     * @param toRound Next round
     * @param escalatedBy Address that initiated escalation
     */
    function onEscalated(
        uint256 workflowId,
        address escrowContract,
        uint8 fromRound,
        uint8 toRound,
        address escalatedBy
    ) external;

    /**
     * @notice Called when a dispute is finalized (no more appeals)
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param finalRound Final round that decided the outcome
     * @param finalDecision Final resolution outcome
     */
    function onDisputeFinalized(
        uint256 workflowId,
        address escrowContract,
        uint8 finalRound,
        ResolutionOutcome finalDecision
    ) external;

    /**
     * @notice Called when a resolver times out
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param resolver Address of resolver that timed out
     * @param round Round where timeout occurred
     * @param timeoutType Type of timeout (accept=0, resolve=1)
     */
    function onResolverTimeout(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint8 round,
        uint8 timeoutType
    ) external;

    // ============ Payment Distribution ============

    /**
     * @notice Calculate and distribute resolver payments for a finalized dispute
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param token Token address for payment
     * @param totalFees Total fees available for distribution
     */
    function distributePayments(
        uint256 workflowId,
        address escrowContract,
        address token,
        uint256 totalFees
    ) external;

    /**
     * @notice Get claimable payment for a resolver
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param resolver Resolver address
     * @return amount Claimable amount
     */
    function getClaimablePayment(
        uint256 workflowId,
        address escrowContract,
        address resolver
    ) external view returns (uint256 amount);

    // ============ V2+ Functions (optional in V1) ============

    /**
     * @notice Check if module supports a specific feature
     * @param featureId Feature identifier (bytes4 keccak256 hash)
     * @return supported Whether the feature is supported
     * @dev Feature IDs (defined as constants in implementations):
     *      - FEATURE_APPEAL_BONDS = bytes4(keccak256("APPEAL_BONDS_V1"))
     *        Indicates module supports appeal bonds for escalation
     *      - FEATURE_PULL_ERC20_BONDS = bytes4(keccak256("PULL_ERC20_BONDS_V1"))
     *        Indicates module uses pull-based pattern for ERC20 bonds (safeTransferFrom)
     * @dev V1 implementations should return false for all features
     * @dev V2+ implementations should return true for supported features
     */
    function supportsFeature(bytes4 featureId) external view returns (bool supported);

    /**
     * @notice Get required appeal bond for escalation (V2+)
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param fromRound Current round
     * @param toRound Next round
     * @return bondAmount Required bond amount
     * @return token Token address for bond
     * @dev V1 implementations should return (0, address(0))
     */
    function getRequiredAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 fromRound,
        uint8 toRound
    ) external view returns (uint256 bondAmount, address token);

    /**
     * @notice Record appeal bond payment (V2+)
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param depositor Address that deposited bond (for ERC20: escrow contract, for ETH: user/escalator)
     * @param escalatedBy Address that initiated the escalation (always the user/escalator)
     * @param amount Bond amount
     * @param token Token address (address(0) = ETH)
     * @param round Round being appealed to
     * @dev V1 implementations should revert
     * @dev SHOULD only be callable by the escrow contract or resolution module (enforced by implementation)
     * @dev For ETH bonds (token == address(0)): MUST be payable and require(msg.value == amount)
     *      For ETH bonds, depositor MUST equal escalatedBy (user-funded)
     * @dev For ERC20 bonds: Implementation MUST pull tokens via safeTransferFrom(depositor, address(this), amount)
     *      and MUST revert on transfer failure. Depositor is typically the escrow contract (escrow-funded),
     *      but escalatedBy tracks the actual escalator for metrics/accounting.
     */
    function recordAppealBond(
        uint256 workflowId,
        address escrowContract,
        address depositor,
        address escalatedBy,
        uint256 amount,
        address token,
        uint8 round
    ) external payable;

    /**
     * @notice Distribute appeal bond based on outcome (V2+)
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param round Round that was appealed
     * @param outcomeFlipped Whether the appeal succeeded
     * @dev V1 implementations should revert
     */
    function distributeAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 round,
        bool outcomeFlipped
    ) external;
}