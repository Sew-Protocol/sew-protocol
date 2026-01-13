// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

/**
 * @title ISlashingModule
 * @notice Interface for DR v3 resolver slashing module
 * @dev Defines the contract for penalizing resolvers who misbehave
 *      
 *      Key Features:
 *      - Graduated penalties (timeout < reversal < fraud)
 *      - Slashing appeals process
 *      - Slash distribution (protocol, counter-party, insurance pool)
 *      - Circuit breakers (max slash per period)
 *      - Fraud proof verification
 */
interface ISlashingModule {
    
    // ============ Enums ============
    
    enum SlashReason {
        TIMEOUT_ACCEPT,      // Failed to accept assignment
        TIMEOUT_RESOLVE,     // Failed to resolve on time
        REVERSAL,            // Decision reversed on escalation
        FRAUD,               // Provable malicious behavior
        COLLUSION,           // Coordination with other resolvers
        BRIBERY             // Accepted bribe to manipulate outcome
    }
    
    enum SlashStatus {
        PENDING,             // Slash proposed, can be appealed
        APPEALED,            // Under appeal review
        EXECUTED,            // Slash executed
        REVERSED             // Slash reversed after successful appeal
    }
    
    // ============ Structs ============
    
    struct SlashEvent {
        uint256 slashId;              // Unique slash ID
        uint256 workflowId;           // Related dispute ID
        address resolver;             // Resolver being slashed
        SlashReason reason;           // Reason for slash
        uint256 amount;               // Amount slashed
        uint256 proposedAt;           // Timestamp slash was proposed
        uint256 executedAt;           // Timestamp slash was executed (0 if not executed)
        uint256 appealDeadline;       // Deadline to appeal
        SlashStatus status;           // Current status
        address proposer;             // Who proposed the slash
        bytes evidence;               // Evidence for slash (fraud proofs, etc.)
    }
    
    struct SlashAppeal {
        uint256 slashId;              // Slash being appealed
        address appellant;            // Who is appealing
        uint256 appealBond;           // Bond posted for appeal
        uint256 appealedAt;           // Timestamp of appeal
        string reason;                // Appeal reason
        bytes evidence;               // Counter-evidence
        bool resolved;                // Whether appeal is resolved
        bool upheld;                  // Whether appeal was upheld (slash reversed)
    }
    
    struct SlashConfig {
        uint256 timeoutSlashBps;      // Slash % for timeout (basis points)
        uint256 reversalSlashBps;     // Slash % for reversal
        uint256 fraudSlashBps;        // Slash % for fraud
        uint256 maxSlashPerPeriod;    // Max slash per resolver per period
        uint256 slashPeriod;          // Period for max slash calculation
        uint256 appealWindow;         // Time to appeal (seconds)
        uint256 appealBond;           // Bond required to appeal
    }
    
    struct SlashDistribution {
        uint256 toProtocol;           // Amount to protocol treasury
        uint256 toCounterParty;       // Amount to harmed party
        uint256 toInsurancePool;      // Amount to insurance pool
        uint256 toSlashProposer;      // Reward for slash proposer (fraud cases)
    }
    
    // ============ Events ============
    
    event SlashProposed(
        uint256 indexed slashId,
        uint256 indexed workflowId,
        address indexed resolver,
        SlashReason reason,
        uint256 amount,
        address proposer
    );
    
    event SlashExecuted(
        uint256 indexed slashId,
        address indexed resolver,
        uint256 amount,
        SlashDistribution distribution
    );
    
    event SlashAppealed(
        uint256 indexed slashId,
        address indexed appellant,
        uint256 appealBond,
        string reason
    );
    
    event SlashAppealResolved(
        uint256 indexed slashId,
        bool upheld,
        address indexed resolver,
        uint256 bondReturned
    );
    
    event SlashReversed(
        uint256 indexed slashId,
        address indexed resolver,
        uint256 amountRestored
    );
    
    event SlashConfigUpdated(
        SlashReason reason,
        uint256 oldBps,
        uint256 newBps
    );
    
    event CircuitBreakerTriggered(
        address indexed resolver,
        uint256 totalSlashed,
        uint256 period,
        string reason
    );
    
    event InsurancePoolFunded(uint256 amount, uint256 newBalance);
    event InsurancePoolPayout(address indexed to, uint256 amount, uint256 workflowId);
    
    // ============ Core Slashing Functions ============
    
    /**
     * @notice Propose a slash for a resolver
     * @param workflowId Related dispute ID
     * @param resolver Resolver to slash
     * @param reason Reason for slash
     * @param evidence Evidence supporting slash (fraud proofs, etc.)
     * @return slashId Unique ID for this slash
     */
    function proposeSlash(
        uint256 workflowId,
        address resolver,
        SlashReason reason,
        bytes calldata evidence
    ) external returns (uint256 slashId);
    
    /**
     * @notice Execute a slash after appeal period
     * @param slashId Slash ID to execute
     */
    function executeSlash(uint256 slashId) external;
    
    /**
     * @notice Appeal a slash
     * @param slashId Slash ID to appeal
     * @param reason Appeal reason
     * @param evidence Counter-evidence
     */
    function appealSlash(
        uint256 slashId,
        string calldata reason,
        bytes calldata evidence
    ) external;
    
    /**
     * @notice Resolve a slash appeal (governance/senior resolver)
     * @param slashId Slash ID
     * @param upheld Whether to uphold the appeal (true = reverse slash)
     */
    function resolveAppeal(uint256 slashId, bool upheld) external;
    
    // ============ Automated Slashing (called by DecentralizedResolutionModule) ============
    
    /**
     * @notice Automatically slash for timeout
     * @param workflowId Dispute ID
     * @param resolver Resolver who timed out
     * @param timeoutType Type of timeout (accept vs resolve)
     */
    function slashForTimeout(
        uint256 workflowId,
        address resolver,
        uint8 timeoutType
    ) external returns (uint256 slashId);
    
    /**
     * @notice Automatically slash for reversal
     * @param workflowId Dispute ID
     * @param resolver Resolver whose decision was reversed
     * @param priorRound Round at which decision was made
     */
    function slashForReversal(
        uint256 workflowId,
        address resolver,
        uint8 priorRound
    ) external returns (uint256 slashId);
    
    /**
     * @notice Slash for proven fraud
     * @param workflowId Dispute ID (may be 0 for off-chain fraud)
     * @param resolver Resolver who committed fraud
     * @param evidence Fraud proof
     */
    function slashForFraud(
        uint256 workflowId,
        address resolver,
        bytes calldata evidence
    ) external returns (uint256 slashId);
    
    // ============ Query Functions ============
    
    /**
     * @notice Get slash event information
     * @param slashId Slash ID
     * @return slashEvent Slash event struct
     */
    function getSlashEvent(uint256 slashId) external view returns (SlashEvent memory slashEvent);
    
    /**
     * @notice Get slash appeal information
     * @param slashId Slash ID
     * @return appeal Slash appeal struct
     */
    function getSlashAppeal(uint256 slashId) external view returns (SlashAppeal memory appeal);
    
    /**
     * @notice Calculate slash amount for a resolver/reason
     * @param resolver Resolver address
     * @param reason Slash reason
     * @return amount Slash amount
     */
    function calculateSlashAmount(address resolver, SlashReason reason) 
        external 
        view 
        returns (uint256 amount);
    
    /**
     * @notice Get slashable stake (respects circuit breakers)
     * @param resolver Resolver address
     * @return slashable Amount that can be slashed
     */
    function getSlashableStake(address resolver) external view returns (uint256 slashable);
    
    /**
     * @notice Get total slashed for resolver in current period
     * @param resolver Resolver address
     * @return slashed Total slashed in period
     */
    function getSlashedInPeriod(address resolver) external view returns (uint256 slashed);
    
    /**
     * @notice Get slash configuration
     * @return config Slash configuration struct
     */
    function getSlashConfig() external view returns (SlashConfig memory config);
    
    /**
     * @notice Check if slash can be appealed
     * @param slashId Slash ID
     * @return canAppeal Whether slash can be appealed
     */
    function canAppeal(uint256 slashId) external view returns (bool canAppeal);
    
    /**
     * @notice Check if slash can be executed
     * @param slashId Slash ID
     * @return canExecute Whether slash can be executed
     */
    function canExecute(uint256 slashId) external view returns (bool canExecute);
    
    /**
     * @notice Get insurance pool balance
     * @return balance Insurance pool balance
     */
    function getInsurancePoolBalance() external view returns (uint256 balance);
    
    // ============ Distribution Functions ============
    
    /**
     * @notice Calculate slash distribution
     * @param amount Total slash amount
     * @param reason Slash reason
     * @return distribution Distribution struct
     */
    function calculateDistribution(uint256 amount, SlashReason reason) 
        external 
        view 
        returns (SlashDistribution memory distribution);
    
    /**
     * @notice Claim insurance payout (for users harmed by resolver misbehavior)
     * @param workflowId Dispute ID
     * @param to Address to send payout
     * @param amount Amount to claim
     */
    function claimInsurancePayout(
        uint256 workflowId,
        address to,
        uint256 amount
    ) external;
    
    // ============ Admin Functions (Governance) ============
    
    /**
     * @notice Update slash percentage for a reason
     * @param reason Slash reason
     * @param bps New slash percentage (basis points)
     */
    function setSlashPercentage(SlashReason reason, uint256 bps) external;
    
    /**
     * @notice Set max slash per period
     * @param max Maximum slash amount
     * @param period Period in seconds
     */
    function setMaxSlashPerPeriod(uint256 max, uint256 period) external;
    
    /**
     * @notice Set appeal window duration
     * @param window Appeal window in seconds
     */
    function setAppealWindow(uint256 window) external;
    
    /**
     * @notice Set appeal bond amount
     * @param bond Bond amount required to appeal
     */
    function setAppealBond(uint256 bond) external;
    
    /**
     * @notice Fund insurance pool
     * @param amount Amount to add to pool
     */
    function fundInsurancePool(uint256 amount) external;
    
    /**
     * @notice Trigger circuit breaker (emergency pause)
     * @param reason Reason for trigger
     */
    function triggerCircuitBreaker(string memory reason) external;
    
    /**
     * @notice Reset circuit breaker
     */
    function resetCircuitBreaker() external;
}
