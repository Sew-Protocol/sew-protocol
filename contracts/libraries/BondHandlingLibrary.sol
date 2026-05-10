// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../shared/interfaces/IIncentiveModule.sol';
import '../core/BondCollector.sol';

library BondHandlingLibrary {
    using SafeERC20 for IERC20;

    struct BondProcessingResult {
        bool success;
        uint256 bondToRecord;
        uint256 protocolFeeAmount;
    }

    /**
     * @notice Process appeal bond with protocol fee calculation
     * @param bondAmount Total bond amount
     * @param bondToken Token address (address(0) for ETH)
     * @param snapshottedBondFee Protocol fee in basis points
     * @param escrowFeeAddress Fee recipient address
     * @return result Bond processing result
     */
    function processBondWithFee(
        uint256 bondAmount,
        address bondToken,
        uint256 snapshottedBondFee,
        address escrowFeeAddress
    ) internal pure returns (BondProcessingResult memory result) {
        result.success = true;
        result.bondToRecord = bondAmount;
        result.protocolFeeAmount = 0;

        if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
            result.protocolFeeAmount = (bondAmount * snapshottedBondFee) / 10000;
            if (result.protocolFeeAmount > 0) {
                result.bondToRecord = bondAmount - result.protocolFeeAmount;
            }
        }
    }

    /**
     * @notice Handle ETH bond payment and recording
     * @param incentiveMod Incentive module contract
     * @param workflowId Escrow workflow ID
     * @param escalatedBy Address that escalated
     * @param bondToRecord Net bond amount after fee
     * @param bondToken Token address (must be address(0) for ETH)
     * @param newLevel New escalation level
     * @param escrowFeeAddress Fee recipient (unused in pull-only hardening)
     * @param protocolFeeAmount Protocol fee amount
     */
    function handleETHBond(
        IIncentiveModule incentiveMod,
        uint256 workflowId,
        address escalatedBy,
        uint256 bondToRecord,
        address bondToken,
        uint8 newLevel,
        address escrowFeeAddress,
        uint256 protocolFeeAmount
    ) internal {
        // Pull-only hardening: do not auto-forward protocol fees.
        // Any fee amount remains in escrow custody for explicit governed withdrawal.
        escrowFeeAddress; // silence unused-parameter warning
        protocolFeeAmount; // silence unused-parameter warning

        // Record bond (depositor MUST equal escalatedBy for ETH bonds)
        incentiveMod.recordAppealBond{value: bondToRecord}(
            workflowId,
            address(this),
            escalatedBy, // depositor
            escalatedBy, // escalatedBy
            bondToRecord,
            bondToken,
            newLevel
        );
    }

    /**
     * @notice Handle ERC20 bond payment and recording (after tokens are already pulled)
     * @param incentiveMod Incentive module contract
     * @param bondCollector Bond collector contract
     * @param workflowId Escrow workflow ID
     * @param escalatedBy Address that escalated
     * @param bondToken Token address
     * @param bondToRecord Net bond amount after fee
     * @param newLevel New escalation level
     * @param escrowFeeAddress Fee recipient (unused in pull-only hardening)
     * @param protocolFeeAmount Protocol fee amount
     */
    function handleERC20BondAfterPull(
        IIncentiveModule incentiveMod,
        BondCollector bondCollector,
        uint256 workflowId,
        address escalatedBy,
        address bondToken,
        uint256 bondToRecord,
        uint8 newLevel,
        address escrowFeeAddress,
        uint256 protocolFeeAmount
    ) internal {
        // Pull-only hardening: do not auto-forward protocol fees.
        // Fee tokens remain in escrow custody for explicit governed withdrawal.
        escrowFeeAddress; // silence unused-parameter warning
        protocolFeeAmount; // silence unused-parameter warning
        
        // Transfer to bond collector
        IERC20(bondToken).safeTransfer(address(bondCollector), bondToRecord);

        // Approve and record bond
        bondCollector.approveBondSpender(bondToken, address(incentiveMod), bondToRecord);
        incentiveMod.recordAppealBond(
            workflowId,
            address(this),
            address(bondCollector), // depositor (custodian)
            escalatedBy, // escalatedBy
            bondToRecord,
            bondToken,
            newLevel
        );
        bondCollector.resetBondSpender(bondToken, address(incentiveMod));
    }

    error TransferFailed(uint8 kind, address token, address to, uint256 amount);
}
