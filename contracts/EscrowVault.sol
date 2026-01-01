// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./BaseEscrow.sol";
import "./interfaces/IReleaseStrategy.sol";
import "./interfaces/IResolutionModule.sol";
import "./interfaces/IYieldGenerationModule.sol";
import "./interfaces/IYieldDistributionModule.sol";
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
    
    // Module registries
    mapping(uint256 => address) public releaseStrategyForEscrow;
    mapping(uint256 => address) public resolutionModuleForEscrow;
    
    // Yield generation module registries
    mapping(uint256 => address) public yieldGenerationModuleForEscrow;
    IYieldGenerationModule public defaultYieldGenerationModule;
    
    // Yield distribution module registries
    mapping(uint256 => address) public yieldDistributionModuleForEscrow;
    IYieldDistributionModule public defaultYieldDistributionModule;
    
    // Default module instances (other modules)
    IReleaseStrategy public defaultReleaseStrategy;
    IResolutionModule public defaultResolutionModule;

    // Events specific to EscrowVault (with token parameter)
    event EscrowTransferCreated(uint256 indexed workflowId, address indexed token, address indexed from, address to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed workflowId, address indexed token, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed workflowId, address indexed token, address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed token, uint256 amount);
    
    // Module events
    event YieldGenerationModuleSet(uint256 indexed workflowId, address indexed module);
    event DefaultYieldGenerationModuleSet(address indexed module);
    event YieldDistributionModuleSet(uint256 indexed workflowId, address indexed module);
    event DefaultYieldDistributionModuleSet(address indexed module);

    constructor(uint256 _escrowFee, address _escrowFeeAddress) Ownable(_msgSender()) {
        if (_escrowFee > ESCROW_FEE_DENOMINATOR) {
            revert InvalidEscrowFee(_escrowFee, ESCROW_FEE_DENOMINATOR);
        }
        if (_escrowFeeAddress == address(0)) {
            revert InvalidAddress("Fee address cannot be zero", _escrowFeeAddress);
        }
        escrowFee = _escrowFee;
        escrowFeeAddress = _escrowFeeAddress;
        authorizedResolver = _msgSender();
    }

    // createEscrowWithPermit() removed for contract size reduction - see docs/PERMIT_FUNCTIONALITY_REMOVED.md

    /**
     * @notice Create a new escrow with custom settings
     * @param token ERC20 token address to escrow
     * @param to Recipient address
     * @param amount Amount to escrow (fee will be deducted)
     * @param settings Escrow settings (custom resolver, yield, timing, etc.)
     * @return workflowId The ID of the created escrow transfer
     */
    function createEscrow(
        address token,
        address to,
        uint256 amount,
        EscrowSettings memory settings
    ) public nonReentrant whenNotPaused returns (uint256) {
        // Input validation
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
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
            to,
            amountAfterFee,
            amount
        );
        escrowTransfers.push(EscrowTransfer(
            {
                workflowId: workflowId,
                token: token,
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
                attachmentHashes: new bytes32[](0)
            }));
        
        // Assert workflowId consistency: struct ID should match array index
        assert(escrowTransfers[workflowId].workflowId == workflowId);
        
        totalFees += fee;
        totalFeesPerToken[token] += fee;
        totalHeldInEscrowPerToken[token] += amountAfterFee;
        totalEscrowsPending++;
        nextWorkflowId++;
        
        // Apply settings (this will override defaults set above)
        _applyEscrowSettings(workflowId, settings);
        
        // Phase 2: If yieldEnabled, deposit to Aave (handled in BaseEscrow._depositToAave)
        if (settings.yieldEnabled) {
            IYieldGenerationModule genModule = _getYieldGenerationModule(workflowId);
            if (address(genModule) != address(0) && genModule.isTokenSupported(token)) {
                genModule.depositForYield(workflowId, token, amountAfterFee);
            }
        }
        
        // Phase 1: Emit state change event (creation -> PENDING)
        emit EscrowStateChanged(workflowId, EscrowState.PENDING, EscrowState.PENDING);
        emit EscrowTransferCreated(workflowId, token, _msgSender(), to, amount);
        return workflowId;
    }

    /**
     * @notice Create an escrow transfer with custom auto-release or auto-cancel time
     * @param token ERC20 token address to escrow
     * @param to Recipient address
     * @param amount Amount to escrow (after fee deduction)
     * @param autoReleaseTime Timestamp for automatic release (0 = no auto-release)
     * @param autoCancelTime Timestamp for automatic cancel (0 = no auto-cancel)
     * @return workflowId The ID of the created escrow transfer
     * @dev Backward compatibility wrapper for createEscrow
     */
    function timedEscrowTransfer(address token, address to, uint256 amount, uint256 autoReleaseTime, uint256 autoCancelTime) public nonReentrant whenNotPaused returns (uint256) {
        EscrowSettings memory settings = _getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;
        settings.autoCancelTime = autoCancelTime;
        return createEscrow(token, to, amount, settings);
    }

    /**
     * @notice Create a new escrow transfer for any ERC20 token
     * @param token ERC20 token address to escrow
     * @param to Recipient address
     * @param amount Amount to escrow (fee will be deducted)
     * @return workflowId The ID of the created escrow transfer
     * @dev Backward compatibility wrapper for createEscrow with default settings
     */
    function escrowTransfer(address token, address to, uint256 amount) public whenNotPaused returns (uint256) {
        EscrowSettings memory settings = _getDefaultSettings();
        return createEscrow(token, to, amount, settings);
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
     * @dev Get the yield generation module for an escrow (override from BaseEscrow)
     * @param workflowId The escrow transfer ID
     * @return The yield generation module interface
     * @dev Overrides BaseEscrow._getYieldGenerationModule. Returns escrow-specific module or default.
     */
    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldGenerationModule) {
        return getYieldGenerationModule(workflowId);
    }

    /**
     * @dev Get the yield distribution module for an escrow (override from BaseEscrow)
     * @param workflowId The escrow transfer ID
     * @return The yield distribution module interface
     * @dev Overrides BaseEscrow._getYieldDistributionModule. Returns escrow-specific module or default.
     */
    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        return getYieldDistributionModule(workflowId);
    }

    // Module getter functions
    /**
     * @notice Get the release strategy for an escrow
     * @param workflowId The escrow transfer ID
     * @return The release strategy module (or default if not set)
     */
    function getReleaseStrategy(uint256 workflowId) public view returns (IReleaseStrategy) {
        address module = releaseStrategyForEscrow[workflowId];
        return module != address(0) ? IReleaseStrategy(module) : defaultReleaseStrategy;
    }

    /**
     * @notice Get the resolution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The resolution module (or default if not set)
     */
    function getResolutionModule(uint256 workflowId) public view returns (IResolutionModule) {
        address module = resolutionModuleForEscrow[workflowId];
        return module != address(0) ? IResolutionModule(module) : defaultResolutionModule;
    }

    /**
     * @notice Get the yield generation module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The yield generation module (or default if not set)
     */
    function getYieldGenerationModule(uint256 workflowId) public view returns (IYieldGenerationModule) {
        address module = yieldGenerationModuleForEscrow[workflowId];
        return module != address(0) ? IYieldGenerationModule(module) : defaultYieldGenerationModule;
    }

    /**
     * @notice Get the yield distribution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The yield distribution module (or default if not set)
     */
    function getYieldDistributionModule(uint256 workflowId) public view returns (IYieldDistributionModule) {
        address module = yieldDistributionModuleForEscrow[workflowId];
        return module != address(0) ? IYieldDistributionModule(module) : defaultYieldDistributionModule;
    }

    // Module setter functions (only owner)
    /**
     * @notice Set the release strategy for a specific escrow
     * @param workflowId The escrow transfer ID
     * @param strategy The release strategy module address
     */
    function setReleaseStrategyForEscrow(uint256 workflowId, address strategy) public onlyOwner {
        if (strategy != address(0) && strategy.code.length == 0) {
            revert InvalidAddress("Release strategy must be a contract or zero", strategy);
        }
        releaseStrategyForEscrow[workflowId] = strategy;
    }

    /**
     * @notice Set the resolution module for a specific escrow
     * @param workflowId The escrow transfer ID
     * @param module The resolution module address
     */
    function setResolutionModuleForEscrow(uint256 workflowId, address module) public onlyOwner {
        if (module != address(0) && module.code.length == 0) {
            revert InvalidAddress("Resolution module must be a contract or zero", module);
        }
        resolutionModuleForEscrow[workflowId] = module;
    }

    /**
     * @notice Set the yield generation module for a specific escrow
     * @param workflowId The escrow transfer ID
     * @param module The yield generation module address
     */
    function setYieldGenerationModuleForEscrow(uint256 workflowId, address module) public onlyOwner {
        if (module != address(0)) {
            // Validate module implements IYieldGenerationModule via ERC-165
            if (module.code.length == 0) {
                revert InvalidAddress("Yield generation module must be a contract or zero", module);
            }
            if (!IERC165(module).supportsInterface(type(IYieldGenerationModule).interfaceId)) {
                revert InvalidAddress("Module does not implement IYieldGenerationModule", module);
            }
        }
        yieldGenerationModuleForEscrow[workflowId] = module;
        emit YieldGenerationModuleSet(workflowId, module);
    }

    /**
     * @notice Set the yield distribution module for a specific escrow
     * @param workflowId The escrow transfer ID
     * @param module The yield distribution module address
     */
    function setYieldDistributionModuleForEscrow(uint256 workflowId, address module) public onlyOwner {
        if (module != address(0)) {
            // Validate module implements IYieldDistributionModule via ERC-165
            if (module.code.length == 0) {
                revert InvalidAddress("Yield distribution module must be a contract or zero", module);
            }
            if (!IERC165(module).supportsInterface(type(IYieldDistributionModule).interfaceId)) {
                revert InvalidAddress("Module does not implement IYieldDistributionModule", module);
            }
        }
        yieldDistributionModuleForEscrow[workflowId] = module;
        emit YieldDistributionModuleSet(workflowId, module);
    }

    /**
     * @notice Set the default release strategy
     * @param strategy The release strategy module address
     */
    function setDefaultReleaseStrategy(address strategy) public onlyOwner {
        if (strategy == address(0) || strategy.code.length == 0) {
            revert InvalidAddress("Default release strategy must be a contract", strategy);
        }
        defaultReleaseStrategy = IReleaseStrategy(strategy);
    }

    /**
     * @notice Set the default resolution module
     * @param module The resolution module address
     */
    function setDefaultResolutionModule(address module) public onlyOwner {
        if (module == address(0) || module.code.length == 0) {
            revert InvalidAddress("Default resolution module must be a contract", module);
        }
        defaultResolutionModule = IResolutionModule(module);
    }

    /**
     * @notice Set the default yield generation module
     * @param module The yield generation module address
     */
    function setDefaultYieldGenerationModule(address module) public onlyOwner {
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
        defaultYieldGenerationModule = IYieldGenerationModule(module);
        emit DefaultYieldGenerationModuleSet(module);
    }

    /**
     * @notice Set the default yield distribution module
     * @param module The yield distribution module address
     */
    function setDefaultYieldDistributionModule(address module) public onlyOwner {
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
        defaultYieldDistributionModule = IYieldDistributionModule(module);
        emit DefaultYieldDistributionModuleSet(module);
    }

    /**
     * @notice Withdraw accumulated fees for a specific token
     * @param token ERC20 token address
     * @return success True if withdrawal was successful
     */
    function withdrawFees(address token) public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) {
            revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        }
        if (token == address(0)) {
            revert InvalidAddress("Token address cannot be zero", token);
        }
        uint256 fees = totalFeesPerToken[token];
        if (fees == 0) {
            revert NoFeesToWithdraw(token, fees);
        }
        
        // State changes before external call (checks-effects-interactions)
        totalFeesPerToken[token] = 0;
        totalFees -= fees;
        
        // External call after state changes
        IERC20(token).safeTransfer(_msgSender(), fees);
        emit FeesWithdrawn(token, fees);
        return true;
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
            if (token == address(0)) {
                continue; // Skip invalid tokens
            }
            uint256 fees = totalFeesPerToken[token];
            if (fees > 0) {
                // State changes before external call (checks-effects-interactions)
                totalFeesPerToken[token] = 0;
                totalFees -= fees;
                
                // External call after state changes
                IERC20(token).safeTransfer(_msgSender(), fees);
                emit FeesWithdrawn(token, fees);
            }
        }
        return true;
    }
    
    /**
     * @notice Get total escrow balance for a specific token
     * @param token ERC20 token address
     * @return Total amount currently held in escrow for the token
     */
    function getEscrowBalance(address token) public view returns (uint256) {
        return totalHeldInEscrowPerToken[token];
    }
    
    /**
     * @notice Get total accumulated fees for a specific token
     * @param token ERC20 token address
     * @return Total fees accumulated for the token (available for withdrawal)
     */
    function getTotalFeesByToken(address token) public view returns (uint256) {
        return totalFeesPerToken[token];
    }
}
