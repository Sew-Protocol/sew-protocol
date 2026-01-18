// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../decentralized-resolution-module/IIncentiveModule.sol';

/**
 * @title BondCollector
 * @notice External contract for collecting escalation bonds (ETH or ERC20)
 * @dev Extracted from BaseEscrow to reduce contract size (Priority 2 optimization)
 * 
 *      Handles:
 *      - ETH bond collection with protocol fee deduction
 *      - ERC20 bond collection with protocol fee deduction
 *      - Pull-based pattern for ERC20 (user approves escrow, escrow pulls)
 *      - Protocol fee transfer to fee address
 *      - Bond recording via incentive module
 */
contract BondCollector {
    using SafeERC20 for IERC20;

    // Events
    event ProtocolFeeCollected(
        uint8 indexed kind, // 1 = appeal bond
        uint256 indexed workflowId,
        address indexed token,
        uint256 bondAmount,
        uint256 feeBps,
        uint256 feeAmount
    );

    /**
     * @notice Collect escalation bond (ETH or ERC20) and deduct protocol fee
     * @param workflowId The escrow ID
     * @param incentiveMod Incentive module for bond recording
     * @param bondAmount Bond amount to collect
     * @param bondToken Bond token address (address(0) for ETH)
     * @param newLevel New escalation level
     * @param snapshottedBondFee Protocol fee in basis points (from module snapshot)
     * @param escrowFeeAddress Address to receive protocol fees
     * @param depositor Address that deposited the bond (user for ETH, escrow contract for ERC20)
     * @param escalatedBy Address that initiated the escalation (always the user)
     * @return collected Whether bond was successfully collected
     */
    function collectBond(
        uint256 workflowId,
        IIncentiveModule incentiveMod,
        uint256 bondAmount,
        address bondToken,
        uint8 newLevel,
        uint256 snapshottedBondFee,
        address escrowFeeAddress,
        address depositor,
        address escalatedBy
    ) external payable returns (bool collected) {
        if (address(incentiveMod) == address(0)) return false;
        
        if (bondToken == address(0)) {
            // ETH bond
            uint256 ethToSend = bondAmount;
            if (msg.value > bondAmount) {
                ethToSend = bondAmount;
            }
            
            uint256 protocolFeeAmount = 0;
            if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
                protocolFeeAmount = (ethToSend * snapshottedBondFee) / 10000;
                if (protocolFeeAmount > 0) {
                    // Transfer protocol fee first - if it fails, revert to keep accounting clean
                    (bool feeSuccess, ) = payable(escrowFeeAddress).call{value: protocolFeeAmount}('');
                    if (!feeSuccess) {
                        return false; // Fee transfer failed
                    }
                    ethToSend = ethToSend - protocolFeeAmount;
                    emit ProtocolFeeCollected(1, workflowId, bondToken, bondAmount, snapshottedBondFee, protocolFeeAmount);
                }
            }
            
            if (ethToSend > 0) {
                // ETH bond: call payable function with ETH value
                // For ETH bonds, depositor = escalatedBy = user
                (bool s, ) = address(incentiveMod).call{value: ethToSend}(
                    abi.encodeWithSelector(
                        IIncentiveModule.recordAppealBond.selector,
                        workflowId,
                        depositor, // depositor (user for ETH)
                        escalatedBy, // escalatedBy (user)
                        ethToSend,
                        bondToken,
                        newLevel
                    )
                );
                return s;
            }
        } else {
            // ERC20 bond - pull-based pattern
            // Step 1: Pull tokens from user to escrow contract (already done by BaseEscrow before calling this)
            // Step 2: Calculate and transfer protocol fee
            uint256 protocolFeeAmount = 0;
            uint256 bondToRecord = bondAmount;
            
            if (snapshottedBondFee > 0 && escrowFeeAddress != address(0)) {
                protocolFeeAmount = (bondAmount * snapshottedBondFee) / 10000;
                if (protocolFeeAmount > 0) {
                    bondToRecord = bondAmount - protocolFeeAmount;
                    IERC20(bondToken).safeTransfer(escrowFeeAddress, protocolFeeAmount);
                    emit ProtocolFeeCollected(1, workflowId, bondToken, bondAmount, snapshottedBondFee, protocolFeeAmount);
                }
            }
            
            // Step 3: Approve incentive module to pull remaining tokens
            if (bondToRecord > 0) {
                // Pull-based pattern: approve incentive module to pull tokens
                // If recordAppealBond fails, tokens remain with escrow contract (no loss)
                IERC20(bondToken).safeIncreaseAllowance(address(incentiveMod), bondToRecord);
                try incentiveMod.recordAppealBond(workflowId, depositor, escalatedBy, bondToRecord, bondToken, newLevel) {
                    // Reset approval to zero after successful call
                    IERC20(bondToken).approve(address(incentiveMod), 0);
                    return true;
                } catch {
                    // Reset approval on failure
                    IERC20(bondToken).approve(address(incentiveMod), 0);
                    return false;
                }
            }
        }
        return false;
    }
}
