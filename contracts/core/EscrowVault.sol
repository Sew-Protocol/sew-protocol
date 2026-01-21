// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './BaseEscrow.sol';
import '../types/EscrowTypes.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
// PRIORITY: Removed unused IModuleRegistry import (only used in EscrowableERC20)
import './ModuleManagementContract.sol';

/**
 * @title EscrowVault
 * @notice Main escrow contract implementation supporting ERC20 tokens
 * @dev Concrete implementation of BaseEscrow that handles ERC20 token escrows.
 *      Supports multiple tokens, yield generation, dispute resolution, and module snapshots.
 *      Uses a pull model for token transfers and implements fee tracking per token.
 */
contract EscrowVault is BaseEscrow {
    using SafeERC20 for IERC20;

    /// @notice Default yield protocol fee (30%)
    uint256 public constant DEFAULT_YIELD_PROTOCOL_FEE_BPS = 3000; // 30% default

    mapping(address => uint256) public totalFeesPerToken;
    // Tracks total amount held in escrow per token (immutable amounts - no partial releases)
    mapping(address => uint256) public totalHeldInEscrowPerToken;

    // Module management contract (stores module state externally to reduce contract size)
    ModuleManagementContract public moduleManagement;

    // EscrowCreated and EscrowStateChanged already provide this information
    event FeesWithdrawn(address indexed token, uint256 amount);

    /// @notice Compact error for zero address validation (saves bytecode vs string-based errors)
    error ZeroAddress(uint8 which); // 1=fee, 2=yieldOps, 3=disputeOps, 4=moduleMgmt

    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) {
        // AccessControl initialization (required so tests/admin can grant roles)
        address deployer = _msgSender();
        _grantRole(DEFAULT_ADMIN_ROLE, deployer);
        _grantRole(ROLE_TIMELOCK, deployer);

        // Validate inputs (compact custom errors save bytecode)
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        if (feeAddress == address(0)) revert ZeroAddress(1);
        if (yieldOpsAddress == address(0)) revert ZeroAddress(2);
        if (disputeOpsAddress == address(0)) revert ZeroAddress(3);
        if (moduleManagementAddress == address(0)) revert ZeroAddress(4);

        // Set state variables
        escrowFee = escrowFeeBps;
        escrowFeeAddress = feeAddress;
        moduleManagement = ModuleManagementContract(moduleManagementAddress);
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        
        // Only set non-zero / non-default values (skip zero assignments to save bytecode)
        yieldProtocolFeeBps = DEFAULT_YIELD_PROTOCOL_FEE_BPS;
        
        // Set timeout config fields directly (avoid struct literal to save bytecode)
        timeoutConfig.maxDisputeDuration = 90 days;
        timeoutConfig.appealWindowDuration = 2 days;
        // Note: defaultAutoReleaseTime and defaultAutoCancelTime are zero by default, no need to set
    }


    /**
     * @notice Release escrow funds to recipient (sender-initiated)
     * @param workflowId The escrow ID
     * @return success Whether the release succeeded
     * @dev Only the sender (from address) can release. Transfers funds to recipient.
     */
    function releaseEscrowTransfer(uint256 workflowId) public nonReentrant whenNotPaused returns (bool) {
        _requirePending(workflowId);
        if (escrowTransfers[workflowId].from != _msgSender())
            revert NotSender(workflowId, _msgSender(), escrowTransfers[workflowId].from);
        _releaseEscrowTransfer(workflowId);
        return true;
    }

    function _pullTokens(address token, address from, uint256 amount) internal override {
        IERC20(token).safeTransferFrom(from, address(this), amount);
    }
    function _recordFee(address token, uint256 amount) internal override {
        // MED-4: Prevent overflow when accumulating fees
        // currentFees is the current total accumulated fees for this token before adding the new fee
        uint256 currentFees = totalFeesPerToken[token];
        if (amount > type(uint256).max - currentFees) {
            revert FeeOverflow();
        }
        totalFeesPerToken[token] = currentFees + amount;
    }
    function _depositForYield(
        IYieldGenerationModule generationModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal override {
        generationModule.depositForYield(workflowId, token, amount);
    }
    function _emitEscrowTransferCreated(
        uint256 workflowId,
        address token,
        address from,
        address to,
        uint256 amount
    ) internal override {
        // PRIORITY: Event removed - EscrowCreated already provides this information
    }
    function _transferTokens(address token, address to, uint256 amount) internal override {
        IERC20(token).safeTransfer(to, amount);
    }
    function _updateEscrowBalance(address token, uint256 amount, bool add) internal override {
        // MED-3: Input validation (use compact error)
        if (token == address(0)) revert ZeroAddress(0);
        
        if (add) {
            totalHeldInEscrowPerToken[token] += amount;
        } else {
            // CRIT-1: Prevent underflow that could break accounting
            if (totalHeldInEscrowPerToken[token] < amount) {
                revert BalanceUnderflow(token, totalHeldInEscrowPerToken[token], amount);
            }
            totalHeldInEscrowPerToken[token] -= amount;
        }
    }
    function _emitEscrowTransferCancelled(
        uint256 workflowId,
        address token,
        address from,
        uint256 amount
    ) internal override {
        // PRIORITY: Event removed - EscrowStateChanged already provides this information
    }
    function _emitEscrowTransferReleased(
        uint256 workflowId,
        address token,
        address to,
        uint256 amount
    ) internal override {
        // PRIORITY: Event removed - EscrowStateChanged already provides this information
    }

    // PRIORITY: Consolidated module getters to reduce bytecode
    function _getModuleAddress(uint256 workflowId, ModuleType moduleType) internal view returns (address) {
        address snapshotModule;
        if (moduleType == ModuleType.RELEASE) {
            snapshotModule = moduleSnapshots[workflowId].releaseStrategy;
        } else if (moduleType == ModuleType.RESOLUTION) {
            snapshotModule = moduleSnapshots[workflowId].resolutionModule;
        } else if (moduleType == ModuleType.YIELD_GEN) {
            snapshotModule = moduleSnapshots[workflowId].yieldGenerationModule;
        } else if (moduleType == ModuleType.YIELD_DIST) {
            snapshotModule = moduleSnapshots[workflowId].yieldDistributionModule;
        }
        
        if (snapshotModule != address(0)) {
            return snapshotModule;
        }
        
        // Query ModuleManagementContract for default module
        return moduleManagement.getDefaultModule(address(this), moduleType);
    }

    function _getReleaseStrategy(uint256 workflowId) internal view override returns (IReleaseStrategy) {
        return IReleaseStrategy(_getModuleAddress(workflowId, ModuleType.RELEASE));
    }

    function _getResolutionModule(uint256 workflowId) internal view override returns (IResolutionModule) {
        address moduleAddr = _getModuleAddress(workflowId, ModuleType.RESOLUTION);
        if (moduleAddr != address(0)) {
            return IResolutionModule(moduleAddr);
        }
        // Fallback to BaseEscrow's disputeResolutionModule
        return IResolutionModule(disputeResolutionModule);
    }

    function _getYieldGenerationModule(
        uint256 workflowId
    ) internal view override returns (IYieldGenerationModule) {
        return IYieldGenerationModule(_getModuleAddress(workflowId, ModuleType.YIELD_GEN));
    }

    function _getYieldDistributionModule(
        uint256 workflowId
    ) internal view override returns (IYieldDistributionModule) {
        return IYieldDistributionModule(_getModuleAddress(workflowId, ModuleType.YIELD_DIST));
    }

    /**
     * @notice Get default yield generation module (for emergency operations)
     * @return module Default yield generation module
     * @dev Returns default module from ModuleManagementContract
     */
    function _getDefaultYieldGenerationModule() internal view override returns (IYieldGenerationModule module) {
        return IYieldGenerationModule(moduleManagement.getDefaultModule(address(this), ModuleType.YIELD_GEN));
    }

    // PRIORITY: Removed thin wrapper functions (queueDefaultModule, activateDefaultModule, getPendingDefaultModule)
    // Users should call ModuleManagementContract directly to reduce EscrowVault bytecode size

    bytes32 public constant ROLE_FEE_RECIPIENT = keccak256('ROLE_FEE_RECIPIENT');

    /**
     * @notice Withdraw accumulated fees for a specific token
     * @param token Token address to withdraw fees for
     * @return success Whether withdrawal succeeded
     * @dev Only fee recipient role can withdraw. Withdraws all accumulated fees for the token.
     */
    function withdrawFees(address token) external onlyRole(ROLE_FEE_RECIPIENT) nonReentrant returns (bool) {
        uint256 feeAmount = totalFeesPerToken[token];
        if (feeAmount == 0) revert NoFeesToWithdraw(token, feeAmount);
        
        // Check balance before clearing state (checks-effects-interactions pattern)
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < feeAmount) {
            revert InsufficientContractBalance(token, feeAmount, balance);
        }
        
        // Clear state AFTER successful transfer to prevent fee loss on failure
        // Note: If transfer fails, revert will restore state (Solidity 0.8+ automatic)
        IERC20(token).safeTransfer(escrowFeeAddress, feeAmount);
        totalFeesPerToken[token] = 0;
        
        emit FeesWithdrawn(token, feeAmount);
        return true;
    }

    /**
     * @notice Recover ERC20 tokens (excluding escrow balances and fees)
     * @param token Token address to recover
     * @param recipient Recipient address
     * @param amount Amount to recover (0 = recover all excess)
     * @return success Whether recovery succeeded
     * @dev Only recovers tokens beyond escrow balances and fees. Requires ROLE_TIMELOCK.
     *      PRIORITY: Simplified to use safeTransfer directly, removed RecoveryLibrary dependency.
     */
    function recoverERC20(
        address token,
        address recipient,
        uint256 amount
    ) external override onlyRole(ROLE_TIMELOCK) nonReentrant returns (bool) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 protected = totalHeldInEscrowPerToken[token] + totalFeesPerToken[token];
        uint256 available = balance > protected ? balance - protected : 0;
        uint256 recoveryAmount = amount == 0 ? available : amount;
        
        if (recoveryAmount == 0 || recoveryAmount > available) {
            revert AmountExceedsAvailable(token, recoveryAmount, available);
        }
        
        IERC20(token).safeTransfer(recipient, recoveryAmount);
        emit ERC20Recovered(token, recipient, recoveryAmount);
        return true;
    }
}
