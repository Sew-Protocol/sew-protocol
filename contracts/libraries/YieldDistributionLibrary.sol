// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '../types/EscrowTypes.sol';

/**
 * @title YieldDistributionLibrary
 * @notice Library for yield distribution validation, encoding, and fallback distribution
 * @dev Extracted from BaseEscrow to reduce contract size
 */
library YieldDistributionLibrary {
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
            revert InvalidAmount(AMOUNT_EMPTY);
        }
        if (recipients.length != percentages.length) {
            revert ArrayLengthMismatch(recipients.length, percentages.length);
        }

        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            if (recipients[i] == address(0)) {
                revert InvalidAddress(ADDR_RECIPIENT, recipients[i]);
            }
            if (percentages[i] == 0) {
                revert InvalidAmount(AMOUNT_GENERIC);
            }
            totalPercentage += percentages[i];
        }

        if (totalPercentage != ESCROW_FEE_DENOMINATOR) {
            revert InvalidAmount(AMOUNT_GENERIC);
        }
    }

    /**
     * @dev DEPRECATED: Encode yield distribution data
     * @dev This function is deprecated - distribution now derived from preset
     * @param recipients Array of recipient addresses
     * @param percentages Array of percentages in basis points
     * @return Encoded distribution data as bytes
     */
    function encodeYieldDistribution(
        address[] memory recipients,
        uint256[] memory percentages
    ) internal pure returns (bytes memory) {
        return abi.encode(recipients, percentages);
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
     * @dev DEPRECATED: Legacy fallback distribution helper.
     * @dev Pull-only hardening: no direct recipient transfers are performed here.
     *      Inputs are validated and callers should retain/credit yield via
     *      escrow-controlled claimable accounting.
     * @return totalDistributed Always 0 in pull-only mode.
     */
    function distributeYieldFallback(
        address,
        uint256 yieldAmount,
        address[] memory recipients,
        uint256[] memory percentages,
        address
    ) internal returns (uint256 totalDistributed) {
        if (yieldAmount == 0) {
            return 0;
        }

        if (recipients.length == 0 || recipients.length != percentages.length) {
            return 0;
        }

        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            if (recipients[i] == address(0)) {
                continue;
            }
            totalPercentage += percentages[i];
        }

        if (totalPercentage != ESCROW_FEE_DENOMINATOR) {
            return 0;
        }

        return 0;
    }
}
