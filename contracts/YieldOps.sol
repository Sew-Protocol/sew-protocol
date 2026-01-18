// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import './interfaces/IYieldGenerationModule.sol';
import './interfaces/IYieldDistributionModule.sol';
import './libraries/ResolverLogicLibrary.sol';

/**
 * @title YieldOps
 * @notice External contract for yield withdrawal and distribution operations
 * @dev Extracted from BaseEscrow to reduce contract size (Phase 1 size optimization)
 *
 *      Key design principles (from updated plan):
 *      - Non-blocking: Uses try/catch to prevent yield failures from blocking escrow lifecycle
 *      - Non-reentrant: No callbacks to BaseEscrow, operates in "compute and return" pattern
 *      - Pull-based: BaseEscrow transfers tokens to this contract before calling
 *
 *      This contract is stateless and purely operational - no escrow state stored here.
 */
contract YieldOps is AccessControl {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============
    error ZeroOwner();
    error FeeRecipientCannotBeZero();
    error ProtocolFeeExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);
    error InternalOnly(address caller);
    error DistributionFailed(uint256 workflowId, address token, uint256 amount);
    error InvalidRecipient(address recipient);
    error TransferFailed(address recipient, uint256 amount);

    // ============ Role Constants ============
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');

    // ============ Constants ============
    /// @notice Maximum protocol fee (30%)
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3000; // 30% maximum protocol fee

    // Events for yield operations
    event YieldWithdrawn(uint256 indexed workflowId, address indexed token, uint256 yieldAmount);
    event YieldDistributed(uint256 indexed workflowId, address indexed token, uint256 yieldAmount);
    event YieldDistributionFailed(
        uint256 indexed workflowId,
        address indexed token,
        uint256 yieldAmount,
        string reason
    );
    event YieldProtocolFeeCollected(
        uint256 indexed workflowId,
        address indexed token,
        uint256 yieldAmount,
        uint256 protocolFeeAmount
    );
    event YieldRecoveredToFeeAddress(
        uint256 indexed workflowId,
        address indexed token,
        uint256 yieldAmount,
        address indexed feeRecipient
    );
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Constructor for YieldOps
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
    }

    /**
     * @dev Result of yield handling operation
     */
    struct YieldResult {
        uint256 actualAmount; // Actual amount withdrawn (may include yield)
        uint256 yield; // Total yield amount
        uint256 yieldDistributed; // Amount successfully distributed
        bool success; // Whether distribution succeeded
    }

    /**
     * @notice Handle yield withdrawal and distribution
     * @param genModule Yield generation module
     * @param distModule Yield distribution module
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param amount Original escrow amount
     * @param protocolFeeBps Protocol fee in basis points (0-3000 = 0-30%)
     * @param feeRecipient Address to receive protocol fee
     * @param distributionData Encoded per-escrow yield distribution (recipients, percentages) or empty for module default
     * @return result Yield operation result
     * @dev Non-blocking: Returns success=false if distribution fails, doesn't revert
     *      Caller (BaseEscrow) should handle failure case (e.g., route to fee address)
     *      Protocol fee is deducted from yield before distribution to recipients
     */
    function handleYield(
        IYieldGenerationModule genModule,
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 amount,
        uint256 protocolFeeBps,
        address feeRecipient,
        bytes memory distributionData
    ) external returns (YieldResult memory result) {
        result.actualAmount = amount;
        result.yield = 0;
        result.yieldDistributed = 0;
        result.success = true;

        // No yield module - early return
        if (address(genModule) == address(0)) {
            return result;
        }

        // Withdraw with yield (try/catch to prevent blocking)
        try genModule.withdrawWithYield(workflowId, token, amount) returns (
            bool withdrawSuccess,
            uint256 actualAmount,
            uint256 /* yieldGenerated */
        ) {
            if (withdrawSuccess) {
                result.actualAmount = actualAmount;
                if (actualAmount > amount) {
                    result.yield = actualAmount - amount;
                    emit YieldWithdrawn(workflowId, token, result.yield);
                }
            }
        } catch {
            // Withdrawal failed - continue with original amount
            emit YieldDistributionFailed(workflowId, token, 0, 'Yield withdrawal failed');
        }

        // Deduct protocol fee and distribute remaining yield if any
        if (result.yield > 0) {
            uint256 protocolFeeAmount = 0;
            uint256 yieldToDistribute = result.yield;

            // Calculate and collect protocol fee if enabled
            // MED-3: Validate fee recipient is not zero address
            if (protocolFeeBps > 0) {
                if (feeRecipient == address(0)) revert FeeRecipientCannotBeZero();
                if (protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeExceedsMaximum(protocolFeeBps, MAX_PROTOCOL_FEE_BPS);
                protocolFeeAmount = (result.yield * protocolFeeBps) / 10000;
                if (protocolFeeAmount > 0) {
                    yieldToDistribute = result.yield - protocolFeeAmount;
                    // Transfer protocol fee to fee recipient
                    IERC20(token).safeTransfer(feeRecipient, protocolFeeAmount);
                    emit YieldProtocolFeeCollected(workflowId, token, result.yield, protocolFeeAmount);
                }
            }

            // Distribute remaining yield to recipients if distribution module is set
            if (yieldToDistribute > 0 && address(distModule) != address(0)) {
                try this._distributeYieldInternal(distModule, workflowId, token, yieldToDistribute, distributionData) {
                    result.yieldDistributed = yieldToDistribute;
                    result.success = true;
                } catch Error(string memory reason) {
                    emit YieldDistributionFailed(workflowId, token, yieldToDistribute, reason);
                    result.success = false;
                    
                    // CRIT-2: Fallback to fee recipient on distribution failure
                    if (feeRecipient != address(0)) {
                        IERC20(token).safeTransfer(feeRecipient, yieldToDistribute);
                        result.yieldDistributed = yieldToDistribute;
                        emit YieldRecoveredToFeeAddress(workflowId, token, yieldToDistribute, feeRecipient);
                    }
                } catch {
                    emit YieldDistributionFailed(workflowId, token, yieldToDistribute, 'Unknown error');
                    result.success = false;
                    
                    // CRIT-2: Fallback to fee recipient on distribution failure
                    if (feeRecipient != address(0)) {
                        IERC20(token).safeTransfer(feeRecipient, yieldToDistribute);
                        result.yieldDistributed = yieldToDistribute;
                        emit YieldRecoveredToFeeAddress(workflowId, token, yieldToDistribute, feeRecipient);
                    }
                }
            } else if (yieldToDistribute > 0) {
                // CRIT-2: No distribution module - route to fee recipient as fallback
                if (feeRecipient != address(0)) {
                    IERC20(token).safeTransfer(feeRecipient, yieldToDistribute);
                    result.yieldDistributed = yieldToDistribute;
                    emit YieldRecoveredToFeeAddress(workflowId, token, yieldToDistribute, feeRecipient);
                } else {
                    // No distribution module and no fee recipient - yield stays in contract
                    result.yieldDistributed = 0;
                }
                result.success = true;
            }
        }

        return result;
    }

    /**
     * @dev Internal yield distribution (public for try/catch pattern)
     * @param distModule Yield distribution module
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param yieldAmount Yield amount to distribute
     * @param distributionData Encoded per-escrow yield distribution (recipients, percentages) or empty for module default
     * @dev This function is public to allow try/catch from within the contract
     *      but should only be called by handleYield
     */
    function _distributeYieldInternal(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 yieldAmount,
        bytes memory distributionData
    ) public {
        if (msg.sender != address(this)) revert InternalOnly(msg.sender);

        if (yieldAmount == 0) return;

        // Transfer yield to module
        IERC20(token).safeTransfer(address(distModule), yieldAmount);

        // Distribute using per-escrow distribution data or module default (empty = module default)
        (bool success, ) = distModule.distributeYield(
            workflowId,
            token,
            yieldAmount,
            distributionData
        );
        if (!success) revert DistributionFailed(workflowId, token, yieldAmount);

        emit YieldDistributed(workflowId, token, yieldAmount);
    }

    /**
     * @notice Recover tokens accidentally sent to this contract
     * @param token Token address (or address(0) for native ETH)
     * @param to Recipient address
     * @param amount Amount to recover
     * @dev CRIT-1: Emergency function - requires ROLE_GUARDIAN access control
     *      This contract should not hold funds, but access control prevents unauthorized draining
     */
    function recoverTokens(address token, address to, uint256 amount) 
        external 
        onlyRole(ROLE_GUARDIAN) 
    {
        if (to == address(0)) revert InvalidRecipient(to);

        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}('');
            if (!success) revert TransferFailed(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        
        emit TokensRecovered(token, to, amount);
    }
}
