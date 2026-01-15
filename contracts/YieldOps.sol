// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IYieldGenerationModule.sol";
import "./interfaces/IYieldDistributionModule.sol";
import "./libraries/ResolverLogicLibrary.sol";

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
contract YieldOps {
    using SafeERC20 for IERC20;

    // Events for yield operations
    event YieldWithdrawn(uint256 indexed escrowId, address indexed token, uint256 yieldAmount);
    event YieldDistributed(uint256 indexed escrowId, address indexed token, uint256 yieldAmount);
    event YieldDistributionFailed(uint256 indexed escrowId, address indexed token, uint256 yieldAmount, string reason);

    /**
     * @dev Result of yield handling operation
     */
    struct YieldResult {
        uint256 actualAmount;      // Actual amount withdrawn (may include yield)
        uint256 yield;             // Total yield amount
        uint256 yieldDistributed;  // Amount successfully distributed
        bool success;              // Whether distribution succeeded
    }

    /**
     * @notice Handle yield for full withdrawal (complete release/cancel)
     * @param genModule Yield generation module
     * @param distModule Yield distribution module  
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param amount Original escrow amount
     * @return result Yield operation result
     * @dev Non-blocking: Returns success=false if distribution fails, doesn't revert
     *      Caller (BaseEscrow) should handle failure case (e.g., route to fee address)
     */
    function handleFullYield(
        IYieldGenerationModule genModule,
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 amount
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
            emit YieldDistributionFailed(workflowId, token, 0, "Yield withdrawal failed");
        }

        // Distribute yield if any (try/catch for non-blocking)
        if (result.yield > 0 && address(distModule) != address(0)) {
            try this._distributeYieldInternal(distModule, workflowId, token, result.yield) {
                result.yieldDistributed = result.yield;
                result.success = true;
            } catch Error(string memory reason) {
                emit YieldDistributionFailed(workflowId, token, result.yield, reason);
                result.success = false;
            } catch {
                emit YieldDistributionFailed(workflowId, token, result.yield, "Unknown error");
                result.success = false;
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
     * @dev This function is public to allow try/catch from within the contract
     *      but should only be called by handleFullYield
     */
    function _distributeYieldInternal(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 yieldAmount
    ) public {
        require(msg.sender == address(this), "Internal only");
        
        if (yieldAmount == 0) return;

        // Transfer yield to module
        IERC20(token).safeTransfer(address(distModule), yieldAmount);

        // Distribute (empty data means no specific distribution config)
        bytes memory distributionData = "";
        (bool success, ) = distModule.distributeYield(workflowId, token, yieldAmount, distributionData);
        require(success, "Distribution failed");

        emit YieldDistributed(workflowId, token, yieldAmount);
    }

    /**
     * @notice Recover tokens accidentally sent to this contract
     * @param token Token address (or address(0) for native ETH)
     * @param to Recipient address
     * @param amount Amount to recover
     * @dev Emergency function - this contract should not hold funds
     */
    function recoverTokens(
        address token,
        address to,
        uint256 amount
    ) external {
        require(to != address(0), "Invalid recipient");
        
        if (token == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
