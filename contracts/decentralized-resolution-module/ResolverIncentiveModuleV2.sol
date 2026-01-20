// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import './ResolverIncentiveModuleV1.sol';
import './IIncentiveModule.sol';
import './DecentralizedResolverStructs.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

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
        address depositor; // Who deposited the bond (for ERC20: escrow contract, for ETH: user)
        address escalatedBy; // Who initiated the escalation (always the user/escalator)
        uint256 amount; // Bond amount
        address token; // Token address (address(0) = ETH)
        uint256 depositedAt; // Timestamp
        bool distributed; // Whether bond has been refunded/paid
        bool refunded; // True = refunded to depositor, False = paid to resolvers
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

    // ============ Token Consistency Enforcement ============
    
    /// @dev Enforce single payout token per dispute to prevent token-mixing in claimablePayments
    /// @dev Set on first payment source (fee or bond), subsequent payments must match
    mapping(uint256 => address) public payoutToken;

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
        require(appealBonds[workflowId][round].amount == 0, 'Bond already exists');
        require(!appealBonds[workflowId][round].distributed, 'Bond already distributed');

        // Enforce custody: pull funds atomically
        if (token == address(0)) {
            // ETH bond: require exact msg.value match
            require(msg.value == amount, 'ETH amount mismatch');
            // For ETH bonds, depositor must be the escalator (user-funded)
            require(depositor == escalatedBy, 'Depositor must be escalator for ETH bonds');
            // Funds are automatically received via payable
        } else {
            // ERC20 bond: pull tokens from depositor (pull-based pattern)
            // This ensures atomicity: if this call reverts, no tokens move
            // Depositor must approve this contract (the incentive module) for ERC20 bonds
            IERC20(token).safeTransferFrom(depositor, address(this), amount);
        }

        // Enforce single payout token per dispute (CRITICAL: prevents token-mixing in claimablePayments)
        _requirePayoutToken(workflowId, token);

        // Record bond with actual received amount
        appealBonds[workflowId][round] = AppealBondRecord({
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
     * @param round Round that was appealed FROM (bond depositor appealed decision at this round)
     * @param outcomeFlipped Whether the appeal succeeded (decision changed)
     * @dev If outcomeFlipped = true: refund to depositor
     *      If outcomeFlipped = false: pay to resolvers from 'round'
     * @dev Protected by reentrancy guard to prevent reentrancy attacks
     */
    function distributeAppealBond(
        uint256 workflowId,
        uint8 round,
        bool outcomeFlipped
    ) external override onlyEscrowContract nonReentrant {
        // Validate round bounds
        require(round < 2, 'Invalid round - no higher round');

        // Bond was posted to escalate FROM round to round+1
        // So we look up the bond at round+1
        uint8 bondRound = round + 1;
        AppealBondRecord storage bond = appealBonds[workflowId][bondRound];

        require(bond.amount > 0, 'No bond recorded');
        require(!bond.distributed, 'Bond already distributed');

        bond.distributed = true;
        // Clear bond amount for gas refunds and "cannot reuse" clarity
        uint256 bondAmount = bond.amount;
        bond.amount = 0;

        if (outcomeFlipped) {
            // Appeal succeeded - refund to depositor
            _refundBond(workflowId, bondRound, bond, bondAmount);
        } else {
            // Appeal failed - pay to resolvers from prior round
            _payBondToResolvers(workflowId, round, bond, bondAmount);
        }
    }

    // ============ Internal DR v2 Functions ============

    /**
     * @notice Enforce single payout token per dispute
     * @param workflowId Dispute ID
     * @param token Token address to check/enforce
     * @dev Sets payout token on first payment source (fee or bond)
     *      Subsequent payments must match to prevent token-mixing in claimablePayments
     */
    function _requirePayoutToken(uint256 workflowId, address token) internal {
        address p = payoutToken[workflowId];
        if (p == address(0)) {
            // First payment source - set the payout token
            payoutToken[workflowId] = token;
        } else {
            // Subsequent payment - must match
            require(p == token, 'Mixed payout tokens - bond token must match fee token');
        }
    }

    /**
     * @notice Refund bond to depositor
     */
    function _refundBond(
        uint256 workflowId,
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

        if (bond.token == address(0)) {
            // ETH
            (bool success, ) = refundTo.call{value: bondAmount}('');
            require(success, 'ETH refund failed');
        } else {
            // ERC20
            IERC20(bond.token).safeTransfer(refundTo, bondAmount);
        }

        emit AppealBondRefunded(workflowId, bondRound, bond.depositor, bondAmount, bond.token);
    }

    /**
     * @notice Pay bond to resolvers from prior round
     * @param workflowId Dispute ID
     * @param priorRound Round whose resolvers should receive bond
     * @param bond Bond record
     * @param bondAmount Bond amount (bond.amount is cleared before this call)
     * @dev Only increments totalBondsPaidToResolvers when actually paid to resolvers
     *      If no resolvers found, bond is retained by protocol (not counted as "paid")
     */
    function _payBondToResolvers(
        uint256 workflowId,
        uint8 priorRound,
        AppealBondRecord storage bond,
        uint256 bondAmount
    ) internal {
        bond.refunded = false;

        // Get resolvers from prior round
        ResolverRecord[] storage resolvers = disputeResolvers[workflowId];

        // If no resolvers in storage (e.g., testing scenario), bond is retained by protocol
        if (resolvers.length == 0) {
            // Don't increment totalBondsPaidToResolvers - bond is not actually paid
            // Bond remains in contract as protocol revenue
            emit AppealBondPaidToResolvers(
                workflowId,
                priorRound,
                new address[](0),
                bondAmount,
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

        // If no resolvers found at this round, bond is retained by protocol
        if (count == 0) {
            // Don't increment totalBondsPaidToResolvers - bond is not actually paid
            emit AppealBondPaidToResolvers(
                workflowId,
                priorRound,
                new address[](0),
                bondAmount,
                bond.token
            );
            return;
        }

        // Actually pay to resolvers - increment metric only now
        totalBondsPaidToResolvers += bondAmount;

        // Distribute bond equally among resolvers from that round
        uint256 amountPerResolver = bondAmount / count;
        uint256 remainder = bondAmount % count; // Handle rounding error

        // Add to claimable payments for each resolver
        //
        // IMPORTANT TOKEN ACCOUNTING LIMITATION:
        // claimablePayments[workflowId][resolver] is NOT token-scoped.
        // This assumes bond.token matches the token used for fee payments in onDisputeResolved().
        //
        // If bonds can be in different tokens than fees, this will cause accounting errors:
        // - Resolver claims will use the wrong token
        // - Amounts from different tokens will be mixed
        //
        // To support multi-token bonds, claimablePayments should be changed to:
        // mapping(uint256 => mapping(address => mapping(address => uint256))) claimablePayments;
        // (workflowId => resolver => token => amount)
        //
        // For now, we require bond.token == fee token for the dispute.
        for (uint256 i = 0; i < count; i++) {
            uint256 payment = amountPerResolver;
            // Distribute remainder to first resolver(s) to avoid loss
            if (i < remainder) {
                payment += 1;
            }
            claimablePayments[workflowId][eligibleResolvers[i]] += payment;
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
            bondAmount,
            bond.token
        );
    }

    /**
     * @notice Forfeit bond (e.g., if escalator doesn't follow through)
     * @param workflowId Dispute ID
     * @param round Bond round
     * @param reason Reason for forfeiture
     * @dev Protected by reentrancy guard to prevent reentrancy attacks
     */
    function forfeitAppealBond(
        uint256 workflowId,
        uint8 round,
        string memory reason
    ) external onlyEscrowContract nonReentrant {
        AppealBondRecord storage bond = appealBonds[workflowId][round];

        require(bond.amount > 0, 'No bond recorded');
        require(!bond.distributed, 'Bond already distributed');

        bond.distributed = true;
        bond.refunded = false;
        uint256 bondAmount = bond.amount;
        bond.amount = 0; // Clear for gas refunds and "cannot reuse" clarity
        totalBondsForfeited += bondAmount;

        // Bond remains in contract as protocol revenue
        // Can be withdrawn via sweep function

        emit AppealBondForfeited(workflowId, round, bondAmount, bond.token, reason);
    }

    // ============ View Functions (DR v2 Metrics) ============

    /**
     * @notice Get appeal bond record for a dispute/round
     */
    function getAppealBond(
        uint256 workflowId,
        uint8 round
    ) external view returns (AppealBondRecord memory) {
        return appealBonds[workflowId][round];
    }

    /**
     * @notice Get DR v2 observability metrics
     * @return bondsPosted Total bonds posted
     * @return bondsRefunded Total bonds refunded to depositors
     * @return bondsPaidToResolvers Total bonds paid to resolvers
     * @return bondsForfeited Total bonds forfeited
     */
    function getV2Metrics()
        external
        view
        returns (
            uint256 bondsPosted,
            uint256 bondsRefunded,
            uint256 bondsPaidToResolvers,
            uint256 bondsForfeited
        )
    {
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
    function getEscalationDepthHistogram()
        external
        view
        returns (uint256 round0, uint256 round1, uint256 round2)
    {
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

    /**
     * @notice Calculate and distribute resolver payments for a finalized dispute (IIncentiveModule interface)
     * @param workflowId Unique identifier for the dispute
     * @param token Token address for payment
     * @param totalFees Total fees available for distribution
     * @dev This is a wrapper that calls onDisputeResolved for backward compatibility
     *      Note: totalFees parameter is ignored as fees are already recorded via recordEscrowFee/recordEscalationFee
     */
    function distributePayments(
        uint256 workflowId,
        address token,
        uint256 totalFees
    ) external virtual override onlyEscrowContract {
        // Intentionally unused; fees are tracked via recordEscrowFee/recordEscalationFee.
        totalFees;

        // Enforce single payout token per dispute (CRITICAL: prevents token-mixing in claimablePayments)
        _requirePayoutToken(workflowId, token);
        // Delegate to onDisputeResolved for backward compatibility
        // Note: totalFees parameter is ignored as fees are already recorded via recordEscrowFee/recordEscalationFee
        onDisputeResolved(workflowId, token);
    }

    // ============ Treasury/Admin Functions ============

    /**
     * @notice Sweep retained bonds (protocol revenue) to treasury
     * @param token Token address to sweep (address(0) = ETH)
     * @param to Recipient address (typically treasury)
     * @param amount Amount to sweep (0 = sweep all)
     * @dev Restricted to timelock/owner for security
     * @dev Used to withdraw bonds retained by protocol when no resolvers are found
     */
    function sweep(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(ROLE_TIMELOCK) {
        require(to != address(0), 'Invalid recipient');
        
        if (token == address(0)) {
            // ETH
            uint256 balance = address(this).balance;
            uint256 toTransfer = amount == 0 ? balance : amount;
            require(toTransfer <= balance, 'Insufficient ETH balance');
            if (toTransfer > 0) {
                (bool success, ) = payable(to).call{value: toTransfer}('');
                require(success, 'ETH transfer failed');
            }
        } else {
            // ERC20
            IERC20 tokenContract = IERC20(token);
            uint256 balance = tokenContract.balanceOf(address(this));
            uint256 toTransfer = amount == 0 ? balance : amount;
            require(toTransfer <= balance, 'Insufficient token balance');
            if (toTransfer > 0) {
                tokenContract.safeTransfer(to, toTransfer);
            }
        }
    }

    // Allow contract to receive ETH for bonds
    receive() external payable {}
}
