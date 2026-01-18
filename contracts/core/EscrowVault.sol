// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import './BaseEscrow.sol';
import '../governance/SlowLaneQueueActivate.sol';
// PRIORITY: Removed RecoveryLibrary import - recoverERC20 simplified to use safeTransfer directly
// PRIORITY 5: Removed EscrowAccountingLibrary import (moved to external AccountingOps contract if needed)
import '../types/EscrowTypes.sol';
import '../interfaces/IReleaseStrategy.sol';
import '../shared/interfaces/IResolutionModule.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../interfaces/IModuleRegistry.sol';
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
    // PRIORITY 5: Removed EscrowAccountingLibrary usage (moved to external AccountingOps contract if needed)

    /// @notice Default yield protocol fee (30%)
    uint256 public constant DEFAULT_YIELD_PROTOCOL_FEE_BPS = 3000; // 30% default

    mapping(address => uint256) public totalFeesPerToken;
    // Tracks total amount held in escrow per token (immutable amounts - no partial releases)
    mapping(address => uint256) public totalHeldInEscrowPerToken;

    // Module management contract (stores module state externally to reduce contract size)
    ModuleManagementContract public moduleManagement;
    
    // Module registry for validation (optional - if not set, validation skipped)
    IModuleRegistry public moduleRegistry;

    // PRIORITY: Removed EscrowTransferCreated/Released/Cancelled events
    // EscrowCreated and EscrowStateChanged already provide this information
    event FeesWithdrawn(address indexed token, uint256 amount);
    // PRIORITY 5: Removed AccountingReconciled event (moved to external AccountingOps contract if needed)

    constructor(
        uint256 escrowFeeBps,
        address feeAddress,
        address yieldOpsAddress,
        address disputeOpsAddress,
        address moduleManagementAddress
    ) {
        // Validate escrow fee is within allowed range (0 to 2%)
        if (escrowFeeBps > MAX_ESCROW_FEE_BPS) {
            revert InvalidEscrowFee(escrowFeeBps, MAX_ESCROW_FEE_BPS);
        }
        if (feeAddress == address(0)) revert InvalidAddress('Fee address cannot be zero', feeAddress);
        if (yieldOpsAddress == address(0)) revert InvalidAddress('YieldOps address cannot be zero', yieldOpsAddress);
        if (disputeOpsAddress == address(0)) revert InvalidAddress('DisputeOps address cannot be zero', disputeOpsAddress);
        if (moduleManagementAddress == address(0)) revert InvalidAddress('ModuleManagement address cannot be zero', moduleManagementAddress);

        escrowFee = escrowFeeBps;
        moduleManagement = ModuleManagementContract(moduleManagementAddress);
        escrowFeeAddress = feeAddress;
        yieldOps = YieldOps(yieldOpsAddress);
        disputeOps = DisputeOps(disputeOpsAddress);
        
        // PRIORITY: Role granting moved to deployment script for security (timelock-only from day 1)

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
            revert InvalidAmount('Fee accumulation would overflow');
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
        // MED-3: Input validation
        if (token == address(0)) revert InvalidAddress('Token address cannot be zero', token);
        
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
     * @notice Queue a new default module
     * @param moduleType Type of module to queue (RELEASE, YIELD_GEN, YIELD_DIST)
     * @param module Address of the new module to queue
     * @dev Delegates to ModuleManagementContract. Requires ROLE_TIMELOCK.
     */
    function queueDefaultModule(ModuleType moduleType, address module) external onlyRole(ROLE_TIMELOCK) {
        if (moduleType == ModuleType.RESOLUTION) revert InvalidAmount('Use queueResolutionModule');
        moduleManagement.queueDefaultModule(address(this), moduleType, module);
    }

    /**
     * @notice Activate the queued default module
     * @param moduleType Type of module to activate (RELEASE, YIELD_GEN, YIELD_DIST)
     * @dev Delegates to ModuleManagementContract. Requires ROLE_TIMELOCK.
     */
    function activateDefaultModule(ModuleType moduleType) external onlyRole(ROLE_TIMELOCK) {
        if (moduleType == ModuleType.RESOLUTION) revert InvalidAmount('Use activateResolutionModule');
        moduleManagement.activateDefaultModule(address(this), moduleType);
    }

    /**
     * @notice Get pending default module information
     * @param moduleType Type of module to query
     * @return Pending module address, activation timestamp, and existence flag
     */
    function getPendingDefaultModule(ModuleType moduleType) external view returns (address, uint64, bool) {
        return moduleManagement.getPendingDefaultModule(address(this), moduleType);
    }

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

    // PRIORITY 5: Removed getAccountingDelta and reconcileAccounting
    // These functions have been removed to reduce contract size.
    // Off-chain monitoring can track accounting deltas via events and public storage.
    // If reconciliation is needed, it can be done via a separate AccountingOps contract.
}
