// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import './ModuleManagementContract.sol';
import '../libraries/ModuleGetterLibrary.sol';
import '../libraries/ModuleGetterConsolidationLibrary.sol';

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
    
    
    // Single token tracking (not per-token like EscrowVault)
    uint256 public totalHeldInEscrow = 0;
    uint256 public totalFees = 0;
    
    // Module management contract (stores module state externally to reduce contract size)
    ModuleManagementContract public immutable moduleManagement;

    event FeesWithdrawn(uint256 amount);
    event WiringConfigured(address indexed yieldOps, address indexed disputeOps, address indexed moduleManagement);

    /// @notice Compact error for zero address validation (saves bytecode vs string-based errors)
    error ZeroAddress(uint8 which); // 1=fee, 2=yieldOps, 3=disputeOps, 4=moduleMgmt

    constructor(
        string memory name,
        string memory symbol,
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) ERC20(name, symbol) {
        // Validate escrow fee is within allowed range (0 to 2%)
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        if (feeAddress == address(0)) revert ZeroAddress(1);
        if (yieldOpsAddress == address(0)) revert ZeroAddress(2);
        if (disputeOpsAddress == address(0)) revert ZeroAddress(3);
        if (moduleManagementAddress == address(0)) revert ZeroAddress(4);
        if (yieldOpsAddress.code.length == 0) revert ZeroAddress(2);
        if (disputeOpsAddress.code.length == 0) revert ZeroAddress(3);
        if (moduleManagementAddress.code.length == 0) revert ZeroAddress(4);

        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        moduleManagement = ModuleManagementContract(moduleManagementAddress);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ROLE_TIMELOCK, _msgSender());

        // Initialize protocol fees (constants are already within bounds)
        yieldProtocolFeeBps = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
        appealBondProtocolFeeBps = 0; // 0% default

        // Set timeout config fields directly (avoid struct literal to save bytecode)
        timeoutConfig.maxDisputeDuration = 90 days;
        timeoutConfig.appealWindowDuration = 2 days;
        // Note: defaultAutoReleaseTime and defaultAutoCancelTime are zero by default
        
        emit WiringConfigured(yieldOpsAddress, disputeOpsAddress, moduleManagementAddress);
        
        // Mint initial supply to deployer
        _mint(_msgSender(), INITIAL_SUPPLY);
    }

    // ============ Convenience Functions ============

    /**
     * @notice Create a new escrow with custom auto-release or auto-cancel time
     * @param seller Recipient address (seller)
     * @param amount Total amount to escrow (after fee deduction)
     * @param autoReleaseTime Timestamp for automatic release (0 = no auto-release)
     * @param autoCancelTime Timestamp for automatic cancel (0 = no auto-cancel)
     * @return workflowId The ID of the created escrow transfer
     * @dev Convenience function - calls BaseEscrow.createEscrow with address(this) as token
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

    /**
     * @notice Create a new escrow with default settings
     * @param seller Recipient address (seller)
     * @param amount Total amount to escrow (after fee deduction)
     * @return workflowId The ID of the created escrow transfer
     * @dev Convenience function - calls BaseEscrow.createEscrow with address(this) as token
     */
    function createEscrow(address seller, uint256 amount) public whenNotPaused returns (uint256) {
        return createEscrow(address(this), seller, amount, SettingsValidationLibrary.getDefaultSettings());
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
        if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);
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
        if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);
        // MED-4: Prevent overflow when accumulating fees
        // currentFees is the current total accumulated fees before adding the new fee
        uint256 currentFees = totalFees;
        if (amount > type(uint256).max - currentFees) {
            revert FeeOverflow();
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
        if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);
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
        if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);
        
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
    ) internal pure override {
        // EscrowCreated already provides this information (token is always address(this))
        workflowId;
        token;
        from;
        to;
        amount;
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
    ) internal pure override {
        // EscrowStateChanged already provides this information
        workflowId;
        token;
        from;
        amount;
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
    ) internal pure override {
        // EscrowStateChanged already provides this information
        workflowId;
        token;
        to;
        amount;
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
        address moduleAddress = address(generationModule);
        uint256 currentAllowance = allowance(address(this), moduleAddress);
        if (currentAllowance < amount) {
            _approve(address(this), moduleAddress, type(uint256).max);
        }
        generationModule.depositForYield(workflowId, token, amount);
    }

    // ============ Module Getters ============

    // Consolidated module getters to reduce bytecode (mirrors EscrowVault)
    function _getModuleAddress(uint256 workflowId, ModuleType moduleType) internal view returns (address) {
        return ModuleGetterLibrary.getModuleAddress(
            workflowId,
            moduleType,
            moduleSnapshots,
            moduleManagement,
            address(this)
        );
    }

    // ============ Module swapping (escrow-originated calls) ============
    // Removed wrappers as ModuleManagementContract now allows direct ROLE_TIMELOCK calls

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        return ModuleGetterConsolidationLibrary.getReleaseStrategy(_getModuleAddress(workflowId, ModuleType.RELEASE));
    }

    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        return ModuleGetterConsolidationLibrary.getResolutionModule(_getModuleAddress(workflowId, ModuleType.RESOLUTION), disputeResolutionModule);
    }

    function _getDefaultYieldGenerationModule() internal view override returns (IYieldGenerationModule module) {
        return IYieldGenerationModule(moduleManagement.getModule(address(this), ModuleType.YIELD_GEN));
    }

    function _getYieldGenerationModule(uint256 workflowId) internal view override returns (IYieldGenerationModule) {
        return ModuleGetterConsolidationLibrary.getYieldGenerationModule(_getModuleAddress(workflowId, ModuleType.YIELD_GEN));
    }

    function _getYieldDistributionModule(uint256 workflowId) internal view override returns (IYieldDistributionModule) {
        return ModuleGetterConsolidationLibrary.getYieldDistributionModule(_getModuleAddress(workflowId, ModuleType.YIELD_DIST));
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

    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external override onlyRole(ROLE_TIMELOCK) nonReentrant {
        if (token != address(this)) revert InvalidAddress(ADDR_TOKEN, token);
        if (recipient == address(0)) revert InvalidAddress(ADDR_RECIPIENT, recipient);
        
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
            revert NoTokensToRecover();
        }

        // Token is address(this): use ERC20 internal transfer directly (saves bytecode vs RecoveryLibrary)
        _transfer(address(this), recipient, recoveryAmount);
        emit ERC20Recovered(token, recipient, recoveryAmount);
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
        address disputeOps,
        address moduleManagement
    ) public returns (address) {
        return
            address(
                new EscrowableERC20(
                    name,
                    symbol,
                    escrowFee,
                    escrowFeeAddress,
                    yieldOps,
                    disputeOps,
                    moduleManagement
                )
            );
    }
}
