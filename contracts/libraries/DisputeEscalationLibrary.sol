// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../shared/interfaces/IResolutionModule.sol';
import '../libraries/EscrowEncodingLibrary.sol';
import '../libraries/BondHandlingLibrary.sol';
import '../decentralized-resolution-module/IIncentiveModule.sol';
import '../core/BondCollector.sol';
import '../types/EscrowTypes.sol';

/**
 * @title DisputeEscalationLibrary
 * @notice Library for escalateDispute logic extraction
 * @dev Extracted from BaseEscrow to reduce contract size (Phase 1 size optimization)
 */
library DisputeEscalationLibrary {
    /**
     * @notice Query required appeal bond from resolution module
     * @param resolutionModule Resolution module address
     * @param workflowId The escrow ID
     * @param currentLevel Current escalation level
     * @param escrowData Encoded escrow data
     * @return success True if query succeeded
     * @return bondAmount Required bond amount
     * @return bondToken Bond token address (address(0) for ETH)
     */
    function queryAppealBond(
        IResolutionModule resolutionModule,
        uint256 workflowId,
        uint8 currentLevel,
        bytes memory escrowData
    ) internal view returns (bool success, uint256 bondAmount, address bondToken) {
        (bool bondCheckSuccess, bytes memory bondData) = address(resolutionModule).staticcall(
            abi.encodeWithSelector(
                IResolutionModule.getRequiredAppealBond.selector,
                workflowId,
                currentLevel,
                escrowData
            )
        );
        
        if (!bondCheckSuccess || bondData.length < 64) {
            return (false, 0, address(0));
        }

        (bondAmount, bondToken) = abi.decode(bondData, (uint256, address));
        return (true, bondAmount, bondToken);
    }

    /**
     * @notice Validate msg.value against bond requirements
     * @param bondToken Bond token address (address(0) for ETH)
     * @param bondAmount Required bond amount
     * @param msgValue msg.value sent with transaction
     * @return valid True if validation passed
     * @return errorCode Error code: 0 = valid, 1 = insufficient ETH, 2 = unexpected ETH
     */
    function validateBondMsgValue(
        address bondToken,
        uint256 bondAmount,
        uint256 msgValue
    ) internal pure returns (bool valid, uint8 errorCode) {
        // errorCode: 0 = valid, 1 = insufficient ETH, 2 = unexpected ETH
        if (bondToken == address(0)) {
            if (msgValue < bondAmount) {
                return (false, 1); // Insufficient ETH
            }
        } else {
            if (msgValue != 0) {
                return (false, 2); // Unexpected ETH
            }
        }
        return (true, 0);
    }

    /**
     * @notice Process bond with fee calculation
     * @param bondAmount Required bond amount
     * @param bondToken Bond token address (address(0) for ETH)
     * @param incentiveModAddr Incentive module address (from snapshot)
     * @param snapshottedBondFee Protocol fee in basis points
     * @param escrowFeeAddress Fee recipient address
     * @return bondResult Bond processing result
     * @return incentiveMod Incentive module instance (if exists)
     * @dev Returns bondResult and incentiveMod. Caller handles ETH/ERC20 bond processing.
     */
    function processBondWithFeeCalculation(
        uint256 bondAmount,
        address bondToken,
        address incentiveModAddr,
        uint256 snapshottedBondFee,
        address escrowFeeAddress
    ) internal view returns (
        BondHandlingLibrary.BondProcessingResult memory bondResult,
        IIncentiveModule incentiveMod
    ) {
        if (bondAmount == 0 || incentiveModAddr == address(0)) {
            return (bondResult, IIncentiveModule(address(0))); // No bond or no incentive module
        }

        incentiveMod = IIncentiveModule(incentiveModAddr);

        // Process bond with fee calculation
        bondResult = BondHandlingLibrary.processBondWithFee(
            bondAmount,
            bondToken,
            snapshottedBondFee,
            escrowFeeAddress
        );
    }
}
