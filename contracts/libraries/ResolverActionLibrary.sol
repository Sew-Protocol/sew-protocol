// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.33;

import "../types/EscrowTypes.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../interfaces/IYieldDistributionModule.sol";
import "./YieldHandlingLibrary.sol";

/**
 * @title ResolverActionLibrary
 * @notice Library for resolver action execution (partial/full release/cancel)
 * @dev Extracted from BaseEscrow to reduce contract size
 *      Consolidates common logic between partialReleaseAsDisputeResolver and partialCancelAsDisputeResolver
 */
library ResolverActionLibrary {
    /**
     * @dev Parameters for resolver action
     */
    struct ActionParams {
        uint256 workflowId;
        uint256 amount;
        bool isRelease;      // true = release to recipient, false = cancel/refund to sender
        bool isPartial;      // true = partial, false = full
        address recipient;   // to (if release) or from (if cancel)
        address token;
        uint256 remainingBalance;
        uint256 totalDeposited;
    }

    /**
     * @dev Result of resolver action
     */
    struct ActionResult {
        uint256 actualAmount;
        uint256 yieldToDistribute;
        bool isComplete;
    }

    /**
     * @dev Execute resolver action (release or cancel, partial or full)
     * @param params Action parameters
     * @param genModule Yield generation module
     * @return result Action result
     */
    function executeAction(
        ActionParams memory params,
        IYieldGenerationModule genModule
    ) internal returns (ActionResult memory result) {
        result.isComplete = false;
        result.actualAmount = params.amount;
        result.yieldToDistribute = 0;

        // Calculate yield and withdraw if partial
        if (params.isPartial) {
            YieldHandlingLibrary.YieldWithdrawalResult memory yieldResult = 
                YieldHandlingLibrary.withdrawAndCalculateYield(
                    genModule,
                    params.workflowId,
                    params.token,
                    params.amount,
                    params.remainingBalance,
                    params.totalDeposited
                );
            result.actualAmount = yieldResult.actualAmount;
            result.yieldToDistribute = yieldResult.yieldToDistribute;
        } else {
            // Full action - withdraw with yield
            (uint256 actualAmount, uint256 yield) = YieldHandlingLibrary.withdrawFullWithYield(
                genModule,
                params.workflowId,
                params.token,
                params.amount
            );
            result.actualAmount = actualAmount;
            result.yieldToDistribute = yield;
        }

        return result;
    }
}

