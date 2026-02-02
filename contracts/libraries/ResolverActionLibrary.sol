// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import './YieldHandlingLibrary.sol';

/**
 * @title ResolverActionLibrary
 * @notice Library for resolver action execution (full release/cancel only)
 * @dev Extracted from BaseEscrow to reduce contract size
 *      Note: Partial operations removed - escrow amounts are now immutable
 */
library ResolverActionLibrary {
    /**
     * @dev Parameters for resolver action
     */
    struct ActionParams {
        uint256 workflowId;
        uint256 amount;
        bool isRelease; // true = release to recipient, false = cancel/refund to sender
        address recipient; // to (if release) or from (if cancel)
        address token;
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
     * @dev Execute resolver action (release or cancel, full only)
     * @param params Action parameters
     * @param genModule Yield generation module
     * @return result Action result
     */
    function executeAction(
        ActionParams memory params,
        IYieldGenerationModule genModule,
        address escrowContract
    ) internal returns (ActionResult memory result) {
        result.isComplete = true; // Always complete for full resolution
        result.actualAmount = params.amount;
        result.yieldToDistribute = 0;

        // Full action - withdraw with yield
        (uint256 actualAmount, uint256 yield) = YieldHandlingLibrary.withdrawFullWithYield(
            genModule,
            params.workflowId,
            params.token,
            params.amount,
            escrowContract
        );
        result.actualAmount = actualAmount;
        result.yieldToDistribute = yield;

        return result;
    }
}
