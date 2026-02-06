// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../shared/interfaces/IIncentiveModule.sol';
import '../core/BaseEscrow.sol';

/**
 * @title DisputeRaiseLibrary
 * @notice Library for raiseDispute logic extraction
 * @dev Extracted from BaseEscrow to reduce contract size (Phase 1 size optimization)
 */
library DisputeRaiseLibrary {
    /**
     * @notice Call incentive module onDisputeOpened hook
     * @param incentiveModAddr Address of incentive module (from snapshot)
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amountAfterFee Amount after fee
     * @param escrowFee Escrow fee in basis points
     * @param escrowFeeDenominator Fee denominator (10000)
     * @dev Returns whether to emit failure events (caller should emit if true)
     */
    function callIncentiveModuleHook(
        address incentiveModAddr,
        uint256 workflowId,
        address token,
        uint256 amountAfterFee,
        uint256 escrowFee,
        uint256 escrowFeeDenominator
    ) internal returns (bool shouldEmitFailure) {
        if (incentiveModAddr == address(0)) {
            return false; // No incentive module, no failure to emit
        }

        IIncentiveModule incentiveMod = IIncentiveModule(incentiveModAddr);
        
        // Calculate escrow fee: fee = amount * escrowFee / ESCROW_FEE_DENOMINATOR
        // Original amount = amountAfterFee + fee, so: fee = (amountAfterFee * escrowFee) / (ESCROW_FEE_DENOMINATOR - escrowFee)
        uint256 originalAmount = amountAfterFee +
            ((amountAfterFee * escrowFee) / (escrowFeeDenominator - escrowFee));
        uint256 escrowFeeAmount = (originalAmount * escrowFee) / escrowFeeDenominator;
        
        // Use low-level call to save bytecode (replaces try/catch)
        (bool success, ) = address(incentiveMod).call(
            abi.encodeWithSelector(
                IIncentiveModule.onDisputeOpened.selector,
                workflowId,
                address(this),
                token,
                originalAmount,
                escrowFeeAmount,
                0
            )
        );
        
        return !success; // Return true if call failed (caller should emit events)
    }
}
