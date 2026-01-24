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
    bytes32 public constant ROLE_ESCROW_CONTRACT = keccak256('ROLE_ESCROW_CONTRACT');

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
     * @param initialOwner Address that will receive DEFAULT_ADMIN_ROLE (for initial setup only)
     */
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        _grantRole(DEFAULT_ADMIN_ROLE, initialOwner);
        // ROLE_TIMELOCK gates registerEscrowContract(), so initialOwner must have it for initial setup.
        _grantRole(ROLE_TIMELOCK, initialOwner);
    }

    /**
     * @notice Register an escrow contract (grants it ROLE_ESCROW_CONTRACT)
     * @param escrowContract Address of the escrow contract
     * @dev Only ROLE_TIMELOCK can register escrow contracts (governance-controlled)
     */
    function registerEscrowContract(address escrowContract) external onlyRole(ROLE_TIMELOCK) {
        if (escrowContract == address(0)) revert InvalidRecipient(address(0));
        _grantRole(ROLE_ESCROW_CONTRACT, escrowContract);
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
     * @notice Distribute yield that has already been withdrawn (no withdrawal step).
     * @param distModule Yield distribution module
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param yieldAmount Yield amount already held by this contract
     * @param protocolFeeBps Protocol fee in basis points (0-3000 = 0-30%)
     * @param feeRecipient Address to receive protocol fee / fallback yield
     * @param distributionData Encoded per-escrow yield distribution (recipients, percentages) or empty for module default
     * @return success Whether distribution succeeded (or fallback succeeded)
     * @return distributedAmount Amount distributed (or recovered to feeRecipient)
     * @dev Intended for the BaseEscrow "library pattern" where BaseEscrow withdraws from Aave directly,
     *      then transfers only the yield to YieldOps for distribution.
     *      Only authorized escrow contracts can call this function.
     */
    function distributeWithdrawnYield(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 yieldAmount,
        uint256 protocolFeeBps,
        address feeRecipient,
        bytes memory distributionData
    ) external onlyRole(ROLE_ESCROW_CONTRACT) returns (bool success, uint256 distributedAmount) {
        if (yieldAmount == 0) return (true, 0);

        uint256 protocolFeeAmount = 0;
        uint256 yieldToDistribute = yieldAmount;

        // Calculate and collect protocol fee if enabled
        if (protocolFeeBps > 0) {
            if (feeRecipient == address(0)) revert FeeRecipientCannotBeZero();
            if (protocolFeeBps > MAX_PROTOCOL_FEE_BPS)
                revert ProtocolFeeExceedsMaximum(protocolFeeBps, MAX_PROTOCOL_FEE_BPS);
            protocolFeeAmount = (yieldAmount * protocolFeeBps) / 10000;
            if (protocolFeeAmount > 0) {
                yieldToDistribute = yieldAmount - protocolFeeAmount;
                IERC20(token).safeTransfer(feeRecipient, protocolFeeAmount);
                emit YieldProtocolFeeCollected(workflowId, token, yieldAmount, protocolFeeAmount);
            }
        }

        // Distribute remaining yield to recipients if a distribution module is set
        if (yieldToDistribute > 0 && address(distModule) != address(0)) {
            try this._distributeYieldInternal(distModule, workflowId, token, yieldToDistribute, distributionData) {
                emit YieldDistributed(workflowId, token, yieldToDistribute);
                return (true, yieldToDistribute);
            } catch Error(string memory reason) {
                emit YieldDistributionFailed(workflowId, token, yieldToDistribute, reason);
            } catch {
                emit YieldDistributionFailed(workflowId, token, yieldToDistribute, 'Unknown error');
            }

            // CRIT-2: Fallback: route remaining yield to feeRecipient
            // If feeRecipient is zero, yield remains in YieldOps (can be recovered via recoverTokens)
            // This is acceptable as YieldOps has guardian recovery function
            if (feeRecipient != address(0)) {
                IERC20(token).safeTransfer(feeRecipient, yieldToDistribute);
                emit YieldRecoveredToFeeAddress(workflowId, token, yieldToDistribute, feeRecipient);
                return (false, yieldToDistribute);
            }

            // CRIT-2: No feeRecipient: yield remains in YieldOps (last resort)
            // Yield can be recovered by guardian via recoverTokens() function
            // Emit event to track this scenario
            emit YieldDistributionFailed(workflowId, token, yieldToDistribute, 'No fee recipient for fallback');
            return (false, 0);
        }

        // No distribution module: route to feeRecipient as fallback
        if (yieldToDistribute > 0 && feeRecipient != address(0)) {
            IERC20(token).safeTransfer(feeRecipient, yieldToDistribute);
            emit YieldRecoveredToFeeAddress(workflowId, token, yieldToDistribute, feeRecipient);
            return (true, yieldToDistribute);
        }

        // CRIT-2: No distribution module and no feeRecipient: yield stays in contract
        // Yield can be recovered by guardian via recoverTokens() function
        // Emit event to track this scenario
        if (yieldToDistribute > 0) {
            emit YieldDistributionFailed(workflowId, token, yieldToDistribute, 'No distribution module and no fee recipient');
        }
        return (true, 0);
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
     *      Only authorized escrow contracts can call this function
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
    ) external onlyRole(ROLE_ESCROW_CONTRACT) returns (YieldResult memory result) {
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

        // NOTE: Distribution is NOT done here (PUSH MODEL)
        // Escrow must transfer yield to YieldOps and call distributeWithdrawnYield
        // This keeps custody clear: vault holds tokens, YieldOps only holds during distribution
        
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

        // CRIT-2: Transfer yield to module before calling distributeYield
        // If distributeYield reverts or returns false, tokens are already in the module
        // The module should handle this gracefully (return tokens or distribute them)
        IERC20(token).safeTransfer(address(distModule), yieldAmount);

        // CRIT-2: Distribute using per-escrow distribution data or module default
        // If this reverts, the try/catch in caller will handle it
        // If it returns false, we revert here and caller's catch block will recover
        (bool success, uint256 distributedAmount) = distModule.distributeYield(
            workflowId,
            token,
            yieldAmount,
            distributionData
        );
        
        // CRIT-2: Handle partial distribution
        // If distributedAmount < yieldAmount, some yield may be stuck in module
        // This is acceptable as modules should handle their own accounting
        if (!success) {
            revert DistributionFailed(workflowId, token, yieldAmount);
        }
        
        // CRIT-2: Verify full distribution (distributedAmount should equal yieldAmount)
        // If not, emit warning but don't revert (module may have valid reasons)
        if (distributedAmount < yieldAmount) {
            emit YieldDistributionFailed(
                workflowId, 
                token, 
                yieldAmount - distributedAmount, 
                'Partial distribution - some yield may remain in module'
            );
        }

        emit YieldDistributed(workflowId, token, distributedAmount);
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
