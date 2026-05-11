// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/utils/math/Math.sol';

/**
 * @title ProtocolMathLibrary
 * @notice Centralized library for protocol-standardized arithmetic, rounding, and decimal normalization.
 * @dev Replaces scattered mul/div logic with safe, auditable, and consistent Math.mulDiv operations.
 */
library ProtocolMathLibrary {
    enum Rounding {
        Floor,
        Ceil
    }

    /**
     * @notice Safely calculates (amount * bps) / 10000 with explicit rounding.
     * @param amount The base amount
     * @param bps The basis points
     * @param rounding The rounding mode (Floor or Ceil)
     */
    function calculateBps(
        uint256 amount,
        uint256 bps,
        Rounding rounding
    ) internal pure returns (uint256) {
        Math.Rounding mode = rounding == Rounding.Floor ? Math.Rounding.Floor : Math.Rounding.Ceil;
        return Math.mulDiv(amount, bps, 10000, mode);
    }

    /**
     * @notice Normalizes an amount from one decimal scale to another.
     * @param amount The base amount
     * @param fromDecimals Current decimals
     * @param toDecimals Target decimals
     * @param rounding The rounding mode
     */
    function normalize(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals,
        Rounding rounding
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) return amount;
        
        Math.Rounding mode = rounding == Rounding.Floor ? Math.Rounding.Floor : Math.Rounding.Ceil;

        if (fromDecimals < toDecimals) {
            uint256 multiplier = 10**(toDecimals - fromDecimals);
            return amount * multiplier;
        } else {
            uint256 divisor = 10**(fromDecimals - toDecimals);
            return Math.mulDiv(amount, 1, divisor, mode);
        }
    }
}
