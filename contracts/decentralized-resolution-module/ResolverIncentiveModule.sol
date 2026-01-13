// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "./IPaymentCalculationLibrary.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../shared/governance/SlowLaneQueueActivateUpgradeable.sol";

/**
 * @title ResolverIncentiveModule
 * @notice Module for calculating and distributing resolver payments
 * @dev Uses functional library approach with governance-controlled upgrades
 *      - State management: Imperative (in this contract)
 *      - Payment calculations: Functional (in library)
 *      - Library upgrades: Governance-controlled (slow lane) or instant (module developer)
 *      - UUPS upgradeable for rapid iteration and bug fixes
 */
contract ResolverIncentiveModule is 
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    SlowLaneQueueActivateUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    
    // ============ Role Constants ============
    bytes32 public constant ROLE_TIMELOCK = keccak256("ROLE_TIMELOCK");
    
    // ============ Constants ============
    uint256 public constant BASIS_POINTS_DENOMINATOR = 10000;
    uint256 public constant MAX_SINGLE_PAYMENT_PERCENTAGE = 9000; // 90% - maximum single payment share
    
    // ============ State Variables ============
    
    // Current payment calculation library (upgradeable via governance)
    address public currentPaymentLibrary;
    PendingAddress private _pendingPaymentLibrary;
    
    // Resolver tracking per dispute
    mapping(uint256 => ResolverRecord[]) public disputeResolvers;
    mapping(uint256 => uint256) public disputeEscrowFees;
    mapping(uint256 => uint256) public disputeEscalationFees;
    mapping(uint256 => bool) public disputePaymentsDistributed;
    
    // Pull pattern: claimable payments per resolver per dispute
    mapping(uint256 => mapping(address => uint256)) public claimablePayments;
    mapping(uint256 => bool) public paymentsCalculated;
    
    // Configuration (governance-controlled)
    uint256 public resolverSharePercentage;
    PendingUint private _pendingResolverSharePercentage;
    
    Weights public weights;
    PendingWeights private _pendingWeights;
    
    // Registered escrow contracts that can call onDisputeOpened and onDisputeResolved
    mapping(address => bool) public registeredEscrowContracts;
    
    // ============ Events ============
    
    event ResolverRecorded(
        uint256 indexed workflowId,
        address indexed resolver,
        uint8 level,
        uint256 timestamp
    );
    
    event EscrowFeeRecorded(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount
    );
    
    event EscalationFeeRecorded(
        uint256 indexed workflowId,
        address indexed token,
        uint256 amount
    );
    
    event PaymentsDistributed(
        uint256 indexed workflowId,
        address indexed token,
        uint256 totalResolverShare,
        address[] resolvers,
        uint256[] payments
    );
    
    event PaymentLibraryQueued(
        address indexed oldLibrary,
        address indexed newLibrary,
        uint64 eta
    );
    
    event PaymentLibraryActivated(
        address indexed oldLibrary,
        address indexed newLibrary
    );
    
    event PaymentLibraryRolledBack(
        address indexed previousLibrary
    );
    
    event PaymentLibrarySwappedInstant(
        address indexed oldLibrary,
        address indexed newLibrary,
        address indexed swappedBy,
        uint256 timestamp
    );
    
    // Phase 3: Task 3.3 - Event completeness
    event ZeroPaymentSkipped(
        uint256 indexed workflowId,
        address indexed resolver
    );
    
    event ResolverSharePercentageQueued(
        uint256 oldPercentage,
        uint256 newPercentage,
        uint64 eta
    );
    
    event ResolverSharePercentageActivated(
        uint256 oldPercentage,
        uint256 newPercentage
    );
    
    event WeightsQueued(
        Weights oldWeights,
        Weights newWeights,
        uint64 eta
    );
    
    event WeightsActivated(
        Weights oldWeights,
        Weights newWeights
    );
    
    event EscrowContractRegistered(address indexed escrowContract);
    event EscrowContractUnregistered(address indexed escrowContract);
    
    event PaymentsCalculated(
        uint256 indexed workflowId,
        address indexed token,
        uint256 totalResolverShare
    );
    
    event PaymentClaimed(
        uint256 indexed workflowId,
        address indexed resolver,
        uint256 amount
    );
    
    event PaymentClaimFailed(
        uint256 indexed workflowId,
        address indexed resolver,
        string reason
    );
    
    // ============ Structs ============
    
    struct PendingWeights {
        Weights value;
        uint64 eta;
        bool exists;
    }
    
    // ============ Modifiers ============
    
    modifier onlyEscrowContract() {
        require(registeredEscrowContracts[_msgSender()], "Not registered escrow contract");
        _;
    }
    
    // ============ Initialization ============
    
    /**
     * @notice Initialize the upgradeable contract
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE and ROLE_TIMELOCK
     * @param initialLibrary Address of initial payment calculation library
     * @dev Replaces constructor for upgradeable contracts
     */
    function initialize(address initialOwner, address initialLibrary) public initializer {
        require(initialOwner != address(0), "Zero owner");
        require(initialLibrary != address(0), "Zero library");
        
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_TIMELOCK, initialOwner);
        
        // Initialize configuration
        resolverSharePercentage = 5000; // 50%
        weights = Weights({
            level0: 10000,
            level1: 15000,
            level2: 20000
        });

        // Validate and set initial library
        require(validateLibrary(initialLibrary), "Invalid library");
        currentPaymentLibrary = initialLibrary;
    }
    
    /**
     * @notice Authorize upgrade (UUPS pattern)
     * @param newImplementation Address of new implementation
     * @dev Only ROLE_TIMELOCK can upgrade (via standard governance lanes)
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
    {
        require(
            hasRole(ROLE_TIMELOCK, _msgSender()),
            "Not authorized to upgrade"
        );
        
        address oldImplementation = ERC1967Utils.getImplementation();
        
        emit IncentiveModuleUpgraded(
            oldImplementation,
            newImplementation,
            _msgSender(),
            block.timestamp
        );
    }
    
    /**
     * @notice Event emitted when incentive module is upgraded
     * @param oldImplementation Previous implementation address
     * @param newImplementation New implementation address
     * @param upgradedBy Address that executed the upgrade
     * @param timestamp Block timestamp of upgrade
     */
    event IncentiveModuleUpgraded(
        address indexed oldImplementation,
        address indexed newImplementation,
        address indexed upgradedBy,
        uint256 timestamp
    );
    
    // ============ Core Functions ============
    
    /**
     * @notice Record resolver involvement in a dispute
     * @param workflowId The escrow transfer ID
     * @param resolver Resolver address
     * @param level Escalation level (0 = standard, 1 = senior, 2 = external)
     * @dev Called by escrow contract when resolver is assigned or escalated
     */
    function recordResolver(
        uint256 workflowId,
        address resolver,
        uint8 level
    ) external onlyEscrowContract {
        require(resolver != address(0), "Zero resolver");
        require(level <= 2, "Invalid level");
        
        // Check if resolver already recorded for this dispute
        ResolverRecord[] storage resolvers = disputeResolvers[workflowId];
        for (uint256 i = 0; i < resolvers.length; i++) {
            if (resolvers[i].resolver == resolver && resolvers[i].level == level) {
                // Already recorded, skip
                return;
            }
        }
        
        // Record new resolver
        resolvers.push(ResolverRecord({
            resolver: resolver,
            level: level,
            timestamp: block.timestamp
        }));
        
        emit ResolverRecorded(workflowId, resolver, level, block.timestamp);
    }
    
    /**
     * @notice Record escrow fee for a dispute
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param amount Fee amount
     * @dev Called by escrow contract when dispute is opened
     */
    function recordEscrowFee(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external onlyEscrowContract {
        require(token != address(0), "Zero token");
        require(amount > 0, "Zero amount");
        
        disputeEscrowFees[workflowId] = amount;
        emit EscrowFeeRecorded(workflowId, token, amount);
    }
    
    /**
     * @notice Record escalation fee for a dispute
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param amount Fee amount
     * @dev Called by escrow contract when dispute is escalated
     */
    function recordEscalationFee(
        uint256 workflowId,
        address token,
        uint256 amount
    ) external onlyEscrowContract {
        require(token != address(0), "Zero token");
        require(amount > 0, "Zero amount");
        require(amount < type(uint256).max / 2, "Amount too large"); // Prevent overflow (Phase 1: Task 1.8)
        
        // Check if dispute exists (Phase 1: Task 1.8)
        require(
            disputeResolvers[workflowId].length > 0,
            "Dispute not initialized"
        );
        
        disputeEscalationFees[workflowId] += amount; // Accumulate escalation fees
        emit EscalationFeeRecorded(workflowId, token, amount);
    }
    
    /**
     * @notice Calculate payments when dispute is resolved (pull pattern)
     * @param workflowId The escrow transfer ID
     * @param token Token address for payments
     * @dev Called by escrow contract when dispute is resolved
     *      Calculates payments and makes them claimable (pull pattern)
     *      Escrow contract must transfer tokens to this contract before calling
     */
    function onDisputeResolved(
        uint256 workflowId,
        address token
    ) external onlyEscrowContract nonReentrant {
        require(token != address(0), "Zero token");
        require(!paymentsCalculated[workflowId], "Payments already calculated");
        
        // Gather data (imperative - state reads)
        ResolverRecord[] memory resolvers = disputeResolvers[workflowId];
        require(resolvers.length > 0, "No resolvers");
        
        uint256 escrowFee = disputeEscrowFees[workflowId];
        uint256 escalationFees = disputeEscalationFees[workflowId];
        
        // Prepare input (functional data structure)
        PaymentInput memory input = PaymentInput({
            escrowFee: escrowFee,
            escalationFees: escalationFees,
            resolverSharePercentage: resolverSharePercentage,
            resolvers: resolvers,
            weights: weights
        });
        
        // Calculate payments (functional - pure library call)
        PaymentOutput memory output = calculatePaymentsWithVersion(input);
        
        // ============ Bounds Checking ============
        // Validate payment calculation results
        
        // 1. Array length validation
        require(output.resolvers.length == output.payments.length, "Array length mismatch");
        require(output.resolvers.length > 0, "No resolvers in output");
        
        // 2. Total amount validation - resolver share cannot exceed total fees
        require(output.totalResolverShare <= escrowFee + escalationFees, "Resolver share exceeds total fees");
        
        // 3. Individual payment validation
        uint256 calculatedTotal = 0;
        for (uint256 i = 0; i < output.payments.length; i++) {
            // Each payment must be non-negative and not exceed total
            require(output.payments[i] <= output.totalResolverShare, "Individual payment exceeds total");
            
            // Sum validation (check for overflow)
            uint256 previousTotal = calculatedTotal;
            calculatedTotal += output.payments[i];
            require(calculatedTotal >= previousTotal, "Payment sum overflow");
        }
        
        // 4. Sum validation - sum of individual payments should equal total
        require(calculatedTotal == output.totalResolverShare, "Payment sum mismatch");
        
        // 5. Resolver address validation
        for (uint256 i = 0; i < output.resolvers.length; i++) {
            require(output.resolvers[i] != address(0), "Zero resolver address");
        }
        
        // 6. Maximum payment validation - no single payment should exceed reasonable bounds
        // (e.g., no single resolver should get more than 90% of total share)
        // Only apply this check when there are multiple resolvers
        // When there's only one resolver, they should legitimately get 100% of the share
        if (output.resolvers.length > 1) {
            uint256 maxSinglePayment = (output.totalResolverShare * MAX_SINGLE_PAYMENT_PERCENTAGE) / BASIS_POINTS_DENOMINATOR;
            for (uint256 i = 0; i < output.payments.length; i++) {
                require(output.payments[i] <= maxSinglePayment, "Payment exceeds maximum allowed");
            }
        }
        
        // 7. Minimum payment validation - if there are multiple resolvers, no payment should be 0
        // (unless explicitly allowed by the payment library)
        // Note: Zero payments are allowed but will be skipped in distribution
        
        // Check contract has sufficient balance
        IERC20 tokenContract = IERC20(token);
        uint256 contractBalance = tokenContract.balanceOf(address(this));
        require(contractBalance >= output.totalResolverShare, "Insufficient balance");
        
        // Store claimable amounts (pull pattern - resolvers claim their payments)
        for (uint256 i = 0; i < output.resolvers.length; i++) {
            if (output.resolvers[i] != address(0) && output.payments[i] > 0) {
                claimablePayments[workflowId][output.resolvers[i]] = output.payments[i];
            }
        }
        
        // Mark as calculated (allows resolvers to claim)
        paymentsCalculated[workflowId] = true;
        disputePaymentsDistributed[workflowId] = true; // For backward compatibility
        
        emit PaymentsCalculated(workflowId, token, output.totalResolverShare);
    }
    
    /**
     * @notice Claim payment for a resolved dispute (pull pattern)
     * @param workflowId The escrow transfer ID
     * @param token Token address for payment
     * @dev Resolvers call this to claim their payment
     *      Allows retry if initial transfer fails
     */
    function claimPayment(
        uint256 workflowId,
        address token
    ) external nonReentrant {
        require(token != address(0), "Zero token");
        require(paymentsCalculated[workflowId], "Payments not calculated");
        
        uint256 amount = claimablePayments[workflowId][_msgSender()];
        require(amount > 0, "Nothing to claim");
        
        // Clear claimable amount before transfer (prevent reentrancy)
        delete claimablePayments[workflowId][_msgSender()];
        
        // Transfer payment (safeTransfer will revert on failure, restoring claimable amount is not needed
        // since the delete above will be reverted by the transaction revert)
        IERC20 tokenContract = IERC20(token);
        tokenContract.safeTransfer(_msgSender(), amount);
        
        emit PaymentClaimed(workflowId, _msgSender(), amount);
    }
    
    /**
     * @notice Calculate payments using current library with version detection
     * @param input Payment calculation input
     * @return output Payment calculation results
     * @dev Detects library version and calls appropriate function
     */
    function calculatePaymentsWithVersion(PaymentInput memory input)
        internal view returns (PaymentOutput memory)
    {
        // Get library version
        string memory libVersion = IPaymentCalculationLibrary(currentPaymentLibrary).version();
        
        // For V1, use standard interface
        // Future versions can add version-specific handling here
        if (keccak256(bytes(libVersion)) == keccak256(bytes("1.0.0"))) {
            // V1: Standard interface call
            return IPaymentCalculationLibrary(currentPaymentLibrary).calculatePayments(input);
        } else {
            // Unknown version - try standard interface (extensible input should handle it)
            return IPaymentCalculationLibrary(currentPaymentLibrary).calculatePayments(input);
        }
    }
    
    /**
     * @notice Distribute payments to resolvers (legacy push pattern - kept for backward compatibility)
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param output Payment calculation output
     * @dev Transfers tokens to each resolver
     * @dev NOTE: This function is deprecated. Use claimPayment() (pull pattern) instead.
     *      Kept for backward compatibility if needed.
     */
    function distributePayments(
        uint256 workflowId,
        address token,
        PaymentOutput memory output
    ) internal {
        require(output.resolvers.length == output.payments.length, "Array length mismatch");
        require(output.resolvers.length > 0, "No resolvers");
        
        IERC20 tokenContract = IERC20(token);
        
        // Transfer payments to each resolver
        // Phase 3: Task 3.3 - Emit event for zero payments
        for (uint256 i = 0; i < output.resolvers.length; i++) {
            if (output.payments[i] > 0 && output.resolvers[i] != address(0)) {
                tokenContract.safeTransfer(output.resolvers[i], output.payments[i]);
            } else if (output.resolvers[i] != address(0)) {
                // Emit event for zero payments (Phase 3: Task 3.3)
                emit ZeroPaymentSkipped(workflowId, output.resolvers[i]);
            }
        }
        
        emit PaymentsDistributed(
            workflowId,
            token,
            output.totalResolverShare,
            output.resolvers,
            output.payments
        );
    }
    
    // ============ Governance Functions ============
    
    
    /**
     * @notice Queue new payment calculation library (slow-lane, governance-controlled)
     * @param newLibrary Address of new library contract
     * @dev Validates library before queueing, 7-day delay before activation
     */
    function queuePaymentCalculationLibrary(address newLibrary)
        external onlyRole(ROLE_TIMELOCK)
    {
        require(newLibrary != address(0), "Zero address");
        require(validateLibrary(newLibrary), "Invalid library");
        
        _queueAddress(_pendingPaymentLibrary, newLibrary);
        emit PaymentLibraryQueued(currentPaymentLibrary, newLibrary, _pendingPaymentLibrary.eta);
    }
    
    /**
     * @notice Activate queued payment calculation library
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activatePaymentCalculationLibrary()
        external onlyRole(ROLE_TIMELOCK)
    {
        address oldLibrary = currentPaymentLibrary;
        currentPaymentLibrary = _activateAddress(_pendingPaymentLibrary);
        
        emit PaymentLibraryActivated(oldLibrary, currentPaymentLibrary);
    }
    
    /**
     * @notice Rollback to previous library (emergency only)
     * @param previousLibrary Address of previous library
     * @dev Should be used only in emergencies
     */
    function rollbackToPreviousLibrary(address previousLibrary)
        external onlyRole(ROLE_TIMELOCK)
    {
        require(previousLibrary != address(0), "Zero address");
        require(validateLibrary(previousLibrary), "Invalid library");
        
        currentPaymentLibrary = previousLibrary;
        emit PaymentLibraryRolledBack(previousLibrary);
    }
    
    /**
     * @notice Queue resolver share percentage change
     * @param newPercentage New percentage (basis points, e.g., 5000 = 50%)
     * @dev 7-day delay before activation
     */
    function queueResolverSharePercentage(uint256 newPercentage)
        external onlyRole(ROLE_TIMELOCK)
    {
        require(newPercentage <= 10000, "Invalid percentage");
        
        _queueUint(_pendingResolverSharePercentage, newPercentage);
        emit ResolverSharePercentageQueued(
            resolverSharePercentage,
            newPercentage,
            _pendingResolverSharePercentage.eta
        );
    }
    
    /**
     * @notice Activate queued resolver share percentage
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activateResolverSharePercentage()
        external onlyRole(ROLE_TIMELOCK)
    {
        uint256 oldPercentage = resolverSharePercentage;
        resolverSharePercentage = _activateUint(_pendingResolverSharePercentage);
        
        emit ResolverSharePercentageActivated(oldPercentage, resolverSharePercentage);
    }
    
    /**
     * @notice Queue weights change
     * @param newWeights New weight configuration
     * @dev 7-day delay before activation
     */
    function queueWeights(Weights memory newWeights)
        external onlyRole(ROLE_TIMELOCK)
    {
        require(newWeights.level0 > 0, "Invalid level0 weight");
        require(newWeights.level1 > 0, "Invalid level1 weight");
        require(newWeights.level2 > 0, "Invalid level2 weight");
        
        _pendingWeights = PendingWeights({
            value: newWeights,
            eta: uint64(block.timestamp + SLOW_DELAY),
            exists: true
        });
        
        emit WeightsQueued(weights, newWeights, _pendingWeights.eta);
    }
    
    /**
     * @notice Activate queued weights
     * @dev Reverts if 7-day delay has not elapsed
     */
    function activateWeights()
        external onlyRole(ROLE_TIMELOCK)
    {
        if (!_pendingWeights.exists) {
            revert NoPending();
        }
        if (block.timestamp < _pendingWeights.eta) {
            revert NotReady(_pendingWeights.eta);
        }
        
        Weights memory oldWeights = weights;
        weights = _pendingWeights.value;
        
        emit WeightsActivated(oldWeights, weights);
        
        // Clear pending
        delete _pendingWeights;
    }
    
    /**
     * @notice Register escrow contract
     * @param escrowContract Address of escrow contract
     * @dev Only registered contracts can call incentive functions
     */
    function registerEscrowContract(address escrowContract)
        external onlyRole(ROLE_TIMELOCK)
    {
        require(escrowContract != address(0), "Zero address");
        registeredEscrowContracts[escrowContract] = true;
        emit EscrowContractRegistered(escrowContract);
    }
    
    /**
     * @notice Unregister escrow contract
     * @param escrowContract Address of escrow contract
     */
    function unregisterEscrowContract(address escrowContract)
        external onlyRole(ROLE_TIMELOCK)
    {
        registeredEscrowContracts[escrowContract] = false;
        emit EscrowContractUnregistered(escrowContract);
    }
    
    // ============ Validation Functions ============
    
    /**
     * @notice Validate a library before queueing
     * @param libAddress Library address to validate
     * @return valid True if library is valid
     */
    function validateLibrary(address libAddress) public view returns (bool) {
        if (libAddress.code.length == 0) return false;
        
        // Check interface compliance
        try IPaymentCalculationLibrary(libAddress).validate() returns (bool valid) {
            if (!valid) return false;
        } catch {
            return false;
        }
        
        // Test with sample input
        PaymentInput memory testInput = createTestInput();
        try IPaymentCalculationLibrary(libAddress).calculatePayments(testInput) 
            returns (PaymentOutput memory) 
        {
            return true;
        } catch {
            return false;
        }
    }
    
    /**
     * @notice Create test input for validation
     * @return testInput Test payment input
     */
    function createTestInput() internal view returns (PaymentInput memory) {
        ResolverRecord[] memory resolvers = new ResolverRecord[](2);
        resolvers[0] = ResolverRecord({
            resolver: address(0x1),
            level: 0,
            timestamp: 0 // Timestamp not needed for calculation
        });
        resolvers[1] = ResolverRecord({
            resolver: address(0x2),
            level: 1,
            timestamp: 0 // Timestamp not needed for calculation
        });
        
        return PaymentInput({
            escrowFee: 1000,
            escalationFees: 500,
            resolverSharePercentage: resolverSharePercentage,
            resolvers: resolvers,
            weights: weights
        });
    }
    
    // ============ View Functions ============
    
    /**
     * @notice Get pending library change
     * @return libAddress Pending library address
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingPaymentLibrary() 
        external view returns (address libAddress, uint64 eta, bool exists)
    {
        return getPendingAddress(_pendingPaymentLibrary);
    }
    
    /**
     * @notice Get pending resolver share percentage change
     * @return percentage Pending percentage
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingResolverSharePercentage()
        external view returns (uint256 percentage, uint64 eta, bool exists)
    {
        return getPendingUint(_pendingResolverSharePercentage);
    }
    
    /**
     * @notice Get pending weights change
     * @return pendingWeights Pending weights
     * @return eta Activation timestamp
     * @return exists Whether pending change exists
     */
    function getPendingWeights()
        external view returns (Weights memory pendingWeights, uint64 eta, bool exists)
    {
        return (_pendingWeights.value, _pendingWeights.eta, _pendingWeights.exists);
    }
    
    /**
     * @notice Get resolvers for a dispute
     * @param workflowId The escrow transfer ID
     * @return resolvers Array of resolver records
     */
    function getDisputeResolvers(uint256 workflowId)
        external view returns (ResolverRecord[] memory)
    {
        return disputeResolvers[workflowId];
    }
    
    /**
     * @notice Get fee information for a dispute
     * @param workflowId The escrow transfer ID
     * @return escrowFee Escrow fee
     * @return escalationFees Total escalation fees
     */
    function getDisputeFees(uint256 workflowId)
        external view returns (uint256 escrowFee, uint256 escalationFees)
    {
        return (disputeEscrowFees[workflowId], disputeEscalationFees[workflowId]);
    }
    
    /**
     * @notice Check if payments have been distributed for a dispute
     * @param workflowId The escrow transfer ID
     * @return distributed True if payments have been distributed
     */
    function arePaymentsDistributed(uint256 workflowId)
        external view returns (bool)
    {
        return disputePaymentsDistributed[workflowId];
    }
    
    /**
     * @notice Check if payments have been calculated for a dispute
     * @param workflowId The escrow transfer ID
     * @return calculated True if payments have been calculated (claimable)
     */
    function arePaymentsCalculated(uint256 workflowId)
        external view returns (bool)
    {
        return paymentsCalculated[workflowId];
    }
    
    /**
     * @notice Get claimable payment amount for a resolver
     * @param workflowId The escrow transfer ID
     * @param resolver Resolver address
     * @return amount Claimable amount (0 if nothing to claim)
     */
    function getClaimablePayment(uint256 workflowId, address resolver)
        external view returns (uint256)
    {
        return claimablePayments[workflowId][resolver];
    }
    
    /**
     * @notice ERC165 interface support
     * @param interfaceId The interface identifier
     * @return True if the contract supports the interface
     * @dev AccessControlUpgradeable already includes ERC165Upgradeable
     */
    function supportsInterface(bytes4 interfaceId)
        public view virtual override(AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
    
    // ============ Storage Gap ============
    // Reserve storage slots for future upgrades
    uint256[50] private __gap;
}

