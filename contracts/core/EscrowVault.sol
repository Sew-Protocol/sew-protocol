// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./BaseEscrow.sol";
import "../governance/SlowLaneQueueActivate.sol";
import "../libraries/ModuleManagementLibrary.sol";
import "../libraries/EscrowCreationLibrary.sol";
import "../libraries/RecoveryLibrary.sol";
import "../interfaces/IReleaseStrategy.sol";
import "../shared/interfaces/IResolutionModule.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title EscrowVault
 * @notice Multi-token escrow vault supporting any ERC20 token
 * @dev Extends BaseEscrow to provide escrow functionality for any ERC20 token.
 *      Users can create escrows for any supported ERC20 token, with support for disputes,
 *      attachments, yield generation via Aave, and modular release/resolution strategies.
 *      Tracks balances and fees per token.
 */
contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;

    // Track fees per token
    mapping(address => uint256) public totalFeesPerToken;
    // Track escrow balance per token (replaces totalHeldInEscrow)
    mapping(address => uint256) public totalHeldInEscrowPerToken;
    
    // Default module instances (per-escrow overrides removed in Phase 5 for mainnet credibility)
    IReleaseStrategy public defaultReleaseStrategy;
    IResolutionModule public defaultDisputeResolutionModule;
    IYieldGenerationModule public defaultYieldGenerationModule;
    IYieldDistributionModule public defaultYieldDistributionModule;

    // Slow lane pending changes (Phase 8: Lane consistency fix)
    PendingAddress private _pendingDefaultReleaseStrategy;
    PendingAddress private _pendingDefaultResolutionModule;
    PendingAddress private _pendingDefaultYieldGenerationModule;
    PendingAddress private _pendingDefaultYieldDistributionModule;

    // Events specific to EscrowVault (with token parameter)
    event EscrowTransferCreated(uint256 indexed workflowId, address indexed token, address indexed from, address to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed workflowId, address indexed token, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed workflowId, address indexed token, address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed token, uint256 amount);
    
    // Module events (per-escrow events removed in Phase 5)
    event DefaultYieldGenerationModuleSet(address indexed module);
    event DefaultYieldDistributionModuleSet(address indexed module);

    // Slow lane queue/activate events (Phase 8: Lane consistency fix)
    event DefaultReleaseStrategyQueued(address indexed oldStrategy, address indexed newStrategy, uint64 eta);
    event DefaultReleaseStrategyActivated(address indexed oldStrategy, address indexed newStrategy);
    event DefaultResolutionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event DefaultYieldGenerationModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultYieldGenerationModuleActivated(address indexed oldModule, address indexed newModule);
    event DefaultYieldDistributionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultYieldDistributionModuleActivated(address indexed oldModule, address indexed newModule);

    constructor(uint256 _escrowFee, address _escrowFeeAddress, address _yieldOps) SlowLaneQueueActivate() {
        if (_escrowFee > ESCROW_FEE_DENOMINATOR) {
            revert InvalidEscrowFee(_escrowFee, ESCROW_FEE_DENOMINATOR);
        }
        if (_escrowFeeAddress == address(0)) {
            revert InvalidAddress("Fee address cannot be zero", _escrowFeeAddress);
        }
        escrowFee = _escrowFee;
        escrowFeeAddress = _escrowFeeAddress;
        
        // Phase 1 size optimization: Set YieldOps contract
        yieldOps = YieldOps(_yieldOps);
        
        // Grant DEFAULT_ADMIN_ROLE to deployer so roles can be granted later
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    // createEscrowWithPermit() removed for contract size reduction - see docs/PERMIT_FUNCTIONALITY_REMOVED.md

    /**
     * @notice Create a new escrow with custom settings
     * @param token ERC20 token address to escrow
     * @param seller Recipient address (seller)
     * @param amount Amount to escrow (fee will be deducted)
     * @param settings Escrow settings (custom dispute resolver, yield, timing, etc.)
     * @return workflowId The ID of the created escrow transfer
     */
    function createEscrow(
        address token,
        address seller,
        uint256 amount,
        EscrowSettings memory settings
    ) public nonReentrant whenNotPaused returns (uint256) {
        // Input validation
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
        if (seller == address(0)) {
            revert InvalidAddress("Seller address cannot be zero", seller);
        }
        if (amount == 0) {
            revert InvalidAmount("Amount must be greater than zero");
        }
        
        // Validate settings
        _validateEscrowSettings(settings);
        
        uint256 fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR;
        uint256 amountAfterFee = amount - fee;

        // Check if sender has sufficient balance and allowance (view calls before state changes)
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(_msgSender());
        uint256 allowance = tokenContract.allowance(_msgSender(), address(this));
        
        if (balance < amount) {
            revert InsufficientTokenBalance({
                balance: balance,
                required: amount
            });
        }
        if (allowance < amount) {
            revert InsufficientTokenBalance({
                balance: allowance,
                required: amount
            });
        }

        // Transfer tokens from sender to this contract (external call before state changes)
        tokenContract.safeTransferFrom(_msgSender(), address(this), amount);
        
        // State changes after external call (checks-effects-interactions pattern)
        uint256 workflowId = nextWorkflowId;
        address defaultResolver = _getDisputeResolverForNewEscrow(
            workflowId,
            token,
            _msgSender(),
            seller,
            amountAfterFee,
            amount
        );
        
        // Get module addresses for snapshotting (before incrementing nextWorkflowId)
        address resolutionModule = address(getResolutionModule(workflowId));
        address releaseStrategy = address(getReleaseStrategy(workflowId));
        address yieldGenModule = address(getYieldGenerationModule(workflowId));
        address yieldDistModule = address(getYieldDistributionModule(workflowId));
        
        // Create escrow transfer struct using library
        EscrowTransfer memory newTransfer = EscrowCreationLibrary.createEscrowTransferStruct(
            workflowId,
            token,
            seller,
            _msgSender(),
            amount,
            amountAfterFee,
            defaultResolver,
            resolutionModule,
            releaseStrategy,
            yieldGenModule,
            yieldDistModule
        );
        escrowTransfers.push(newTransfer);
        assert(escrowTransfers[workflowId].workflowId == workflowId);
        totalFees += fee;
        totalFeesPerToken[token] += fee;
        totalHeldInEscrowPerToken[token] += amountAfterFee;
        totalEscrowsPending++;
        nextWorkflowId++;
        _applyEscrowSettings(workflowId, settings);
        // Emit module snapshot event (fields already set in struct)
        _snapshotModulesForEscrow(
            workflowId,
            resolutionModule,
            releaseStrategy,
            yieldGenModule,
            yieldDistModule
        );
        if (settings.yieldEnabled) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
                genModule.depositForYield(workflowId, token, amountAfterFee);
            }
        }
        
        // Phase 1: Emit state change event (creation -> PENDING)
        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.PENDING);
        emit EscrowTransferCreated(workflowId, token, _msgSender(), seller, amount);
        return workflowId;
    }

    /**
     * @notice Create an escrow with custom auto-release or auto-cancel time
     * @param token ERC20 token address to escrow
     * @param seller Recipient address (seller)
     * @param amount Amount to escrow (after fee deduction)
     * @param autoReleaseTime Timestamp for automatic release (0 = no auto-release)
     * @param autoCancelTime Timestamp for automatic cancel (0 = no auto-cancel)
     * @return workflowId The ID of the created escrow transfer
     * @dev Convenience function - calls main createEscrow with timing settings
     */
    function createEscrow(address token, address seller, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime) public nonReentrant whenNotPaused returns (uint256) {
        EscrowSettings memory settings = _getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;
        settings.autoCancelTime = autoCancelTime;
        return createEscrow(token, seller, amount, settings);
    }

    /**
     * @notice Create a new escrow with default settings
     * @param token ERC20 token address to escrow
     * @param seller Recipient address (seller)
     * @param amount Amount to escrow (fee will be deducted)
     * @return workflowId The ID of the created escrow transfer
     * @dev Convenience function - calls main createEscrow with default settings
     */
    function createEscrow(address token, address seller, uint256 amount) public whenNotPaused returns (uint256) {
        return createEscrow(token, seller, amount, _getDefaultSettings());
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
     * @dev Transfer tokens using SafeERC20
     * @param token ERC20 token address
     * @param to Recipient address
     * @param amount Amount to transfer
     * @dev Overrides BaseEscrow._transferTokens. Uses SafeERC20 for safe token transfers.
     */
    function _transferTokens(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }
    
    /**
     * @dev Update escrow balance tracking per token
     * @param token ERC20 token address
     * @param amount Amount to add or subtract
     * @param add True to add to totalHeldInEscrowPerToken, false to subtract
     * @dev Overrides BaseEscrow._updateEscrowBalance. Tracks escrowed amounts per token.
     */
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        if (add) {
            totalHeldInEscrowPerToken[token] += amount;
        } else {
            totalHeldInEscrowPerToken[token] -= amount;
        }
    }
    
    /**
     * @dev Emit EscrowTransferCancelled event
     * @param workflowId The escrow transfer ID
     * @param token ERC20 token address
     * @param from Sender address
     * @param originalAmount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferCancelled. Emits event with token parameter.
     */
    function _emitEscrowTransferCancelled(uint256 workflowId, address token, address from, uint256 originalAmount) internal override {
        emit EscrowTransferCancelled(workflowId, token, from, originalAmount);
    }
    
    /**
     * @dev Emit EscrowTransferReleased event
     * @param workflowId The escrow transfer ID
     * @param token ERC20 token address
     * @param to Recipient address
     * @param originalAmount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferReleased. Emits event with token parameter.
     */
    function _emitEscrowTransferReleased(uint256 workflowId, address token, address to, uint256 originalAmount) internal override {
        emit EscrowTransferReleased(workflowId, token, to, originalAmount);
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
        return snapshot != address(0) ? IResolutionModule(snapshot) : defaultDisputeResolutionModule;
    }

    /**
     * @dev Override BaseEscrow's _getDisputeResolverForNewEscrow to use defaultDisputeResolutionModule
     * @param workflowId The escrow transfer ID
     * @param token Token address
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount after fee
     * @param originalAmount Original amount before fee
     * @return disputeResolver The dispute resolver address
     */
    function _getDisputeResolverForNewEscrow(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 originalAmount
    ) internal view override returns (address) {
        // Always use defaultDisputeResolutionModule
        if (address(defaultDisputeResolutionModule) == address(0)) {
            revert ResolutionModuleNotConfigured();
        }

        bytes memory escrowData = _encodeResolutionData(token, from, to, amount, originalAmount);
        try IResolutionModule(defaultDisputeResolutionModule).getDisputeResolver(workflowId, escrowData) returns (address disputeResolver, uint8 /* escalationLevel */) {
            if (disputeResolver == address(0)) {
                revert ResolutionModuleReturnedZeroAddress();
            }
            return disputeResolver;
        } catch {
            revert ResolutionModuleCallFailed();
        }
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
        return defaultDisputeResolutionModule;
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

    // Per-escrow override functions removed in Phase 5 for mainnet credibility.
    // No governance actor can modify the rules of an existing escrow.
    // All escrows use the default modules configured via queue/activate pattern.

    /**
     * @notice Queue a new default release strategy (Slow lane: 7-day delay)
     * @param strategy The release strategy module address
     * @dev After 7 days, call activateDefaultReleaseStrategy() to apply the change
     */
    function queueDefaultReleaseStrategy(address strategy) public onlyRole(ROLE_TIMELOCK) {
        ModuleManagementLibrary.validateModule(strategy, ModuleManagementLibrary.ModuleConfig({
            requireContract: true,
            allowZero: false,
            interfaceId: bytes4(0),
            moduleName: "release strategy"
        }));
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
        return getPendingAddress(_pendingDefaultReleaseStrategy);
    }

    /**
     * @notice Queue a new default resolution module (Slow lane: 7-day delay)
     * @param module The resolution module address
     * @dev After 7 days, call activateDefaultResolutionModule() to apply the change
     */
    function queueDefaultResolutionModule(address module) public onlyRole(ROLE_TIMELOCK) {
        ModuleManagementLibrary.validateModule(module, ModuleManagementLibrary.ModuleConfig({
            requireContract: true,
            allowZero: false,
            interfaceId: bytes4(0),
            moduleName: "resolution module"
        }));
        _queueAddress(_pendingDefaultResolutionModule, module);
        emit DefaultResolutionModuleQueued(address(defaultDisputeResolutionModule), module, _pendingDefaultResolutionModule.eta);
    }

    /**
     * @notice Activate the queued default resolution module
     * @dev Reverts if no pending change or 7-day delay has not elapsed
     */
    function activateDefaultResolutionModule() public onlyRole(ROLE_TIMELOCK) {
        address oldModule = address(defaultDisputeResolutionModule);
        defaultDisputeResolutionModule = IResolutionModule(_activateAddress(_pendingDefaultResolutionModule));
        emit DefaultResolutionModuleActivated(oldModule, address(defaultDisputeResolutionModule));
    }

    /**
     * @notice Get pending default resolution module change (if any)
     * @return value Pending module address
     * @return eta Timestamp when activation is allowed
     * @return exists Whether a pending change exists
     */
    function getPendingDefaultResolutionModule() public view returns (address value, uint64 eta, bool exists) {
        return getPendingAddress(_pendingDefaultResolutionModule);
    }

    /**
     * @notice Queue a new default yield generation module (Slow lane: 7-day delay)
     * @param module The yield generation module address
     * @dev After 7 days, call activateDefaultYieldGenerationModule() to apply the change
     */
    function queueDefaultYieldGenerationModule(address module) public onlyRole(ROLE_TIMELOCK) {
        ModuleManagementLibrary.validateModule(module, ModuleManagementLibrary.ModuleConfig({
            requireContract: true,
            allowZero: false,
            interfaceId: type(IYieldGenerationModule).interfaceId,
            moduleName: "yield generation module"
        }));
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
        return getPendingAddress(_pendingDefaultYieldGenerationModule);
    }

    /**
     * @notice Queue a new default yield distribution module (Slow lane: 7-day delay)
     * @param module The yield distribution module address
     * @dev After 7 days, call activateDefaultYieldDistributionModule() to apply the change
     */
    function queueDefaultYieldDistributionModule(address module) public onlyRole(ROLE_TIMELOCK) {
        ModuleManagementLibrary.validateModule(module, ModuleManagementLibrary.ModuleConfig({
            requireContract: true,
            allowZero: false,
            interfaceId: type(IYieldDistributionModule).interfaceId,
            moduleName: "yield distribution module"
        }));
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
        return getPendingAddress(_pendingDefaultYieldDistributionModule);
    }

    /**
     * @notice Withdraw accumulated fees for a specific token
     * @param token ERC20 token address
     * @return success True if withdrawal was successful
     * @dev Calls withdrawFeesBatch with single token array
     */
    function withdrawFees(address token) public returns (bool) {
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
        // Check authorization first (before checking fees)
        if (_msgSender() != escrowFeeAddress) {
            revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        }
        uint256 fees = totalFeesPerToken[token];
        if (fees == 0) {
            revert NoFeesToWithdraw(token, fees);
        }
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return withdrawFeesBatch(tokens);
    }
    
    /**
     * @notice Batch withdraw fees for multiple tokens
     * @param tokens Array of ERC20 token addresses
     * @return success True if batch withdrawal was successful
     */
    function withdrawFeesBatch(address[] memory tokens) public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) {
            revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            uint256 fees = totalFeesPerToken[token];
            if (fees > 0) {
                totalFeesPerToken[token] = 0;
                totalFees -= fees;
                IERC20(token).safeTransfer(_msgSender(), fees);
                emit FeesWithdrawn(token, fees);
            }
        }
        return true;
    }
    
    /**
     * @notice Get escrow balance and fees for a specific token
     * @param token ERC20 token address
     * @return balance Total amount currently held in escrow for the token
     * @return fees Total fees accumulated for the token (available for withdrawal)
     */
    function getTokenInfo(address token) public view returns (uint256 balance, uint256 fees) {
        return (totalHeldInEscrowPerToken[token], totalFeesPerToken[token]);
    }

    /**
     * @notice Recover ERC20 tokens sent directly to the contract by mistake
     * @param token ERC20 token address
     * @param recipient Address to receive the recovered tokens
     * @param amount Amount of tokens to recover (0 = recover all available)
     * @dev Overrides BaseEscrow.recoverERC20 to add validation that we're not recovering
     *      tracked fees or escrowed amounts. Only recovers tokens sent directly to the contract.
     */
    function recoverERC20(address token, address recipient, uint256 amount) 
        external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) 
    {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = tokenContract.balanceOf(address(this));
        uint256 escrowed = totalHeldInEscrowPerToken[token];
        uint256 fees = totalFeesPerToken[token];
        
        // Calculate available amount (balance minus escrowed funds and fees)
        uint256 available = balance;
        if (available >= escrowed) {
            available -= escrowed;
        } else {
            // Edge case: balance is less than tracked escrowed (shouldn't happen, but be safe)
            available = 0;
        }
        if (available >= fees) {
            available -= fees;
        } else {
            available = 0;
        }
        
        // Determine recover amount
        uint256 recoverAmount = amount == 0 ? available : amount;
        
        // Validate we're not trying to recover more than available
        require(recoverAmount <= available, "Cannot recover escrowed funds or fees");
        require(recoverAmount > 0, "No tokens available to recover");
        
        // Use RecoveryLibrary for the actual transfer
        uint256 actualRecovered = RecoveryLibrary.recoverERC20(token, recipient, recoverAmount, balance);
        emit ERC20Recovered(token, recipient, actualRecovered);
        return true;
    }
}
