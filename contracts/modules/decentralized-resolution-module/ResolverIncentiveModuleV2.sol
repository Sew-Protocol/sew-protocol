// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './ResolverIncentiveModuleV1.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/**
 * @title ResolverIncentiveModuleV2
 * @notice DR v2 incentive module: appeal bonds + escalation cost curves
 * @dev Inherits V1 performance tracking, adds financial commitment via bonds:
 *      - Escalation requires depositing a bond (V2)
 *      - Bonds refunded if decision changes (appeal succeeds)
 *      - Bonds paid to prior round's resolvers if decision upheld (appeal fails)
 *      - No resolver capital at risk (DR v3 feature)
 */
contract ResolverIncentiveModuleV2 is ResolverIncentiveModuleV1 {
    using SafeERC20 for IERC20;

    // ============ DR v2 Structures ============

    struct AppealBondRecord {
        address depositor; // Who deposited the bond (for ERC20: escrow contract, for ETH: user)
        address escalatedBy; // Who initiated the escalation (always the user/escalator)
        uint256 amount; // Bond amount
        address token; // Token address (address(0) = ETH)
        uint256 depositedAt; // Timestamp
        bool distributed; // Whether bond has been refunded/paid
        bool refunded; // True = refunded to depositor, False = paid to resolvers
    }

    // ============ DR v2 State Variables ============

    // Appeal bond storage: escrowContract => workflowId => round => AppealBondRecord
    mapping(address => mapping(uint256 => mapping(uint8 => AppealBondRecord))) public appealBonds;

    // Pull-based bond refunds (ERC20 + ETH): escrowContract => workflowId => claimant => amount
    mapping(address => mapping(uint256 => mapping(address => uint256))) public claimableBondRefunds;

    // Observability metrics
    uint256 public totalBondsPosted;
    uint256 public totalBondsRefunded;
    uint256 public totalBondRefundsClaimed;
    uint256 public totalBondsPaidToResolvers;
    uint256 public totalBondsForfeited;

    // Escalation depth histogram: round => count
    mapping(uint8 => uint256) public escalationDepthHistogram;

    // Note: payoutToken mapping is inherited from V1

    // ============ Feature Support Constants ============
    
    /// @dev Feature ID for appeal bonds support
    bytes4 public constant FEATURE_APPEAL_BONDS = bytes4(keccak256("APPEAL_BONDS_V1"));
    
    /// @dev Feature ID for pull-based ERC20 bonds
    bytes4 public constant FEATURE_PULL_ERC20_BONDS = bytes4(keccak256("PULL_ERC20_BONDS_V1"));

    // ============ DR v2 Constructor ============

    constructor(
        address initialOwner,
        address initialLibrary
    ) ResolverIncentiveModuleV1(initialOwner, initialLibrary) {}

    // ============ DR v2 Events ============

    event AppealBondRecorded(
        uint256 indexed workflowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );

    event AppealBondRefunded(
        uint256 indexed workflowId,
        uint8 round,
        address indexed depositor,
        uint256 amount,
        address token
    );

    // Emitted when a bond refund is credited to claimableBondRefunds (pull pattern)
    event AppealBondRefundClaimable(
        uint256 indexed workflowId,
        uint8 round,
        address indexed claimant,
        uint256 amount,
        address token
    );

    event BondRefundClaimed(
        uint256 indexed workflowId,
        address indexed claimant,
        uint256 amount,
        address token
    );

    event AppealBondPaidToResolvers(
        uint256 indexed workflowId,
        uint8 round,
        address[] resolvers,
        uint256 totalAmount,
        address token
    );

    event AppealBondForfeited(
        uint256 indexed workflowId,
        uint8 round,
        uint256 amount,
        address token,
        string reason
    );

    // ============ IIncentiveModule V2 Implementation ============

    /**
     * @notice Get required appeal bond for escalation (V2)
     * @dev This function is a stub for interface compliance.
     *      The actual bond calculation is done in DecentralizedResolutionModule.
     *      Callers should use IResolutionModule.getRequiredAppealBond() instead.
     *      This function always reverts to prevent misuse.
     * @return bondAmount Always reverts - use resolution module instead
     * @return token Always reverts - use resolution module instead
     */
    function getRequiredAppealBond(
        uint256 /* workflowId */,
        address /* escrowContract */,
        uint8 /* fromRound */,
        uint8 /* toRound */
    ) external pure override returns (uint256 /* bondAmount */, address /* token */) {
        // This function exists in IIncentiveModule for interface compliance,
        // but the actual calculation is done in DecentralizedResolutionModule
        // to maintain consistency and avoid duplication.
        //
        // Escrow contracts should call IResolutionModule.getRequiredAppealBond() directly.
        revert('Use IResolutionModule.getRequiredAppealBond() instead');
    }

    /**
     * @notice Check if module supports a specific feature
     * @param featureId Feature identifier (bytes4 keccak256 hash)
     * @return supported Whether the feature is supported
     */
    function supportsFeature(bytes4 featureId) external pure override returns (bool supported) {
        return featureId == FEATURE_APPEAL_BONDS || featureId == FEATURE_PULL_ERC20_BONDS;
    }

    /**
     * @notice Record appeal bond payment (V2)
     * @param workflowId Unique identifier for the dispute
     * @param escrowContract Address of the vault
     * @param depositor Address that deposited bond (for ERC20: escrow contract, for ETH: user/escalator)
     * @param escalatedBy Address that initiated the escalation (always the user/escalator)
     * @param amount Bond amount
     * @param token Token address (address(0) = ETH)
     * @param round Round being appealed to
     * @dev For ETH bonds: MUST be payable and require(msg.value == amount)
     *      For ETH bonds, depositor MUST equal escalatedBy (user-funded)
     * @dev For ERC20 bonds: Pulls tokens via safeTransferFrom(depositor, address(this), amount)
     *      and reverts on transfer failure. Depositor is typically the escrow contract (escrow-funded),
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
    ) external payable override onlyEscrowContract {
        require(depositor != address(0), 'Invalid depositor');
        require(escalatedBy != address(0), 'Invalid escalatedBy');
        require(amount > 0, 'Invalid amount');
        require(round > 0 && round <= 2, 'Invalid round');
        require(appealBonds[escrowContract][workflowId][round].amount == 0, 'Bond already exists');
        require(!appealBonds[escrowContract][workflowId][round].distributed, 'Bond already distributed');

        // Enforce custody: pull funds atomically
        if (token == address(0)) {
            // ETH bond: require exact msg.value match
            require(msg.value == amount, 'ETH amount mismatch');
            // For ETH bonds, depositor must be the escalator (user-funded)
            require(depositor == escalatedBy, 'Depositor must be escalator for ETH bonds');
            // ETH must be sent by the caller (escrow contract) which received it from user
            // require(depositor == msg.sender, 'Depositor must be caller'); // Removed restrictive check
            // Funds are automatically received via payable
        } else {
            // ERC20 bond: pull tokens from depositor (pull-based pattern)
            // This ensures atomicity: if this call reverts, no tokens move
            // Depositor must approve this contract (the incentive module) for ERC20 bonds
            // SECURITY: Prevent arbitrary transferFrom - depositor must be caller or trusted custodian
            // Since this function is onlyEscrowContract, we trust the caller to specify the correct depositor
            // (either themselves or a trusted intermediary like BondCollector).
            
            IERC20(token).safeTransferFrom(depositor, address(this), amount);
        }

        // Enforce single payout token per dispute (CRITICAL: prevents token-mixing in claimablePayments)
        _requirePayoutToken(escrowContract, workflowId, token);

        // Record bond with actual received amount
        appealBonds[escrowContract][workflowId][round] = AppealBondRecord({
            depositor: depositor,
            escalatedBy: escalatedBy,
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
     * @param escrowContract Address of the vault
     * @param round Round that was appealed FROM (bond depositor appealed decision at this round)
     * @param outcomeFlipped Whether the appeal succeeded (decision changed)
     * @dev If outcomeFlipped = true: refund to depositor
     *      If outcomeFlipped = false: pay to resolvers from 'round'
     * @dev Protected by reentrancy guard to prevent reentrancy attacks
     */
    function distributeAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 round,
        bool outcomeFlipped
    ) external override onlyEscrowContract nonReentrant {
        // Validate round bounds
        require(round < 2, 'Invalid round - no higher round');

        // Bond was posted to escalate FROM round to round+1
        // So we look up the bond at round+1
        uint8 bondRound = round + 1;
        AppealBondRecord storage bond = appealBonds[escrowContract][workflowId][bondRound];

        require(bond.amount > 0, 'No bond recorded');
        require(!bond.distributed, 'Bond already distributed');

        bond.distributed = true;
        // Clear bond amount for gas refunds and "cannot reuse" clarity
        uint256 bondAmount = bond.amount;
        bond.amount = 0;

        if (outcomeFlipped) {
            // Appeal succeeded - refund to depositor
            _refundBond(workflowId, escrowContract, bondRound, bond, bondAmount);
        } else {
            // Appeal failed - pay to resolvers from prior round
            _payBondToResolvers(workflowId, escrowContract, round, bond, bondAmount);
        }
    }

    /**
     * @notice Forfeit an appeal bond to the protocol
     * @param workflowId Unique identifier for the dispute
     * @param round Round the bond was posted for
     * @param reason Reason for forfeiture
     */
    function forfeitAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 round,
        string calldata reason
    ) external onlyEscrowContract nonReentrant {
        AppealBondRecord storage bond = appealBonds[escrowContract][workflowId][round];
        require(bond.amount > 0, 'No bond recorded');
        require(!bond.distributed, 'Bond already distributed');

        bond.distributed = true;
        uint256 amount = bond.amount;
        bond.amount = 0;
        totalBondsForfeited += amount;

        emit AppealBondForfeited(workflowId, round, amount, bond.token, reason);
    }

    /**
     * @notice Get appeal bond record
     * @param workflowId Dispute ID
     * @param escrowContract Address of the vault
     * @param round Round bond was posted for
     * @return bond Appeal bond record
     */
    function getAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 round
    ) external view returns (AppealBondRecord memory bond) {
        return appealBonds[escrowContract][workflowId][round];
    }

    /**
     * @notice Get observability metrics for V2 (bonds)
     * @return posted Total bond value posted
     * @return refunded Total bond value credited to claimableBondRefunds or pushed (ETH)
     * @return refundsClaimed Total ERC20 bond refund value claimed via claimBondRefund
     * @return paidToResolvers Total bond value paid to resolvers
     * @return forfeited Total bond value forfeited to protocol (no eligible resolvers)
     */
    function getV2Metrics()
        external
        view
        returns (
            uint256 posted,
            uint256 refunded,
            uint256 refundsClaimed,
            uint256 paidToResolvers,
            uint256 forfeited
        )
    {
        return (
            totalBondsPosted,
            totalBondsRefunded,
            totalBondRefundsClaimed,
            totalBondsPaidToResolvers,
            totalBondsForfeited
        );
    }

    /**
     * @notice Get escalation depth histogram
     */
    function getEscalationDepthHistogram()
        external
        view
        returns (
            uint256 round0,
            uint256 round1,
            uint256 round2
        )
    {
        return (
            escalationDepthHistogram[0],
            escalationDepthHistogram[1],
            escalationDepthHistogram[2]
        );
    }

    /**
     * @notice Claim a pending bond refund (pull pattern for ERC20 + ETH)
     */
    function claimBondRefund(uint256 workflowId, address escrowContract, address token) external nonReentrant {
        uint256 amount = claimableBondRefunds[escrowContract][workflowId][_msgSender()];
        require(amount > 0, 'Nothing to claim');

        delete claimableBondRefunds[escrowContract][workflowId][_msgSender()];
        totalBondRefundsClaimed += amount;

        if (token == address(0)) {
            (bool success, ) = payable(_msgSender()).call{value: amount}("");
            require(success, 'ETH refund claim failed');
        } else {
            IERC20(token).safeTransfer(_msgSender(), amount);
        }
        emit BondRefundClaimed(workflowId, _msgSender(), amount, token);
    }

    /**
     * @notice Check if an appeal bond exists for a dispute round
     */
    function hasAppealBond(
        uint256 workflowId,
        address escrowContract,
        uint8 round
    ) external view returns (bool) {
        return appealBonds[escrowContract][workflowId][round].amount > 0;
    }

    // ============ Internal DR v2 Functions ============

    // Note: _requirePayoutToken is inherited from V1

    /**
     * @notice Refund bond to depositor
     */
    function _refundBond(
        uint256 workflowId,
        address escrowContract,
        uint8 bondRound,
        AppealBondRecord storage bond,
        uint256 bondAmount
    ) internal {
        bond.refunded = true;
        totalBondsRefunded += bondAmount;

        // Refund bond back to the escalator.
        // For ETH bonds: depositor == escalatedBy (user-funded)
        // For ERC20 bonds: depositor may be an intermediary custodian (e.g., BondCollector),
        // but escalatedBy is always the user who should receive the refund.
        address refundTo = bond.escalatedBy;

        // Pull pattern for both ETH and ERC20 bonds.
        // Avoids push-to-contract failure trapping the bond permanently.
        claimableBondRefunds[escrowContract][workflowId][refundTo] += bondAmount;
        emit AppealBondRefundClaimable(workflowId, bondRound, refundTo, bondAmount, bond.token);
    }

    /**
     * @notice Pay bond to resolvers from prior round
     * @param workflowId Dispute ID
     * @param escrowContract Address of the vault
     * @param priorRound Round whose resolvers should receive bond
     * @param bond Bond record
     * @param bondAmount Bond amount (bond.amount is cleared before this call)
     * @dev Only increments totalBondsPaidToResolvers when actually paid to resolvers
     *      If no resolvers found, bond is retained by protocol (not counted as "paid")
     */
    function _payBondToResolvers(
        uint256 workflowId,
        address escrowContract,
        uint8 priorRound,
        AppealBondRecord storage bond,
        uint256 bondAmount
    ) internal {
        bond.refunded = false;

        // Get resolvers from prior round
        ResolverRecord[] storage resolvers = disputeResolvers[escrowContract][workflowId];

        // If no resolvers in storage, bond is retained by protocol as revenue
        if (resolvers.length == 0) {
            totalBondsForfeited += bondAmount;
            emit AppealBondForfeited(workflowId, priorRound, bondAmount, bond.token, 'No resolvers recorded');
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

        // If no resolvers found at this round, bond is retained by protocol as revenue
        if (count == 0) {
            totalBondsForfeited += bondAmount;
            emit AppealBondForfeited(workflowId, priorRound, bondAmount, bond.token, 'No resolvers at round');
            return;
        }

        // Actually pay to resolvers - increment metric only now
        totalBondsPaidToResolvers += bondAmount;

        // Distribute bond equally among resolvers from that round
        uint256 amountPerResolver = bondAmount / count;
        uint256 remainder = bondAmount % count; // Handle rounding error

        // Add to claimable payments for each resolver
        for (uint256 i = 0; i < count; i++) {
            address resolver = eligibleResolvers[i];
            if (resolver != address(0)) {
                uint256 payment = amountPerResolver;
                if (i < remainder) payment += 1; // Distribute remainder 1-wei each to first 'remainder' resolvers

                claimablePayments[escrowContract][workflowId][resolver] += payment;
            }
        }

        emit AppealBondPaidToResolvers(
            workflowId,
            priorRound,
            eligibleResolvers,
            bondAmount,
            bond.token
        );
    }

    /**
     * @notice Clean up outstanding bonds when a dispute is finalized.
     * @dev Any bond posted for a round <= finalRound that was never distributed
     *      is forfeited to the protocol. This prevents bonds from being stuck
     *      indefinitely when the dispute ends without going through the full
     *      reversal/appeal path for every bonded round.
     */
    function onDisputeFinalized(
        uint256 workflowId,
        address escrowContract,
        uint8 finalRound,
        ResolutionOutcome /* finalDecision */
    ) external override onlyEscrowContract {
        // Forfeit any outstanding bonds for rounds 0 to finalRound
        for (uint8 round = 0; round <= finalRound; round++) {
            AppealBondRecord storage bond = appealBonds[escrowContract][workflowId][round];
            if (bond.amount > 0 && !bond.distributed) {
                bond.distributed = true;
                uint256 amount = bond.amount;
                bond.amount = 0;
                totalBondsForfeited += amount;
                emit AppealBondForfeited(workflowId, round, amount, bond.token, 'Finalize cleanup');
            }
        }
    }
}