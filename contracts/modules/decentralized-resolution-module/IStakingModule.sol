// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

/**
 * @title IStakingModule
 * @notice Interface for DR v3 resolver staking module
 * @dev Defines the contract for resolver capital at risk
 *      This is the final phase: "Decentralise decisions first, decentralise incentives second, decentralise capital last."
 *
 *      Key Features:
 *      - ERC20 stake token support
 *      - Minimum stake requirements per resolver tier
 *      - Time-locked withdrawals (prevent instant exit after bad decisions)
 *      - Delegation support (senior resolvers back standard resolvers)
 *      - Stake utilization tracking (available vs at-risk)
 */
interface IStakingModule {
    // ============ Enums ============

    enum StakeStatus {
        ACTIVE, // Stake is active and can be used
        LOCKED, // Stake is locked (post-decision, during appeal, etc.)
        UNSTAKING, // Unstake initiated, waiting for time-lock
        SLASHED // Stake has been slashed (tracking purposes)
    }

    // ============ Structs ============

    struct StakeInfo {
        uint256 totalStake; // Total stake deposited by resolver
        uint256 availableStake; // Stake not currently at risk
        uint256 lockedStake; // Stake locked in active disputes
        uint256 delegatedFrom; // Stake delegated from others (seniors backing this resolver)
        uint256 delegatedTo; // Stake this resolver delegated to others
        uint256 slashedAmount; // Cumulative slashed amount (historical)
        uint256 unstakeRequestedAt; // Timestamp of unstake request (0 if none)
        uint256 unstakeAmount; // Amount requested for unstake
        StakeStatus status; // Current stake status
    }

    struct DelegationInfo {
        address delegator; // Who is delegating
        address delegatee; // Who receives delegation
        uint256 amount; // Amount delegated
        uint256 delegatedAt; // Timestamp of delegation
        bool active; // Whether delegation is active
    }

    // ============ Events ============

    event StakeDeposited(address indexed resolver, uint256 amount, uint256 newTotal);
    event StakeWithdrawn(address indexed resolver, uint256 amount, uint256 remaining);
    event UnstakeRequested(address indexed resolver, uint256 amount, uint256 availableAt);
    event UnstakeCancelled(address indexed resolver, uint256 amount);

    event StakeDelegated(address indexed delegator, address indexed delegatee, uint256 amount);
    event StakeUndelegated(address indexed delegator, address indexed delegatee, uint256 amount);

    event StakeLocked(
        address indexed resolver,
        uint256 amount,
        uint256 indexed workflowId,
        string reason
    );
    event StakeUnlocked(address indexed resolver, uint256 amount, uint256 indexed workflowId);

    event StakeSlashed(
        address indexed resolver,
        uint256 amount,
        uint256 indexed workflowId,
        string reason
    );
    event StakeRestored(
        address indexed resolver,
        uint256 amount,
        uint256 indexed workflowId,
        string reason
    );

    event MinimumStakeUpdated(uint8 resolverTier, uint256 oldMinimum, uint256 newMinimum);
    event StakeTokenUpdated(address indexed oldToken, address indexed newToken);
    event UnstakePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    event EmergencyPaused(address indexed by, string reason);
    event EmergencyUnpaused(address indexed by);
    event EmergencyWithdrawal(address indexed resolver, uint256 amount, address indexed to);

    // ============ Core Staking Functions ============

    /**
     * @notice Deposit stake tokens to become/remain a resolver
     * @param amount Amount of stake tokens to deposit
     */
    function stake(uint256 amount) external;

    /**
     * @notice Request to unstake tokens (initiates time-lock period)
     * @param amount Amount to unstake
     */
    function requestUnstake(uint256 amount) external;

    /**
     * @notice Cancel an unstake request
     */
    function cancelUnstake() external;

    /**
     * @notice Complete unstake after time-lock period has passed
     */
    function completeUnstake() external;

    /**
     * @notice Emergency withdraw (only when paused, may incur penalty)
     * @param to Address to send stake to
     */
    function emergencyWithdraw(address to) external;

    // ============ Delegation Functions ============

    /**
     * @notice Delegate stake to another resolver (senior backs standard resolver)
     * @param resolver Address to delegate to
     * @param amount Amount to delegate
     */
    function delegateStake(address resolver, uint256 amount) external;

    /**
     * @notice Undelegate stake from a resolver
     * @param resolver Address to undelegate from
     * @param amount Amount to undelegate
     */
    function undelegateStake(address resolver, uint256 amount) external;

    // ============ Lifecycle Hooks (called by DecentralizedResolutionModule) ============

    /**
     * @notice Called when a resolver is assigned to a dispute
     * @param workflowId Escrow transfer ID (escrowId) for the disputed escrow
     * @param escrowContract Address of the vault
     * @param resolver Resolver address
     * @param stakeRequired Amount of stake required for this dispute
     */
    function onResolverAssigned(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint256 stakeRequired
    ) external;

    /**
     * @notice Called when a resolver's decision is finalized
     * @param workflowId Escrow transfer ID (escrowId) for the disputed escrow
     * @param escrowContract Address of the vault
     * @param resolver Resolver address
     * @param outcome Was the decision upheld (true) or reversed (false)
     */
    function onResolutionFinalized(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        bool outcome
    ) external;

    /**
     * @notice Called when a dispute is escalated (unlock stake from prior round)
     * @param workflowId Escrow transfer ID (escrowId) for the disputed escrow
     * @param escrowContract Address of the vault
     * @param resolver Resolver from prior round
     */
    function onDisputeEscalated(uint256 workflowId, address escrowContract, address resolver) external;

    /**
     * @notice Called when stake needs to be locked (e.g., during appeal period)
     * @param workflowId Escrow transfer ID (escrowId) for the disputed escrow
     * @param escrowContract Address of the vault
     * @param resolver Resolver address
     * @param amount Amount to lock
     * @param duration How long to lock (0 = until manually unlocked)
     */
    function lockStake(
        uint256 workflowId,
        address escrowContract,
        address resolver,
        uint256 amount,
        uint256 duration
    ) external;

    /**
     * @notice Called when stake should be unlocked
     * @param workflowId Escrow transfer ID (escrowId) for the disputed escrow
     * @param escrowContract Address of the vault
     * @param resolver Resolver address
     */
    function unlockStake(uint256 workflowId, address escrowContract, address resolver) external;

    /**
     * @notice Credit resolver's stake on vindication (protocol-backed liability, no token transfer)
     * @dev Called by slashing module when a reversal slash is restored on vindication.
     *      Increases the resolver's bond amounts proportionally to restore economic capacity.
     *      No actual tokens are transferred — this represents a protocol liability.
     * @param resolver Resolver to credit
     * @param amount Amount to credit (in USD, 18 decimals)
     */
    function creditStakeForVindication(address resolver, uint256 amount) external;

    // ============ Query Functions ============

    /**
     * @notice Get stake information for a resolver
     * @param resolver Resolver address
     * @return info Stake information struct
     */
    function getStakeInfo(address resolver) external view returns (StakeInfo memory info);

    /**
     * @notice Check if resolver has sufficient stake for assignment
     * @param resolver Resolver address
     * @param required Required stake amount
     * @return sufficient Whether resolver has enough stake
     */
    function isStakeSufficient(
        address resolver,
        uint256 required
    ) external view returns (bool sufficient);

    /**
     * @notice Get available stake (not locked or delegated)
     * @param resolver Resolver address
     * @return available Available stake amount
     */
    function getAvailableStake(address resolver) external view returns (uint256 available);

    /**
     * @notice Get total effective stake (own + delegated from others)
     * @param resolver Resolver address
     * @return effective Effective stake amount
     */
    function getEffectiveStake(address resolver) external view returns (uint256 effective);

    /**
     * @notice Get delegation information
     * @param delegator Who is delegating
     * @param delegatee Who receives delegation
     * @return info Delegation information
     */
    function getDelegationInfo(
        address delegator,
        address delegatee
    ) external view returns (DelegationInfo memory info);

    /**
     * @notice Get active delegation for a delegator (if any)
     * @param delegator Who is delegating
     * @return info Active delegation information, or inactive with zero delegatee
     */
    function getActiveDelegation(address delegator) external view returns (DelegationInfo memory info);

    /**
     * @notice Get minimum stake required for a resolver tier
     * @param tier Resolver tier (0 = standard, 1 = senior)
     * @return minimum Minimum stake required
     */
    function getMinimumStake(uint8 tier) external view returns (uint256 minimum);

    /**
     * @notice Get stake token address
     * @return token Stake token address
     */
    function getStakeToken() external view returns (address token);

    /**
     * @notice Check if staking is paused
     * @return paused Whether staking is paused
     */
    function isPaused() external view returns (bool paused);

    // ============ Admin Functions (Governance) ============

    /**
     * @notice Set minimum stake for a resolver tier
     * @param tier Resolver tier (0 = standard, 1 = senior)
     * @param minimum New minimum stake
     */
    function setMinimumStake(uint8 tier, uint256 minimum) external;

    /**
     * @notice Set unstake time-lock period
     * @param period New time-lock period in seconds
     */
    function setUnstakePeriod(uint256 period) external;

    /**
     * @notice Pause staking operations (emergency)
     * @param reason Reason for pause
     */
    function pause(string memory reason) external;

    /**
     * @notice Unpause staking operations
     */
    function unpause() external;

    /**
     * @notice Get max escrow value this resolver can handle based on stake
     * @param resolver Resolver address
     * @return maxEscrow Maximum escrow value (18 decimals)
     */
    function getMaxEscrowPerCase(address resolver) external view returns (uint256 maxEscrow);
}