// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// Uncomment this line to use console.log
// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./BaseEscrow.sol";
import "./governance/SlowLaneQueueActivate.sol";
import "./interfaces/IReleaseStrategy.sol";
import "./interfaces/IResolutionModule.sol";
import "./interfaces/IYieldGenerationModule.sol";
import "./interfaces/IYieldDistributionModule.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

// Additional errors specific to EscrowableERC20 (if any needed)

/**
 * @title EscrowableERC20
 * @notice ERC20 token with built-in escrow functionality
 * @dev Extends ERC20 and BaseEscrow to provide escrow capabilities for the token itself.
 *      Users can create escrows using this contract's tokens, with support for disputes,
 *      attachments, yield generation via Aave, and modular release/resolution strategies.
 */
contract EscrowableERC20 is ERC20, BaseEscrow {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SUPPLY = 1000000000000000000000000; // 1,000,000 tokens with 18 decimals
    uint256 public totalHeldInEscrow = 0;
    
    // Default module instances (per-escrow overrides removed in Phase 5 for mainnet credibility)
    IReleaseStrategy public defaultReleaseStrategy;
    IResolutionModule public defaultResolutionModule;
    IYieldGenerationModule public defaultYieldGenerationModule;
    IYieldDistributionModule public defaultYieldDistributionModule;

    // Slow lane pending changes (Phase 3)
    PendingAddress private _pendingDefaultReleaseStrategy;
    PendingAddress private _pendingDefaultResolutionModule;
    PendingAddress private _pendingDefaultYieldGenerationModule;
    PendingAddress private _pendingDefaultYieldDistributionModule; 
    

    // Events specific to EscrowableERC20 (without token parameter)
    event EscrowTransferCreated(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
    event FeesWithdrawn(uint256 amount);
    
    // Module events (per-escrow events removed in Phase 5)
    event DefaultYieldGenerationModuleSet(address indexed module);
    event DefaultYieldDistributionModuleSet(address indexed module);

    // Slow lane queue/activate events (Phase 3)
    event DefaultReleaseStrategyQueued(address indexed oldStrategy, address indexed newStrategy, uint64 eta);
    event DefaultReleaseStrategyActivated(address indexed oldStrategy, address indexed newStrategy);
    event DefaultResolutionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event DefaultYieldGenerationModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultYieldGenerationModuleActivated(address indexed oldModule, address indexed newModule);
    event DefaultYieldDistributionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultYieldDistributionModuleActivated(address indexed oldModule, address indexed newModule);


    constructor(
        string memory name,
        string memory symbol,
        uint256 _escrowFee,
        address _escrowFeeAddress
    ) ERC20(name, symbol) {
        if (_escrowFee > ESCROW_FEE_DENOMINATOR) {
            revert InvalidEscrowFee(_escrowFee, ESCROW_FEE_DENOMINATOR);
        }
        if (_escrowFeeAddress == address(0)) {
            revert InvalidAddress("Fee address cannot be zero", _escrowFeeAddress);
        }
        escrowFee = _escrowFee;
        escrowFeeAddress = _escrowFeeAddress;
        // Phase 7: authorizedResolver removed - resolver gate eliminated
        
        // Grant DEFAULT_ADMIN_ROLE to deployer so roles can be granted later
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        
        // Mint initial supply to deployer
        _mint(_msgSender(), INITIAL_SUPPLY);
    }

    // createEscrowWithPermit() removed for contract size reduction - see docs/PERMIT_FUNCTIONALITY_REMOVED.md

    /**
     * @notice Create a new escrow with custom settings
     * @param to Recipient address
     * @param amount Amount to escrow (fee will be deducted)
     * @param settings Escrow settings (custom resolver, yield, timing, etc.)
     * @return workflowId The ID of the created escrow transfer
     */
    function createEscrow(
        address to,
        uint256 amount,
        EscrowSettings memory settings
    ) public nonReentrant whenNotPaused returns (uint256) {
        // Input validation
        if (to == address(0)) {
            revert InvalidAddress("Recipient address cannot be zero", to);
        }
        if (amount == 0) {
            revert InvalidAmount("Amount must be greater than zero");
        }
        
        // Validate settings
        _validateEscrowSettings(settings);
        
        uint256 fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Check if sender has sufficient balance
        if (balanceOf(_msgSender()) < amount) {
            revert InsufficientTokenBalance({
                balance: balanceOf(_msgSender()),
                required: amount
            });
        }

        // Transfer tokens from sender to this contract (before state changes)
        _transfer(_msgSender(), address(this), amount);
        
        // State changes after successful transfer
        uint256 workflowId = nextWorkflowId;
        address defaultResolver = _getDisputeResolverForNewEscrow(
            workflowId,
            address(this),
            _msgSender(),
            to,
            amountAfterFee,
            amount
        );
        escrowTransfers.push(EscrowTransfer(
            {
                workflowId: workflowId,
                token: address(this), // This contract's token
                to: to, 
                from: _msgSender(), 
                amount: amountAfterFee,
                originalAmount: amount,
                escrowState: EscrowState.PENDING,
                senderStatus: SenderStatus.NONE,
                recipientStatus: RecipientStatus.NONE,
                disputeResolver: defaultResolver, // Will be overridden by settings if set
                autoReleaseTime: 0, // Will be set by _applyEscrowSettings
                autoCancelTime: 0, // Will be set by _applyEscrowSettings
                attachmentURIs: new string[](0),
                attachmentHashes: new bytes32[](0),
                // Phase 7: Initialize module snapshots (will be set after escrow is created)
                snapshotResolutionModule: address(0),
                snapshotReleaseStrategy: address(0),
                snapshotYieldGenerationModule: address(0),
                snapshotYieldDistributionModule: address(0)
            }));
        
        // Assert workflowId consistency: struct ID should match array index
        assert(escrowTransfers[workflowId].workflowId == workflowId);
        
        totalFees += fee;
        totalHeldInEscrow += amountAfterFee;
        totalEscrowsPending++;
        nextWorkflowId++;
        
        // Apply settings (this will set auto times correctly, applying defaults only if both are 0)
        _applyEscrowSettings(workflowId, settings);
        
        // Phase 7: Snapshot module addresses at creation time
        _snapshotModulesForEscrow(
            workflowId,
            address(getResolutionModule(workflowId)),
            address(getReleaseStrategy(workflowId)),
            address(getYieldGenerationModule(workflowId)),
            address(getYieldDistributionModule(workflowId))
        );
        
        // Phase 2: If yieldEnabled, deposit to Aave (handled in BaseEscrow._depositToAave)
        if (settings.yieldEnabled) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            if (address(genModule) != address(0) && genModule.isTokenSupported(address(this))) {
                // Approve Aave pool to spend tokens from this contract
                // The module's forceApprove sets allowance for the module, not the escrow contract
                // So we need to approve here using _approve to set allowance for this contract
                address aavePool = _getAavePoolAddress(genModule);
                if (aavePool != address(0)) {
                    _approve(address(this), aavePool, amountAfterFee);
                }
                genModule.depositForYield(workflowId, address(this), amountAfterFee);
            }
        }
        
        // Phase 1: Emit state change event (creation -> PENDING)
        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.PENDING);
        emit EscrowTransferCreated(workflowId, to, _msgSender(), amount);
        return workflowId;
    }

    /**
     * @notice Create an escrow transfer with custom auto-release or auto-cancel time
     * @param to Recipient address
     * @param amount Amount to escrow (after fee deduction)
     * @param autoReleaseTime Timestamp for automatic release (0 = no auto-release)
     * @param autoCancelTime Timestamp for automatic cancel (0 = no auto-cancel)
     * @return workflowId The ID of the created escrow transfer
     * @dev Backward compatibility wrapper for createEscrow
     */
    function timedEscrowTransfer(address to, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime) public whenNotPaused returns (uint256) {
        EscrowSettings memory settings = _getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;
        settings.autoCancelTime = autoCancelTime;
        return createEscrow(to, amount, settings);
    }

    /**
     * @notice Create a new escrow transfer
     * @param to Recipient address
     * @param amount Amount to escrow (fee will be deducted)
     * @return workflowId The ID of the created escrow transfer
     * @dev Backward compatibility wrapper for createEscrow with default settings
     */
    function escrowTransfer(address to, uint256 amount) public whenNotPaused returns (uint256) {
        EscrowSettings memory settings = _getDefaultSettings();
        return createEscrow(to, amount, settings);
    }


    /**
     * @notice Release escrow transfer with a single attachment
     * @param workflowId The escrow transfer ID
     * @param uri URI of the attachment (e.g., IPFS hash, URL)
     * @param hash Hash of the attachment content for verification
     * @return True if release was successful
     * @dev Adds the attachment to the escrow and immediately releases it. Only sender can call this.
     */
    // releaseEscrowTransferWithAttachment() and releaseEscrowTransferWithAttachmentSet() removed
    // Use addAttachment() then releaseEscrowTransfer() separately for contract size reduction

    /**
     * @notice Release escrow transfer to recipient (only sender can call)
     * @param workflowId The escrow transfer ID
     * @return success True if release was successful
     */
    function releaseEscrowTransfer(uint256 workflowId) public nonReentrant whenNotPaused returns (bool) {
        if (workflowId >= nextWorkflowId) {
            revert InvalidWorkflowId(workflowId, nextWorkflowId);
        }
        
        EscrowTransfer storage et = escrowTransfers[workflowId];

        if (et.escrowState != EscrowState.PENDING) {
            revert TransferNotPending(workflowId, et.escrowState);
        }
        
        if (et.from != _msgSender()) {
            revert NotSender(workflowId, _msgSender(), et.from);
        }
        
        _releaseEscrowTransfer(workflowId);
        return true;
    }

    
    // Implement abstract functions from BaseEscrow
    
    /**
     * @dev Transfer tokens using ERC20's internal _transfer
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param to Recipient address
     * @param amount Amount to transfer
     * @dev Overrides BaseEscrow._transferTokens. For EscrowableERC20, token must always be address(this).
     */
    function _transferTokens(address token, address to, uint256 amount) internal override {
        // For EscrowableERC20, token should always be address(this)
        require(token == address(this), "Invalid token");
        _transfer(address(this), to, amount);
    }
    
    /**
     * @dev Update escrow balance tracking
     * @param amount Amount to add or subtract
     * @param add True to add to totalHeldInEscrow, false to subtract
     * @dev Overrides BaseEscrow._updateEscrowBalance. Tracks total escrowed amount across all escrows.
     * @dev Note: token parameter is unused for EscrowableERC20 (always address(this))
     */
    function _updateEscrowBalance(address /* token */, uint256 amount, bool add) internal override {
        // For EscrowableERC20, we track total across all (single token)
        if (add) {
            totalHeldInEscrow += amount;
        } else {
            // Use unchecked to prevent underflow (amount should never exceed totalHeldInEscrow)
            unchecked {
                totalHeldInEscrow -= amount;
            }
        }
    }
    
    /**
     * @dev Emit EscrowTransferCancelled event
     * @param workflowId The escrow transfer ID
     * @param from Sender address
     * @param originalAmount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferCancelled. Emits event without token parameter.
     * @dev Note: token parameter is unused for EscrowableERC20
     */
    function _emitEscrowTransferCancelled(uint256 workflowId, address /* token */, address from, uint256 originalAmount) internal override {
        emit EscrowTransferCancelled(workflowId, from, originalAmount);
    }
    
    /**
     * @dev Emit EscrowTransferReleased event
     * @param workflowId The escrow transfer ID
     * @param to Recipient address
     * @param originalAmount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferReleased. Emits event without token parameter.
     * @dev Note: token parameter is unused for EscrowableERC20
     */
    function _emitEscrowTransferReleased(uint256 workflowId, address /* token */, address to, uint256 originalAmount) internal override {
        emit EscrowTransferReleased(workflowId, to, originalAmount);
    }

    /**
     * @dev Get the release strategy for an escrow
     * @param workflowId The escrow transfer ID
     * @return The release strategy module
     * @dev Phase 7: Returns snapshot module to ensure module changes only affect new escrows
     */
    function _getReleaseStrategy(uint256 workflowId) internal view returns (IReleaseStrategy) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        address snapshot = et.snapshotReleaseStrategy;
        return snapshot != address(0) ? IReleaseStrategy(snapshot) : defaultReleaseStrategy;
    }

    /**
     * @dev Get the resolution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The resolution module
     * @dev Phase 7: Returns snapshot module to ensure module changes only affect new escrows
     */
    function _getResolutionModule(uint256 workflowId) internal view returns (IResolutionModule) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        address snapshot = et.snapshotResolutionModule;
        return snapshot != address(0) ? IResolutionModule(snapshot) : defaultResolutionModule;
    }

    /**
     * @dev Get the yield generation module for an escrow (override from BaseEscrow)
     * @param workflowId The escrow transfer ID
     * @return The yield generation module interface
     * @dev Phase 7: Returns snapshot module to ensure module changes only affect new escrows
     */
    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldGenerationModule) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        address snapshot = et.snapshotYieldGenerationModule;
        return snapshot != address(0) ? IYieldGenerationModule(snapshot) : defaultYieldGenerationModule;
    }

    /**
     * @dev Get Aave pool address from AaveYieldGenerationModule using low-level call
     * @param module The yield generation module
     * @return poolAddress The Aave pool address
     */
    function _getAavePoolAddress(IYieldGenerationModule module) internal view returns (address poolAddress) {
        // Use low-level call to read the public aavePool variable
        // Public variables have auto-generated getters, so we can call the getter function
        bytes4 selector = bytes4(keccak256("aavePool()"));
        (bool success, bytes memory data) = address(module).staticcall(
            abi.encodeWithSelector(selector)
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    /**
     * @dev Get the yield distribution module for an escrow (override from BaseEscrow)
     * @param workflowId The escrow transfer ID
     * @return The yield distribution module interface
     * @dev Phase 7: Returns snapshot module to ensure module changes only affect new escrows
     */
    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        EscrowTransfer storage et = escrowTransfers[workflowId];
        address snapshot = et.snapshotYieldDistributionModule;
        return snapshot != address(0) ? IYieldDistributionModule(snapshot) : defaultYieldDistributionModule;
    }

    // Module getter functions
    /**
     * @notice Get the release strategy for an escrow
     * @param workflowId The escrow transfer ID
     * @return The release strategy module (or default if not set)
     */
    /**
     * @notice Get the release strategy for an escrow
     * @param workflowId The escrow transfer ID (unused, kept for interface compatibility)
     * @return The default release strategy module
     * @dev Per-escrow overrides removed in Phase 5. All escrows use default modules.
     */
    function getReleaseStrategy(uint256 workflowId) public view returns (IReleaseStrategy) {
        workflowId; // Silence unused parameter warning
        return defaultReleaseStrategy;
    }

    /**
     * @notice Get the resolution module for an escrow
     * @param workflowId The escrow transfer ID (unused, kept for interface compatibility)
     * @return The default resolution module
     * @dev Per-escrow overrides removed in Phase 5. All escrows use default modules.
     */
    function getResolutionModule(uint256 workflowId) public view returns (IResolutionModule) {
        workflowId; // Silence unused parameter warning
        return defaultResolutionModule;
    }

    /**
     * @notice Get the yield generation module for an escrow
     * @param workflowId The escrow transfer ID (unused, kept for interface compatibility)
     * @return The default yield generation module
     * @dev Per-escrow overrides removed in Phase 5. All escrows use default modules.
     */
    function getYieldGenerationModule(uint256 workflowId) public view returns (IYieldGenerationModule) {
        workflowId; // Silence unused parameter warning
        return defaultYieldGenerationModule;
    }

    /**
     * @notice Get the yield distribution module for an escrow
     * @param workflowId The escrow transfer ID (unused, kept for interface compatibility)
     * @return The default yield distribution module
     * @dev Per-escrow overrides removed in Phase 5. All escrows use default modules.
     */
    function getYieldDistributionModule(uint256 workflowId) public view returns (IYieldDistributionModule) {
        workflowId; // Silence unused parameter warning
        return defaultYieldDistributionModule;
    }

    // Module setter functions (only owner)
    // Per-escrow override functions removed in Phase 5 for mainnet credibility.
    // No governance actor can modify the rules of an existing escrow.
    // All escrows use the default modules configured via queue/activate pattern.

    /**
     * @notice Queue a new default release strategy (Slow lane: 7-day delay)
     * @param strategy The release strategy module address
     * @dev After 7 days, call activateDefaultReleaseStrategy() to apply the change
     */
    function queueDefaultReleaseStrategy(address strategy) public onlyRole(ROLE_TIMELOCK) {
        if (strategy == address(0) || strategy.code.length == 0) {
            revert InvalidAddress("Default release strategy must be a contract", strategy);
        }
        _queueAddress(_pendingDefaultReleaseStrategy, strategy);
        emit DefaultReleaseStrategyQueued(address(defaultReleaseStrategy), strategy, _pendingDefaultReleaseStrategy.eta);
    }

    /**
     * @notice Activate the queued default release strategy
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateDefaultReleaseStrategy() public onlyRole(ROLE_TIMELOCK) {
        address oldStrategy = address(defaultReleaseStrategy);
        defaultReleaseStrategy = IReleaseStrategy(_activateAddress(_pendingDefaultReleaseStrategy));
        emit DefaultReleaseStrategyActivated(oldStrategy, address(defaultReleaseStrategy));
    }

    /**
     * @notice Get pending default release strategy change (if any)
     * @return value Pending strategy address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingDefaultReleaseStrategy() public view returns (address value, uint64 eta, bool exists) {
        return (getPendingAddress(_pendingDefaultReleaseStrategy));
    }

    /**
     * @notice Queue a new default resolution module (Slow lane: 7-day delay)
     * @param module The resolution module address
     * @dev After 7 days, call activateDefaultResolutionModule() to apply the change
     */
    function queueDefaultResolutionModule(address module) public onlyRole(ROLE_TIMELOCK) {
        if (module == address(0) || module.code.length == 0) {
            revert InvalidAddress("Default resolution module must be a contract", module);
        }
        _queueAddress(_pendingDefaultResolutionModule, module);
        emit DefaultResolutionModuleQueued(address(defaultResolutionModule), module, _pendingDefaultResolutionModule.eta);
    }

    /**
     * @notice Activate the queued default resolution module
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateDefaultResolutionModule() public onlyRole(ROLE_TIMELOCK) {
        address oldModule = address(defaultResolutionModule);
        defaultResolutionModule = IResolutionModule(_activateAddress(_pendingDefaultResolutionModule));
        emit DefaultResolutionModuleActivated(oldModule, address(defaultResolutionModule));
    }

    /**
     * @notice Get pending default resolution module change (if any)
     * @return value Pending module address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingDefaultResolutionModule() public view returns (address value, uint64 eta, bool exists) {
        return (getPendingAddress(_pendingDefaultResolutionModule));
    }

    /**
     * @notice Queue a new default yield generation module (Slow lane: 7-day delay)
     * @param module The yield generation module address
     * @dev After 7 days, call activateDefaultYieldGenerationModule() to apply the change
     */
    function queueDefaultYieldGenerationModule(address module) public onlyRole(ROLE_TIMELOCK) {
        if (module == address(0)) {
            revert InvalidAddress("Default yield generation module cannot be zero", module);
        }
        if (module.code.length == 0) {
            revert InvalidAddress("Default yield generation module must be a contract", module);
        }
        // Validate module implements IYieldGenerationModule via ERC-165
        if (!IERC165(module).supportsInterface(type(IYieldGenerationModule).interfaceId)) {
            revert InvalidAddress("Module does not implement IYieldGenerationModule", module);
        }
        _queueAddress(_pendingDefaultYieldGenerationModule, module);
        emit DefaultYieldGenerationModuleQueued(address(defaultYieldGenerationModule), module, _pendingDefaultYieldGenerationModule.eta);
    }

    /**
     * @notice Activate the queued default yield generation module
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateDefaultYieldGenerationModule() public onlyRole(ROLE_TIMELOCK) {
        address oldModule = address(defaultYieldGenerationModule);
        defaultYieldGenerationModule = IYieldGenerationModule(_activateAddress(_pendingDefaultYieldGenerationModule));
        emit DefaultYieldGenerationModuleActivated(oldModule, address(defaultYieldGenerationModule));
        emit DefaultYieldGenerationModuleSet(address(defaultYieldGenerationModule));
    }

    /**
     * @notice Get pending default yield generation module change (if any)
     * @return value Pending module address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingDefaultYieldGenerationModule() public view returns (address value, uint64 eta, bool exists) {
        return (getPendingAddress(_pendingDefaultYieldGenerationModule));
    }

    /**
     * @notice Queue a new default yield distribution module (Slow lane: 7-day delay)
     * @param module The yield distribution module address
     * @dev After 7 days, call activateDefaultYieldDistributionModule() to apply the change
     */
    function queueDefaultYieldDistributionModule(address module) public onlyRole(ROLE_TIMELOCK) {
        if (module == address(0)) {
            revert InvalidAddress("Default yield distribution module cannot be zero", module);
        }
        if (module.code.length == 0) {
            revert InvalidAddress("Default yield distribution module must be a contract", module);
        }
        // Validate module implements IYieldDistributionModule via ERC-165
        if (!IERC165(module).supportsInterface(type(IYieldDistributionModule).interfaceId)) {
            revert InvalidAddress("Module does not implement IYieldDistributionModule", module);
        }
        _queueAddress(_pendingDefaultYieldDistributionModule, module);
        emit DefaultYieldDistributionModuleQueued(address(defaultYieldDistributionModule), module, _pendingDefaultYieldDistributionModule.eta);
    }

    /**
     * @notice Activate the queued default yield distribution module
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateDefaultYieldDistributionModule() public onlyRole(ROLE_TIMELOCK) {
        address oldModule = address(defaultYieldDistributionModule);
        defaultYieldDistributionModule = IYieldDistributionModule(_activateAddress(_pendingDefaultYieldDistributionModule));
        emit DefaultYieldDistributionModuleActivated(oldModule, address(defaultYieldDistributionModule));
        emit DefaultYieldDistributionModuleSet(address(defaultYieldDistributionModule));
    }

    /**
     * @notice Get pending default yield distribution module change (if any)
     * @return value Pending module address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingDefaultYieldDistributionModule() public view returns (address value, uint64 eta, bool exists) {
        return (getPendingAddress(_pendingDefaultYieldDistributionModule));
    }

    /**
     * @notice Withdraw accumulated escrow fees
     * @return True if withdrawal was successful
     * @dev Only the fee address can withdraw fees. Transfers all accumulated fees to the fee address.
     */
    function withdrawFees() public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) {
            revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        }
        uint256 fees = totalFees;
        if (fees == 0) {
            revert NoFeesToWithdraw(address(this), fees);
        }
        
        // State changes before external call (checks-effects-interactions)
        totalFees = 0;
        
        // External call after state changes
        _transfer(address(this), _msgSender(), fees);
        emit FeesWithdrawn(fees);
        return true;
    }

}

/**
 * @title EscrowableERC20Factory
 * @notice Factory contract for creating new EscrowableERC20 instances
 * @dev Allows deployment of new EscrowableERC20 tokens with custom parameters
 */
contract EscrowableERC20Factory {
    /**
     * @notice Create a new EscrowableERC20 token contract
     * @param name Token name
     * @param symbol Token symbol
     * @param escrowFee Escrow fee in basis points (e.g., 100 = 1%)
     * @param escrowFeeAddress Address to receive escrow fees
     * @return Address of the newly deployed EscrowableERC20 contract
     */
    function createEscrowableERC20(
        string memory name,
        string memory symbol,
        uint256 escrowFee,
        address escrowFeeAddress
    ) public returns (address) {
        return address(new EscrowableERC20(name, symbol, escrowFee, escrowFeeAddress));
    }
}
