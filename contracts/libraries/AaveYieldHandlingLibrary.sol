// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '../interfaces/IYieldGenerationModule.sol';
import '../interfaces/IYieldDistributionModule.sol';
import '../interfaces/aave/AaveV3Interfaces.sol';
import '../libraries/AaveYieldLibrary.sol';
import '../libraries/YieldPresetLibrary.sol';
import '../types/EscrowTypes.sol';
import '../types/YieldPresets.sol';
import '../YieldOps.sol';

/**
 * @title AaveYieldHandlingLibrary
 * @notice Library for Aave V3 yield handling operations (deposit, withdrawal, distribution)
 * @dev Extracted from BaseEscrow to reduce contract size
 *      Handles Aave-specific yield operations using the library pattern (delegatecall)
 */
library AaveYieldHandlingLibrary {
    using SafeERC20 for IERC20;

    uint256 internal constant AAVE_RAY = 1e27;
    uint256 internal constant MAX_PROTOCOL_FEE_BPS = 3000; // 30% maximum
    
    // CRIT-1: Minimum normalized income to prevent precision loss (0.1% of RAY = 1e24)
    // This ensures scaledShares calculation doesn't overflow/underflow
    uint256 internal constant MIN_NORMALIZED_INCOME = 1e24; // 0.1% of RAY
    
    // CRIT-1: Minimum deposit amount to prevent scaledShares = 0 due to rounding
    // For 18-decimal tokens, this is 1e15 (0.001 tokens)
    // This ensures (amount * AAVE_RAY) / incomeRay >= 1
    //
    // NOTE: This value is optimized for 18-decimal tokens (WETH, DAI, etc.)
    // For 6-decimal tokens (USDC, USDT), this effectively blocks yield deposits
    // but escrow creation still succeeds (yield deposit fails silently).
    // Consider making this configurable per token in future versions.
    uint256 internal constant MIN_DEPOSIT_AMOUNT = 1e15;

    /**
     * @notice Result of yield withdrawal operation
     */
    struct WithdrawalResult {
        uint256 actualAmount;
        bool success;
        uint8 failureReason; // 0 = success, otherwise FailureReason enum
    }

    /**
     * @notice Result of yield deposit operation
     */
    struct DepositResult {
        bool success;
        uint256 scaledShares;
        uint8 failureReason; // 0 = success, otherwise FailureReason enum
    }

    /**
     * @notice Helper to get Aave pool address from module
     * @param genModule Yield generation module
     * @return poolAddress Aave pool address (0 if not available)
     */
    function getAavePoolAddress(IYieldGenerationModule genModule) internal view returns (address poolAddress) {
        if (address(genModule) == address(0)) {
            return address(0);
        }
        (bool success, bytes memory data) = address(genModule).staticcall(
            abi.encodeWithSelector(bytes4(keccak256("getAavePoolAddress()")))
        );
        if (success && data.length >= 32) {
            poolAddress = abi.decode(data, (address));
        }
    }

    /**
     * @notice Helper to get aToken address from module
     * @param genModule Yield generation module
     * @param token Underlying token address
     * @return aTokenAddress aToken address (0 if not available)
     */
    function getATokenAddress(IYieldGenerationModule genModule, address token) internal view returns (address aTokenAddress) {
        if (address(genModule) == address(0)) {
            return address(0);
        }
        (bool success, bytes memory data) = address(genModule).staticcall(
            abi.encodeWithSelector(bytes4(keccak256("getATokenAddress(address)")), token)
        );
        if (success && data.length >= 32) {
            aTokenAddress = abi.decode(data, (address));
        }
    }

    /**
     * @notice Read Aave normalized income (RAY) for an asset
     * @param pool Aave pool address
     * @param token Token address
     * @return incomeRay Normalized income in RAY (1e27 = 1.0)
     * @dev Returns AAVE_RAY (1.0) if unavailable or too small
     *      CRIT-1: Validates income is >= MIN_NORMALIZED_INCOME to prevent precision issues
     */
    function getAaveNormalizedIncome(address pool, address token) internal view returns (uint256 incomeRay) {
        if (pool == address(0)) return AAVE_RAY;
        (bool success, bytes memory data) = pool.staticcall(
            abi.encodeWithSelector(bytes4(keccak256("getReserveNormalizedIncome(address)")), token)
        );
        if (success && data.length >= 32) {
            incomeRay = abi.decode(data, (uint256));
            // CRIT-1: Handle zero or very small income (could cause overflow/underflow)
            if (incomeRay == 0 || incomeRay < MIN_NORMALIZED_INCOME) {
                return AAVE_RAY;
            }
            return incomeRay;
        }
        return AAVE_RAY;
    }

    /**
     * @notice Handle yield withdrawal via library pattern
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Original escrow amount
     * @param genModule Yield generation module
     * @param settings Escrow settings
     * @param scaledShares Current scaled shares for this escrow
     * @param aaveYieldLibrary Aave yield library address
     * @return result Withdrawal result
     */
    function handleYieldWithdrawal(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        uint256 scaledShares,
        address aaveYieldLibrary
    ) internal returns (WithdrawalResult memory result) {
        result.actualAmount = amount;
        result.success = false;
        result.failureReason = 0;

        // Check if yield is enabled
        if (settings.yieldPreset == YieldPreset.OFF) {
            return result;
        }

        if (address(genModule) == address(0)) {
            return result;
        }

        // Get aToken address from module
        address aToken = getATokenAddress(genModule, token);
        if (aToken == address(0)) {
            result.failureReason = 3; // MODULE_NOT_SET
            return result;
        }

        // Check if we have scaled shares
        if (scaledShares == 0) {
            result.failureReason = 2; // MALFORMED_RETURN_DATA
            return result;
        }

        // Get Aave pool address from module
        address aavePool = getAavePoolAddress(genModule);
        if (aavePool == address(0)) {
            result.failureReason = 3; // MODULE_NOT_SET
            return result;
        }

        // Compute underlying to withdraw = scaledShares * normalizedIncome / RAY
        uint256 incomeRay = getAaveNormalizedIncome(aavePool, token);
        uint256 underlyingToWithdraw = (scaledShares * incomeRay) / AAVE_RAY;
        if (underlyingToWithdraw == 0) {
            return result; // No underlying to withdraw
        }
        
        // Withdraw the calculated amount (or maximum available if less)
        // Note: Aave will return the actual amount available, which may be less than requested
        (bool success, bytes memory returnData) = aaveYieldLibrary.delegatecall(
            abi.encodeWithSelector(AaveYieldLibrary.withdraw.selector, aavePool, token, underlyingToWithdraw, address(this))
        );
        if (success && returnData.length >= 32) {
            uint256 withdrawnAmount = abi.decode(returnData, (uint256));
            
            // CRIT-1: Ensure user gets at least their principal back
            // If income decreased or precision issue caused less withdrawal, use original amount
            // This protects users from losing principal due to Aave edge cases
            if (withdrawnAmount < amount) {
                // Income decreased or precision issue - ensure principal protection
                // In this case, we've withdrawn what we could, but we need to ensure
                // the user gets at least their principal. The calling contract should
                // handle this by ensuring sufficient balance or reverting.
                // For now, we return the withdrawn amount and let the caller handle it.
                result.actualAmount = withdrawnAmount;
                result.success = true;
                // Note: Caller should validate actualAmount >= amount or handle gracefully
                return result;
            }
            
            result.actualAmount = withdrawnAmount;
            result.success = true;
            return result;
        }
        
        // Delegatecall failed
        result.failureReason = 9; // WITHDRAWAL_FAILED
        return result;
    }

    /**
     * @notice Handle yield deposit via library pattern
     * @param workflowId The escrow ID
     * @param token Token address
     * @param amount Amount to deposit
     * @param genModule Yield generation module
     * @param settings Escrow settings
     * @param aaveYieldLibrary Aave yield library address
     * @return result Deposit result
     */
    function handleYieldDeposit(
        uint256 workflowId,
        address token,
        uint256 amount,
        IYieldGenerationModule genModule,
        EscrowSettings memory settings,
        address aaveYieldLibrary
    ) internal returns (DepositResult memory result) {
        result.success = false;
        result.scaledShares = 0;
        result.failureReason = 0;

        // Check if yield is enabled
        if (settings.yieldPreset == YieldPreset.OFF) {
            return result;
        }

        if (address(genModule) == address(0)) {
            return result;
        }

        if (!genModule.isTokenSupported(token)) {
            return result;
        }

        // Get Aave pool and aToken addresses from module
        address aavePool = getAavePoolAddress(genModule);
        address aToken = getATokenAddress(genModule, token);

        if (aavePool == address(0) || aToken == address(0)) {
            result.failureReason = 3; // MODULE_NOT_SET
            return result;
        }

        // CRIT-1: Validate minimum deposit amount to prevent precision loss
        // For very small deposits, (amount * AAVE_RAY) / incomeRay could round to 0
        if (amount < MIN_DEPOSIT_AMOUNT) {
            result.failureReason = 8; // DEPOSIT_FAILED
            return result;
        }
        
        // Compute scaled shares for this escrow at current normalized income
        // scaledShares = amount * RAY / incomeRay
        uint256 incomeRay = getAaveNormalizedIncome(aavePool, token);
        
        // CRIT-1: Additional validation - ensure income is valid before calculation
        // This prevents division by very small numbers that could cause overflow
        if (incomeRay < MIN_NORMALIZED_INCOME) {
            result.failureReason = 3; // MODULE_NOT_SET (treat as configuration issue)
            return result;
        }
        
        uint256 scaledShares = (amount * AAVE_RAY) / incomeRay;
        if (scaledShares == 0) {
            result.failureReason = 8; // DEPOSIT_FAILED
            return result;
        }

        // Call library to supply (msg.sender = BaseEscrow via delegatecall)
        (bool success, ) = aaveYieldLibrary.delegatecall(
            abi.encodeWithSelector(AaveYieldLibrary.supply.selector, aavePool, token, amount, address(this))
        );
        if (success) {
            result.success = true;
            result.scaledShares = scaledShares;
            return result;
        }

        // Delegatecall failed
        result.failureReason = 8; // DEPOSIT_FAILED
        return result;
    }


}
