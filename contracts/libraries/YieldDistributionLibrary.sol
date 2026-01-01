// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "../types/EscrowTypes.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldDistributionLibrary
 * @notice Library for yield distribution validation, encoding, and fallback distribution
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library YieldDistributionLibrary {
    using SafeERC20 for IERC20;

    /// @notice Fee denominator (10000 = 100% in basis points)
    uint256 public constant ESCROW_FEE_DENOMINATOR = 10000;

    /**
     * @dev Validate yield distribution parameters
     * @param recipients Array of recipient addresses
     * @param percentages Array of percentages in basis points (10000 = 100%)
     * @dev Reverts if validation fails: empty arrays, length mismatch, zero addresses, zero percentages,
     *      or percentages don't sum to 10000 (100%).
     */
    function validateYieldDistribution(
        address[] memory recipients,
        uint256[] memory percentages
    ) internal pure {
        if (recipients.length == 0) {
            revert InvalidAmount("Yield distribution must have at least one recipient");
        }
        if (recipients.length != percentages.length) {
            revert ArrayLengthMismatch(recipients.length, percentages.length);
        }
        
        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            if (recipients[i] == address(0)) {
                revert InvalidAddress("Recipient address cannot be zero", recipients[i]);
            }
            if (percentages[i] == 0) {
                revert InvalidAmount("Percentage must be greater than zero");
            }
            totalPercentage += percentages[i];
        }
        
        if (totalPercentage != ESCROW_FEE_DENOMINATOR) {
            revert InvalidAmount("Yield distribution percentages must sum to 10000 (100%)");
        }
    }

    /**
     * @dev Encode yield distribution data
     * @param distribution YieldDistribution struct to encode
     * @return Encoded distribution data as bytes
     */
    function encodeYieldDistribution(
        YieldDistribution memory distribution
    ) internal pure returns (bytes memory) {
        return abi.encode(distribution.recipients, distribution.percentages);
    }

    /**
     * @dev Decode yield distribution data
     * @param data Encoded distribution data
     * @return recipients Array of recipient addresses
     * @return percentages Array of percentages in basis points
     */
    function decodeYieldDistribution(
        bytes memory data
    ) internal pure returns (address[] memory recipients, uint256[] memory percentages) {
        return abi.decode(data, (address[], uint256[]));
    }

    /**
     * @dev Distribute yield using fallback distribution settings
     * @param token Token address
     * @param yieldAmount Amount of yield to distribute
     * @param distribution YieldDistribution struct with recipients and percentages
     * @param feeAddress Address to receive remainder if distribution is incomplete
     * @return totalDistributed Total amount distributed
     * @dev Distributes yield according to distribution settings. Sends remainder to feeAddress.
     */
    function distributeYieldFallback(
        address token,
        uint256 yieldAmount,
        YieldDistribution memory distribution,
        address feeAddress
    ) internal returns (uint256 totalDistributed) {
        if (yieldAmount == 0) {
            return 0;
        }

        if (distribution.isSet && distribution.recipients.length > 0) {
            totalDistributed = 0;
            for (uint256 i = 0; i < distribution.recipients.length; i++) {
                if (distribution.recipients[i] == address(0)) {
                    continue;
                }
                uint256 share = (yieldAmount * distribution.percentages[i]) / ESCROW_FEE_DENOMINATOR;
                if (share > 0) {
                    IERC20(token).safeTransfer(distribution.recipients[i], share);
                    totalDistributed += share;
                }
            }
            if (totalDistributed < yieldAmount && feeAddress != address(0)) {
                uint256 remainder = yieldAmount - totalDistributed;
                IERC20(token).safeTransfer(feeAddress, remainder);
            }
        } else if (feeAddress != address(0)) {
            IERC20(token).safeTransfer(feeAddress, yieldAmount);
            totalDistributed = yieldAmount;
        }
    }
}

