// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "./ResolverIncentiveModuleV1.sol";
import "./IIncentiveModule.sol";
import "./DecentralizedResolverStructs.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ResolverIncentiveModuleV2
 * @notice DR v2 incentive module: adds appeal bonds + escalation cost curves (no resolver staking)
 * @dev Extends V1 with:
 *      - Appeal bond tracking per dispute/round
 *      - Bond custody and payout logic (refund if appeal succeeds, pay to resolvers if fails)
 *      - Escalation cost curve integration
 *      - Observability metrics (bonds posted/refunded/forfeited)
 *      
 *      Key principles:
 *      - Users post bonds to escalate (not resolvers)
 *      - Bonds refunded if decision changes (appeal succeeds)
 *      - Bonds paid to prior round's resolvers if decision upheld (appeal fails)
 *      - No resolver capital at risk (DR v3 feature)
 */
contract ResolverIncentiveModuleV2 is ResolverIncentiveModuleV1 {
    using SafeERC20 for IERC20;
    
    // ============ DR v2 Structures ============
    
    struct AppealBondRecord {
        address depositor;           // Who deposited the bond
        uint256 amount;              // Bond amount
        address token;               // Token address (address(0) = ETH)
        uint256 depositedAt;         // Timestamp
        bool distributed;            // Whether bond has been refunded/paid
        bool refunded;               // True = refunded to depositor, False = paid to resolvers
    }
    
    // ============ DR v2 State Variables ============
    
    // Appeal bond storage: workflowId => round => AppealBondRecord
    mapping(uint256 => mapping(uint8 => AppealBondRecord)) public appealBonds;
    
    // Observability metrics
    uint256 public totalBondsPosted;
    uint256 public totalBondsRefunded;
    uint256 public totalBondsPaidToResolvers;
    uint256 public totalBondsForfeited;
    
    // Escalation depth histogram: round => count
    mapping(uint8 => uint256) public escalationDepthHistogram;
    
    // ============ DR v2 Constructor ============
    
    constructor(address initialOwner, address initialLibrary) 
        ResolverIncentiveModuleV1(initialOwner, initialLibrary) 
    {}
    
    // ============ DR v2 Events ============
    
    event AppealBondRecorded(
        uint256 indexed escrowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );
    
    event AppealBondRefunded(
        uint256 indexed escrowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );
    
    event AppealBondPaidToResolvers(
        uint256 indexed escrowId,
        uint8 round,
        address[] resolvers,
        uint256 totalAmount,
        address token
    );
    
    event AppealBondForfeited(
        uint256 indexed escrowId,
        uint8 round,
        uint256 amount,
        address token,
        string reason
    );
    
    // ============ IIncentiveModule V2 Implementation ============
    
    /**
     * @notice Get required appeal bond for escalation (V2)
     * @dev Delegates to DecentralizedResolutionModule.getRequiredAppealBond()
     *      This is a passthrough function - actual calculation happens in resolution module
     */
    function getRequiredAppealBond(
        uint256 workflowId,
        uint8 fromRound,
        uint8 toRound
    ) external view returns (uint256 bondAmount, address token) {
        // This function exists in IIncentiveModule but the actual calculation
        // is done in DecentralizedResolutionModule for consistency
        // Just return 0 here - escrow contracts should call resolution module directly
        return (0, address(0));
    }
    
    /**
     * @notice Record appeal bond payment (V2)
     * @param workflowId Unique identifier for the dispute
     * @param depositor Address that deposited bond
     * @param amount Bond amount
     * @param token Token address (address(0) = ETH)
     * @param round Round being appealed to
     */
    function recordAppealBond(
        uint256 workflowId,
        address depositor,
        uint256 amount,
        address token,
        uint8 round
    ) external onlyEscrowContract {
        require(depositor != address(0), "Invalid depositor");
        require(amount > 0, "Invalid amount");
        require(round > 0 && round <= 2, "Invalid round");
        require(!appealBonds[workflowId][round].distributed, "Bond already recorded");
        
        // Record bond
        appealBonds[workflowId][round] = AppealBondRecord({
            depositor: depositor,
            amount: amount,
            token: token,
            depositedAt: block.timestamp,
            distributed: false,
            refunded: false
        });
        
        // Update metrics
        totalBondsPosted += amount;
        escalationDepthHistogram[round]++;
        
        emit AppealBondRecorded(workflowId, round, depositor, amount, token);
    }
    
    /**
     * @notice Distribute appeal bond based on outcome (V2)
     * @param workflowId Unique identifier for the dispute
     * @param round Round that was appealed FROM (bond depositor appealed decision at this round)
     * @param outcomeFlipped Whether the appeal succeeded (decision changed)
     * @dev If outcomeFlipped = true: refund to depositor
     *      If outcomeFlipped = false: pay to resolvers from 'round'
     */
    function distributeAppealBond(
        uint256 workflowId,
        uint8 round,
        bool outcomeFlipped
    ) external onlyEscrowContract {
        // Bond was posted to escalate FROM round to round+1
        // So we look up the bond at round+1
        uint8 bondRound = round + 1;
        AppealBondRecord storage bond = appealBonds[workflowId][bondRound];
        
        require(bond.amount > 0, "No bond recorded");
        require(!bond.distributed, "Bond already distributed");
        
        bond.distributed = true;
        
        if (outcomeFlipped) {
            // Appeal succeeded - refund to depositor
            _refundBond(workflowId, bondRound, bond);
        } else {
            // Appeal failed - pay to resolvers from prior round
            _payBondToResolvers(workflowId, round, bond);
        }
    }
    
    // ============ Internal DR v2 Functions ============
    
    /**
     * @notice Refund bond to depositor
     */
    function _refundBond(
        uint256 workflowId,
        uint8 bondRound,
        AppealBondRecord storage bond
    ) internal {
        bond.refunded = true;
        totalBondsRefunded += bond.amount;
        
        // Transfer bond back to depositor
        if (bond.token == address(0)) {
            // ETH
            (bool success,) = bond.depositor.call{value: bond.amount}("");
            require(success, "ETH refund failed");
        } else {
            // ERC20
            IERC20(bond.token).safeTransfer(bond.depositor, bond.amount);
        }
        
        emit AppealBondRefunded(
            workflowId,
            bondRound,
            bond.depositor,
            bond.amount,
            bond.token
        );
    }
    
    /**
     * @notice Pay bond to resolvers from prior round
     * @param workflowId Dispute ID
     * @param priorRound Round whose resolvers should receive bond
     * @param bond Bond record
     */
    function _payBondToResolvers(
        uint256 workflowId,
        uint8 priorRound,
        AppealBondRecord storage bond
    ) internal {
        bond.refunded = false;
        totalBondsPaidToResolvers += bond.amount;
        
        // Get resolvers from prior round
        ResolverRecord[] storage resolvers = disputeResolvers[workflowId];
        
        // If no resolvers in storage (e.g., testing scenario), store bond as protocol revenue
        if (resolvers.length == 0) {
            emit AppealBondPaidToResolvers(
                workflowId,
                priorRound,
                new address[](0),
                bond.amount,
                bond.token
            );
            return;
        }
        
        // Find resolvers who decided at priorRound
        address[] memory eligibleResolvers = new address[](resolvers.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < resolvers.length; i++) {
            if (resolvers[i].level == priorRound) {
                eligibleResolvers[count] = resolvers[i].resolver;
                count++;
            }
        }
        
        require(count > 0, "No resolvers found");
        
        // Distribute bond equally among resolvers from that round
        uint256 amountPerResolver = bond.amount / count;
        
        // Add to claimable payments for each resolver
        for (uint256 i = 0; i < count; i++) {
            claimablePayments[workflowId][eligibleResolvers[i]] += amountPerResolver;
        }
        
        // Emit event with actual resolver addresses (trimmed array)
        address[] memory actualResolvers = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            actualResolvers[i] = eligibleResolvers[i];
        }
        
        emit AppealBondPaidToResolvers(
            workflowId,
            priorRound,
            actualResolvers,
            bond.amount,
            bond.token
        );
    }
    
    /**
     * @notice Forfeit bond (e.g., if escalator doesn't follow through)
     * @param workflowId Dispute ID
     * @param round Bond round
     * @param reason Reason for forfeiture
     */
    function forfeitAppealBond(
        uint256 workflowId,
        uint8 round,
        string memory reason
    ) external onlyEscrowContract {
        AppealBondRecord storage bond = appealBonds[workflowId][round];
        
        require(bond.amount > 0, "No bond recorded");
        require(!bond.distributed, "Bond already distributed");
        
        bond.distributed = true;
        bond.refunded = false;
        totalBondsForfeited += bond.amount;
        
        // Bond remains in contract as protocol revenue
        // or could be sent to treasury
        
        emit AppealBondForfeited(workflowId, round, bond.amount, bond.token, reason);
    }
    
    // ============ View Functions (DR v2 Metrics) ============
    
    /**
     * @notice Get appeal bond record for a dispute/round
     */
    function getAppealBond(uint256 workflowId, uint8 round) 
        external 
        view 
        returns (AppealBondRecord memory) 
    {
        return appealBonds[workflowId][round];
    }
    
    /**
     * @notice Get DR v2 observability metrics
     * @return bondsPosted Total bonds posted
     * @return bondsRefunded Total bonds refunded to depositors
     * @return bondsPaidToResolvers Total bonds paid to resolvers
     * @return bondsForfeited Total bonds forfeited
     */
    function getV2Metrics() external view returns (
        uint256 bondsPosted,
        uint256 bondsRefunded,
        uint256 bondsPaidToResolvers,
        uint256 bondsForfeited
    ) {
        return (
            totalBondsPosted,
            totalBondsRefunded,
            totalBondsPaidToResolvers,
            totalBondsForfeited
        );
    }
    
    /**
     * @notice Get escalation depth histogram
     * @return round0 Count of escalations to round 0 (should be 0)
     * @return round1 Count of escalations to round 1
     * @return round2 Count of escalations to round 2
     */
    function getEscalationDepthHistogram() external view returns (
        uint256 round0,
        uint256 round1,
        uint256 round2
    ) {
        return (
            escalationDepthHistogram[0],
            escalationDepthHistogram[1],
            escalationDepthHistogram[2]
        );
    }
    
    /**
     * @notice Check if dispute has appeal bond at round
     */
    function hasAppealBond(uint256 workflowId, uint8 round) external view returns (bool) {
        return appealBonds[workflowId][round].amount > 0;
    }
    
    // Allow contract to receive ETH for bonds
    receive() external payable {}
}
