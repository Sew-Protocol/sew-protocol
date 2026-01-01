// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../interfaces/IResolver.sol";
import "../interfaces/IYieldGenerationModule.sol";
import "../types/EscrowTypes.sol";

// Payout struct is defined in IResolver.sol at file level

/**
 * @title ResolverLogicLibrary
 * @notice Library for resolver payout calculations and yield handling
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library ResolverLogicLibrary {
    /**
     * @dev Calculate proportional yield for payouts
     * @param totalYield Total yield amount
     * @param payoutAmount Individual payout amount
     * @param totalAmount Total escrow amount
     * @return Proportional yield for this payout
     */
    function calculateProportionalYield(
        uint256 totalYield,
        uint256 payoutAmount,
        uint256 totalAmount
    ) internal pure returns (uint256) {
        if (totalAmount == 0) return 0;
        return (totalYield * payoutAmount) / totalAmount;
    }

    /**
     * @dev Calculate total yield to distribute across all payouts
     * @param totalYield Total yield amount
     * @param payoutAmounts Array of payout amounts
     * @param totalAmount Total escrow amount
     * @return Total yield to distribute
     */
    function calculateTotalYieldToDistribute(
        uint256 totalYield,
        uint256[] memory payoutAmounts,
        uint256 totalAmount
    ) internal pure returns (uint256) {
        if (totalAmount == 0) return 0;
        uint256 yieldToDistribute = 0;
        for (uint256 i = 0; i < payoutAmounts.length; i++) {
            uint256 proportionalYield = calculateProportionalYield(totalYield, payoutAmounts[i], totalAmount);
            if (proportionalYield > 0) {
                yieldToDistribute += proportionalYield;
            }
        }
        return yieldToDistribute;
    }

    /**
     * @dev Adjust payout amounts proportionally based on actual withdrawal amount
     * @param payoutAmounts Array of payout amounts to adjust
     * @param actualTotalPayout Actual total amount withdrawn
     * @param requestedTotalPayout Requested total payout amount
     * @return Adjusted payout amounts
     * @dev Multiplies before dividing to maintain precision
     */
    function adjustPayoutAmounts(
        uint256[] memory payoutAmounts,
        uint256 actualTotalPayout,
        uint256 requestedTotalPayout
    ) internal pure returns (uint256[] memory) {
        if (actualTotalPayout == requestedTotalPayout || requestedTotalPayout == 0) {
            return payoutAmounts;
        }
        for (uint256 i = 0; i < payoutAmounts.length; i++) {
            payoutAmounts[i] = (payoutAmounts[i] * actualTotalPayout) / requestedTotalPayout;
        }
        return payoutAmounts;
    }

    /**
     * @dev Validate payout array and calculate total
     * @param payouts Array of payout structs
     * @param availableBalance Available escrow balance
     * @return totalPayout Sum of all payout amounts
     * @dev Reverts if validation fails
     */
    function validatePayouts(
        Payout[] memory payouts,
        uint256 availableBalance
    ) internal pure returns (uint256 totalPayout) {
        if (payouts.length == 0) {
            revert InvalidAmount("At least one payout required");
        }

        totalPayout = 0;
        for (uint256 i = 0; i < payouts.length; i++) {
            if (payouts[i].recipient == address(0)) {
                revert InvalidAddress("Payout recipient cannot be zero", address(0));
            }
            if (payouts[i].amount == 0) {
                revert InvalidAmount("Payout amount must be greater than zero");
            }
            totalPayout += payouts[i].amount;
        }

        if (totalPayout > availableBalance) {
            revert InvalidAmount("Total payout exceeds available balance");
        }
    }

    /**
     * @dev Copy payout amounts to memory array
     * @param payouts Array of payout structs
     * @return Array of payout amounts
     */
    function copyPayoutAmounts(
        Payout[] memory payouts
    ) internal pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](payouts.length);
        for (uint256 i = 0; i < payouts.length; i++) {
            amounts[i] = payouts[i].amount;
        }
        return amounts;
    }
}

