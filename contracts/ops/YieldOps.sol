// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.37;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '../interfaces/IYieldModule.sol';

/**
 * @title YieldOps
 * @notice External contract for yield withdrawal and distribution operations
 */
contract YieldOps is AccessControl {
    using SafeERC20 for IERC20;

    // ============ Custom Errors ============
    error ZeroOwner();
    error InvalidRecipient(address recipient);
    error TransferFailed(address recipient, uint256 amount);

    // ============ Role Constants ============
    bytes32 public constant ROLE_GUARDIAN = keccak256('ROLE_GUARDIAN');
    bytes32 public constant ROLE_TIMELOCK = keccak256('ROLE_TIMELOCK');
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');

    // Events
    event YieldWithdrawn(uint256 indexed workflowId, address indexed token, uint256 yieldAmount);
    event YieldDistributionFailed(uint256 indexed workflowId, address indexed token, uint256 yieldAmount, string reason);
    event YieldProtocolFeeCollected(uint256 indexed workflowId, address indexed token, uint256 yieldAmount, uint256 protocolFeeAmount);
    event ProtocolFeeClaimableCredited(uint256 indexed workflowId, address indexed token, address indexed feeRecipient, uint256 amount);
    event ProtocolFeeClaimed(address indexed token, address indexed feeRecipient, uint256 amount);
    event EscrowYieldClaimableCredited(uint256 indexed workflowId, address indexed token, address indexed escrowContract, uint256 amount);
    event EscrowYieldClaimed(address indexed token, address indexed escrowContract, uint256 amount);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // token => recipient => claimable protocol fee amount
    mapping(address => mapping(address => uint256)) public claimableProtocolFees;
    // token => escrowContract => claimable amount withdrawn from generation module and held for explicit pull
    mapping(address => mapping(address => uint256)) public claimableEscrowYield;

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
        IYieldModule genModule,
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

        // Yield generation is unified on IYieldModule (v2.5).
        try genModule.unwindToEscrow(workflowId, token, amount) returns (
            uint256 principalOut,
            uint256 yieldOut
        ) {
            uint256 balAfter = IERC20(token).balanceOf(address(this));
            uint256 received = balAfter > balBefore ? balAfter - balBefore : 0;

            result.actualAmount = principalOut;
            result.yield = yieldOut;
            if (yieldOut > 0) {
                emit YieldWithdrawn(workflowId, token, yieldOut);
            }

            // Pull-only hardening: do not auto-forward to escrow contract.
            // Credit escrow claimable balance for explicit pull.
            if (received > 0) {
                claimableEscrowYield[token][escrowContract] += received;
                emit EscrowYieldClaimableCredited(workflowId, token, escrowContract, received);
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

    /**
     * @notice Escrow contract explicitly claims yield previously credited in handleYield().
     */
    function claimEscrowYield(address token, uint256 amount) external onlyRole(ROLE_ESCROW_CONTRACT) returns (uint256 claimed) {
        uint256 available = claimableEscrowYield[token][_msgSender()];
        if (amount == 0 || amount > available) revert TransferFailed(_msgSender(), amount);
        claimableEscrowYield[token][_msgSender()] = available - amount;
        IERC20(token).safeTransfer(_msgSender(), amount);
        emit EscrowYieldClaimed(token, _msgSender(), amount);
        return amount;
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
