// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";
import "./ResolverLogicLibrary.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldHandlingLibrary
 * @notice Library for yield withdrawal and distribution orchestration
 * @dev Extracted from BaseEscrow to reduce contract size
 *      Handles the workflow: calculate yield → withdraw → distribute
 */
library YieldHandlingLibrary {
    using SafeERC20 for IERC20;
    /**
     * @dev Result of yield withdrawal operation
     */
    struct YieldWithdrawalResult {
        uint256 actualAmount;      // Actual amount withdrawn (may include yield)
        uint256 yield;             // Yield amount (actualAmount - originalAmount)
        uint256 yieldToDistribute; // Proportional yield to distribute
    }

    /**
     * @dev Withdraw from yield module and calculate yield for partial operations
     * @param genModule Yield generation module (can be address(0))
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param amount Amount to withdraw
     * @param remainingBalance Remaining escrow balance (for proportional calculation)
     * @param originalDeposit Original deposit amount (for proportional withdrawal)
     * @return result Yield withdrawal result
     */
    function withdrawAndCalculateYield(
        IYieldGenerationModule genModule,
        uint256 workflowId,
        address token,
        uint256 amount,
        uint256 remainingBalance,
        uint256 originalDeposit
    ) internal returns (YieldWithdrawalResult memory result) {
        result.actualAmount = amount;
        result.yield = 0;
        result.yieldToDistribute = 0;

        if (address(genModule) == address(0)) {
            return result; // No yield module
        }

        // Calculate total yield
        uint256 totalYield = genModule.calculateYield(workflowId, token);
        
        // Calculate proportional yield to distribute
        result.yieldToDistribute = ResolverLogicLibrary.calculateProportionalYield(
            totalYield,
            amount,
            remainingBalance
        );

        // Withdraw proportional amount (includes yield)
        (bool success, uint256 amt) = genModule.withdrawProportional(
            workflowId,
            token,
            amount,
            originalDeposit
        );
        
        if (success) {
            result.actualAmount = amt;
            // Yield is already included in actualAmount, but we track it separately for distribution
            // Note: actualAmount may be > amount due to yield, but we use yieldToDistribute for distribution
        }

        return result;
    }

    /**
     * @dev Withdraw full amount from yield module (for complete release/cancel)
     * @param genModule Yield generation module (can be address(0))
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param amount Amount to withdraw
     * @return actualAmount Actual amount withdrawn (may include yield)
     * @return yield Yield amount (actualAmount - amount, if positive)
     */
    function withdrawFullWithYield(
        IYieldGenerationModule genModule,
        uint256 workflowId,
        address token,
        uint256 amount
    ) internal returns (uint256 actualAmount, uint256 yield) {
        actualAmount = amount;
        yield = 0;

        if (address(genModule) == address(0)) {
            return (actualAmount, yield);
        }

        (bool success, uint256 amt, ) = genModule.withdrawWithYield(workflowId, token, amount);
        
        if (success) {
            actualAmount = amt;
            if (amt > amount) {
                yield = amt - amount;
            }
        }

        return (actualAmount, yield);
    }

    /**
     * @dev Distribute yield via distribution module
     * @param distModule Yield distribution module (must not be address(0))
     * @param workflowId Escrow workflow ID
     * @param token Token address
     * @param yieldAmount Yield amount to distribute
     * @dev Transfers yield to module first, then calls distributeYield
     *      Reverts if distribution fails
     */
    function distributeYield(
        IYieldDistributionModule distModule,
        uint256 workflowId,
        address token,
        uint256 yieldAmount
    ) internal {
        if (yieldAmount == 0) return;
        require(address(distModule) != address(0), "No yield distribution module");

        // Transfer yield to module first (module expects tokens to be in its balance)
        // This matches the pattern used by DefaultYieldDistributionModule which uses safeTransfer
        IERC20(token).safeTransfer(address(distModule), yieldAmount);

        // Empty distributionData means no distribution configured - yield stays in contract
        // This allows tests to work without full distribution setup
        bytes memory distributionData = "";
        (bool success, ) = distModule.distributeYield(workflowId, token, yieldAmount, distributionData);
        // Revert if distribution fails - yield should be properly distributed
        // This ensures yield is not lost if distribution module has issues
        require(success, "Yield distribution failed");
    }

    /**
     * @dev Get approval target from yield generation module
     * @param genModule Yield generation module
     * @param token Token address (for EscrowableERC20, this is address(this))
     * @return approvalTarget Address that needs approval (address(0) if none or handled by module)
     * @dev For EscrowableERC20: module returns pool address, escrow contract handles approval
     *      For EscrowVault: typically returns address(0) as module handles approvals via forceApprove
     */
    function getApprovalTarget(
        IYieldGenerationModule genModule,
        address token
    ) internal view returns (address approvalTarget) {
        if (address(genModule) == address(0)) {
            return address(0);
        }
        
        // Try to get approval target from module (new interface method)
        try genModule.getApprovalTarget(token) returns (address target) {
            return target;
        } catch {
            // Module doesn't support getApprovalTarget yet, return address(0)
            return address(0);
        }
    }
}

