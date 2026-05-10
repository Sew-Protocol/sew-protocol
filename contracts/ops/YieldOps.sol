// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../libraries/ResolverLogicLibrary.sol';

/**
 * @title YieldOps
 * @notice External contract for yield withdrawal and distribution operations
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
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');

    // ============ Constants ============
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 3000;

    // Events
    event YieldWithdrawn(uint256 indexed workflowId, address indexed token, uint256 yieldAmount);
    event YieldDistributed(uint256 indexed workflowId, address indexed token, uint256 yieldAmount);
    event YieldDistributionDeferred(uint256 indexed workflowId, address indexed token, uint256 yieldAmount, string reason);
    event YieldDistributionFailed(uint256 indexed workflowId, address indexed token, uint256 yieldAmount, string reason);
    event YieldProtocolFeeCollected(uint256 indexed workflowId, address indexed token, uint256 yieldAmount, uint256 protocolFeeAmount);
    event ProtocolFeeClaimableCredited(uint256 indexed workflowId, address indexed token, address indexed feeRecipient, uint256 amount);
    event ProtocolFeeClaimed(address indexed token, address indexed feeRecipient, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // token => recipient => claimable protocol fee amount
    mapping(address => mapping(address => uint256)) public claimableProtocolFees;

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidRecipient(address(0));
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
    }

    struct YieldResult {
        uint256 actualAmount;
        uint256 yield;
        uint256 yieldDistributed;
        bool success;
        string failureReason;
    }

    struct DistributionResult {
        bool success;
        uint256 distributedAmount;
        string failureReason;
    }

    /**
     * @notice Distribute withdrawn yield with pull-first safety semantics.
     * @dev Protocol fee (if configured) is credited as claimable for feeRecipient.
     *      Any non-fee remainder that cannot be distributed is retained for
     *      escrow-level claimable accounting (no fallback push transfer).
     */
    function distributeWithdrawnYield(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 yieldAmount,
        uint256 protocolFeeBps,
        address feeRecipient,
        bytes memory distributionData
    ) external onlyRole(ROLE_ESCROW_CONTRACT) returns (DistributionResult memory result) {
        address escrowContract = _msgSender();
        result.success = true;
        result.distributedAmount = 0;
        result.failureReason = '';

        if (yieldAmount == 0) return result;

        uint256 protocolFeeAmount = 0;
        uint256 yieldToDistribute = yieldAmount;

        if (protocolFeeBps > 0) {
            if (feeRecipient == address(0)) revert FeeRecipientCannotBeZero();
            if (protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert ProtocolFeeExceedsMaximum(protocolFeeBps, MAX_PROTOCOL_FEE_BPS);
            protocolFeeAmount = (yieldAmount * protocolFeeBps) / 10000;
            if (protocolFeeAmount > 0) {
                yieldToDistribute = yieldAmount - protocolFeeAmount;
                claimableProtocolFees[token][feeRecipient] += protocolFeeAmount;
                emit YieldProtocolFeeCollected(workflowId, token, yieldAmount, protocolFeeAmount);
                emit ProtocolFeeClaimableCredited(workflowId, token, feeRecipient, protocolFeeAmount);
            }
        }

        if (yieldToDistribute > 0 && address(distModule) != address(0)) {
            try this._distributeYieldInternal(distModule, workflowId, escrowContract, token, yieldToDistribute, distributionData) returns (uint256 distributedAmount) {
                if (distributedAmount > 0) {
                    emit YieldDistributed(workflowId, token, distributedAmount);
                } else {
                    emit YieldDistributionDeferred(workflowId, token, yieldToDistribute, 'Deferred to escrow claimable flow');
                }
                result.distributedAmount = distributedAmount;
                return result;
            } catch Error(string memory reason) {
                result.failureReason = reason;
                emit YieldDistributionFailed(workflowId, token, yieldToDistribute, reason);
            } catch {
                result.failureReason = 'Unknown error';
                emit YieldDistributionFailed(workflowId, token, yieldToDistribute, 'Unknown error');
            }

            if (feeRecipient != address(0)) {
                result.success = false;
                result.distributedAmount = 0;
                return result;
            }
            result.success = false;
            return result;
        }

        if (yieldToDistribute > 0 && feeRecipient != address(0)) {
            result.distributedAmount = 0;
            result.failureReason = 'Yield retained in escrow claimable pool';
            emit YieldDistributionDeferred(workflowId, token, yieldToDistribute, result.failureReason);
            return result;
        }

        if (yieldToDistribute > 0) {
            result.success = true;
            result.failureReason = 'Yield retained in escrow claimable pool';
            emit YieldDistributionDeferred(workflowId, token, yieldToDistribute, result.failureReason);
        }

        return result;
    }

    /**
     * @notice Withdraw claimable protocol fees for msg.sender.
     * @dev Explicit pull path only; no automatic fee delivery.
     */
    function withdrawClaimableProtocolFee(address token, uint256 amount) external returns (uint256 withdrawn) {
        uint256 claimable = claimableProtocolFees[token][_msgSender()];
        if (amount == 0 || amount > claimable) revert TransferFailed(_msgSender(), amount);

        claimableProtocolFees[token][_msgSender()] = claimable - amount;
        IERC20(token).safeTransfer(_msgSender(), amount);
        emit ProtocolFeeClaimed(token, _msgSender(), amount);
        return amount;
    }

    /**
     * @notice Handle yield withdrawal
     */
    function handleYield(
        IYieldGenerationModule genModule,
        IYieldDistributionModule /* distModule */,
        uint256 workflowId,
        address token,
        uint256 amount,
        uint256 /* protocolFeeBps */,
        address /* feeRecipient */,
        bytes memory /* distributionData */
    ) external onlyRole(ROLE_ESCROW_CONTRACT) returns (YieldResult memory result) {
        address escrowContract = _msgSender();
        result.actualAmount = amount;
        result.yield = 0;
        result.yieldDistributed = 0;
        result.success = true;
        result.failureReason = '';

        if (address(genModule) == address(0)) return result;

        uint256 balBefore = IERC20(token).balanceOf(address(this));

        try genModule.withdrawWithYield(workflowId, token, amount, escrowContract) returns (
            bool withdrawSuccess,
            uint256 actualAmountWithdrawn,
            uint256 /* yieldGenerated */
        ) {
            uint256 balAfter = IERC20(token).balanceOf(address(this));
            uint256 received = balAfter > balBefore ? balAfter - balBefore : 0;

            if (withdrawSuccess) {
                result.actualAmount = actualAmountWithdrawn;
                if (actualAmountWithdrawn > amount) {
                    result.yield = actualAmountWithdrawn - amount;
                    emit YieldWithdrawn(workflowId, token, result.yield);
                }
                
                // Forward any tokens actually received to the caller (vault),
                // where settlement remains claimable-first.
                if (received > 0) {
                    IERC20(token).safeTransfer(escrowContract, received);
                }
            } else {
                result.success = false;
                result.failureReason = 'Yield generation module returned false';
            }
        } catch Error(string memory reason) {
            result.success = false;
            result.failureReason = reason;
            emit YieldDistributionFailed(workflowId, token, 0, reason);
        } catch {
            result.success = false;
            result.failureReason = 'Yield withdrawal failed';
            emit YieldDistributionFailed(workflowId, token, 0, 'Yield withdrawal failed');
        }

        return result;
    }

    function _distributeYieldInternal(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address escrowContract,
        address token,
        uint256 yieldAmount,
        bytes memory distributionData
    ) public returns (uint256 distributedAmount) {
        if (_msgSender() != address(this)) revert InternalOnly(_msgSender());
        if (yieldAmount == 0) return 0;
        IERC20(token).safeTransfer(address(distModule), yieldAmount);
        (bool success, uint256 moduleDistributedAmount) = distModule.distributeYield(workflowId, escrowContract, token, yieldAmount, distributionData);
        if (!success) revert DistributionFailed(workflowId, token, yieldAmount);
        if (moduleDistributedAmount < yieldAmount) {
             emit YieldDistributionFailed(workflowId, token, yieldAmount - moduleDistributedAmount, 'Partial distribution');
        }
        return moduleDistributedAmount;
    }

    function recoverTokens(address token, address to, uint256 amount) external onlyRole(ROLE_GUARDIAN) {
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
