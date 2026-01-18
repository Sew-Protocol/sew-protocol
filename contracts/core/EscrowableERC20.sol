// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../interfaces/IModuleRegistry.sol';
import '../libraries/RecoveryLibrary.sol';

/**
 * @title EscrowableERC20
 * @notice ERC20 token with built-in escrow functionality
 * @dev Extends ERC20 and BaseEscrow to provide escrow capabilities for the token itself.
 *      Users can create escrows using this contract's tokens, with support for disputes,
 *      attachments, yield generation via Aave, and modular release/resolution strategies.
 *      Token parameter is always address(this) - single token escrow contract.
 */
contract EscrowableERC20 is ERC20, BaseEscrow {
    uint256 public constant INITIAL_SUPPLY = 1000000000000000000000000; // 1,000,000 tokens with 18 decimals
    
    /// @notice Default yield protocol fee (30%)
    uint256 public constant DEFAULT_YIELD_PROTOCOL_FEE_BPS = 3000; // 30% default
    
    // Single token tracking (not per-token like EscrowVault)
    uint256 public totalHeldInEscrow = 0;
    uint256 public totalFees = 0;
    
    // Default module instances
    IReleaseStrategy public defaultReleaseStrategy;
    IResolutionModule public defaultDisputeResolutionModule;
    IYieldGenerationModule public defaultYieldGenerationModule;
    IYieldDistributionModule public defaultYieldDistributionModule;
    
    // Module registry for validation (optional - if not set, validation skipped)
    IModuleRegistry public moduleRegistry;

    // Events specific to EscrowableERC20 (without token parameter since token is always address(this))
    event EscrowTransferCreated(uint256 indexed workflowId, address indexed from, address indexed to, uint256 amount);
    event EscrowTransferReleased(uint256 indexed workflowId, address indexed to, uint256 amount);
    event EscrowTransferCancelled(uint256 indexed workflowId, address indexed from, uint256 amount);
    event FeesWithdrawn(uint256 amount);
    
    // Module events
    event DefaultReleaseStrategyQueued(address indexed oldStrategy, address indexed newStrategy, uint64 eta);
    event DefaultReleaseStrategyActivated(address indexed oldStrategy, address indexed newStrategy);
    event DefaultResolutionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultResolutionModuleActivated(address indexed oldModule, address indexed newModule);
    event DefaultYieldGenerationModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultYieldGenerationModuleActivated(address indexed oldModule, address indexed newModule);
    event DefaultYieldDistributionModuleQueued(address indexed oldModule, address indexed newModule, uint64 eta);
    event DefaultYieldDistributionModuleActivated(address indexed oldModule, address indexed newModule);

    /// @dev Legacy slow-lane functions are disabled; use ModuleManagementContract.
    error UseModuleManagementContract();

    constructor(
        string memory name,
        string memory symbol,
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress
    ) ERC20(name, symbol) {
        // Validate escrow fee is within allowed range (0 to 2%)
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) {
            revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        }
        if (feeAddress == address(0)) revert InvalidAddress('Fee address cannot be zero', feeAddress);
        if (yieldOpsAddress == address(0)) revert InvalidAddress('YieldOps address cannot be zero', yieldOpsAddress);
        if (disputeOpsAddress == address(0)) revert InvalidAddress('DisputeOps address cannot be zero', disputeOpsAddress);

        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ROLE_TIMELOCK, _msgSender());

        // Initialize protocol fees with validation
        uint256 initialYieldFee = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
        uint256 initialAppealFee = 0; // 0% default
        
        if (initialYieldFee > MAX_PROTOCOL_FEE_BPS) {
            revert FeeExceedsMaximum(initialYieldFee, MAX_PROTOCOL_FEE_BPS);
        }
        if (initialAppealFee > MAX_PROTOCOL_FEE_BPS) {
            revert FeeExceedsMaximum(initialAppealFee, MAX_PROTOCOL_FEE_BPS);
        }
        
        yieldProtocolFeeBps = initialYieldFee;
        appealBondProtocolFeeBps = initialAppealFee;

        // Initialize timeout config
        timeoutConfig = TimeoutConfig({
            defaultAutoReleaseTime: 0,
            defaultAutoCancelTime: 0,
            maxDisputeDuration: 90 days,
            appealWindowDuration: 2 days
        });
        
        // Mint initial supply to deployer
        _mint(_msgSender(), INITIAL_SUPPLY);
    }

    // ============ Convenience Functions ============

    /**
     * @notice Create a new escrow with default settings
     * @param seller Recipient address (seller)
     * @param amount Amount to escrow (fee will be deducted)
     * @return workflowId The ID of the created escrow transfer
     * @dev Convenience function - calls BaseEscrow.createEscrow with address(this) as token
     */
    function createEscrow(address seller, uint256 amount) public whenNotPaused returns (uint256) {
        return createEscrow(address(this), seller, amount, SettingsValidationLibrary.getDefaultSettings());
    }

    /**
     * @notice Create an escrow with custom auto-release or auto-cancel time
     * @param seller Recipient address (seller)
     * @param amount Amount to escrow (after fee deduction)
     * @param autoReleaseTime Timestamp for automatic release (0 = no auto-release)
     * @param autoCancelTime Timestamp for automatic cancel (0 = no auto-cancel)
     * @return workflowId The ID of the created escrow transfer
     * @dev Convenience function - calls BaseEscrow.createEscrow with timing settings
     */
    function createEscrow(
        address seller,
        uint256 amount,
        uint256 autoReleaseTime,
        uint256 autoCancelTime
    ) public whenNotPaused returns (uint256) {
        EscrowSettings memory settings = SettingsValidationLibrary.getDefaultSettings();
        settings.autoReleaseTime = autoReleaseTime;
        settings.autoCancelTime = autoCancelTime;
        return createEscrow(address(this), seller, amount, settings);
    }

    // ============ BaseEscrow Hook Implementations ============

    /**
     * @dev Transfer tokens from sender to contract using ERC20's internal _transfer
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param from Sender address
     * @param amount Amount to transfer
     * @dev Overrides BaseEscrow._pullTokens. For EscrowableERC20, token must always be address(this).
     */
    function _pullTokens(address token, address from, uint256 amount) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        // Transfer from sender to contract using ERC20's internal _transfer
        _transfer(from, address(this), amount);
    }

    /**
     * @dev Record fee in totalFees (single token tracking)
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param amount Fee amount to record
     * @dev Overrides BaseEscrow._recordFee. Tracks fees in single totalFees variable.
     */
    function _recordFee(address token, uint256 amount) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        // MED-4: Prevent overflow when accumulating fees
        // currentFees is the current total accumulated fees before adding the new fee
        uint256 currentFees = totalFees;
        if (amount > type(uint256).max - currentFees) {
            revert InvalidAmount('Fee accumulation would overflow');
        }
        totalFees = currentFees + amount;
    }

    /**
     * @dev Transfer tokens using ERC20's internal _transfer
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param to Recipient address
     * @param amount Amount to transfer
     * @dev Overrides BaseEscrow._transferTokens. For EscrowableERC20, token must always be address(this).
     */
    function _transferTokens(address token, address to, uint256 amount) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        _transfer(address(this), to, amount);
    }

    /**
     * @dev Update escrow balance tracking
     * @param token Token address (must be address(this) for EscrowableERC20)
     * @param amount Amount to add or subtract
     * @param add True to add to totalHeldInEscrow, false to subtract
     * @dev Overrides BaseEscrow._updateEscrowBalance. Tracks total escrowed amount across all escrows.
     */
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        // MED-3: Input validation
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        
        if (add) {
            totalHeldInEscrow += amount;
        } else {
            // CRIT-1: Prevent underflow that could break accounting
            if (totalHeldInEscrow < amount) {
                revert BalanceUnderflow(token, totalHeldInEscrow, amount);
            }
            totalHeldInEscrow -= amount;
        }
    }

    /**
     * @dev Emit EscrowTransferCreated event (without token parameter)
     * @param workflowId The escrow transfer ID
     * @param token Token address (must be address(this))
     * @param from Sender address
     * @param to Recipient address
     * @param amount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferCreated. Emits event without token parameter.
     */
    function _emitEscrowTransferCreated(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        emit EscrowTransferCreated(workflowId, from, to, amount);
    }

    /**
     * @dev Emit EscrowTransferCancelled event (without token parameter)
     * @param workflowId The escrow transfer ID
     * @param token Token address (must be address(this))
     * @param from Sender address
     * @param amount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferCancelled. Emits event without token parameter.
     */
    function _emitEscrowTransferCancelled(
        uint256 workflowId,
        address token,
        address from,
        uint256 amount
    ) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        emit EscrowTransferCancelled(workflowId, from, amount);
    }

    /**
     * @dev Emit EscrowTransferReleased event (without token parameter)
     * @param workflowId The escrow transfer ID
     * @param token Token address (must be address(this))
     * @param to Recipient address
     * @param amount Original escrow amount
     * @dev Overrides BaseEscrow._emitEscrowTransferReleased. Emits event without token parameter.
     */
    function _emitEscrowTransferReleased(
        uint256 workflowId,
        address token,
        address to,
        uint256 amount
    ) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        emit EscrowTransferReleased(workflowId, to, amount);
    }

    /**
     * @dev Delegate yield deposit to module
     * @param generationModule Yield generation module
     * @param workflowId The escrow transfer ID
     * @param token Token address (must be address(this))
     * @param amount Amount to deposit
     * @dev Overrides BaseEscrow._depositForYield. Delegates to generationModule's depositForYield().
     */
    function _depositForYield(
        IYieldGenerationModule generationModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal override {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        generationModule.depositForYield(workflowId, token, amount);
    }

    // ============ Module Getters ============

    /**
     * @dev Get the release strategy for an escrow
     * @param workflowId The escrow transfer ID
     * @return The release strategy module (from snapshot or default)
     */
    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        address snapshot = moduleSnapshots[workflowId].releaseStrategy;
        return snapshot != address(0) ? IReleaseStrategy(snapshot) : defaultReleaseStrategy;
    }

    /**
     * @dev Get the resolution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The resolution module (from snapshot or default or BaseEscrow's disputeResolutionModule)
     */
    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        address snapshot = moduleSnapshots[workflowId].resolutionModule;
        if (snapshot != address(0)) {
            return IResolutionModule(snapshot);
        }
        // Fall back to defaultDisputeResolutionModule if set, otherwise BaseEscrow's disputeResolutionModule
        if (address(defaultDisputeResolutionModule) != address(0)) {
            return defaultDisputeResolutionModule;
        }
        return super._getResolutionModule(workflowId);
    }

    /**
     * @dev Get the yield generation module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The yield generation module (from snapshot or default)
     */
    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldGenerationModule) {
        address snapshot = moduleSnapshots[workflowId].yieldGenerationModule;
        return snapshot != address(0) ? IYieldGenerationModule(snapshot) : defaultYieldGenerationModule;
    }

    /**
     * @dev Get the yield distribution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The yield distribution module (from snapshot or default)
     */
    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        address snapshot = moduleSnapshots[workflowId].yieldDistributionModule;
        return snapshot != address(0) ? IYieldDistributionModule(snapshot) : defaultYieldDistributionModule;
    }

    // ============ Public Module Getters ============

    /**
     * @notice Get the release strategy for an escrow
     * @param workflowId The escrow transfer ID
     * @return The release strategy module
     */
    function getReleaseStrategy(uint256 workflowId) public view returns (IReleaseStrategy) {
        return _getReleaseStrategy(workflowId);
    }

    /**
     * @notice Get the resolution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The resolution module
     */
    function getResolutionModule(uint256 workflowId) public view returns (IResolutionModule) {
        return _getResolutionModule(workflowId);
    }

    /**
     * @notice Get the yield generation module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The yield generation module
     */
    function getYieldGenerationModule(uint256 workflowId) public view returns (IYieldGenerationModule) {
        return _getYieldGenerationModule(workflowId);
    }

    /**
     * @notice Get the yield distribution module for an escrow
     * @param workflowId The escrow transfer ID
     * @return The yield distribution module
     */
    function getYieldDistributionModule(uint256 workflowId) public view returns (IYieldDistributionModule) {
        return _getYieldDistributionModule(workflowId);
    }

    // ============ Module Management (Slow Lane Queue/Activate) ============

    /**
     * @notice Disabled legacy entrypoint (use ModuleManagementContract)
     */
    function queueDefaultModule(ModuleType, address) external onlyRole(ROLE_TIMELOCK) {
        revert UseModuleManagementContract();
    }

    /**
     * @notice Disabled legacy entrypoint (use ModuleManagementContract)
     */
    function activateDefaultModule(ModuleType) external onlyRole(ROLE_TIMELOCK) {
        revert UseModuleManagementContract();
    }

    /**
     * @notice Disabled legacy entrypoint (use ModuleManagementContract)
     */
    function getPendingDefaultModule(ModuleType) external pure returns (address, uint64, bool) {
        revert UseModuleManagementContract();
    }

    // ============ Fee Management ============

    /**
     * @notice Withdraw accumulated escrow fees
     * @return success True if withdrawal was successful
     * @dev Only the fee address can withdraw fees. Transfers all accumulated fees to the fee address.
     */
    function withdrawFees() public nonReentrant returns (bool) {
        if (_msgSender() != escrowFeeAddress) {
            revert NotFeeAddress(_msgSender(), escrowFeeAddress);
        }
        uint256 feeAmount = totalFees;
        if (feeAmount == 0) {
            revert NoFeesToWithdraw(address(this), feeAmount);
        }
        
        // Check balance before clearing state (checks-effects-interactions pattern)
        uint256 balance = balanceOf(address(this));
        if (balance < feeAmount) {
            revert InsufficientContractBalance(address(this), feeAmount, balance);
        }
        
        // Clear state AFTER successful transfer to prevent fee loss on failure
        // Note: If transfer fails, revert will restore state (Solidity 0.8+ automatic)
        _transfer(address(this), escrowFeeAddress, feeAmount);
        totalFees = 0;
        
        emit FeesWithdrawn(feeAmount);
        return true;
    }

    /**
     * @notice Recover ERC20 tokens sent to the contract
     * @dev Overrides BaseEscrow.recoverERC20 to validate against escrow accounting
     * @param token Token address to recover
     * @param recipient Address to receive the recovered tokens
     * @param amount Amount of tokens to recover
     * @return success Whether recovery succeeded
     * @dev Only ROLE_TIMELOCK can recover. Validates that recovery won't affect escrowed funds or fees.
     */
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        if (token != address(this)) revert InvalidAddress('Token must be address(this)', token);
        
        uint256 balance = balanceOf(address(this));
        uint256 escrowBalance = totalHeldInEscrow;
        uint256 feeBalance = totalFees;
        
        // Calculate available excess (balance minus escrow and fees)
        uint256 available = balance > escrowBalance + feeBalance ? balance - escrowBalance - feeBalance : 0;
        
        // CRIT-2: Determine recovery amount - if amount == 0, recover all available excess
        uint256 recoveryAmount = amount == 0 ? available : amount;
        
        // CRIT-2: Critical validation - ensure requested amount doesn't exceed available excess
        if (recoveryAmount > available) {
            revert AmountExceedsAvailable(token, recoveryAmount, available);
        }
        if (recoveryAmount == 0) {
            revert InvalidAmount('No tokens to recover');
        }
        
        recoveryAmount = RecoveryLibrary.recoverERC20(token, recipient, recoveryAmount, balance);
        emit ERC20Recovered(token, recipient, recoveryAmount);
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
     * @param yieldOps Address of YieldOps contract
     * @param disputeOps Address of DisputeOps contract
     * @return Address of the newly deployed EscrowableERC20 contract
     */
    function createEscrowableERC20(
        string memory name,
        string memory symbol,
        uint256 escrowFee,
        address escrowFeeAddress,
        address yieldOps,
        address disputeOps
    ) public returns (address) {
        return address(new EscrowableERC20(name, symbol, escrowFee, escrowFeeAddress, yieldOps, disputeOps));
    }
}
